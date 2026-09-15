import Foundation

/// Rebuilds disposable metadata and discards text caches after privacy facts commit. The library owns the adapters;
/// production query workers must be drained before this maintenance-owned replay begins.
public struct SessionPrivacyProjections: Sendable {
    private let journal: any SessionJournal
    private let payloads: any SessionPayloadReader
    private let stores: [any SessionProjectionStore]
    private let searchIndexes: [any SessionSearchIndex]
    private let schemas: [String: Set<Int>]
    public init(
        journal: any SessionJournal, payloads: any SessionPayloadReader,
        stores: [any SessionProjectionStore], searchIndexes: [any SessionSearchIndex] = [], extensionSchemas: [String: Set<Int>] = [:]
    ) throws {
        guard stores.count <= 16, searchIndexes.count <= 16 else {
            throw MiraError(.configuration, "Too many session privacy projections were registered.")
        }
        self.journal = journal
        self.payloads = payloads
        self.stores = stores
        self.searchIndexes = searchIndexes
        self.schemas = extensionSchemas
    }
    public func rebuild(plan: SessionPrivacyPlan) async throws {
        try plan.validate()
        for index in searchIndexes { try await index.clear() }
        for store in stores {
            let coordinator = try SessionProjectionCoordinator(
                journal: journal, projection: store, extensionSchemas: schemas)
            do {
                for change in plan.changes {
                    let head = try await coordinator.rebuild(sessionID: change.batch.sessionID)
                    guard head == SessionJournalHead(cursor: change.batch.cursor, batchID: change.batch.id) else {
                        throw Self.invalid
                    }
                }
            } catch {
                await coordinator.close()
                throw error
            }
            await coordinator.close()
        }
    }
    public func verify(plan: SessionPrivacyPlan) async throws {
        try plan.validate()
        for index in searchIndexes { try await index.verifyEmpty() }
        for store in stores {
            for change in plan.changes {
                guard case .invalidated(let fact) = change.batch.events[0].fact,
                    try await store.head(sessionID: change.batch.sessionID)
                        == SessionJournalHead(cursor: change.batch.cursor, batchID: change.batch.id)
                else { throw Self.invalid }
                let canonical = try await JournalSessionReader(
                    journal: journal, payloads: payloads,
                    extensionSchemas: schemas
                ).snapshot(through: .init(cursor: change.batch.cursor, batchID: change.batch.id))
                let selected = fact.executionIDs
                var expectedExecutions: [ExecutionID: SessionExecutionState] = [:]
                for executionID in selected {
                    guard let execution = canonical.state.executions[executionID],
                        execution.completion != nil,
                        execution.admission.executionID == executionID,
                        execution.completion?.executionID == executionID
                    else { throw Self.invalid }
                    expectedExecutions[executionID] = execution
                }
                var before: Int64?
                var found = Set<ExecutionID>()
                while true {
                    let page = try await store.executions(
                        sessionID: change.batch.sessionID, beforeSequence: before, limit: 128)
                    guard page.count <= 128 else { throw Self.invalid }
                    if page.isEmpty { break }
                    for row in page {
                        guard row.sessionID == change.batch.sessionID, row.sequence > 0,
                            row.sequence < (before ?? change.batch.cursor.sequence)
                        else { throw Self.invalid }
                        before = row.sequence
                        if fact.executionIDs.contains(row.id) {
                            // SQL query timestamps use Unix seconds; compare that exact representation.
                            guard let expected = expectedExecutions[row.id], found.insert(row.id).inserted,
                                row.admission == expected.admission, row.completion == expected.completion,
                                row.sequence == expected.admissionSequence,
                                row.admittedAt.timeIntervalSince1970 == expected.admittedAt.timeIntervalSince1970,
                                row.isExcludedFromContext == canonical.state.excludedExecutionIDs.contains(row.id),
                                row.isExcludedFromContext
                            else { throw Self.invalid }
                        }
                    }
                }
                guard found == fact.executionIDs else { throw Self.invalid }
                var expectedMessages:
                    [MessageID: (
                        executionID: ExecutionID, role: SessionMessageRole, body: SessionPayloadReference?,
                        thinking: SessionPayloadReference?, excluded: Bool
                    )] = [:]
                let affectedUsers = Set(expectedExecutions.values.map { $0.admission.userMessageID })
                for execution in canonical.state.executions.values
                where affectedUsers.contains(execution.admission.userMessageID) {
                    if let body = execution.admission.userBody {
                        expectedMessages[execution.admission.userMessageID] = (
                            execution.admission.executionID, .user, body, nil,
                            canonical.state.excludedExecutionIDs.contains(execution.admission.executionID)
                        )
                    }
                }
                for execution in expectedExecutions.values {
                    if let completion = execution.completion, let id = completion.assistantMessageID {
                        expectedMessages[id] = (
                            execution.admission.executionID, .assistant, completion.answer, completion.visibleThinking,
                            canonical.state.excludedExecutionIDs.contains(execution.admission.executionID)
                        )
                    }
                }
                var actualMessages: [MessageID: SessionMessageSummary] = [:]
                before = nil
                while true {
                    let page = try await store.messages(
                        sessionID: change.batch.sessionID, beforeSequence: before, limit: 128)
                    guard page.count <= 128 else { throw Self.invalid }
                    if page.isEmpty { break }
                    for row in page {
                        guard row.sessionID == change.batch.sessionID, row.sequence > 0,
                            row.sequence < (before ?? change.batch.cursor.sequence)
                        else { throw Self.invalid }
                        before = row.sequence
                        if selected.contains(row.executionID) || expectedMessages[row.id] != nil {
                            guard expectedMessages[row.id] != nil,
                                actualMessages.updateValue(row, forKey: row.id) == nil
                            else { throw Self.invalid }
                        }
                    }
                }
                guard Set(actualMessages.keys) == Set(expectedMessages.keys) else { throw Self.invalid }
                for (id, expected) in expectedMessages {
                    guard let actual = actualMessages[id], actual.executionID == expected.executionID,
                        actual.role == expected.role, actual.body == expected.body,
                        actual.thinking == expected.thinking,
                        actual.isExcludedFromContext == expected.excluded,
                        actual.bodyInvalidated
                            == (expected.body.map {
                                canonical.state.invalidatedRetentionGroups.contains($0.retentionGroup)
                            } ?? false),
                        actual.thinkingInvalidated
                            == (expected.thinking.map {
                                canonical.state.invalidatedRetentionGroups.contains($0.retentionGroup)
                            } ?? false)
                    else { throw Self.invalid }
                }
            }
        }
    }
    private static var invalid: MiraError {
        .init(.storage, "The session privacy projection does not match the journal.")
    }
}
