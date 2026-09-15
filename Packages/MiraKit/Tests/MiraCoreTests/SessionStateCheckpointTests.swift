import Foundation
import Testing
@testable import MiraCore

@Suite("Session state checkpoints")
struct SessionStateCheckpointTests {
    @Test func recoverySummaryMissReducesTheCompletePrefix() async throws {
        let fixture = try CheckpointFixture.openedAndRenamed()
        let target = try #require(await fixture.targetHead())
        let summary = try await JournalSessionReader(journal: fixture, payloads: EmptyPayloads())
            .recoverySummary(sessionID: target.cursor.sessionID)
        #expect(summary == .init(head: target, activeExecutionID: nil))
        #expect(await fixture.cacheCalls == 1)
    }

    @Test func recoverySummaryCannotSubstituteAnotherBatchOrSession() async throws {
        for damage in ["batch", "session", "sequence"] {
            let fixture = try CheckpointFixture.openedAndRenamed()
            let target = try #require(await fixture.targetHead())
            let cursor = SessionCursor(sessionID: damage == "session" ? ConversationID() : target.cursor.sessionID,
                                       sequence: target.cursor.sequence - (damage == "sequence" ? 1 : 0))
            await fixture.setSummary(.init(head: .init(cursor: cursor, batchID: damage == "batch" ? UUID() : target.batchID),
                                           activeExecutionID: nil))
            await #expect(throws: MiraError.self) {
                _ = try await JournalSessionReader(journal: fixture, payloads: EmptyPayloads())
                    .recoverySummary(sessionID: target.cursor.sessionID)
            }
        }
    }

    @Test func nonEmptyStateRoundTripsThroughThePersistedCodec() async throws {
        let fixture = try CheckpointFixture.openedAndRenamed()
        let snapshot = try #require(await fixture.checkpointSnapshot())
        let data = try SessionCodec.encode(snapshot)
        #expect(try SessionCodec.decode(SessionJournalSnapshot.self, from: data) == snapshot)
        #expect(snapshot.state.header != nil)
        #expect(snapshot.state.revision == 1)
        #expect(snapshot.state.title != nil)
    }

    @Test func checkpointRestoresEarlierHeadAndReplaysOnlyTheSuffix() async throws {
        let fixture = try CheckpointFixture.openedAndRenamed()
        let target = try #require(await fixture.targetHead())
        let reader = JournalSessionReader(journal: fixture, payloads: EmptyPayloads())
        let result = try await reader.snapshot(through: target)
        #expect(result.state.revision == 2)
        #expect(await fixture.checkpointCalls == 1)
        #expect(await fixture.cacheCalls == 1)
    }

    @Test func targetBatchIdentityIsValidatedEvenWhenCheckpointHasNoSuffix() async throws {
        let fixture = try CheckpointFixture.openedAndRenamed()
        let actual = try #require(await fixture.checkpointSnapshot()?.head)
        let wrong = SessionJournalHead(cursor: actual.cursor, batchID: UUID())
        let reader = JournalSessionReader(journal: fixture, payloads: EmptyPayloads())
        await #expect(throws: MiraError.self) { _ = try await reader.snapshot(through: wrong) }
    }

    @Test func duplicateHistoricalEventIDInSuffixIsRejected() async throws {
        let fixture = try CheckpointFixture.duplicateSuffixEvent()
        let target = try #require(await fixture.targetHead())
        let reader = JournalSessionReader(journal: fixture, payloads: EmptyPayloads())
        do {
            _ = try await reader.snapshot(through: target)
            Issue.record("Duplicate event identity was accepted")
        } catch let error as MiraError {
            #expect(error.code == .conflict)
            #expect(error.message.contains("identity"))
        }
    }

    @Test func extensionRegistryMismatchDisablesReuseAndUnavailableRequiredExtensionFails() async throws {
        let fixture = try CheckpointFixture.requiredExtension()
        let target = try #require(await fixture.targetHead())
        let reader = JournalSessionReader(journal: fixture, payloads: EmptyPayloads(),
                                           extensionSchemas: ["test.event": [2]])
        await #expect(throws: MiraError.self) { _ = try await reader.snapshot(through: target) }
        #expect(await fixture.checkpointCalls == 1)
        #expect(await fixture.cacheCalls == 0)
    }

    @Test func cancellationDuringCheckpointReadPropagates() async throws {
        let fixture = try CheckpointFixture.openedAndRenamed(gated: true)
        let target = try #require(await fixture.targetHead())
        let reader = JournalSessionReader(journal: fixture, payloads: EmptyPayloads())
        let task = Task { try await reader.snapshot(through: target) }
        await fixture.waitForCheckpoint()
        task.cancel()
        await fixture.releaseCheckpoint()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}

private actor CheckpointFixture: SessionCheckpointJournal {
    nonisolated private let batches: [SessionBatch]
    nonisolated let checkpoint: SessionJournalSnapshot?
    private let expectedSchemas: [String: Set<Int>]
    private let gated: Bool
    private var entered = false
    private var released = false
    private(set) var checkpointCalls = 0
    private(set) var cacheCalls = 0
    private var summary: SessionRecoverySummary?

    private init(batches: [SessionBatch], checkpoint: SessionJournalSnapshot?,
                 expectedSchemas: [String: Set<Int>] = [:], gated: Bool = false) {
        self.batches = batches; self.checkpoint = checkpoint
        self.expectedSchemas = expectedSchemas; self.gated = gated
    }

    static func openedAndRenamed(gated: Bool = false) throws -> CheckpointFixture {
        let id = ConversationID()
        let openID = UUID()
        let title1 = reference(sessionID: id, kind: .title, batchID: openID)
        let open = SessionBatch(id: openID, sessionID: id, expectedSequence: 0,
            events: [.init(id: UUID(), sequence: 1, occurredAt: Date(timeIntervalSince1970: 1),
                fact: .opened(.init(workspaceID: nil, title: title1)))] )
        let renameID = UUID()
        let title2 = reference(sessionID: id, kind: .title, batchID: renameID)
        let rename = SessionBatch(id: renameID, sessionID: id, expectedSequence: 1,
            events: [.init(id: UUID(), sequence: 2, occurredAt: Date(timeIntervalSince1970: 2),
                fact: .renamed(title: title2, revision: 2))])
        var state = SessionState(id: id)
        try state.apply(open)
        let checkpoint = SessionJournalSnapshot(head: .init(cursor: open.cursor, batchID: open.id), state: state)
        return CheckpointFixture(batches: [open, rename], checkpoint: checkpoint, gated: gated)
    }

    static func duplicateSuffixEvent() throws -> CheckpointFixture {
        let base = try openedAndRenamed()
        let first = base.batches[0].events[0]
        let id = base.batches[0].sessionID
        let duplicateID = UUID()
        let duplicate = SessionBatch(id: duplicateID, sessionID: id, expectedSequence: 2,
            events: [.init(id: first.id, sequence: 3, occurredAt: Date(timeIntervalSince1970: 3),
                fact: .renamed(title: reference(sessionID: id, kind: .title, batchID: duplicateID), revision: 3))])
        return CheckpointFixture(batches: base.batches + [duplicate], checkpoint: base.checkpoint)
    }

    static func requiredExtension() throws -> CheckpointFixture {
        let base = try openedAndRenamed()
        let id = base.batches[0].sessionID
        let batchID = UUID()
        let body = reference(sessionID: id, kind: .module, batchID: batchID)
        let event = SessionBatch(id: batchID, sessionID: id, expectedSequence: 2,
            events: [.init(id: UUID(), sequence: 3, occurredAt: Date(timeIntervalSince1970: 3),
                fact: .extensionRecorded(namespace: "test.event", schemaVersion: 1, required: true, body: body))])
        var state = SessionState(id: id)
        try state.apply(base.batches[0])
        try state.apply(base.batches[1])
        try state.apply(event, extensionSchemas: ["test.event": [1]])
        let checkpoint = SessionJournalSnapshot(head: .init(cursor: event.cursor, batchID: event.id), state: state)
        return CheckpointFixture(batches: base.batches + [event], checkpoint: checkpoint,
                                 expectedSchemas: ["test.event": [1]])
    }

    func append(_ batch: SessionBatch) async -> SessionAppendOutcome { .committed(batch.cursor) }
    func reconcile(_ batch: SessionBatch) async -> SessionAppendOutcome { .committed(batch.cursor) }
    func batch(id: UUID, sessionID: ConversationID) async throws -> SessionBatch? {
        batches.first { $0.id == id && $0.sessionID == sessionID }
    }
    func head(sessionID: ConversationID) async throws -> SessionJournalHead {
        let last = batches.last { $0.sessionID == sessionID }
        return .init(cursor: last?.cursor ?? .init(sessionID: sessionID, sequence: 0), batchID: last?.id)
    }
    func read(sessionID: ConversationID, after sequence: Int64, limit: Int) async throws -> [SessionBatch] {
        Array(batches.filter { $0.sessionID == sessionID && $0.expectedSequence >= sequence }.prefix(limit))
    }
    func sessions(after: ConversationID?, limit: Int) async throws -> [ConversationID] { [] }
    func flush() async throws {}
    func close() async throws {}

    func setSummary(_ value: SessionRecoverySummary) { summary = value }
    func recoverySummary(through head: SessionJournalHead, extensionSchemas: [String: Set<Int>]) -> SessionRecoverySummary? { summary }
    func checkpoint(through head: SessionJournalHead,
                    extensionSchemas: [String: Set<Int>]) async throws -> SessionJournalSnapshot? {
        checkpointCalls += 1
        entered = true
        for _ in 0..<10_000 where gated && !released { await Task.yield() }
        guard extensionSchemas == expectedSchemas else { return nil }
        guard let checkpoint, checkpoint.head.cursor.sequence <= head.cursor.sequence else { return nil }
        return checkpoint
    }
    func cache(_ snapshot: SessionJournalSnapshot, extensionSchemas: [String: Set<Int>]) async { cacheCalls += 1 }
    func waitForCheckpoint() async {
        for _ in 0..<10_000 where !entered { await Task.yield() }
    }
    func releaseCheckpoint() { released = true }

    func checkpointSnapshot() -> SessionJournalSnapshot? { checkpoint }
    func targetHead() -> SessionJournalHead? { batches.last.map { .init(cursor: $0.cursor, batchID: $0.id) } }

    private static func reference(sessionID: ConversationID, kind: SessionPayloadKind,
                                  batchID: UUID) -> SessionPayloadReference {
        .init(id: UUID(), sessionID: sessionID, batchID: batchID, retentionGroup: UUID(), kind: kind,
              byteCount: 1, digest: String(repeating: "a", count: 64))
    }
}

private struct EmptyPayloads: SessionPayloadReader {
    func read(_ reference: SessionPayloadReference) async throws -> Data { Data() }
}
