import Foundation
import GRDB
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Journal-backed knowledge domain", .timeLimit(.minutes(1)))
struct JournalKnowledgeStoreTests {
    @Test func importSnapshotKeepsExactImmutablePositionsAcrossUpdates() async throws {
        try await withKnowledgeStore { f in
            let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("# First\r\nOriginal evidence\r\n".utf8)
            let a = try await f.importBytes(bytes)
            let detail = try await f.store.knowledgeSource(a.source.id, versionID: nil, scope: f.local)
            let summary = try #require(detail.chunks.first)
            #expect(summary.startUTF8Offset == 3)
            let original = try await f.store.sourceChunk(summary.id, scope: f.local)
            #expect(original.text == "# First\r\nOriginal evidence\r\n")
            let b = try await f.store.importMarkdown(.init(title: "same.md", bytes: Data("# Second\nChanged evidence".utf8)), workspaceID: nil, updating: a.source.id, expectedRevision: 1, operationID: UUID(), authorization: f.authorization, at: f.date)
            #expect(b.source.id == a.source.id && b.source.revision == 2)
            #expect(b.version.id != a.version.id)
            let citation = try await f.store.sourceCitation(.init(versionID: a.version.id, chunkID: summary.id), scope: f.local)
            #expect(citation.chunk == original && citation.version.id == a.version.id)
            await #expect(throws: MiraError.self) { _ = try await f.store.sourceCitation(.init(versionID: b.version.id, chunkID: summary.id), scope: f.local) }
            #expect(try await f.store.searchKnowledge(query: "Original", scope: f.local, limit: 6).hits.isEmpty)
            #expect(try await f.store.searchKnowledge(query: "Changed", scope: f.local, limit: 6).hits.count == 1)
        }
    }
    @Test func operationReplayIsFrozenAcrossRestartAndDifferentArgumentsConflict() async throws {
        try await withKnowledgeStore { f in
            let op = UUID(), input = KnowledgeImport(title: "original.md", bytes: Data("one".utf8))
            let first = try await f.store.importMarkdown(input, workspaceID: nil, updating: nil, expectedRevision: nil, operationID: op, authorization: f.authorization, at: f.date)
            let duplicate = try await f.store.importMarkdown(.init(title: "other.md", bytes: input.bytes), workspaceID: nil, updating: nil, expectedRevision: nil, operationID: UUID(), authorization: f.authorization, at: f.date)
            #expect(duplicate.reused && duplicate.source.id == first.source.id)
            _ = try await f.store.allowSourceRemoteUse(first.source.id, workspaceID: nil, expectedRevision: 1, operationID: UUID(), authorization: f.authorization, at: f.date)
            await f.store.close()
            let reopened = try SQLiteKnowledgeStore(database: f.database, libraryID: f.authority.libraryID, directory: f.directory)
            do {
                let replay = try await reopened.importMarkdown(input, workspaceID: nil, updating: nil, expectedRevision: nil, operationID: op, authorization: f.authorization, at: f.date.addingTimeInterval(50))
                #expect(replay == first && !replay.source.allowsRemoteUse)
                await #expect(throws: MiraError.self) { _ = try await reopened.importMarkdown(.init(title: "other.md", bytes: input.bytes), workspaceID: nil, updating: nil, expectedRevision: nil, operationID: op, authorization: f.authorization, at: f.date) }
                await reopened.close()
            } catch { await reopened.close(); throw error }
        }
    }
    @Test func invalidUTF8RetainsFailedVersionWithoutReplacingCurrent() async throws {
        try await withKnowledgeStore { f in
            let first = try await f.importBytes(Data("usable".utf8))
            let failed = try await f.store.importMarkdown(.init(title: "bad.md", bytes: Data([0xFF, 0x00])), workspaceID: nil, updating: first.source.id, expectedRevision: 1, operationID: UUID(), authorization: f.authorization, at: f.date)
            #expect(failed.version.parseState == .failed && failed.version.parseError != nil)
            #expect(failed.source.currentVersionID == first.version.id && failed.source.revision == 2)
            let detail = try await f.store.knowledgeSource(first.source.id, versionID: failed.version.id, scope: f.local)
            #expect(detail.chunks.isEmpty)
            #expect(try f.blobs.read(failed.version.contentHash) == Data([0xFF, 0x00]))
            #expect(try await f.store.searchKnowledge(query: "usable", scope: f.local, limit: 6).hits.count == 1)
        }
    }
    @Test(arguments: [KnowledgeStorageFaultStage.afterBlobInstall, .beforeImportCommit])
    func failedPublicationHasNoCanonicalPartialReferences(stage: KnowledgeStorageFaultStage) async throws {
        try await withKnowledgeStore { f in
            let failing = try SQLiteKnowledgeStore(database: f.database, libraryID: f.authority.libraryID, directory: f.directory, faultInjector: { point in
                if point == stage { throw MiraError(.storage, "Injected knowledge publication failure.") }
            })
            do {
                await #expect(throws: MiraError.self) {
                    _ = try await failing.importMarkdown(.init(title: "atomic.md", bytes: Data("atomic bytes".utf8)), workspaceID: nil, updating: nil, expectedRevision: nil, operationID: UUID(), authorization: f.authorization, at: f.date)
                }
                #expect(try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM knowledge_sources") } == 0)
                #expect(try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM knowledge_versions") } == 0)
                #expect(try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM knowledge_operations") } == 0)
                #expect(try f.blobs.digests().count == 1)
                await failing.close()
            } catch { await failing.close(); throw error }
        }
    }
    @Test func revokeUsesExactPendingMaintenanceAndRejectsStaleAuthority() async throws {
        try await withKnowledgeStore { f in
            let first = try await f.importBytes(Data("policy".utf8))
            let allowed = try await f.store.allowSourceRemoteUse(first.source.id, workspaceID: nil, expectedRevision: 1, operationID: UUID(), authorization: f.authorization, at: f.date)
            let request = AgentLibraryMaintenanceRequest(id: UUID(), namespace: "knowledge.revoke", revision: 1, scope: .sources([KnowledgeSources.metadata(allowed)]), requestedAt: f.date)
            let operation = try await f.authority.begin(request, expected: f.authorization)
            await #expect(throws: MiraError.self) { _ = try await f.store.knowledgeSources(scope: f.local, limit: 10) }
            let revoked = try await f.store.revokeSourceRemoteUse(allowed.id, workspaceID: nil, expectedRevision: allowed.revision, maintenance: operation, at: f.date)
            #expect(!revoked.allowsRemoteUse && revoked.revision == 3)
            #expect(try await f.store.revokeSourceRemoteUse(allowed.id, workspaceID: nil, expectedRevision: 2, maintenance: operation, at: f.date) == revoked)
            _ = try await f.authority.complete(operation, at: f.date)
            await #expect(throws: MiraError.self) { _ = try await f.store.revokeSourceRemoteUse(allowed.id, workspaceID: nil, expectedRevision: 2, maintenance: operation, at: f.date) }
            await #expect(throws: MiraError.self) { _ = try await f.store.allowSourceRemoteUse(allowed.id, workspaceID: nil, expectedRevision: 3, operationID: UUID(), authorization: f.authorization, at: f.date) }
        }
    }
    @Test func purgeRemovesCanonicalBodiesAndReceiptsButRetainsSharedBlob() async throws {
        try await withKnowledgeStore { f in
            let bytes = Data("shared source body".utf8), op = UUID()
            let first = try await f.store.importMarkdown(.init(title: "erase title.md", bytes: bytes), workspaceID: nil, updating: nil, expectedRevision: nil, operationID: op, authorization: f.authorization, at: f.date)
            let workspace = Workspace(id: .init(), name: "Other")
            try await f.workspaces.saveWorkspace(workspace, expectedRevision: nil, authorization: f.authorization)
            let other = try await f.store.importMarkdown(.init(title: "retained.md", bytes: bytes), workspaceID: workspace.id, updating: nil, expectedRevision: nil, operationID: UUID(), authorization: f.authorization, at: f.date)
            #expect(first.version.contentHash == other.version.contentHash)
            let request = AgentLibraryMaintenanceRequest(id: UUID(), namespace: "knowledge.delete", revision: 1, scope: .sources([KnowledgeSources.metadata(first.source)]), requestedAt: f.date)
            let operation = try await f.authority.begin(request, expected: f.authorization)
            try await f.store.purgeKnowledgeSource(first.source.id, workspaceID: nil, expectedRevision: 1, maintenance: operation, at: f.date)
            try await f.store.purgeKnowledgeSource(first.source.id, workspaceID: nil, expectedRevision: 1, maintenance: operation, at: f.date)
            #expect(try await f.database.read { try Data.fetchOne($0, sql: "SELECT receipt_json FROM knowledge_operations WHERE operation_id = ?", arguments: [op.uuidString.lowercased()]) } == nil)
            #expect(try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM knowledge_versions") } == 1)
            #expect(try await f.database.read { try Double.fetchOne($0, sql: "SELECT pending_deletion_at FROM knowledge_blobs") } == nil)
            _ = try await f.authority.complete(operation, at: f.date)
            #expect(try f.blobs.read(other.version.contentHash) == bytes)
            await #expect(throws: MiraError.self) { _ = try await f.store.knowledgeSource(first.source.id, versionID: nil, scope: f.local) }
            #expect(try await f.store.knowledgeSource(other.source.id, versionID: nil, scope: .init(workspaceID: workspace.id, destination: .local)).source.id == other.source.id)
        }
    }
    @Test func malformedCanonicalRelationshipAndMissingBlobFailClosed() async throws {
        try await withKnowledgeStore { f in
            let first = try await f.importBytes(Data("consistent".utf8))
            let summary = try #require(try await f.store.knowledgeSource(first.source.id, versionID: nil, scope: f.local).chunks.first)
            try await f.database.write { try $0.execute(sql: "UPDATE knowledge_chunks SET normalized_text = 'z' WHERE id = ?", arguments: [summary.id.rawValue.uuidString.lowercased()]) }
            await #expect(throws: MiraError.self) { _ = try await f.store.searchKnowledge(query: "z", scope: f.local, limit: 6) }
            let normalized = SQLiteKnowledgeStore.normalize(first.source.title + "\n" + summary.headingPath.joined(separator: "\n") + "\nconsistent")
            try await f.database.write { try $0.execute(sql: "UPDATE knowledge_chunks SET normalized_text = ? WHERE id = ?", arguments: [normalized, summary.id.rawValue.uuidString.lowercased()]) }
            try await f.database.write { try $0.execute(sql: "UPDATE knowledge_chunks SET text = 'tampered' WHERE id = ?", arguments: [summary.id.rawValue.uuidString.lowercased()]) }
            await #expect(throws: MiraError.self) { _ = try await f.store.sourceChunk(summary.id, scope: f.local) }
            try await f.database.write { try $0.execute(sql: "UPDATE knowledge_chunks SET text = 'consistent' WHERE id = ?", arguments: [summary.id.rawValue.uuidString.lowercased()]) }
            try f.blobs.remove(first.version.contentHash)
            await #expect(throws: MiraError.self) { _ = try await f.store.sourceChunk(summary.id, scope: f.local) }
            #expect(try await f.store.knowledgeSources(scope: f.local, limit: 10).count == 1)
        }
    }
}

private struct KnowledgeStoreFixture: Sendable {
    let directory: URL; let database: DatabaseQueue; let authority: SQLiteLibraryAuthority
    let workspaces: SQLiteWorkspaceStore; let store: SQLiteKnowledgeStore; let authorization: AgentLibraryAuthorization
    let blobs: ManagedBlobStore
    let date = Date(timeIntervalSince1970: 10_000)
    var local: KnowledgeReadScope { .init(workspaceID: nil, destination: .local) }
    func importBytes(_ bytes: Data) async throws -> KnowledgeImportReceipt {
        try await store.importMarkdown(.init(title: "fixture.md", bytes: bytes), workspaceID: nil, updating: nil, expectedRevision: nil, operationID: UUID(), authorization: authorization, at: date)
    }
}
private func withKnowledgeStore(_ body: (KnowledgeStoreFixture) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-knowledge-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var configuration = Configuration(); configuration.foreignKeysEnabled = true
    configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
    let database = try DatabaseQueue(path: directory.appendingPathComponent("business.sqlite").path, configuration: configuration)
    let authority = try SQLiteLibraryAuthority(database: database, validators: SQLiteKnowledgeStore.maintenanceValidators)
    let workspaces = try SQLiteWorkspaceStore(database: database, libraryID: authority.libraryID)
    let store = try SQLiteKnowledgeStore(database: database, libraryID: authority.libraryID, directory: directory)
    let fixture = KnowledgeStoreFixture(directory: directory, database: database, authority: authority, workspaces: workspaces, store: store, authorization: try await authority.authorization(), blobs: try ManagedBlobStore(directory: directory))
    do { try await body(fixture); await store.close(); await workspaces.close(); await authority.close(); try database.close(); try FileManager.default.removeItem(at: directory) }
    catch { await store.close(); await workspaces.close(); await authority.close(); try? database.close(); try? FileManager.default.removeItem(at: directory); throw error }
}
