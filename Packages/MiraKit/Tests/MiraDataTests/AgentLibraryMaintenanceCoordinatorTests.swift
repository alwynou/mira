import Foundation
import Testing
import GRDB
@testable import MiraCore
@testable import MiraData

@Suite("Agent library maintenance coordinator", .timeLimit(.minutes(1)))
struct AgentLibraryMaintenanceCoordinatorTests {
    @Test func heldOwnersAndReadsPreventCleanupAndCallerCancellationCannotAbandonIt() async throws {
        let fixture = try await CoordinatorFixture.make()
        let producer = CoordinatorBarrier(), reader = CoordinatorBarrier()
        let workScope = RuntimeScope(kind: .application)
        let lease = try await fixture.access.acquire(in: workScope)
        let reading = Task { try await lease.read { await reader.wait(); return "private" } }
        let owner = AgentLibraryWorkOwner(id: "producer") { await producer.wait(); await lease.release() }
        let coordinator = try fixture.coordinator(owners: [owner])
        let command = fixture.request()
        var maintaining: Task<AgentLibraryMaintenanceOperation, any Error>?
        var duplicate: Task<AgentLibraryMaintenanceOperation, any Error>?
        var closing: Task<Void, Never>?
        let closed = CoordinatorBarrier()
        do {
            try await eventually { await reader.entered }
            maintaining = Task { try await coordinator.perform(command, expected: fixture.initial) }
            try await eventually { await producer.entered }
            maintaining?.cancel()
            duplicate = Task { try await coordinator.perform(command, expected: fixture.initial) }
            try await eventually { await coordinator.joiningWaiterCount == 1 }
            #expect(lease.isRevoked)
            #expect(await fixture.handler.applyCount == 0)
            await #expect(throws: AgentLibraryMaintenanceError.busy) {
                try await coordinator.perform(fixture.request(), expected: fixture.initial)
            }
            closing = Task { await coordinator.close(); await closed.release() }
            await producer.release()
            try await eventually { await fixture.access.pendingLeaseReleaseCount == 1 }
            #expect(await fixture.handler.applyCount == 0)
            #expect(await closed.isReleased == false)
            #expect((await fixture.access.snapshot()).activeReads == 1)
            await reader.release()
            do { _ = try await reading.value; Issue.record("A revoked read published bytes.") }
            catch let error as MiraError { #expect(error.code == .unauthorized) }
            let result = try await maintaining!.value
            #expect(try await duplicate!.value == result)
            await closing?.value
            #expect(result.authorization.epoch == fixture.initial.epoch + 1)
            #expect(result.completedAt == fixture.finishedAt)
            #expect(await fixture.handler.applyCount == 1)
            #expect(await fixture.handler.verifyCount == 1)
            #expect(try await fixture.deletedCount() == 1)
            #expect((await fixture.access.snapshot()).phase == .ready)
            await #expect(throws: AgentLibraryMaintenanceError.closed) {
                try await coordinator.perform(command, expected: fixture.initial)
            }
        } catch {
            await producer.release(); await reader.release(); _ = await reading.result
            await lease.release(); _ = await maintaining?.result; _ = await duplicate?.result
            await closing?.value; await coordinator.close(); await workScope.dispose(); await fixture.close()
            throw error
        }
        await coordinator.close(); await workScope.dispose(); await fixture.close()
    }

    @Test func everyOwnerIsStoppedAfterOneFailsAndPendingOperationCanBeRetried() async throws {
        let fixture = try await CoordinatorFixture.make()
        let first = CoordinatorOwner(failing: true), second = CoordinatorOwner(failing: false)
        let coordinator = try fixture.coordinator(owners: [
            .init(id: "first") { try await first.stop() }, .init(id: "second") { try await second.stop() }
        ])
        do {
            let command = fixture.request()
            await #expect(throws: AgentLibraryMaintenanceError.unsettledWork(["first"])) {
                try await coordinator.perform(command, expected: fixture.initial)
            }
            #expect(await first.count == 1)
            #expect(await second.count == 1)
            #expect(await fixture.handler.applyCount == 0)
            #expect(try await fixture.authority.state().pending?.request == command)
            await #expect(throws: MiraError.self) { try await fixture.access.checkReady() }
            await first.allow()
            let done = try await coordinator.perform(command, expected: fixture.initial)
            #expect(done.authorization.epoch == fixture.initial.epoch + 1)
            #expect(await first.count == 2)
            #expect(await second.count == 2)
            #expect(await fixture.handler.verifyCount == 1)
        } catch { await coordinator.close(); await fixture.close(); throw error }
        await coordinator.close(); await fixture.close()
    }

    @Test(arguments: ["apply", "verify"])
    func committedDomainCleanupSurvivesFailureAndCoordinatorRecreation(stage: String) async throws {
        let fixture = try await CoordinatorFixture.make()
        if stage == "verify" { await fixture.handler.failVerificationOnce() }
        else { await fixture.handler.failApplyOnce() }
        let coordinator = try fixture.coordinator()
        let command = fixture.request()
        do {
            await #expect(throws: CoordinatorFault.verification) {
                try await coordinator.perform(command, expected: fixture.initial)
            }
            #expect(try await fixture.deletedCount() == 1)
            #expect(try await fixture.authority.state().pending?.request == command)
            #expect((await fixture.access.snapshot()).phase == .maintenance)
            await coordinator.close(); await fixture.access.close(); await fixture.authority.close()
            // A new adapter and gate read the actual durable pending operation.
            let authority = try SQLiteLibraryAuthority(database: fixture.database)
            let access = try await AgentLibraryAccess.open(store: authority)
            let recovered = try AgentLibraryMaintenanceCoordinator(access: access, handlers: fixture.registry, workOwners: [])
            do {
                #expect((await access.snapshot()).phase == .maintenance)
                let done = try await recovered.perform(command, expected: fixture.initial)
                #expect(done.completedAt != nil)
                #expect(done.authorization.epoch == fixture.initial.epoch + 1)
                #expect(await fixture.handler.applyCount == 2)
                #expect(await fixture.handler.verifyCount == (stage == "verify" ? 2 : 1))
                #expect(try await fixture.deletedCount() == 1)
                #expect(try await authority.state().pending == nil)
                await recovered.close(); await access.close(); await authority.close()
            } catch { await recovered.close(); await access.close(); await authority.close(); throw error }
        } catch { await coordinator.close(); await fixture.close(); throw error }
        await fixture.close()
    }

    @Test(arguments: [false, true])
    func completionFailureBeforeCommitRetainsDateAndVerifiedWorkForExactRetry(recreateCoordinator: Bool) async throws {
        let fixture = try await CoordinatorFixture.make(failBeforeComplete: true)
        let clock = CoordinatorClock()
        let coordinator = try AgentLibraryMaintenanceCoordinator(access: fixture.access, handlers: fixture.registry,
            workOwners: [], now: { clock.next() })
        do {
            let command = fixture.request()
            await #expect(throws: CoordinatorFault.verification) {
                try await coordinator.perform(command, expected: fixture.initial)
            }
            #expect(try await fixture.authority.state().pending?.request == command)
            #expect((await fixture.access.snapshot()).phase == .uncertain)
            let retry: AgentLibraryMaintenanceCoordinator
            if recreateCoordinator {
                await coordinator.close()
                try await fixture.registry.unregister(id: "fixture")
                retry = try fixture.coordinator()
            } else { retry = coordinator }
            let done: AgentLibraryMaintenanceOperation
            do { done = try await retry.perform(command, expected: fixture.initial); await retry.close() }
            catch { await retry.close(); throw error }
            #expect(done.completedAt == clock.first)
            #expect(clock.calls == 1)
            #expect(await fixture.handler.applyCount == 1)
            #expect(await fixture.handler.verifyCount == 1)
        } catch { await coordinator.close(); await fixture.close(); throw error }
        await coordinator.close(); await fixture.close()
    }

    @Test(arguments: [SQLiteLibraryAuthorityFaultPoint.afterBeginCommit, .afterCompletionCommit])
    func lostCommitConfirmationRetainsOriginalCommandAndDoesNotRepeatDomainWork(point: SQLiteLibraryAuthorityFaultPoint) async throws {
        let fault = CoordinatorCommitFault(point)
        let fixture = try await CoordinatorFixture.make(fault: fault)
        let owner = CoordinatorOwner(failing: false)
        let coordinator = try fixture.coordinator(owners: [.init(id: "work") { try await owner.stop() }])
        do {
            let command = fixture.request()
            await #expect(throws: MiraError.self) { try await coordinator.perform(command, expected: fixture.initial) }
            #expect((await fixture.access.snapshot()).phase == .uncertain)
            #expect(await owner.count == 1)
            #expect(fault.count == 1)
            let fact = try #require(try await fixture.authority.operation(id: command.id))
            #expect(fact.authorization.epoch == fixture.initial.epoch + 1)
            let done = try await coordinator.perform(command, expected: fixture.initial)
            #expect(done.completedAt == fixture.finishedAt)
            #expect(done.authorization == fact.authorization)
            #expect(await fixture.handler.applyCount == 1)
            #expect(await fixture.handler.verifyCount == 1)
            #expect(fault.count == 1)
            try await fixture.access.checkReady()
        } catch { await coordinator.close(); await fixture.close(); throw error }
        await coordinator.close(); await fixture.close()
    }

    @Test(arguments: [false, true])
    func completedLookupReconcilesLostConfirmationAfterCoordinatorRecreationWithoutHandler(reopenAccess: Bool) async throws {
        let fixture = try await CoordinatorFixture.make(fault: CoordinatorCommitFault(.afterCompletionCommit))
        let coordinator = try fixture.coordinator(), command = fixture.request()
        do {
            await #expect(throws: MiraError.self) { try await coordinator.perform(command, expected: fixture.initial) }
            await coordinator.close()
            try await fixture.registry.unregister(id: "fixture")
            let access: AgentLibraryAccess
            if reopenAccess {
                await fixture.access.close()
                access = try await AgentLibraryAccess.open(store: fixture.authority)
            } else { access = fixture.access }
            let recovered = try AgentLibraryMaintenanceCoordinator(access: access, handlers: fixture.registry, workOwners: [])
            do {
                let done = try await recovered.perform(command, expected: fixture.initial)
                #expect(done.completedAt == fixture.finishedAt)
                try await access.checkReady()
                #expect(await fixture.handler.applyCount == 1)
                await recovered.close(); await access.close()
            } catch { await recovered.close(); await access.close(); throw error }
        } catch { await coordinator.close(); await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func oldCompletedCommandDoesNotRevokeFreshLeaseOrClearLaterPendingOperation() async throws {
        let fixture = try await CoordinatorFixture.make()
        let coordinator = try fixture.coordinator()
        let scope = RuntimeScope(kind: .application)
        var lease: AgentLibraryAccessLease?
        do {
            let command = fixture.request()
            let done = try await coordinator.perform(command, expected: fixture.initial)
            lease = try await fixture.access.acquire(in: scope)
            #expect(try await coordinator.perform(command, expected: fixture.initial) == done)
            try await lease!.check()
            let later = try await fixture.access.begin(fixture.request(), expected: done.authorization)
            #expect(try await coordinator.perform(command, expected: fixture.initial) == done)
            #expect(try await fixture.authority.state().pending == later)
            #expect((await fixture.access.snapshot()).phase == .maintenance)
            let changed = AgentLibraryMaintenanceRequest(id: command.id, namespace: command.namespace, revision: 2,
                scope: command.scope, requestedAt: command.requestedAt)
            await #expect(throws: AgentLibraryMaintenanceError.conflict) {
                try await coordinator.perform(changed, expected: fixture.initial)
            }
        } catch { await lease?.release(); await coordinator.close(); await scope.dispose(); await fixture.close(); throw error }
        await lease?.release(); await coordinator.close(); await scope.dispose(); await fixture.close()
    }

    @Test(arguments: ["missing", "application", "wrong-library", "duplicate", "revision"])
    func invalidCatalogueFailsBeforeRevocationOrEpochAdvance(kind: String) async throws {
        let fixture = try await CoordinatorFixture.make()
        let scope = RuntimeScope(kind: kind == "application" ? .application : .library(UUID()))
        let coordinator = try fixture.coordinator()
        let workScope = RuntimeScope(kind: .application)
        let lease = try await fixture.access.acquire(in: workScope)
        do {
            let expected: AgentLibraryMaintenanceError
            switch kind {
            case "application", "wrong-library":
                try await fixture.registry.unregister(id: "fixture")
                try await fixture.registry.register(id: "fixture", value: fixture.handler, scope: scope)
                expected = .invalidHandlerScope("fixture")
            case "duplicate":
                try await fixture.registry.register(id: "duplicate", value: fixture.handler, scope: fixture.scope)
                expected = .duplicateHandler(fixture.handler.identity)
            case "revision":
                expected = .missingHandler(.init(namespace: "test.cleanup", revision: 2))
            default:
                try await fixture.registry.unregister(id: "fixture")
                expected = .missingHandler(fixture.handler.identity)
            }
            let command = fixture.request(revision: kind == "revision" ? 2 : 1)
            await #expect(throws: expected) { try await coordinator.perform(command, expected: fixture.initial) }
            try await lease.check()
            #expect(try await fixture.authority.authorization() == fixture.initial)
            #expect(await fixture.handler.applyCount == 0)
        } catch { await lease.release(); await coordinator.close(); await scope.dispose(); await workScope.dispose(); await fixture.close(); throw error }
        await lease.release(); await coordinator.close(); await scope.dispose(); await workScope.dispose(); await fixture.close()
    }

    @Test func handlerScopeIsPinnedUntilVerificationActuallyReturns() async throws {
        let fixture = try await CoordinatorFixture.make()
        let verify = CoordinatorBarrier(), disposed = CoordinatorBarrier()
        await fixture.handler.holdVerification(verify)
        let coordinator = try fixture.coordinator()
        let task = Task { try await coordinator.perform(fixture.request(), expected: fixture.initial) }
        var closing: Task<Void, Never>?
        do {
            try await eventually { await verify.entered }
            closing = Task { await fixture.scope.dispose(); await disposed.release() }
            try await eventually { await fixture.scope.isDisposed }
            #expect(await disposed.isReleased == false)
            #expect(try await fixture.authority.state().pending != nil)
            await verify.release()
            #expect(try await task.value.completedAt != nil)
            await closing?.value
            #expect(await disposed.isReleased)
        } catch { await verify.release(); _ = await task.result; await closing?.value; await coordinator.close(); await fixture.close(); throw error }
        await coordinator.close(); await fixture.close()
    }
}

private func eventually(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw CoordinatorFault.timeout }
        try await Task.sleep(for: .milliseconds(1))
    }
}
private enum CoordinatorFault: Error { case verification, timeout, unsettled }
private actor CoordinatorBarrier {
    private(set) var entered = false
    private(set) var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { entered = true; if !isReleased { await withCheckedContinuation { waiters.append($0) } } }
    func release() { isReleased = true; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
}
private actor CoordinatorOwner {
    private(set) var count = 0
    private var failing: Bool
    init(failing: Bool) { self.failing = failing }
    func allow() { failing = false }
    func stop() throws { count += 1; if failing { throw CoordinatorFault.unsettled } }
}

/// A real transactional synthetic domain adapter, intentionally not a production privacy handler.
private actor CoordinatorHandler: AgentLibraryMaintenanceHandler {
    nonisolated let identity = AgentLibraryMaintenanceHandlerIdentity(namespace: "test.cleanup", revision: 1)
    let database: DatabaseQueue
    private(set) var applyCount = 0
    private(set) var verifyCount = 0
    private var failVerification = false
    private var failApply = false
    private var verificationBarrier: CoordinatorBarrier?
    init(database: DatabaseQueue) { self.database = database }
    func failVerificationOnce() { failVerification = true }
    func failApplyOnce() { failApply = true }
    func holdVerification(_ barrier: CoordinatorBarrier) { verificationBarrier = barrier }
    func apply(_ operation: AgentLibraryMaintenanceOperation) async throws {
        applyCount += 1
        try await database.write { db in
            try db.execute(sql: "DELETE FROM synthetic_private_values")
            try db.execute(sql: "INSERT OR IGNORE INTO synthetic_deletions (operation_id) VALUES (?)",
                           arguments: [operation.request.id.uuidString])
        }
        if failApply { failApply = false; throw CoordinatorFault.verification }
    }
    func verify(_ operation: AgentLibraryMaintenanceOperation) async throws {
        verifyCount += 1
        await verificationBarrier?.wait()
        if failVerification { failVerification = false; throw CoordinatorFault.verification }
        let valid = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM synthetic_private_values") == 0 &&
                Int.fetchOne(db, sql: "SELECT count(*) FROM synthetic_deletions WHERE operation_id = ?",
                             arguments: [operation.request.id.uuidString]) == 1
        }
        guard valid else { throw CoordinatorFault.verification }
    }
}

private final class CoordinatorClock: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let first = Date(timeIntervalSince1970: 1_700_000_123)
    var calls: Int { lock.withLock { count } }
    func next() -> Date { lock.withLock { count += 1; return first.addingTimeInterval(Double(count - 1)) } }
}

private actor BeforeCompletionFailure: AgentLibraryMaintenanceStore {
    let base: SQLiteLibraryAuthority
    private var failed = false
    init(base: SQLiteLibraryAuthority) { self.base = base }
    func state() async throws -> AgentLibraryMaintenanceState { try await base.state() }
    func operation(id: UUID) async throws -> AgentLibraryMaintenanceOperation? { try await base.operation(id: id) }
    func begin(_ request: AgentLibraryMaintenanceRequest, expected: AgentLibraryAuthorization) async throws -> AgentLibraryMaintenanceOperation {
        try await base.begin(request, expected: expected)
    }
    func complete(_ operation: AgentLibraryMaintenanceOperation, at date: Date) async throws -> AgentLibraryMaintenanceOperation {
        if !failed { failed = true; throw CoordinatorFault.verification }
        return try await base.complete(operation, at: date)
    }
}

private final class CoordinatorCommitFault: @unchecked Sendable {
    private let lock = NSLock()
    private let point: SQLiteLibraryAuthorityFaultPoint
    private var hits = 0
    init(_ point: SQLiteLibraryAuthorityFaultPoint) { self.point = point }
    var count: Int { lock.withLock { hits } }
    func hit(_ actual: SQLiteLibraryAuthorityFaultPoint) throws {
        try lock.withLock {
            guard actual == point else { return }
            hits += 1
            if hits == 1 { throw MiraError(.storage, "Synthetic maintenance commit acknowledgement was lost.") }
        }
    }
}

private struct CoordinatorFixture: Sendable {
    let database: DatabaseQueue
    let authority: SQLiteLibraryAuthority
    let access: AgentLibraryAccess
    let registry: RuntimeRegistry<any AgentLibraryMaintenanceHandler>
    let handler: CoordinatorHandler
    let scope: RuntimeScope
    let initial: AgentLibraryAuthorization
    let directory: URL
    let finishedAt = Date(timeIntervalSince1970: 1_700_000_100)

    static func make(fault: CoordinatorCommitFault? = nil, failBeforeComplete: Bool = false) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-maintenance-coordinator-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var database: DatabaseQueue?, authority: SQLiteLibraryAuthority?, access: AgentLibraryAccess?, scope: RuntimeScope?
        do {
            var config = Configuration(); config.foreignKeysEnabled = true
            config.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
            let db = try DatabaseQueue(path: directory.appendingPathComponent("business.sqlite").path, configuration: config)
            database = db
            let store = try SQLiteLibraryAuthority(database: db, afterCommit: { try fault?.hit($0) }); authority = store
            let port: any AgentLibraryMaintenanceStore = failBeforeComplete ? BeforeCompletionFailure(base: store) : store
            let gate = try await AgentLibraryAccess.open(store: port); access = gate
            let registry = RuntimeRegistry<any AgentLibraryMaintenanceHandler>()
            let libraryScope = RuntimeScope(kind: .library(store.libraryID)); scope = libraryScope
            let handler = CoordinatorHandler(database: db)
            try await db.write { db in
                try db.execute(sql: "CREATE TABLE synthetic_private_values (value TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO synthetic_private_values VALUES ('synthetic private content')")
                try db.execute(sql: "CREATE TABLE synthetic_deletions (operation_id TEXT PRIMARY KEY)")
            }
            try await registry.register(id: "fixture", value: handler, scope: libraryScope)
            return .init(database: db, authority: store, access: gate, registry: registry, handler: handler,
                         scope: libraryScope, initial: try await store.authorization(), directory: directory)
        } catch {
            await access?.close(); await scope?.dispose(); await authority?.close(); try? database?.close()
            try? FileManager.default.removeItem(at: directory); throw error
        }
    }
    func request(revision: Int = 1) -> AgentLibraryMaintenanceRequest {
        .init(id: UUID(), namespace: "test.cleanup", revision: revision, scope: .library,
              requestedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
    func coordinator(owners: [AgentLibraryWorkOwner] = []) throws -> AgentLibraryMaintenanceCoordinator {
        try .init(access: access, handlers: registry, workOwners: owners, now: { finishedAt })
    }
    func deletedCount() async throws -> Int {
        try await database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM synthetic_deletions")! }
    }
    func close() async {
        await access.close(); await scope.dispose(); await authority.close(); try? database.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
