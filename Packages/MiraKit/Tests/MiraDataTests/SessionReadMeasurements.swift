import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

/// Explicit measurements use synthetic metadata batches, not a product-scale message corpus.
@Suite("Journal read measurements", .serialized)
struct SessionReadMeasurements {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIRA_MEASURE_SESSION_READS"] == "1"))
    func measureIndexedReopenAndCheckpointRestore() async throws {
        for count in [1_000, 10_000] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("mira-read-measure-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let writer = try FileSessionLibrary(directory: root)
            let id = ConversationID(), firstID = UUID()
            let title = try await writer.stage(Data("Synthetic benchmark".utf8), sessionID: id, batchID: firstID, kind: .title)
            let body = try await writer.stage(Data("Synthetic module".utf8), sessionID: id, batchID: firstID, kind: .module)
            let first = SessionBatch(id: firstID, sessionID: id, expectedSequence: 0, events: [
                .init(sequence: 1, occurredAt: Date(timeIntervalSince1970: 1), fact: .opened(.init(workspaceID: nil, title: title))),
                .init(sequence: 2, occurredAt: Date(timeIntervalSince1970: 1), fact: .extensionRecorded(namespace: "bench.sample", schemaVersion: 1, required: false, body: body))
            ])
            #expect(await writer.append(first) == .committed(first.cursor))
            for ordinal in 1..<count {
                let sequence = Int64(ordinal + 1)
                let batch = SessionBatch(id: UUID(), sessionID: id, expectedSequence: sequence, events: [
                    .init(sequence: sequence + 1, occurredAt: Date(timeIntervalSince1970: Double(ordinal)),
                          fact: .extensionRecorded(namespace: "bench.sample", schemaVersion: 1, required: false, body: body))
                ])
                #expect(await writer.append(batch) == .committed(batch.cursor))
            }
            let replayStart = ContinuousClock.now
            let snapshot = try await JournalSessionReader(journal: writer, payloads: writer).snapshot(sessionID: id)
            let initialReplayMS = milliseconds(replayStart.duration(to: .now))
            try await writer.close()
            var openMS: [Double] = [], restoreMS: [Double] = [], pageMS: [Double] = []
            for iteration in 0..<35 {
                let openStart = ContinuousClock.now
                let library = try FileSessionLibrary(directory: root)
                let opened = milliseconds(openStart.duration(to: .now))
                let restoreStart = ContinuousClock.now
                let restored = try await JournalSessionReader(journal: library, payloads: library).snapshot(sessionID: id)
                let restore = milliseconds(restoreStart.duration(to: .now))
                #expect(restored == snapshot)
                let pageStart = ContinuousClock.now
                #expect(try await library.read(sessionID: id, after: Int64(count - 9), limit: 10).count == 10)
                let page = milliseconds(pageStart.duration(to: .now))
                let metrics = await library.readMetrics()
                #expect(metrics.scannedBatches == 0 && metrics.indexedSessions == 1 && metrics.restoredCheckpoints == 1)
                #expect(metrics.pageDecodedBatches == 12)
                try await library.close()
                if iteration >= 5 { openMS.append(opened); restoreMS.append(restore); pageMS.append(page) }
            }
            let fileManager = FileManager.default
            func bytes(_ path: String) throws -> Int { (try fileManager.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.size] as! NSNumber).intValue }
            let result = ReadMeasurement(batchCount: count, warmups: 5, samples: 30,
                journalBytes: try bytes("sessions/\(id.rawValue.uuidString).jsonl"),
                indexBytes: try bytes("indexes/\(id.rawValue.uuidString).index"),
                checkpointBytes: try bytes("checkpoints/\(id.rawValue.uuidString).state"),
                initialReplayMS: initialReplayMS, reopenP95MS: p95(openMS), checkpointP95MS: p95(restoreMS), pageP95MS: p95(pageMS))
            let encoded = try SessionCodec.encode(result)
            print("MIRA_SESSION_READ_MEASUREMENT " + String(decoding: encoded, as: UTF8.self))
        }
    }
    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
    private func p95(_ values: [Double]) -> Double { values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1] }
}

private struct ReadMeasurement: Encodable {
    let batchCount: Int, warmups: Int, samples: Int
    let journalBytes: Int, indexBytes: Int, checkpointBytes: Int
    let initialReplayMS: Double, reopenP95MS: Double, checkpointP95MS: Double, pageP95MS: Double
}
