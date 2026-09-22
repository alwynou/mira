import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Memory retraction archives")
struct MemoryRetractionArchiveTests {
    @Test func archiveAcceptsRetractionAndRejectsOrphanOrMissingLatestTag() async throws {
        try await withTaskWorkflow(memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let authorization = try await fixture.authority.authorization()
            let original = try await store.createMemory(
                draft: .init(content: "Archive this retraction", scope: .global),
                source: .manualEntry(id: UUID(), statement: "Archive this retraction"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now).memory
            let request = AgentContextRequest(sessionID: ConversationID(), executionID: ExecutionID(), workspaceID: nil,
                                              userText: "I retract this", authorizationEpoch: 0, destination: .local)
            let retracted = try await fixture.database.write { db in
                try SQLiteMemoryStore.retractMemoryInTransaction(
                    target: .init(memoryID: original.id, revision: original.revision),
                    source: .manualEntry(id: UUID(), statement: "I retract this"), operationID: UUID(),
                    request: request, at: TaskWorkflowFixture.now, in: db)
            }
            let module = try SQLiteMemoryStore.archiveModule()
            try await fixture.library.withSnapshot { snapshot in
                try fixture.database.read { db in _ = try module.inspect(db, snapshot) }
            }
            let rowData = try await fixture.database.read { db in
                try #require(try Data.fetchOne(db, sql: "SELECT json FROM memory_evidence WHERE memory_id = ? AND json_extract(CAST(json AS TEXT), '$.retractionRevision') IS NOT NULL", arguments: [original.id.rawValue.uuidString.lowercased()]))
            }
            var orphan: MemoryEvidence = try SQLiteMemoryStore.decode(rowData)
            orphan.retractionRevision = retracted.memory.revision + 1
            let orphanData = try SQLiteMemoryStore.encode(orphan)
            let withdrawalID = orphan.id.uuidString.lowercased()
            try await fixture.database.write { db in
                try db.execute(sql: "UPDATE memory_evidence SET json = ? WHERE memory_id = ? AND json_extract(CAST(json AS TEXT), '$.retractionRevision') IS NOT NULL", arguments: [orphanData, original.id.rawValue.uuidString.lowercased()])
            }
            await #expect(throws: MiraError.self) {
                try await fixture.library.withSnapshot { snapshot in
                    try fixture.database.read { db in _ = try module.inspect(db, snapshot) }
                }
            }
            try await fixture.database.write { db in
                try db.execute(sql: "UPDATE memory_evidence SET json = ? WHERE id = ?", arguments: [rowData, withdrawalID])
            }
            try await fixture.library.withSnapshot { snapshot in
                try fixture.database.read { db in _ = try module.inspect(db, snapshot) }
            }
            var missing: MemoryEvidence = try SQLiteMemoryStore.decode(rowData)
            missing.retractionRevision = nil
            let missingData = try SQLiteMemoryStore.encode(missing)
            try await fixture.database.write { db in
                try db.execute(sql: "UPDATE memory_evidence SET json = ? WHERE id = ?", arguments: [missingData, withdrawalID])
            }
            await #expect(throws: MiraError.self) {
                try await fixture.library.withSnapshot { snapshot in
                    try fixture.database.read { db in _ = try module.inspect(db, snapshot) }
                }
            }
        }
    }
}
