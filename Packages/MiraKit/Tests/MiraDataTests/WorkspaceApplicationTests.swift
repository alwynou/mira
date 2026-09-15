import Foundation
import GRDB
import MiraCore
import Testing

@testable import MiraData

@Suite("Workspace application", .timeLimit(.minutes(1)))
struct WorkspaceApplicationTests {
    @Test func listsReadsAndSavesWorkspacesWithCompareAndSwap() async throws {
        let fixture = try await WorkspaceApplicationFixture.make()
        try await withFixture(fixture) { _ in
            let id = WorkspaceID()
            let original = Workspace(id: id, name: "Project", background: "Initial")
            try await fixture.application.save(original, expectedRevision: nil)

            #expect(try await fixture.application.workspace(id) == original)
            #expect(try await fixture.application.workspaces() == [original])

            var revised = original
            revised.background = "Updated"
            revised.revision = 2
            try await fixture.application.save(revised, expectedRevision: original.revision)
            #expect(try await fixture.application.workspace(id) == revised)

            await #expect(throws: MiraError.self) {
                try await fixture.application.save(revised, expectedRevision: original.revision)
            }
        }
    }

    @Test func maintenanceRejectsNewWorkAndClosedApplicationRejectsWork() async throws {
        let fixture = try await WorkspaceApplicationFixture.make()
        try await withFixture(fixture) { _ in
            let expected = try await fixture.authority.state().authorization
            let request = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: "workspace.test", revision: 1, scope: .library,
                requestedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
            let operation = try await fixture.access.begin(request, expected: expected)

            await #expect(throws: MiraError.self) {
                _ = try await fixture.application.workspaces()
            }

            _ = try await fixture.access.complete(operation, at: Date(timeIntervalSince1970: 1_800_000_001))
            #expect(try await fixture.application.workspaces().isEmpty)

            await fixture.application.close()
            await #expect(throws: MiraError.self) {
                _ = try await fixture.application.workspaces()
            }
        }
    }

    @Test func closeWaitsForTheActualNonCooperativeRead() async throws {
        let gate = BlockingReadGate()
        let fixture = try await WorkspaceApplicationFixture.make(blockingGate: gate)
        let pending = Task { try await fixture.application.workspaces() }
        await gate.waitUntilEntered()

        let closed = CompletionFlag()
        let closing = Task {
            await fixture.application.close()
            closed.mark()
        }
        do {
            try await waitUntil {
                do {
                    _ = try await fixture.application.workspaces()
                    return false
                } catch let error as MiraError {
                    return error.code == .busy
                } catch {
                    return false
                }
            }
            #expect(closed.value == false)
            #expect((await fixture.access.snapshot()).activeResources == 1)

            await gate.release()
            _ = await pending.result
            await closing.value
            #expect(closed.value)
            #expect((await fixture.access.snapshot()).activeResources == 0)
            #expect((await fixture.access.snapshot()).activeLeases == 0)

            await #expect(throws: MiraError.self) {
                _ = try await fixture.application.workspaces()
            }
            await fixture.close()
        } catch {
            await gate.release()
            _ = await pending.result
            await closing.value
            await fixture.close()
            throw error
        }
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                throw MiraError(.timeout, "The workspace application condition was not reached.")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private func withFixture<T: Sendable>(
    _ fixture: WorkspaceApplicationFixture,
    operation: (WorkspaceApplicationFixture) async throws -> T
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

private final class WorkspaceApplicationFixture: @unchecked Sendable {
    let directory: URL
    let database: DatabaseQueue
    let authority: SQLiteLibraryAuthority
    let access: AgentLibraryAccess
    let scope: RuntimeScope
    let workspaceStore: SQLiteWorkspaceStore
    let application: WorkspaceApplication
    let blockingGate: BlockingReadGate?

    private init(
        directory: URL, database: DatabaseQueue, authority: SQLiteLibraryAuthority,
        access: AgentLibraryAccess, scope: RuntimeScope,
        workspaceStore: SQLiteWorkspaceStore, application: WorkspaceApplication,
        blockingGate: BlockingReadGate?
    ) {
        self.directory = directory
        self.database = database
        self.authority = authority
        self.access = access
        self.scope = scope
        self.workspaceStore = workspaceStore
        self.application = application
        self.blockingGate = blockingGate
    }

    static func make(blockingGate: BlockingReadGate? = nil) async throws -> WorkspaceApplicationFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mira-workspace-application-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var database: DatabaseQueue?
        var authority: SQLiteLibraryAuthority?
        var workspaceStore: SQLiteWorkspaceStore?
        do {
            var configuration = Configuration()
            configuration.foreignKeysEnabled = true
            configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous = FULL") }
            let openedDatabase = try DatabaseQueue(
                path: directory.appendingPathComponent("business.sqlite").path,
                configuration: configuration
            )
            database = openedDatabase
            let openedAuthority = try SQLiteLibraryAuthority(database: openedDatabase)
            authority = openedAuthority
            let openedWorkspaceStore = try SQLiteWorkspaceStore(
                database: openedDatabase, libraryID: openedAuthority.libraryID
            )
            workspaceStore = openedWorkspaceStore
            let access = try await AgentLibraryAccess.open(store: openedAuthority)
            let scope = RuntimeScope(kind: .application)
            let store: any WorkspaceStore =
                if let blockingGate {
                    ForwardingWorkspaceStore(base: openedWorkspaceStore, gate: blockingGate)
                } else {
                    openedWorkspaceStore
                }
            let application = WorkspaceApplication(store: store, access: access, scope: scope)
            return .init(
                directory: directory, database: openedDatabase, authority: openedAuthority,
                access: access, scope: scope, workspaceStore: openedWorkspaceStore,
                application: application, blockingGate: blockingGate)
        } catch {
            await workspaceStore?.close()
            await authority?.close()
            try? database?.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func close() async {
        await blockingGate?.release()
        await application.close()
        await access.close()
        await scope.dispose()
        await workspaceStore.close()
        await authority.close()
        try? database.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class ForwardingWorkspaceStore: WorkspaceStore, @unchecked Sendable {
    private let base: SQLiteWorkspaceStore
    private let gate: BlockingReadGate

    init(base: SQLiteWorkspaceStore, gate: BlockingReadGate) {
        self.base = base
        self.gate = gate
    }

    func workspaces() async throws -> [Workspace] {
        await gate.wait()
        return try await base.workspaces()
    }

    func workspace(_ id: WorkspaceID) async throws -> Workspace {
        await gate.wait()
        return try await base.workspace(id)
    }

    func saveWorkspace(_ workspace: Workspace, expectedRevision: Int?, authorization: AgentLibraryAuthorization)
        async throws
    {
        try await base.saveWorkspace(workspace, expectedRevision: expectedRevision, authorization: authorization)
    }
}

private actor BlockingReadGate {
    private var entered = false
    private var released = false
    private var blocksNextRead = true
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        guard blocksNextRead else { return }
        blocksNextRead = false
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var value: Bool { lock.withLock { completed } }
    func mark() { lock.withLock { completed = true } }
}
