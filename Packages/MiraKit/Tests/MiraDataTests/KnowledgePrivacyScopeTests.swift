import Foundation
import GRDB
import MiraCore
import Testing

@testable import MiraData

@Suite("Knowledge privacy scopes", .timeLimit(.minutes(1)))
struct KnowledgePrivacyScopeTests {
    @Test func scopeCapturesHistoricalAndFailedVersionsAndSurvivesDeletionAndReopen() async throws {
        try await withFixture { f in
            let first = try await f.store.importMarkdown(
                .init(title: "guide.md", bytes: Data("one two".utf8)), workspaceID: nil,
                updating: nil, expectedRevision: nil, operationID: UUID(), authorization: f.authorization, at: f.date)
            let second = try await f.store.importMarkdown(
                .init(title: "guide.md", bytes: Data("three four".utf8)), workspaceID: nil,
                updating: first.source.id, expectedRevision: 1, operationID: UUID(), authorization: f.authorization,
                at: f.date)
            let failed = try await f.store.importMarkdown(
                .init(title: "guide.md", bytes: Data([0xFF])), workspaceID: nil,
                updating: first.source.id, expectedRevision: 2, operationID: UUID(), authorization: f.authorization,
                at: f.date)
            let operation = try await f.authority.begin(request(failed.source, at: f.date), expected: f.authorization)
            let scope = try await f.store.prepareKnowledgePrivacy(operation: operation)
            #expect(Set(scope.versions.map(\.id)) == [first.version.id, second.version.id, failed.version.id])
            #expect(scope.currentVersionID == second.version.id)
            #expect(scope.chunks.count == 2 && scope.operationIDs.count == 3)
            #expect(try scope.roots(for: operation).count == 5)
            let omitted = KnowledgePrivacyScope(
                action: scope.action, sourceID: scope.sourceID, workspaceID: scope.workspaceID,
                expectedRevision: scope.expectedRevision, currentVersionID: scope.currentVersionID,
                versions: scope.versions, chunks: [], operationIDs: scope.operationIDs)
            await #expect(throws: MiraError.self) {
                try await f.store.applyKnowledgePrivacy(omitted, operation: operation)
            }
            try await f.store.applyKnowledgePrivacy(scope, operation: operation)
            await f.store.close()
            let reopened = try SQLiteKnowledgeStore(
                database: f.database, libraryID: f.authority.libraryID, directory: f.directory)
            do {
                #expect(try await reopened.prepareKnowledgePrivacy(operation: operation) == scope)
                try await reopened.applyKnowledgePrivacy(scope, operation: operation)
                try await reopened.verifyKnowledgePrivacy(scope, operation: operation)
                _ = try await reopened.collectKnowledgeBlobs(operation: operation)
                try await reopened.verifyKnowledgeBlobs(operation: operation)
                let completed = try await f.authority.complete(operation, at: f.date)
                await #expect(throws: MiraError.self) {
                    try await reopened.verifyKnowledgePrivacy(scope, operation: completed)
                }
                await #expect(throws: MiraError.self) {
                    _ = try await reopened.prepareKnowledgePrivacy(operation: operation)
                }
                await reopened.close()
            } catch {
                await reopened.close()
                throw error
            }
        }
    }

    @Test(arguments: [false, true])
    func scopeDigestAndLengthTamperingAreRejected(changeLength: Bool) async throws {
        try await withFixture { f in
            let imported = try await f.store.importMarkdown(
                .init(title: "one.md", bytes: Data("body".utf8)), workspaceID: nil,
                updating: nil, expectedRevision: nil, operationID: UUID(), authorization: f.authorization, at: f.date)
            let operation = try await f.authority.begin(request(imported.source, at: f.date), expected: f.authorization)
            _ = try await f.store.prepareKnowledgePrivacy(operation: operation)
            try await f.database.write { db in
                if changeLength {
                    try db.execute(sql: "UPDATE knowledge_privacy_scopes SET byte_count = byte_count + 1")
                } else {
                    try db.execute(
                        sql: "UPDATE knowledge_privacy_scopes SET digest = ?",
                        arguments: [String(repeating: "0", count: 64)])
                }
            }
            await #expect(throws: MiraError.self) {
                _ = try await f.store.prepareKnowledgePrivacy(operation: operation)
            }
            #expect(try await f.authority.state().pending == operation)
        }
    }

    @Test func wrongPendingIdentityAndStaleAdmissionDoNotMutateAuthority() async throws {
        try await withFixture { f in
            let imported = try await f.store.importMarkdown(
                .init(title: "one.md", bytes: Data("body".utf8)), workspaceID: nil,
                updating: nil, expectedRevision: nil, operationID: UUID(), authorization: f.authorization, at: f.date)
            var stale = imported.source
            stale.revision += 1
            await #expect(throws: MiraError.self) {
                _ = try await f.authority.begin(request(stale, at: f.date), expected: f.authorization)
            }
            #expect(try await f.authority.state() == .init(authorization: f.authorization, pending: nil))
            let operation = try await f.authority.begin(request(imported.source, at: f.date), expected: f.authorization)
            let forged = AgentLibraryMaintenanceOperation(
                request: request(imported.source, at: f.date),
                previousAuthorization: operation.previousAuthorization, authorization: operation.authorization,
                completedAt: nil)
            await #expect(throws: MiraError.self) { _ = try await f.store.prepareKnowledgePrivacy(operation: forged) }
            #expect(
                try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM knowledge_privacy_scopes") }
                    == 0)
        }
    }

    @Test func restoredOperationBodiesPreventDeletionVerification() async throws {
        try await withFixture { f in
            let imported = try await f.store.importMarkdown(
                .init(title: "one.md", bytes: Data("body".utf8)), workspaceID: nil,
                updating: nil, expectedRevision: nil, operationID: UUID(), authorization: f.authorization, at: f.date)
            let receipt = try #require(
                try await f.database.read {
                    try Data.fetchOne($0, sql: "SELECT receipt_json FROM knowledge_operations")
                })
            let hash = try #require(
                try await f.database.read {
                    try String.fetchOne($0, sql: "SELECT request_hash FROM knowledge_operations")
                })
            let operation = try await f.authority.begin(request(imported.source, at: f.date), expected: f.authorization)
            let scope = try await f.store.prepareKnowledgePrivacy(operation: operation)
            try await f.store.applyKnowledgePrivacy(scope, operation: operation)
            try await f.store.verifyKnowledgePrivacy(scope, operation: operation)
            try await f.database.write { db in
                try db.execute(
                    sql: "UPDATE knowledge_operations SET receipt_json = ?, request_hash = ?",
                    arguments: [receipt, hash])
            }
            await #expect(throws: MiraError.self) {
                try await f.store.verifyKnowledgePrivacy(scope, operation: operation)
            }
        }
    }

    private func request(_ source: KnowledgeSource, at date: Date) -> AgentLibraryMaintenanceRequest {
        .init(
            id: UUID(), namespace: KnowledgePrivacyAction.deleteSource.namespace, revision: 1,
            scope: .sources([KnowledgeSources.metadata(source)]), requestedAt: date)
    }

    private struct Fixture: Sendable {
        let root: URL
        let directory: URL
        let database: DatabaseQueue
        let authority: SQLiteLibraryAuthority
        let workspaces: SQLiteWorkspaceStore
        let store: SQLiteKnowledgeStore
        let authorization: AgentLibraryAuthorization
        let date = Date(timeIntervalSince1970: 20_000)
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mira-knowledge-privacy-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("knowledge", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
        let database = try DatabaseQueue(
            path: root.appendingPathComponent("business.sqlite").path, configuration: configuration)
        let authority = try SQLiteLibraryAuthority(
            database: database, validators: SQLiteKnowledgeStore.maintenanceValidators)
        let workspaces = try SQLiteWorkspaceStore(database: database, libraryID: authority.libraryID)
        let store = try SQLiteKnowledgeStore(database: database, libraryID: authority.libraryID, directory: directory)
        let fixture = Fixture(
            root: root, directory: directory, database: database, authority: authority, workspaces: workspaces,
            store: store, authorization: try await authority.authorization())
        do {
            try await body(fixture)
            await store.close()
            await workspaces.close()
            await authority.close()
            try database.close()
            try FileManager.default.removeItem(at: root)
        } catch {
            await store.close()
            await workspaces.close()
            await authority.close()
            try? database.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
