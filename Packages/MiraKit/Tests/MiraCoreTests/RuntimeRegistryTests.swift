import Foundation
import Testing
@testable import MiraCore

@Suite("Runtime registry")
struct RuntimeRegistryTests {
    @Test func freezesInOrderAndAdvancesGeneration() async throws {
        let registry = RuntimeRegistry<String>()
        let scope = RuntimeScope(kind: .application)
        try await registry.register(id: "zeta", value: "z", scope: scope, order: 2)
        try await registry.register(id: "alpha", value: "a", scope: scope, order: 1)
        try await registry.register(id: "same", value: "later", scope: scope, order: 2)

        let first = try await registry.freeze()
        #expect(first.generation == 3)
        #expect(first.entries.map(\.id) == ["alpha", "same", "zeta"])
        let second = try await registry.freeze()
        #expect(second.generation == 3)
        #expect(first.entries.map(\.value) == ["a", "later", "z"])
        await first.release()
        await second.release()
        await scope.dispose()
    }

    @Test func duplicateRegistrationIsRejected() async throws {
        let registry = RuntimeRegistry<Int>()
        let scope = RuntimeScope(kind: .application)
        try await registry.register(id: "memory", value: 1, scope: scope)
        await #expect(throws: RuntimeRegistryError.duplicateID("memory")) {
            try await registry.register(id: "memory", value: 2, scope: scope)
        }
        await scope.dispose()
    }

    @Test func snapshotLeasePinsScopeAfterUnregister() async throws {
        let recorder = RegistryRecorder()
        let scope = RuntimeScope(kind: .application)
        try await scope.registerCleanup { await recorder.append("cleanup") }
        let registry = RuntimeRegistry<String>()
        try await registry.register(id: "resource", value: "live", scope: scope)
        let snapshot = try await registry.freeze()
        try await registry.unregister(id: "resource")

        let disposal = Task { await scope.dispose() }
        await Task.yield()
        #expect(await recorder.values().isEmpty)
        await snapshot.release()
        await snapshot.release()
        await disposal.value
        #expect(await recorder.values() == ["cleanup"])
    }

    @Test func unregisterWithdrawsClosingRegistrationBeforeSameIDCanReRegister() async throws {
        let registry = RuntimeRegistry<String>()
        let scope = RuntimeScope(kind: .application)

        do {
            try await registry.register(id: "resource", value: "first", scope: scope)
            #expect(await scope.closingRegistrationCount == 1)
            try await registry.unregister(id: "resource")
            #expect(await scope.closingRegistrationCount == 0)

            try await registry.register(id: "resource", value: "second", scope: scope)
            #expect(await scope.closingRegistrationCount == 1)
            let snapshot = try await registry.freeze()
            #expect(snapshot.entries.map { $0.value } == ["second"])
            #expect(snapshot.entries.first?.scopeID == scope.id)
            #expect(snapshot.entries.first?.scopeKind == scope.kind)
            await snapshot.release()
            try await registry.unregister(id: "resource")
            #expect(await scope.closingRegistrationCount == 0)
        } catch { await scope.dispose(); throw error }
        await scope.dispose()
    }

    @Test func registrationRacingScopeCloseLeavesNoEntry() async throws {
        let registry = RuntimeRegistry<Int>()
        let scope = RuntimeScope(kind: .application)
        let attempts = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for index in 0..<24 {
                group.addTask {
                    do {
                        try await registry.register(id: "module\(index)", value: index, scope: scope)
                        return true
                    } catch RuntimeScopeError.disposed {
                        return false
                    } catch RuntimeRegistryError.registrationCancelled {
                        return false
                    } catch {
                        Issue.record("Unexpected registration race error: \(error)")
                        return false
                    }
                }
            }
            group.addTask {
                await scope.dispose()
                return false
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        #expect(attempts.count == 25)
        let snapshot = try await registry.freeze()
        #expect(snapshot.entries.isEmpty)
        await snapshot.release()
    }

    @Test func failedFreezeReleasesAlreadyAcquiredLeases() async throws {
        let registry = RuntimeRegistry<String>()
        let first = RuntimeScope(kind: .application)
        let second = RuntimeScope(kind: .application)
        try await registry.register(id: "first", value: "1", scope: first, order: 0)
        try await registry.register(id: "second", value: "2", scope: second, order: 1)

        // Closing the second scope removes its registration. A concurrent
        // freeze may have captured it; either outcome must leave first releasable.
        await second.dispose()
        if let snapshot = try? await registry.freeze() { await snapshot.release() }
        let disposal = Task { await first.dispose() }
        await disposal.value
    }

    @Test func ownedTaskIsCancelledBeforeScopeCleanupAndSelfDisposeDoesNotDeadlock() async throws {
        let scope = RuntimeScope(kind: .application)
        let started = RegistrySignal()
        let task = try await scope.ownTask {
            await started.signal()
            while !Task.isCancelled { await Task.yield() }
        }
        await started.wait()
        let disposal = Task { await scope.dispose() }
        await task.value
        await disposal.value
        #expect(await scope.isDisposed)

        let selfDisposing = RuntimeScope(kind: .application)
        let selfTask = try await selfDisposing.ownTask { await selfDisposing.dispose() }
        await selfTask.value
        #expect(await selfDisposing.isDisposed)
    }

    @Test func cancelledOwnedTaskCanDisposeItsAlreadyClosingScope() async throws {
        let scope = RuntimeScope(kind: .application)
        let started = RegistrySignal()
        let task = try await scope.ownTask {
            await started.signal()
            while !Task.isCancelled { await Task.yield() }
            await scope.dispose()
        }
        await started.wait()
        let disposal = Task { await scope.dispose() }
        await task.value
        await disposal.value
        #expect(await scope.isDisposed)
    }

    @Test func parentTeardownCancelsChildTasksBeforeCleanup() async throws {
        let parent = RuntimeScope(kind: .application)
        let child = try await parent.makeChild(kind: .execution(ExecutionID()))
        let started = RegistrySignal()
        let task = try await child.ownTask {
            await started.signal()
            while !Task.isCancelled { await Task.yield() }
        }
        await started.wait()
        await parent.dispose()
        await task.value
        #expect(await parent.isDisposed)
        #expect(await child.isDisposed)
    }

    @Test func concurrentRuntimeReleaseCallersBothAwaitOneDrain() async throws {
        let operationStarted = RegistrySignal()
        let operationFinished = RegistrySignal()
        let release = RuntimeRelease {
            await operationStarted.signal()
            await operationFinished.wait()
        }

        let firstFinished = RegistrySignal()
        let secondFinished = RegistrySignal()
        let first = Task {
            await release.release()
            await firstFinished.signal()
        }
        await operationStarted.wait()
        let second = Task {
            await release.release()
            await secondFinished.signal()
        }
        for _ in 0..<8 { await Task.yield() }
        #expect(!(await firstFinished.isSignaled))
        #expect(!(await secondFinished.isSignaled))

        await operationFinished.signal()
        await first.value
        await second.value
        #expect(await firstFinished.isSignaled)
        #expect(await secondFinished.isSignaled)
    }
}

private actor RegistryRecorder {
    private var events: [String] = []
    func append(_ event: String) { events.append(event) }
    func values() -> [String] { events }
}

private actor RegistrySignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isSignaled: Bool { signaled }

    func signal() {
        signaled = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation in
            if signaled { continuation.resume() } else { waiters.append(continuation) }
        }
    }
}
