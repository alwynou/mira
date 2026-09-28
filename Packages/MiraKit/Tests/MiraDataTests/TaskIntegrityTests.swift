import Foundation
import Testing
import GRDB
import MiraCore
@testable import MiraData

@Suite("Task storage integrity")
struct TaskIntegrityTests {
    @Test func pausedReminderSurvivesEditsUntilExplicitResume() async throws {
        let fixture = try await TaskIntegrityFixture.make()
        try await withTaskIntegrityFixture(fixture) { f in
            let authorization = try await f.authorization()
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let reminder = now.addingTimeInterval(3600)
            var task = try await f.store.saveTask(.init(), workspaceID: nil,
                draft: .init(title: "Reminder", reminderAt: reminder), status: .open,
                expectedRevision: nil, operationID: UUID(), authorization: authorization, at: now)
            #expect(try await f.store.setReminderDelivery(task.id, expectedRevision: task.revision, state: .paused,
                error: nil, authorization: authorization, at: now))
            task = try await f.store.saveTask(task.id, workspaceID: nil,
                draft: .init(title: "Edited", reminderAt: reminder), status: .open,
                expectedRevision: task.revision, operationID: UUID(), authorization: authorization, at: now.addingTimeInterval(1))
            #expect(task.deliveryState == .paused)
            try await f.store.resumeReminder(task.id, workspaceID: nil, expectedRevision: task.revision,
                authorization: authorization, at: now)
            task = try await f.store.taskDetail(task.id, workspaceID: nil)
            #expect(task.deliveryState == .pending)
            task = try await f.store.saveTask(task.id, workspaceID: nil,
                draft: .init(title: "Rescheduled", reminderAt: reminder.addingTimeInterval(3600)), status: .open,
                expectedRevision: task.revision, operationID: UUID(), authorization: authorization, at: now.addingTimeInterval(2))
            #expect(task.deliveryState == .pending)
        }
    }

    @Test func revisionPagesCoverAllHistoryAndEnforceWorkspaceScope() async throws {
        let fixture = try await TaskIntegrityFixture.make()
        try await withTaskIntegrityFixture(fixture) { f in
            let authorization = try await f.authorization()
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var task = try await f.store.saveTask(.init(), workspaceID: nil, draft: .init(title: "Revision 0"),
                status: .open, expectedRevision: nil, operationID: UUID(), authorization: authorization, at: now)
            for revision in 1...104 {
                task = try await f.store.saveTask(task.id, workspaceID: nil,
                    draft: .init(title: "Revision \(revision)"), status: .open, expectedRevision: task.revision,
                    operationID: UUID(), authorization: authorization, at: now.addingTimeInterval(TimeInterval(revision)))
            }
            var collected: [Int] = []
            for offset in stride(from: 0, through: 100, by: 25) {
                let page = try await f.store.taskRevisionPage(task.id, workspaceID: nil, offset: offset, limit: 25)
                collected += page.items.map(\.task.revision)
                if offset < 100 { #expect(page.hasMore) }
            }
            #expect(collected == Array(stride(from: 105, through: 1, by: -1)))
            await #expect(throws: MiraError.self) {
                _ = try await f.store.taskRevisionPage(task.id, workspaceID: WorkspaceID(), offset: 0, limit: 25)
            }
            await #expect(throws: MiraError.self) {
                _ = try await f.store.saveTask(task.id, workspaceID: nil, draft: .init(title: "Stale"), status: .open,
                    expectedRevision: 1, operationID: UUID(), authorization: authorization, at: now.addingTimeInterval(1000))
            }
        }
    }

    @Test func managementPagesDoNotSilentlyTruncateAndUseLiteralScopedSearch() async throws {
        let fixture = try await TaskIntegrityFixture.make()
        try await withTaskIntegrityFixture(fixture) { f in
            let authorization = try await f.authorization()
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            for index in 0..<205 {
                _ = try await f.store.saveTask(.init(), workspaceID: nil,
                    draft: .init(title: index == 204 ? "中文计划 [x]" : "Task \(index)"), // i18n-fixture: Chinese literal task search with punctuation.
                    status: .open, expectedRevision: nil, operationID: UUID(), authorization: authorization, at: now)
            }
            let first = try await f.store.taskManagementPage(.init(status: .active, offset: 0, limit: 50))
            let fifth = try await f.store.taskManagementPage(.init(status: .active, offset: 200, limit: 50))
            #expect(first.items.count == 50)
            #expect(first.hasMore)
            #expect(fifth.items.count == 5)
            #expect(!fifth.hasMore)

            let literal = try await f.store.taskManagementPage(.init(search: "[x]", status: .all, limit: 10))
            #expect(literal.items.count == 1)
            #expect(literal.items[0].draft.title == "中文计划 [x]") // i18n-fixture: Chinese literal search result remains verbatim.

            let normalized = try await f.store.saveTask(.init(), workspaceID: nil,
                draft: .init(title: "Caf\u{00E9} \u{FF30}lan", notes: "Quarterly [100%]"),
                status: .open, expectedRevision: nil, operationID: UUID(), authorization: authorization, at: now)
            let folded = try await f.store.taskManagementPage(.init(search: "CAFE plan", status: .all))
            #expect(folded.items.map(\.id) == [normalized.id])
            let notes = try await f.store.taskManagementPage(.init(search: "[100%]", status: .all))
            #expect(notes.items.map(\.id) == [normalized.id])
            await #expect(throws: MiraError.self) {
                _ = try await f.store.taskManagementPage(.init(offset: -1))
            }
            await #expect(throws: MiraError.self) {
                _ = try await f.store.taskManagementPage(.init(limit: 201))
            }
        }
    }

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
