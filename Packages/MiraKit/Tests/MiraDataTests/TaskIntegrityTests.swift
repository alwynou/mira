import Foundation
import Testing
import GRDB
import MiraCore
@testable import MiraData

@Suite("Task storage integrity")
struct TaskIntegrityTests {
    @Test func fractionalSecondTimesRoundTripWithoutFalseCorruption() async throws {
        let fixture = try await TaskIntegrityFixture.make()
        try await withTaskIntegrityFixture(fixture) { fixture in
            let authorization = try await fixture.authorization()
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            for index in 1...32 {
                let time = Date(timeIntervalSince1970: 1_800_003_600 + Double(index) / 97)
                let task = try await fixture.store.saveTask(
                    .init(), workspaceID: nil, draft: .init(title: "Fractional task", reminderAt: time),
                    status: .open, expectedRevision: nil, operationID: UUID(), authorization: authorization, at: now)
                let loaded = try await fixture.store.taskDetail(task.id, workspaceID: nil)
                #expect(abs(try #require(loaded.draft.reminderAt).timeIntervalSince(time)) < 0.000_002)
            }
        }
    }

    @Test func corruptedManualReceiptCannotBeReturnedAsASuccessfulReplay() async throws {
        let fixture = try await TaskIntegrityFixture.make()
        try await withTaskIntegrityFixture(fixture) { f in
            let authorization = try await f.authorization(), id = MiraTaskID(), operationID = UUID()
            let draft = TaskDraft(title: "Original receipt")
            _ = try await f.store.saveTask(id, workspaceID: nil, draft: draft, status: .open,
                expectedRevision: nil, operationID: operationID, authorization: authorization, at: Date())
            try await f.database.write {
                try $0.execute(sql: "UPDATE task_operations SET receipt_json = json_set(receipt_json, '$.task.draft.title', 'Altered')")
            }
            await #expect(throws: MiraError.self) {
                try await f.store.saveTask(id, workspaceID: nil, draft: draft, status: .open,
                    expectedRevision: nil, operationID: operationID, authorization: authorization, at: Date())
            }
            #expect(try await f.store.taskDetail(id, workspaceID: nil).draft == draft)
            #expect(try await f.store.taskRevisions(id, workspaceID: nil).count == 1)
        }
    }

    @Test(arguments: ["receipt", "revision", "indexedStatus"])
    func inconsistentTaskSnapshotsAreRejected(field: String) async throws {
        let fixture = try await TaskIntegrityFixture.make()
        try await withTaskIntegrityFixture(fixture) { fixture in
            let authorization = try await fixture.authorization()
            _ = try await fixture.store.saveTask(.init(), workspaceID: nil, draft: .init(title: "Original task"),
                                                  status: .open, expectedRevision: nil, operationID: UUID(),
                                                  authorization: authorization, at: Date())
            try await fixture.database.read { try SQLiteTaskStore.validateTaskContents(in: $0) }
            try await fixture.database.write { db in
                switch field {
                case "receipt":
                    try db.execute(sql: "UPDATE task_operations SET receipt_json = json_set(receipt_json, '$.task.draft.title', 'Altered')")
                case "revision":
                    try db.execute(sql: "UPDATE task_revisions SET revision_json = json_set(revision_json, '$.task.draft.title', 'Altered')")
                default:
                    try db.execute(sql: "UPDATE mira_tasks SET status = 'cancelled'")
                }
            }
            await #expect(throws: MiraError.self) {
                try await fixture.database.read { try SQLiteTaskStore.validateTaskContents(in: $0) }
            }
        }
    }
}

private final class TaskIntegrityFixture: Sendable {
    let directory: URL
    let database: DatabaseQueue
    let authority: SQLiteLibraryAuthority
    let workspaceStore: SQLiteWorkspaceStore
    let store: SQLiteTaskStore

    static func make() async throws -> TaskIntegrityFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-task-integrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var database: DatabaseQueue?
        var authority: SQLiteLibraryAuthority?
        var workspaceStore: SQLiteWorkspaceStore?
        var taskStore: SQLiteTaskStore?
        do {
            var configuration = Configuration()
            configuration.foreignKeysEnabled = true
            configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous = FULL") }
            let opened = try DatabaseQueue(path: directory.appendingPathComponent("business.sqlite").path, configuration: configuration)
            database = opened
            let openedAuthority = try SQLiteLibraryAuthority(database: opened)
            authority = openedAuthority
            let openedWorkspaceStore = try SQLiteWorkspaceStore(database: opened, libraryID: openedAuthority.libraryID)
            workspaceStore = openedWorkspaceStore
            let openedTaskStore = try SQLiteTaskStore(database: opened, libraryID: openedAuthority.libraryID)
            taskStore = openedTaskStore
            return .init(directory: directory, database: opened, authority: openedAuthority,
                         workspaceStore: openedWorkspaceStore, store: openedTaskStore)
        } catch {
            await taskStore?.close()
            await workspaceStore?.close()
            await authority?.close()
            try? database?.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private init(directory: URL, database: DatabaseQueue, authority: SQLiteLibraryAuthority,
                 workspaceStore: SQLiteWorkspaceStore, store: SQLiteTaskStore) {
        self.directory = directory
        self.database = database
        self.authority = authority
        self.workspaceStore = workspaceStore
        self.store = store
    }

    func authorization() async throws -> AgentLibraryAuthorization {
        try await authority.state().authorization
    }

    func close() async {
        await store.close()
        await workspaceStore.close()
        await authority.close()
        try? database.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func withTaskIntegrityFixture<T>(
    _ fixture: TaskIntegrityFixture,
    operation: (TaskIntegrityFixture) async throws -> T
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
