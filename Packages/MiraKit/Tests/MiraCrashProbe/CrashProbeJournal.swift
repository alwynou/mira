import Foundation
import MiraCore
import MiraData

enum CrashProbeJournal {
    private struct Input: Codable {
        let scenario: String
        let batch: SessionBatch
        let originalTitle: SessionContent
        let newTitle: SessionContent
    }

    static func crash(_ context: CrashProbeContext, scenario: String) async throws {
        let gate = JournalCrashGate(context: context)
        let library = try FileSessionLibrary(directory: context.journalDirectory, faultInjector: gate.visit)
        do {
            let session = ConversationID()
            let firstID = UUID()
            let original = try await library.stage(
                Data("Original synthetic title".utf8), sessionID: session,
                batchID: firstID, kind: .title)
            let first = SessionBatch(
                id: firstID, sessionID: session, expectedSequence: 0,
                events: [
                    .init(
                        sequence: 1, occurredAt: Date(timeIntervalSince1970: 1),
                        fact: .opened(.init(workspaceID: nil, title: original)))
                ])
            try probeRequire(
                await library.append(first) == .committed(first.cursor), "The probe could not commit its initial batch."
            )
            let nextID = UUID()
            let changed = try await library.stage(
                Data("Changed synthetic title".utf8), sessionID: session,
                batchID: nextID, kind: .title)
            let batch = SessionBatch(
                id: nextID, sessionID: session, expectedSequence: 1,
                events: [
                    .init(
                        sequence: 2, occurredAt: Date(timeIntervalSince1970: 2),
                        fact: .renamed(title: changed, revision: 2)),
                    .init(
                        sequence: 3, occurredAt: Date(timeIntervalSince1970: 3),
                        fact: .renamed(title: changed, revision: 3)),
                ])
            try context.save(Input(scenario: scenario, batch: batch, originalTitle: original, newTitle: changed))
            if scenario == "payloadStaged" { try context.pause() }
            if scenario == "tornJournalTail" {
                // Deliberately leave a physical partial record, while the real writer still owns its lock.
                let url = context.journalDirectory.appendingPathComponent(
                    "sessions/\(session.rawValue.uuidString).jsonl")
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("{\"interrupted-record\":".utf8))
                try context.pause()
            }
            let stage: SessionStorageFaultStage
            switch scenario {
            case "beforeJournalWrite": stage = .beforeJournalWrite
            case "afterJournalWrite": stage = .afterJournalWrite
            case "afterJournalSync": stage = .afterJournalSync
            default: throw MiraError(.invalidInput, "The journal crash scenario is unknown.")
            }
            gate.arm(stage)
            _ = await library.append(batch)
            throw MiraError(.conflict, "The journal crash boundary was missed.")
        } catch {
            try? await library.close()
            throw error
        }
    }

    static func verify(_ context: CrashProbeContext, scenario: String) async throws -> [String: Int] {
        let input = try context.load(Input.self)
        try probeRequire(input.scenario == scenario, "The journal probe input changed.")
        let library = try FileSessionLibrary(directory: context.journalDirectory)
        do {
            let committed = scenario == "afterJournalWrite" || scenario == "afterJournalSync"
            let expected: Int64 = committed ? 3 : 1
            let before = try await library.head(sessionID: input.batch.sessionID)
            try probeRequire(before.cursor.sequence == expected, "Recovery exposed an invalid journal prefix.")
            let snapshot = try await JournalSessionReader(journal: library, payloads: library).snapshot(
                sessionID: input.batch.sessionID)
            try probeRequire(
                snapshot.state.sequence == expected && snapshot.state.revision == Int(expected),
                "The recovered batch was only partially reduced.")
            try probeRequire(
                try await library.read(input.originalTitle) == Data("Original synthetic title".utf8),
                "The prior committed body changed.")
            if committed {
                try probeRequire(
                    await library.reconcile(input.batch) == .committed(input.batch.cursor),
                    "Recovery lost the original batch identity.")
                try probeRequire(
                    await library.append(input.batch) == .committed(input.batch.cursor),
                    "Duplicate append did not return the original batch.")
                try probeRequire(
                    try await library.read(input.newTitle) == Data("Changed synthetic title".utf8),
                    "Recovery lost a committed body.")
            } else {
                try probeRequire(
                    try await library.batch(id: input.batch.id, sessionID: input.batch.sessionID) == nil,
                    "An uncommitted batch became visible.")
                try probeRequire(
                    (try? await library.read(input.newTitle)) == nil, "An unpublished body became readable.")
            }
            let after = try await library.head(sessionID: input.batch.sessionID)
            try probeRequire(after == before, "Verification replayed a journal command.")
            let batches = try await library.read(sessionID: input.batch.sessionID, after: 0, limit: 128)
            try probeRequire(batches.count == (committed ? 2 : 1), "Recovery changed the committed batch count.")
            try await library.close()
            return [
                "journalSequence": Int(after.cursor.sequence), "visibleBatches": batches.count, "unpublishedBodies": 0,
            ]
        } catch {
            try? await library.close()
            throw error
        }
    }
}

private final class JournalCrashGate: @unchecked Sendable {
    private let lock = NSLock()
    private var stage: SessionStorageFaultStage?
    private let context: CrashProbeContext
    init(context: CrashProbeContext) { self.context = context }
    func arm(_ stage: SessionStorageFaultStage) { lock.withLock { self.stage = stage } }
    func visit(_ stage: SessionStorageFaultStage) throws {
        if lock.withLock({ self.stage == stage }) { try context.pause() }
    }
}
