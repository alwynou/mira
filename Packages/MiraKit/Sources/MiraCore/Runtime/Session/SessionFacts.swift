import Foundation

public enum ExecutionPhase: String, Codable, Sendable {
    case queued, preparing, waitingForModel, waitingForTools, waitingForUser, settling, cancelling
}

public struct SessionHeader: Codable, Sendable, Equatable {
    public let workspaceID: WorkspaceID?
    public let title: SessionPayloadReference
    public init(workspaceID: WorkspaceID?, title: SessionPayloadReference) {
        self.workspaceID = workspaceID; self.title = title
    }
}

public struct SessionAdmission: Codable, Sendable, Equatable {
    public let executionID: ExecutionID
    public let userMessageID: MessageID
    public let retryOfExecutionID: ExecutionID?
    public let userBody: SessionPayloadReference?
    public let plan: SessionPayloadReference
    public let hasModelRoute: Bool
    public let authorizationEpoch: UInt64
    public let timeZoneIdentifier: String
    /// The selection revision observed while this admission was prepared.
    /// Admission is rejected if a concurrent selection change committed first.
    public let modelSelectionRevision: Int
    public init(executionID: ExecutionID, userMessageID: MessageID, retryOfExecutionID: ExecutionID? = nil,
                userBody: SessionPayloadReference?, plan: SessionPayloadReference, hasModelRoute: Bool, authorizationEpoch: UInt64,
                timeZoneIdentifier: String, modelSelectionRevision: Int = 0) {
        self.executionID = executionID; self.userMessageID = userMessageID
        self.retryOfExecutionID = retryOfExecutionID; self.userBody = userBody
        self.plan = plan; self.hasModelRoute = hasModelRoute
        self.authorizationEpoch = authorizationEpoch; self.timeZoneIdentifier = timeZoneIdentifier
        self.modelSelectionRevision = modelSelectionRevision
    }
}

public struct SessionAttempt: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let executionID: ExecutionID
    public let stepID: UUID
    public let stepIndex: Int
    public let attemptIndex: Int
    public let request: SessionPayloadReference
    public let contents: [SessionPayloadReference]
    public init(id: UUID, executionID: ExecutionID, stepID: UUID, stepIndex: Int,
                attemptIndex: Int, request: SessionPayloadReference, contents: [SessionPayloadReference] = []) {
        self.id = id; self.executionID = executionID; self.stepID = stepID
        self.stepIndex = stepIndex; self.attemptIndex = attemptIndex; self.request = request; self.contents = contents
    }
}

public struct SessionAttemptResolution: Codable, Sendable, Equatable {
    public let attemptID: UUID
    public let status: AttemptStatus
    public let output: SessionPayloadReference?
    public let error: SessionPayloadReference?
    public let usage: TokenUsage
    public init(attemptID: UUID, status: AttemptStatus, output: SessionPayloadReference? = nil,
                error: SessionPayloadReference? = nil, usage: TokenUsage = .init()) {
        self.attemptID = attemptID; self.status = status; self.output = output
        self.error = error; self.usage = usage
    }
}

public enum SessionEffectKind: String, Codable, Sendable { case read, localWrite, externalWrite }

public struct SessionInvocation: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let attemptID: UUID
    public let modelOrder: Int
    public let toolName: String
    public let effect: SessionEffectKind
    public let call: SessionPayloadReference
    public init(id: UUID, attemptID: UUID, modelOrder: Int, toolName: String,
                effect: SessionEffectKind, call: SessionPayloadReference) {
        self.id = id; self.attemptID = attemptID; self.modelOrder = modelOrder
        self.toolName = toolName; self.effect = effect; self.call = call
    }
}

public struct SessionEffectIntent: Codable, Sendable, Equatable {
    public let invocationID: UUID
    public let authorization: AgentLibraryAuthorization
    public let proposal: SessionPayloadReference
    public init(invocationID: UUID, authorization: AgentLibraryAuthorization, proposal: SessionPayloadReference) {
        self.invocationID = invocationID; self.authorization = authorization; self.proposal = proposal
    }
}

public struct SessionToolResolution: Codable, Sendable, Equatable {
    public let invocationID: UUID
    public let status: ToolResultStatus
    public let result: SessionPayloadReference?
    public let businessReceipt: AgentBusinessReceiptReference?
    public let resultWasPurged: Bool
    public let effectIsKnown: Bool
    public init(invocationID: UUID, status: ToolResultStatus, result: SessionPayloadReference? = nil,
                businessReceipt: AgentBusinessReceiptReference? = nil, resultWasPurged: Bool = false, effectIsKnown: Bool = true) {
        self.invocationID = invocationID; self.status = status; self.result = result
        self.businessReceipt = businessReceipt; self.resultWasPurged = resultWasPurged; self.effectIsKnown = effectIsKnown
    }
}

public enum SessionDraftPart: String, Codable, Sendable, Hashable { case answer, thinking, transcript }

public struct SessionCompletion: Codable, Sendable, Equatable {
    public let executionID: ExecutionID
    public let status: ExecutionStatus
    public let assistantMessageID: MessageID?
    public let answer: SessionPayloadReference?
    public let visibleThinking: SessionPayloadReference?
    public let replay: SessionPayloadReference?
    public let error: SessionPayloadReference?
    public let usage: TokenUsage
    public init(executionID: ExecutionID, status: ExecutionStatus, assistantMessageID: MessageID? = nil,
                answer: SessionPayloadReference? = nil, visibleThinking: SessionPayloadReference? = nil,
                replay: SessionPayloadReference? = nil, error: SessionPayloadReference? = nil,
                usage: TokenUsage = .init()) {
        self.executionID = executionID; self.status = status; self.assistantMessageID = assistantMessageID
        self.answer = answer; self.visibleThinking = visibleThinking; self.replay = replay
        self.error = error; self.usage = usage
    }
}

public enum SessionInvalidationReason: String, Codable, Sendable {
    case forgotten, sourceDeleted, permissionRevoked, sourceChanged
}

public struct SessionInvalidation: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let executionIDs: Set<ExecutionID>
    public let retentionGroups: Set<UUID>
    public let authorizationEpoch: UInt64
    public let reason: SessionInvalidationReason
    public init(operationID: UUID, executionIDs: Set<ExecutionID>, retentionGroups: Set<UUID>,
                authorizationEpoch: UInt64, reason: SessionInvalidationReason) {
        self.operationID = operationID; self.executionIDs = executionIDs; self.retentionGroups = retentionGroups
        self.authorizationEpoch = authorizationEpoch; self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case operationID, executionIDs, retentionGroups, authorizationEpoch, reason
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        operationID = try values.decode(UUID.self, forKey: .operationID)
        let executions = try values.decode([ExecutionID].self, forKey: .executionIDs)
        let groups = try values.decode([UUID].self, forKey: .retentionGroups)
        executionIDs = Set(executions); retentionGroups = Set(groups)
        guard executions.count == executionIDs.count, groups.count == retentionGroups.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "The session invalidation contains duplicate identities."))
        }
        authorizationEpoch = try values.decode(UInt64.self, forKey: .authorizationEpoch)
        reason = try values.decode(SessionInvalidationReason.self, forKey: .reason)
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(operationID, forKey: .operationID)
        // Hashes and idempotent batch comparisons must survive decoding in another process.
        try values.encode(executionIDs.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }, forKey: .executionIDs)
        try values.encode(retentionGroups.sorted { $0.uuidString < $1.uuidString }, forKey: .retentionGroups)
        try values.encode(authorizationEpoch, forKey: .authorizationEpoch)
        try values.encode(reason, forKey: .reason)
    }
}

/// Clears generated payloads from an unsuccessful execution when its question is
/// retried. The execution remains in the journal as content-free provenance; the
/// retry owns the only live answer for that user message.
public struct SessionRetryCleanup: Codable, Sendable, Equatable {
    public let sourceExecutionID: ExecutionID
    public let retryExecutionID: ExecutionID
    public let retentionGroups: Set<UUID>

    public init(sourceExecutionID: ExecutionID, retryExecutionID: ExecutionID, retentionGroups: Set<UUID>) {
        self.sourceExecutionID = sourceExecutionID
        self.retryExecutionID = retryExecutionID
        self.retentionGroups = retentionGroups
    }

    private enum CodingKeys: String, CodingKey { case sourceExecutionID, retryExecutionID, retentionGroups }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sourceExecutionID, forKey: .sourceExecutionID)
        try values.encode(retryExecutionID, forKey: .retryExecutionID)
        try values.encode(retentionGroups.sorted { $0.uuidString < $1.uuidString }, forKey: .retentionGroups)
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceExecutionID = try values.decode(ExecutionID.self, forKey: .sourceExecutionID)
        retryExecutionID = try values.decode(ExecutionID.self, forKey: .retryExecutionID)
        let groups = try values.decode([UUID].self, forKey: .retentionGroups)
        retentionGroups = Set(groups)
        guard groups.count == retentionGroups.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "The retry cleanup contains duplicate retention groups."))
        }
    }
}

/// Reserved facts are written only by validated kernel commands. Extension bodies cannot impersonate them.
public enum SessionFact: Codable, Sendable, Equatable {
    case opened(SessionHeader)
    case modelSelectionChanged(selection: AgentSessionModelSelection, expectedRevision: Int)
    case renamed(title: SessionPayloadReference, revision: Int)
    case archived(revision: Int)
    case admitted(SessionAdmission)
    case phaseChanged(executionID: ExecutionID, phase: ExecutionPhase)
    case attemptStarted(SessionAttempt)
    case attemptResolved(SessionAttemptResolution)
    case toolProposed(SessionInvocation)
    case toolPrepared(SessionEffectIntent)
    case toolApprovalRequested(invocationID: UUID, expiresAt: Date)
    case toolApprovalResolved(invocationID: UUID, approved: Bool)
    case toolDispatched(invocationID: UUID, authorizationEpoch: UInt64)
    case toolResolved(SessionToolResolution)
    case finished(SessionCompletion)
    case invalidated(SessionInvalidation)
    case retryCleared(SessionRetryCleanup)
    case extensionRecorded(namespace: String, schemaVersion: Int, required: Bool, body: SessionPayloadReference)

    public var payloadReferences: [SessionPayloadReference] {
        switch self {
        case .opened(let value): [value.title]
        case .modelSelectionChanged: []
        case .renamed(let title, _): [title]
        case .admitted(let value): [value.userBody, value.plan].compactMap { $0 }
        case .attemptStarted(let value): [value.request] + value.contents
        case .attemptResolved(let value): [value.output, value.error].compactMap { $0 }
        case .toolProposed(let value): [value.call]
        case .toolPrepared(let value): [value.proposal]
        case .toolResolved(let value): [value.result].compactMap { $0 }
        case .finished(let value): [value.answer, value.visibleThinking, value.replay, value.error].compactMap { $0 }
        case .extensionRecorded(_, _, _, let body): [body]
        case .archived, .phaseChanged, .toolDispatched, .toolApprovalRequested, .toolApprovalResolved,
             .invalidated, .retryCleared: []
        }
    }
}
