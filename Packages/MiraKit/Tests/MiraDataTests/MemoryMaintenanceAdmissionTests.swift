import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Memory maintenance admission", .timeLimit(.minutes(1)))
struct MemoryMaintenanceAdmissionTests {
    @Test func anUnregisteredSourceValidatorCannotAdmitMaintenance() async throws {
        try await withAdmissionFixture { fixture in
            let coordinator = try fixture.coordinator()
            let request = fixture.request(scope: .sources([.domain(namespace: "memories", id: UUID(), revision: 1)]))
            await #expect(throws: MiraError.self) {
                _ = try await coordinator.perform(request, expected: fixture.initial)
            }
            #expect(try await fixture.authority.operation(id: request.id) == nil)
            #expect(try await fixture.authority.authorization() == fixture.initial)
            #expect(await fixture.access.snapshot().phase == .ready)
            await coordinator.close()
        }
    }

    @Test("A source validator rejects before commit while coordinator drains revoked work")
    func validatorRejectsBeforeCommitAndDrainsOwners() async throws {
        let validator = SQLiteLibraryMaintenanceValidator(
            identity: .init(namespace: "memory.maintenance", revision: 1),
            validate: { _, _ in throw MiraError(.unauthorized, "The memory source selection is not admissible.") })
        try await withAdmissionFixture(validators: [validator]) { fixture in
            let workScope = RuntimeScope(kind: .application)
            let lease = try await fixture.access.acquire(in: workScope)
            let owner = AdmissionOwnerProbe()
            let workOwner = AgentLibraryWorkOwner(id: "memory-worker") {
                await owner.enter()
                await owner.waitUntilReleased()
                await lease.release()
            }
            let coordinator = try fixture.coordinator(workOwners: [workOwner])
            let request = fixture.request(scope: .sources([.domain(namespace: "memories", id: UUID(), revision: 1)]))
            let task = Task { try await coordinator.perform(request, expected: fixture.initial) }
            do {
                try await eventually { await owner.entered }
                #expect((await fixture.access.snapshot()).phase != .ready)
                #expect((await fixture.access.snapshot()).activeLeases == 1)
                await owner.release()
                do {
                    _ = try await task.value
                    Issue.record("Validator rejection unexpectedly admitted maintenance.")
                } catch let error as MiraError {
                    #expect(error.code == .unauthorized)
                }
                #expect(try await fixture.authority.authorization() == fixture.initial)
                #expect(try await fixture.authority.operation(id: request.id) == nil)
                #expect((await fixture.access.snapshot()).phase == .ready)
                let replacement = try await fixture.access.acquire(in: workScope)
                try await replacement.check()
                await replacement.release()
            } catch {
                await owner.release()
                _ = await task.result
                await lease.release()
                await coordinator.close()
                await workScope.dispose()
                throw error
            }
            await coordinator.close()
            await workScope.dispose()
        }
    }

    @Test("A lost post-commit acknowledgement leaves uncertain pending state until exact retry")
    func lostBeginAcknowledgementKeepsPendingStateAndBlocksFreshLeases() async throws {
        let fault = AdmissionCommitFault()
        try await withAdmissionFixture(afterCommit: { try fault.hit($0) }) { fixture in
            let coordinator = try fixture.coordinator()
            let request = fixture.request()
            do {
                await #expect(throws: MiraError.self) {
                    _ = try await coordinator.perform(request, expected: fixture.initial)
                }
                let state = try await fixture.authority.state()
                #expect(state.authorization.epoch == fixture.initial.epoch + 1)
                #expect(state.pending?.request == request)
                #expect((await fixture.access.snapshot()).phase == .uncertain)
                #expect(await fixture.handler.applyCount == 0)
                let blockedScope = RuntimeScope(kind: .application)
                await #expect(throws: MiraError.self) { _ = try await fixture.access.acquire(in: blockedScope) }
                await blockedScope.dispose()

                let recovered = try await coordinator.perform(request, expected: fixture.initial)
                #expect(recovered.completedAt != nil)
                #expect(await fixture.handler.applyCount == 1)
                #expect(await fixture.handler.verifyCount == 1)
                #expect(try await fixture.authority.state().pending == nil)
                #expect((await fixture.access.snapshot()).phase == .ready)
                let freshScope = RuntimeScope(kind: .application)
                let freshLease = try await fixture.access.acquire(in: freshScope)
                try await freshLease.check()
                await freshLease.release()
                await freshScope.dispose()
            } catch {
                await coordinator.close()
                throw error
            }
            await coordinator.close()
        }
    }
}

private actor AdmissionOwnerProbe {
    private(set) var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() { entered = true }
    func waitUntilReleased() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor AdmissionHandler: AgentLibraryMaintenanceHandler {
    nonisolated let identity = AgentLibraryMaintenanceHandlerIdentity(namespace: "memory.maintenance", revision: 1)
    private(set) var applyCount = 0
    private(set) var verifyCount = 0

    func apply(_ operation: AgentLibraryMaintenanceOperation) async throws { applyCount += 1 }
    func verify(_ operation: AgentLibraryMaintenanceOperation) async throws { verifyCount += 1 }
}

private final class AdmissionCommitFault: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func hit(_ point: SQLiteLibraryAuthorityFaultPoint) throws {
        try lock.withLock {
            guard point == .afterBeginCommit, !fired else { return }
            fired = true
            throw MiraError(.storage, "Synthetic begin acknowledgement loss.")
        }
    }
}

private struct AdmissionFixture: Sendable {
    let directory: URL
    let database: DatabaseQueue
    let authority: SQLiteLibraryAuthority
    let access: AgentLibraryAccess
    let registry: RuntimeRegistry<any AgentLibraryMaintenanceHandler>
    let scope: RuntimeScope
    let handler: AdmissionHandler
    let initial: AgentLibraryAuthorization

    static func make(
        validators: [SQLiteLibraryMaintenanceValidator] = [],
        afterCommit: (@Sendable (SQLiteLibraryAuthorityFaultPoint) throws -> Void)? = nil
    ) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mira-memory-maintenance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var database: DatabaseQueue?
        var authority: SQLiteLibraryAuthority?
        var access: AgentLibraryAccess?
        var scope: RuntimeScope?
        do {
            var configuration = Configuration()
            configuration.foreignKeysEnabled = true
            configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
            let db = try DatabaseQueue(
                path: directory.appendingPathComponent("business.sqlite").path, configuration: configuration)
            database = db
            let store = try SQLiteLibraryAuthority(database: db, validators: validators, afterCommit: afterCommit)
            authority = store
            let gate = try await AgentLibraryAccess.open(store: store)
            access = gate
            let registry = RuntimeRegistry<any AgentLibraryMaintenanceHandler>()
            let libraryScope = RuntimeScope(kind: .library(store.libraryID))
            scope = libraryScope
            let handler = AdmissionHandler()
            try await registry.register(id: "memory-maintenance", value: handler, scope: libraryScope)
            return .init(
                directory: directory, database: db, authority: store, access: gate,
                registry: registry, scope: libraryScope, handler: handler,
                initial: try await store.authorization())
        } catch {
            await access?.close()
            await scope?.dispose()
            await authority?.close()
            try? database?.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func request(scope: AgentLibraryMaintenanceScope = .library) -> AgentLibraryMaintenanceRequest {
        .init(
            id: UUID(), namespace: "memory.maintenance", revision: 1, scope: scope,
            requestedAt: Date(timeIntervalSince1970: 1_900_000_000))
    }

    func coordinator(workOwners: [AgentLibraryWorkOwner] = []) throws -> AgentLibraryMaintenanceCoordinator {
        try .init(
            access: access, handlers: registry, workOwners: workOwners,
            now: { Date(timeIntervalSince1970: 1_900_000_100) })
    }

    func close() async {
        await access.close()
        await scope.dispose()
        await authority.close()
        try? database.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func withAdmissionFixture<T>(
    validators: [SQLiteLibraryMaintenanceValidator] = [],
    afterCommit: (@Sendable (SQLiteLibraryAuthorityFaultPoint) throws -> Void)? = nil,
    _ body: (AdmissionFixture) async throws -> T
) async throws -> T {
    let fixture = try await AdmissionFixture.make(validators: validators, afterCommit: afterCommit)
    do {
        let value = try await body(fixture)
        await fixture.close()
        return value
    } catch {
        await fixture.close()
        throw error
    }
}

private func eventually(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            throw MiraError(.timeout, "Synthetic maintenance admission did not reach the expected state.")
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}
