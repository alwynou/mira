import Foundation

public struct SessionExecutionState: Sendable, Equatable, Codable {
    public let admission: SessionAdmission
    public let admittedAt: Date
    public let admissionEventID: UUID
    public let admissionSequence: Int64
    public let admissionBatchID: UUID
    public internal(set) var phase: ExecutionPhase = .queued
    public internal(set) var attemptIDs: [UUID] = []
    public internal(set) var drafts: [SessionDraftPart: SessionDraftState] = [:]
    public internal(set) var completion: SessionCompletion?
}

public struct SessionAttemptState: Sendable, Equatable, Codable {
    public let attempt: SessionAttempt
    /// Sequence and wall clock are the committed `attemptStarted` event metadata.
    /// They are retained so audit pagination never infers ordering from payloads.
    public let sequence: Int64
    public let startedAt: Date
    public internal(set) var resolution: SessionAttemptResolution?
    public internal(set) var invocationIDs: [UUID] = []
}

public struct SessionInvocationState: Sendable, Equatable, Codable {
    public let invocation: SessionInvocation
    public internal(set) var intent: SessionEffectIntentState?
    public internal(set) var approval: SessionToolApprovalState? = nil
    public internal(set) var dispatchedAt: Date?
    public internal(set) var resolution: SessionToolResolution?
}

public struct SessionToolApprovalState: Sendable, Equatable, Codable {
    public let expiresAt: Date
    public internal(set) var approved: Bool?
    public init(expiresAt: Date, approved: Bool? = nil) { self.expiresAt = expiresAt; self.approved = approved }
}

public struct SessionEffectIntentState: Sendable, Equatable, Codable {
    public let intent: SessionEffectIntent
    public let sequence: Int64
    public let batchID: UUID
}

public struct SessionDraftState: Sendable, Equatable, Codable {
    public let sequence: Int64
    public let checkpoint: SessionDraftCheckpoint
}

/// A deterministic metadata reducer. Payload bytes and application projections are not authority here.
public struct SessionState: Sendable, Equatable, Codable {
    public let id: ConversationID
    public private(set) var sequence: Int64 = 0
    public private(set) var header: SessionHeader?
    public private(set) var title: SessionPayloadReference?
    public private(set) var revision = 0
    public private(set) var isArchived = false
    public private(set) var authorizationEpoch: UInt64 = 0
    /// The journal-authoritative session model intent. It defaults to inherit
    /// when the opening fact is reduced and is never changed by resolution.
    public private(set) var modelSelection: AgentSessionModelSelection = .inherit
    public private(set) var modelSelectionRevision: Int = 0
    public private(set) var activeExecutionID: ExecutionID?
    public private(set) var executionOrder: [ExecutionID] = []
    public private(set) var executions: [ExecutionID: SessionExecutionState] = [:]
    public private(set) var attempts: [UUID: SessionAttemptState] = [:]
    public private(set) var invocations: [UUID: SessionInvocationState] = [:]
    public private(set) var excludedExecutionIDs: Set<ExecutionID> = []
    public private(set) var invalidatedRetentionGroups: Set<UUID> = []
    /// Groups retired by retry remain logically unavailable but are physically erasable only
    /// after a later explicit privacy operation authorizes their removal.
    public private(set) var erasedRetentionGroups: Set<UUID> = []
    public private(set) var references: [UUID: SessionPayloadReference] = [:]
    private var eventIDs: Set<UUID> = []
    private var batchIDs: Set<UUID> = []
    private var messageIDs: Set<MessageID> = []
    private var invalidationIDs: Set<UUID> = []
    private var retentionOwners: [UUID: RetentionOwner] = [:]

    private struct RetentionOwner: Sendable, Equatable, Codable {
        let executionID: ExecutionID?
        let visible: Bool
    }

    public init(id: ConversationID) { self.id = id }

    var privacyOperationIDs: Set<UUID> { invalidationIDs }

    /// Retention ownership is established by the reducer, never inferred from a query projection.
    func privacyGroups(for executionIDs: Set<ExecutionID>, retention: SessionPrivacyRetention) -> Set<UUID> {
        Set(references.values.compactMap { reference in
            guard let owner = retentionOwners[reference.retentionGroup],
                  let executionID = owner.executionID, executionIDs.contains(executionID) else { return nil }
            if !owner.visible || invalidatedRetentionGroups.contains(reference.retentionGroup) {
                return reference.retentionGroup
            }
            if retention == .purgeGeneratedHistory,
               reference.kind == .visibleAnswer || reference.kind == .visibleThinking { return reference.retentionGroup }
            return nil
        })
    }

    /// Generated retry bodies are retired while the execution plan remains
    /// available for admission idempotency and recovery validation.
    func retryCleanupGroups(forUserMessageID userMessageID: MessageID) -> Set<UUID> {
        Set(references.values.compactMap { reference in
            guard let owner = retentionOwners[reference.retentionGroup],
                  let executionID = owner.executionID,
                  executions[executionID]?.admission.userMessageID == userMessageID,
                  !invalidatedRetentionGroups.contains(reference.retentionGroup) else { return nil }
            switch reference.kind {
            case .title, .userText, .executionPlan: return nil
            default: return reference.retentionGroup
            }
        })
    }

    /// Rejection leaves the complete pre-batch state intact, including the sequence and identities.
    public mutating func apply(_ batch: SessionBatch,
                               extensionSchemas: [String: Set<Int>] = [:]) throws {
        try batch.validate()
        guard batch.sessionID == id, batch.expectedSequence == sequence,
              !batchIDs.contains(batch.id) else { throw invalid("The session batch is out of order.") }
        var next = self
        var completedInBatch: Set<UUID> = []
        for event in batch.events {
            guard next.eventIDs.insert(event.id).inserted else {
                throw invalid("The session event identity has already been used.")
            }
            try next.reduce(event, batchID: batch.id, completedInBatch: &completedInBatch,
                            extensionSchemas: extensionSchemas)
            next.sequence = event.sequence
        }
        next.batchIDs.insert(batch.id)
        self = next
    }

    private mutating func reduce(_ event: SessionEvent, batchID: UUID,
                                 completedInBatch: inout Set<UUID>,
                                 extensionSchemas: [String: Set<Int>]) throws {
        if header == nil {
            guard case .opened = event.fact, sequence == 0 else {
                throw invalid("The first session event must open the session.")
            }
        }
        switch event.fact {
        case .opened(let value):
            guard header == nil else { throw invalid("The session is already open.") }
            try register(value.title, kind: .title, owner: nil, batchID: batchID)
            header = value; title = value.title; revision = 1
            modelSelection = .inherit; modelSelectionRevision = 0

        case .modelSelectionChanged(let selection, let expectedRevision):
            guard !isArchived, activeExecutionID == nil,
                  expectedRevision == modelSelectionRevision,
                  modelSelectionRevision < Int.max else {
                throw invalid("The session model selection revision is stale or the session is busy.")
            }
            try selection.validate()
            modelSelection = selection
            modelSelectionRevision = expectedRevision + 1

        case .renamed(let value, let expectedRevision):
            guard !isArchived, revision < Int.max, expectedRevision == revision + 1 else {
                throw invalid("The session revision is stale.")
            }
            try register(value, kind: .title, owner: nil, batchID: batchID)
            title = value; revision = expectedRevision

        case .archived(let expectedRevision):
            guard !isArchived, activeExecutionID == nil, revision < Int.max,
                  expectedRevision == revision + 1 else {
                throw invalid("An active or archived session cannot be archived.")
            }
            revision = expectedRevision; isArchived = true

        case .admitted(let value):
            guard !isArchived, activeExecutionID == nil, executions[value.executionID] == nil,
                  value.authorizationEpoch == authorizationEpoch, value.timeZoneIdentifier.utf8.count <= 128,
                  value.modelSelectionRevision >= 0,
                  value.modelSelectionRevision == modelSelectionRevision,
                  TimeZone(identifier: value.timeZoneIdentifier) != nil else {
                throw invalid("The session cannot admit this execution.")
            }
            if let previousID = value.retryOfExecutionID {
                guard executionOrder.last == previousID, let previous = executions[previousID],
                      let completion = previous.completion, completion.status != .completed,
                      previous.admission.userMessageID == value.userMessageID, value.userBody == nil,
                      !excludedExecutionIDs.contains(previousID), effectsAreKnown(previous) else {
                    throw invalid("Only the last eligible unsuccessful execution can be retried.")
                }
            } else {
                guard let body = value.userBody, messageIDs.insert(value.userMessageID).inserted else {
                    throw invalid("A new execution requires a unique user message.")
                }
                try register(body, kind: .userText, owner: value.executionID, batchID: batchID)
            }
            try register(value.plan, kind: .executionPlan, owner: value.executionID, batchID: batchID)
            executions[value.executionID] = .init(admission: value, admittedAt: event.occurredAt,
                admissionEventID: event.id, admissionSequence: event.sequence, admissionBatchID: batchID)
            executionOrder.append(value.executionID); activeExecutionID = value.executionID

        case .phaseChanged(let executionID, let phase):
            let current = try active(executionID, allowExcluded: phase == .cancelling)
            guard current.phase != phase, Self.permits(from: current.phase, to: phase) else {
                throw invalid("The execution phase transition is invalid.")
            }
            executions[executionID]?.phase = phase

        case .attemptStarted(let value):
            let execution = try active(value.executionID)
            guard execution.phase == .preparing, execution.admission.hasModelRoute, attempts[value.id] == nil,
                  value.stepIndex > 0, value.attemptIndex > 0 else {
                throw invalid("A model attempt cannot start in this state.")
            }
            if let previousID = execution.attemptIDs.last, let previous = attempts[previousID] {
                guard let resolution = previous.resolution,
                      previous.invocationIDs.allSatisfy({ invocations[$0]?.resolution?.effectIsKnown == true }) else {
                    throw invalid("A previous model attempt or tool is unsettled.")
                }
                let old = previous.attempt
                if value.stepID == old.stepID {
                    guard resolution.status == .failed, old.attemptIndex < Int.max,
                          value.stepIndex == old.stepIndex, value.attemptIndex == old.attemptIndex + 1,
                          value.request == old.request else {
                        throw invalid("A retry must retain its frozen request and step.")
                    }
                } else {
                    guard resolution.status == .completed, old.stepIndex < Int.max,
                          value.stepIndex == old.stepIndex + 1, value.attemptIndex == 1,
                          !execution.attemptIDs.contains(where: { attempts[$0]?.attempt.stepID == value.stepID }) else {
                        throw invalid("A new model step is out of order.")
                    }
                }
            } else if value.stepIndex != 1 || value.attemptIndex != 1 {
                throw invalid("The first model attempt must start at step one.")
            }
            try register(value.request, kind: .request, owner: value.executionID, batchID: batchID)
            attempts[value.id] = .init(attempt: value, sequence: event.sequence, startedAt: event.occurredAt)
            executions[value.executionID]?.attemptIDs.append(value.id)
            executions[value.executionID]?.phase = .waitingForModel

        case .attemptResolved(let value):
            guard let attempt = attempts[value.attemptID], attempt.resolution == nil,
                  value.status != .prepared else { throw invalid("The model attempt is already settled or missing.") }
            let execution = try active(attempt.attempt.executionID, allowExcluded: true)
            if excludedExecutionIDs.contains(attempt.attempt.executionID) || execution.phase == .cancelling {
                guard value.status == .interrupted, value.output == nil, value.error == nil else {
                    throw invalid("A revoked model attempt cannot publish content.")
                }
            }
            guard value.status != .completed || value.output != nil else {
                throw invalid("A completed model attempt requires its output.")
            }
            try value.usage.validate(maximumTokens: TokenUsage.maximumAggregateTokens)
            try register(value.output, kind: .modelOutput, owner: attempt.attempt.executionID, batchID: batchID)
            try register(value.error, kind: .error, owner: attempt.attempt.executionID, batchID: batchID)
            attempts[value.attemptID]?.resolution = value
            if value.status == .completed { completedInBatch.insert(value.attemptID) }

        case .toolProposed(let value):
            guard let attempt = attempts[value.attemptID], completedInBatch.contains(value.attemptID),
                  invocations[value.id] == nil, value.modelOrder == attempt.invocationIDs.count,
                  Self.validIdentifier(value.toolName, maximumBytes: 64) else {
                throw invalid("Tool proposals must be ordered and atomic with their model output.")
            }
            _ = try active(attempt.attempt.executionID)
            try register(value.call, kind: .toolCall, owner: attempt.attempt.executionID, batchID: batchID)
            invocations[value.id] = .init(invocation: value)
            attempts[value.attemptID]?.invocationIDs.append(value.id)

        case .toolPrepared(let value):
            guard let invocation = invocations[value.invocationID], invocation.intent == nil,
                  invocation.dispatchedAt == nil, invocation.resolution == nil,
                  let attempt = attempts[invocation.invocation.attemptID], attempt.resolution?.status == .completed else {
                throw invalid("The tool effect intent is missing, stale, or duplicated.")
            }
            let execution = try active(attempt.attempt.executionID)
            guard execution.phase == .waitingForTools || execution.phase == .waitingForUser else {
                throw invalid("The execution is not ready to prepare a tool effect.")
            }
            try register(value.proposal, kind: .effectIntent, owner: attempt.attempt.executionID, batchID: batchID)
            invocations[value.invocationID]?.intent = .init(intent: value, sequence: event.sequence, batchID: batchID)

        case .toolApprovalRequested(let invocationID, let expiresAt):
            guard let invocation = invocations[invocationID], invocation.intent != nil,
                  invocation.dispatchedAt == nil, invocation.resolution == nil, invocation.approval == nil,
                  let attempt = attempts[invocation.invocation.attemptID], attempt.resolution?.status == .completed,
                  let execution = executions[attempt.attempt.executionID], activeExecutionID == attempt.attempt.executionID,
                  execution.completion == nil,
                  !excludedExecutionIDs.contains(attempt.attempt.executionID),
                  [.waitingForTools, .waitingForUser].contains(execution.phase),
                  expiresAt.timeIntervalSince(event.occurredAt).isFinite,
                  expiresAt > event.occurredAt, expiresAt.timeIntervalSince(event.occurredAt) <= 86_400 else {
                throw invalid("The tool approval request is stale or invalid.")
            }
            invocations[invocationID]?.approval = .init(expiresAt: expiresAt)

        case .toolApprovalResolved(let invocationID, let approved):
            guard let invocation = invocations[invocationID], let approval = invocation.approval,
                  approval.approved == nil, invocation.dispatchedAt == nil, invocation.resolution == nil,
                  let attempt = attempts[invocation.invocation.attemptID],
                  let execution = executions[attempt.attempt.executionID], execution.completion == nil,
                  activeExecutionID == attempt.attempt.executionID else {
                throw invalid("The tool approval request is missing or already resolved.")
            }
            if approved {
                guard !excludedExecutionIDs.contains(attempt.attempt.executionID),
                      [.waitingForTools, .waitingForUser].contains(execution.phase),
                      event.occurredAt < approval.expiresAt else { throw invalid("The tool approval has expired or is no longer authorized.") }
            }
            invocations[invocationID]?.approval?.approved = approved

        case .toolDispatched(let invocationID, let epoch):
            guard let invocation = invocations[invocationID], invocation.dispatchedAt == nil,
                  invocation.intent != nil, invocation.resolution == nil, epoch == authorizationEpoch,
                  (invocation.approval.map { $0.approved == true } ?? true),
                  let attempt = attempts[invocation.invocation.attemptID] else {
                throw invalid("The tool dispatch is stale or duplicated.")
            }
            let execution = try active(attempt.attempt.executionID)
            guard execution.phase == .waitingForTools || execution.phase == .waitingForUser else {
                throw invalid("The execution is not ready to dispatch tools.")
            }
            invocations[invocationID]?.dispatchedAt = event.occurredAt

        case .toolResolved(let value):
            guard let invocation = invocations[value.invocationID], invocation.resolution == nil,
                  invocation.approval.map({ $0.approved != nil }) ?? true,
                  let attempt = attempts[invocation.invocation.attemptID] else {
                throw invalid("The tool invocation is already settled or missing.")
            }
            _ = try active(attempt.attempt.executionID, allowExcluded: true)
            if excludedExecutionIDs.contains(attempt.attempt.executionID), value.result != nil {
                throw invalid("A revoked tool cannot publish content.")
            }
            if invocation.dispatchedAt == nil {
                guard [.invalidArguments, .notFound, .denied, .cancelledBeforeDispatch].contains(value.status),
                      value.effectIsKnown, value.businessReceipt == nil, !value.resultWasPurged else {
                    throw invalid("An undispatched tool cannot report an effect.")
                }
            } else if value.status == .succeeded {
                guard value.effectIsKnown, value.result != nil || value.resultWasPurged,
                      invocation.invocation.effect != .localWrite || value.businessReceipt != nil else {
                    throw invalid("A successful local write requires a durable business receipt.")
                }
            }
            if !value.effectIsKnown {
                guard invocation.dispatchedAt != nil, invocation.invocation.effect != .read,
                      [.interrupted, .cancelled, .timedOut, .failed].contains(value.status) else {
                    throw invalid("The tool effect uncertainty is invalid.")
                }
            }
            guard value.businessReceipt == nil || invocation.invocation.effect == .localWrite else {
                throw invalid("Only a local write can reference a business receipt.")
            }
            if let receipt = value.businessReceipt {
                try receipt.validate()
                guard let intent = invocation.intent?.intent, receipt.invocationID == value.invocationID,
                      receipt.authorization == intent.authorization, receipt.intentDigest == intent.proposal.digest,
                      value.effectIsKnown, value.status == .succeeded,
                      value.result.map({ $0.digest == receipt.resultDigest }) ?? value.resultWasPurged else {
                    throw invalid("The business receipt does not match the durable tool intent or result.")
                }
            }
            guard !value.resultWasPurged || (value.businessReceipt != nil && value.result == nil && value.status == .succeeded) else {
                throw invalid("Only a committed business receipt can have a purged result.")
            }
            try register(value.result, kind: .toolResult, owner: attempt.attempt.executionID, batchID: batchID)
            invocations[value.invocationID]?.resolution = value

        case .draftCheckpoint(let value):
            let execution = try active(value.executionID)
            guard execution.phase == .waitingForModel, execution.attemptIDs.last == value.attemptID,
                  attempts[value.attemptID]?.resolution == nil else {
                throw invalid("Only the current streaming model attempt can advance its draft.")
            }
            let previous = execution.drafts[value.part]
            try SessionDraftPatch.validate(value, previous: previous)
            try register(value.replacement, kind: .draft, owner: value.executionID, batchID: batchID)
            executions[value.executionID]?.drafts[value.part] = .init(sequence: event.sequence, checkpoint: value)

        case .finished(let value):
            let execution = try active(value.executionID, allowExcluded: true)
            guard value.status.isTerminal, [.settling, .cancelling].contains(execution.phase),
                  value.status != .completed || effectsAreKnown(execution),
                  execution.attemptIDs.allSatisfy({ id in
                      guard let attempt = attempts[id], attempt.resolution != nil else { return false }
                      return attempt.invocationIDs.allSatisfy { invocations[$0]?.resolution != nil }
                  }) else { throw invalid("An execution with unsettled work cannot finish.") }
            if excludedExecutionIDs.contains(value.executionID) || execution.phase == .cancelling {
                guard value.status == .cancelled || value.status == .interrupted else {
                    throw invalid("A cancelled execution cannot complete successfully.")
                }
            }
            if excludedExecutionIDs.contains(value.executionID) {
                guard event.fact.payloadReferences.isEmpty else { throw invalid("A revoked execution cannot publish content.") }
            }
            let hasVisibleContent = value.answer != nil || value.visibleThinking != nil
            guard (value.assistantMessageID != nil) == hasVisibleContent,
                  value.status != .completed || hasVisibleContent,
                  value.status == .completed || value.replay == nil else {
                throw invalid("The assistant result and completion do not agree.")
            }
            if let messageID = value.assistantMessageID, !messageIDs.insert(messageID).inserted {
                throw invalid("The assistant message identity has already been used.")
            }
            try value.usage.validate(maximumTokens: TokenUsage.maximumAggregateTokens)
            try register(value.answer, kind: .visibleAnswer, owner: value.executionID, batchID: batchID)
            try register(value.visibleThinking, kind: .visibleThinking, owner: value.executionID, batchID: batchID)
            try register(value.replay, kind: .replay, owner: value.executionID, batchID: batchID)
            try register(value.error, kind: .error, owner: value.executionID, batchID: batchID)
            executions[value.executionID]?.completion = value
            executions[value.executionID]?.drafts.removeAll()
            activeExecutionID = nil

        case .invalidated(let value):
            guard !invalidationIDs.contains(value.operationID), authorizationEpoch < UInt64.max,
                  value.authorizationEpoch == authorizationEpoch + 1,
                  value.executionIDs.allSatisfy({ executions[$0] != nil }),
                  value.retentionGroups.allSatisfy({ group in
                      guard let owner = retentionOwners[group] else { return false }
                      return owner.executionID.map { value.executionIDs.contains($0) } ?? true
                  }) else {
                throw invalid("The invalidation epoch or ownership is invalid.")
            }
            let affectedMessages = Set(value.executionIDs.compactMap { executions[$0]?.admission.userMessageID })
            guard executions.allSatisfy({ executionID, execution in
                !affectedMessages.contains(execution.admission.userMessageID) || value.executionIDs.contains(executionID)
            }), retentionOwners.allSatisfy({ group, owner in
                guard let executionID = owner.executionID, value.executionIDs.contains(executionID),
                      !owner.visible || invalidatedRetentionGroups.contains(group) else { return true }
                return value.retentionGroups.contains(group) || erasedRetentionGroups.contains(group)
            }) else { throw invalid("Invalidation must include retry descendants and their hidden payloads.") }
            invalidationIDs.insert(value.operationID)
            authorizationEpoch = value.authorizationEpoch
            excludedExecutionIDs.formUnion(value.executionIDs)
            invalidatedRetentionGroups.formUnion(value.retentionGroups)
            erasedRetentionGroups.formUnion(value.retentionGroups)

        case .retryCleared(let value):
            guard activeExecutionID == value.retryExecutionID,
                  let retry = executions[value.retryExecutionID], retry.completion == nil,
                  retry.admissionBatchID == batchID,
                  event.sequence == retry.admissionSequence + 1,
                  retry.admission.retryOfExecutionID == value.sourceExecutionID,
                  let source = executions[value.sourceExecutionID], let completion = source.completion,
                  completion.status != .completed,
                  source.admission.userMessageID == retry.admission.userMessageID,
                  !excludedExecutionIDs.contains(value.sourceExecutionID), effectsAreKnown(source),
                  value.retentionGroups == retryCleanupGroups(forUserMessageID: retry.admission.userMessageID),
                  value.retentionGroups.allSatisfy({ !invalidatedRetentionGroups.contains($0) }) else {
                throw invalid("Retry cleanup is stale, incomplete, or targets an invalid execution.")
            }
            invalidatedRetentionGroups.formUnion(value.retentionGroups)

        case .extensionRecorded(let namespace, let schemaVersion, let required, let body):
            guard Self.validIdentifier(namespace, maximumBytes: 128), !namespace.hasPrefix("mira."),
                  schemaVersion > 0 else { throw invalid("The extension event identity is invalid or reserved.") }
            if required && extensionSchemas[namespace]?.contains(schemaVersion) != true {
                throw MiraError(.unsupported, "A required session extension is unavailable.")
            }
            try register(body, kind: .module, owner: activeExecutionID, batchID: batchID)
        }
    }

    private func active(_ executionID: ExecutionID, allowExcluded: Bool = false) throws -> SessionExecutionState {
        guard activeExecutionID == executionID, let execution = executions[executionID],
              execution.completion == nil, allowExcluded || !excludedExecutionIDs.contains(executionID) else {
            throw invalid("The execution is inactive, settled, or revoked.")
        }
        return execution
    }

    private func effectsAreKnown(_ execution: SessionExecutionState) -> Bool {
        execution.attemptIDs.allSatisfy { id in
            guard let attempt = attempts[id] else { return false }
            return attempt.invocationIDs.allSatisfy { invocations[$0]?.resolution?.effectIsKnown == true }
        }
    }

    private mutating func register(_ reference: SessionPayloadReference?, kind: SessionPayloadKind,
                                   owner: ExecutionID?, batchID: UUID) throws {
        guard let reference else { return }
        guard reference.kind == kind, !invalidatedRetentionGroups.contains(reference.retentionGroup) else {
            throw invalid("The payload kind or retention eligibility is invalid.")
        }
        let lifetime = RetentionOwner(executionID: owner,
                                      visible: [.title, .userText, .visibleAnswer, .visibleThinking].contains(kind))
        if let old = references[reference.id] {
            guard old == reference, retentionOwners[reference.retentionGroup] == lifetime else {
                throw invalid("An existing payload identity cannot change ownership.")
            }
        } else {
            guard reference.batchID == batchID,
                  retentionOwners[reference.retentionGroup].map({ $0 == lifetime }) ?? true else {
                throw invalid("New payloads must belong to this batch and one retention lifetime.")
            }
            references[reference.id] = reference
            retentionOwners[reference.retentionGroup] = lifetime
        }
    }

    private static func permits(from: ExecutionPhase, to: ExecutionPhase) -> Bool {
        if to == .cancelling { return from != .cancelling }
        switch from {
        case .queued: return to == .preparing || to == .settling
        case .preparing: return to == .settling
        case .waitingForModel: return [.preparing, .waitingForTools, .settling].contains(to)
        case .waitingForTools: return [.preparing, .waitingForUser, .settling].contains(to)
        case .waitingForUser: return [.waitingForTools, .settling].contains(to)
        case .settling, .cancelling: return false
        }
    }

    static func validIdentifier(_ value: String, maximumBytes: Int) -> Bool {
        let bytes = value.utf8
        guard (1...maximumBytes).contains(bytes.count), let first = bytes.first,
              (97...122).contains(first) else { return false }
        return bytes.allSatisfy { (97...122).contains($0) || (65...90).contains($0) ||
            (48...57).contains($0) || $0 == 46 || $0 == 95 || $0 == 45 }
    }

    private func invalid(_ message: String) -> MiraError { .init(.conflict, message) }
}
