import Foundation

public struct AgentExecutionLimits: Codable, Sendable, Equatable {
    public let maximumSteps: Int
    public let maximumToolCalls: Int
    public let maximumParallelTools: Int
    public let maximumReservedOutputTokens: Int
    public let modelPreparationTimeoutMilliseconds: Int
    public let modelTimeoutMilliseconds: Int
    public let executionTimeoutMilliseconds: Int
    public let modelRetryPolicy: AgentModelRetryPolicy

    public init(maximumSteps: Int = 20, maximumToolCalls: Int = 32, maximumParallelTools: Int = 4,
                maximumReservedOutputTokens: Int = 32_768, modelPreparationTimeoutMilliseconds: Int = 30_000,
                modelTimeoutMilliseconds: Int = 300_000,
                executionTimeoutMilliseconds: Int = 1_200_000, modelRetryPolicy: AgentModelRetryPolicy = .init()) {
        self.maximumSteps = maximumSteps; self.maximumToolCalls = maximumToolCalls
        self.maximumParallelTools = maximumParallelTools; self.maximumReservedOutputTokens = maximumReservedOutputTokens
        self.modelPreparationTimeoutMilliseconds = modelPreparationTimeoutMilliseconds
        self.modelTimeoutMilliseconds = modelTimeoutMilliseconds; self.executionTimeoutMilliseconds = executionTimeoutMilliseconds
        self.modelRetryPolicy = modelRetryPolicy
    }

    public func validate() throws {
        try modelRetryPolicy.validate()
        guard (1...10_000).contains(maximumSteps), (0...10_000).contains(maximumToolCalls),
              (1...32).contains(maximumParallelTools), (1...TokenUsage.maximumAggregateTokens).contains(maximumReservedOutputTokens),
              (1...3_600_000).contains(modelPreparationTimeoutMilliseconds),
              (1...3_600_000).contains(modelTimeoutMilliseconds),
              (1...86_400_000).contains(executionTimeoutMilliseconds) else {
            throw MiraError(.configuration, "The execution limits are invalid.")
        }
    }
}

/// Owns one admitted execution. No driver can change its route, capability generation, or limits.
/// The application retains this owner until settlement succeeds or explicit shutdown drains it.
actor AgentExecutionKernel {
    nonisolated let request: AgentContextRequest
    private let runtime: SessionRuntime
    private let journal: any SessionJournal
    private let payloads: any SessionContentReader
    private let workPayloads: any SessionContentReader
    private let libraryLease: AgentLibraryAccessLease
    private let catalog: AgentRuntimeCatalog
    private let route: AgentModelRoute?
    private let instructions: String
    private let limits: AgentExecutionLimits
    private let priority: RuntimePriority
    private let environment: RuntimeEnvironment
    private let driver: any AgentDriver
    private let authorizer: any AgentSourceAuthorizer
    private let business: any AgentBusinessEffects
    private let modelExecutor: AgentModelExecutor
    private let toolExecutor: AgentToolExecutor
    private let tools: AgentToolCatalog
    private let finalizer: AgentExecutionFinalizer

    private enum OperationResult: Sendable { case model(AgentDriverStep), tools([ToolResultStatus]) }
    private var operation: Task<OperationResult, any Error>?
    private var runTask: Task<SessionCommitResult, Never>?
    private var lastRunResult: SessionCommitResult?
    private var acceptingOperations = false
    private var started = false
    private var resourcesReleased = false
    private var settlementStarted = false
    private var intendedCompletion: AgentDriverDecision?
    private var failure: MiraError?
    private var latestStep: AgentModelStepResult?
    private var latestStepID: UUID?
    private var toolsResolved = true
    /// Ordinary contributor output is captured on the first preparation and reused
    /// for every tool continuation in this turn.
    private var frozenContext: AgentFrozenContext?
    private var steps = 0
    private var toolCalls = 0
    private var reservedOutputTokens = 0

    /// On initialization failure the caller still owns and must release the catalog and library lease.
    init(runtime: SessionRuntime, journal: any SessionJournal, payloads: any SessionContentReader,
         libraryLease: AgentLibraryAccessLease, executionID: ExecutionID, runtimeID: UUID, catalog: AgentRuntimeCatalog,
         policy: any AgentToolPolicy, authority: any AgentEffectAuthority, business: any AgentBusinessEffects,
         authorizer: any AgentSourceAuthorizer, approvals: RuntimeApprovalService,
         scheduler: RuntimeScheduler, environment: RuntimeEnvironment = .init()) async throws {
        let workPayloads = libraryLease.reader(from: payloads)
        try await libraryLease.check()
        let state = await runtime.snapshot()
        guard state.activeExecutionID == executionID,
              let execution = state.executions[executionID], execution.phase == .queued,
              execution.attemptIDs.isEmpty, execution.completion == nil,
              let original = state.executionOrder.compactMap({ state.executions[$0]?.admission })
                .first(where: { $0.userMessageID == execution.admission.userMessageID && $0.userBody != nil }),
              let body = original.userBody,
              let text = String(data: try await workPayloads.read(body), encoding: .utf8) else {
            throw MiraError(.conflict, "Only a fresh admitted execution can start a driver.")
        }
        let plan = try await AgentExecutionPlan.read(for: execution.admission, from: workPayloads)
        guard plan.runtimeID == runtimeID, plan.catalogGeneration == catalog.generation else {
            throw MiraError(.conflict, "The execution plan belongs to another runtime generation.")
        }
        let route = plan.route, limits = plan.limits
        self.request = .init(sessionID: state.id, executionID: executionID, workspaceID: state.header?.workspaceID,
                             userText: text, authorizationEpoch: state.authorizationEpoch,
                             destination: route.map(AgentContextDestination.model) ?? .local)
        self.runtime = runtime; self.journal = journal; self.payloads = payloads; self.catalog = catalog
        self.workPayloads = workPayloads; self.libraryLease = libraryLease
        self.route = route; self.instructions = plan.instructions; self.limits = limits; self.priority = plan.priority
        self.environment = environment; self.driver = try catalog.driver(id: plan.driverID, revision: plan.driverRevision)
        self.authorizer = authorizer; self.business = business
        self.tools = try route?.capabilities.callsTools == true ? catalog.tools : AgentToolCatalog([])
        self.modelExecutor = .init(runtime: runtime, journal: journal, payloads: payloads, libraryLease: libraryLease, scheduler: scheduler, environment: environment)
        self.toolExecutor = try .init(runtime: runtime, payloads: payloads, libraryLease: libraryLease, catalog: tools, policy: policy,
            authority: authority, business: business, authorizer: authorizer, approvals: approvals,
            maximumParallelTools: limits.maximumParallelTools, environment: environment)
        self.finalizer = .init(runtime: runtime, authorizer: authorizer, environment: environment)
    }

    func run() async -> SessionCommitResult {
        if let runTask { return await runTask.value }
        if let lastRunResult { return lastRunResult }
        started = true
        let task = Task { await self.drive() }
        runTask = task
        do { try libraryLease.bindCancellation { task.cancel() } }
        catch { failure = Self.safe(error); task.cancel() }
        let result = await withTaskCancellationHandler { await task.value } onCancel: {
            Task { await self.cancel() }
        }
        runTask = nil; lastRunResult = result
        return result
    }

    /// Feedback precedes transport cancellation and durable business fencing.
    func cancel() async {
        acceptingOperations = false
        await runtime.requestCancellation(executionID: request.executionID)
        operation?.cancel(); runTask?.cancel()
        try? await toolExecutor.cancel(executionID: request.executionID)
        // Settlement retries this mandatory fence if this attempt fails.
        try? await business.fenceExecution(sessionID: request.sessionID, executionID: request.executionID)
    }

    /// No provider or tool body can run through this entry point.
    func retrySettlement() async -> SessionCommitResult {
        if let runTask { return await runTask.value }
        if let lastRunResult, case .committed = lastRunResult { return lastRunResult }
        guard started, !resourcesReleased else { return .notCommitted(.init(.conflict, "The execution has not started settlement.")) }
        let task = Task { await self.settle() }
        runTask = task
        let result = await task.value
        runTask = nil; lastRunResult = result
        return result
    }

    /// The composition owner must await this before releasing adapters or closing their stores.
    /// A failed settlement remains durable recovery work; shutdown never dispatches it again.
    func shutdown() async -> SessionCommitResult {
        if resourcesReleased, let lastRunResult { return lastRunResult }
        await cancel()
        let result = started ? await retrySettlement() : await run()
        await releaseExecutionResources()
        return result
    }

    func modelStep() async throws -> AgentDriverStep {
        do { return try await ownedModelStep() }
        catch { latch(error); throw error }
    }

    private func ownedModelStep() async throws -> AgentDriverStep {
        try requireOperationSlot()
        guard toolsResolved else { throw MiraError(.conflict, "The current tool batch must settle before another model step.") }
        guard steps < limits.maximumSteps else { throw MiraError(.outputLimit, "The execution reached its model step limit.") }
        let task = Task { OperationResult.model(try await self.performModelStep()) }
        operation = task
        defer { operation = nil }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard case .model(let step) = result else { throw MiraError(.conflict, "The execution operation returned an invalid result.") }
        return step
    }

    func executeTools(for step: AgentDriverStep) async throws -> [ToolResultStatus] {
        do { return try await ownedTools(for: step) }
        catch { latch(error); throw error }
    }

    private func ownedTools(for step: AgentDriverStep) async throws -> [ToolResultStatus] {
        try requireOperationSlot()
        guard let latestStep, latestStepID == step.id, step.output == latestStep.output,
              !toolsResolved, !latestStep.invocations.isEmpty else {
            throw MiraError(.conflict, "The tool request does not match the current model step.")
        }
        let task = Task { OperationResult.tools(try await self.performTools(latestStep)) }
        operation = task
        defer { operation = nil }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard case .tools(let results) = result else { throw MiraError(.conflict, "The execution operation returned an invalid result.") }
        return results
    }

    private func drive() async -> SessionCommitResult {
        acceptingOperations = true
        do {
            try await eligible()
            let context = AgentRunContext(kernel: self)
            let decision = try await withThrowingTaskGroup(of: AgentDriverDecision.self) { group in
                group.addTask { [driver] in try await driver.run(in: context) }
                group.addTask { [environment, limits] in
                    try await environment.clock.sleep(for: .milliseconds(limits.executionTimeoutMilliseconds))
                    let error = MiraError(.timeout, "The execution reached its time limit.")
                    await self.failOperations(error)
                    throw error
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
            guard operation == nil else { throw MiraError(.conflict, "The driver returned while an operation was still running.") }
            if let failure { throw failure }
            intendedCompletion = decision
        } catch { if failure == nil { failure = Self.safe(error) } }
        acceptingOperations = false
        if Task.isCancelled || libraryLease.isRevoked {
            await runtime.requestCancellation(executionID: request.executionID)
        }
        if let operation {
            operation.cancel()
            _ = await operation.result
            self.operation = nil
        }
        // Cancellation cannot abandon a known business effect or the terminal command.
        let settlement = Task { await self.settle() }
        return await settlement.value
    }

    private func performModelStep() async throws -> AgentDriverStep {
        try await eligible()
        guard let route else { throw MiraError(.unsupported, "This execution has no model route.") }
        let adapter = try catalog.model(identity: route.adapter)
        let stepID = environment.uuid()
        let state = await runtime.snapshot()
        let currentTrace = try await JournalAgentHistoryReader(payloads: workPayloads).readCurrentExecution(
            state: state, request: request, route: route)
        let preparation = AgentModelPreparation(runtime: runtime, payloads: workPayloads, request: request,
            instructions: instructions, currentTrace: currentTrace, frozenContext: frozenContext,
            tools: tools.definitions, route: route, adapter: adapter,
            contributors: catalog.contributors, authorizer: authorizer)
        let build = try await prepareModel(preparation, stepID: stepID)
        if frozenContext == nil {
            let contextMessages = build.prepared.input.messages.filter { $0.role == .context }
            guard contextMessages.count <= 1 else {
                throw MiraError(.malformedStream, "The model input contains multiple context messages.")
            }
            frozenContext = .init(message: contextMessages.first, evidence: build.evidence,
                                  omissions: build.omissions,
                                  sources: build.evidence.flatMap(\.sources))
        }
        try await eligible()
        steps += 1
        var attemptIndex = 0
        var retryingAttemptID: UUID?
        let output: AgentModelStepResult
        while true {
            try await eligible()
            guard route.maximumOutputTokens <= limits.maximumReservedOutputTokens - reservedOutputTokens else {
                throw MiraError(.outputLimit, "The execution reached its reserved output limit.")
            }
            // Reserve every physical attempt, including failures with unknown provider usage.
            reservedOutputTokens += route.maximumOutputTokens; attemptIndex += 1
            do {
                output = try await modelExecutor.execute(stepIndex: steps, attemptID: environment.uuid(), build: build,
                    request: request, route: route, adapter: adapter, toolEffects: tools.effects,
                    authorizer: authorizer, priority: priority, timeoutMilliseconds: limits.modelTimeoutMilliseconds,
                    retryingAttemptID: retryingAttemptID)
                break
            } catch let failed as AgentModelAttemptFailure {
                guard !failed.receivedStreamEvents, let advice = failed.failure.retryAdvice,
                      let delay = try limits.modelRetryPolicy.delayMilliseconds(afterAttempt: attemptIndex, advice: advice) else {
                    throw failed.failure.error
                }
                try await eligible()
                // execute has drained the producer and released its scheduler lease before this delay.
                try await environment.clock.sleep(for: .milliseconds(delay))
                retryingAttemptID = failed.attemptID
            }
        }
        try await eligible()
        latestStep = output; latestStepID = stepID; toolsResolved = output.invocations.isEmpty
        guard output.output.message.blocks.count <= 64, build.sources.count <= 8_192 else {
            throw MiraError(.contextLimit, "The model input exceeds its supported bounds.")
        }
        if output.invocations.isEmpty {
            try AgentModelInput(stepID: stepID, executionID: request.executionID, instructions: "",
                                messages: [output.output.message], tools: []).validate(for: route)
        }
        guard output.output.finishReason != .outputLimit else {
            throw MiraError(.outputLimit, "The model stopped at its output limit.")
        }
        guard output.invocations.count <= limits.maximumToolCalls - toolCalls else {
            throw MiraError(.outputLimit, "The execution reached its tool invocation limit.")
        }
        // A provider must not reuse a tool-call identity across continuation steps.
        // The journal-derived trace is the authority here; retaining this check on
        // the derived messages prevents a duplicate from reaching tool dispatch.
        var committedToolCallIDs = Set<String>()
        for message in currentTrace.messages {
            for block in message.blocks {
                if case .toolCall(let call) = block.content,
                   !committedToolCallIDs.insert(call.id).inserted {
                    throw MiraError(.malformedStream, "The execution history contains a duplicate tool-call identity.")
                }
            }
        }
        for call in output.output.toolCalls {
            guard committedToolCallIDs.insert(call.id).inserted else {
                throw MiraError(.malformedStream, "The model reused a tool-call identity across steps.")
            }
        }
        toolCalls += output.invocations.count
        return .init(id: stepID, output: output.output)
    }

    private func performTools(_ step: AgentModelStepResult) async throws -> [ToolResultStatus] {
        try await eligible()
        let resolutions = try await toolExecutor.execute(attemptID: step.attemptID, executionID: request.executionID)
        try await eligible()
        guard resolutions.count == step.output.toolCalls.count,
              resolutions.allSatisfy(\.effectIsKnown) else {
            throw MiraError(.interrupted, "The tool batch cannot safely continue model execution.")
        }
        let state = await runtime.snapshot()
        for (_, resolution) in zip(step.output.toolCalls, resolutions) {
            if let reference = state.invocations[resolution.invocationID]?.intent?.intent.proposal {
                let proposal = try SessionCodec.decode(AgentToolProposal.self, from: await payloads.read(reference))
                for source in proposal.plan.sources { try source.validate() }
            }
        }
        try await eligible()
        toolsResolved = true
        return resolutions.map(\.status)
    }

    /// Preparation never owns a model lease or admits an attempt. Both children remain owned
    /// until they drain, even when a contributor or pure adapter ignores cancellation.
    private func prepareModel(_ preparation: AgentModelPreparation, stepID: UUID) async throws -> AgentContextBuild {
        let build = try await withThrowingTaskGroup(of: AgentContextBuild.self) { group in
            group.addTask { [environment, limits] in
                let failure: MiraError
                do {
                    try await environment.clock.sleep(for: .milliseconds(limits.modelPreparationTimeoutMilliseconds))
                    try Task.checkCancellation()
                    failure = .init(.timeout, "The model preparation exceeded its timeout.")
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    failure = .init(.interrupted, "The model preparation timer failed.")
                }
                // Latch before draining: a late preparation cannot reopen the operation slot.
                try await self.latchPreparationFailure(failure)
                throw failure
            }
            group.addTask {
                let build = try await preparation.build(stepID: stepID)
                try await self.eligible()
                return build
            }
            do {
                guard let build = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                return build
            } catch {
                group.cancelAll()
                latch(error)
                throw self.failure ?? error
            }
        }
        if let failure { throw failure }
        try await eligible()
        return build
    }

    private func latchPreparationFailure(_ error: MiraError) throws {
        // The timer may have been cancelled while waiting to reenter this actor.
        // A preparation result already accepted by the owner must not be invalidated by that late timer.
        try Task.checkCancellation()
        latch(error)
    }

    private func settle() async -> SessionCommitResult {
        do {
            if settlementStarted {
                let result = await finalizer.retry()
                if case .committed = result { await releaseExecutionResources() }
                return result
            }
            let reconciliation = await runtime.reconcile()
            if case .indeterminate = reconciliation { return reconciliation }
            let observation = await runtime.currentObservation()
            if observation.requiresReconciliation { return reconciliation }
            // Definite absence removes the journal fence; recovery can now settle the original work.
            let observed = await runtime.snapshot()
            if observed.executions[request.executionID]?.completion != nil {
                await releaseExecutionResources()
                return .committed(.init(sessionID: observed.id, sequence: observed.sequence))
            }
            guard !observation.isClosing else {
                return .notCommitted(.init(.interrupted, "The session runtime is closed."))
            }
            try await toolExecutor.recover(executionID: request.executionID)
            let state = await runtime.snapshot()
            guard let execution = state.executions[request.executionID] else { throw MiraError(.notFound, "The execution is unavailable during settlement.") }
            let cancelled = await runtime.isCancellationRequested(executionID: request.executionID)
            var status: ExecutionStatus = cancelled ? .cancelled : .failed
            var localAnswer: String?
            if failure == nil, case .complete = intendedCompletion {
                if let latestStep, latestStep.output.toolCalls.isEmpty, toolsResolved,
                   execution.attemptIDs.last == latestStep.attemptID {
                    status = cancelled ? .cancelled : .completed
                } else {
                    failure = .init(.conflict, "The driver cannot complete an unfinished execution.")
                }
            } else if failure == nil, case .respond(let text) = intendedCompletion {
                if execution.attemptIDs.isEmpty, steps == 0, !text.isEmpty,
                   text.utf8.count <= 2_097_152 {
                    if !cancelled {
                        status = .completed; localAnswer = text
                    }
                } else {
                    failure = .init(.conflict, "A local driver response requires bounded text and no model attempts.")
                }
            } else if failure == nil, case .stop = intendedCompletion { status = .interrupted }
            let settled = try await SessionSettledOutput.read(
                execution: execution, attempts: state.attempts, payloads: workPayloads)
            // The executor owns an unresolved stream only while this process
            // is alive. It is safe to settle that in-memory prefix here; a
            // cold recovery has no executor and therefore supplies no prefix.
            let recoveredAttempts = await modelExecutor.interruptedAttempts()
            var answer = localAnswer ?? settled.answer
            var thinkingParts = settled.thinking.map { [$0] } ?? []
            // A live executor can still own the final unresolved prefix when
            // cancellation or another terminal failure reaches settlement.
            // Fold it in attempt order after committed output; a cold recovery
            // has no executor and therefore contributes no in-flight prefix.
            for attemptID in execution.attemptIDs {
                guard state.attempts[attemptID]?.resolution == nil,
                      let output = recoveredAttempts[attemptID]?.output else { continue }
                if !output.text.isEmpty { answer = output.text }
                if !output.thinkingText.isEmpty {
                    let currentBytes = thinkingParts.reduce(0) { $0 + $1.utf8.count }
                    guard currentBytes + output.thinkingText.utf8.count <= SessionFormatLimits.maximumContentBytes else {
                        throw MiraError(.outputLimit, "The settled thinking output exceeds its storage limit.")
                    }
                    thinkingParts.append(output.thinkingText)
                }
            }
            let thinking = thinkingParts.isEmpty ? nil : thinkingParts.joined()
            var usage: TokenUsage?
            for id in execution.attemptIDs {
                if let value = state.attempts[id]?.resolution?.usage { usage = usage.map { $0.adding(value) } ?? value }
            }
            // A process-local cancellation can leave the latest attempt
            // unresolved while the executor still owns provider usage. Include
            // that usage exactly once; resolved attempts are already represented
            // above and must not be counted again.
            for (attemptID, recovered) in recoveredAttempts {
                guard state.attempts[attemptID]?.resolution == nil,
                      let value = recovered.output?.usage else { continue }
                usage = usage.map { $0.adding(value) } ?? value
            }
            settlementStarted = true
            let result = await finalizer.finish(.init(executionID: request.executionID,
                expectedAttemptID: execution.attemptIDs.last, status: status, answer: answer,
                visibleThinking: thinking, error: failure, usage: usage ?? .init(),
                recoveredAttempts: recoveredAttempts))
            if case .committed = result { await releaseExecutionResources() }
            return result
        } catch { return .notCommitted(Self.safe(error)) }
    }

    private func releaseExecutionResources() async {
        resourcesReleased = true
        await libraryLease.release()
        await catalog.release()
    }

    private func requireOperationSlot() throws {
        try Task.checkCancellation()
        if let failure { throw failure }
        guard acceptingOperations, operation == nil else { throw MiraError(.conflict, "The driver operation is unavailable or already occupied.") }
    }

    /// Failure belongs to the execution, even when a custom driver catches the thrown error.
    private func latch(_ error: any Error) {
        guard acceptingOperations else { return }
        if failure == nil { failure = Self.safe(error) }
        acceptingOperations = false
        operation?.cancel()
    }

    private func failOperations(_ error: MiraError) async {
        latch(error)
        try? await business.fenceExecution(sessionID: request.sessionID, executionID: request.executionID)
    }
    private func eligible() async throws {
        try Task.checkCancellation()
        try await libraryLease.check()
        let observation = await runtime.currentObservation()
        guard !observation.isClosing, !observation.requiresReconciliation else {
            throw MiraError(.storage, "The session cannot start execution work while closing or reconciling.")
        }
        guard acceptingOperations, !(await runtime.isCancellationRequested(executionID: request.executionID)) else { throw CancellationError() }
        let state = await runtime.snapshot()
        guard state.activeExecutionID == request.executionID, state.authorizationEpoch == request.authorizationEpoch,
              state.header?.workspaceID == request.workspaceID,
              state.executions[request.executionID]?.completion == nil else {
            throw MiraError(.unauthorized, "The execution context is no longer authorized.")
        }
    }
    private static func safe(_ error: any Error) -> MiraError {
        if error is CancellationError { return .init(.cancelled, "The execution was cancelled.") }
        if let error = error as? MiraError { return error }
        if case AgentDurabilityFailure.rejected(let error) = error { return error }
        if case AgentDurabilityFailure.uncertain(_, let error) = error { return error }
        return .init(.interrupted, "The execution driver failed.")
    }
}
