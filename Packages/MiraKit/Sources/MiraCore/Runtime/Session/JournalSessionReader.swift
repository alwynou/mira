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

    public init(sessionID: ConversationID, originalExecutionID: ExecutionID, userMessageID: MessageID,
                admissionEventID: UUID, admissionSequence: Int64) {
        self.sessionID = sessionID; self.originalExecutionID = originalExecutionID
        self.userMessageID = userMessageID; self.admissionEventID = admissionEventID
        self.admissionSequence = admissionSequence
    }

    public func validate() throws {
        guard admissionSequence > 0 else {
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
/// The original body is resolved from the canonical session prefix when evidence is read.
public struct SessionExecutionSourceEvidence: Sendable, Equatable {
    public let source: AgentSourceReference
    public let originalUser: SessionEvidenceReference
    public let workspaceID: WorkspaceID?
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
    private let payloads: any SessionContentReader
    private let extensionSchemas: [String: Set<Int>]

    public init(journal: any SessionJournal, payloads: any SessionContentReader,
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

    func userEvidence(in snapshot: SessionJournalSnapshot, executionID: ExecutionID) async throws -> SessionUserEvidence {
        guard let selected = snapshot.state.executions[executionID],
              !snapshot.state.supersededExecutionIDs.contains(executionID),
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

    public func memoryExtractionContext(for job: MemoryExtractionJob) async throws -> MemoryExtractionPrefix {
        try job.validate()
        let selectedTurn = job.turns.last
        let source = selectedTurn?.source ?? job.origin.source
        let executionID = selectedTurn?.completedExecutionID ?? job.origin.completedExecutionID
        let snapshot = try await snapshot(sessionID: source.sessionID)
        guard snapshot.state.header?.workspaceID == job.workspaceID,
              let execution = snapshot.state.executions[executionID],
              execution.completion?.status == .completed,
              !snapshot.state.supersededExecutionIDs.contains(executionID) else {
            throw Self.unavailableEvidence
        }
        let plan = try await AgentExecutionPlan.read(for: execution.admission, from: payloads)
        guard let route = plan.route else { throw Self.unavailableEvidence }
        let evidence = try await userEvidence(in: snapshot, executionID: executionID)
        guard evidence.reference == source else { throw Self.invalidPrefix }
        for attemptID in execution.attemptIDs {
            guard let attempt = snapshot.state.attempts[attemptID],
                  attempt.resolution?.status == .completed else { continue }
            let request = try SessionCodec.decode(AgentSessionRequest.self, from: await payloads.read(attempt.attempt.request))
            try request.validate(for: route)
            guard request.request.sessionID == snapshot.state.id,
                  request.request.executionID == executionID,
                  request.request.workspaceID == job.workspaceID,
                  request.request.destination == .model(route) else { throw Self.invalidPrefix }
            let input = AgentModelInput(stepID: attempt.attempt.stepID,
                executionID: executionID, instructions: request.instructions,
                messages: request.contextMessages + [.init(role: .user,
                    blocks: [.init(id: "extraction-user", content: .text(evidence.text))])],
                tools: request.tools)
            try input.validate(for: route)
            return .init(route: route, input: input,
                         sources: AgentContextBuild.orderedSources(request.sources +
                            [.sessionExecution(sessionID: snapshot.state.id,
                                                executionID: executionID)]))
        }
        throw Self.unavailableEvidence
    }

    public func memoryExtractionReply(_ turn: MemoryExtractionTurn) async throws -> String? {
        try turn.validate()
        let snapshot = try await snapshot(sessionID: turn.source.sessionID)
        guard let execution = snapshot.state.executions[turn.completedExecutionID],
              execution.completion?.status == .completed,
              !snapshot.state.supersededExecutionIDs.contains(turn.completedExecutionID),
              execution.admission.userMessageID == turn.source.userMessageID,
              let answer = execution.completion?.answer, answer.kind == .visibleAnswer else {
            throw Self.unavailableEvidence
        }
        let evidence = try await userEvidence(in: snapshot, executionID: turn.completedExecutionID)
        guard evidence.reference == turn.source else { throw Self.unavailableEvidence }
        let context = try await recordedContextEvidence(in: snapshot, executionID: turn.completedExecutionID)
        guard context.sources.isEmpty else { return nil }
        let bytes = try await payloads.read(answer)
        guard let text = String(data: bytes, encoding: .utf8) else { throw Self.invalidPrefix }
        return String(text.prefix(1_024))
    }

    /// Sources recorded in successful model requests for an available completed reply.
    /// This proves historical use, not current domain or disclosure permission. Callers own a
    /// library lease and must resolve each exact domain revision through its owning authority.
    public func recordedContextEvidence(sessionID: ConversationID, executionID: ExecutionID) async throws -> SessionRecordedContextEvidence {
        let snapshot = try await snapshot(sessionID: sessionID)
        return try await recordedContextEvidence(in: snapshot, executionID: executionID)
    }

    func recordedContextEvidence(in snapshot: SessionJournalSnapshot, executionID: ExecutionID) async throws -> SessionRecordedContextEvidence {
        let state = snapshot.state
        let sessionID = state.id
        guard let execution = state.executions[executionID],
              let completion = execution.completion, completion.status == .completed,
              let answer = completion.answer, answer.kind == .visibleAnswer, completion.assistantMessageID != nil,
              !state.supersededExecutionIDs.contains(executionID) else { throw Self.unavailableEvidence }
        func requireAvailable(_ reference: SessionContent) throws {
            try reference.validate()
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
            let request = try SessionCodec.decode(AgentSessionRequest.self, from: await payloads.read(reference))
            guard request.request.sessionID == sessionID, request.request.executionID == executionID,
                  request.request.workspaceID == state.header?.workspaceID,
                  request.request.destination.modelRoute == route else {
                throw MiraError(.storage, "The execution request evidence is inconsistent.")
            }
            try request.validate(for: route)
            for source in request.sources { try source.validate(); sources.insert(source) }
            guard sources.count <= 8_192 else { throw Self.invalidPrefix }
        }
        try Task.checkCancellation()
        return .init(workspaceID: state.header?.workspaceID, route: route,
                     sources: sources.sorted(by: AgentSourceReference.ordered))
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
                      !state.supersededExecutionIDs.contains(executionID),
                      let original = originals[execution.admission.userMessageID] else {
                    throw MiraError(.unauthorized, "The historical execution source is unavailable.")
                }
                if completion.status == .completed {
                    guard execution.attemptIDs.allSatisfy({ state.attempts[$0]?.resolution?.status == .completed }) else {
                        throw MiraError(.unauthorized, "The historical execution source is unavailable.")
                    }
                    if !execution.attemptIDs.isEmpty {
                        _ = try await recordedContextEvidence(in: snapshot, executionID: executionID)
                    }
                } else if [.cancelled, .interrupted].contains(completion.status) {
                    if let answer = completion.answer {
                        guard answer.kind == .visibleAnswer else {
                            throw MiraError(.unauthorized, "The historical execution source is unavailable.")
                        }
                    }
                    if let thinking = completion.visibleThinking {
                        guard thinking.kind == .visibleThinking else {
                            throw MiraError(.unauthorized, "The historical execution source is unavailable.")
                        }
                    }
                } else {
                    throw MiraError(.unauthorized, "The historical execution source is unavailable.")
                }
                let user = try evidenceReference(original: original, sessionID: sessionID)
                resolved[selection.index] = .init(source: sources[selection.index], originalUser: user,
                    workspaceID: state.header?.workspaceID, observedHead: snapshot.head,
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
        guard let body = original.admission.userBody else {
            throw Self.unavailableEvidence
        }
        let bytes = try await payloads.read(body)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw MiraError(.storage, "The admitted user message contains invalid text encoding.")
        }
        try Task.checkCancellation()
        return .init(reference: reference, workspaceID: snapshot.state.header?.workspaceID,
                     admittedAt: original.admittedAt, timeZoneIdentifier: original.admission.timeZoneIdentifier,
                     text: text, observedHead: snapshot.head, sessionAuthorizationEpoch: snapshot.state.authorizationEpoch)
    }

    private func evidenceReference(original: SessionExecutionState, sessionID: ConversationID) throws -> SessionEvidenceReference {
        guard original.admission.retryOfExecutionID == nil, original.admission.userBody != nil else { throw Self.unavailableEvidence }
        let reference = SessionEvidenceReference(sessionID: sessionID, originalExecutionID: original.admission.executionID,
            userMessageID: original.admission.userMessageID, admissionEventID: original.admissionEventID,
            admissionSequence: original.admissionSequence)
        try reference.validate()
        return reference
    }

    private static var invalidPrefix: MiraError { .init(.storage, "The requested session prefix is incomplete or invalid.") }
    private static var unavailableEvidence: MiraError { .init(.unauthorized, "The original user evidence is unavailable.") }
}
