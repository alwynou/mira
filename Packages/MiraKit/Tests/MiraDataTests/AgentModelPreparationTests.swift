import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Model preparation ownership", .timeLimit(.minutes(1)))
struct AgentModelPreparationTests {
    @Test func nonCooperativeContributorTimesOutBeforeAttemptAndReopensFailedState() async throws {
        let clock = PreparationClock(duration: .milliseconds(25))
        let contributor = BlockingPreparationContributor()
        let fixture = try await PreparationFixture.make(contributor: contributor,
            limits: .init(modelPreparationTimeoutMilliseconds: 25), environment: RuntimeEnvironment(sleep: { duration in
                try await clock.sleep(for: duration)
            }))
        let kernel = try await fixture.kernel()
        let task = Task { await kernel.run() }
        var disposal: Task<Void, Never>?
        do {
            try await contributor.waitUntilEntered()
            try await clock.waitUntilPreparationEntered()
            await clock.fire(.timeout)
            try await contributor.waitUntilCancellationObserved()
            disposal = Task { await fixture.scope.dispose() }
            try await fixture.scopeProbe.waitUntilClosing()
            #expect(await fixture.scopeProbe.completed == false)
            #expect((await fixture.runtime.snapshot()).executions[fixture.executionID]?.completion == nil)
            #expect((await fixture.runtime.snapshot()).executions[fixture.executionID]?.attemptIDs.isEmpty == true)
            #expect(await fixture.modelProbe.dispatchCount == 0)
            await contributor.release()
            let result = await task.value
            guard case .committed = result else { throw MiraError(.storage, "Preparation timeout did not settle: \(result)") }
            let state = await fixture.runtime.snapshot()
            #expect(state.executions[fixture.executionID]?.completion?.status == .failed)
            #expect(state.executions[fixture.executionID]?.attemptIDs.isEmpty == true)
            let completion = try #require(state.executions[fixture.executionID]?.completion)
            let errorReference = try #require(completion.error)
            let diagnostic = try SessionCodec.decode(MiraError.self, from: await fixture.library.read(errorReference))
            #expect(diagnostic.code == .timeout)
            #expect(diagnostic.message == "The model preparation exceeded its timeout.")
            await disposal?.value
            #expect(await fixture.scopeProbe.completed)
            let captured = state
            await fixture.shutdown(kernel, deleteDirectory: false)
            let reopenedLibrary = try FileSessionLibrary(directory: fixture.directory)
            do {
                let reopened = try await SessionRuntime.open(id: fixture.sessionID, journal: reopenedLibrary, payloads: reopenedLibrary)
                do {
                    #expect(await reopened.snapshot() == captured)
                    await reopened.close()
                    try await reopenedLibrary.close()
                } catch {
                    await reopened.close(); try? await reopenedLibrary.close(); throw error
                }
            } catch {
                try? await reopenedLibrary.close(); throw error
            }
            fixture.removeDirectory()
        } catch {
            await contributor.release()
            await kernel.cancel()
            _ = await task.value
            await disposal?.value
            await fixture.shutdown(kernel)
            throw error
        }
    }

    @Test func cancellationDoesNotSettleUntilContributorReleasesAndNeverDispatches() async throws {
        let contributor = BlockingPreparationContributor()
        let fixture = try await PreparationFixture.make(contributor: contributor)
        let kernel = try await fixture.kernel()
        let completion = PreparationCompletionProbe()
        let task = Task {
            let result = await kernel.run(); await completion.mark(); return result
        }
        do {
            try await contributor.waitUntilEntered()
            await kernel.cancel()
            #expect(await completion.done == false)
            #expect((await fixture.runtime.snapshot()).executions[fixture.executionID]?.completion == nil)
            #expect((await fixture.runtime.snapshot()).executions[fixture.executionID]?.attemptIDs.isEmpty == true)
            #expect(await fixture.modelProbe.dispatchCount == 0)
            await contributor.release()
            let result = await task.value
            guard case .committed = result else { throw MiraError(.storage, "Cancellation did not settle: \(result)") }
            #expect((await fixture.runtime.snapshot()).executions[fixture.executionID]?.completion?.status == .cancelled)
            #expect(await fixture.modelProbe.dispatchCount == 0)
        } catch {
            await contributor.release()
            await kernel.cancel()
            _ = await task.value
            await fixture.shutdown(kernel)
            throw error
        }
        await fixture.shutdown(kernel)
    }

    @Test func maintenanceRevokesBlockedPreparationAndWaitsForActualOwner() async throws {
        let contributor = BlockingPreparationContributor()
        let fixture = try await PreparationFixture.make(contributor: contributor)
        let kernel = try await fixture.kernel()
        let completion = PreparationCompletionProbe()
        let task = Task { let result = await kernel.run(); await completion.mark(); return result }
        let access = fixture.libraryAccessFixture.access
        do {
            try await contributor.waitUntilEntered()
            let before = await access.snapshot()
            #expect(before.activeLeases == 1)
            let operation = try await access.begin(.init(id: UUID(), namespace: "test.purge", revision: 1,
                scope: .library, requestedAt: Date()), expected: before.authorization)
            try await contributor.waitUntilCancellationObserved()
            #expect(await completion.done == false)
            #expect((await access.snapshot()).activeLeases == 1)
            #expect((await fixture.runtime.snapshot()).executions[fixture.executionID]?.attemptIDs.isEmpty == true)
            #expect(await fixture.modelProbe.dispatchCount == 0)
            do {
                _ = try await access.complete(operation, at: Date())
                Issue.record("Maintenance completed before the preparation owner drained.")
            } catch let error as MiraError { #expect(error.code == .busy) }
            await contributor.release()
            let result = await task.value
            guard case .committed = result else { throw MiraError(.storage, "Revoked preparation did not settle.") }
            #expect((await fixture.runtime.snapshot()).executions[fixture.executionID]?.completion?.status == .cancelled)
            #expect(await fixture.modelProbe.dispatchCount == 0)
            try await access.waitForQuiescence()
            #expect((await access.snapshot()).activeLeases == 0)
            _ = try await access.complete(operation, at: Date())
            #expect((await access.snapshot()).phase == .ready)
        } catch {
            await contributor.release(); await kernel.cancel(); _ = await task.value
            await fixture.shutdown(kernel); throw error
        }
        await fixture.shutdown(kernel)
    }

    @Test func synchronousPrepareDeadlineRespondsWithoutHoldingKernelActor() async throws {
        let prepareGate = SynchronousPrepareGate()
        let clock = PreparationClock(duration: .milliseconds(25))
        let fixture = try await PreparationFixture.make(prepareGate: prepareGate,
            limits: .init(modelPreparationTimeoutMilliseconds: 25), environment: RuntimeEnvironment(sleep: { duration in
                try await clock.sleep(for: duration)
            }))
        let kernel = try await fixture.kernel()
        let task = Task { await kernel.run() }
        do {
            try await prepareGate.waitUntilEntered()
            try await clock.waitUntilPreparationEntered()
            await clock.fire(.timeout)
            try await prepareGate.waitUntilCancellationObserved()
            #expect((await fixture.runtime.snapshot()).executions[fixture.executionID]?.attemptIDs.isEmpty == true)
            prepareGate.release()
            let result = await task.value
            guard case .committed = result else { throw MiraError(.storage, "Synchronous preparation timeout did not settle: \(result)") }
            let state = await fixture.runtime.snapshot()
            #expect(state.executions[fixture.executionID]?.completion?.status == .failed)
            #expect(state.executions[fixture.executionID]?.attemptIDs.isEmpty == true)
            let completion = try #require(state.executions[fixture.executionID]?.completion)
            let errorReference = try #require(completion.error)
            let diagnostic = try SessionCodec.decode(MiraError.self, from: await fixture.library.read(errorReference))
            #expect(diagnostic.code == .timeout)
            #expect(diagnostic.message == "The model preparation exceeded its timeout.")
            #expect(await fixture.modelProbe.dispatchCount == 0)
        } catch {
            prepareGate.release()
            await kernel.cancel()
            _ = await task.value
            await fixture.shutdown(kernel)
            throw error
        }
        await fixture.shutdown(kernel)
    }

    @Test func normalPreparationAdmitsExactlyOneAttemptAndDispatchesOnce() async throws {
        let fixture = try await PreparationFixture.make()
        let kernel = try await fixture.kernel()
        let task = Task { await kernel.run() }
        do {
            let result = await task.value
            guard case .committed = result else { throw MiraError(.storage, "Normal preparation did not settle: \(result)") }
            let state = await fixture.runtime.snapshot()
            #expect(state.executions[fixture.executionID]?.completion?.status == .completed)
            #expect(state.executions[fixture.executionID]?.attemptIDs.count == 1)
            #expect(await fixture.modelProbe.dispatchCount == 1)
        } catch {
            await kernel.cancel()
            _ = await task.value
            await fixture.shutdown(kernel)
            throw error
        }
        await fixture.shutdown(kernel)
    }

    @Test func successfulPreparationWaitsForCancelledTimerCleanupBeforeDispatch() async throws {
        let clock = PreparationCancellationClock(duration: .milliseconds(25))
        let prepareGate = SynchronousPrepareGate()
        let fixture = try await PreparationFixture.make(prepareGate: prepareGate,
            limits: .init(modelPreparationTimeoutMilliseconds: 25), environment: RuntimeEnvironment(sleep: { duration in
            try await clock.sleep(for: duration)
        }))
        let kernel = try await fixture.kernel()
        let completion = PreparationCompletionProbe()
        let task = Task {
            let result = await kernel.run(); await completion.mark(); return result
        }
        do {
            try await prepareGate.waitUntilEntered()
            try await clock.waitUntilEntered()
            prepareGate.release()
            try await clock.waitUntilCancellationObserved()
            #expect(await completion.done == false)
            #expect(await fixture.modelProbe.dispatchCount == 0)
            #expect((await fixture.runtime.snapshot()).executions[fixture.executionID]?.attemptIDs.isEmpty == true)
            await clock.releaseNormally()
            let result = await task.value
            guard case .committed = result else { throw MiraError(.storage, "Successful preparation did not settle: \(result)") }
            let state = await fixture.runtime.snapshot()
            #expect(state.executions[fixture.executionID]?.completion?.status == .completed)
            #expect(state.executions[fixture.executionID]?.attemptIDs.count == 1)
            #expect(await fixture.modelProbe.dispatchCount == 1)
        } catch {
            prepareGate.release()
            await kernel.cancel()
            await clock.releaseNormally()
            _ = await task.value
            await fixture.shutdown(kernel)
            throw error
        }
        await fixture.shutdown(kernel)
    }

    @Test func preparationTimerFailureBecomesSanitizedInterruptedFailure() async throws {
        let clock = PreparationClock(duration: .milliseconds(25))
        let contributor = BlockingPreparationContributor()
        let fixture = try await PreparationFixture.make(contributor: contributor,
            limits: .init(modelPreparationTimeoutMilliseconds: 25), environment: RuntimeEnvironment(sleep: { duration in
                try await clock.sleep(for: duration)
            }))
        let kernel = try await fixture.kernel()
        let task = Task { await kernel.run() }
        do {
            try await contributor.waitUntilEntered()
            try await clock.waitUntilPreparationEntered()
            await clock.fire(.privateFailure)
            try await contributor.waitUntilCancellationObserved()
            #expect((await fixture.runtime.snapshot()).executions[fixture.executionID]?.attemptIDs.isEmpty == true)
            await contributor.release()
            let result = await task.value
            guard case .committed = result else { throw MiraError(.storage, "Preparation timer failure did not settle: \(result)") }
            let state = await fixture.runtime.snapshot()
            #expect(state.executions[fixture.executionID]?.completion?.status == .failed)
            #expect(await fixture.modelProbe.dispatchCount == 0)
            let completion = try #require(state.executions[fixture.executionID]?.completion)
            let errorReference = try #require(completion.error)
            let diagnostic = try SessionCodec.decode(MiraError.self, from: await fixture.library.read(errorReference))
            #expect(diagnostic.code == .interrupted)
            #expect(diagnostic.message == "The model preparation timer failed.")
            #expect(!diagnostic.message.contains("private-preparation-marker"))
            let lease = try await fixture.scheduler.acquire(executionID: fixture.executionID, priority: .foreground)
            await lease.release()
        } catch {
            await contributor.release()
            await kernel.cancel()
            _ = await task.value
            await fixture.shutdown(kernel)
            throw error
        }
        await fixture.shutdown(kernel)
    }
}

private final class PreparationFixture: Sendable {
    let directory: URL
    let library: FileSessionLibrary
    let runtime: SessionRuntime
    let sessionID: ConversationID
    let executionID: ExecutionID
    let modelProbe: PreparationModelProbe
    let catalog: AgentRuntimeCatalog
    let scope: RuntimeScope
    let scopeProbe: PreparationScopeProbe
    let scheduler: RuntimeScheduler
    let adapter: PreparationAdapter
    let environment: RuntimeEnvironment
    let libraryAccessFixture: LibraryAccessFixture

    static func make(contributor: BlockingPreparationContributor? = nil,
                     prepareGate: SynchronousPrepareGate? = nil,
                     limits: AgentExecutionLimits = .init(),
                     environment: RuntimeEnvironment = .init()) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-model-preparation-\(UUID().uuidString)")
        let library = try FileSessionLibrary(directory: directory)
        var runtime: SessionRuntime?
        var scope: RuntimeScope?
        var catalog: AgentRuntimeCatalog?
        do {
            let sessionID = ConversationID(), executionID = ExecutionID()
            let opened = try await SessionRuntime.open(id: sessionID, journal: library, payloads: library, environment: environment)
            runtime = opened
            let modelProbe = PreparationModelProbe()
            let adapter = PreparationAdapter(probe: modelProbe, gate: prepareGate)
            let registry = RuntimeRegistry<AgentCapability>()
            let runtimeScope = RuntimeScope(kind: .application)
            scope = runtimeScope
            let scopeProbe = PreparationScopeProbe()
            _ = try await runtimeScope.registerClosing { await scopeProbe.beginClosing() }
            try await runtimeScope.registerCleanup { await scopeProbe.finished() }
            try await registry.register(id: "model", value: .model(adapter), scope: runtimeScope)
            if let contributor {
                try await registry.register(id: "contributor", value: .context(contributor), scope: runtimeScope)
            }
            try await registry.register(id: "driver", value: .driver(PreparationDriver()), scope: runtimeScope)
            let snapshot = try await registry.freeze()
            let runtimeCatalog: AgentRuntimeCatalog
            do {
                runtimeCatalog = try AgentRuntimeCatalog(snapshot: snapshot)
            } catch {
                await snapshot.release()
                throw error
            }
            catalog = runtimeCatalog
            let route = AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
                modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1, adapter: adapter.identity, invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", modelID: "synthetic",
                credential: nil, contextWindow: 4_096, maximumOutputTokens: 128,
                capabilities: .init(streamsText: true, callsTools: false, producesThinking: false), configuration: .object([:]))
            let plan = AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: runtimeCatalog.generation,
                driverID: "prep.driver", driverRevision: 1, instructions: "Answer.", limits: limits,
                priority: .foreground, route: route)
            let admission = await opened.commit(id: UUID()) { context in
                let title = try await context.stageBytes(Data("Preparation fixture".utf8), kind: .title)
                let body = try await context.stageBytes(Data("Question".utf8), kind: .userText)
                let planReference = try await context.stage(plan, kind: .executionPlan)
                return [.opened(.init(workspaceID: nil, title: title)),
                        .admitted(.init(executionID: executionID, userMessageID: MessageID(), userBody: body,
                            plan: planReference, hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
            }
            guard case .committed = admission else { throw MiraError(.storage, "Preparation fixture admission failed.") }
            let scheduler = RuntimeScheduler(modelCapacity: 1, backgroundCapacity: 0)
            let libraryAccessFixture = try await LibraryAccessFixture.make()
            return .init(directory: directory, library: library, runtime: opened, sessionID: sessionID,
                executionID: executionID, modelProbe: modelProbe, catalog: runtimeCatalog, scope: runtimeScope,
                scopeProbe: scopeProbe, scheduler: scheduler, adapter: adapter, environment: environment,
                libraryAccessFixture: libraryAccessFixture)
        } catch {
            await catalog?.release(); await scope?.dispose(); await runtime?.close()
            try? await library.close(); try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private init(directory: URL, library: FileSessionLibrary, runtime: SessionRuntime, sessionID: ConversationID,
                 executionID: ExecutionID, modelProbe: PreparationModelProbe, catalog: AgentRuntimeCatalog,
                 scope: RuntimeScope, scopeProbe: PreparationScopeProbe, scheduler: RuntimeScheduler,
                 adapter: PreparationAdapter, environment: RuntimeEnvironment,
                 libraryAccessFixture: LibraryAccessFixture) {
        self.directory = directory; self.library = library; self.runtime = runtime; self.sessionID = sessionID
        self.executionID = executionID; self.modelProbe = modelProbe; self.catalog = catalog; self.scope = scope
        self.scopeProbe = scopeProbe; self.scheduler = scheduler; self.adapter = adapter; self.environment = environment
        self.libraryAccessFixture = libraryAccessFixture
    }

    func kernel() async throws -> AgentExecutionKernel {
        let libraryLease = try await libraryAccessFixture.acquire()
        do {
            return try await AgentExecutionKernel(runtime: runtime, journal: library, payloads: library,
            libraryLease: libraryLease,
                executionID: executionID, runtimeID: try await planRuntimeID(), catalog: catalog,
                policy: PreparationAllowPolicy(), authority: PreparationAllowAuthority(), business: PreparationNoopBusiness(),
                authorizer: PreparationAllowAuthorizer(), approvals: RuntimeApprovalService(), scheduler: scheduler,
                environment: environment)
        } catch {
            await libraryAccessFixture.close()
            await scheduler.shutdown(); await catalog.release(); await scope.dispose()
            await runtime.close(); try? await library.close(); removeDirectory()
            throw error
        }
    }

    private func planRuntimeID() async throws -> UUID {
        let state = await runtime.snapshot()
        let execution = try #require(state.executions[executionID])
        let plan = try await AgentExecutionPlan.read(for: execution.admission, from: library)
        return plan.runtimeID
    }

    func shutdown(_ kernel: AgentExecutionKernel, deleteDirectory: Bool = true) async {
        _ = await kernel.shutdown(); await scheduler.shutdown(); await runtime.close()
        await libraryAccessFixture.close()
        await catalog.release(); await scope.dispose(); try? await library.close()
        if deleteDirectory { removeDirectory() }
    }

    func removeDirectory() { try? FileManager.default.removeItem(at: directory) }
}

private struct PreparationDriver: AgentDriver {
    let id = "prep.driver"
    let revision = 1
    func run(in context: AgentRunContext) async throws -> AgentDriverDecision {
        _ = try await context.modelStep(); return .complete
    }
}

private struct PreparationAdapter: AgentModelAdapter {
    let identity = AgentAdapterIdentity(id: "preparation.synthetic", revision: 1)
    let probe: PreparationModelProbe
    let gate: SynchronousPrepareGate?
    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        gate?.enterAndWait()
        return .init(adapter: identity, input: input, wirePayload: .object(["synthetic": .bool(true)]), estimatedInputTokens: 1)
    }
    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        let (stream, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
        let producer = Task {
            await probe.dispatched()
            continuation.yield(.blockStarted(.init(id: "text", content: .text("prepared")))); continuation.yield(.blockFinished(id: "text")); continuation.yield(.finished(.stop)); continuation.finish()
            await probe.drained()
        }
        return .init(events: stream, cancelAndDrain: { producer.cancel(); _ = await producer.value; await probe.drained() })
    }
    func replay(_ messages: [AgentModelMessage], from source: AgentModelRoute, to target: AgentModelRoute,
                boundary: AgentReplayBoundary) throws -> AgentReplayDecision { .include(messages) }
}

private actor PreparationModelProbe {
    private(set) var dispatchCount = 0
    private var drainedFlag = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    func dispatched() { dispatchCount += 1 }
    func drained() { drainedFlag = true; drainWaiters.forEach { $0.resume() }; drainWaiters.removeAll() }
    func waitUntilDrained() async { if !drainedFlag { await withCheckedContinuation { drainWaiters.append($0) } } }
}

private actor BlockingPreparationContributor: AgentContextContributor {
    let id = "blocking.preparation"
    let isRequired = true
    private var entered = false
    private var released = false
    private var cancellationObserved = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func contribute(to request: AgentContextRequest) async throws -> [AgentContextItem] {
        entered = true
        await withTaskCancellationHandler(operation: {
            if !released { await withCheckedContinuation { releaseWaiter = $0 } }
        }, onCancel: { Task { await self.observeCancellation() } })
        return [.init(id: "delayed", text: "delayed contribution", sources: [])]
    }
    func waitUntilEntered() async throws {
        try await waitForPreparationState { await self.hasEntered() }
    }
    func waitUntilCancellationObserved() async throws {
        try await waitForPreparationState { await self.hasObservedCancellation() }
    }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
    private func hasEntered() -> Bool { entered }
    private func hasObservedCancellation() -> Bool { cancellationObserved }
    private func observeCancellation() { cancellationObserved = true }
}

private final class SynchronousPrepareGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var cancellationObserved = false
    func enterAndWait() {
        condition.lock(); defer { condition.unlock() }
        entered = true
        while !released {
            _ = condition.wait(until: Date().addingTimeInterval(0.01))
            if Task.isCancelled { cancellationObserved = true }
        }
    }
    func waitUntilEntered() async throws {
        try await waitForPreparationState { self.isEntered() }
    }
    func waitUntilCancellationObserved() async throws {
        try await waitForPreparationState { self.isCancellationObserved() }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    private func isEntered() -> Bool { condition.lock(); defer { condition.unlock() }; return entered }
    private func isCancellationObserved() -> Bool { condition.lock(); defer { condition.unlock() }; return cancellationObserved }
}

private enum PreparationClockEvent: Sendable { case timeout, privateFailure }

private actor PreparationCancellationClock: RuntimeClock {
    let duration: Duration
    private var entered = false
    private var cancelled = false
    private var released = false
    private var waiter: CheckedContinuation<Void, any Error>?
    init(duration: Duration) { self.duration = duration }
    func sleep(for duration: Duration) async throws {
        guard duration == self.duration else { try await Task.sleep(for: duration); return }
        try await withTaskCancellationHandler(operation: {
            entered = true
            if !released { try await withCheckedThrowingContinuation { waiter = $0 } }
        }, onCancel: { Task { await self.observeCancellation() } })
    }
    func waitUntilEntered() async throws {
        try await waitForPreparationState { await self.hasEntered() }
    }
    func waitUntilCancellationObserved() async throws {
        try await waitForPreparationState { await self.hasObservedCancellation() }
    }
    func releaseNormally() { released = true; waiter?.resume(); waiter = nil }
    private func hasEntered() -> Bool { entered }
    private func hasObservedCancellation() -> Bool { cancelled }
    private func observeCancellation() { cancelled = true }
}

private actor PreparationClock: RuntimeClock {
    let duration: Duration
    private var entered = false
    private var waiter: CheckedContinuation<Void, any Error>?
    init(duration: Duration) { self.duration = duration }
    func sleep(for duration: Duration) async throws {
        guard duration == self.duration else { try await Task.sleep(for: duration); return }
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                entered = true; waiter = continuation
            }
        }, onCancel: { Task { await self.cancel() } })
    }
    func waitUntilPreparationEntered() async throws {
        try await waitForPreparationState { await self.hasEntered() }
    }
    func fire(_ event: PreparationClockEvent) {
        switch event {
        case .timeout: waiter?.resume()
        case .privateFailure: waiter?.resume(throwing: MiraError(.network, "private-preparation-marker"))
        }
        waiter = nil
    }
    private func hasEntered() -> Bool { entered }
    private func cancel() { waiter?.resume(throwing: CancellationError()); waiter = nil }
}

private actor PreparationCompletionProbe {
    private(set) var done = false
    func mark() { done = true }
}

private actor PreparationScopeProbe {
    private(set) var completed = false
    private var closing = false
    func beginClosing() { closing = true }
    func waitUntilClosing() async throws {
        try await waitForPreparationState { await self.isClosing() }
    }
    func finished() { completed = true }
    private func isClosing() -> Bool { closing }
}

private func waitForPreparationState(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw MiraError(.timeout, "The preparation fixture did not reach its expected state.")
}

private struct PreparationAllowPolicy: AgentToolPolicy {
    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision { .allow }
    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws {}
}

private struct PreparationAllowAuthority: AgentEffectAuthority {
    func authorization(for proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentLibraryAuthorization { .init(libraryID: UUID(), epoch: 0) }
    func validate(_ authorization: AgentLibraryAuthorization, proposal: AgentToolProposal, context: AgentToolContext) async throws {}
}

private struct PreparationAllowAuthorizer: AgentSourceAuthorizer {
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {}
}

private struct PreparationNoopBusiness: AgentBusinessEffects {
    func fenceExecution(sessionID: ConversationID, executionID: ExecutionID) async throws {}
    func commit(_ proof: AgentEffectProof) async -> AgentBusinessCommitOutcome { .notCommitted(.init(.unsupported, "Preparation tests have no business effects.")) }
    func receipt(for proof: AgentEffectProof) async -> AgentBusinessReceiptLookup { .absent }
    func unpublished(after receiptID: UUID?, limit: Int) async throws -> [AgentReceiptPublication] { [] }
    func acknowledge(_ receipt: AgentBusinessReceiptReference, at cursor: SessionCursor) async throws {}
}
