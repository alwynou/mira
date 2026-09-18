import Foundation

struct AgentRecoveredAttempt: Sendable, Equatable {
    let output: AgentModelOutput?
    let stream: [SessionMessageStreamRecord]
}

struct AgentFinishIntent: Sendable, Equatable {
    let executionID: ExecutionID
    let expectedAttemptID: UUID?
    let status: ExecutionStatus
    let answer: String?
    let visibleThinking: String?
    let error: MiraError?
    let usage: TokenUsage
    let recoveredAttempts: [UUID: AgentRecoveredAttempt]

    init(executionID: ExecutionID, expectedAttemptID: UUID?, status: ExecutionStatus, answer: String? = nil,
         visibleThinking: String? = nil,
         error: MiraError? = nil, usage: TokenUsage = .init(),
         recoveredAttempts: [UUID: AgentRecoveredAttempt] = [:]) {
        self.executionID = executionID; self.expectedAttemptID = expectedAttemptID
        self.status = status; self.answer = answer
        self.visibleThinking = visibleThinking; self.error = error; self.usage = usage
        self.recoveredAttempts = recoveredAttempts
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
            return await runtime.commit(id: pending.commandID) { context in
                try await Self.facts(pending, context: context, cancellationRequested: cancelled, authorizer: authorizer)
            }
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
        let cancelled = cancellationRequested || execution.phase == .cancelling
        var status: ExecutionStatus = cancelled ? .cancelled : intent.status
        var suppressContent = false
        var terminalError = intent.error
        let publishesContent = !(intent.answer?.isEmpty ?? true) || !(intent.visibleThinking?.isEmpty ?? true)
        let retainsInterruptedContent = intent.recoveredAttempts.values.contains {
            $0.output != nil || !$0.stream.isEmpty
        }
        if status == .completed || publishesContent || retainsInterruptedContent {
            let plan = try await AgentExecutionPlan.read(for: execution.admission, from: context.payloads)
            let sources = try await JournalAgentHistoryReader(payloads: context.payloads)
                .readExecutionSources(execution: execution, state: context.state, route: plan.route)
            // The latest committed request is the authorization context. Read it
            // directly so source validation keeps the same request identity checks
            // as the collector; no request payload is inferred from projections.
            if let attemptID = execution.attemptIDs.last,
               let reference = context.state.attempts[attemptID]?.attempt.request {
                let request = try SessionCodec.decode(AgentSessionRequest.self, from: await context.payloads.read(reference))
                do { try await authorizer.validate(sources, for: request.request) }
                catch let error as MiraError where error.code == .unauthorized {
                    // Definite revocation is a terminal outcome, not a retryable storage failure.
                    status = .interrupted; suppressContent = true; terminalError = error
                }
            }
        }
        let cancelling = status == .cancelled || status == .interrupted
        var facts: [SessionFact] = []
        let phase: ExecutionPhase = cancelling ? .cancelling : .settling
        if execution.phase != phase { facts.append(.phaseChanged(executionID: intent.executionID, phase: phase)) }
        for attemptID in execution.attemptIDs {
            guard let attempt = context.state.attempts[attemptID] else {
                throw MiraError(.storage, "The execution attempt is unavailable during settlement.")
            }
            if attempt.resolution == nil {
                guard status != .completed else { throw MiraError(.conflict, "A running model attempt cannot finish successfully.") }
                let recovered = suppressContent ? nil : intent.recoveredAttempts[attemptID]
                var outputReference: SessionContent?
                if let output = recovered?.output {
                    outputReference = try await context.stage(output, kind: .modelOutput)
                }
                facts.append(.attemptResolved(.init(attemptID: attemptID, status: cancelling ? .interrupted : .failed,
                    output: outputReference, usage: recovered?.output?.usage ?? .init(),
                    stream: recovered?.stream ?? [])))
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
                    facts.append(.toolResolved(.init(invocationID: invocationID, status: .cancelledBeforeDispatch,
                        error: MiraError(.cancelled, "The tool was cancelled before dispatch."))))
                } else if invocation.invocation.effect == .read {
                    facts.append(.toolResolved(.init(invocationID: invocationID, status: .interrupted,
                        error: MiraError(.interrupted, "The read tool was interrupted before its result was confirmed."))))
                } else {
                    throw MiraError(.conflict, "A dispatched write requires effect reconciliation before settlement.")
                }
            }
        }
        try intent.usage.validate(maximumTokens: TokenUsage.maximumAggregateTokens)
        var answer: SessionContent?
        var thinking: SessionContent?
        var error: SessionContent?
        if !suppressContent {
            if let value = intent.answer, !value.isEmpty {
                answer = try await context.stageBytes(Data(value.utf8), kind: .visibleAnswer)
            }
            if let value = intent.visibleThinking, !value.isEmpty {
                thinking = try await context.stageBytes(Data(value.utf8), kind: .visibleThinking)
            }
        }
        if let value = terminalError {
            error = try await context.stage(value, kind: .error)
        }
        facts.append(.finished(.init(executionID: intent.executionID, status: status,
            assistantMessageID: answer != nil || thinking != nil ? pending.messageID : nil,
            answer: answer, visibleThinking: thinking, error: error, usage: intent.usage)))
        return facts
    }
}
