import Foundation
import Testing
@testable import MiraCore

@Suite("Session draft reader")
struct SessionDraftReaderTests {
    @Test func reconstructsIndependentInterleavedComponents() async throws {
        let fixture = try DraftFixture()
        let reader = SessionDraftReader(journal: fixture.journal, payloads: fixture.payloads)
        let result = try await reader.read(state: fixture.state, executionID: fixture.executionID)
        #expect(result[.answer] == Data("你好 answer".utf8)) // i18n-fixture: Draft patches preserve multibyte UTF-8 text.
        #expect(result[.thinking] == Data("thinking".utf8))
        #expect(result[.transcript] == Data("transcript".utf8))
    }

    @Test func unknownExecutionThrows() async throws {
        let fixture = try DraftFixture()
        let reader = SessionDraftReader(journal: fixture.journal, payloads: fixture.payloads)
        await #expect(throws: MiraError.self) { try await reader.read(state: fixture.state, executionID: ExecutionID()) }
    }

    @Test func terminalAndExcludedExecutionsDoNotReadPayloads() async throws {
        let fixture = try DraftFixture()
        fixture.payloads.values.removeAll()
        for terminal in [true, false] {
            var state = fixture.state
            let facts: [SessionFact]
            if terminal {
                facts = [.phaseChanged(executionID: fixture.executionID, phase: .cancelling),
                         .attemptResolved(.init(attemptID: fixture.attemptID, status: .interrupted)),
                         .finished(.init(executionID: fixture.executionID, status: .interrupted))]
            } else {
                let hidden = Set(state.references.values.filter { [.executionPlan, .request, .draft].contains($0.kind) }.map(\.retentionGroup))
                facts = [.invalidated(.init(operationID: UUID(), executionIDs: [fixture.executionID], retentionGroups: hidden,
                                            authorizationEpoch: 1, reason: .forgotten))]
            }
            try state.apply(.init(id: UUID(), sessionID: state.id, expectedSequence: state.sequence,
                events: facts.enumerated().map { .init(sequence: state.sequence + Int64($0.offset) + 1, occurredAt: Date(), fact: $0.element) }))
            let result = try await SessionDraftReader(journal: fixture.journal, payloads: fixture.payloads).read(state: state, executionID: fixture.executionID)
            #expect(result.isEmpty)
        }
    }

    @Test func pagesAdvanceAndFactsAfterCapturedSequenceAreIgnored() async throws {
        let fixture = try DraftFixture(); let extra = SessionBatch(id: UUID(), sessionID: fixture.state.id, expectedSequence: fixture.state.sequence, events: [SessionEvent(sequence: fixture.state.sequence + 2, occurredAt: Date(), fact: .archived(revision: 99))])
        for journal in [MemoryJournal(batches: fixture.journal.batches + [extra]), PagedJournal(batches: fixture.journal.batches + [extra])] {
            let reader = SessionDraftReader(journal: journal, payloads: fixture.payloads)
            #expect(try await reader.read(state: fixture.state, executionID: fixture.executionID)[.answer] == fixture.answerData)
        }
    }

    @Test func missingInvalidatedPayloadFailsClosedAndNonProgressCursorFails() async throws {
        let fixture = try DraftFixture(); fixture.payloads.values.removeValue(forKey: fixture.answerReference.id)
        let reader = SessionDraftReader(journal: fixture.journal, payloads: fixture.payloads)
        await #expect(throws: MiraError.self) { try await reader.read(state: fixture.state, executionID: fixture.executionID) }
        let stalled = SessionDraftReader(journal: NonProgressJournal(batches: fixture.journal.batches), payloads: fixture.payloads)
        await #expect(throws: MiraError.self) { try await stalled.read(state: fixture.state, executionID: fixture.executionID) }
    }

    @Test func malformedBatchEnvelopeFailsBeforeDraftReconstruction() async throws {
        let fixture = try DraftFixture(); let original = try #require(fixture.journal.batches.last)
        let malformed = SessionBatch(id: original.id, sessionID: original.sessionID, expectedSequence: original.expectedSequence, events: [SessionEvent(sequence: original.expectedSequence + 2, occurredAt: Date(), fact: original.events[0].fact)])
        let reader = SessionDraftReader(journal: MemoryJournal(batches: Array(fixture.journal.batches.dropLast()) + [malformed]), payloads: fixture.payloads)
        await #expect(throws: MiraError.self) { try await reader.read(state: fixture.state, executionID: fixture.executionID) }
    }

    @Test func stalePatchChainAndInvalidatedPayloadFailClosed() async throws {
        let fixture = try DraftFixture()
        let stale = SessionDraftCheckpoint(executionID: fixture.executionID, attemptID: fixture.attemptID, part: .answer, baseSequence: 999, prefixByteCount: 0, suffixByteCount: 0, replacement: fixture.answerReference, resultByteCount: fixture.answerData.count)
        let original = try #require(fixture.journal.batches.last)
        let events = original.events.enumerated().map { index, event in index == 0 ? SessionEvent(id: event.id, sequence: event.sequence, occurredAt: event.occurredAt, fact: .draftCheckpoint(stale)) : event }
        let badBatch = SessionBatch(id: original.id, sessionID: original.sessionID, expectedSequence: original.expectedSequence, events: events)
        let journal = MemoryJournal(batches: Array(fixture.journal.batches.dropLast()) + [badBatch]); let reader = SessionDraftReader(journal: journal, payloads: fixture.payloads)
        await #expect(throws: MiraError.self) { try await reader.read(state: fixture.state, executionID: fixture.executionID) }
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

private final class PagedJournal: MemoryJournal, @unchecked Sendable {
    override func read(sessionID: ConversationID, after sequence: Int64, limit: Int) async throws -> [SessionBatch] { Array(try await super.read(sessionID: sessionID, after: sequence, limit: 1)) }
}

private final class NonProgressJournal: MemoryJournal, @unchecked Sendable {
    override func read(sessionID: ConversationID, after sequence: Int64, limit: Int) async throws -> [SessionBatch] { [batches[0]] }
}

private final class MemoryPayloads: SessionPayloadStore, @unchecked Sendable {
    var values: [UUID: Data] = [:]
    func stage(_ data: Data, sessionID: ConversationID, batchID: UUID, retentionGroup: UUID, kind: SessionPayloadKind) async throws -> SessionPayloadReference { fatalError() }
    func read(_ reference: SessionPayloadReference) async throws -> Data { guard let value = values[reference.id] else { throw MiraError(.storage, "missing") }; return value }
    func purge(sessionID: ConversationID, retentionGroups: Set<UUID>) async throws {}
}

private struct DraftFixture {
    let state: SessionState
    let journal: MemoryJournal
    let payloads: MemoryPayloads
    let executionID: ExecutionID
    let attemptID: UUID
    let answerReference: SessionPayloadReference
    let answerData = Data("你好 answer".utf8) // i18n-fixture: Draft patches preserve multibyte UTF-8 text.

    init() throws {
        let sid = ConversationID(); let executionID = ExecutionID(); self.executionID = executionID; let answerData = Data("你好 answer".utf8) // i18n-fixture: Draft patches preserve multibyte UTF-8 text.
        let payloads = MemoryPayloads(); self.payloads = payloads
        let group = UUID()
        func ref(_ kind: SessionPayloadKind, _ batch: UUID, _ count: Int = 1, _ retention: UUID = UUID()) -> SessionPayloadReference { SessionPayloadReference(id: UUID(), sessionID: sid, batchID: batch, retentionGroup: retention, kind: kind, byteCount: count, digest: String(repeating: "0", count: 64)) }
        let openID = UUID(); let title = ref(.title, openID); payloads.values[title.id] = Data("Title".utf8)
        let routeBatch = UUID(); let route = ref(.executionPlan, routeBatch); payloads.values[route.id] = Data("route".utf8)
        let admitBatch = UUID(); let body = ref(.userText, admitBatch); payloads.values[body.id] = Data("hello".utf8)
        let admittedRoute = SessionPayloadReference(id: route.id, sessionID: sid, batchID: admitBatch, retentionGroup: route.retentionGroup, kind: route.kind, byteCount: route.byteCount, digest: route.digest); payloads.values[admittedRoute.id] = Data("route".utf8)
        let requestBatch = UUID(); let request = ref(.request, requestBatch); payloads.values[request.id] = Data("request".utf8)
        let answerBatch = UUID(); let answer = ref(.draft, answerBatch, answerData.count, group); payloads.values[answer.id] = answerData
        let thinkingBatch = answerBatch; let thinkingData = Data("thinking".utf8); let thinking = ref(.draft, thinkingBatch, thinkingData.count, group); payloads.values[thinking.id] = thinkingData
        let transcriptData = Data("transcript".utf8); let transcript = ref(.draft, thinkingBatch, transcriptData.count, group); payloads.values[transcript.id] = transcriptData
        var state = SessionState(id: sid); var batches: [SessionBatch] = []
        let events: [(UUID, SessionFact)] = [
            (openID, .opened(SessionHeader(workspaceID: nil, title: title))),
            (admitBatch, .admitted(SessionAdmission(executionID: executionID, userMessageID: MessageID(), userBody: body, plan: admittedRoute, hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC"))),
            (UUID(), .phaseChanged(executionID: executionID, phase: .preparing)),
            (requestBatch, .attemptStarted(SessionAttempt(id: UUID(), executionID: executionID, stepID: UUID(), stepIndex: 1, attemptIndex: 1, request: request)))
        ]
        var sequence: Int64 = 0
        for (id, fact) in events { let b = SessionBatch(id: id, sessionID: sid, expectedSequence: sequence, events: [SessionEvent(sequence: sequence + 1, occurredAt: Date(), fact: fact)]); try state.apply(b); batches.append(b); sequence += 1 }
        let attemptID = try #require(state.executions[executionID]?.attemptIDs.first); self.attemptID = attemptID
        let answerCheckpoint = SessionDraftCheckpoint(executionID: executionID, attemptID: attemptID, part: .answer, baseSequence: nil, prefixByteCount: 0, suffixByteCount: 0, replacement: answer, resultByteCount: answerData.count)
        let thinkingCheckpoint = SessionDraftCheckpoint(executionID: executionID, attemptID: attemptID, part: .thinking, baseSequence: nil, prefixByteCount: 0, suffixByteCount: 0, replacement: thinking, resultByteCount: thinkingData.count)
        let transcriptCheckpoint = SessionDraftCheckpoint(executionID: executionID, attemptID: attemptID, part: .transcript, baseSequence: nil, prefixByteCount: 0, suffixByteCount: 0, replacement: transcript, resultByteCount: transcriptData.count)
        let draftBatch = SessionBatch(id: answerBatch, sessionID: sid, expectedSequence: sequence, events: [SessionEvent(sequence: sequence + 1, occurredAt: Date(), fact: .draftCheckpoint(answerCheckpoint)), SessionEvent(sequence: sequence + 2, occurredAt: Date(), fact: .draftCheckpoint(thinkingCheckpoint)), SessionEvent(sequence: sequence + 3, occurredAt: Date(), fact: .draftCheckpoint(transcriptCheckpoint))]); try state.apply(draftBatch); batches.append(draftBatch)
        _ = attemptID; self.answerReference = answer; self.state = state; self.journal = MemoryJournal(batches: batches)
        _ = thinkingBatch
    }
}
