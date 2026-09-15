import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Agent library quiescent snapshots", .timeLimit(.minutes(1)))
struct AgentLibrarySnapshotTests {
    @Test
    func successfulExportQuiescesOwnersRevokesOldLeaseAndLeavesAuthorityUnchanged() async throws {
        let fixture = try await SnapshotFixture.make()
        let workScope = RuntimeScope(kind: .application)
        let lease = try await fixture.access.acquire(in: workScope)
        let ownerGate = SnapshotGate()
        let owner = AgentLibraryWorkOwner(id: "producer") {
            await ownerGate.enter()
            await lease.release()
        }
        let coordinator = try fixture.coordinator(owners: [owner])
        do {
            let result = try await coordinator.withQuiescentSnapshot(expected: fixture.initial) { authorization in
                authorization
            }
            #expect(result == fixture.initial)
            #expect(lease.isRevoked)
            await #expect(throws: MiraError.self) { try await lease.check() }
            #expect(try await fixture.authority.authorization() == fixture.initial)
            #expect(try await fixture.authority.state().pending == nil)
            #expect((await fixture.access.snapshot()).phase == .ready)
        } catch {
            await ownerGate.release()
            await lease.release()
            await coordinator.close()
            await workScope.dispose()
            await fixture.close()
            throw error
        }
        await coordinator.close()
        await workScope.dispose()
        await fixture.close()
    }

    @Test
    func failedExportRestoresReadyGateAndDoesNotWriteMaintenanceState() async throws {
        let fixture = try await SnapshotFixture.make()
        let coordinator = try fixture.coordinator()
        do {
            await #expect(throws: MiraError.self) {
                _ = try await coordinator.withQuiescentSnapshot(expected: fixture.initial) { _ in
                    throw MiraError(.storage, "Synthetic export failure.")
                }
            }
            #expect((await fixture.access.snapshot()).phase == .ready)
            #expect(try await fixture.authority.authorization() == fixture.initial)
            #expect(try await fixture.authority.state().pending == nil)
            let retry = try await coordinator.withQuiescentSnapshot(expected: fixture.initial) { $0 }
            #expect(retry == fixture.initial)
        } catch {
            await coordinator.close()
            await fixture.close()
            throw error
        }
        await coordinator.close()
        await fixture.close()
    }

    @Test
    func pendingMaintenanceRejectsSnapshotWithoutChangingPendingOperation() async throws {
        let fixture = try await SnapshotFixture.make()
        let coordinator = try fixture.coordinator()
        do {
            let request = fixture.request()
            let pending = try await fixture.access.begin(request, expected: fixture.initial)
            await #expect(throws: MiraError.self) {
                _ = try await coordinator.withQuiescentSnapshot(expected: fixture.initial) { $0 }
            }
            #expect(try await fixture.authority.state().pending == pending)
            #expect((await fixture.access.snapshot()).phase == .maintenance)
        } catch {
            await coordinator.close()
            await fixture.close()
            throw error
        }
        await coordinator.close()
        await fixture.close()
    }

    @Test
    func quiesceFailureLeavesUncertainGateUntilAccessReopens() async throws {
        let fixture = try await SnapshotFixture.make()
        let coordinator = try fixture.coordinator(owners: [
            .init(id: "blocked") { throw MiraError(.storage, "Synthetic quiesce failure.") }
        ])
        do {
            await #expect(throws: AgentLibraryMaintenanceError.unsettledWork(["blocked"])) {
                _ = try await coordinator.withQuiescentSnapshot(expected: fixture.initial) { $0 }
            }
            #expect((await fixture.access.snapshot()).phase == .uncertain)
            await coordinator.close()
            await fixture.access.close()
            await fixture.authority.close()
            let authority = try SQLiteLibraryAuthority(database: fixture.database)
            let access = try await AgentLibraryAccess.open(store: authority)
            let reopened = try AgentLibraryMaintenanceCoordinator(
                access: access, handlers: RuntimeRegistry<any AgentLibraryMaintenanceHandler>(), workOwners: [])
            let result = try await reopened.withQuiescentSnapshot(expected: fixture.initial) { $0 }
            #expect(result == fixture.initial)
            await reopened.close()
            await access.close()
            await authority.close()
        } catch {
            await coordinator.close()
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test
    func snapshotIsExclusiveCancellationDoesNotAbandonExportAndCloseWaits() async throws {
        let fixture = try await SnapshotFixture.make()
        let gate = SnapshotGate()
        let finished = SnapshotGate()
        let coordinator = try fixture.coordinator()
        let primary = Task {
            try await coordinator.withQuiescentSnapshot(expected: fixture.initial) { authorization in
                await gate.enter()
                await gate.wait()
                await finished.enter()
                return authorization
            }
        }
        do {
            try await snapshotEventually { await gate.entered }
            await #expect(throws: AgentLibraryMaintenanceError.busy) {
                _ = try await coordinator.withQuiescentSnapshot(expected: fixture.initial) { $0 }
            }
            await #expect(throws: AgentLibraryMaintenanceError.busy) {
                _ = try await coordinator.perform(fixture.request(), expected: fixture.initial)
            }
            primary.cancel()
            let closing = Task {
                await coordinator.close()
                await finished.release()
            }
            try await snapshotEventually {
                do {
                    _ = try await coordinator.withQuiescentSnapshot(expected: fixture.initial) { $0 }
                    return false
                } catch AgentLibraryMaintenanceError.closed { return true } catch { return false }
            }
            #expect(await finished.released == false)
            await gate.release()
            let result = try await primary.value
            #expect(result == fixture.initial)
            try await snapshotEventually { await finished.entered }
            await closing.value
            #expect((await fixture.access.snapshot()).phase == .ready)
            await fixture.access.close()
            #expect((await fixture.access.snapshot()).phase == .closed)
        } catch {
            await gate.release()
            _ = await primary.result
            await coordinator.close()
            await fixture.close()
            throw error
        }
        await fixture.close()
    }
}

private struct SnapshotFixture: Sendable {
    let root: URL
    let database: DatabaseQueue
    let authority: SQLiteLibraryAuthority
    let access: AgentLibraryAccess
    let initial: AgentLibraryAuthorization

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mira-snapshot-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
        let database = try DatabaseQueue(
            path: root.appendingPathComponent("business.sqlite").path, configuration: configuration)
        let authority = try SQLiteLibraryAuthority(database: database)
        let access = try await AgentLibraryAccess.open(store: authority)
        let initial = try await authority.authorization()
        return .init(root: root, database: database, authority: authority, access: access, initial: initial)
    }

    func coordinator(owners: [AgentLibraryWorkOwner] = []) throws -> AgentLibraryMaintenanceCoordinator {
        try .init(access: access, handlers: RuntimeRegistry<any AgentLibraryMaintenanceHandler>(), workOwners: owners)
    }

    func request() -> AgentLibraryMaintenanceRequest {
        .init(
            id: UUID(), namespace: "snapshot.pending", revision: 1, scope: .library,
            requestedAt: Date(timeIntervalSince1970: 10))
    }

    func close() async {
        await access.close()
        await authority.close()
        try? database.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private actor SnapshotGate {
    private(set) var entered = false
    private(set) var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() { entered = true }
    func wait() async { if !released { await withCheckedContinuation { waiters.append($0) } } }
    func release() {
        released = true
        resumeWaiters()
    }
    private func resumeWaiters() {
        let values = waiters
        waiters.removeAll()
        values.forEach { $0.resume() }
    }
}

private func snapshotEventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard ContinuousClock.now < end else { throw MiraError(.timeout, "Synthetic snapshot state did not converge.") }
        await Task.yield()
    }
}
