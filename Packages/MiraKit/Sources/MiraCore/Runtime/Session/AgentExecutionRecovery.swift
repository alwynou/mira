import Foundation

/// Completes one interrupted execution after a process restart without
/// dispatching a model or tool. The instance is intentionally bound to one
/// execution and owns the uncancelled settlement task for its lifetime.
actor AgentExecutionRecovery {
    private let executionID: ExecutionID
    private let error: MiraError?
    private let runtime: SessionRuntime
    private let journal: any SessionJournal
    private let payloads: any SessionPayloadReader
    private let business: any AgentBusinessReceipts
    private let authorizer: any AgentSourceAuthorizer
    private let environment: RuntimeEnvironment
    private let finalizer: AgentExecutionFinalizer
    private let toolRecovery: AgentToolRecovery
    private var operation: Task<SessionCommitResult, Never>?

    init(runtime: SessionRuntime, journal: any SessionJournal, payloads: any SessionPayloadReader,
         executionID: ExecutionID, business: any AgentBusinessReceipts,
         authorizer: any AgentSourceAuthorizer, error: MiraError? = nil,
         environment: RuntimeEnvironment) {
        self.executionID = executionID
        self.error = error
        self.runtime = runtime
        self.journal = journal
        self.payloads = payloads
        self.business = business
        self.authorizer = authorizer
        self.environment = environment
        self.finalizer = .init(runtime: runtime, authorizer: authorizer, environment: environment)
        self.toolRecovery = .init(runtime: runtime, business: business,
            approvals: RuntimeApprovalService(environment: environment), environment: environment)
    }

    /// Concurrent callers share one durable recovery operation. The task is
    /// owned here rather than by the caller, so cancellation cannot abandon
    /// the journal settlement.
    func settle() async -> SessionCommitResult {
        if let operation { return await operation.value }
        let task = Task { await self.performSettlement() }
        operation = task
        let result = await task.value
        operation = nil
        return result
    }

    private func performSettlement() async -> SessionCommitResult {
        let reconciliation = await runtime.reconcile()
        if case .indeterminate = reconciliation { return reconciliation }
        let observation = await runtime.currentObservation()
        if observation.isClosing {
            return .notCommitted(.init(.interrupted, "The session runtime is closing."))
        }
        if observation.requiresReconciliation { return reconciliation }
        switch reconciliation {
        case .committed, .notCommitted:
            // A definite absence of a pending batch is safe to continue from.
            // The journal may report a non-committed reconciliation even when
            // the runtime has no pending state left to resolve.
            break
        case .indeterminate:
            return reconciliation
        }

        let beforeRecovery = await runtime.snapshot()
        guard let execution = beforeRecovery.executions[executionID] else {
            return .notCommitted(.init(.notFound, "The execution is unavailable during recovery."))
        }
        if finalizerStarted {
            // Reconciliation above resolves any pending journal append; the
            // finalizer retains the original command and intent identity.
            return await finalizer.retry()
        }
        if execution.completion != nil {
            return .committed(.init(sessionID: beforeRecovery.id, sequence: beforeRecovery.sequence))
        }

        do {
            try await recoverTools()
            let state = await runtime.snapshot()
            guard let execution = state.executions[executionID] else {
                throw MiraError(.notFound, "The execution is unavailable during recovery.")
            }
            if execution.completion != nil {
                return .committed(.init(sessionID: state.id, sequence: state.sequence))
            }

            let draft = try await SessionDraftReader(journal: journal, payloads: payloads)
                .read(state: state, executionID: executionID)
            var usage: TokenUsage?
            for attemptID in execution.attemptIDs {
                if let value = state.attempts[attemptID]?.resolution?.usage {
                    usage = usage.map { $0.adding(value) } ?? value
                }
            }
            let intent = AgentFinishIntent(
                executionID: executionID,
                expectedAttemptID: execution.attemptIDs.last,
                status: .interrupted,
                answer: try Self.text(draft[.answer]),
                visibleThinking: try Self.text(draft[.thinking]),
                error: error,
                usage: usage ?? .init())
            finalizerStarted = true
            return await finalizer.finish(intent)
        } catch {
            return .notCommitted(.safe(error))
        }
    }

    private var finalizerStarted = false

    private func recoverTools() async throws {
        try await toolRecovery.recover(executionID: executionID)
    }

    private static func text(_ bytes: Data?) throws -> String? {
        guard let bytes, !bytes.isEmpty else { return nil }
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw MiraError(.storage, "The execution draft contains invalid text encoding.")
        }
        return value
    }
}
