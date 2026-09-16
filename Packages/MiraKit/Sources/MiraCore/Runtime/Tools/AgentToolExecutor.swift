import Foundation

/// Owns one execution's tool batch. Drivers cannot dispatch contributions or manufacture receipts.
actor AgentToolExecutor {
    private let runtime: SessionRuntime
    private let payloads: any SessionPayloadReader
    private let libraryLease: AgentLibraryAccessLease
    private let catalog: AgentToolCatalog
    private let policy: any AgentToolPolicy
    private let authority: any AgentEffectAuthority
    private let authorizer: any AgentSourceAuthorizer
    private let business: any AgentBusinessEffects
    private let recovery: AgentToolRecovery
    private let approvals: RuntimeApprovalService
    private let environment: RuntimeEnvironment
    private let maximumParallelTools: Int
    private var owner: (executionID: ExecutionID, task: Task<[SessionToolResolution], any Error>)?
    private var recovering = false

    init(runtime: SessionRuntime, payloads: any SessionPayloadReader, libraryLease: AgentLibraryAccessLease, catalog: AgentToolCatalog,
         policy: any AgentToolPolicy, authority: any AgentEffectAuthority, business: any AgentBusinessEffects,
         authorizer: any AgentSourceAuthorizer,
         approvals: RuntimeApprovalService, maximumParallelTools: Int, environment: RuntimeEnvironment = .init()) throws {
        guard (1...32).contains(maximumParallelTools) else { throw MiraError(.configuration, "The tool concurrency limit is invalid.") }
        self.runtime = runtime; self.payloads = libraryLease.reader(from: payloads)
        self.libraryLease = libraryLease; self.catalog = catalog; self.policy = policy
        self.authority = authority; self.business = business; self.approvals = approvals
        self.authorizer = authorizer
        self.maximumParallelTools = maximumParallelTools; self.environment = environment
        self.recovery = .init(runtime: runtime, business: business, approvals: approvals, environment: environment)
    }

    func execute(attemptID: UUID, executionID: ExecutionID) async throws -> [SessionToolResolution] {
        guard owner == nil, !recovering else { throw MiraError(.busy, "A tool batch is already running or recovering.") }
        try Task.checkCancellation()
        let state = await runtime.snapshot()
        // Reject misuse before acquiring execution ownership or scheduling recovery effects.
        try Self.validateFreshBatch(state, attemptID: attemptID, executionID: executionID)
        guard owner == nil, !recovering else { throw MiraError(.busy, "A tool batch is already running or recovering.") }
        let task = Task { try await self.run(attemptID: attemptID, executionID: executionID) }
        owner = (executionID, task)
        defer { owner = nil }
        return try await withTaskCancellationHandler {
            do { return try await task.value }
            catch {
                // An uncertain journal candidate must first be reconciled unchanged by the kernel.
                if case AgentDurabilityFailure.uncertain = error { throw error }
                // The batch's structured children have drained. Settlement owns an uncancelled task.
                let recovery = Task { try await self.settleInterrupted(executionID: executionID) }
                try await recovery.value
                throw error
            }
        } onCancel: {
            Task { try? await self.cancel(executionID: executionID) }
        }
    }

    func cancel(executionID: ExecutionID) async throws {
        guard owner?.executionID == executionID else { return }
        await runtime.requestCancellation(executionID: executionID)
        owner?.task.cancel()
        await approvals.cancel(executionID: executionID)
        try await business.fenceExecution(sessionID: runtime.id, executionID: executionID)
    }

    /// Restart and reconciliation never resume a tool body, preparation, or an old approval.
    func recover(executionID: ExecutionID) async throws {
        guard owner == nil, !recovering else { throw MiraError(.busy, "A tool batch is already running or recovering.") }
        recovering = true
        defer { recovering = false }
        let task = Task { try await self.settleInterrupted(executionID: executionID) }
        try await task.value
    }

    private func run(attemptID: UUID, executionID: ExecutionID) async throws -> [SessionToolResolution] {
        let state = await runtime.snapshot()
        try Self.validateFreshBatch(state, attemptID: attemptID, executionID: executionID)
        let attempt = state.attempts[attemptID]!
        let build = try SessionCodec.decode(AgentContextBuild.self, from: await payloads.read(attempt.attempt.request))
        guard build.request.sessionID == state.id, build.request.executionID == executionID,
              build.request.authorizationEpoch == state.authorizationEpoch,
              build.prepared.input.tools == catalog.definitions else {
            throw MiraError(.conflict, "The tool catalog differs from the frozen model request.")
        }
        let invocations = attempt.invocationIDs.compactMap { state.invocations[$0]?.invocation }
        var index = 0
        while index < invocations.count {
            try await checkEligibility(executionID, epoch: build.request.authorizationEpoch)
            let first = invocations[index]
            if catalog.entry(named: first.toolName)?.descriptor.executionMode != .parallelSafe {
                try await runOne(first, build: build)
                index += 1
                continue
            }
            // Ordered and exclusive declarations are barriers within this execution's batch.
            // Cross-session resource exclusion belongs to the contribution's transaction/resource owner.
            var end = index
            while end < invocations.count,
                  catalog.entry(named: invocations[end].toolName)?.descriptor.executionMode == .parallelSafe { end += 1 }
            let parallel = Array(invocations[index..<end])
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0
                while next < min(maximumParallelTools, parallel.count) {
                    let invocation = parallel[next]
                    group.addTask { try await self.runOne(invocation, build: build) }
                    next += 1
                }
                while try await group.next() != nil {
                    if next < parallel.count {
                        let invocation = parallel[next]
                        group.addTask { try await self.runOne(invocation, build: build) }
                        next += 1
                    }
                }
            }
            index = end
        }
        let completed = await runtime.snapshot()
        return try attempt.invocationIDs.map { id in
            guard let value = completed.invocations[id]?.resolution else { throw MiraError(.storage, "The tool batch has an unresolved invocation.") }
            return value
        }
    }

    private func runOne(_ invocation: SessionInvocation, build: AgentContextBuild) async throws {
        try await checkEligibility(build.request.executionID, epoch: build.request.authorizationEpoch)
        guard let entry = catalog.entry(named: invocation.toolName) else {
            try await resolve(invocation, status: .notFound); return
        }
        guard entry.effect == invocation.effect,
              build.prepared.input.tools.contains(entry.descriptor.definition) else {
            throw MiraError(.conflict, "The tool differs from its frozen model request.")
        }
        let call = try SessionCodec.decode(CanonicalToolCall.self, from: await payloads.read(invocation.call))
        guard call.name == invocation.toolName else { throw MiraError(.storage, "The tool call identity does not match its journal record.") }
        let arguments: JSONValue
        do { arguments = try ToolSchemaValidator.decode(call.arguments, schema: entry.descriptor.definition.inputSchema) }
        catch { try await resolve(invocation, status: .invalidArguments); return }
        let context = try await toolContext(invocation, build: build)
        let invocationPolicy = AgentToolPolicyComposition(host: policy, requirement: entry.policy)
        let proposal: AgentToolProposal
        do {
            let prepared = try await entry.tool.preparation.prepare(arguments, context: context)
            try prepared.validate()
            proposal = .init(descriptor: entry.descriptor, effect: entry.effect,
                businessNamespace: entry.businessNamespace, callDigest: invocation.call.digest,
                inheritedSources: build.sources, plan: prepared)
            try proposal.validate()
        } catch {
            try Task.checkCancellation()
            try await resolve(invocation, status: .invalidArguments); return
        }
        let authorization: AgentLibraryAuthorization
        do {
            try await authorizer.validate(proposal.sources, for: build.request)
            authorization = try await authority.authorization(for: proposal, context: context)
            guard authorization == libraryLease.authorization else {
                throw MiraError(.unauthorized, "The tool execution is no longer authorized.")
            }
        }
        catch {
            try Task.checkCancellation()
            try await resolve(invocation, status: .denied); return
        }
        try await checkEligibility(context.executionID, epoch: context.evidence.sessionAuthorizationEpoch)
        let intentCommit = await runtime.commit(id: environment.uuid()) { command in
            try Self.eligible(command.state, executionID: context.executionID, epoch: context.evidence.sessionAuthorizationEpoch)
            let reference = try await command.stage(proposal, kind: .effectIntent, retentionGroup: UUID())
            return [.toolPrepared(.init(invocationID: invocation.id, authorization: authorization, proposal: reference))]
        }
        try AgentDurabilityFailure.requireCommitted(intentCommit)
        let proof = try await proof(for: invocation.id, executionID: context.executionID)
        do {
            switch try await invocationPolicy.evaluate(proposal, context: context) {
            case .deny: try await resolve(invocation, status: .denied); return
            case .allow: break
            case .requireApproval(let prompt, let expiresAt):
                try await approvalRequested(invocation, executionID: context.executionID, expiresAt: expiresAt)
                let decision = try await approvals.request(.init(invocationID: invocation.id, executionID: context.executionID,
                    proposalHash: proof.proposal.digest, authorizationEpoch: authorization.epoch, expiresAt: expiresAt, prompt: prompt))
                try await approvalResolved(invocation, executionID: context.executionID, approved: decision == .approved)
                if decision == .denied { try await resolve(invocation, status: .denied); return }
            }
            try await checkEligibility(context.executionID, epoch: context.evidence.sessionAuthorizationEpoch)
            try await invocationPolicy.validate(proposal, context: context)
            try await authorizer.validate(proposal.sources, for: build.request)
            try await authority.validate(authorization, proposal: proposal, context: context)
        } catch {
            if error is AgentDurabilityFailure { throw error }
            try Task.checkCancellation()
            try await denyPendingApproval(invocation, executionID: context.executionID)
            try await resolve(invocation, status: .denied); return
        }
        let dispatch = await runtime.commit(id: environment.uuid()) { command in
            try Self.eligible(command.state, executionID: context.executionID, epoch: context.evidence.sessionAuthorizationEpoch)
            return [.toolDispatched(invocationID: invocation.id, authorizationEpoch: context.evidence.sessionAuthorizationEpoch)]
        }
        try AgentDurabilityFailure.requireCommitted(dispatch)
        do {
            try await checkEligibility(context.executionID, epoch: context.evidence.sessionAuthorizationEpoch)
            try await invocationPolicy.validate(proposal, context: context)
            try await authorizer.validate(proposal.sources, for: build.request)
            try await authority.validate(authorization, proposal: proposal, context: context)
        } catch {
            try Task.checkCancellation()
            try await resolve(invocation, status: .denied); return
        }
        switch entry.tool {
        case .localWrite:
            let outcome = await timed(milliseconds: entry.descriptor.timeoutMilliseconds) { await self.business.commit(proof) }
            switch outcome {
            case .success(.committed(let receipt)): try await publish(receipt, invocation: invocation)
            case .success(.notCommitted): try await resolve(invocation, status: .failed)
            case .success(.indeterminate): try await reconcile(proof, invocation: invocation, absentStatus: .failed)
            case .failure(let failure):
                // A timeout cannot permit a late local mutation after recovery reports absence.
                try await business.fenceExecution(sessionID: context.evidence.reference.sessionID, executionID: context.executionID)
                try await reconcile(proof, invocation: invocation, absentStatus: failure.status)
            }
        case .read(let tool):
            let outcome = await timed(milliseconds: entry.descriptor.timeoutMilliseconds) { try await tool.execute(proposal.plan, context: context) }
            guard try await mayPublish(outcome, invocation: invocation, proposal: proposal,
                                       context: context, authorization: authorization, policy: invocationPolicy, isRead: true) else { return }
            try await publish(outcome, invocation: invocation, descriptor: entry.descriptor, isRead: true)
        case .externalWrite(let tool):
            let outcome = await timed(milliseconds: entry.descriptor.timeoutMilliseconds) { try await tool.execute(proposal.plan, context: context) }
            guard try await mayPublish(outcome, invocation: invocation, proposal: proposal,
                                       context: context, authorization: authorization, policy: invocationPolicy, isRead: false) else { return }
            try await publish(outcome, invocation: invocation, descriptor: entry.descriptor, isRead: false)
        }
    }

    private func mayPublish(_ outcome: Result<JSONValue, BodyFailure>, invocation: SessionInvocation,
                            proposal: AgentToolProposal, context: AgentToolContext,
                            authorization: AgentLibraryAuthorization, policy: any AgentToolPolicy, isRead: Bool) async throws -> Bool {
        guard case .success = outcome else { return true }
        do {
            try await checkEligibility(context.executionID, epoch: context.evidence.sessionAuthorizationEpoch)
            try await policy.validate(proposal, context: context)
            let request = AgentContextRequest(sessionID: context.evidence.reference.sessionID,
                executionID: context.executionID, workspaceID: context.evidence.workspaceID,
                userText: context.evidence.text, authorizationEpoch: context.evidence.sessionAuthorizationEpoch,
                destination: .model(context.route))
            try await authorizer.validate(proposal.sources, for: request)
            try await authority.validate(authorization, proposal: proposal, context: context)
            try await checkEligibility(context.executionID, epoch: context.evidence.sessionAuthorizationEpoch)
            return true
        } catch {
            try Task.checkCancellation()
            try await resolve(invocation, status: .interrupted, known: isRead)
            return false
        }
    }

    private func toolContext(_ invocation: SessionInvocation, build: AgentContextBuild) async throws -> AgentToolContext {
        let state = await runtime.snapshot()
        try Self.eligible(state, executionID: build.request.executionID, epoch: build.request.authorizationEpoch)
        guard let execution = state.executions[build.request.executionID],
              let attempt = state.attempts[invocation.attemptID],
              attempt.attempt.executionID == build.request.executionID,
              attempt.attempt.stepID == build.prepared.input.stepID else {
            throw MiraError(.conflict, "The tool request differs from its admitted execution.")
        }
        let plan = try await AgentExecutionPlan.read(for: execution.admission, from: payloads)
        guard let route = plan.route else {
            throw MiraError(.conflict, "The tool request has no admitted model route.")
        }
        try build.prepared.validate(for: route)
        let evidence = try await runtime.userEvidence(executionID: build.request.executionID)
        guard build.request.destination == .model(route), evidence.workspaceID == build.request.workspaceID,
              evidence.text == build.request.userText,
              evidence.sessionAuthorizationEpoch == build.request.authorizationEpoch,
              build.request.sessionID == state.id,
              build.prepared.input.executionID == build.request.executionID,
              build.prepared.input.messages.last(where: { $0.role == .user })?.text == evidence.text,
              build.prepared.input.instructions == plan.instructions else {
            throw MiraError(.conflict, "The tool context differs from the admitted user message.")
        }
        try await checkEligibility(build.request.executionID, epoch: evidence.sessionAuthorizationEpoch)
        return .init(executionID: build.request.executionID, invocationID: invocation.id,
                     evidence: evidence, route: route)
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

    private func approvalRequested(_ invocation: SessionInvocation, executionID: ExecutionID, expiresAt: Date) async throws {
        let result = await runtime.commit(id: environment.uuid()) { command in
            var facts: [SessionFact] = [.toolApprovalRequested(invocationID: invocation.id, expiresAt: expiresAt)]
            let unresolved = command.state.invocations.values.filter { value in
                command.state.attempts[value.invocation.attemptID]?.attempt.executionID == executionID && value.resolution == nil
            }
            if unresolved.allSatisfy({ $0.invocation.id == invocation.id || ($0.approval != nil && $0.approval?.approved == nil) }),
               command.state.executions[executionID]?.phase == .waitingForTools {
                facts.append(.phaseChanged(executionID: executionID, phase: .waitingForUser))
            }
            return facts
        }
        try AgentDurabilityFailure.requireCommitted(result)
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
        if let approval, approval.approved == nil { try await approvalResolved(invocation, executionID: executionID, approved: false) }
    }

    private func resolve(_ invocation: SessionInvocation, status: ToolResultStatus, bytes: Data? = nil,
                         receipt: AgentBusinessReceiptReference? = nil, purged: Bool = false, known: Bool = true) async throws {
        let result = await runtime.commit(id: environment.uuid()) { command in
            let reference: SessionPayloadReference?
            if let bytes { reference = try await command.stageBytes(bytes, kind: .toolResult, retentionGroup: UUID()) }
            else { reference = nil }
            var facts: [SessionFact] = [.toolResolved(.init(invocationID: invocation.id, status: status, result: reference,
                businessReceipt: receipt, resultWasPurged: purged, effectIsKnown: known))]
            if let executionID = command.state.attempts[invocation.attemptID]?.attempt.executionID,
               command.state.executions[executionID]?.phase == .waitingForTools {
                let remaining = command.state.invocations.values.filter { value in
                    value.invocation.id != invocation.id && value.resolution == nil &&
                    command.state.attempts[value.invocation.attemptID]?.attempt.executionID == executionID
                }
                if !remaining.isEmpty, remaining.allSatisfy({ $0.approval != nil && $0.approval?.approved == nil }) {
                    facts.append(.phaseChanged(executionID: executionID, phase: .waitingForUser))
                }
            }
            return facts
        }
        try AgentDurabilityFailure.requireCommitted(result)
        if let receipt, case .committed(let cursor) = result { try await business.acknowledge(receipt, at: cursor) }
    }

    private func publish(_ receipt: AgentBusinessReceipt, invocation: SessionInvocation) async throws {
        try await resolve(invocation, status: .succeeded, bytes: receipt.result, receipt: receipt.reference, purged: receipt.result == nil)
    }

    private func publish(_ outcome: Result<JSONValue, BodyFailure>, invocation: SessionInvocation,
                         descriptor: AgentToolDescriptor, isRead: Bool) async throws {
        switch outcome {
        case .success(let value):
            let bytes: Data
            do {
                try ToolSchemaValidator.validate(value, schema: descriptor.outputSchema)
                bytes = try SessionCodec.encode(value)
                guard bytes.count <= descriptor.maximumResultBytes else { throw MiraError(.outputLimit, "The tool result exceeds its declared limit.") }
            } catch {
                // A malformed external result cannot prove whether the external mutation happened.
                try await resolve(invocation, status: .failed, known: isRead); return
            }
            try await resolve(invocation, status: .succeeded, bytes: bytes)
        case .failure(let failure): try await resolve(invocation, status: failure.status, known: isRead)
        }
    }

    private func reconcile(_ proof: AgentEffectProof, invocation: SessionInvocation, absentStatus: ToolResultStatus) async throws {
        switch await business.receipt(for: proof) {
        case .committed(let receipt): try await publish(receipt, invocation: invocation)
        case .absent: try await resolve(invocation, status: absentStatus)
        case .unavailable(let error): throw error
        }
    }

    private func settleInterrupted(executionID: ExecutionID) async throws {
        try await recovery.recover(executionID: executionID)
    }

    private func checkEligibility(_ executionID: ExecutionID, epoch: UInt64) async throws {
        try await libraryLease.check()
        guard !(await runtime.isCancellationRequested(executionID: executionID)) else { throw CancellationError() }
        try Self.eligible(await runtime.snapshot(), executionID: executionID, epoch: epoch)
    }
    private static func eligible(_ state: SessionState, executionID: ExecutionID, epoch: UInt64? = nil) throws {
        guard state.activeExecutionID == executionID, !state.excludedExecutionIDs.contains(executionID),
              let execution = state.executions[executionID], execution.completion == nil,
              [.waitingForTools, .waitingForUser].contains(execution.phase),
              epoch.map({ $0 == state.authorizationEpoch }) ?? true else {
            throw MiraError(.unauthorized, "The tool execution is no longer authorized.")
        }
    }

    private static func validateFreshBatch(_ state: SessionState, attemptID: UUID, executionID: ExecutionID) throws {
        try eligible(state, executionID: executionID)
        guard let attempt = state.attempts[attemptID], attempt.attempt.executionID == executionID,
              attempt.resolution?.status == .completed, !attempt.invocationIDs.isEmpty,
              attempt.invocationIDs.allSatisfy({ id in
                  guard let invocation = state.invocations[id] else { return false }
                  return invocation.intent == nil && invocation.dispatchedAt == nil && invocation.resolution == nil
              }) else { throw MiraError(.conflict, "The tool batch is missing or has already started.") }
    }

    private enum BodyFailure: Error, Sendable {
        case cancelled, timedOut, failed
        var status: ToolResultStatus { switch self { case .cancelled: .cancelled; case .timedOut: .timedOut; case .failed: .failed } }
    }
    /// Cancellation is cooperative: retain ownership and drain the losing body before returning.
    private func timed<T: Sendable>(milliseconds: Int, operation: @escaping @Sendable () async throws -> T) async -> Result<T, BodyFailure> {
        do {
            let clock = environment.clock
            let resource = try await libraryLease.start {
                let task = Task {
                    await withTaskGroup(of: Result<T, BodyFailure>.self) { group in
                        group.addTask {
                            do { try Task.checkCancellation(); return .success(try await operation()) }
                            catch is CancellationError { return .failure(.cancelled) }
                            catch { return .failure(.failed) }
                        }
                        group.addTask {
                            do { try await clock.sleep(for: .milliseconds(milliseconds)); return .failure(.timedOut) }
                            catch { return .failure(.cancelled) }
                        }
                        let result = await group.next() ?? .failure(.cancelled)
                        group.cancelAll()
                        return result
                    }
                }
                return AgentLibraryResource(value: task, cleanup: { task.cancel(); _ = await task.value })
            }
            let result = await withTaskCancellationHandler {
                await resource.value.value
            } onCancel: { resource.value.cancel() }
            await resource.release()
            return result
        } catch { return .failure(.cancelled) }
    }
}
