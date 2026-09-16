import Foundation

/// Replay is hidden execution data. Visible text has a separate deletion lifetime.
public struct AgentReplayRecord: Codable, Sendable, Equatable {
    public let messages: [AgentModelMessage]
    public let sources: [AgentSourceReference]
    public init(messages: [AgentModelMessage], sources: [AgentSourceReference]) {
        self.messages = messages; self.sources = sources
    }
}

struct AgentFinishIntent: Sendable, Equatable {
    let executionID: ExecutionID
    let expectedAttemptID: UUID?
    let status: ExecutionStatus
    let answer: String?
    let visibleThinking: String?
    let replay: AgentReplayRecord?
    let error: MiraError?
    let usage: TokenUsage

    init(executionID: ExecutionID, expectedAttemptID: UUID?, status: ExecutionStatus, answer: String? = nil,
         visibleThinking: String? = nil, replay: AgentReplayRecord? = nil,
         error: MiraError? = nil, usage: TokenUsage = .init()) {
        self.executionID = executionID; self.expectedAttemptID = expectedAttemptID
        self.status = status; self.answer = answer
        self.visibleThinking = visibleThinking; self.replay = replay; self.error = error; self.usage = usage
    }
}

/// One settlement command survives caller cancellation and retains its immutable content on I/O failure.
/// Retrying this owner can only reconcile or write the terminal batch; it has no effect adapters.
actor AgentExecutionFinalizer {
    private struct Pending: Sendable {
        let commandID: UUID
        let messageID: MessageID
        let intent: AgentFinishIntent
    }
    private let runtime: SessionRuntime
    private let authorizer: any AgentSourceAuthorizer
    private let environment: RuntimeEnvironment
    private var pending: Pending?
    private var operation: Task<SessionCommitResult, Never>?

    init(runtime: SessionRuntime, authorizer: any AgentSourceAuthorizer, environment: RuntimeEnvironment = .init()) {
        self.runtime = runtime; self.authorizer = authorizer; self.environment = environment
    }

    func finish(_ intent: AgentFinishIntent) async -> SessionCommitResult {
        if let pending, pending.intent != intent {
            return .notCommitted(.init(.conflict, "Another execution settlement is already pending."))
        }
        if pending == nil {
            pending = .init(commandID: environment.uuid(), messageID: MessageID(), intent: intent)
        }
        return await retry()
    }

    func retry() async -> SessionCommitResult {
        if let operation { return await operation.value }
        guard let pending else { return .notCommitted(.init(.notFound, "There is no pending execution settlement.")) }
        let runtime = runtime
        let authorizer = authorizer
        // This task belongs to the finalizer. Cancelling a view/driver cannot abandon a durable outcome.
        let task = Task {
            let reconciliation = await runtime.reconcile()
            if case .indeterminate = reconciliation { return reconciliation }
            let observation = await runtime.currentObservation()
            if observation.isClosing {
                let state = await runtime.snapshot()
                guard state.executions[pending.intent.executionID]?.completion != nil else {
                    return .notCommitted(.init(.interrupted, "The session runtime is closed."))
                }
                return .committed(.init(sessionID: state.id, sequence: state.sequence))
            }
            if observation.requiresReconciliation { return reconciliation }
            let cancelled = await runtime.isCancellationRequested(executionID: pending.intent.executionID)
            let result = await runtime.commit(id: pending.commandID) { context in
                try await Self.facts(pending, context: context, cancellationRequested: cancelled, authorizer: authorizer)
            }
            if case .committed = result, let attemptID = pending.intent.expectedAttemptID {
                // A stale sidecar is harmless after settlement; cleanup can be retried at startup.
                try? await runtime.removeActiveDraft(sessionID: runtime.id, attemptID: attemptID)
            }
            return result
        }
        operation = task
        let result = await task.value
        operation = nil
        // Keep the command identity after success too: a repeated finish is the same operation.
        return result
    }

    private static func facts(_ pending: Pending, context: SessionCommandContext,
                              cancellationRequested: Bool, authorizer: any AgentSourceAuthorizer) async throws -> [SessionFact] {
        let intent = pending.intent
        guard intent.status.isTerminal,
              let execution = context.state.executions[intent.executionID], execution.completion == nil,
              execution.attemptIDs.last == intent.expectedAttemptID,
              context.state.activeExecutionID == intent.executionID else {
            throw MiraError(.conflict, "The execution cannot enter terminal settlement.")
        }
        let revoked = context.state.excludedExecutionIDs.contains(intent.executionID)
        let cancelled = cancellationRequested || execution.phase == .cancelling
        var status: ExecutionStatus = revoked ? .interrupted : (cancelled ? .cancelled : intent.status)
        var suppressContent = revoked
        var terminalError = intent.error
        let activeDraft = revoked ? nil : try await SessionDraftReader.active(
            state: context.state, executionID: intent.executionID, payloads: context.payloads)
        let publishesContent = !(intent.answer?.isEmpty ?? true) || !(intent.visibleThinking?.isEmpty ?? true)
            || activeDraft?.blocks.isEmpty == false || activeDraft?.continuation != nil
        if !revoked, status == .completed || publishesContent {
            var sources: [AgentSourceReference] = []
            var contextRequest: AgentContextRequest?
            let plan = try await AgentExecutionPlan.read(for: execution.admission, from: context.payloads)
            for attemptID in execution.attemptIDs {
                guard let reference = context.state.attempts[attemptID]?.attempt.request else {
                    throw MiraError(.storage, "The execution attempt is unavailable during settlement.")
                }
                let record = try await AgentRequestRecord.read(reference, payloads: context.payloads)
                guard record.request.destination.modelRoute == plan.route,
                      record.request.workspaceID == context.state.header?.workspaceID,
                      record.request.executionID == intent.executionID, record.request.sessionID == context.state.id else {
                    throw MiraError(.storage, "The execution request evidence is inconsistent.")
                }
                sources += record.sources; contextRequest = record.request
            }
            let expectedSources = AgentContextBuild.orderedSources(sources)
            if let replay = intent.replay {
                guard AgentContextBuild.orderedSources(replay.sources) == expectedSources else {
                    throw MiraError(.unauthorized, "The execution replay sources differ from its durable requests.")
                }
            }
            if let contextRequest {
                do { try await authorizer.validate(expectedSources, for: contextRequest) }
                catch let error as MiraError where error.code == .unauthorized {
                    // Definite revocation is a terminal outcome, not a retryable storage failure.
                    status = .interrupted; suppressContent = true; terminalError = error
                }
            }
        }
        let cancelling = status == .cancelled || status == .interrupted
        var facts: [SessionFact] = []
        var terminalUsage = intent.usage
        let phase: ExecutionPhase = cancelling ? .cancelling : .settling
        if execution.phase != phase { facts.append(.phaseChanged(executionID: intent.executionID, phase: phase)) }
        for attemptID in execution.attemptIDs {
            guard let attempt = context.state.attempts[attemptID] else {
                throw MiraError(.storage, "The execution attempt is unavailable during settlement.")
            }
            if attempt.resolution == nil {
                guard status != .completed else { throw MiraError(.conflict, "A running model attempt cannot finish successfully.") }
                var output: SessionPayloadReference?
                var usage = TokenUsage()
                if !suppressContent, let draft = activeDraft, draft.attemptID == attemptID {
                    usage = draft.usage
                    terminalUsage = terminalUsage.adding(usage)
                    if !draft.blocks.isEmpty || draft.continuation != nil {
                        output = try await context.stage(AgentModelOutput(blocks: draft.blocks,
                            continuation: draft.continuation, usage: draft.usage, finishReason: .stop),
                            kind: .modelOutput, retentionGroup: UUID())
                    }
                }
                facts.append(.attemptResolved(.init(attemptID: attemptID,
                    status: cancelling ? .interrupted : .failed, output: output, usage: usage)))
            }
            for invocationID in attempt.invocationIDs {
                guard let invocation = context.state.invocations[invocationID] else {
                    throw MiraError(.storage, "The tool invocation is unavailable during settlement.")
                }
                if invocation.resolution != nil { continue }
                guard status != .completed else { throw MiraError(.conflict, "An unresolved tool cannot finish successfully.") }
                if invocation.dispatchedAt == nil {
                    if let approval = invocation.approval, approval.approved == nil {
                        facts.append(.toolApprovalResolved(invocationID: invocationID, approved: false))
                    }
                    facts.append(.toolResolved(.init(invocationID: invocationID, status: .cancelledBeforeDispatch)))
                } else if invocation.invocation.effect == .read {
                    facts.append(.toolResolved(.init(invocationID: invocationID, status: .interrupted)))
                } else {
                    throw MiraError(.conflict, "A dispatched write requires effect reconciliation before settlement.")
                }
            }
        }
        try terminalUsage.validate(maximumTokens: TokenUsage.maximumAggregateTokens)
        var answer: SessionPayloadReference?
        var thinking: SessionPayloadReference?
        var replay: SessionPayloadReference?
        var error: SessionPayloadReference?
        if !suppressContent {
            if let value = intent.answer, !value.isEmpty {
                answer = try await context.stageBytes(Data(value.utf8), kind: .visibleAnswer, retentionGroup: UUID())
            }
            if let value = intent.visibleThinking, !value.isEmpty {
                thinking = try await context.stageBytes(Data(value.utf8), kind: .visibleThinking, retentionGroup: UUID())
            }
            if status == .completed, let value = intent.replay {
                guard !value.messages.isEmpty, value.messages.count <= 256,
                      value.messages.allSatisfy({ $0.role == .assistant || $0.role == .tool }), value.sources.count <= 8_192,
                      let last = value.messages.last, last.role == .assistant, last.toolCalls.isEmpty,
                      last.text == intent.answer ?? "" else {
                    throw MiraError(.invalidInput, "The execution replay record is invalid.")
                }
                if execution.attemptIDs.isEmpty {
                    guard value.messages.count == 1, last.thinkingText.isEmpty, last.toolResults.isEmpty,
                          last.continuation == nil,
                          value.sources.isEmpty else {
                        throw MiraError(.invalidInput, "The local driver replay record is invalid.")
                    }
                } else {
                    let plan = try await AgentExecutionPlan.read(for: execution.admission, from: context.payloads)
                    guard let route = plan.route else {
                        throw MiraError(.storage, "The execution model route is unavailable.")
                    }
                    try AgentModelInput(stepID: pending.commandID, executionID: intent.executionID,
                        instructions: "", messages: value.messages, tools: []).validate(for: route)
                }
                for source in value.sources { try source.validate() }
                replay = try await AgentReplayManifest.stage(value, execution: execution, context: context)
            }
        }
        if !revoked, let value = terminalError {
            error = try await context.stage(value, kind: .error, retentionGroup: UUID())
        }
        facts.append(.finished(.init(executionID: intent.executionID, status: status,
            assistantMessageID: answer != nil || thinking != nil ? pending.messageID : nil,
            answer: answer, visibleThinking: thinking, replay: replay, error: error, usage: terminalUsage)))
        return facts
    }
}
