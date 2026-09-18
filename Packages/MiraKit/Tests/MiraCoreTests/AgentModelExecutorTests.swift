import Foundation
import Testing
@testable import MiraCore

@Suite("Model operation")
struct AgentModelExecutorTests {
    @Test func closedSessionCannotBeReportedAsSuccessfulFinalizerCommit() async throws {
        let fixture = try await ModelOperationFixture.make()
        try await withModelOperationFixture(fixture) { fixture in
            await fixture.runtime.close()
            let finalizer = AgentExecutionFinalizer(runtime: fixture.runtime, authorizer: fixture.authority)
            let result = await finalizer.finish(.init(executionID: fixture.executionID, expectedAttemptID: nil,
                                                    status: .interrupted))
            guard case .notCommitted(let error) = result else {
                Issue.record("Closing a session was reported as a terminal commit"); return
        }
        #expect(error.code == .interrupted)
        #expect(await fixture.runtime.snapshot().executions[fixture.executionID]?.completion == nil)
        }
    }

    @Test func modelTimeoutStartsOnlyAfterSchedulerLeaseAndLeaseIsReclaimed() async throws {
        let scheduler = RuntimeScheduler(modelCapacity: 1, backgroundCapacity: 0)
        let held = try await scheduler.acquire(executionID: ExecutionID(), priority: .foreground)
        let clock = ExecutorBlockingClock()
        let fixture = try await ModelOperationFixture.make(scheduler: scheduler,
            environment: RuntimeEnvironment(sleep: { duration in try await clock.sleep(for: duration) }))
        try await withModelOperationFixture(fixture) { fixture in
            let task = Task { try await fixture.execute(timeoutMilliseconds: 1_000) }
            for _ in 0..<20 { await Task.yield() }
            #expect(await clock.started == false)
            await held.release()
            await clock.waitUntilStarted()
            _ = try await task.value
            let reclaimed = try await scheduler.acquire(executionID: ExecutionID(), priority: .foreground)
            await reclaimed.release()
        }
    }

    @Test func modelTimeoutCancelsAndDrainsStreamWithoutRedispatch() async throws {
        let clock = ExecutorFiringClock()
        let streamGate = ExecutorThrowingGate()
        let cleanupGate = ExecutorDrainGate()
        let fixture = try await ModelOperationFixture.make(environment: RuntimeEnvironment(sleep: { duration in
            try await clock.sleep(for: duration)
        }), streamGate: streamGate, cleanupGate: cleanupGate)
        try await withModelOperationFixture(fixture) { fixture in
            let task = Task { try await fixture.execute(timeoutMilliseconds: 1) }
            await clock.waitUntilStarted()
            await fixture.probe.waitUntilDispatched()
            await streamGate.waitUntilEntered()
            await streamGate.openGate()
            await cleanupGate.waitUntilEntered()
            await clock.fire()
            do {
                let unexpectedLease = try await fixture.scheduler.acquire(executionID: fixture.executionID, priority: .foreground)
                await unexpectedLease.release()
                Issue.record("Scheduler lease was released before producer cleanup drained")
            } catch let error as MiraError {
                #expect(error.code == .conflict)
        }
        #expect(await fixture.probe.isDrained == false)
        await cleanupGate.openGate()
        do {
            _ = try await task.value
            Issue.record("Timed out model unexpectedly completed")
        } catch let error as MiraError {
            #expect(error.code == .timeout)
        }
        await fixture.probe.waitUntilDrained()
        #expect(await fixture.probe.count == 1)
        #expect(await fixture.executor.interruptedAttempts()[fixture.attemptID] != nil)
        #expect(await fixture.runtime.snapshot().attempts[fixture.attemptID]?.resolution == nil)
        let reclaimed = try await fixture.scheduler.acquire(executionID: fixture.executionID, priority: .foreground)
        await reclaimed.release()
        }
    }

    @Test func laterStepPreservesVisibleThinkingAndExactOpaqueContinuation() async throws {
        let identity = AgentAdapterIdentity(id: "synthetic.model", revision: 1)
        let firstContinuation = AgentModelContinuation(adapter: identity,
            format: "synthetic.trace", payload: .object(["opaque": .string("first-signature")]), isComplete: true)
        let call = CanonicalToolCall(id: "read-first", name: "sample.read", arguments: "{}")
        let fixture = try await ModelOperationFixture.make(events: [
            .blockStarted(.init(id: "thinking", content: .thinking("First thought. "))), .continuation(firstContinuation), .blockFinished(id: "thinking"),
            .blockStarted(.init(id: "tool-0", content: .toolCall(call))), .blockFinished(id: "tool-0"), .finished(.toolCalls)
        ], withTool: true)
        try await withModelOperationFixture(fixture) { fixture in
            let first = try await fixture.execute()
            let firstState = await fixture.runtime.snapshot()
            #expect(fixture.attemptID != fixture.build.prepared.input.stepID)
            #expect(firstState.attempts[fixture.attemptID]?.attempt.stepID == fixture.build.prepared.input.stepID)
            let invocation = try #require(first.invocations.first)
            try AgentDurabilityFailure.requireCommitted(await fixture.runtime.commit(id: UUID()) { context in
                let result = try await context.stageBytes(Data("Observation".utf8), kind: .toolResult)
                let prepared = try await fixture.prepareIntent(context: context, invocation: invocation, effect: .read)
                return [prepared, .toolDispatched(invocationID: invocation.id, authorizationEpoch: 0),
                        .toolResolved(.init(invocationID: invocation.id, status: .succeeded, result: result))]
            })
            let nextContinuation = AgentModelContinuation(adapter: identity,
                format: "synthetic.trace", payload: .object(["opaque": .array([.number(42), .string("second-signature")])]), isComplete: true)
            let nextID = UUID()
            let nextStepID = UUID()
            let nextAdapter = ModelOperationAdapter(identity: identity, events: [
                .blockStarted(.init(id: "thinking", content: .thinking("Second thought."))), .continuation(nextContinuation), .blockFinished(id: "thinking"),
                .blockStarted(.init(id: "text", content: .text("Final answer"))), .blockFinished(id: "text"), .finished(.stop)
            ], terminalFailure: nil, store: fixture.store, probe: fixture.probe, attemptID: nextID, streamGate: nil, cleanupGate: nil)
            let input = AgentModelInput(stepID: nextStepID, executionID: fixture.executionID, instructions: "Answer the user.", messages: [
                .init(role: .user, blocks: [.init(id: "text", content: .text("Question"))]), first.output.message,
                .init(role: .tool, blocks: [.init(id: "result-\(call.id)", content: .toolResult(callID: call.id, text: "Observation"))])
            ], tools: fixture.build.prepared.input.tools)
            let nextBuild = AgentContextBuild(request: fixture.request, prepared: try nextAdapter.prepare(input, route: fixture.route), inheritedSources: [], evidence: [], omissions: [])
            _ = try await fixture.executor.execute(stepIndex: 2, attemptID: nextID, build: nextBuild, request: fixture.request,
                route: fixture.route, adapter: nextAdapter, toolEffects: fixture.tools, authorizer: fixture.authority, priority: .foreground)
            let state = await fixture.runtime.snapshot()
            #expect(nextID != nextStepID)
            #expect(state.attempts[nextID]?.attempt.stepID == nextStepID)
            let nextResolution = try #require(state.attempts[nextID]?.resolution)
            let nextOutput = try SessionCodec.decode(AgentModelOutput.self, from: await fixture.store.read(#require(nextResolution.output)))
            #expect(nextOutput.thinkingText == "Second thought.")
            #expect(nextOutput.text == "Final answer")
            #expect(nextOutput.continuation?.payload == nextContinuation.payload)
            let stale = await AgentExecutionFinalizer(runtime: fixture.runtime, authorizer: fixture.authority).finish(
                .init(executionID: fixture.executionID, expectedAttemptID: fixture.attemptID, status: .completed, answer: "Stale answer"))
            guard case .notCommitted(let error) = stale else { Issue.record("An old attempt finalized newer work"); return }
            #expect(error.code == .conflict)
            #expect(await fixture.runtime.snapshot().executions[fixture.executionID]?.completion == nil)
        }
    }

    @Test func requestPrecedesDispatchAndToolProposalsShareOutputBatch() async throws {
        let call = CanonicalToolCall(id: "call-one", name: "sample.read", arguments: "{\"id\":\"one\"}")
        let fixture = try await ModelOperationFixture.make(events: [
            .blockStarted(.init(id: "text", content: .text("Checking"))), .blockFinished(id: "text"),
            .blockStarted(.init(id: "tool-0", content: .toolCall(call))), .blockFinished(id: "tool-0"), .finished(.toolCalls)
        ], withTool: true)
        try await withModelOperationFixture(fixture) { fixture in
            let result = try await fixture.execute()
            #expect(await fixture.probe.count == 1)
            #expect(await fixture.probe.requestWasDurable)
            #expect(await fixture.executor.interruptedAttempts().isEmpty)
            #expect(result.invocations.count == 1)
            let state = await fixture.runtime.snapshot()
            #expect(state.executions[fixture.executionID]?.phase == .waitingForTools)
            let batch = try #require(await fixture.store.allBatches().first { batch in
                batch.events.contains { if case .attemptResolved = $0.fact { return true }; return false }
            })
            #expect(batch.events.contains { if case .toolProposed = $0.fact { return true }; return false })
            let reopened = try await SessionRuntime.open(id: state.id, journal: fixture.store, payloads: fixture.store)
            #expect(await reopened.snapshot() == state)
            do { _ = try await fixture.execute(); Issue.record("Attempt was dispatched twice") }
            catch let error as MiraError { #expect(error.code == .conflict) }
            #expect(await fixture.probe.count == 1)
        }
    }

    @Test func interruptedSmallStreamCommitsPartialOutputAndStreamOnce() async throws {
        let fixture = try await ModelOperationFixture.make(events: [.blockStarted(.init(id: "text", content: .text("Partial answer")))])
        try await withModelOperationFixture(fixture) { fixture in
            do { _ = try await fixture.execute(); Issue.record("Missing finish was accepted") }
            catch let error as MiraError { #expect(error.code == .malformedStream) }
            let state = await fixture.runtime.snapshot()
            let failed = try #require(state.attempts[fixture.attemptID]?.resolution)
            #expect(failed.status == .failed)
            let partial = try SessionCodec.decode(AgentModelOutput.self, from: await fixture.store.read(#require(failed.output)))
            #expect(partial.text == "Partial answer")
            #expect(!failed.stream.isEmpty)
            #expect(await fixture.store.allBatches().filter { batch in
                batch.events.contains { event in
                    if case .attemptResolved(let value) = event.fact { return value.attemptID == fixture.attemptID }
                    return false
                }
            }.count == 1)
            let record = try SessionCodec.decode(AgentModelAttemptFailureRecord.self,
                from: await fixture.store.read(#require(failed.error)))
            #expect(record.failure.error.code == .malformedStream)
            #expect(record.receivedStreamEvents && record.failure.retryAdvice == nil)
            let lease = try await fixture.scheduler.acquire(executionID: fixture.executionID, priority: .foreground)
            await lease.release()
            let finalizer = AgentExecutionFinalizer(runtime: fixture.runtime, authorizer: fixture.authority)
            let terminal = await finalizer.finish(.init(executionID: fixture.executionID, expectedAttemptID: fixture.attemptID, status: .interrupted, answer: "Partial answer"))
            guard case .committed = terminal else { Issue.record("Interrupted execution did not settle"); return }
            let settled = await fixture.runtime.snapshot()
            #expect(settled.attempts[fixture.attemptID]?.resolution == failed)
            #expect(settled.executions[fixture.executionID]?.completion?.status == .interrupted)
        }
    }

    @Test func uncertainStartNeverCallsAdapter() async throws {
        let fixture = try await ModelOperationFixture.make(events: [.blockStarted(.init(id: "text", content: .text("Answer"))), .blockFinished(id: "text"), .finished(.stop)])
        try await withModelOperationFixture(fixture) { fixture in
            await fixture.store.setUncertainty(.start)
            do { _ = try await fixture.execute(); Issue.record("Uncertainty was ignored") }
            catch let error as AgentDurabilityFailure {
                guard case .uncertain(let id, _) = error else { Issue.record("Expected uncertain outcome"); return }
                #expect(id == fixture.attemptID)
        }
        #expect(await fixture.probe.count == 0)
        #expect(await fixture.store.allBatches().count == 2)
        guard case .committed = await fixture.runtime.reconcile() else { Issue.record("Reconciliation failed"); return }
        do { _ = try await fixture.execute(); Issue.record("Reconciled attempt dispatched") }
        catch let error as MiraError { #expect(error.code == .conflict) }
        #expect(await fixture.probe.count == 0)
        }
    }

    @Test func uncertainResolutionRetainsOriginalOutputWithoutRedispatch() async throws {
        let fixture = try await ModelOperationFixture.make(events: [.blockStarted(.init(id: "text", content: .text("Answer"))), .blockFinished(id: "text"), .finished(.stop)])
        try await withModelOperationFixture(fixture) { fixture in
            await fixture.store.setUncertainty(.resolution)
            do { _ = try await fixture.execute(); Issue.record("Uncertainty was ignored") }
            catch let error as AgentDurabilityFailure {
                guard case .uncertain = error else { Issue.record("Expected uncertain outcome"); return }
        }
        #expect(await fixture.probe.count == 1)
        let count = await fixture.store.allBatches().count
        guard case .committed = await fixture.runtime.reconcile() else { Issue.record("Reconciliation failed"); return }
        #expect(await fixture.store.allBatches().count == count)
        #expect(await fixture.runtime.snapshot().attempts[fixture.attemptID]?.resolution?.status == .completed)
        do { _ = try await fixture.execute(); Issue.record("Model was dispatched again") }
        catch let error as MiraError { #expect(error.code == .conflict) }
        #expect(await fixture.probe.count == 1)
        }
    }

    @Test func transientFailureCannotAuthorizeRetryBeforeDrainAndDurableResolution() async throws {
        let cleanupGate = ExecutorDrainGate()
        let failure = AgentModelFailure(error: .init(.network, "Synthetic transient failure."),
            retryAdvice: .transient(minimumDelayMilliseconds: 0))
        let fixture = try await ModelOperationFixture.make(events: [], terminalFailure: failure, cleanupGate: cleanupGate)
        try await withModelOperationFixture(fixture) { fixture in
            let running = Task { try await fixture.execute() }
            await cleanupGate.waitUntilEntered()
            #expect(await fixture.runtime.snapshot().attempts[fixture.attemptID]?.resolution == nil)
            do {
                let lease = try await fixture.scheduler.acquire(executionID: fixture.executionID, priority: .foreground)
                await lease.release()
                Issue.record("A failed producer released its lease before draining")
            } catch let error as MiraError { #expect(error.code == .conflict) }
            catch { Issue.record("Unexpected scheduler error: \(error)") }
            await cleanupGate.openGate()
            do { _ = try await running.value; Issue.record("A transient failure unexpectedly succeeded") }
            catch let retry as AgentModelAttemptFailure {
                #expect(retry.attemptID == fixture.attemptID && retry.failure == failure && !retry.receivedStreamEvents)
        }
        #expect(await fixture.probe.isDrained)
        #expect(await fixture.runtime.snapshot().attempts[fixture.attemptID]?.resolution?.status == .failed)
        let released = try await fixture.scheduler.acquire(executionID: fixture.executionID, priority: .foreground)
        await released.release()
        }
    }

    @Test func uncertainFailedResolutionNeverEmitsRetryAuthorization() async throws {
        let failure = AgentModelFailure(error: .init(.network, "Synthetic transient failure."),
            retryAdvice: .transient(minimumDelayMilliseconds: 0))
        let fixture = try await ModelOperationFixture.make(events: [], terminalFailure: failure)
        try await withModelOperationFixture(fixture) { fixture in
            await fixture.store.setUncertainty(.resolution)
            do { _ = try await fixture.execute(); Issue.record("Uncertain failure was accepted") }
            catch let error as AgentDurabilityFailure {
                guard case .uncertain = error else { Issue.record("Expected uncertain failed resolution"); return }
        }
        let batchCount = await fixture.store.allBatches().count
        try AgentDurabilityFailure.requireCommitted(await fixture.runtime.reconcile())
        let finalizer = AgentExecutionFinalizer(runtime: fixture.runtime, authorizer: fixture.authority)
        try AgentDurabilityFailure.requireCommitted(await finalizer.finish(.init(executionID: fixture.executionID,
            expectedAttemptID: fixture.attemptID, status: .interrupted)))
        let state = await fixture.runtime.snapshot()
        #expect(state.attempts[fixture.attemptID]?.resolution?.status == .failed)
        #expect(state.executions[fixture.executionID]?.attemptIDs == [fixture.attemptID])
        #expect(await fixture.store.allBatches().count == batchCount + 1)
        #expect(await fixture.probe.count == 1)
        }
    }

    @Test func retryRejectsChangedRequestAndRechecksCurrentSourceAuthority() async throws {
        let failure = AgentModelFailure(error: .init(.network, "Synthetic transient failure."),
            retryAdvice: .transient(minimumDelayMilliseconds: 0))
        let fixture = try await ModelOperationFixture.make(events: [], terminalFailure: failure)
        try await withModelOperationFixture(fixture) { fixture in
            do { _ = try await fixture.execute(); Issue.record("A transient failure unexpectedly succeeded") }
            catch is AgentModelAttemptFailure {}
            let changedInput = AgentModelInput(stepID: fixture.build.prepared.input.stepID,
                executionID: fixture.executionID, instructions: "Changed instruction.",
                messages: fixture.build.prepared.input.messages, tools: fixture.build.prepared.input.tools)
            let changed = AgentContextBuild(request: fixture.request,
                prepared: try fixture.adapter.prepare(changedInput, route: fixture.route),
                inheritedSources: [], evidence: [], omissions: [])
            do {
                _ = try await fixture.executor.execute(stepIndex: 1, attemptID: UUID(), build: changed,
                    request: fixture.request, route: fixture.route, adapter: fixture.adapter, toolEffects: fixture.tools,
                    authorizer: fixture.authority, priority: .foreground, retryingAttemptID: fixture.attemptID)
                Issue.record("Retry accepted a different prepared request")
            } catch let error as MiraError { #expect(error.code == .conflict) }
            await fixture.authority.setAction(.denyAlways)
            do {
                _ = try await fixture.executor.execute(stepIndex: 1, attemptID: UUID(), build: fixture.build,
                    request: fixture.request, route: fixture.route, adapter: fixture.adapter, toolEffects: fixture.tools,
                    authorizer: fixture.authority, priority: .foreground, retryingAttemptID: fixture.attemptID)
                Issue.record("Retry dispatched after source revocation")
            } catch let error as MiraError { #expect(error.code == .unauthorized) }
            #expect(await fixture.probe.count == 1)
            #expect(await fixture.runtime.snapshot().executions[fixture.executionID]?.attemptIDs == [fixture.attemptID])
        }
    }

    @Test func cancellationOrSourceRevocationAfterRequestCommitBlocksDispatch() async throws {
        for cancel in [false, true] {
            let fixture = try await ModelOperationFixture.make(events: [.blockStarted(.init(id: "text", content: .text("Answer"))), .blockFinished(id: "text"), .finished(.stop)])
            try await withModelOperationFixture(fixture) { fixture in
                    await fixture.authority.setAction(cancel ? .cancel(fixture.runtime, fixture.executionID) : .deny)
                    do { _ = try await fixture.execute(); Issue.record("Revoked model was dispatched") }
                    catch { #expect(cancel ? error is CancellationError : (error as? MiraError)?.code == .unauthorized) }
                    #expect(await fixture.probe.count == 0)
                    #expect(await fixture.runtime.snapshot().attempts[fixture.attemptID] != nil)
                    let lease = try await fixture.scheduler.acquire(executionID: fixture.executionID, priority: .foreground)
                    await lease.release()
            }
        }
    }

    @Test func terminalUncertaintyRetriesOnlySameSettlement() async throws {
        let fixture = try await ModelOperationFixture.make(events: [.blockStarted(.init(id: "text", content: .text("Answer"))), .blockFinished(id: "text"), .finished(.stop)])
        try await withModelOperationFixture(fixture) { fixture in
            let step = try await fixture.execute()
            await fixture.store.setUncertainty(.terminal)
            let owner = AgentExecutionFinalizer(runtime: fixture.runtime, authorizer: fixture.authority)
            let intent = AgentFinishIntent(executionID: fixture.executionID, expectedAttemptID: fixture.attemptID, status: .completed, answer: step.output.text)
            guard case .indeterminate(let id, _) = await owner.finish(intent) else { Issue.record("Expected terminal uncertainty"); return }
            let batches = await fixture.store.allBatches().count
            guard case .committed = await owner.retry() else { Issue.record("Terminal reconciliation failed"); return }
            guard case .committed = await owner.finish(intent) else { Issue.record("Duplicate finish failed"); return }
            #expect(await fixture.store.allBatches().count == batches)
            #expect(await fixture.store.allBatches().filter { $0.id == id }.count == 1)
            #expect(await fixture.probe.count == 1)
            let state = await fixture.runtime.snapshot()
            let completion = try #require(state.executions[fixture.executionID]?.completion)
            #expect(completion.status == .completed)
            #expect(completion.answer?.kind == .visibleAnswer)
            let reopened = try await SessionRuntime.open(id: state.id, journal: fixture.store, payloads: fixture.store)
            #expect(await reopened.snapshot() == state)
        }
    }

    @Test func finalizerSurvivesCallerCancellationAndHonorsExecutionCancellation() async throws {
        let fixture = try await ModelOperationFixture.make(events: [.blockStarted(.init(id: "text", content: .text("Answer"))), .blockFinished(id: "text"), .finished(.stop)])
        try await withModelOperationFixture(fixture) { fixture in
            _ = try await fixture.execute()
            await fixture.runtime.requestCancellation(executionID: fixture.executionID)
            let owner = AgentExecutionFinalizer(runtime: fixture.runtime, authorizer: fixture.authority)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await owner.finish(.init(executionID: fixture.executionID, expectedAttemptID: fixture.attemptID, status: .completed, answer: "Answer"))
        }
        guard case .committed = await task.value else { Issue.record("Caller cancellation abandoned settlement"); return }
        #expect(await fixture.runtime.snapshot().executions[fixture.executionID]?.completion?.status == .cancelled)
        }
    }

    @Test func admittedRouteMismatchRejectsBeforeAdapterDispatch() async throws {
        let fixture = try await ModelOperationFixture.make(events: [.blockStarted(.init(id: "text", content: .text("Answer"))), .blockFinished(id: "text"), .finished(.stop)])
        try await withModelOperationFixture(fixture) { fixture in
            let mismatched = AgentModelRoute(id: fixture.route.id, revision: fixture.route.revision, connectionID: fixture.route.connectionID, connectionRevision: fixture.route.connectionRevision, modelDescriptorID: fixture.route.modelDescriptorID, modelRevision: fixture.route.modelRevision, modelAuthorizationRevision: fixture.route.modelAuthorizationRevision, adapter: fixture.route.adapter, invocationID: fixture.route.invocationID, invocationRevision: fixture.route.invocationRevision, endpointID: fixture.route.endpointID, modelID: "different", credential: fixture.route.credential, contextWindow: fixture.route.contextWindow, maximumOutputTokens: fixture.route.maximumOutputTokens, capabilities: fixture.route.capabilities, configuration: fixture.route.configuration, maximumInputTokens: fixture.route.maximumInputTokens)
            do { _ = try await fixture.executor.execute(stepIndex: 1, attemptID: fixture.attemptID, build: fixture.build, request: fixture.request, route: mismatched, adapter: fixture.adapter, toolEffects: fixture.tools, authorizer: fixture.authority, priority: .foreground); Issue.record("Route mismatch was accepted") }
            catch let error as MiraError { #expect(error.code == .conflict || error.code == .configuration) }
            #expect(await fixture.probe.count == 0)
        }
    }

    @Test func finalizerRejectsUnresolvedDispatchedLocalWrite() async throws {
        let call = CanonicalToolCall(id: "call-write", name: "sample.write", arguments: "{}")
        let fixture = try await ModelOperationFixture.make(events: modelToolStream([call]), withTool: true, effect: .localWrite)
        try await withModelOperationFixture(fixture) { fixture in
            let step = try await fixture.execute(); let invocation = try #require(step.invocations.first)
            let dispatched = await fixture.runtime.commit(id: UUID()) { context in
                let prepared = try await fixture.prepareIntent(context: context, invocation: invocation, effect: .localWrite)
                return [prepared, .toolDispatched(invocationID: invocation.id, authorizationEpoch: 0)]
        }
        guard case .committed = dispatched else { Issue.record("Tool dispatch did not commit"); return }
        let result = await AgentExecutionFinalizer(runtime: fixture.runtime, authorizer: fixture.authority).finish(.init(executionID: fixture.executionID, expectedAttemptID: fixture.attemptID, status: .completed, answer: step.output.text))
        guard case .notCommitted = result else { Issue.record("Finalizer settled unresolved local write"); return }
        #expect(await fixture.runtime.snapshot().executions[fixture.executionID]?.completion == nil)
        }
    }
}

private func withModelOperationFixture<T>(
    _ fixture: ModelOperationFixture,
    operation: (ModelOperationFixture) async throws -> T
) async throws -> T {
    do {
        let result = try await operation(fixture)
        await fixture.close()
        return result
    } catch {
        await fixture.close()
        throw error
    }
}

private struct ModelOperationFixture: Sendable {
    let store: ModelOperationStore
    let runtime: SessionRuntime
    let scheduler: RuntimeScheduler
    let executor: AgentModelExecutor
    let executionID: ExecutionID
    let attemptID: UUID
    let route: AgentModelRoute
    let request: AgentContextRequest
    let build: AgentContextBuild
    let adapter: ModelOperationAdapter
    let probe: ModelOperationProbe
    let authority: ModelOperationAuthority
    let tools: [String: SessionEffectKind]
    let accessFixture: ExecutorAccessFixture

    static func make(events: [AgentModelStreamEvent] = [.blockStarted(.init(id: "text", content: .text("Answer"))), .blockFinished(id: "text"), .finished(.stop)],
                     terminalFailure: AgentModelFailure? = nil,
                     withTool: Bool = false, effect: SessionEffectKind = .read,
                     scheduler: RuntimeScheduler? = nil, environment: RuntimeEnvironment = .init(),
                     streamGate: ExecutorThrowingGate? = nil, cleanupGate: ExecutorDrainGate? = nil) async throws -> Self {
        let store = ModelOperationStore(); let executionID = ExecutionID(); let stepID = UUID(); let attemptID = UUID()
        let runtime = try await SessionRuntime.open(id: ConversationID(), journal: store, payloads: store)
        let route = AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
            modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1, adapter: .init(id: "synthetic.model", revision: 1),
            invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", modelID: "fixture", credential: nil, contextWindow: 4_096, maximumOutputTokens: 512,
            capabilities: .init(streamsText: true, callsTools: true, producesThinking: true), configuration: .object([:]))
        try AgentDurabilityFailure.requireCommitted(await runtime.commit(id: UUID()) { context in
            let title = try await context.stageBytes(Data("Synthetic".utf8), kind: .title)
            let user = try await context.stageBytes(Data("Question".utf8), kind: .userText)
            let routeRef = try await context.stage(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 0, driverID: "mira.default", driverRevision: 1, instructions: "Answer the user.", limits: .init(), priority: .foreground, route: route), kind: .executionPlan)
            return [.opened(.init(workspaceID: nil, title: title)), .admitted(.init(executionID: executionID,
                userMessageID: MessageID(), userBody: user, plan: routeRef, hasModelRoute: true, authorizationEpoch: 0,
                timeZoneIdentifier: "UTC"))]
        })
        let probe = ModelOperationProbe(); let authority = ModelOperationAuthority()
        let adapter = ModelOperationAdapter(identity: route.adapter, events: events, terminalFailure: terminalFailure, store: store, probe: probe, attemptID: attemptID, streamGate: streamGate, cleanupGate: cleanupGate)
        let definitions: [ToolDefinition] = withTool ? [.init(name: "sample.read", description: "Read a synthetic record.", inputSchema: .object(["type": .string("object")])), .init(name: "sample.write", description: "Write a synthetic record.", inputSchema: .object(["type": .string("object")]))] : []
        let request = AgentContextRequest(sessionID: runtime.id, executionID: executionID, workspaceID: nil, userText: "Question", authorizationEpoch: 0, destination: .model(route))
        let input = AgentModelInput(stepID: stepID, executionID: executionID, instructions: "Answer the user.",
            messages: [.init(role: .user, blocks: [.init(id: "text", content: .text("Question"))])], tools: definitions)
        let build = AgentContextBuild(request: request, prepared: try adapter.prepare(input, route: route), inheritedSources: [], evidence: [], omissions: [])
        let runtimeScheduler = scheduler ?? RuntimeScheduler(modelCapacity: 1, backgroundCapacity: 0)
        let accessFixture = try await ExecutorAccessFixture.make()
        let libraryLease = accessFixture.lease
        return .init(store: store, runtime: runtime, scheduler: runtimeScheduler,
            executor: AgentModelExecutor(runtime: runtime, journal: store, payloads: store, libraryLease: libraryLease, scheduler: runtimeScheduler, environment: environment),
            executionID: executionID, attemptID: attemptID, route: route, request: request, build: build,
            adapter: adapter, probe: probe, authority: authority, tools: withTool ? ["sample.read": effect, "sample.write": effect] : [:], accessFixture: accessFixture)
    }

    func close() async {
        await scheduler.shutdown()
        await runtime.close()
        await accessFixture.close()
    }

    func execute(timeoutMilliseconds: Int = 300_000) async throws -> AgentModelStepResult {
        try await executor.execute(stepIndex: 1, attemptID: attemptID, build: build, request: request, route: route,
            adapter: adapter, toolEffects: tools, authorizer: authority, priority: .foreground,
            timeoutMilliseconds: timeoutMilliseconds)
    }

    func prepareIntent(context: SessionCommandContext, invocation: SessionInvocation,
                       effect: SessionEffectKind) async throws -> SessionFact {
        let descriptor = AgentToolDescriptor(definition: .init(name: invocation.toolName,
            description: "Synthetic tool", inputSchema: .object(["type": .string("object")])), revision: 1,
            outputSchema: .object(["type": .string("object")]), executionMode: .ordered,
            timeoutMilliseconds: 1_000, maximumResultBytes: 1_024)
        let proposal = AgentToolProposal(descriptor: descriptor, effect: effect,
            businessNamespace: effect == .localWrite ? "sample.write" : nil,
            callDigest: String(repeating: "a", count: 64),
            plan: .init(input: .object([:]), sources: [], targets: []))
        let proposalReference = try await context.stage(proposal, kind: .effectIntent)
        let authorization = AgentLibraryAuthorization(libraryID: runtime.id.rawValue, epoch: 0)
        return .toolPrepared(.init(invocationID: invocation.id, authorization: authorization,
            proposal: proposalReference))
    }
}

private actor ExecutorMaintenanceStore: AgentLibraryMaintenanceStore {
    let authorization: AgentLibraryAuthorization
    init(libraryID: UUID = UUID()) { authorization = .init(libraryID: libraryID, epoch: 0) }
    func state() async throws -> AgentLibraryMaintenanceState { .init(authorization: authorization, pending: nil) }
    func operation(id: UUID) async throws -> AgentLibraryMaintenanceOperation? { nil }
    func begin(_ request: AgentLibraryMaintenanceRequest, expected: AgentLibraryAuthorization) async throws -> AgentLibraryMaintenanceOperation {
        throw MiraError(.unsupported, "The executor test access store has no maintenance operation.")
    }
    func complete(_ operation: AgentLibraryMaintenanceOperation, at date: Date) async throws -> AgentLibraryMaintenanceOperation {
        throw MiraError(.unsupported, "The executor test access store has no maintenance operation.")
    }
}

private final class ExecutorAccessFixture: Sendable {
    let access: AgentLibraryAccess
    let scope: RuntimeScope
    let lease: AgentLibraryAccessLease

    static func make() async throws -> ExecutorAccessFixture {
        let store = ExecutorMaintenanceStore()
        let access = try await AgentLibraryAccess.open(store: store)
        let scope = RuntimeScope(kind: .application)
        do {
            let lease = try await access.acquire(in: scope)
            return .init(access: access, scope: scope, lease: lease)
        } catch {
            await access.close(); await scope.dispose(); throw error
        }
    }

    private init(access: AgentLibraryAccess, scope: RuntimeScope, lease: AgentLibraryAccessLease) {
        self.access = access; self.scope = scope; self.lease = lease
    }

    func close() async {
        await lease.release()
        await access.close()
        await scope.dispose()
    }

}

private struct ModelOperationAdapter: AgentModelAdapter {
    let identity: AgentAdapterIdentity
    let events: [AgentModelStreamEvent]
    let terminalFailure: AgentModelFailure?
    let store: ModelOperationStore
    let probe: ModelOperationProbe
    let attemptID: UUID
    let streamGate: ExecutorThrowingGate?
    let cleanupGate: ExecutorDrainGate?
    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        .init(adapter: identity, input: input, wirePayload: .object(["synthetic": .bool(true)]), estimatedInputTokens: 50)
    }
    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        let (operationEvents, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
        let task = Task {
            do {
                let durable = await store.allBatches().contains { batch in
                    batch.events.contains { event in
                        if case .attemptStarted(let attempt) = event.fact { return attempt.id == attemptID }
                        return false
                    }
                }
                await probe.dispatched(requestWasDurable: durable)
                if let streamGate { try await streamGate.wait() }
                for event in events { continuation.yield(event) }
                continuation.finish(throwing: terminalFailure)
                if let cleanupGate { await cleanupGate.wait() }
                await probe.drained()
            } catch {
                continuation.finish(throwing: error)
                await probe.drained()
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return .init(events: operationEvents, cancelAndDrain: { task.cancel(); await task.value })
    }
    func replay(_ messages: [AgentModelMessage], from source: AgentModelRoute, to target: AgentModelRoute,
                boundary: AgentReplayBoundary) throws -> AgentReplayDecision { .include(messages) }
}

private actor ModelOperationProbe {
    var count = 0
    var requestWasDurable = false
    var isDrained = false
    private var dispatchWaiters: [CheckedContinuation<Void, Never>] = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    func dispatched(requestWasDurable: Bool) {
        count += 1; self.requestWasDurable = requestWasDurable
        dispatchWaiters.forEach { $0.resume() }; dispatchWaiters.removeAll()
    }
    func waitUntilDispatched() async {
        if count > 0 { return }
        await withCheckedContinuation { dispatchWaiters.append($0) }
    }
    func drained() {
        isDrained = true
        drainWaiters.forEach { $0.resume() }; drainWaiters.removeAll()
    }
    func waitUntilDrained() async {
        if isDrained { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }
}

private actor ExecutorThrowingGate {
    private var open = false
    private var entered = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async throws {
        let id = UUID()
        entered = true
        entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        try await withTaskCancellationHandler(operation: {
            if Task.isCancelled { throw CancellationError() }
            if open { return }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if open { continuation.resume() }
                else { waiters[id] = continuation }
            }
        }, onCancel: {
            Task { await self.cancel(id) }
        })
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }

    func openGate() {
        open = true
        let continuations = Array(waiters.values)
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private actor ExecutorDrainGate {
    private var entered = false
    private var open = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        if !open { await withCheckedContinuation { waiters.append($0) } }
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }

    func openGate() {
        open = true
        waiters.forEach { $0.resume() }; waiters.removeAll()
    }
}

private actor ExecutorBlockingClock: RuntimeClock {
    private(set) var started = false
    private var sleeping = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var sleepers: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func sleep(for duration: Duration) async throws {
        started = true
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else {
                    sleepers[id] = continuation
                    sleeping = true
                    entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
                }
            }
        }, onCancel: {
            Task { await self.cancel(id) }
        })
    }

    func waitUntilStarted() async {
        if !sleeping { await withCheckedContinuation { entryWaiters.append($0) } }
    }

    private func cancel(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private actor ExecutorFiringClock: RuntimeClock {
    private var started = false
    private var sleeping = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var sleepers: [UUID: (duration: Duration, continuation: CheckedContinuation<Void, any Error>)] = [:]

    func sleep(for duration: Duration) async throws {
        started = true
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else {
                    sleepers[id] = (duration, continuation)
                    sleeping = true
                    entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
                }
            }
        }, onCancel: {
            Task { await self.cancel(id) }
        })
    }

    func waitUntilStarted() async {
        if !sleeping { await withCheckedContinuation { entryWaiters.append($0) } }
    }

    func fire() {
        guard let id = sleepers.min(by: { $0.value.duration < $1.value.duration })?.key,
              let sleeper = sleepers.removeValue(forKey: id) else { return }
        sleeper.continuation.resume()
    }
    private func cancel(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

private actor ModelOperationAuthority: AgentSourceAuthorizer {
    enum Action { case none, deny, denyAlways, cancel(SessionRuntime, ExecutionID) }
    var calls = 0
    var action: Action = .none
    func setAction(_ value: Action) { action = value }
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {
        calls += 1
        if case .denyAlways = action { throw MiraError(.unauthorized, "Synthetic source revocation.") }
        if calls == 2 {
            switch action {
            case .none: break
            case .deny, .denyAlways: throw MiraError(.unauthorized, "Synthetic source revocation.")
            case .cancel(let runtime, let id): await runtime.requestCancellation(executionID: id)
            }
        }
    }
}

private actor ModelOperationStore: SessionJournal, SessionContentStore {
    enum Uncertainty { case none, start, resolution, terminal }
    var uncertainty: Uncertainty = .none
    private var batches: [SessionBatch] = []
    private var bytes: [SessionContent: Data] = [:]
    func setUncertainty(_ value: Uncertainty) { uncertainty = value }
    func allBatches() -> [SessionBatch] { batches }
    func append(_ batch: SessionBatch) -> SessionAppendOutcome {
        batches.append(batch)
        let uncertain = batch.events.contains { event in
            switch (uncertainty, event.fact) {
            case (.start, .attemptStarted), (.resolution, .attemptResolved), (.terminal, .finished): return true
            default: return false
            }
        }
        if uncertain { uncertainty = .none; return .indeterminate(.init(.storage, "Synthetic uncertain commit.")) }
        return .committed(batch.cursor)
    }
    func reconcile(_ batch: SessionBatch) -> SessionAppendOutcome {
        if !batches.contains(where: { $0.id == batch.id }) { batches.append(batch) }
        return .committed(batch.cursor)
    }
    func batch(id: UUID, sessionID: ConversationID) -> SessionBatch? { batches.first { $0.id == id && $0.sessionID == sessionID } }
    func head(sessionID: ConversationID) -> SessionJournalHead {
        guard let batch = batches.filter({ $0.sessionID == sessionID }).max(by: { $0.cursor.sequence < $1.cursor.sequence }) else {
            return .init(cursor: .init(sessionID: sessionID, sequence: 0), batchID: nil)
        }
        return .init(cursor: batch.cursor, batchID: batch.id)
    }
    func read(sessionID: ConversationID, after: Int64, limit: Int) -> [SessionBatch] {
        Array(batches.filter { $0.sessionID == sessionID && $0.cursor.sequence > after }.prefix(limit))
    }
    func sessions(after: ConversationID?, limit: Int) -> [ConversationID] { Array(Set(batches.map(\.sessionID)).prefix(limit)) }
    func flush() {}
    func close() {}
    func stage(_ data: Data, sessionID: ConversationID, batchID: UUID, kind: SessionContentKind) async throws -> SessionContent {
        let reference = SessionContent(id: UUID(), kind: kind, bytes: data)
        bytes[reference] = data; return reference
    }
    func read(_ reference: SessionContent) throws -> Data {
        guard let data = bytes[reference], batches.contains(where: { $0.events.contains { $0.fact.payloadReferences.contains(reference) } }) else {
            throw MiraError(.notFound, "The synthetic payload is unavailable.")
        }
        return data
    }
}
