import CryptoKit
import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("SQLite memory privacy", .timeLimit(.minutes(1)))
struct SQLiteMemoryPrivacyStoreTests {
    @Test func scopeIncludesAllStoredRevisionsAndPurgeVerificationIsStrict() async throws {
        try await withPrivacyFixture { fixture in
            let created = try await fixture.create("first")
            let revised = try await fixture.store.reviseMemory(
                created.id, workspaceID: nil,
                draft: .init(content: "second", scope: .global), expectedRevision: created.revision,
                operationID: UUID(), authorization: fixture.authorization, at: fixture.date)
            let operation = try await fixture.begin(memory: revised)
            let scope = try await fixture.store.memoryForgetScope(operation: operation)
            #expect(scope.roots.contains(.domain(namespace: "memories", id: revised.id.rawValue, revision: 1)))
            #expect(scope.roots.contains(.domain(namespace: "memories", id: revised.id.rawValue, revision: 2)))

            let unrelatedScope = MemoryForgetScope(
                memoryID: scope.memoryID, workspaceID: scope.workspaceID,
                expectedRevision: scope.expectedRevision,
                roots: [.domain(namespace: "memories", id: UUID(), revision: 1)])
            #expect(throws: MiraError.self) { try unrelatedScope.validate(for: operation) }

            try await fixture.store.purgeMemoryForget(scope, operation: operation)
            let tombstone = try await fixture.database.read { db -> (revision: Int?, forgottenAt: Double?, scope: String?, workspaceID: String?) in
                let row = try #require(try Row.fetchOne(
                    db, sql: "SELECT revision, forgotten_at, scope, workspace_id FROM memory_records WHERE id = ?",
                    arguments: [revised.id.rawValue.uuidString.lowercased()]))
                return (row["revision"], row["forgotten_at"], row["scope"], row["workspace_id"])
            }
            #expect(tombstone.revision == revised.revision + 1)
            #expect(tombstone.forgottenAt == fixture.date.timeIntervalSince1970)
            #expect(tombstone.scope == "global")
            #expect(tombstone.workspaceID == nil)
            try await fixture.store.verifyMemoryForgotten(scope, operation: operation)
            let retryScope = try await fixture.store.memoryForgetScope(operation: operation)
            #expect(retryScope == scope)
        }
    }

    @Test func validatorRejectsStaleRevisionAndWrongOperationScope() async throws {
        try await withPrivacyFixture { fixture in
            let memory = try await fixture.create("protected")
            let valid = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: "memory.forget", revision: 1,
                scope: .sources([.domain(namespace: "memories", id: memory.id.rawValue, revision: memory.revision)]),
                requestedAt: fixture.date)

            let stale = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: valid.namespace, revision: valid.revision,
                scope: .sources([.domain(namespace: "memories", id: memory.id.rawValue, revision: memory.revision + 1)]
                ),
                requestedAt: fixture.date)
            let collision = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: valid.namespace, revision: valid.revision,
                scope: .sources([.domain(namespace: "tasks", id: memory.id.rawValue, revision: memory.revision)]),
                requestedAt: fixture.date)
            await #expect(throws: MiraError.self) {
                _ = try await fixture.authority.begin(collision, expected: fixture.authorization)
            }
            await #expect(throws: MiraError.self) {
                _ = try await fixture.authority.begin(stale, expected: fixture.authorization)
            }
            #expect(try await fixture.authority.state().pending == nil)
            #expect(try await fixture.authority.authorization() == fixture.authorization)
            _ = try await fixture.authority.begin(valid, expected: fixture.authorization)
        }
    }

    @Test func maintenanceAdmissionAllowsOnlyOnePendingOperation() async throws {
        try await withPrivacyFixture { fixture in
            let first = try await fixture.create("first pending")
            let second = try await fixture.create("second pending")
            _ = try await fixture.begin(memory: first)
            let request = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: "memory.forget", revision: 1,
                scope: .sources([.domain(namespace: "memories", id: second.id.rawValue, revision: second.revision)]),
                requestedAt: fixture.date)
            await #expect(throws: MiraError.self) {
                try await fixture.authority.begin(request, expected: fixture.authorization)
            }
        }
    }

    @Test func scopeRejectsMissingRevisionInsteadOfCreatingAnIncompleteRootSet() async throws {
        try await withPrivacyFixture { fixture in
            let created = try await fixture.create("revision one")
            let revised = try await fixture.store.reviseMemory(
                created.id, workspaceID: nil,
                draft: .init(content: "revision two", scope: .global), expectedRevision: created.revision,
                operationID: UUID(), authorization: fixture.authorization, at: fixture.date)
            try await fixture.database.write { db in
                try db.execute(
                    sql: "DELETE FROM memory_revisions WHERE memory_id = ? AND revision = 1",
                    arguments: [revised.id.rawValue.uuidString.lowercased()])
            }
            let operation = try await fixture.begin(memory: revised)
            await #expect(throws: MiraError.self) {
                try await fixture.store.memoryForgetScope(operation: operation)
            }
        }
    }

    @Test func tamperingWithPurgedBodyFailsVerification() async throws {
        try await withPrivacyFixture { fixture in
            let memory = try await fixture.create("tamper")
            let operation = try await fixture.begin(memory: memory)
            let scope = try await fixture.store.memoryForgetScope(operation: operation)
            try await fixture.store.purgeMemoryForget(scope, operation: operation)
            try await fixture.database.write { db in
                try db.execute(
                    sql: "UPDATE memory_records SET draft_json = ? WHERE id = ?",
                    arguments: [Data("tampered".utf8), memory.id.rawValue.uuidString.lowercased()])
            }
            await #expect(throws: MiraError.self) {
                try await fixture.store.verifyMemoryForgotten(scope, operation: operation)
            }
        }
    }

    @Test func sharedSourcePurgeRetainsAnIndependentlyConfirmedMemory() async throws {
        try await withPrivacyFixture { fixture in
            let evidence = fixture.userEvidence()
            let forgotten = try await fixture.create("first assertion", evidence: evidence)
            let retained = try await fixture.create("second assertion", evidence: evidence)
            let operation = try await fixture.begin(memory: forgotten)
            let scope = try await fixture.store.memoryForgetScope(operation: operation)

            try await fixture.store.purgeMemoryForget(scope, operation: operation)
            try await fixture.store.verifyMemoryForgotten(scope, operation: operation)

            let retainedMemory = try await fixture.database.read { db in
                let row = try #require(
                    try Row.fetchOne(
                        db, sql: "SELECT * FROM memory_records WHERE id = ?",
                        arguments: [retained.id.rawValue.uuidString.lowercased()]))
                return try SQLiteMemoryStore.record(row)
            }
            #expect(retainedMemory.forgottenAt == nil)
            #expect(retainedMemory.draft?.content == "second assertion")
            let retainedAssertionCount = try await fixture.database.read { db in
                try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM memory_assertions WHERE memory_id = ?",
                    arguments: [retained.id.rawValue.uuidString.lowercased()]) ?? 0
            }
            #expect(retainedAssertionCount == 1)
        }
    }

    @Test func purgeMarksQueuedSourceJobSuppressedAndLeavesNoPrivateAttemptBodies() async throws {
        try await withPrivacyFixture { fixture in
            let evidence = fixture.userEvidence()
            let memory = try await fixture.create("job source", evidence: evidence)
            let origin = MemoryExtractionOrigin(
                source: evidence.reference, completedExecutionID: evidence.reference.originalExecutionID,
                completionEventID: evidence.reference.admissionEventID,
                completionHead: .init(
                    cursor: .init(
                        sessionID: evidence.reference.sessionID,
                        sequence: evidence.reference.admissionSequence + 1),
                    batchID: UUID()))
            let job = MemoryExtractionJob(
                id: .init(), origin: origin, workspaceID: evidence.workspaceID,
                policyRevision: 1, state: .queued, attemptCount: 0,
                createdAt: fixture.date, updatedAt: fixture.date)
            try await fixture.database.write { db in
                try SQLiteMemoryExtractionStore.write(job, insert: true, in: db)
            }

            let operation = try await fixture.begin(memory: memory)
            let scope = try await fixture.store.memoryForgetScope(operation: operation)
            try await fixture.store.purgeMemoryForget(scope, operation: operation)
            try await fixture.store.verifyMemoryForgotten(scope, operation: operation)

            let persisted = try await fixture.database.read { db -> (state: String?, json: Data?) in
                let row = try #require(try Row.fetchOne(
                    db, sql: "SELECT state, json FROM memory_extraction_jobs WHERE id = ?",
                    arguments: [job.id.rawValue.uuidString.lowercased()]))
                return (row["state"], row["json"])
            }
            #expect(persisted.state == MemoryExtractionJobState.suppressed.rawValue)
            #expect(persisted.json != nil)
        }
    }
}

private struct MemoryPrivacyFixture: Sendable {
    let directory: URL
    let database: DatabaseQueue
    let authority: SQLiteLibraryAuthority
    let store: SQLiteMemoryStore
    let authorization: AgentLibraryAuthorization
    let date = Date(timeIntervalSince1970: 20_000)

    func create(_ text: String) async throws -> Memory {
        try await store.createMemory(
            draft: .init(content: text, scope: .global),
            source: .manualEntry(id: UUID(), statement: text), operationID: UUID(),
            replacing: nil, expectedRevision: nil, authorization: authorization, at: date
        ).memory
    }

    func create(_ text: String, evidence: SessionUserEvidence) async throws -> Memory {
        try await store.createMemory(
            draft: .init(content: text, scope: .global),
            source: .userMessage(evidence: evidence, excerpt: evidence.text), operationID: UUID(),
            replacing: nil, expectedRevision: nil, authorization: authorization, at: date
        ).memory
    }

    func userEvidence() -> SessionUserEvidence {
        let sessionID = ConversationID()
        let executionID = ExecutionID()
        let batchID = UUID()
        let text = "A shared journal source"
        let body = SessionContent(id: UUID(), kind: .userText, bytes: Data(text.utf8))
        let reference = SessionEvidenceReference(
            sessionID: sessionID, originalExecutionID: executionID, userMessageID: MessageID(),
            admissionEventID: UUID(), admissionSequence: 1)
        return .init(
            reference: reference, workspaceID: nil, admittedAt: date,
            timeZoneIdentifier: "UTC", text: text,
            observedHead: .init(cursor: .init(sessionID: sessionID, sequence: 1), batchID: batchID),
            sessionAuthorizationEpoch: 0)
    }

    func begin(memory: Memory) async throws -> AgentLibraryMaintenanceOperation {
        let request = AgentLibraryMaintenanceRequest(
            id: UUID(), namespace: "memory.forget", revision: 1,
            scope: .sources([.domain(namespace: "memories", id: memory.id.rawValue, revision: memory.revision)]),
            requestedAt: date)
        return try await authority.begin(request, expected: authorization)
    }
}

private func withPrivacyFixture(_ body: (MemoryPrivacyFixture) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "mira-memory-privacy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("business.sqlite")
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous = FULL") }
    let database = try DatabaseQueue(path: path.path, configuration: configuration)
    let authority = try SQLiteLibraryAuthority(database: database, validators: [SQLiteMemoryStore.maintenanceValidator])
    let workspaces = try SQLiteWorkspaceStore(database: database, libraryID: authority.libraryID)
    let store = try SQLiteMemoryStore(database: database, libraryID: authority.libraryID)
    do {
        let fixture = MemoryPrivacyFixture(
            directory: directory, database: database, authority: authority,
            store: store, authorization: try await authority.authorization())
        try await body(fixture)
        await store.close()
        await workspaces.close()
        await authority.close()
        try database.close()
        try FileManager.default.removeItem(at: directory)
    } catch {
        await store.close()
        await workspaces.close()
        await authority.close()
        try? database.close()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}
