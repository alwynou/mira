import Foundation
import Testing
@testable import MiraCore

@Suite("Session draft reader")
struct SessionDraftReaderTests {
    @Test func readsOrderedLatestSnapshotWithoutJournalTraversal() async throws {
        let fixture = try DraftFixture()
        let result = try await SessionDraftReader(journal: fixture.journal, payloads: fixture.payloads)
            .read(state: fixture.state, executionID: fixture.executionID)
        #expect(result[.answer] == Data("answer".utf8))
        #expect(result[.thinking] == Data("firstlast".utf8))
        let transcript = try SessionCodec.decode(SessionActiveDraft.self, from: #require(result[.transcript]))
        #expect(transcript.blocks.map(\.id) == ["think-1", "text", "think-2"])
        #expect(fixture.state.sequence == 4)
    }

    @Test func staleOwnerCannotSupplyVisibleDraft() async throws {
        let fixture = try DraftFixture()
        let original = try #require(fixture.payloads.draft)
        fixture.payloads.draft = .init(request: original.request, executionID: original.executionID,
            attemptID: UUID(), authorizationEpoch: 0, revision: 2, blocks: original.blocks)
        let result = try await SessionDraftReader(journal: fixture.journal, payloads: fixture.payloads)
            .read(state: fixture.state, executionID: fixture.executionID)
        #expect(result[.answer] == Data())
        #expect(result[.transcript] == nil)
    }

    @Test func terminalAndExcludedExecutionsCannotReadSidecar() async throws {
        let fixture = try DraftFixture()
        for terminal in [true, false] {
            var state = fixture.state
            let facts: [SessionFact]
            if terminal {
                facts = [.phaseChanged(executionID: fixture.executionID, phase: .cancelling),
                         .attemptResolved(.init(attemptID: fixture.attemptID, status: .interrupted)),
                         .finished(.init(executionID: fixture.executionID, status: .interrupted))]
            } else {
                let hidden = Set(state.references.values.filter { [.executionPlan, .request].contains($0.kind) }.map(\.retentionGroup))
                facts = [.invalidated(.init(operationID: UUID(), executionIDs: [fixture.executionID], retentionGroups: hidden,
                                            authorizationEpoch: 1, reason: .forgotten))]
            }
            try state.apply(.init(id: UUID(), sessionID: state.id, expectedSequence: state.sequence,
                events: facts.enumerated().map { .init(sequence: state.sequence + Int64($0.offset) + 1, occurredAt: Date(), fact: $0.element) }))
            let result = try await SessionDraftReader(journal: fixture.journal, payloads: fixture.payloads)
                .read(state: state, executionID: fixture.executionID)
            #expect(result.isEmpty)
        }
    }
}

private class MemoryJournal: SessionJournal, @unchecked Sendable {
    let batches: [SessionBatch]
    init(batches: [SessionBatch]) { self.batches = batches }
    func append(_ batch: SessionBatch) async -> SessionAppendOutcome { .notCommitted(.init(.unsupported, "test")) }
    func reconcile(_ batch: SessionBatch) async -> SessionAppendOutcome { .notCommitted(.init(.unsupported, "test")) }
    func batch(id: UUID, sessionID: ConversationID) async throws -> SessionBatch? { batches.first { $0.id == id && $0.sessionID == sessionID } }
    func head(sessionID: ConversationID) async throws -> SessionJournalHead {
        guard let batch = batches.filter({ $0.sessionID == sessionID }).max(by: { $0.cursor.sequence < $1.cursor.sequence }) else {
            return .init(cursor: .init(sessionID: sessionID, sequence: 0), batchID: nil)
        }
        return .init(cursor: batch.cursor, batchID: batch.id)
    }
    func read(sessionID: ConversationID, after sequence: Int64, limit: Int) async throws -> [SessionBatch] { Array(batches.filter { $0.sessionID == sessionID && $0.cursor.sequence > sequence }.prefix(limit)) }
    func sessions(after: ConversationID?, limit: Int) async throws -> [ConversationID] { [batches[0].sessionID] }
    func flush() async throws {}
    func close() async throws {}
}


private final class MemoryPayloads: SessionPayloadReader, @unchecked Sendable {
    var draft: SessionActiveDraft?
    func activeDraft(sessionID: ConversationID) async throws -> SessionActiveDraft? { draft }
    func read(_ reference: SessionPayloadReference) async throws -> Data {
        throw MiraError(.storage, "Unexpected payload read.")
    }
}

private struct DraftFixture {
    let state: SessionState
    let journal: MemoryJournal
    let payloads: MemoryPayloads
    let executionID = ExecutionID()
    let attemptID = UUID()

    init() throws {
        let sid = ConversationID()
        func ref(_ kind: SessionPayloadKind, _ batch: UUID) -> SessionPayloadReference {
            .init(id: UUID(), sessionID: sid, batchID: batch, retentionGroup: UUID(),
                kind: kind, byteCount: 1, digest: String(repeating: "0", count: 64))
        }
        let open = UUID(), admission = UUID(), requestBatch = UUID()
        let request = ref(.request, requestBatch)
        var state = SessionState(id: sid)
        let facts: [(UUID, SessionFact)] = [
            (open, .opened(.init(workspaceID: nil, title: ref(.title, open)))),
            (admission, .admitted(.init(executionID: executionID, userMessageID: MessageID(),
                userBody: ref(.userText, admission), plan: ref(.executionPlan, admission), hasModelRoute: true,
                authorizationEpoch: 0, timeZoneIdentifier: "UTC"))),
            (UUID(), .phaseChanged(executionID: executionID, phase: .preparing)),
            (requestBatch, .attemptStarted(.init(id: attemptID, executionID: executionID,
                stepID: UUID(), stepIndex: 1, attemptIndex: 1, request: request)))
        ]
        for (id, fact) in facts {
            try state.apply(.init(id: id, sessionID: sid, expectedSequence: state.sequence,
                events: [.init(sequence: state.sequence + 1, occurredAt: Date(), fact: fact)]))
        }
        payloads = MemoryPayloads()
        payloads.draft = .init(request: request, executionID: executionID, attemptID: attemptID,
            authorizationEpoch: 0, revision: 1, blocks: [
                .init(id: "think-1", content: .thinking("first")),
                .init(id: "text", content: .text("answer")),
                .init(id: "think-2", content: .thinking("last"))])
        self.state = state
        journal = MemoryJournal(batches: [])
    }
}
