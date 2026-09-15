import Foundation
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Snapshot task ownership", .timeLimit(.minutes(1)))
struct AgentLibrarySnapshotOwnershipTests {
    @Test(arguments: [false, true])
    func gateCloseWaitsForActualExportAndCannotBeOverwrittenByFailureProof(duringFailureProof: Bool) async throws {
        let fixture = try await LibraryAccessFixture.make()
        await fixture.access.close()
        let proof = SnapshotOwnershipBarrier()
        let store = SnapshotProofStore(base: fixture.authority, proof: proof, blockThirdRead: duringFailureProof)
        let access = try await AgentLibraryAccess.open(store: store)
        let expected = try await fixture.authority.authorization()
        let coordinator = try AgentLibraryMaintenanceCoordinator(
            access: access,
            handlers: RuntimeRegistry<any AgentLibraryMaintenanceHandler>(), workOwners: [])
        let copying = SnapshotOwnershipBarrier()
        let closed = SnapshotOwnershipBarrier()
        let scope = RuntimeScope(kind: .application)
        let export = Task {
            try await coordinator.withQuiescentSnapshot(expected: expected) { authorization in
                await copying.wait()
                if duringFailureProof { throw MiraError(.storage, "Synthetic snapshot publication failure.") }
                return authorization
            }
        }
        var closing: Task<Void, Never>?
        do {
            try await eventually { await copying.entered }
            if duringFailureProof {
                await copying.release()
                try await eventually { await proof.entered }
            }
            closing = Task {
                await access.close()
                await closed.release()
            }
            try await eventually { await access.snapshot().phase == .closing }
            #expect(await closed.released == false)
            await #expect(throws: MiraError.self) { _ = try await access.acquire(in: scope) }
            await copying.release()
            await proof.release()
            switch await export.result {
            case .success: Issue.record("A closing snapshot published a result to its waiter.")
            case .failure(let error):
                if duringFailureProof {
                    #expect((error as? MiraError)?.code == .storage)
                } else {
                    #expect(error is CancellationError)
                }
            }
            await closing?.value
            #expect(await access.snapshot().phase == .closed)
            #expect(await closed.released)
            #expect(try await fixture.authority.authorization() == expected)
            #expect(try await fixture.authority.state().pending == nil)
        } catch {
            await copying.release()
            await proof.release()
            _ = await export.result
            await closing?.value
            await coordinator.close()
            await access.close()
            await scope.dispose()
            await fixture.close()
            throw error
        }
        await coordinator.close()
        await access.close()
        await scope.dispose()
        await fixture.close()
    }

    @Test func snapshotCannotBeginCopyingWhileProducerOrRevokedReadStillRuns() async throws {
        let fixture = try await LibraryAccessFixture.make()
        let expected = try await fixture.authority.authorization()
        let scope = RuntimeScope(kind: .application)
        let lease = try await fixture.access.acquire(in: scope)
        let producer = SnapshotOwnershipBarrier()
        let reader = SnapshotOwnershipBarrier()
        let copying = SnapshotOwnershipBarrier()
        let reading = Task {
            try await lease.read {
                await reader.wait()
                return "synthetic private body"
            }
        }
        let coordinator = try AgentLibraryMaintenanceCoordinator(
            access: fixture.access,
            handlers: RuntimeRegistry<any AgentLibraryMaintenanceHandler>(),
            workOwners: [
                .init(id: "producer") {
                    await producer.wait()
                    await lease.release()
                }
            ])
        var export: Task<AgentLibraryAuthorization, any Error>?
        do {
            try await eventually { await reader.entered }
            export = Task {
                try await coordinator.withQuiescentSnapshot(expected: expected) { authorization in
                    await copying.release()
                    return authorization
                }
            }
            try await eventually { await producer.entered }
            #expect(lease.isRevoked)
            #expect(await copying.released == false)
            await producer.release()
            try await eventually { await fixture.access.pendingLeaseReleaseCount == 1 }
            #expect(await fixture.access.snapshot().activeReads == 1)
            #expect(await copying.released == false)
            await reader.release()
            await #expect(throws: MiraError.self) { _ = try await reading.value }
            #expect(try await export?.value == expected)
            #expect(await copying.released)
            #expect(await fixture.access.snapshot().phase == .ready)
            #expect(try await fixture.authority.authorization() == expected)
        } catch {
            await producer.release()
            await reader.release()
            _ = await reading.result
            await lease.release()
            _ = await export?.result
            await coordinator.close()
            await scope.dispose()
            await fixture.close()
            throw error
        }
        await coordinator.close()
        await scope.dispose()
        await fixture.close()
    }

    @Test func authorityChangeWhileQuiescingPreventsCopying() async throws {
        let fixture = try await LibraryAccessFixture.make()
        let expected = try await fixture.authority.authorization()
        let producer = SnapshotOwnershipBarrier()
        let copying = SnapshotOwnershipBarrier()
        let coordinator = try AgentLibraryMaintenanceCoordinator(
            access: fixture.access,
            handlers: RuntimeRegistry<any AgentLibraryMaintenanceHandler>(),
            workOwners: [
                .init(id: "producer") { await producer.wait() }
            ])
        let export = Task {
            try await coordinator.withQuiescentSnapshot(expected: expected) { authorization in
                await copying.release()
                return authorization
            }
        }
        do {
            try await eventually { await producer.entered }
            // Simulate an unexpected authority mutation outside the single host gate.
            let request = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: "snapshot.fixture", revision: 1,
                scope: .library, requestedAt: Date(timeIntervalSince1970: 10))
            let operation = try await fixture.authority.begin(request, expected: expected)
            await producer.release()
            await #expect(throws: MiraError.self) { _ = try await export.value }
            #expect(await copying.released == false)
            #expect(await fixture.access.snapshot().phase == .uncertain)
            #expect(try await fixture.authority.state().pending == operation)
        } catch {
            await producer.release()
            _ = await export.result
            await coordinator.close()
            await fixture.close()
            throw error
        }
        await coordinator.close()
        await fixture.close()
    }

    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                throw MiraError(.timeout, "Synthetic snapshot ownership did not converge.")
            }
            await Task.yield()
        }
    }
}

private actor SnapshotOwnershipBarrier {
    private(set) var entered = false
    private(set) var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        released = true
        let values = waiters
        waiters.removeAll()
        values.forEach { $0.resume() }
    }
}

private actor SnapshotProofStore: AgentLibraryMaintenanceStore {
    let base: SQLiteLibraryAuthority
    let proof: SnapshotOwnershipBarrier
    let blockThirdRead: Bool
    var reads = 0
    init(base: SQLiteLibraryAuthority, proof: SnapshotOwnershipBarrier, blockThirdRead: Bool) {
        self.base = base
        self.proof = proof
        self.blockThirdRead = blockThirdRead
    }
    func state() async throws -> AgentLibraryMaintenanceState {
        reads += 1
        let state = try await base.state()
        if blockThirdRead && reads == 3 { await proof.wait() }
        return state
    }
    func operation(id: UUID) async throws -> AgentLibraryMaintenanceOperation? { try await base.operation(id: id) }
    func begin(_ request: AgentLibraryMaintenanceRequest, expected: AgentLibraryAuthorization) async throws
        -> AgentLibraryMaintenanceOperation
    {
        try await base.begin(request, expected: expected)
    }
    func complete(_ operation: AgentLibraryMaintenanceOperation, at date: Date) async throws
        -> AgentLibraryMaintenanceOperation
    {
        try await base.complete(operation, at: date)
    }
}
