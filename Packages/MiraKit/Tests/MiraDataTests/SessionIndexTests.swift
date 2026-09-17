import Foundation
import Testing
import MiraCore
@testable import MiraData

@Suite("Persistent session offsets")
struct SessionIndexTests {
    @Test func reopenVerifiesSourceBytesWithoutDecodingTheJournalAndPagesByOffset() async throws {
        try await withDirectory { directory in
            let id = ConversationID()
            let writer = try FileSessionLibrary(directory: directory)
            let batches = (0..<140).map { batch(id, sequence: Int64($0)) }
            for batch in batches { #expect(await writer.append(batch) == .committed(batch.cursor)) }
            try await writer.close()
            let reopened = try FileSessionLibrary(directory: directory)
            let before = await reopened.readMetrics()
            #expect(before.indexedSessions == 1)
            #expect(before.scannedBatches == 0)
            #expect(before.verifiedJournalBytes > 0)
            #expect(try await reopened.read(sessionID: id, after: 137, limit: 2) == Array(batches[137..<139]))
            #expect(try await reopened.batch(id: batches[0].id, sessionID: id) == batches[0])
            let after = await reopened.readMetrics()
            #expect(after.pageDecodedBatches - before.pageDecodedBatches == 3)
            try await reopened.close()
        }
    }

    @Test func missingAndDamagedIndexesRebuildWithoutChangingTheJournal() async throws {
        try await withDirectory { directory in
            let id = ConversationID(), writer = try FileSessionLibrary(directory: directory)
            let value = batch(id, sequence: 0)
            #expect(await writer.append(value) == .committed(value.cursor)); try await writer.close()
            let journal = journalURL(directory, id), index = indexURL(directory, id)
            let original = try Data(contentsOf: journal)
            for damage in [false, true] {
                if damage { try Data("damaged sidecar".utf8).write(to: index) }
                else { try FileManager.default.removeItem(at: index) }
                let reopened = try FileSessionLibrary(directory: directory)
                #expect(await reopened.readMetrics().scannedBatches == 1)
                #expect(try await reopened.batch(id: value.id, sessionID: id) == value)
                try await reopened.close()
                #expect(try Data(contentsOf: journal) == original)
            }
            let cached = try FileSessionLibrary(directory: directory)
            #expect(await cached.readMetrics().indexedSessions == 1)
            try await cached.close()
        }
    }

    @Test func completeJournalCorruptionCannotHideBehindAValidSidecarOrRestoredModificationDate() async throws {
        try await withDirectory { directory in
            let id = ConversationID(), writer = try FileSessionLibrary(directory: directory)
            #expect(await writer.append(batch(id, sequence: 0)).isCommittedForIndexTest)
            try await writer.close()
            let url = journalURL(directory, id)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            var bytes = try Data(contentsOf: url); bytes[12] ^= 1; try bytes.write(to: url)
            if let date = attributes[.modificationDate] { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
            #expect(throws: MiraError.self) { _ = try FileSessionLibrary(directory: directory) }
        }
    }

    @Test func staleSidecarRecoversTheValidTailAndRejectsStaleMetadata() async throws {
        try await withDirectory { directory in
            let id = ConversationID(), writer = try FileSessionLibrary(directory: directory)
            let first = batch(id, sequence: 0), second = batch(id, sequence: 1)
            #expect(await writer.append(first) == .committed(first.cursor)); try await writer.close()
            let url = journalURL(directory, id)
            var bytes = try Data(contentsOf: url)
            bytes.append(try wrapFileSessionRecord(batch: second, payloads: [:]))
            // An interrupted final delimiter is recovered even with an earlier valid index.
            try bytes.write(to: url)
            let reopened = try FileSessionLibrary(directory: directory)
            #expect(await reopened.readMetrics().scannedBatches == 2)
            #expect(try await reopened.head(sessionID: id) == .init(cursor: second.cursor, batchID: second.id))
            #expect(try await reopened.read(sessionID: id, after: 0, limit: 2) == [first, second])
            try await reopened.close()
        }
    }

    @Test func indexPublicationFailureDoesNotChangeAcknowledgedOutcome() async throws {
        for stage in [SessionStorageFaultStage.beforeIndexWrite, .afterIndexWrite, .beforeIndexPublication, .afterIndexPublication] {
            try await withDirectory { directory in
                let writer = try FileSessionLibrary(directory: directory) { current in
                    if current == stage { throw MiraError(.storage, "Synthetic sidecar failure.") }
                }
                let id = ConversationID(), value = batch(id, sequence: 0)
                #expect(await writer.append(value) == .committed(value.cursor))
                try await writer.flush(); try await writer.close()
                let reopened = try FileSessionLibrary(directory: directory)
                #expect(try await reopened.batch(id: value.id, sessionID: id) == value)
                try await reopened.close()
            }
        }
    }

    @Test func pageReadDetectsJournalMutationAfterOpening() async throws {
        try await withDirectory { directory in
            let id = ConversationID(), writer = try FileSessionLibrary(directory: directory)
            let value = batch(id, sequence: 0)
            #expect(await writer.append(value) == .committed(value.cursor))
            let url = journalURL(directory, id)
            var bytes = try Data(contentsOf: url); bytes[12] ^= 1; try bytes.write(to: url)
            await #expect(throws: MiraError.self) { _ = try await writer.batch(id: value.id, sessionID: id) }
            if case .notCommitted = await writer.append(batch(id, sequence: 1)) {} else { Issue.record("Changed source accepted an append.") }
            try await writer.close()
        }
    }

    @Test func linkedSidecarsAreRejectedAndInterruptedTemporaryFilesAreRemoved() async throws {
        try await withDirectory { directory in
            let id = ConversationID(), writer = try FileSessionLibrary(directory: directory)
            #expect(await writer.append(batch(id, sequence: 0)).isCommittedForIndexTest)
            try await writer.close()
            let temporary = directory.appendingPathComponent("indexes/.stage-\(UUID().uuidString)")
            try Data("interrupted".utf8).write(to: temporary)
            let clean = try FileSessionLibrary(directory: directory)
            #expect(!FileManager.default.fileExists(atPath: temporary.path)); try await clean.close()
            let index = indexURL(directory, id), outside = directory.appendingPathComponent("external.index")
            try FileManager.default.moveItem(at: index, to: outside)
            try FileManager.default.createSymbolicLink(at: index, withDestinationURL: outside)
            #expect(throws: MiraError.self) { _ = try FileSessionLibrary(directory: directory) }
        }
    }

    private func withDirectory(_ operation: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-index-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await operation(directory)
    }
    private func batch(_ id: ConversationID, sequence: Int64) -> SessionBatch {
        .init(id: UUID(), sessionID: id, expectedSequence: sequence,
              events: [.init(sequence: sequence + 1, occurredAt: Date(), fact: .archived(revision: Int(sequence + 1)))])
    }
    private func journalURL(_ directory: URL, _ id: ConversationID) -> URL { directory.appendingPathComponent("sessions/\(id.rawValue.uuidString).jsonl") }
    private func indexURL(_ directory: URL, _ id: ConversationID) -> URL { directory.appendingPathComponent("indexes/\(id.rawValue.uuidString).index") }

    private func wrapFileSessionRecord(batch: SessionBatch, payloads: [String: String]) throws -> Data {
        try FileSessionIO.encodeRecord(FileSessionRecord(batch: batch, payloads: payloads))
    }
}

private extension SessionAppendOutcome {
    var isCommittedForIndexTest: Bool { if case .committed = self { true } else { false } }
}
