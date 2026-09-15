import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("SQLite knowledge archives", .timeLimit(.minutes(1)))
struct SQLiteKnowledgeArchiveTests {
    @Test
    func archiveListsEveryHistoricalAndFailedVersionBlob() async throws {
        try await withKnowledgeArchiveFixture { fixture in
            let first = try await fixture.importBytes(Data("# old\nold body".utf8))
            let second = try await fixture.importBytes(
                Data("# current\ncurrent body".utf8), updating: first)
            let failed = try await fixture.importBytes(
                Data([0xff, 0xfe]), updating: second)
            #expect(failed.version.parseState == .failed)

            let module = try SQLiteKnowledgeStore.archiveModule(blobDirectory: "Blobs")
            let attachments = try await fixture.database.read { db in
                try module.inspect(db, .init(sessions: []))
            }
            #expect(attachments.count == 3)
            #expect(
                Set(attachments.map(\.digest))
                    == Set([first.version.contentHash, second.version.contentHash, failed.version.contentHash]))
            #expect(attachments.allSatisfy { $0.path.hasPrefix("Blobs/") })
            #expect(
                attachments.allSatisfy {
                    $0.path == "Blobs/\($0.digest.prefix(2))/\($0.digest.dropFirst(2).prefix(2))/\($0.digest)"
                })
        }
    }

    @Test
    func archiveRejectsCorruptSearchProjectionAndInvalidBlobDirectory() async throws {
        await #expect(throws: MiraError.self) {
            _ = try SQLiteKnowledgeStore.archiveModule(blobDirectory: "../Blobs")
        }
        try await withKnowledgeArchiveFixture { fixture in
            let receipt = try await fixture.importBytes(Data("# indexed\nsearch body".utf8))
            try await fixture.database.write { db in
                try db.execute(
                    sql: "UPDATE knowledge_chunks SET normalized_text = ? WHERE version_id = ?",
                    arguments: ["tampered", receipt.version.id.rawValue.uuidString.lowercased()])
            }
            let module = try SQLiteKnowledgeStore.archiveModule(blobDirectory: "Blobs")
            await #expect(throws: MiraError.self) {
                try await fixture.database.read { db in
                    _ = try module.inspect(db, .init(sessions: []))
                }
            }
        }
    }

    @Test
    func archivePreservesCompletedRevocationScopeThroughLaterDeletion() async throws {
        try await withKnowledgeArchiveFixture { fixture in
            let imported = try await fixture.importBytes(Data("# source\nRetained text".utf8))
            let module = try SQLiteKnowledgeStore.archiveModule(blobDirectory: "Blobs")
            var revision = imported.source.revision
            for action in [KnowledgePrivacyAction.revokeRemoteUse, .deleteSource] {
                let operation = try await fixture.authority.begin(
                    .init(
                        id: UUID(), namespace: action.namespace, revision: 1,
                        scope: .sources([
                            .domain(
                                namespace: KnowledgeSources.metadataNamespace, id: imported.source.id.rawValue,
                                revision: revision)
                        ]),
                        requestedAt: fixture.date), expected: fixture.authority.authorization())
                let scope = try await fixture.knowledge.prepareKnowledgePrivacy(operation: operation)
                try await fixture.knowledge.applyKnowledgePrivacy(scope, operation: operation)
                try await fixture.knowledge.verifyKnowledgePrivacy(scope, operation: operation)
                _ = try await fixture.authority.complete(operation, at: fixture.date)
                let attachments = try await fixture.database.read { db in
                    try module.inspect(db, .init(sessions: []))
                }
                #expect(attachments.count == (action == .deleteSource ? 0 : 1))
                revision += 1
            }
        }
    }

    @Test
    func archiveRejectsDeletedSourceWithRetainedCanonicalRows() async throws {
        try await withKnowledgeArchiveFixture { fixture in
            let receipt = try await fixture.importBytes(Data("# retained\nbody".utf8))
            try await fixture.database.write { db in
                try db.execute(
                    sql:
                        "UPDATE knowledge_sources SET deleted_at = ?, current_version_id = NULL, allows_remote_use = 0 WHERE id = ?",
                    arguments: [fixture.date.timeIntervalSince1970, receipt.source.id.rawValue.uuidString.lowercased()])
            }
            let module = try SQLiteKnowledgeStore.archiveModule(blobDirectory: "Blobs")
            await #expect(throws: MiraError.self) {
                try await fixture.database.read { db in
                    _ = try module.inspect(db, .init(sessions: []))
                }
            }
        }
    }
}

private struct KnowledgeArchiveFixture: Sendable {
    let directory: URL
    let database: DatabaseQueue
    let authority: SQLiteLibraryAuthority
    let workspaces: SQLiteWorkspaceStore
    let knowledge: SQLiteKnowledgeStore
    let authorization: AgentLibraryAuthorization
    let date = Date(timeIntervalSince1970: 10_000)

    func importBytes(_ bytes: Data, updating: KnowledgeImportReceipt? = nil) async throws -> KnowledgeImportReceipt {
        try await knowledge.importMarkdown(
            .init(title: "archive.md", bytes: bytes), workspaceID: nil,
            updating: updating?.source.id, expectedRevision: updating?.source.revision,
            operationID: UUID(), authorization: authorization, at: date)
    }
}

private func withKnowledgeArchiveFixture(
    _ body: (KnowledgeArchiveFixture) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mira-knowledge-archive-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
    let database = try DatabaseQueue(
        path: directory.appendingPathComponent("business.sqlite").path,
        configuration: configuration)
    let authority = try SQLiteLibraryAuthority(
        database: database, validators: SQLiteKnowledgeStore.maintenanceValidators)
    let workspaces = try SQLiteWorkspaceStore(database: database, libraryID: authority.libraryID)
    let knowledge = try SQLiteKnowledgeStore(
        database: database, libraryID: authority.libraryID, directory: directory)
    let fixture = KnowledgeArchiveFixture(
        directory: directory, database: database, authority: authority,
        workspaces: workspaces, knowledge: knowledge,
        authorization: try await authority.authorization())
    do {
        try await body(fixture)
        await knowledge.close()
        await workspaces.close()
        await authority.close()
        try database.close()
        try FileManager.default.removeItem(at: directory)
    } catch {
        await knowledge.close()
        await workspaces.close()
        await authority.close()
        try? database.close()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}
