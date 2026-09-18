import Foundation
import Testing
import GRDB
@testable import MiraCore
@testable import MiraData

@Suite("Agent library access integration", .timeLimit(.minutes(1)))
struct AgentLibraryAccessIntegrationTests {
    @Test func pendingIntentSurvivesReopenAndDeniesAccessUntilCompleted() async throws {
        let fixture = try await AccessIntegrationFixture.make()
        do {
            let previous = try await fixture.authority.authorization()
            let operation = try await fixture.access.begin(request(), expected: previous)
            await #expect(throws: MiraError.self) { try await fixture.access.checkReady() }
            await fixture.access.close()
            await fixture.authority.close()
            let reopenedAuthority = try SQLiteLibraryAuthority(database: fixture.database)
            do {
                let reopened = try await AgentLibraryAccess.open(store: reopenedAuthority)
                do {
                    #expect((await reopened.snapshot()).pending == operation)
                    await #expect(throws: MiraError.self) { try await reopened.checkReady() }
                    _ = try await reopened.complete(operation, at: Date())
                    try await reopened.checkReady()
                    await reopened.close()
                } catch { await reopened.close(); throw error }
                await reopenedAuthority.close()
            } catch { await reopenedAuthority.close(); throw error }
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func lostBeginConfirmationKeepsAccessClosedAndRetriesOriginalEpoch() async throws {
        let fault = AccessCommitFault(.afterBeginCommit)
        let fixture = try await AccessIntegrationFixture.make(fault: fault)
        do {
            let lease = try await fixture.acquire()
            let command = request()
            await #expect(throws: MiraError.self) { try await fixture.access.begin(command, expected: lease.authorization) }
            #expect(fault.count == 1)
            #expect((await fixture.access.snapshot()).phase == .uncertain)
            #expect(lease.isRevoked)
            await #expect(throws: MiraError.self) { try await fixture.access.checkReady() }
            let persisted = try #require(try await fixture.authority.state().pending)
            #expect(persisted.request == command)
            #expect(persisted.authorization.epoch == lease.authorization.epoch + 1)
            let retried = try await fixture.access.begin(command, expected: lease.authorization)
            #expect(retried == persisted)
            #expect(fault.count == 1)
            #expect((await fixture.access.snapshot()).phase == .maintenance)
            #expect(try await fixture.authority.state().authorization == persisted.authorization)
            await lease.release()
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func lostCompletionConfirmationDoesNotGrantAccessUntilExactRetry() async throws {
        let fault = AccessCommitFault(.afterCompletionCommit)
        let fixture = try await AccessIntegrationFixture.make(fault: fault)
        do {
            let old = try await fixture.acquire()
            let command = request()
            let operation = try await fixture.access.begin(command, expected: old.authorization)
            await old.release()
            let finishedAt = Date(timeIntervalSince1970: 1_700_000_005)
            await #expect(throws: MiraError.self) { try await fixture.access.complete(operation, at: finishedAt) }
            #expect(fault.count == 1)
            #expect((await fixture.access.snapshot()).phase == .uncertain)
            await #expect(throws: MiraError.self) { try await fixture.access.checkReady() }
            let persisted = try #require(try await fixture.authority.operation(id: command.id))
            #expect(persisted.completedAt == finishedAt)
            #expect(try await fixture.authority.state().pending == nil)
            let retried = try await fixture.access.complete(operation, at: finishedAt)
            #expect(retried == persisted)
            #expect(fault.count == 1)
            let fresh = try await fixture.acquire()
            try await fresh.check()
            #expect(fresh.authorization == persisted.authorization)
            await #expect(throws: MiraError.self) { try await old.check() }
            // Repeating an old begin is an observation, not another revocation.
            #expect(try await fixture.access.begin(command, expected: old.authorization) == persisted)
            try await fresh.check()
            await fresh.release()
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func heldFileReadPinsLeaseAndDiscardsBytesAfterRevocation() async throws {
        let fixture = try await AccessIntegrationFixture.make()
        let reader = HeldFileReader(store: fixture.library)
        var reading: Task<Data, any Error>?
        var releasing: Task<Void, Never>?
        do {
            let sessionID = ConversationID(), batchID = UUID()
            let reference = try await fixture.library.stage(Data("private fixture".utf8), sessionID: sessionID,
                batchID: batchID, kind: .module)
            let batch = SessionBatch(id: batchID, sessionID: sessionID, expectedSequence: 0,
                events: [.init(sequence: 1, occurredAt: Date(), fact: .extensionRecorded(
                    namespace: "test.body", schemaVersion: 1, required: false, body: reference))])
            #expect(await fixture.library.append(batch) == .committed(batch.cursor))
            let lease = try await fixture.acquire()
            let released = AccessFlag()
            reading = Task { try await lease.read(reference, from: reader) }
            try await waitUntil { await reader.entered }
            let operation = try await fixture.access.begin(request(), expected: lease.authorization)
            releasing = Task { await lease.release(); released.mark() }
            // Observe the read pin and registered release, not merely scheduling the task.
            try await waitUntil {
                let state = await fixture.access.snapshot()
                let releasing = await fixture.access.pendingLeaseReleaseCount
                return lease.isRevoked && state.activeReads == 1 && releasing == 1
            }
            #expect(released.value == false)
            do {
                _ = try await fixture.access.complete(operation, at: Date())
                Issue.record("Maintenance completed while an actual file read was held.")
            } catch let error as MiraError { #expect(error.code == .busy) }
            await reader.release()
            do { _ = try await reading!.value; Issue.record("Revoked read exposed late bytes.") }
            catch let error as MiraError { #expect(error.code == .unauthorized) }
            await releasing!.value
            #expect(released.value)
            #expect((await fixture.access.snapshot()).activeReads == 0)
            #expect((await fixture.access.snapshot()).activeLeases == 0)
            try await fixture.access.waitForQuiescence()
            _ = try await fixture.access.complete(operation, at: Date())
            await #expect(throws: MiraError.self) { try await lease.read(reference, from: fixture.library) }
        } catch {
            await reader.release(); _ = await reading?.result; await releasing?.value
            await fixture.close(); throw error
        }
        await fixture.close()
    }

    private func request() -> AgentLibraryMaintenanceRequest {
        .init(id: UUID(), namespace: "test.purge", revision: 1, scope: .library,
              requestedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
    private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw MiraError(.timeout, "Synthetic access did not converge.") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor AccessIntegrationFixture {
    let access: AgentLibraryAccess
    let authority: SQLiteLibraryAuthority
    let database: DatabaseQueue
    let library: FileSessionLibrary
    private let directory: URL
    private let scope = RuntimeScope(kind: .application)
    private var leases: [AgentLibraryAccessLease] = []
    private init(access: AgentLibraryAccess, authority: SQLiteLibraryAuthority, database: DatabaseQueue,
                 library: FileSessionLibrary, directory: URL) {
        self.access = access; self.authority = authority; self.database = database
        self.library = library; self.directory = directory
    }
    static func make(fault: AccessCommitFault? = nil) async throws -> AccessIntegrationFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-access-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: DatabaseQueue?, authority: SQLiteLibraryAuthority?, library: FileSessionLibrary?
        do {
            var configuration = Configuration(); configuration.foreignKeysEnabled = true
            configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
            let opened = try DatabaseQueue(path: directory.appendingPathComponent("business.sqlite").path, configuration: configuration)
            db = opened
            let store = try SQLiteLibraryAuthority(database: opened, afterCommit: { try fault?.hit($0) })
            authority = store
            let bodies = try FileSessionLibrary(directory: directory.appendingPathComponent("sessions"))
            library = bodies
            let access = try await AgentLibraryAccess.open(store: store)
            return .init(access: access, authority: store, database: opened, library: bodies, directory: directory)
        } catch {
            try? await library?.close(); await authority?.close(); try? db?.close()
            try? FileManager.default.removeItem(at: directory); throw error
        }
    }
    func acquire() async throws -> AgentLibraryAccessLease {
        let lease = try await access.acquire(in: scope); leases.append(lease); return lease
    }
    func close() async {
        for lease in leases { await lease.release() }
        leases.removeAll()
        await access.close(); await scope.dispose(); await authority.close()
        try? await library.close(); try? database.close(); try? FileManager.default.removeItem(at: directory)
    }
}

private final class AccessCommitFault: @unchecked Sendable {
    private let lock = NSLock()
    private let point: SQLiteLibraryAuthorityFaultPoint
    private var hits = 0
    init(_ point: SQLiteLibraryAuthorityFaultPoint) { self.point = point }
    var count: Int { lock.withLock { hits } }
    func hit(_ actual: SQLiteLibraryAuthorityFaultPoint) throws {
        try lock.withLock {
            guard actual == point else { return }
            hits += 1
            if hits == 1 { throw MiraError(.storage, "Synthetic maintenance confirmation was lost.") }
        }
    }
}
private final class AccessFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    var value: Bool { lock.withLock { marked } }
    func mark() { lock.withLock { marked = true } }
}
private actor HeldFileReader: SessionContentReader {
    let store: FileSessionLibrary
    private(set) var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(store: FileSessionLibrary) { self.store = store }
    func read(_ reference: SessionContent) async throws -> Data {
        let bytes = try await store.read(reference)
        entered = true
        if !released { await withCheckedContinuation { waiter = $0 } }
        return bytes
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
