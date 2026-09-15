import Foundation
import Testing
@testable import MiraCore

struct RuntimeModuleTests {
    @Test func activatesInDeterministicDependencyOrderAndDisposesInReverseOrder() async throws {
        let recorder = EventRecorder()
        let modules = [
            makeModule("gamma", dependencies: ["beta"], recorder: recorder),
            makeModule("alpha", recorder: recorder),
            makeModule("beta", dependencies: ["alpha"], recorder: recorder)
        ]
        let host = try RuntimeModuleHost(modules: modules)
        let parent = RuntimeScope(kind: .application)
        let activation = try await host.activate(in: parent)

        #expect(activation.activationOrder == ["alpha", "beta", "gamma"])
        #expect(await recorder.values() == ["activate:alpha", "activate:beta", "activate:gamma"])

        await activation.dispose()
        #expect(await recorder.values() == [
            "activate:alpha", "activate:beta", "activate:gamma",
            "cleanup:gamma", "cleanup:beta", "cleanup:alpha"
        ])
        #expect(await activation.isDisposed)

        await parent.dispose()
        #expect(await recorder.values().count == 6)
    }

    @Test func rejectsDuplicateMissingAndCyclicDependencies() {
        do {
            _ = try RuntimeModuleHost(modules: [
                makeModule("duplicate"),
                makeModule("duplicate")
            ])
            Issue.record("Expected duplicate module IDs to be rejected")
        } catch let error as RuntimeModuleHostError {
            #expect(error == .duplicateID("duplicate"))
        } catch {
            Issue.record("Unexpected duplicate ID error: \(error)")
        }

        do {
            _ = try RuntimeModuleHost(modules: [makeModule("dependent", dependencies: ["missing"])])
            Issue.record("Expected missing dependencies to be rejected")
        } catch let error as RuntimeModuleHostError {
            #expect(error == .missingDependency(module: "dependent", dependency: "missing"))
        } catch {
            Issue.record("Unexpected missing dependency error: \(error)")
        }

        do {
            _ = try RuntimeModuleHost(modules: [
                makeModule("a", dependencies: ["b"]),
                makeModule("b", dependencies: ["a"])
            ])
            Issue.record("Expected dependency cycles to be rejected")
        } catch let error as RuntimeModuleHostError {
            #expect(error == .dependencyCycle(["a", "b", "a"]))
        } catch {
            Issue.record("Unexpected dependency cycle error: \(error)")
        }
    }

    @Test func validatesStableModuleIDNamespaceAndReservedCoreNames() throws {
        let invalidIDs = [
            "",
            "1module",
            "Uppercase",
            "module/slash",
            "模块", // i18n-fixture: Non-ASCII module IDs must be rejected.
            String(repeating: "a", count: 129)
        ]
        for id in invalidIDs {
            do {
                _ = try RuntimeModuleHost(modules: [makeModule(id)])
                Issue.record("Expected invalid module ID to be rejected: \(id)")
            } catch let error as RuntimeModuleHostError {
                #expect(error == .invalidID(id))
            } catch {
                Issue.record("Unexpected invalid ID error: \(error)")
            }
        }

        for id in ["core", "core.scheduler"] {
            do {
                _ = try RuntimeModuleHost(modules: [makeModule(id)])
                Issue.record("Expected reserved module ID to be rejected: \(id)")
            } catch let error as RuntimeModuleHostError {
                #expect(error == .reservedID(id))
            } catch {
                Issue.record("Unexpected reserved ID error: \(error)")
            }
        }

        let validID = "module.v1_test-2" + String(repeating: "a", count: 112)
        _ = try RuntimeModuleHost(modules: [makeModule(validID)])
    }

    @Test func partialActivationFailureRollsBackExactlyOnce() async throws {
        let recorder = EventRecorder()
        let failing = TestModule(id: "failing", dependencies: ["first"]) { scope in
            await recorder.append("activate:failing")
            try await scope.registerCleanup { await recorder.append("cleanup:failing") }
            throw TestModuleError.failed
        }
        let host = try RuntimeModuleHost(modules: [
            failing,
            makeModule("first", recorder: recorder)
        ])
        let parent = RuntimeScope(kind: .application)

        do {
            _ = try await host.activate(in: parent)
            Issue.record("Expected activation failure")
        } catch let error as TestModuleError {
            #expect(error == .failed)
        }

        #expect(await recorder.values() == [
            "activate:first", "activate:failing",
            "cleanup:failing", "cleanup:first"
        ])
        await parent.dispose()
        #expect(await recorder.values().count == 4)
    }

    @Test func cancellationDuringActivationRollsBackTheActiveScope() async throws {
        let recorder = EventRecorder()
        let gate = AsyncGate()
        let module = TestModule(id: "waiting") { scope in
            await recorder.append("activate:waiting")
            try await scope.registerCleanup { await recorder.append("cleanup:waiting") }
            await gate.wait()
            try Task.checkCancellation()
        }
        let host = try RuntimeModuleHost(modules: [module])
        let parent = RuntimeScope(kind: .application)
        let activationTask = Task { try await host.activate(in: parent) }

        await gate.waitUntilEntered()
        activationTask.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await activationTask.value }
        #expect(await recorder.values() == ["activate:waiting", "cleanup:waiting"])
        #expect(!(await parent.isDisposed))
    }

    @Test func parentTeardownConcurrentWithActivationRollsBackExactlyOnce() async throws {
        let recorder = EventRecorder()
        let gate = AsyncGate()
        let module = TestModule(id: "waiting") { scope in
            await recorder.append("activate:waiting")
            try await scope.registerCleanup { await recorder.append("cleanup:waiting") }
            await gate.wait()
        }
        let host = try RuntimeModuleHost(modules: [module])
        let parent = RuntimeScope(kind: .application)
        let activationTask = Task { try await host.activate(in: parent) }

        await gate.waitUntilEntered()
        await parent.dispose()
        await gate.release()
        do {
            _ = try await activationTask.value
            Issue.record("Expected parent disposal to abort activation")
        } catch let error as RuntimeModuleActivationError {
            #expect(error == .parentDisposed)
        }
        #expect(await recorder.values() == ["activate:waiting", "cleanup:waiting"])
    }

    @Test func cleanupRegisteredAfterDisposalIsRejected() async throws {
        let scope = RuntimeScope(kind: .application)
        await scope.dispose()
        await #expect(throws: RuntimeScopeError.disposed) {
            try await scope.registerCleanup { }
        }
    }

    @Test func cleanupRegistrationAndDisposalReentrancyCannotLeakOrDeadlock() async throws {
        let recorder = EventRecorder()
        let scope = RuntimeScope(kind: .application)
        try await scope.registerCleanup {
            await recorder.append("cleanup:started")
            do {
                try await scope.registerCleanup { await recorder.append("cleanup:late") }
                await recorder.append("registration:accepted")
            } catch let error as RuntimeScopeError {
                await recorder.append("registration:\(error == .disposed ? "rejected" : "unexpected")")
            } catch {
                await recorder.append("registration:unexpected")
            }
            await scope.dispose()
            await recorder.append("cleanup:finished")
        }

        await scope.dispose()
        #expect(await recorder.values() == [
            "cleanup:started", "registration:rejected", "cleanup:finished"
        ])
        #expect(await scope.isDisposed)
    }

    @Test func concurrentDisposeWaitsForOneCleanupAndRunsItOnce() async throws {
        let recorder = EventRecorder()
        let gate = AsyncGate()
        let scope = RuntimeScope(kind: .application)
        try await scope.registerCleanup {
            await recorder.append("cleanup:started")
            await gate.wait()
            await recorder.append("cleanup:finished")
        }

        let first = Task { await scope.dispose() }
        await gate.waitUntilEntered()
        let secondStarted = AsyncSignal()
        let secondFinished = AsyncSignal()
        let second = Task {
            await secondStarted.signal()
            await scope.dispose()
            await secondFinished.signal()
        }
        await secondStarted.wait()
        for _ in 0..<5 { await Task.yield() }
        #expect(!(await secondFinished.isSignaled))

        await gate.release()
        await first.value
        await second.value
        #expect(await secondFinished.isSignaled)
        #expect(await recorder.values() == ["cleanup:started", "cleanup:finished"])
    }

    @Test func activationDisposalRemovesChildrenFromParentOwnership() async throws {
        let recorder = EventRecorder()
        let host = try RuntimeModuleHost(modules: [makeModule("child", recorder: recorder)])
        let parent = RuntimeScope(kind: .application)
        let activation = try await host.activate(in: parent)

        await activation.dispose()
        #expect(await recorder.values() == ["activate:child", "cleanup:child"])
        await parent.dispose()
        #expect(await recorder.values() == ["activate:child", "cleanup:child"])
    }

    @Test func sessionScopesAreIndependent() async throws {
        let firstID = ConversationID(UUID())
        let secondID = ConversationID(UUID())
        let first = RuntimeScope(kind: .session(firstID))
        let second = RuntimeScope(kind: .session(secondID))
        let recorder = EventRecorder()
        try await first.registerCleanup { await recorder.append("cleanup:first") }
        try await second.registerCleanup { await recorder.append("cleanup:second") }

        #expect(first.id != second.id)
        #expect(first.kind == .session(firstID))
        #expect(second.kind == .session(secondID))
        await first.dispose()
        #expect(await first.isDisposed)
        #expect(!(await second.isDisposed))
        #expect(await recorder.values() == ["cleanup:first"])

        await second.dispose()
        #expect(await recorder.values() == ["cleanup:first", "cleanup:second"])
    }

    @Test func parentCleanupAwaitingChildDisposeDoesNotDeadlock() async throws {
        let parent = RuntimeScope(kind: .application)
        let child = try await parent.makeChild(kind: .session(ConversationID()))
        let recorder = EventRecorder()
        try await parent.registerCleanup {
            await child.dispose()
            await recorder.append("parent-cleanup")
        }

        await parent.dispose()
        #expect(await child.isDisposed)
        #expect(await recorder.values() == ["parent-cleanup"])
    }

    @Test func activationDoesNotExposePartialRegistrySnapshot() async throws {
        let registry = RuntimeRegistry<String>()
        let gate = AsyncGate()
        let module = TestModule(id: "pending") { scope in
            try await registry.register(id: "pending.value", value: "value", scope: scope)
            await gate.wait()
        }
        let host = try RuntimeModuleHost(modules: [module])
        let parent = RuntimeScope(kind: .application)
        let activationTask = Task { try await host.activate(in: parent) }
        await gate.waitUntilEntered()

        await #expect(throws: RuntimeScopeError.activationUnavailable) {
            _ = try await registry.freeze()
        }

        await gate.release()
        let activation = try await activationTask.value
        let snapshot = try await registry.freeze()
        #expect(snapshot.entries.map(\.id) == ["pending.value"])
        await snapshot.release()
        await activation.dispose()
        await parent.dispose()
    }

    @Test func nestedScopesInheritActivationVisibilityGate() async throws {
        let registry = RuntimeRegistry<String>()
        let gate = AsyncGate()
        let module = TestModule(id: "nested") { scope in
            let nested = try await scope.makeChild(kind: .execution(ExecutionID()))
            try await registry.register(id: "nested.value", value: "value", scope: nested)
            await gate.wait()
        }
        let host = try RuntimeModuleHost(modules: [module])
        let parent = RuntimeScope(kind: .application)
        let activationTask = Task { try await host.activate(in: parent) }
        await gate.waitUntilEntered()
        await #expect(throws: RuntimeScopeError.activationUnavailable) { _ = try await registry.freeze() }
        await gate.release()
        let activation = try await activationTask.value
        let snapshot = try await registry.freeze()
        #expect(snapshot.entries.map(\.id) == ["nested.value"])
        await snapshot.release()
        await activation.dispose()
        await parent.dispose()
    }

    @Test func nestedModuleHostActivationDoesNotExposeEntriesBeforeOuterCommit() async throws {
        let registry = RuntimeRegistry<String>()
        let nestedReady = AsyncSignal()
        let outerHold = AsyncGate()
        let nestedActivationBox = ActivationBox()

        let inner = TestModule(id: "inner") { scope in
            try await registry.register(id: "inner.value", value: "value", scope: scope)
        }
        let outer = TestModule(id: "outer") { scope in
            let nested = try await RuntimeModuleHost(modules: [inner]).activate(in: scope)
            await nestedActivationBox.store(nested)
            await nestedReady.signal()
            await outerHold.wait()
        }
        let parent = RuntimeScope(kind: .application)
        let outerTask = Task { try await RuntimeModuleHost(modules: [outer]).activate(in: parent) }

        await nestedReady.wait()
        await #expect(throws: RuntimeScopeError.activationUnavailable) { _ = try await registry.freeze() }

        await outerHold.release()
        let outerActivation = try await outerTask.value
        let snapshot = try await registry.freeze()
        #expect(snapshot.entries.map(\.id) == ["inner.value"])
        await snapshot.release()
        await (await nestedActivationBox.take())?.dispose()
        await outerActivation.dispose()
        await parent.dispose()
    }

    @Test func failedActivationCancelsEarlierModuleTasksBeforeCleanupRuns() async throws {
        let firstStarted = AsyncSignal()
        let firstCancelled = AsyncSignal()
        let recorder = EventRecorder()
        let first = TestModule(id: "first") { scope in
            _ = try await scope.ownTask {
                await firstStarted.signal()
                while !Task.isCancelled { await Task.yield() }
                await firstCancelled.signal()
            }
            await firstStarted.wait()
        }
        let second = TestModule(id: "second", dependencies: ["first"]) { scope in
            try await scope.registerCleanup {
                await firstCancelled.wait()
                await recorder.append("second-cleanup")
            }
            throw TestModuleError.failed
        }
        let parent = RuntimeScope(kind: .application)

        do {
            _ = try await RuntimeModuleHost(modules: [first, second]).activate(in: parent)
            Issue.record("Expected activation failure")
        } catch let error as TestModuleError {
            #expect(error == .failed)
        }

        #expect(await firstCancelled.isSignaled)
        #expect(await recorder.values() == ["second-cleanup"])
        await parent.dispose()
    }

    @Test func cancelledOwnedTaskCanDisposeItsActivationWithoutDeadlock() async throws {
        let activationBox = ActivationBox()
        let taskStarted = AsyncSignal()
        let taskCancelled = AsyncSignal()
        let module = TestModule(id: "self-disposing") { scope in
            _ = try await scope.ownTask {
                await taskStarted.signal()
                while !Task.isCancelled { await Task.yield() }
                await taskCancelled.signal()
                if let activation = await activationBox.value() {
                    await activation.dispose()
                }
            }
            await taskStarted.wait()
        }
        let parent = RuntimeScope(kind: .application)
        let activation = try await RuntimeModuleHost(modules: [module]).activate(in: parent)
        await activationBox.store(activation)

        let disposal = Task { await activation.dispose() }
        await taskCancelled.wait()
        await disposal.value
        #expect(await activation.isDisposed)
        await parent.dispose()
    }

    @Test func activationDisposalCancelsAllSiblingScopesBeforeWaitingLeases() async throws {
        let firstLease = LeaseBox()
        let secondStarted = AsyncGate()
        let secondFinished = AsyncSignal()
        let leasePermit = AsyncGate()
        let leaseReady = AsyncSignal()
        let first = TestModule(id: "first") { scope in
            _ = try await scope.ownTask {
                await secondStarted.wait()
                while !Task.isCancelled { await Task.yield() }
                await secondFinished.signal()
            }
        }
        let second = TestModule(id: "second") { scope in
            _ = try await scope.ownTask {
                await leasePermit.wait()
                guard let lease = try? await scope.acquireLease() else { return }
                await firstLease.store(lease)
                await leaseReady.signal()
                while !Task.isCancelled { await Task.yield() }
            }
        }
        let activation = try await RuntimeModuleHost(modules: [first, second]).activate(in: RuntimeScope(kind: .application))
        await leasePermit.release()
        await leaseReady.wait()
        await secondStarted.waitUntilEntered()
        await secondStarted.release()
        let disposal = Task { await activation.dispose() }
        await secondFinished.wait()
        await firstLease.release()
        await disposal.value
    }

    private func makeModule(
        _ id: String,
        dependencies: Set<String> = [],
        recorder: EventRecorder? = nil
    ) -> TestModule {
        TestModule(id: id, dependencies: dependencies) { scope in
            if let recorder {
                await recorder.append("activate:\(id)")
                try await scope.registerCleanup { await recorder.append("cleanup:\(id)") }
            }
        }
    }
}

private struct TestModule: RuntimeModule {
    let id: String
    let dependencies: Set<String>
    let body: @Sendable (RuntimeScope) async throws -> Void

    init(
        id: String,
        dependencies: Set<String> = [],
        body: @escaping @Sendable (RuntimeScope) async throws -> Void = { _ in }
    ) {
        self.id = id
        self.dependencies = dependencies
        self.body = body
    }

    func activate(in scope: RuntimeScope) async throws {
        try await body(scope)
    }
}

private enum TestModuleError: Error, Equatable, Sendable {
    case failed
}

private actor EventRecorder {
    private var recorded: [String] = []

    func append(_ event: String) {
        recorded.append(event)
    }

    func values() -> [String] {
        recorded
    }
}

private actor AsyncGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor AsyncSignal {
    private(set) var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignaled = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor LeaseBox {
    private var lease: RuntimeScopeLease?

    func store(_ lease: RuntimeScopeLease) {
        self.lease = lease
    }

    func release() async {
        await lease?.release()
        lease = nil
    }
}

private actor ActivationBox {
    private var activation: RuntimeModuleActivation?

    func store(_ activation: RuntimeModuleActivation) {
        self.activation = activation
    }

    func value() -> RuntimeModuleActivation? {
        activation
    }

    func take() -> RuntimeModuleActivation? {
        defer { activation = nil }
        return activation
    }
}
