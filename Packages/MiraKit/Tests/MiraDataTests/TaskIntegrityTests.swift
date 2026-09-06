import Foundation
import Testing
import GRDB
import MiraCore
@testable import MiraData

@Suite("Task storage integrity")
struct TaskIntegrityTests {
    @Test func fractionalSecondTimesRoundTripWithoutFalseCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiraTaskTimePrecision-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 1...32 {
            let time = Date(timeIntervalSince1970: 1_800_003_600 + Double(index) / 97)
            let task = try store.saveTask(.init(), workspaceID: nil, draft: .init(title: "Fractional task", reminderAt: time),
                                          status: .open, expectedRevision: nil, operationID: UUID(), at: now)
            let loaded = try store.taskDetail(task.id, workspaceID: nil)
            #expect(abs(try #require(loaded.draft.reminderAt).timeIntervalSince(time)) < 0.000_002)
        }
    }

    @Test(arguments: ["receipt", "revision", "indexedStatus"])
    func inconsistentTaskSnapshotsAreRejected(field: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiraTaskIntegrity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        _ = try store.saveTask(.init(), workspaceID: nil, draft: .init(title: "Original task"),
                               status: .open, expectedRevision: nil, operationID: UUID(), at: Date())
        let database = try DatabaseQueue(path: directory.appendingPathComponent("Mira.sqlite").path)
        try database.read { try SQLiteMiraStore.validateTaskContents(in: $0) }
        try database.write { db in
            switch field {
            case "receipt":
                try db.execute(sql: "UPDATE task_operations SET receipt_json = json_set(receipt_json, '$.task.draft.title', 'Altered')")
            case "revision":
                try db.execute(sql: "UPDATE task_revisions SET revision_json = json_set(revision_json, '$.task.draft.title', 'Altered')")
            default:
                try db.execute(sql: "UPDATE mira_tasks SET status = 'cancelled'")
            }
        }
        #expect(throws: MiraError.self) {
            try database.read { try SQLiteMiraStore.validateTaskContents(in: $0) }
        }
    }
}
