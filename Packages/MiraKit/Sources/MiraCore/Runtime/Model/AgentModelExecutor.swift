import Foundation

/// These failures stop the driver. Reconciliation and settlement never repeat a model dispatch.
enum AgentDurabilityFailure: Error, Sendable, Equatable {
    case rejected(MiraError)
    case uncertain(batchID: UUID, error: MiraError)

    static func requireCommitted(_ result: SessionCommitResult) throws {
        switch result {
        case .committed: return
        case .notCommitted(let error): throw Self.rejected(error)
        case .indeterminate(let id, let error): throw Self.uncertain(batchID: id, error: error)
        }
    }
}

struct AgentModelStepResult: Sendable {
    let attemptID: UUID
    let output: AgentModelOutput
    let invocations: [SessionInvocation]
}

/// The kernel owns this executor. Drivers receive operations, never the journal or an adapter.
/// One instance belongs to one execution; actor reentrancy cannot start a second model call.
actor AgentModelExecutor {
    private let runtime: SessionRuntime
    private let libraryLease: AgentLibraryAccessLease
    private let journal: any SessionJournal
    private let payloads: any SessionContentReader
    private let scheduler: RuntimeScheduler
    private let environment: RuntimeEnvironment
    private var running = false
    private var activeAttempts: [UUID: AgentRecoveredAttempt] = [:]

    init(
        runtime: SessionRuntime, journal: any SessionJournal, payloads: any SessionContentReader,
        libraryLease: AgentLibraryAccessLease, scheduler: RuntimeScheduler, environment: RuntimeEnvironment = .init()
    ) {
        self.runtime = runtime
        self.journal = journal
        self.payloads = libraryLease.reader(from: payloads)
        self.libraryLease = libraryLease
        self.scheduler = scheduler
        self.environment = environment
    }

    func execute(
        stepIndex: Int, attemptID: UUID, build: AgentContextBuild,
        request: AgentContextRequest, route: AgentModelRoute,
        adapter: any AgentModelAdapter, toolEffects: [String: SessionEffectKind],
        authorizer: any AgentSourceAuthorizer, priority: RuntimePriority,
        timeoutMilliseconds: Int = 300_000, retryingAttemptID: UUID? = nil
    ) async throws -> AgentModelStepResult {
        guard !running else { throw MiraError(.busy, "A model operation is already running.") }
        guard (1...3_600_000).contains(timeoutMilliseconds) else {
            throw MiraError(.invalidInput, "The model timeout must be between 1 and 3,600,000 milliseconds.")
        }
        running = true
        defer { running = false }
        try Task.checkCancellation()
        try build.prepared.validate(for: route)
        guard request.destination == .model(route), adapter.identity == route.adapter, build.request == request,
            build.prepared.input.executionID == request.executionID,
            Set(build.prepared.input.tools.map(\.name)) == Set(toolEffects.keys)
        else {
            throw MiraError(.configuration, "The model operation does not match its frozen context.")
        }
        let stepID = build.prepared.input.stepID
        let state = await runtime.snapshot()
        try Self.validateActive(state, request: request)
        guard state.attempts[attemptID] == nil else {
            // A committed attempt is never a request to repeat the external call.
            throw MiraError(.conflict, "This model attempt has already been admitted.")
        }
        let admission = state.executions[request.executionID]!.admission
        guard
            let original = state.executionOrder.compactMap({ state.executions[$0]?.admission })
                .first(where: { $0.userMessageID == admission.userMessageID && $0.userBody != nil }),
            let userBody = original.userBody,
            try await payloads.read(userBody) == Data(request.userText.utf8)
        else {
            throw MiraError(.conflict, "The model input differs from the admitted user message.")
        }
        let plan = try await AgentExecutionPlan.read(for: admission, from: payloads)
        guard let frozenRoute = plan.route else {
            throw MiraError(.unsupported, "This execution has no model route.")
        }
        guard frozenRoute == route else {
            throw MiraError(.conflict, "The model route differs from the admitted route.")
        }
        let retryingAttempt: SessionAttempt?
        if let retryingAttemptID {
            guard state.executions[request.executionID]?.attemptIDs.last == retryingAttemptID,
                let previous = state.attempts[retryingAttemptID], previous.resolution?.status == .failed,
                previous.attempt.stepID == stepID, previous.attempt.stepIndex == stepIndex,
                previous.attempt.attemptIndex < plan.limits.modelRetryPolicy.maximumAttempts,
                let failureReference = previous.resolution?.error,
                previous.invocationIDs.isEmpty
            else { throw Self.invalidRetry }
            let record = try SessionCodec.decode(
                AgentModelAttemptFailureRecord.self, from: await payloads.read(failureReference))
            try record.failure.validate()
            guard !record.receivedStreamEvents, record.failure.retryAdvice != nil,
                try SessionCodec.decode(AgentSessionRequest.self, from: await payloads.read(previous.attempt.request))
                    == AgentSessionRequest(build)
            else {
                throw Self.invalidRetry
            }
            retryingAttempt = previous.attempt
        } else {
            retryingAttempt = nil
        }
        let thinkingPrefix = try await settledThinkingPrefix(state: state, executionID: request.executionID)
        let lease = try await scheduler.acquire(executionID: request.executionID, priority: priority)
        do {
            let result = try await withThrowingTaskGroup(of: AgentModelStepResult.self) { group in
                group.addTask { [environment, timeoutMilliseconds] in
                    try await environment.clock.sleep(for: .milliseconds(timeoutMilliseconds))
                    throw MiraError(.timeout, "The model operation exceeded its timeout.")
                }
                group.addTask {
                    try await self.performModel(
                        stepIndex: stepIndex, attemptID: attemptID, stepID: stepID,
                        build: build, request: request, route: route, adapter: adapter, toolEffects: toolEffects,
                        authorizer: authorizer, thinkingPrefix: thinkingPrefix,
                        retryingAttempt: retryingAttempt)
                }
                do {
                    guard let result = try await group.next() else {
                        throw MiraError(.storage, "The model operation ended without a result.")
                    }
                    group.cancelAll()
                    return result
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
            await lease.release()
            return result
        } catch {
            await lease.release()
            throw error
        }
    }

    private func performModel(
        stepIndex: Int, attemptID: UUID, stepID: UUID, build: AgentContextBuild,
        request: AgentContextRequest, route: AgentModelRoute,
        adapter: any AgentModelAdapter, toolEffects: [String: SessionEffectKind],
        authorizer: any AgentSourceAuthorizer,
        thinkingPrefix: String, retryingAttempt: SessionAttempt?
    ) async throws -> AgentModelStepResult {
        try await validateDispatch(request, sources: build.sources, authorizer: authorizer)
        let start = await runtime.commit(id: attemptID) { context in
            try Self.validateActive(context.state, request: request)
            guard context.state.attempts[attemptID] == nil else {
                throw MiraError(.conflict, "This model attempt has already been admitted.")
            }
            let payload: SessionContent
            if let retryingAttempt {
                guard context.state.executions[request.executionID]?.attemptIDs.last == retryingAttempt.id,
                    context.state.attempts[retryingAttempt.id]?.resolution?.status == .failed
                else { throw Self.invalidRetry }
                payload = retryingAttempt.request
            } else {
                payload = try await context.stage(AgentSessionRequest(build), kind: .request)
            }
            var facts: [SessionFact] = []
            if context.state.executions[request.executionID]?.phase != .preparing {
                facts.append(.phaseChanged(executionID: request.executionID, phase: .preparing))
            }
            facts.append(
                .attemptStarted(
                    .init(
                        id: attemptID, executionID: request.executionID,
                        stepID: stepID, stepIndex: stepIndex, attemptIndex: (retryingAttempt?.attemptIndex ?? 0) + 1,
                        request: payload)))
            return facts
        }
        try AgentDurabilityFailure.requireCommitted(start)
        let ownerID = environment.uuid()
        let runtime = runtime
        let visible = try await libraryLease.start {
            AgentLibraryResource(value: ownerID, cleanup: { await runtime.releaseOutput(ownerID: ownerID) })
        }
        do {
            try await runtime.beginOutput(
                ownerID: ownerID, executionID: request.executionID,
                attemptID: attemptID, authorizationEpoch: request.authorizationEpoch, lease: libraryLease)
            activeAttempts[attemptID] = .init(output: nil, stream: [])
            // Preparation, scheduler waits and disk I/O may all outlive a policy change.
            try await validateDispatch(request, sources: build.sources, authorizer: authorizer)
            var accumulator = try AgentModelAccumulator(route: route)
            var recorder = AgentSessionStreamRecorder()
            var receivedStreamEvents = false
            var visibleDirty = false
            var publishedVisible = false
            let channel = AgentModelStreamChannel()
            let owned = try await libraryLease.start {
                let operation = adapter.stream(build.prepared, route: route)
                return AgentLibraryResource(
                    value: operation,
                    cleanup: {
                        await channel.close()
                        await operation.close()
                    })
            }
            let operation = owned.value
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            for try await event in operation.events { try await channel.send(event) }
                            try Task.checkCancellation()
                            await channel.finish()
                        } catch { await channel.finish(error: error) }
                    }
                    group.addTask { [environment] in
                        do {
                            while true {
                                try await environment.clock.sleep(for: .milliseconds(100))
                                try Task.checkCancellation()
                                guard await channel.output() else { return }
                            }
                        } catch {
                            let failure: any Error =
                                Task.isCancelled || error is CancellationError
                                ? CancellationError()
                                : MiraError(.interrupted, "The model output notification timer failed.")
                            await channel.finish(error: failure)
                        }
                    }
                    do {
                        while let input = try await channel.next() {
                            try Task.checkCancellation()
                            try await validateEligibility(request)
                            var outputTick = false
                            var finishing = false
                            switch input {
                            case .event(let event):
                                receivedStreamEvents = true
                                try accumulator.consume(event)
                                try recorder.consume(event, blocks: accumulator.blocks, at: environment.now())
                                activeAttempts[attemptID] = Self.recoveredAttempt(accumulator, stream: recorder.records)
                                switch event {
                                case .blockStarted, .blockDelta, .blockFinished: visibleDirty = true
                                case .finished:
                                    finishing = true
                                    visibleDirty = true
                                default: break
                                }
                            case .output:
                                outputTick = true
                            }
                            if visibleDirty && (!publishedVisible || outputTick || finishing) {
                                let thinking = try Self.visibleThinking(accumulator, prefix: thinkingPrefix)
                                if publishedVisible || !accumulator.blocks.isEmpty || !thinking.isEmpty {
                                    _ = await runtime.publishOutput(
                                        ownerID: ownerID, answer: accumulator.text, thinking: thinking,
                                        phase: accumulator.outputPhase, toolCall: accumulator.toolCalls.last,
                                        blocks: accumulator.blocks)
                                    publishedVisible = true
                                }
                                visibleDirty = false
                            }
                        }
                        group.cancelAll()
                        await channel.close()
                        await owned.release()
                    } catch {
                        group.cancelAll()
                        await runtime.releaseOutput(ownerID: ownerID)
                        await channel.close()
                        await owned.release()
                        throw error
                    }
                }
                await owned.release()
                try Task.checkCancellation()
                let output = try accumulator.finish()
                // The resolved model output and every tool identity enter the journal together.
                let resolutionID = environment.uuid()
                let stream = recorder.records
                let invocationIDs = output.toolCalls.map { _ in environment.uuid() }
                let resolution = await runtime.commit(id: resolutionID) { context in
                    try Self.validateActive(context.state, request: request)
                    let outputRef = try await context.stage(output, kind: .modelOutput)
                    var facts: [SessionFact] = [
                        .attemptResolved(
                            .init(
                                attemptID: attemptID, status: .completed,
                                output: outputRef, usage: output.usage, stream: stream))
                    ]
                    for (order, call) in output.toolCalls.enumerated() {
                        let callRef = try await context.stage(call, kind: .toolCall)
                        facts.append(
                            .toolProposed(
                                .init(
                                    id: invocationIDs[order], attemptID: attemptID,
                                    modelOrder: order, toolName: call.name, effect: toolEffects[call.name] ?? .read,
                                    call: callRef)))
                    }
                    if !output.toolCalls.isEmpty {
                        facts.append(.phaseChanged(executionID: request.executionID, phase: .waitingForTools))
                    }
                    return facts
                }
                try AgentDurabilityFailure.requireCommitted(resolution)
                activeAttempts.removeValue(forKey: attemptID)
                let committed = await runtime.snapshot()
                let invocations = try invocationIDs.map { id in
                    guard let invocation = committed.invocations[id]?.invocation else {
                        throw MiraError(.storage, "The committed tool proposal is unavailable.")
                    }
                    return invocation
                }
                await visible.release()
                return .init(attemptID: attemptID, output: output, invocations: invocations)
            } catch {
                // A persistence fence must be reconciled as-is, never overwritten by an error batch.
                await owned.release()
                if error is AgentDurabilityFailure { throw error }
                let failure = (error as? AgentModelFailure) ?? .init(error: MiraError.safe(error))
                try failure.validate()
                recorder.fail(failure.error, at: environment.now())
                activeAttempts[attemptID] = Self.recoveredAttempt(accumulator, stream: recorder.records)
                if !Task.isCancelled, !(error is CancellationError), failure.error.code != .cancelled {
                    let current = await runtime.snapshot()
                    if current.attempts[attemptID]?.resolution == nil,
                        (try? Self.validateActive(current, request: request)) != nil
                    {
                        let record = AgentModelAttemptFailureRecord(
                            failure: failure, receivedStreamEvents: receivedStreamEvents)
                        let usage = accumulator.usage
                        let stream = recorder.records
                        let partial = Self.partialOutput(accumulator)
                        let resolution = await runtime.commit(id: environment.uuid()) { context in
                            try Self.validateActive(context.state, request: request)
                            let reference = try await context.stage(record, kind: .error)
                            let outputReference: SessionContent?
                            if let partial {
                                outputReference = try await context.stage(partial, kind: .modelOutput)
                            } else {
                                outputReference = nil
                            }
                            return [
                                .attemptResolved(
                                    .init(attemptID: attemptID, status: .failed, output: outputReference,
                                         error: reference, usage: usage, stream: stream))
                            ]
                        }
                        try AgentDurabilityFailure.requireCommitted(resolution)
                        activeAttempts.removeValue(forKey: attemptID)
                        if !receivedStreamEvents, failure.retryAdvice != nil {
                            throw AgentModelAttemptFailure(
                                attemptID: attemptID, failure: failure, receivedStreamEvents: false)
                        }
                    }
                }
                throw failure.error
            }
        } catch {
            await visible.release()
            throw error
        }
    }

    private func validateDispatch(
        _ request: AgentContextRequest, sources: [AgentSourceReference],
        authorizer: any AgentSourceAuthorizer
    ) async throws {
        try await validateEligibility(request)
        try await authorizer.validate(sources, for: request)
        try await validateEligibility(request)
    }

    private func validateEligibility(_ request: AgentContextRequest) async throws {
        try await libraryLease.check()
        try Task.checkCancellation()
        guard !(await runtime.isCancellationRequested(executionID: request.executionID)) else {
            throw CancellationError()
        }
        try Self.validateActive(await runtime.snapshot(), request: request)
    }

    private static func validateActive(_ state: SessionState, request: AgentContextRequest) throws {
        guard state.id == request.sessionID, state.activeExecutionID == request.executionID,
            state.header?.workspaceID == request.workspaceID,
            state.authorizationEpoch == request.authorizationEpoch,
            !state.supersededExecutionIDs.contains(request.executionID),
            let execution = state.executions[request.executionID], execution.completion == nil,
            execution.phase != .cancelling, execution.phase != .settling
        else {
            throw MiraError(.unauthorized, "The model execution is no longer authorized.")
        }
    }

    private static var invalidRetry: MiraError {
        .init(.conflict, "The model retry does not match an eligible failed attempt.")
    }

    private static func visibleThinking(_ accumulator: AgentModelAccumulator, prefix: String) throws -> String {
        let thinking = prefix + accumulator.thinkingText
        guard thinking.utf8.count <= SessionFormatLimits.maximumContentBytes else {
            throw MiraError(.outputLimit, "The execution thinking output exceeds its storage limit.")
        }
        return thinking
    }

    private static func partialOutput(_ accumulator: AgentModelAccumulator) -> AgentModelOutput? {
        guard !accumulator.blocks.isEmpty || accumulator.continuation != nil else { return nil }
        return .init(blocks: accumulator.blocks, continuation: accumulator.continuation,
                     usage: accumulator.usage, finishReason: .outputLimit)
    }

    private static func recoveredAttempt(_ accumulator: AgentModelAccumulator,
                                         stream: [SessionMessageStreamRecord]) -> AgentRecoveredAttempt {
        .init(output: partialOutput(accumulator), stream: stream)
    }

    func interruptedAttempts() async -> [UUID: AgentRecoveredAttempt] {
        let state = await runtime.snapshot()
        return activeAttempts.filter { id, _ in
            guard let attempt = state.attempts[id] else { return false }
            return attempt.resolution == nil
        }
    }

    private func settledThinkingPrefix(state: SessionState, executionID: ExecutionID) async throws -> String {
        guard let execution = state.executions[executionID] else {
            throw MiraError(.notFound, "The model execution is unavailable.")
        }
        let settled = try await SessionSettledOutput.read(
            execution: execution, attempts: state.attempts, payloads: payloads)
        let prefix = settled.thinking ?? ""
        guard prefix.utf8.count <= SessionFormatLimits.maximumContentBytes else {
            throw MiraError(.outputLimit, "The execution thinking output exceeds its storage limit.")
        }
        return prefix
    }
}
