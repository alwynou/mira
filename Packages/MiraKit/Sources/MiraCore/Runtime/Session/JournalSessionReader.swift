import Foundation

public struct SessionJournalSnapshot: Sendable, Equatable, Codable {
    public let head: SessionJournalHead
    public let state: SessionState
}

/// Locates immutable user evidence. This is provenance, never a permission to commit an effect.
public struct SessionEvidenceReference: Codable, Sendable, Equatable {
    public let sessionID: ConversationID
    public let originalExecutionID: ExecutionID
    public let userMessageID: MessageID
    public let admissionEventID: UUID
    public let admissionSequence: Int64
    public let body: SessionPayloadReference

    public init(sessionID: ConversationID, originalExecutionID: ExecutionID, userMessageID: MessageID,
                admissionEventID: UUID, admissionSequence: Int64, body: SessionPayloadReference) {
        self.sessionID = sessionID; self.originalExecutionID = originalExecutionID
        self.userMessageID = userMessageID; self.admissionEventID = admissionEventID
        self.admissionSequence = admissionSequence; self.body = body
    }

    public func validate() throws {
        try body.validate()
        guard admissionSequence > 0, body.sessionID == sessionID, body.kind == .userText else {
            throw MiraError(.invalidInput, "The session evidence reference is invalid.")
        }
    }
}

public struct SessionUserEvidence: Sendable, Equatable {
    public let reference: SessionEvidenceReference
    public let workspaceID: WorkspaceID?
    public let admittedAt: Date
    public let timeZoneIdentifier: String
    public let text: String
    public let observedHead: SessionJournalHead
    public let sessionAuthorizationEpoch: UInt64
}

/// Current journal metadata for a historical exchange. It does not grant workspace or remote-use permission.
/// Body reads remain subject to retention and library maintenance; this value does not pin payload files.
public struct SessionExecutionSourceEvidence: Sendable, Equatable {
    public let source: AgentSourceReference
    public let originalUser: SessionEvidenceReference
    public let workspaceID: WorkspaceID?
    /// Present for successful replayable executions; absent for an incomplete
    /// cancelled/interrupted execution whose source is only its user evidence.
    public let replay: SessionPayloadReference?
    public let observedHead: SessionJournalHead
    public let sessionAuthorizationEpoch: UInt64
}

/// Provenance for a completed visible reply. The route and workspace are the
/// frozen request identity that produced the recorded domain sources; callers
/// still ask each domain authority whether those sources remain usable.
public struct SessionRecordedContextEvidence: Sendable, Equatable {
    public let workspaceID: WorkspaceID?
    public let route: AgentModelRoute
    public let sources: [AgentSourceReference]

    public init(workspaceID: WorkspaceID?, route: AgentModelRoute, sources: [AgentSourceReference]) {
        self.workspaceID = workspaceID; self.route = route; self.sources = sources
    }
}

/// Reads a fixed acknowledged prefix through the authority, independently of every query projection.
public struct JournalSessionReader: Sendable {
    private let journal: any SessionJournal
    private let payloads: any SessionPayloadReader
    private let extensionSchemas: [String: Set<Int>]

    public init(journal: any SessionJournal, payloads: any SessionPayloadReader,
                extensionSchemas: [String: Set<Int>] = [:]) {
        self.journal = journal; self.payloads = payloads; self.extensionSchemas = extensionSchemas
    }

    public func snapshot(sessionID: ConversationID) async throws -> SessionJournalSnapshot {
        try await snapshot(through: journal.head(sessionID: sessionID))
    }

    public func recoverySummary(sessionID: ConversationID) async throws -> SessionRecoverySummary {
        try Task.checkCancellation()
        let head = try await journal.head(sessionID: sessionID)
        try head.validate()
        guard head.cursor.sessionID == sessionID else { throw Self.invalidPrefix }
        if let checkpoints = journal as? any SessionCheckpointJournal,
           let summary = try await checkpoints.recoverySummary(through: head, extensionSchemas: extensionSchemas) {
            try Task.checkCancellation()
            guard summary.head == head,
                  head.cursor.sequence > 0 || summary.activeExecutionID == nil else { throw Self.invalidPrefix }
            try await validateTargetBoundary(head)
            try Task.checkCancellation()
            return summary
        }
        let snapshot = try await snapshot(through: head)
        return .init(head: snapshot.head, activeExecutionID: snapshot.state.activeExecutionID)
    }

    public func snapshot(through head: SessionJournalHead) async throws -> SessionJournalSnapshot {
        try Task.checkCancellation()
        try head.validate()
        var state: SessionState
        var reusedCheckpoint = false
        var reducedSuffix = false
        if let checkpointJournal = journal as? any SessionCheckpointJournal {
            if let checkpoint = try await checkpointJournal.checkpoint(through: head,
                                                                       extensionSchemas: extensionSchemas) {
                try Task.checkCancellation()
                try await validateCheckpoint(checkpoint, through: head)
                state = checkpoint.state
                reusedCheckpoint = true
            } else {
                state = SessionState(id: head.cursor.sessionID)
            }
        } else {
            state = SessionState(id: head.cursor.sessionID)
        }
        while state.sequence < head.cursor.sequence {
            try Task.checkCancellation()
            let page = try await journal.read(sessionID: state.id, after: state.sequence,
                                              limit: SessionFormatLimits.maximumReadBatches)
            guard !page.isEmpty, page.count <= SessionFormatLimits.maximumReadBatches else { throw Self.invalidPrefix }
            for batch in page {
                guard batch.cursor.sequence <= head.cursor.sequence else { throw Self.invalidPrefix }
                try state.apply(batch, extensionSchemas: extensionSchemas)
                reducedSuffix = true
                if state.sequence == head.cursor.sequence {
                    guard batch.id == head.batchID else { throw Self.invalidPrefix }
                    break
                }
            }
        }
        try Task.checkCancellation()
        guard state.id == head.cursor.sessionID,
              state.sequence == head.cursor.sequence else { throw Self.invalidPrefix }
        // Always validate the requested boundary, including a checkpoint hit
        // with no suffix to reduce.
        try await validateTargetBoundary(head)
        let snapshot = SessionJournalSnapshot(head: head, state: state)
        if !reusedCheckpoint || reducedSuffix {
            if let checkpointJournal = journal as? any SessionCheckpointJournal {
                try Task.checkCancellation()
                await checkpointJournal.cache(snapshot, extensionSchemas: extensionSchemas)
                try Task.checkCancellation()
            }
        }
        return snapshot
    }

    private func validateCheckpoint(_ snapshot: SessionJournalSnapshot,
                                    through target: SessionJournalHead) async throws {
        try snapshot.head.validate()
        guard snapshot.state.id == target.cursor.sessionID,
              snapshot.head.cursor.sessionID == target.cursor.sessionID,
              snapshot.head.cursor.sequence <= target.cursor.sequence,
              snapshot.head.cursor.sequence == snapshot.state.sequence else {
            throw MiraError(.storage, "The session checkpoint is not aligned to its journal prefix.")
        }
        if snapshot.head.cursor.sequence == 0 {
            guard snapshot.head.batchID == nil, snapshot.state == SessionState(id: target.cursor.sessionID) else {
                throw MiraError(.storage, "The empty session checkpoint contains invalid state.")
            }
        } else {
            guard snapshot.head.batchID != nil else {
                throw MiraError(.storage, "The session checkpoint is missing its batch identity.")
            }
            guard let batchID = snapshot.head.batchID,
                  let batch = try await journal.batch(id: batchID, sessionID: snapshot.head.cursor.sessionID),
                  batch.cursor == snapshot.head.cursor else {
                throw Self.invalidPrefix
            }
        }
    }

    private func validateTargetBoundary(_ head: SessionJournalHead) async throws {
        if head.cursor.sequence == 0 { return }
        guard let batchID = head.batchID,
              let batch = try await journal.batch(id: batchID, sessionID: head.cursor.sessionID),
              batch.cursor == head.cursor else {
            throw Self.invalidPrefix
        }
    }

    /// A durable consumer cursor must end at a complete batch, never inside one.
    public func snapshot(through cursor: SessionCursor) async throws -> SessionJournalSnapshot {
        guard cursor.sequence >= 0 else { throw Self.invalidPrefix }
        if cursor.sequence == 0 {
            return try await snapshot(through: SessionJournalHead(cursor: cursor, batchID: nil))
        }
        let page = try await journal.read(sessionID: cursor.sessionID, after: cursor.sequence - 1, limit: 1)
        guard page.count == 1, let batch = page.first, batch.cursor == cursor else { throw Self.invalidPrefix }
        return try await snapshot(through: SessionJournalHead(cursor: cursor, batchID: batch.id))
    }

    /// A retry still resolves the original user message and its original date/time zone.
    public func userEvidence(sessionID: ConversationID, executionID: ExecutionID) async throws -> SessionUserEvidence {
        let snapshot = try await snapshot(sessionID: sessionID)
        return try await userEvidence(in: snapshot, executionID: executionID)
    }

    /// The actual route and first successful foreground request are frozen journal facts.
    /// Reading this value does not grant permission to resend its historical sources.
    public func memoryExtractionContext(for job: MemoryExtractionJob) async throws -> MemoryExtractionPrefix {
        let snapshot = try await snapshot(sessionID: job.origin.source.sessionID)
        let executionID = job.turns.last?.completedExecutionID ?? job.origin.completedExecutionID
        guard let execution = snapshot.state.executions[executionID],
              execution.completion?.status == .completed,
              !snapshot.state.excludedExecutionIDs.contains(executionID) else { throw Self.unavailableEvidence }
        func requireAvailable(_ reference: SessionPayloadReference) throws {
            guard snapshot.state.references[reference.id] == reference,
                  !snapshot.state.invalidatedRetentionGroups.contains(reference.retentionGroup) else {
                throw Self.unavailableEvidence
            }
        }
        try requireAvailable(execution.admission.plan)
        let plan = try await AgentExecutionPlan.read(for: execution.admission, from: payloads)
        guard let route = plan.route else { throw Self.unavailableEvidence }
        for id in execution.attemptIDs {
            guard let attempt = snapshot.state.attempts[id], attempt.resolution?.status == .completed else { continue }
            try requireAvailable(attempt.attempt.request)
            let record = try SessionCodec.decode(AgentRequestRecord.self, from: await payloads.read(attempt.attempt.request))
            guard record.request.sessionID == snapshot.state.id,
                  record.request.executionID == executionID,
                  record.request.workspaceID == job.workspaceID,
                  record.request.destination == .model(route),
                  record.input.executionID == executionID,
                  record.input.stepID == attempt.attempt.stepID else { throw Self.invalidPrefix }
            try record.validate(for: route)
            return .init(route: route, input: record.input, sources: record.sources)
        }
        throw Self.unavailableEvidence
    }

    /// Bounded visible conversational context for memory extraction. Replies with auxiliary sources
    /// are omitted: their separate disclosure and deletion lineage cannot be inferred from the text.
    public func memoryExtractionReply(_ turn: MemoryExtractionTurn) async throws -> String? {
        let snapshot = try await snapshot(sessionID: turn.source.sessionID)
        guard let execution = snapshot.state.executions[turn.completedExecutionID],
              !snapshot.state.excludedExecutionIDs.contains(turn.completedExecutionID),
              let completion = execution.completion, completion.status == .completed,
              let answer = completion.answer,
              snapshot.state.references[answer.id] == answer,
              !snapshot.state.invalidatedRetentionGroups.contains(answer.retentionGroup) else {
            throw MiraError(.unauthorized, "The extraction conversation context is unavailable.")
        }
        let context = try await recordedContextEvidence(in: snapshot, executionID: turn.completedExecutionID)
        guard context.sources.isEmpty else { return nil }
        let bytes = try await payloads.read(answer)
        guard let text = String(data: bytes, encoding: .utf8) else { throw Self.invalidPrefix }
        return String(text.prefix(1_024))
    }

    func userEvidence(in snapshot: SessionJournalSnapshot, executionID: ExecutionID) async throws -> SessionUserEvidence {
        guard let selected = snapshot.state.executions[executionID],
              !snapshot.state.excludedExecutionIDs.contains(executionID),
              let original = snapshot.state.executionOrder.compactMap({ snapshot.state.executions[$0] }).first(where: {
                  $0.admission.userMessageID == selected.admission.userMessageID && $0.admission.userBody != nil
              }) else { throw Self.unavailableEvidence }
        return try await evidence(original: original, snapshot: snapshot)
    }

    /// Re-resolves a stored reference against a fresh committed prefix; it never trusts a copied text body.
    public func userEvidence(_ reference: SessionEvidenceReference) async throws -> SessionUserEvidence {
        try reference.validate()
        let snapshot = try await snapshot(sessionID: reference.sessionID)
        guard let original = snapshot.state.executions[reference.originalExecutionID],
              try evidenceReference(original: original, sessionID: reference.sessionID) == reference else {
            throw MiraError(.conflict, "The user evidence does not match its original admission.")
        }
        return try await evidence(original: original, snapshot: snapshot)
    }

    /// Sources recorded in successful model requests for an available completed reply.
    /// This proves historical use, not current domain or disclosure permission. Callers own a
    /// library lease and must resolve each exact domain revision through its owning authority.
    public func recordedContextEvidence(sessionID: ConversationID, executionID: ExecutionID) async throws -> SessionRecordedContextEvidence {
        let snapshot = try await snapshot(sessionID: sessionID)
        return try await recordedContextEvidence(in: snapshot, executionID: executionID)
    }

    private func recordedContextEvidence(in snapshot: SessionJournalSnapshot, executionID: ExecutionID) async throws -> SessionRecordedContextEvidence {
        let state = snapshot.state
        let sessionID = state.id
        guard let execution = state.executions[executionID],
              let completion = execution.completion, completion.status == .completed,
              let answer = completion.answer, completion.assistantMessageID != nil,
              !state.excludedExecutionIDs.contains(executionID) else { throw Self.unavailableEvidence }
        func requireAvailable(_ reference: SessionPayloadReference) throws {
            guard state.references[reference.id] == reference,
                  !state.invalidatedRetentionGroups.contains(reference.retentionGroup) else { throw Self.unavailableEvidence }
        }
        try requireAvailable(answer)
        _ = try await payloads.read(answer)
        try requireAvailable(execution.admission.plan)
        let plan = try await AgentExecutionPlan.read(for: execution.admission, from: payloads)
        guard let route = plan.route else { throw Self.unavailableEvidence }
        var sources = Set<AgentSourceReference>()
        for attemptID in execution.attemptIDs {
            try Task.checkCancellation()
            guard let attempt = state.attempts[attemptID], let resolution = attempt.resolution else {
                throw Self.invalidPrefix
            }
            guard resolution.status == .completed else { continue }
            let reference = attempt.attempt.request
            try requireAvailable(reference)
            let record = try SessionCodec.decode(AgentRequestRecord.self, from: await payloads.read(reference))
            guard record.request.sessionID == sessionID, record.request.executionID == executionID,
                  record.request.workspaceID == state.header?.workspaceID,
                  record.request.destination.modelRoute == route,
                  record.input.executionID == executionID,
                  record.input.stepID == attempt.attempt.stepID else {
                throw MiraError(.storage, "The execution request evidence is inconsistent.")
            }
            for source in record.sources { try source.validate(); sources.insert(source) }
            guard sources.count <= 8_192 else { throw Self.invalidPrefix }
        }
        try Task.checkCancellation()
        return .init(workspaceID: state.header?.workspaceID, route: route,
                     sources: sources.sorted(by: AgentSourceReference.ordered))
    }

    struct HistoryContext: Sendable {
        let connectionID: ConnectionID?
        let sources: [AgentSourceReference]
        var maintenance: [AgentLibraryMaintenanceRequest] = []
    }

    func historyContexts(in snapshot: SessionJournalSnapshot, executionIDs: Set<ExecutionID>,
                         privacyHistory: any SessionPrivacyHistoryReader) async throws -> [ExecutionID: HistoryContext] {
        let state = snapshot.state
        guard executionIDs.count <= 128, executionIDs.allSatisfy({ state.executions[$0] != nil }) else {
            throw MiraError(.invalidInput, "The historical execution selection is invalid.")
        }
        var result: [ExecutionID: HistoryContext] = [:]
        var retained = Set<ExecutionID>()
        var sourceCount = 0
        for id in executionIDs {
            try Task.checkCancellation()
            guard let execution = state.executions[id], let completion = execution.completion, completion.status == .completed,
                  completion.assistantMessageID != nil, let answer = completion.answer,
                  state.references[answer.id] == answer,
                  !state.invalidatedRetentionGroups.contains(answer.retentionGroup) else { continue }
            if state.excludedExecutionIDs.contains(id) {
                _ = try await payloads.read(answer)
                retained.insert(id)
            } else {
                // A completed local-driver reply has no model route or dispatched
                // context request. It is valid history, but it cannot contribute
                // memory source notices; keep the context empty and continue.
                _ = try await payloads.read(answer)
                guard state.references[execution.admission.plan.id] == execution.admission.plan,
                      !state.invalidatedRetentionGroups.contains(execution.admission.plan.retentionGroup) else {
                    throw Self.invalidPrefix
                }
                let plan = try await AgentExecutionPlan.read(for: execution.admission, from: payloads)
                if plan.route == nil {
                    guard execution.attemptIDs.isEmpty else { throw Self.invalidPrefix }
                    result[id] = .init(connectionID: nil, sources: [])
                    continue
                }
                let evidence = try await recordedContextEvidence(in: snapshot, executionID: id)
                sourceCount += evidence.sources.count
                guard sourceCount <= 65_536 else { throw Self.invalidPrefix }
                result[id] = .init(connectionID: evidence.route.connectionID, sources: evidence.sources)
            }
        }
        guard !retained.isEmpty else { return result }
        let records = try await privacyHistory.retainedHistory(
            sessionID: state.id, operationIDs: state.privacyOperationIDs, executionIDs: retained)
        guard records.count == state.privacyOperationIDs.count,
              Set(records.map(\.batch.id)).count == records.count else { throw Self.invalidPrefix }
        var operations = Set<UUID>()
        var sources: [ExecutionID: Set<AgentSourceReference>] = [:]
        var maintenance: [ExecutionID: [AgentLibraryMaintenanceRequest]] = [:]
        for record in records {
            try Task.checkCancellation()
            try record.request.validate()
            let batch = record.batch
            guard batch.sessionID == state.id, batch.cursor.sequence <= state.sequence,
                  batch.events.count == 1, case .invalidated(let fact) = batch.events[0].fact,
                  record.request.id == fact.operationID,
                  state.privacyOperationIDs.contains(fact.operationID), operations.insert(fact.operationID).inserted,
                  try await journal.batch(id: batch.id, sessionID: state.id) == batch,
                  Set(record.dependencies.map(\.executionID)).count == record.dependencies.count,
                  Set(record.dependencies.map(\.executionID)) == fact.executionIDs.intersection(retained) else {
                throw Self.invalidPrefix
            }
            for dependency in record.dependencies {
                try dependency.validate()
                sources[dependency.executionID, default: []].formUnion(dependency.sources)
                maintenance[dependency.executionID, default: []].append(record.request)
                guard sources[dependency.executionID, default: []].count <= 8_192 else { throw Self.invalidPrefix }
            }
        }
        guard Set(sources.keys) == retained else { throw Self.invalidPrefix }
        for (id, values) in sources {
            result[id] = .init(connectionID: nil, sources: values.sorted(by: AgentSourceReference.ordered),
                               maintenance: maintenance[id, default: []])
        }
        return result
    }

    /// Resolves only session-execution references. Callers send domain references to their owning authority.
    /// Reuses one acknowledged snapshot per session within this call and preserves the caller's order.
    public func executionSources(_ sources: [AgentSourceReference]) async throws -> [SessionExecutionSourceEvidence] {
        guard sources.count <= 8_192, Set(sources).count == sources.count,
              sources.allSatisfy({ if case .sessionExecution = $0 { return true }; return false }) else {
            throw MiraError(.invalidInput, "The session execution source selection is invalid.")
        }
        var groups: [ConversationID: [(index: Int, executionID: ExecutionID)]] = [:]
        for (index, source) in sources.enumerated() {
            guard case .sessionExecution(let sessionID, let executionID) = source else {
                throw MiraError(.invalidInput, "The session execution source selection is invalid.")
            }
            groups[sessionID, default: []].append((index, executionID))
        }
        var resolved: [Int: SessionExecutionSourceEvidence] = [:]
        for sessionID in groups.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            try Task.checkCancellation()
            let snapshot = try await self.snapshot(sessionID: sessionID)
            let state = snapshot.state
            // Keep only one full session snapshot live; locate originals once for all selected retries.
            var originals: [MessageID: SessionExecutionState] = [:]
            for executionID in state.executionOrder {
                guard let execution = state.executions[executionID], execution.admission.userBody != nil,
                      originals[execution.admission.userMessageID] == nil else { continue }
                originals[execution.admission.userMessageID] = execution
            }
            for selection in groups[sessionID] ?? [] {
                try Task.checkCancellation()
                let executionID = selection.executionID
                guard let execution = state.executions[executionID],
                      let completion = execution.completion,
                      !state.excludedExecutionIDs.contains(executionID),
                      let original = originals[execution.admission.userMessageID],
                      !state.excludedExecutionIDs.contains(original.admission.executionID) else {
                    throw MiraError(.unauthorized, "The historical execution source is unavailable.")
                }
                let replay: SessionPayloadReference?
                if completion.status == .completed {
                    guard let value = completion.replay, value.kind == .replay,
                          state.references[value.id] == value,
                          !state.invalidatedRetentionGroups.contains(value.retentionGroup) else {
                        throw MiraError(.unauthorized, "The historical execution source is unavailable.")
                    }
                    replay = value
                } else if [.cancelled, .interrupted].contains(completion.status) {
                    if let answer = completion.answer {
                        guard answer.kind == .visibleAnswer,
                              state.references[answer.id] == answer,
                              !state.invalidatedRetentionGroups.contains(answer.retentionGroup) else {
                            throw MiraError(.unauthorized, "The historical execution source is unavailable.")
                        }
                    }
                    if let thinking = completion.visibleThinking {
                        guard thinking.kind == .visibleThinking,
                              state.references[thinking.id] == thinking,
                              !state.invalidatedRetentionGroups.contains(thinking.retentionGroup) else {
                            throw MiraError(.unauthorized, "The historical execution source is unavailable.")
                        }
                    }
                    replay = nil
                } else {
                    throw MiraError(.unauthorized, "The historical execution source is unavailable.")
                }
                let user = try evidenceReference(original: original, sessionID: sessionID)
                guard state.references[user.body.id] == user.body,
                      !state.invalidatedRetentionGroups.contains(user.body.retentionGroup) else {
                    throw MiraError(.unauthorized, "The historical execution source is unavailable.")
                }
                resolved[selection.index] = .init(source: sources[selection.index], originalUser: user,
                    workspaceID: state.header?.workspaceID, replay: replay, observedHead: snapshot.head,
                    sessionAuthorizationEpoch: state.authorizationEpoch)
            }
        }
        let result = sources.indices.compactMap { resolved[$0] }
        guard result.count == sources.count else { throw Self.invalidPrefix }
        try Task.checkCancellation()
        return result
    }

    private func evidence(original: SessionExecutionState, snapshot: SessionJournalSnapshot) async throws -> SessionUserEvidence {
        let reference = try evidenceReference(original: original, sessionID: snapshot.state.id)
        guard !snapshot.state.excludedExecutionIDs.contains(original.admission.executionID),
              !snapshot.state.invalidatedRetentionGroups.contains(reference.body.retentionGroup) else {
            throw Self.unavailableEvidence
        }
        let bytes = try await payloads.read(reference.body)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw MiraError(.storage, "The admitted user message contains invalid text encoding.")
        }
        try Task.checkCancellation()
        return .init(reference: reference, workspaceID: snapshot.state.header?.workspaceID,
                     admittedAt: original.admittedAt, timeZoneIdentifier: original.admission.timeZoneIdentifier,
                     text: text, observedHead: snapshot.head, sessionAuthorizationEpoch: snapshot.state.authorizationEpoch)
    }

    private func evidenceReference(original: SessionExecutionState, sessionID: ConversationID) throws -> SessionEvidenceReference {
        guard original.admission.retryOfExecutionID == nil, let body = original.admission.userBody,
              body.batchID == original.admissionBatchID else { throw Self.unavailableEvidence }
        let reference = SessionEvidenceReference(sessionID: sessionID, originalExecutionID: original.admission.executionID,
            userMessageID: original.admission.userMessageID, admissionEventID: original.admissionEventID,
            admissionSequence: original.admissionSequence, body: body)
        try reference.validate()
        return reference
    }

    private static var invalidPrefix: MiraError { .init(.storage, "The requested session prefix is incomplete or invalid.") }
    private static var unavailableEvidence: MiraError { .init(.unauthorized, "The original user evidence is unavailable.") }
}
