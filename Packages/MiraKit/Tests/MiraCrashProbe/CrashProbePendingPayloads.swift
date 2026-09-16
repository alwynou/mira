import Foundation
import MiraCore
import MiraData

enum CrashProbePendingPayloads {
    private struct Input: Codable {
        let scenario: String
        let sessionID: ConversationID
        let initialBatch: SessionBatch
        let newBatch: SessionBatch
        let oldTitle: SessionPayloadReference
        let newTitle: SessionPayloadReference?
        let unused: SessionPayloadReference?
    }

    static func crash(_ context: CrashProbeContext, scenario: String) async throws {
        let gate = PendingPayloadGate(context: context)
        let library = try FileSessionLibrary(directory: context.journalDirectory, faultInjector: gate.visit)
        do {
            let sessionID = ConversationID()
            let initialID = UUID()
            let oldTitle = try await library.stage(Data("Initial crash probe title".utf8), sessionID: sessionID,
                                                   batchID: initialID, retentionGroup: UUID(), kind: .title)
            let initial = SessionBatch(id: initialID, sessionID: sessionID, expectedSequence: 0, events: [
                .init(sequence: 1, occurredAt: Date(timeIntervalSince1970: 1_800_000_001),
                      fact: .opened(.init(workspaceID: nil, title: oldTitle)))
            ])
            try probeRequire(await library.append(initial) == .committed(initial.cursor), "Initial seed did not commit.")

            let nextID = UUID()
            let next: SessionBatch
            switch scenario {
            case "pendingPayloadMarked", "pendingPayloadWritten":
                // The identity is durable in test input before stage returns its reference.
                next = SessionBatch(id: nextID, sessionID: sessionID, expectedSequence: 1, events: [
                    .init(sequence: 2, occurredAt: Date(timeIntervalSince1970: 1_800_000_002),
                          fact: .renamed(title: oldTitle, revision: 2))
                ])
                try context.save(Input(scenario: scenario, sessionID: sessionID, initialBatch: initial,
                                      newBatch: next, oldTitle: oldTitle, newTitle: nil, unused: nil))
                gate.arm(scenario == "pendingPayloadMarked" ? .afterPendingPayloadMark : .afterPayloadSync)
                // Non-UTF-8 bytes force the external-payload path being interrupted here.
                _ = try await library.stage(Data([0xff, 0xfe]), sessionID: sessionID, batchID: nextID,
                                            retentionGroup: UUID(), kind: .module)
            case "pendingPayloadClearing", "pendingPayloadCleared":
                let title = try await library.stage(Data("New crash probe title".utf8), sessionID: sessionID,
                                                     batchID: nextID, retentionGroup: UUID(), kind: .title)
                let draft = try await library.stage(Data([0xff, 0xfe]), sessionID: sessionID,
                                                     batchID: nextID, retentionGroup: UUID(), kind: .module)
                next = SessionBatch(id: nextID, sessionID: sessionID, expectedSequence: 1, events: [
                    .init(sequence: 2, occurredAt: Date(timeIntervalSince1970: 1_800_000_002),
                          fact: .renamed(title: title, revision: 2))
                ])
                try context.save(Input(scenario: scenario, sessionID: sessionID, initialBatch: initial,
                                      newBatch: next, oldTitle: oldTitle, newTitle: title, unused: draft))
                gate.arm(scenario == "pendingPayloadClearing" ? .beforePendingPayloadClear : .afterPendingPayloadClear)
                _ = await library.append(next)
            default:
                throw MiraError(.invalidInput, "The pending payload scenario is unknown.")
            }
            throw MiraError(.conflict, "The pending payload crash boundary was missed.")
        } catch {
            try? await library.close()
            throw error
        }
    }

    static func verify(_ context: CrashProbeContext, scenario: String) async throws -> [String: Int] {
        let input = try context.load(Input.self)
        try probeRequire(input.scenario == scenario, "The pending payload probe input changed.")
        let library = try FileSessionLibrary(directory: context.journalDirectory)
        do {
            let head = try await library.head(sessionID: input.sessionID)
            let committed = scenario == "pendingPayloadClearing" || scenario == "pendingPayloadCleared"
            let expected = committed ? input.newBatch : input.initialBatch
            try probeRequire(head == .init(cursor: expected.cursor, batchID: expected.id), "Recovery exposed the wrong journal head.")
            try probeRequire(try await library.batch(id: input.initialBatch.id, sessionID: input.sessionID) == input.initialBatch,
                             "Recovery changed the initial batch identity.")
            try probeRequire(try await library.read(input.oldTitle) == Data("Initial crash probe title".utf8), "The old title was lost.")
            if committed {
                try probeRequire(try await library.batch(id: input.newBatch.id, sessionID: input.sessionID) == input.newBatch,
                                 "The committed pending batch was lost.")
                guard let newTitle = input.newTitle, let unused = input.unused else { throw MiraError(.storage, "Missing committed payload identities.") }
                try probeRequire(try await library.read(newTitle) == Data("New crash probe title".utf8), "The new title was lost.")
                try probeRequire((try? await library.read(unused)) == nil, "An unreferenced same-batch payload survived.")
                let unusedURL = context.journalDirectory.appendingPathComponent("payloads")
                    .appendingPathComponent(unused.sessionID.rawValue.uuidString)
                    .appendingPathComponent(unused.batchID.uuidString)
                    .appendingPathComponent(unused.id.uuidString + ".bin")
                try probeRequire(!FileManager.default.fileExists(atPath: unusedURL.path), "The unreferenced payload file was not removed.")
            } else {
                try probeRequire(try await library.batch(id: input.newBatch.id, sessionID: input.sessionID) == nil,
                                 "An uncommitted pending batch became visible.")
            }
            try await library.verifyNoUnpublished()
            let pending = try pendingMarkerCount(context.journalDirectory)
            try probeRequire(pending == 0, "A pending payload marker survived recovery.")
            try await library.close()
            return ["journalSequence": Int(head.cursor.sequence), "newBatch": committed ? 1 : 0,
                    "oldBody": 1, "unpublishedBodies": 0, "pendingMarkers": pending]
        } catch {
            try? await library.close()
            throw error
        }
    }

    private static func pendingMarkerCount(_ directory: URL) throws -> Int {
        let pending = directory.appendingPathComponent("pending-payloads", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil).count
    }
}

private final class PendingPayloadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed: SessionStorageFaultStage?
    private let context: CrashProbeContext
    init(context: CrashProbeContext) { self.context = context }
    func arm(_ stage: SessionStorageFaultStage) { lock.withLock { armed = stage } }
    func visit(_ stage: SessionStorageFaultStage) throws {
        if lock.withLock({ armed == stage }) { try context.pause() }
    }
}
