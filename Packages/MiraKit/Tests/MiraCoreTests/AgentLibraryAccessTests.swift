import Foundation
import Testing
@testable import MiraCore

@Suite("Agent library access")
struct AgentLibraryAccessTests {
    @Test func readyAccessPinsScopeAndReleasesLease() async throws {
        try await withAccess { access in
            try await withScope(access) { scope, leases in
                let lease = try await leases.acquire(access, in: scope)
                let initialSnapshot = await access.snapshot()
                #expect(lease.authorization == initialSnapshot.authorization)
                #expect((await access.snapshot()).activeLeases == 1)
                try await lease.check()
                await lease.release()
                #expect((await access.snapshot()).activeLeases == 0)
            }
        }
    }

    @Test func pendingMaintenanceAtOpenDeniesNewLeases() async throws {
        let authorization = AgentLibraryAuthorization(libraryID: UUID(), epoch: 3)
        let operation = pendingOperation(previous: authorization)
        let store = AccessStore(state: .init(authorization: operation.authorization, pending: operation))
        let access = try await AgentLibraryAccess.open(store: store)
        let scope = RuntimeScope(kind: .application)
        do {
            _ = try await access.acquire(in: scope)
            Issue.record("A pending library maintenance state granted a new lease")
        } catch let error as MiraError {
            #expect(error.code == .unauthorized)
        }
        await scope.dispose()
        await access.close()
    }

    @Test func maintenanceRevokesOldLeaseAndCompletesAfterActualRelease() async throws {
        try await withAccess { access in
            try await withScope(access) { scope, leases in
                let lease = try await leases.acquire(access, in: scope)
                let cancellation = LockedFlag()
                let request = maintenanceRequest()
                let operation = try await access.begin(request, expected: lease.authorization)
                try lease.bindCancellation { cancellation.increment() }
                try await waitUntil { cancellation.count == 1 }
                #expect(lease.isRevoked)
                do { try await lease.check(); Issue.record("Revoked lease passed check") }
                catch let error as MiraError { #expect(error.code == .unauthorized) }
                do {
                    _ = try await access.complete(operation, at: Date(timeIntervalSince1970: 1_700_000_100))
                    Issue.record("Maintenance completed while old lease was still retained")
                } catch let error as MiraError { #expect(error.code == .busy) }
                await lease.release()
                let completed = try await access.complete(operation, at: Date(timeIntervalSince1970: 1_700_000_100))
                #expect(completed.completedAt != nil)
                #expect((await access.snapshot()).authorization == operation.authorization)
                let newLease = try await leases.acquire(access, in: scope)
                #expect(newLease.authorization == operation.authorization)
                do { try await lease.check(); Issue.record("The revoked lease became valid after epoch advancement") }
                catch let error as MiraError { #expect(error.code == .unauthorized) }
                await newLease.release()
            }
        }
    }

    @Test func normalReleaseDoesNotInvokeCancellationOwner() async throws {
        try await withAccess { access in
            try await withScope(access) { scope, leases in
                let lease = try await leases.acquire(access, in: scope)
                let cancellation = LockedFlag()
                try lease.bindCancellation { cancellation.increment() }
                await lease.release()
                #expect(cancellation.count == 0)
            }
        }
    }

    @Test func scopeDisposalRevokesAndWaitsForLibraryLeaseRelease() async throws {
        try await withAccess { access in
            let scope = RuntimeScope(kind: .session(ConversationID()))
            let lease = try await access.acquire(in: scope)
            let disposed = LockedFlag()
            let disposing = Task {
                await scope.dispose()
                disposed.mark()
            }
            do {
                try await waitUntil { lease.isRevoked }
                #expect(disposed.isSet == false)
                await lease.release()
                _ = await disposing.value
                #expect(disposed.isSet)
            } catch {
                await lease.release()
                _ = await disposing.value
                throw error
            }
        }
    }

    @Test func maximumLeaseCountRejectsThenAllowsAfterRelease() async throws {
        try await withAccess(maximumLeases: 1) { access in
            try await withScope(access) { scope, leases in
                let first = try await leases.acquire(access, in: scope)
                do {
                    _ = try await leases.acquire(access, in: scope)
                    Issue.record("The lease limit allowed a simultaneous second lease")
                } catch let error as MiraError { #expect(error.code == .busy) }
                await first.release()
                let second = try await leases.acquire(access, in: scope)
                await second.release()
            }
        }
    }

    @Test func cancelledQuiescenceWaitLeavesLeaseOwned() async throws {
        try await withAccess { access in
            try await withScope(access) { scope, leases in
                let lease = try await leases.acquire(access, in: scope)
                let operation = try await access.begin(maintenanceRequest(), expected: lease.authorization)
                let waiting = Task {
                    do { try await access.waitForQuiescence(); return false }
                    catch is CancellationError { return true }
                    catch { return false }
                }
                await leases.registerTask { waiting.cancel(); _ = await waiting.value }
                try await waitUntil { await access.pendingQuiescenceWaiterCount == 1 }
                waiting.cancel()
                #expect(await waiting.value)
                #expect((await access.snapshot()).activeLeases == 1)
                await lease.release()
                _ = try await access.complete(operation, at: Date(timeIntervalSince1970: 1_700_000_200))
            }
        }
    }

    @Test func revokedLeaseCannotStartResourceAndStartedResourceDrainsBeforeRelease() async throws {
        try await withAccess { access in
            try await withScope(access) { scope, leases in
                let lease = try await leases.acquire(access, in: scope)
                let operation = try await access.begin(maintenanceRequest(), expected: lease.authorization)
                let factoryCalls = LockedFlag()
                do {
                    _ = try await lease.start {
                        factoryCalls.mark()
                        return AgentLibraryResource(value: "should-not-start", cleanup: {})
                    }
                    Issue.record("Revoked lease invoked the resource factory")
                } catch let error as MiraError { #expect(error.code == .unauthorized) }
                #expect(factoryCalls.isSet == false)

                await lease.release()
                _ = try await access.complete(operation, at: Date(timeIntervalSince1970: 1_700_000_300))
                let fresh = try await leases.acquire(access, in: scope)
                let cleanup = CleanupGate()
                await leases.registerGate(cleanup)
                let resource = try await fresh.start {
                    AgentLibraryResource(value: "resource", cleanup: { await cleanup.wait() })
                }
                #expect(resource.value == "resource")
                let resourceReleased = LockedFlag()
                let resourceReleasing = Task { await resource.release(); resourceReleased.mark() }
                await leases.registerTask { _ = await resourceReleasing.value }
                try await waitUntil { await cleanup.enteredState }
                #expect(resourceReleased.isSet == false)
                #expect((await access.snapshot()).activeLeases == 1)
                #expect((await access.snapshot()).activeResources == 1)
                await cleanup.open()
                _ = await resourceReleasing.value
                #expect(resourceReleased.isSet)
                #expect((await access.snapshot()).activeResources == 0)

                let secondCleanup = CleanupGate()
                await leases.registerGate(secondCleanup)
                _ = try await fresh.start {
                    AgentLibraryResource(value: "held", cleanup: { await secondCleanup.wait() })
                }
                let outerReleased = LockedFlag()
                let releasing = Task { await fresh.release(); outerReleased.mark() }
                await leases.registerTask { _ = await releasing.value }
                try await waitUntil { await secondCleanup.enteredState }
                #expect(outerReleased.isSet == false)
                await secondCleanup.open()
                _ = await releasing.value
                #expect(outerReleased.isSet)
            }
        }
    }

    private func withAccess<T>(maximumLeases: Int = 1_024,
                               _ body: (AgentLibraryAccess) async throws -> T) async throws -> T {
        let authorization = AgentLibraryAuthorization(libraryID: UUID(), epoch: 1)
        let access = try await AgentLibraryAccess.open(
            store: AccessStore(state: .init(authorization: authorization, pending: nil)),
            maximumLeases: maximumLeases)
        do {
            let result = try await body(access)
            await access.close()
            return result
        } catch {
            await access.close()
            throw error
        }
    }

    private func withScope<T>(_ access: AgentLibraryAccess,
                              _ body: (RuntimeScope, LeaseTracker) async throws -> T) async throws -> T {
        let scope = RuntimeScope(kind: .application)
        let leases = LeaseTracker()
        do {
            let result = try await body(scope, leases)
            await leases.releaseAll()
            await scope.dispose()
            return result
        } catch {
            await leases.releaseAll()
            await access.close()
            await scope.dispose()
            throw error
        }
    }

    private func maintenanceRequest() -> AgentLibraryMaintenanceRequest {
        .init(id: UUID(), namespace: "memory.purge", revision: 1, scope: .library,
              requestedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func pendingOperation(previous: AgentLibraryAuthorization) -> AgentLibraryMaintenanceOperation {
        .init(request: maintenanceRequest(), previousAuthorization: previous,
              authorization: .init(libraryID: previous.libraryID, epoch: previous.epoch + 1), completedAt: nil)
    }

    private func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard clock.now < deadline else { throw MiraError(.timeout, "Synthetic access state did not converge.") }
            await Task.yield()
        }
    }
}

private actor LeaseTracker {
    private var leases: [AgentLibraryAccessLease] = []
    private var gates: [CleanupGate] = []
    private var tasks: [@Sendable () async -> Void] = []

    func acquire(_ access: AgentLibraryAccess, in scope: RuntimeScope) async throws -> AgentLibraryAccessLease {
        let lease = try await access.acquire(in: scope)
        leases.append(lease)
        return lease
    }

    func releaseAll() async {
        for gate in gates { await gate.open() }
        for lease in leases.reversed() { await lease.release() }
        for task in tasks { await task() }
        tasks.removeAll(); gates.removeAll()
        leases.removeAll()
    }

    func registerGate(_ gate: CleanupGate) { gates.append(gate) }
    func registerTask(_ task: @escaping @Sendable () async -> Void) { tasks.append(task) }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    private var increments = 0

    var isSet: Bool { lock.withLock { marked } }
    var count: Int { lock.withLock { increments } }
    func mark() { lock.withLock { marked = true } }
    func increment() { lock.withLock { increments += 1 } }
}

private actor CleanupGate {
    private var entered = false
    private var openGate = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    var enteredState: Bool { entered }

    func wait() async {
        entered = true
        if !openGate { await withCheckedContinuation { releaseWaiters.append($0) } }
    }

    func open() {
        openGate = true
        releaseWaiters.forEach { $0.resume() }; releaseWaiters.removeAll()
    }

}

private actor AccessStore: AgentLibraryMaintenanceStore {
    private var storedState: AgentLibraryMaintenanceState
    private var operations: [UUID: AgentLibraryMaintenanceOperation] = [:]

    init(state: AgentLibraryMaintenanceState) {
        storedState = state
        if let pending = state.pending { operations[pending.request.id] = pending }
    }
    func state() async throws -> AgentLibraryMaintenanceState { storedState }
    func operation(id: UUID) async throws -> AgentLibraryMaintenanceOperation? { operations[id] }

    func begin(_ request: AgentLibraryMaintenanceRequest,
               expected: AgentLibraryAuthorization) async throws -> AgentLibraryMaintenanceOperation {
        if let existing = operations[request.id] {
            guard existing.request == request, existing.previousAuthorization == expected else {
                throw MiraError(.conflict, "Synthetic maintenance request identity changed.")
            }
            return existing
        }
        guard storedState.authorization == expected, storedState.pending == nil else {
            throw MiraError(.conflict, "Synthetic maintenance authorization changed.")
        }
        let operation = AgentLibraryMaintenanceOperation(request: request, previousAuthorization: expected,
            authorization: .init(libraryID: expected.libraryID, epoch: expected.epoch + 1), completedAt: nil)
        operations[request.id] = operation
        storedState = .init(authorization: operation.authorization, pending: operation)
        return operation
    }

    func complete(_ operation: AgentLibraryMaintenanceOperation,
                  at date: Date) async throws -> AgentLibraryMaintenanceOperation {
        if let existing = operations[operation.request.id], existing.completedAt != nil { return existing }
        guard storedState.pending == operation else { throw MiraError(.conflict, "Synthetic maintenance operation changed.") }
        let completed = AgentLibraryMaintenanceOperation(request: operation.request,
            previousAuthorization: operation.previousAuthorization, authorization: operation.authorization,
            completedAt: date)
        operations[operation.request.id] = completed
        storedState = .init(authorization: completed.authorization, pending: nil)
        return completed
    }
}
