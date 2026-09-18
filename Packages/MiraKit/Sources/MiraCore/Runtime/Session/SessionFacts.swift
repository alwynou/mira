import Foundation

public enum ExecutionPhase: String, Codable, Sendable {
    case queued, preparing, waitingForModel, waitingForTools, waitingForUser, settling, cancelling
}

public struct SessionHeader: Codable, Sendable, Equatable {
    public let workspaceID: WorkspaceID?
    public let title: SessionContent
    public init(workspaceID: WorkspaceID?, title: SessionContent) {
        self.workspaceID = workspaceID; self.title = title
    }
}

public struct SessionAdmission: Codable, Sendable, Equatable {
    public let executionID: ExecutionID
    public let userMessageID: MessageID
    public let retryOfExecutionID: ExecutionID?
    public let userBody: SessionContent?
    public let plan: SessionContent
    public let hasModelRoute: Bool
    public let authorizationEpoch: UInt64
    public let timeZoneIdentifier: String
    /// The selection revision observed while this admission was prepared.
    /// Admission is rejected if a concurrent selection change committed first.
    public let modelSelectionRevision: Int
    public init(executionID: ExecutionID, userMessageID: MessageID, retryOfExecutionID: ExecutionID? = nil,
                userBody: SessionContent?, plan: SessionContent, hasModelRoute: Bool, authorizationEpoch: UInt64,
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
    public let request: SessionContent
    public init(id: UUID, executionID: ExecutionID, stepID: UUID, stepIndex: Int,
                attemptIndex: Int, request: SessionContent) {
        self.id = id; self.executionID = executionID; self.stepID = stepID
        self.stepIndex = stepIndex; self.attemptIndex = attemptIndex; self.request = request
    }
}

public struct SessionAttemptResolution: Codable, Sendable, Equatable {
    public let attemptID: UUID
    public let status: AttemptStatus
    public let output: SessionContent?
    public let error: SessionContent?
    public let usage: TokenUsage
    public let stream: [SessionMessageStreamRecord]
    public init(attemptID: UUID, status: AttemptStatus, output: SessionContent? = nil,
                error: SessionContent? = nil, usage: TokenUsage = .init(),
                stream: [SessionMessageStreamRecord] = []) {
        self.attemptID = attemptID; self.status = status; self.output = output
        self.error = error; self.usage = usage
        self.stream = stream
    }
}

public enum SessionEffectKind: String, Codable, Sendable { case read, localWrite, externalWrite }

public struct SessionInvocation: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let attemptID: UUID
    public let modelOrder: Int
    public let toolName: String
    public let effect: SessionEffectKind
    public let call: SessionContent
    public init(id: UUID, attemptID: UUID, modelOrder: Int, toolName: String,
                effect: SessionEffectKind, call: SessionContent) {
        self.id = id; self.attemptID = attemptID; self.modelOrder = modelOrder
        self.toolName = toolName; self.effect = effect; self.call = call
    }
}

public struct SessionEffectIntent: Codable, Sendable, Equatable {
    public let invocationID: UUID
    public let authorization: AgentLibraryAuthorization
    public let proposal: SessionContent
    public init(invocationID: UUID, authorization: AgentLibraryAuthorization, proposal: SessionContent) {
        self.invocationID = invocationID; self.authorization = authorization; self.proposal = proposal
    }
}

public struct SessionToolResolution: Codable, Sendable, Equatable {
    public let invocationID: UUID
    public let status: ToolResultStatus
    public let result: SessionContent?
    public let businessReceipt: AgentBusinessReceiptReference?
    public let effectIsKnown: Bool
    public let error: MiraError?
    public init(invocationID: UUID, status: ToolResultStatus, result: SessionContent? = nil,
                businessReceipt: AgentBusinessReceiptReference? = nil, effectIsKnown: Bool = true,
                error: MiraError? = nil) {
        self.invocationID = invocationID; self.status = status; self.result = result
        self.businessReceipt = businessReceipt; self.effectIsKnown = effectIsKnown
        self.error = error
    }
}

public struct SessionCompletion: Codable, Sendable, Equatable {
    public let executionID: ExecutionID
    public let status: ExecutionStatus
    public let assistantMessageID: MessageID?
    public let answer: SessionContent?
    public let visibleThinking: SessionContent?
    public let error: SessionContent?
    public let usage: TokenUsage
    public init(executionID: ExecutionID, status: ExecutionStatus, assistantMessageID: MessageID? = nil,
                answer: SessionContent? = nil, visibleThinking: SessionContent? = nil,
                error: SessionContent? = nil,
                usage: TokenUsage = .init()) {
        self.executionID = executionID; self.status = status; self.assistantMessageID = assistantMessageID
        self.answer = answer; self.visibleThinking = visibleThinking
        self.error = error; self.usage = usage
    }
}

/// An explicit retry selects a new execution for the original user message.
public struct SessionRetrySupersession: Codable, Sendable, Equatable {
    public let sourceExecutionID: ExecutionID
    public let retryExecutionID: ExecutionID
    public init(sourceExecutionID: ExecutionID, retryExecutionID: ExecutionID) {
        self.sourceExecutionID = sourceExecutionID; self.retryExecutionID = retryExecutionID
    }
}

/// Reserved facts are written only by validated kernel commands. Extension bodies cannot impersonate them.
public enum SessionFact: Codable, Sendable, Equatable {
    case opened(SessionHeader)
    case modelSelectionChanged(selection: AgentSessionModelSelection, expectedRevision: Int)
    case renamed(title: SessionContent, revision: Int)
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
    case retrySuperseded(SessionRetrySupersession)
    case extensionRecorded(namespace: String, schemaVersion: Int, required: Bool, body: SessionContent)

    public var payloadReferences: [SessionContent] {
        switch self {
        case .opened(let value): [value.title]
        case .modelSelectionChanged: []
        case .renamed(let title, _): [title]
        case .admitted(let value): [value.userBody, value.plan].compactMap { $0 }
        case .attemptStarted(let value): [value.request]
        case .attemptResolved(let value): [value.output, value.error].compactMap { $0 }
        case .toolProposed(let value): [value.call]
        case .toolPrepared(let value): [value.proposal]
        case .toolResolved(let value): [value.result].compactMap { $0 }
        case .finished(let value): [value.answer, value.visibleThinking, value.error].compactMap { $0 }
        case .extensionRecorded(_, _, _, let body): [body]
        case .archived, .phaseChanged, .toolDispatched, .toolApprovalRequested, .toolApprovalResolved,
             .retrySuperseded: []
        }
    }
}
