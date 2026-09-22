import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Memory retraction store")
struct MemoryRetractionStoreTests {
    @Test func retractArchivesInPlaceAndRetainsSeparateWithdrawalProvenance() async throws {
        try await withRetractionFixture { fixture in
            let originalSourceID = UUID()
            let original = try await fixture.store.createMemory(
                draft: .init(content: "I prefer early flights", scope: .global),
                source: .manualEntry(id: originalSourceID, statement: "I prefer early flights"),
                operationID: UUID(), replacing: nil, expectedRevision: nil,
                authorization: fixture.authorization, at: fixture.date).memory
            let request = AgentContextRequest(
                sessionID: ConversationID(), executionID: ExecutionID(), workspaceID: nil,
                userText: "I retract that preference", authorizationEpoch: 0, destination: .local)
            let sourceID = UUID()
            await #expect(throws: MiraError.self) {
                _ = try await fixture.database.write { db in
                    try SQLiteMemoryStore.retractMemoryInTransaction(
                        target: .init(memoryID: original.id, revision: original.revision),
                        source: .manualEntry(id: originalSourceID, statement: "I prefer early flights"),
                        operationID: UUID(), request: request, at: fixture.date, in: db)
                }
            }
            let operationID = UUID()
            let retracted = try await fixture.database.write { db in
                try SQLiteMemoryStore.retractMemoryInTransaction(
                    target: .init(memoryID: original.id, revision: original.revision),
                    source: .manualEntry(id: sourceID, statement: "I retract that preference"),
                    operationID: operationID, request: request, at: fixture.date, in: db)
            }
            let replay = try await fixture.database.write { db in
                try SQLiteMemoryStore.retractMemoryInTransaction(
                    target: .init(memoryID: original.id, revision: original.revision),
                    source: .manualEntry(id: sourceID, statement: "I retract that preference"),
                    operationID: operationID, request: request, at: fixture.date, in: db)
            }
            #expect(replay == retracted)
            let suppressed = try await fixture.store.suppressedMemorySources()
            #expect(suppressed.contains(.manualEntry(originalSourceID)))
            #expect(suppressed.contains(.manualEntry(sourceID)))
            await #expect(throws: MiraError.self) {
                _ = try await fixture.store.createMemory(
                    draft: .init(content: "A later assertion from the old source", scope: .global),
                    source: .manualEntry(id: originalSourceID, statement: "I prefer early flights"),
                    operationID: UUID(), replacing: nil, expectedRevision: nil,
                    authorization: fixture.authorization, at: fixture.date)
            }
            _ = try await fixture.store.createMemory(
                draft: .init(content: "A fresh later assertion", scope: .global),
                source: .manualEntry(id: UUID(), statement: "A fresh later assertion"),
                operationID: UUID(), replacing: nil, expectedRevision: nil,
                authorization: fixture.authorization, at: fixture.date)
            await #expect(throws: MiraError.self) {
                _ = try await fixture.database.write { db in
                    try SQLiteMemoryStore.retractMemoryInTransaction(
                        target: .init(memoryID: original.id, revision: original.revision),
                        source: .manualEntry(id: UUID(), statement: "A later withdrawal"),
                        operationID: UUID(), request: request, at: fixture.date, in: db)
                }
            }
            #expect(retracted.disposition == .retracted)
            #expect(retracted.memory.id == original.id)
            #expect(retracted.memory.state == .archived)
            #expect(retracted.memory.revision == original.revision + 1)
            #expect(retracted.memory.retraction?.priorRevision == original.revision)
            let detail = try await fixture.store.memoryDetail(original.id, workspaceID: nil)
            #expect(detail.memory.isCurrent == false)
            #expect(detail.memory.draft?.content == original.draft?.content)
            #expect(detail.evidence.contains { $0.retractionRevision == retracted.memory.revision && $0.excerpt == "I retract that preference" && $0.sourceHash != nil })
            await #expect(throws: MiraError.self) {
                _ = try await fixture.store.recallMemory(original.id, request: request, at: fixture.date)
            }
        }
    }

    @Test func retractionRollsBackWhenReceiptPersistenceFails() async throws {
        try await withRetractionFixture { fixture in
            let sourceID = UUID()
            let original = try await fixture.store.createMemory(
                draft: .init(content: "Rollback target", scope: .global),
                source: .manualEntry(id: sourceID, statement: "Rollback target"),
                operationID: UUID(), replacing: nil, expectedRevision: nil,
                authorization: fixture.authorization, at: fixture.date).memory
            try await fixture.database.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER fail_memory_receipt BEFORE INSERT ON memory_operations
                    WHEN NEW.request_hash IS NOT NULL BEGIN SELECT RAISE(ABORT, 'synthetic receipt failure'); END
                    """)
            }
            let request = AgentContextRequest(sessionID: ConversationID(), executionID: ExecutionID(), workspaceID: nil,
                                              userText: "I retract this", authorizationEpoch: 0, destination: .local)
            await #expect(throws: DatabaseError.self) {
                _ = try await fixture.database.write { db in
                    try SQLiteMemoryStore.retractMemoryInTransaction(
                        target: .init(memoryID: original.id, revision: original.revision),
                        source: .manualEntry(id: UUID(), statement: "I retract this"),
                        operationID: UUID(), request: request, at: fixture.date, in: db)
                }
            }
            try await fixture.database.write { db in try db.execute(sql: "DROP TRIGGER fail_memory_receipt") }
            let unchanged = try await fixture.store.memoryDetail(original.id, workspaceID: nil)
            #expect(unchanged.memory.revision == original.revision)
            #expect(unchanged.memory.retraction == nil)
        }
    }

    @Test func forgottenRetractionPurgesBothEvidenceRolesAndReceiptBodies() async throws {
        try await withRetractionFixture { fixture in
            let original = try await fixture.store.createMemory(
                draft: .init(content: "Forget this", scope: .global),
                source: .manualEntry(id: UUID(), statement: "Forget this"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: fixture.authorization, at: fixture.date).memory
            let request = AgentContextRequest(sessionID: ConversationID(), executionID: ExecutionID(), workspaceID: nil,
                                              userText: "I retract this", authorizationEpoch: 0, destination: .local)
            let retracted = try await fixture.database.write { db in
                try SQLiteMemoryStore.retractMemoryInTransaction(
                    target: .init(memoryID: original.id, revision: original.revision),
                    source: .manualEntry(id: UUID(), statement: "I retract this"), operationID: UUID(),
                    request: request, at: fixture.date, in: db)
            }
            let forgetRequest = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: "memory.forget", revision: 1,
                scope: .sources([.domain(namespace: "memories", id: original.id.rawValue, revision: retracted.memory.revision)]),
                requestedAt: fixture.date)
            let maintenance = try await fixture.authority.begin(forgetRequest, expected: fixture.authorization)
            _ = try await fixture.store.purgeMemory(original.id, workspaceID: nil,
                expectedRevision: retracted.memory.revision, maintenance: maintenance, at: fixture.date)
            try await fixture.authority.complete(maintenance, at: fixture.date)
            let detail = try await fixture.store.memoryDetail(original.id, workspaceID: nil)
            #expect(detail.memory.retraction != nil)
            #expect(detail.evidence.allSatisfy { $0.excerpt == nil && $0.sourceHash == nil && $0.bodyPurgedAt != nil })
            let receiptRows = try await fixture.database.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_operations WHERE memory_id = ? AND (request_hash IS NOT NULL OR receipt_json IS NOT NULL)", arguments: [original.id.rawValue.uuidString.lowercased()]) ?? 0
            }
            #expect(receiptRows == 0)
        }
    }

    @Test func retractedMemoryReopensWithHistoryCitationAuthorization() async throws {
        try await withRetractionFixture { fixture in
            let original = try await fixture.store.createMemory(
                draft: .init(content: "Reopen this history", scope: .global),
                source: .manualEntry(id: UUID(), statement: "Reopen this history"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: fixture.authorization, at: fixture.date).memory
            let request = AgentContextRequest(sessionID: ConversationID(), executionID: ExecutionID(), workspaceID: nil,
                                              userText: "Withdraw this", authorizationEpoch: 0, destination: .local)
            let retracted = try await fixture.database.write { db in
                try SQLiteMemoryStore.retractMemoryInTransaction(
                    target: .init(memoryID: original.id, revision: original.revision),
                    source: .manualEntry(id: UUID(), statement: "Withdraw this"), operationID: UUID(),
                    request: request, at: fixture.date, in: db)
            }
            await fixture.store.close(); await fixture.workspaces.close(); await fixture.authority.close(); try fixture.database.close()
            let reopenedDatabase = try DatabaseQueue(path: fixture.databasePath.path)
            let reopenedAuthority = try SQLiteLibraryAuthority(database: reopenedDatabase)
            let reopenedStore = try SQLiteMemoryStore(database: reopenedDatabase, libraryID: reopenedAuthority.libraryID)
            let detail = try await reopenedStore.memoryDetail(original.id, workspaceID: nil)
            #expect(detail.memory.retraction?.priorRevision == original.revision)
            let citation = try await reopenedStore.memoryCitationRevision(
                .init(memoryID: original.id, revision: original.revision), workspaceID: nil)
            #expect(citation.revision.draft?.content == original.draft?.content)
            try await reopenedStore.validateMemoryContextSources(
                [.domain(namespace: "memories", id: original.id.rawValue, revision: original.revision)],
                for: request, at: fixture.date)
            #expect(detail.evidence.contains { $0.retractionRevision == retracted.memory.revision })
            await reopenedStore.close(); await reopenedAuthority.close(); try reopenedDatabase.close()
        }
    }
}

private struct RetractionFixture: Sendable {
    let database: DatabaseQueue
    let databasePath: URL
    let directory: URL
    let authority: SQLiteLibraryAuthority
    let workspaces: SQLiteWorkspaceStore
    let store: SQLiteMemoryStore
    let authorization: AgentLibraryAuthorization
    let date = Date(timeIntervalSince1970: 10_000)
}

private func withRetractionFixture(_ body: (RetractionFixture) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-retraction-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("business.sqlite")
    var configuration = Configuration(); configuration.foreignKeysEnabled = true
    let database = try DatabaseQueue(path: path.path, configuration: configuration)
    let authority = try SQLiteLibraryAuthority(database: database, validators: [SQLiteMemoryStore.maintenanceValidator])
    let workspaces = try SQLiteWorkspaceStore(database: database, libraryID: authority.libraryID)
    let store = try SQLiteMemoryStore(database: database, libraryID: authority.libraryID)
    do {
        try await body(.init(database: database, databasePath: path, directory: directory, authority: authority, workspaces: workspaces, store: store, authorization: try await authority.authorization()))
        await store.close(); await workspaces.close(); await authority.close(); try database.close()
        try? FileManager.default.removeItem(at: directory)
    } catch {
        await store.close(); await workspaces.close(); await authority.close(); try? database.close()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}
