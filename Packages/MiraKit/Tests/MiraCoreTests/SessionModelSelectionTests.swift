import Foundation
import Testing
@testable import MiraCore

@Suite("Journal-authoritative session model selection")
struct SessionModelSelectionTests {
    @Test func openingDefaultsToInheritanceAndSelectionRoundTripsThroughJournal() throws {
        var state = SessionState(id: ConversationID())
        let openingBatchID = UUID()
        let title = Self.reference(sessionID: state.id, batchID: openingBatchID, kind: .title)
        try state.apply(Self.batch(state: state, id: openingBatchID,
            facts: [.opened(.init(workspaceID: nil, title: title))]))
        #expect(state.modelSelection == .inherit)
        #expect(state.modelSelectionRevision == 0)

        let selection = Self.selected()
        let changeBatchID = UUID()
        try state.apply(Self.batch(state: state, id: changeBatchID,
            facts: [.modelSelectionChanged(selection: selection, expectedRevision: 0)]))
        let reopened = try Self.reduce(state: SessionState(id: state.id), batches: [
            Self.batch(state: SessionState(id: state.id), id: openingBatchID,
                  facts: [.opened(.init(workspaceID: nil, title: title))]),
            // The second batch is constructed against the committed prefix.
            Self.batch(state: Self.stateAfterOpen(id: state.id, title: title), id: changeBatchID,
                  facts: [.modelSelectionChanged(selection: selection, expectedRevision: 0)])
        ])
        #expect(reopened.modelSelection == selection)
        #expect(reopened.modelSelectionRevision == 1)
    }

    @Test func removedConfigurationDoesNotTurnSelectionIntoInheritance() throws {
        var state = SessionState(id: ConversationID())
        let openID = UUID()
        let title = Self.reference(sessionID: state.id, batchID: openID, kind: .title)
        try state.apply(Self.batch(state: state, id: openID,
            facts: [.opened(.init(workspaceID: nil, title: title))]))
        let selected = Self.selected(routeID: RouteID(), modelConfigurationID: ModelDescriptorID())
        try state.apply(Self.batch(state: state, id: UUID(),
            facts: [.modelSelectionChanged(selection: selected, expectedRevision: 0)]))
        // Configuration deletion is outside the journal. The selected intent
        // remains exact and therefore resolves as unavailable, never inherit.
        #expect(state.modelSelection == selected)
        #expect(state.modelSelection != .inherit)
    }

    @Test func stableCommandRetryDoesNotApplySelectionTwice() async throws {
        let journal = InMemorySelectionJournal()
        var state = SessionState(id: ConversationID())
        let openID = UUID()
        let title = Self.reference(sessionID: state.id, batchID: openID, kind: .title)
        let opening = Self.batch(state: state, id: openID,
            facts: [.opened(.init(workspaceID: nil, title: title))])
        try state.apply(opening)
        #expect(await journal.append(opening) == .committed(opening.cursor))
        let commandID = UUID()
        let selection = Self.selected()
        let change = Self.batch(state: state, id: commandID,
            facts: [.modelSelectionChanged(selection: selection, expectedRevision: 0)])
        #expect(await journal.append(change) == .committed(change.cursor))
        #expect(await journal.append(change) == .committed(change.cursor))
        #expect(try await journal.batch(id: commandID, sessionID: state.id) == change)
        #expect(try await JournalSessionReader(journal: journal, payloads: journal).snapshot(sessionID: state.id).state.modelSelection == selection)
        #expect(try await journal.head(sessionID: state.id) == .init(cursor: change.cursor, batchID: commandID))
    }

    @Test func admissionRevisionGuardRejectsConcurrentSelectionChange() throws {
        var state = SessionState(id: ConversationID())
        let openID = UUID()
        let title = Self.reference(sessionID: state.id, batchID: openID, kind: .title)
        try state.apply(Self.batch(state: state, id: openID,
            facts: [.opened(.init(workspaceID: nil, title: title))]))
        let selection = Self.selected()
        try state.apply(Self.batch(state: state, id: UUID(),
            facts: [.modelSelectionChanged(selection: selection, expectedRevision: 0)]))
        let admissionID = UUID()
        let admission = SessionAdmission(executionID: ExecutionID(), userMessageID: MessageID(),
            userBody: Self.reference(sessionID: state.id, batchID: admissionID, kind: .userText),
            plan: Self.reference(sessionID: state.id, batchID: admissionID, kind: .executionPlan),
            hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC",
            modelSelectionRevision: 0)
        let before = state
        #expect(throws: MiraError.self) {
            try state.apply(Self.batch(state: state, id: admissionID, facts: [.admitted(admission)]))
        }
        #expect(state == before)
    }

    @Test func firstAdmissionCanCommitOpeningSelectionAndMessageAtomically() throws {
        var state = SessionState(id: ConversationID())
        let batchID = UUID()
        let title = Self.reference(sessionID: state.id, batchID: batchID, kind: .title)
        let body = Self.reference(sessionID: state.id, batchID: batchID, kind: .userText)
        let plan = Self.reference(sessionID: state.id, batchID: batchID, kind: .executionPlan)
        let admission = SessionAdmission(executionID: ExecutionID(), userMessageID: MessageID(),
            userBody: body, plan: plan, hasModelRoute: true, authorizationEpoch: 0,
            timeZoneIdentifier: "UTC", modelSelectionRevision: 1)
        let selection = Self.selected()
        try state.apply(Self.batch(state: state, id: batchID, facts: [
            .opened(.init(workspaceID: nil, title: title)),
            .modelSelectionChanged(selection: selection, expectedRevision: 0),
            .admitted(admission)
        ]))
        #expect(state.modelSelection == selection)
        #expect(state.modelSelectionRevision == 1)
        #expect(state.activeExecutionID == admission.executionID)
    }

    private static func selected(routeID: RouteID = RouteID(), modelConfigurationID: ModelDescriptorID = ModelDescriptorID()) -> AgentSessionModelSelection {
        .selected(.init(routeID: routeID,
                        model: .init(connectionID: ConnectionID(), modelID: "synthetic-model"),
                        modelConfigurationID: modelConfigurationID))
    }

    private static func reference(sessionID: ConversationID, batchID: UUID, kind: SessionPayloadKind) -> SessionPayloadReference {
        .init(id: UUID(), sessionID: sessionID, batchID: batchID, retentionGroup: UUID(), kind: kind,
              byteCount: 1, digest: String(repeating: "a", count: 64))
    }

    private static func batch(state: SessionState, id: UUID, facts: [SessionFact]) -> SessionBatch {
        .init(id: id, sessionID: state.id, expectedSequence: state.sequence,
              events: facts.enumerated().map { .init(sequence: state.sequence + Int64($0.offset + 1), occurredAt: Date(timeIntervalSince1970: 1), fact: $0.element) })
    }

    private static func stateAfterOpen(id: ConversationID, title: SessionPayloadReference) -> SessionState {
        var state = SessionState(id: id)
        let opening = Self.batch(state: state, id: title.batchID,
            facts: [.opened(.init(workspaceID: nil, title: title))])
        try! state.apply(opening)
        return state
    }

    private static func reduce(state initial: SessionState, batches: [SessionBatch]) throws -> SessionState {
        var state = initial
        for batch in batches { try state.apply(batch) }
        return state
    }
}

private actor InMemorySelectionJournal: SessionJournal {
    private var batches: [UUID: SessionBatch] = [:]
    func append(_ batch: SessionBatch) async -> SessionAppendOutcome {
        if let old = batches[batch.id] { return old == batch ? .committed(old.cursor) : .notCommitted(.init(.conflict, "Conflicting batch.")) }
        batches[batch.id] = batch
        return .committed(batch.cursor)
    }
    func reconcile(_ batch: SessionBatch) async -> SessionAppendOutcome { await append(batch) }
    func batch(id: UUID, sessionID: ConversationID) async throws -> SessionBatch? { batches[id].flatMap { $0.sessionID == sessionID ? $0 : nil } }
    func head(sessionID: ConversationID) async throws -> SessionJournalHead {
        let values = batches.values.filter { $0.sessionID == sessionID }.sorted { $0.cursor.sequence < $1.cursor.sequence }
        guard let last = values.last else { return .init(cursor: .init(sessionID: sessionID, sequence: 0), batchID: nil) }
        return .init(cursor: last.cursor, batchID: last.id)
    }
    func read(sessionID: ConversationID, after sequence: Int64, limit: Int) async throws -> [SessionBatch] {
        Array(batches.values.filter { $0.sessionID == sessionID && $0.cursor.sequence > sequence }.sorted { $0.expectedSequence < $1.expectedSequence }.prefix(limit))
    }
    func sessions(after: ConversationID?, limit: Int) async throws -> [ConversationID] { [] }
    func flush() async throws {}
    func close() async throws {}
}

extension InMemorySelectionJournal: SessionPayloadReader {
    func read(_ reference: SessionPayloadReference) async throws -> Data {
        Data(repeating: 97, count: reference.byteCount)
    }
}
