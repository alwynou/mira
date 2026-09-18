import Foundation

/// Settles journaled tool work after interruption without a catalog, policy,
/// effect authority, library lease, or tool body. Recovery only reconciles
/// durable receipts and records terminal invocation facts.
actor AgentToolRecovery {
    private let runtime: SessionRuntime
    private let business: any AgentBusinessReceipts
    private let approvals: RuntimeApprovalService
    private let environment: RuntimeEnvironment
    private var operations: [ExecutionID: Task<Void, Error>] = [:]

    init(runtime: SessionRuntime, business: any AgentBusinessReceipts,
         approvals: RuntimeApprovalService, environment: RuntimeEnvironment) {
        self.runtime = runtime
        self.business = business
        self.approvals = approvals
        self.environment = environment
    }

    func recover(executionID: ExecutionID) async throws {
        if let operation = operations[executionID] {
            try await operation.value
            return
        }
        let operation = Task { try await self.performRecovery(executionID: executionID) }
        operations[executionID] = operation
        do {
            try await operation.value
            if operations[executionID] != nil { operations[executionID] = nil }
        } catch {
            if operations[executionID] != nil { operations[executionID] = nil }
            throw error
        }
    }

    private func performRecovery(executionID: ExecutionID) async throws {
        await approvals.cancel(executionID: executionID)
        try await business.fenceExecution(sessionID: runtime.id, executionID: executionID)
        let state = await runtime.snapshot()
        guard let execution = state.executions[executionID] else {
            throw MiraError(.notFound, "The tool execution is unavailable.")
        }
        for attemptID in execution.attemptIDs {
            for id in state.attempts[attemptID]?.invocationIDs ?? [] {
                guard let item = state.invocations[id] else {
                    throw MiraError(.storage, "The tool invocation is unavailable.")
                }
                if let resolution = item.resolution {
                    if let receipt = resolution.businessReceipt {
                        try await business.acknowledge(receipt, at: .init(sessionID: state.id, sequence: state.sequence))
                    }
                    continue
                }
                let invocation = item.invocation
                try await denyPendingApproval(invocation, executionID: executionID)
                if item.dispatchedAt == nil {
                    try await resolve(invocation, status: .cancelledBeforeDispatch,
                                      error: MiraError(.cancelled, "The tool was cancelled before dispatch."))
                } else if invocation.effect == .localWrite {
                    try await reconcile(proof(for: id, executionID: executionID), invocation: invocation,
                        absentStatus: .interrupted)
                } else {
                    try await resolve(invocation, status: .interrupted,
                                      error: MiraError(.interrupted, "The tool was interrupted before recovery could confirm its result."),
                                      known: invocation.effect == .read)
                }
            }
        }
    }

    private func proof(for invocationID: UUID, executionID: ExecutionID) async throws -> AgentEffectProof {
        let state = await runtime.snapshot()
        guard let invocation = state.invocations[invocationID], let intent = invocation.intent,
              state.attempts[invocation.invocation.attemptID]?.attempt.executionID == executionID else {
            throw MiraError(.storage, "The tool effect intent is unavailable.")
        }
        return .init(sessionID: state.id, executionID: executionID, invocationID: invocationID,
            intentBatchID: intent.batchID, intentSequence: intent.sequence,
            authorization: intent.intent.authorization, proposal: intent.intent.proposal)
    }

    private func approvalResolved(_ invocation: SessionInvocation, executionID: ExecutionID, approved: Bool) async throws {
        let result = await runtime.commit(id: environment.uuid()) { command in
            var facts: [SessionFact] = [.toolApprovalResolved(invocationID: invocation.id, approved: approved)]
            if command.state.executions[executionID]?.phase == .waitingForUser {
                facts.append(.phaseChanged(executionID: executionID, phase: .waitingForTools))
            }
            return facts
        }
        try AgentDurabilityFailure.requireCommitted(result)
    }

    private func denyPendingApproval(_ invocation: SessionInvocation, executionID: ExecutionID) async throws {
        let approval = await runtime.snapshot().invocations[invocation.id]?.approval
        if let approval, approval.approved == nil {
            try await approvalResolved(invocation, executionID: executionID, approved: false)
        }
    }

    private func resolve(_ invocation: SessionInvocation, status: ToolResultStatus, bytes: Data? = nil,
                         error: MiraError? = nil,
                         receipt: AgentBusinessReceiptReference? = nil,
                         known: Bool = true) async throws {
        let result = await runtime.commit(id: environment.uuid()) { command in
            let reference: SessionContent?
            if let bytes {
                reference = try await command.stageBytes(bytes, kind: .toolResult)
            } else {
                reference = nil
            }
            var facts: [SessionFact] = [.toolResolved(.init(invocationID: invocation.id, status: status,
                result: reference, businessReceipt: receipt, effectIsKnown: known, error: error))]
            if let executionID = command.state.attempts[invocation.attemptID]?.attempt.executionID,
               command.state.executions[executionID]?.phase == .waitingForTools {
                let remaining = command.state.invocations.values.filter { value in
                    value.invocation.id != invocation.id && value.resolution == nil &&
                    command.state.attempts[value.invocation.attemptID]?.attempt.executionID == executionID
                }
                if !remaining.isEmpty,
                   remaining.allSatisfy({ $0.approval != nil && $0.approval?.approved == nil }) {
                    facts.append(.phaseChanged(executionID: executionID, phase: .waitingForUser))
                }
            }
            return facts
        }
        try AgentDurabilityFailure.requireCommitted(result)
        if let receipt, case .committed(let cursor) = result {
            try await business.acknowledge(receipt, at: cursor)
        }
    }

    private func publish(_ receipt: AgentBusinessReceipt, invocation: SessionInvocation) async throws {
        try await resolve(invocation, status: .succeeded, bytes: receipt.result,
                          receipt: receipt.reference)
    }

    private func reconcile(_ proof: AgentEffectProof, invocation: SessionInvocation,
                           absentStatus: ToolResultStatus) async throws {
        switch await business.receipt(for: proof) {
        case .committed(let receipt):
            try await publish(receipt, invocation: invocation)
        case .absent:
            let error: MiraError
            switch absentStatus {
            case .failed: error = MiraError(.storage, "The tool effect was not committed.")
            case .interrupted: error = MiraError(.interrupted, "The tool effect could not be confirmed after interruption.")
            default: error = MiraError(.storage, "The tool effect did not produce a result.")
            }
            try await resolve(invocation, status: absentStatus, error: error)
        case .unavailable(let error):
            throw error
        }
    }
}
