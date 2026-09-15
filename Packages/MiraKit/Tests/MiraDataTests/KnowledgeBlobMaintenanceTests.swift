import Foundation
import GRDB
import MiraCore
import Testing

@testable import MiraData

@Suite("Knowledge blob maintenance", .timeLimit(.minutes(1)))
struct KnowledgeBlobMaintenanceTests {
    @Test
    func collectionRetainsHistoricalFailedAndSharedBlobsAndRemovesOrphan() async throws {
        try await withFixture { fixture in
            let historical = try await fixture.store.importMarkdown(
                .init(title: "history.md", bytes: Data("historical body".utf8)),
                workspaceID: nil, updating: nil, expectedRevision: nil, operationID: UUID(),
                authorization: fixture.authorization, at: fixture.date)
            _ = try await fixture.store.importMarkdown(
                .init(title: "history.md", bytes: Data("current body".utf8)),
                workspaceID: nil, updating: historical.source.id, expectedRevision: historical.source.revision,
                operationID: UUID(), authorization: fixture.authorization, at: fixture.date)
            let failed = try await fixture.store.importMarkdown(
                .init(title: "history.md", bytes: Data([0xFF, 0x00])),
                workspaceID: nil, updating: historical.source.id, expectedRevision: historical.source.revision + 1,
                operationID: UUID(), authorization: fixture.authorization, at: fixture.date)
            #expect(failed.version.parseState == .failed)

            let workspace = Workspace(id: .init(), name: "Shared")
            try await fixture.workspaces.saveWorkspace(
                workspace, expectedRevision: nil, authorization: fixture.authorization)
            let shared = try await fixture.store.importMarkdown(
                .init(title: "shared.md", bytes: Data("shared body".utf8)),
                workspaceID: workspace.id, updating: nil, expectedRevision: nil, operationID: UUID(),
                authorization: fixture.authorization, at: fixture.date)

            let failing = try SQLiteKnowledgeStore(
                database: fixture.database, libraryID: fixture.authority.libraryID,
                directory: fixture.knowledgeDirectory,
                faultInjector: { point in
                    if point == .afterBlobInstall { throw MiraError(.storage, "Injected blob publication failure.") }
                })
            await #expect(throws: MiraError.self) {
                _ = try await failing.importMarkdown(
                    .init(title: "orphan.md", bytes: Data("orphan body".utf8)), workspaceID: nil,
                    updating: nil, expectedRevision: nil, operationID: UUID(), authorization: fixture.authorization,
                    at: fixture.date)
            }
            await failing.close()

            let before = try fixture.blobs.digests()
            #expect(before.count == 5)
            let request = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: "knowledge.collect", revision: 1, scope: .library, requestedAt: fixture.date)
            let operation = try await fixture.authority.begin(request, expected: fixture.authorization)
            let report = try await fixture.store.collectKnowledgeBlobs(operation: operation)
            #expect(report.removedCount == 1)
            #expect(report.retainedCount == 4)
            #expect(try fixture.blobs.digests().count == 4)
            #expect(try fixture.blobs.read(historical.version.contentHash) == Data("historical body".utf8))
            #expect(try fixture.blobs.read(failed.version.contentHash) == Data([0xFF, 0x00]))
            #expect(try fixture.blobs.read(shared.version.contentHash) == Data("shared body".utf8))
            try await fixture.store.verifyKnowledgeBlobs(operation: operation)
            _ = try await fixture.authority.complete(operation, at: fixture.date)
        }
    }

    @Test
    func referenceScanFailureLeavesOrphanAndPendingOperationIntact() async throws {
        try await withFixture { fixture in
            let failing = try SQLiteKnowledgeStore(
                database: fixture.database, libraryID: fixture.authority.libraryID,
                directory: fixture.knowledgeDirectory,
                faultInjector: { point in
                    if point == .afterBlobInstall { throw MiraError(.storage, "Injected blob publication failure.") }
                })
            await #expect(throws: MiraError.self) {
                _ = try await failing.importMarkdown(
                    .init(title: "orphan.md", bytes: Data("orphan body".utf8)), workspaceID: nil,
                    updating: nil, expectedRevision: nil, operationID: UUID(), authorization: fixture.authorization,
                    at: fixture.date)
            }
            await failing.close()
            let orphan = try #require(fixture.blobs.digests().first)
            let request = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: "knowledge.collect", revision: 1, scope: .library, requestedAt: fixture.date)
            let operation = try await fixture.authority.begin(request, expected: fixture.authorization)
            let blocked = try SQLiteKnowledgeStore(
                database: fixture.database, libraryID: fixture.authority.libraryID,
                directory: fixture.knowledgeDirectory,
                faultInjector: { point in
                    if point == .beforeReferenceScan { throw MiraError(.storage, "Injected reference scan failure.") }
                })
            do {
                await #expect(throws: MiraError.self) {
                    _ = try await blocked.collectKnowledgeBlobs(operation: operation)
                }
                #expect(try fixture.blobs.digests() == [orphan])
                await blocked.close()
            } catch {
                await blocked.close()
                throw error
            }

            let resumed = try SQLiteKnowledgeStore(
                database: fixture.database, libraryID: fixture.authority.libraryID,
                directory: fixture.knowledgeDirectory)
            do {
                let report = try await resumed.collectKnowledgeBlobs(operation: operation)
                #expect(report.removedCount == 1)
                try await fixture.store.verifyKnowledgeBlobs(operation: operation)
                _ = try await fixture.authority.complete(operation, at: fixture.date)
                await resumed.close()
            } catch {
                await resumed.close()
                throw error
            }
        }
    }

    @Test(arguments: [KnowledgeStorageFaultStage.beforeBlobRemoval, .afterBlobRemoval])
    func sourcePurgeAndRemovalFaultResumeWithoutDeletingSharedReference(stage: KnowledgeStorageFaultStage) async throws
    {
        try await withFixture { fixture in
            let unique = try await fixture.store.importMarkdown(
                .init(title: "unique.md", bytes: Data("unique body".utf8)), workspaceID: nil, updating: nil,
                expectedRevision: nil, operationID: UUID(), authorization: fixture.authorization, at: fixture.date)
            let workspaceB = Workspace(id: .init(), name: "B")
            try await fixture.workspaces.saveWorkspace(
                workspaceB, expectedRevision: nil, authorization: fixture.authorization)
            let sharedA = try await fixture.store.importMarkdown(
                .init(title: "shared.md", bytes: Data("shared body".utf8)), workspaceID: nil,
                updating: unique.source.id,
                expectedRevision: unique.source.revision, operationID: UUID(), authorization: fixture.authorization,
                at: fixture.date)
            let sharedB = try await fixture.store.importMarkdown(
                .init(title: "shared.md", bytes: Data("shared body".utf8)), workspaceID: workspaceB.id, updating: nil,
                expectedRevision: nil, operationID: UUID(), authorization: fixture.authorization, at: fixture.date)
            #expect(sharedA.version.contentHash == sharedB.version.contentHash)

            let deleteRequest = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: "knowledge.delete", revision: 1,
                scope: .sources([KnowledgeSources.metadata(sharedA.source)]), requestedAt: fixture.date)
            let deleteOperation = try await fixture.authority.begin(deleteRequest, expected: fixture.authorization)
            try await fixture.store.purgeKnowledgeSource(
                unique.source.id, workspaceID: nil, expectedRevision: sharedA.source.revision,
                maintenance: deleteOperation, at: fixture.date)
            let collectOperation = deleteOperation
            await fixture.store.close()
            let failing = try SQLiteKnowledgeStore(
                database: fixture.database, libraryID: fixture.authority.libraryID,
                directory: fixture.knowledgeDirectory,
                faultInjector: { point in
                    if point == stage { throw MiraError(.storage, "Injected blob removal failure.") }
                })
            await #expect(throws: MiraError.self) {
                _ = try await failing.collectKnowledgeBlobs(operation: collectOperation)
            }
            await failing.close()

            let resumed = try SQLiteKnowledgeStore(
                database: fixture.database, libraryID: fixture.authority.libraryID,
                directory: fixture.knowledgeDirectory)
            do {
                _ = try await resumed.collectKnowledgeBlobs(operation: collectOperation)
                #expect(try fixture.blobs.read(sharedA.version.contentHash) == Data("shared body".utf8))
                #expect(throws: MiraError.self) { _ = try fixture.blobs.read(unique.version.contentHash) }
                try await resumed.verifyKnowledgeBlobs(operation: collectOperation)
                _ = try await fixture.authority.complete(collectOperation, at: fixture.date)
                await resumed.close()
            } catch {
                await resumed.close()
                throw error
            }
        }
    }

    @Test func missingRetainedFileStopsDeletionAndCollectionRemovesRecognizedTemporaryFiles() async throws {
        try await withFixture { f in
            let content = Data("retained".utf8)
            let imported = try await f.store.importMarkdown(
                .init(title: "retained.md", bytes: content), workspaceID: nil,
                updating: nil, expectedRevision: nil, operationID: UUID(), authorization: f.authorization, at: f.date)
            let orphan = try f.blobs.install(Data("orphan".utf8))
            let temporary = f.knowledgeDirectory.appendingPathComponent(
                "Blobs/\(orphan.prefix(2))/\(orphan.dropFirst(2).prefix(2))/.tmp-\(UUID().uuidString.lowercased())")
            try Data("pending write".utf8).write(to: temporary)
            try f.blobs.remove(imported.version.contentHash)
            let request = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: "knowledge.collect", revision: 1, scope: .library, requestedAt: f.date)
            let operation = try await f.authority.begin(request, expected: f.authorization)
            await #expect(throws: MiraError.self) { _ = try await f.store.collectKnowledgeBlobs(operation: operation) }
            #expect(try f.blobs.read(orphan) == Data("orphan".utf8))
            #expect(FileManager.default.fileExists(atPath: temporary.path))
            _ = try f.blobs.install(content)
            let report = try await f.store.collectKnowledgeBlobs(operation: operation)
            #expect(report.removedCount == 1 && report.retainedCount == 1)
            #expect(!FileManager.default.fileExists(atPath: temporary.path))
            try await f.store.verifyKnowledgeBlobs(operation: operation)
            _ = try await f.authority.complete(operation, at: f.date)
        }
    }

    @Test
    func verifyRejectsRestoredOrphanCompletedOperationAndClosedStore() async throws {
        try await withFixture { fixture in
            let failing = try SQLiteKnowledgeStore(
                database: fixture.database, libraryID: fixture.authority.libraryID,
                directory: fixture.knowledgeDirectory,
                faultInjector: { point in
                    if point == .afterBlobInstall { throw MiraError(.storage, "Injected blob publication failure.") }
                })
            await #expect(throws: MiraError.self) {
                _ = try await failing.importMarkdown(
                    .init(title: "orphan.md", bytes: Data("orphan body".utf8)), workspaceID: nil,
                    updating: nil, expectedRevision: nil, operationID: UUID(), authorization: fixture.authorization,
                    at: fixture.date)
            }
            await failing.close()
            let orphan = try #require(fixture.blobs.digests().first)
            let request = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: "knowledge.collect", revision: 1, scope: .library, requestedAt: fixture.date)
            let operation = try await fixture.authority.begin(request, expected: fixture.authorization)
            let report = try await fixture.store.collectKnowledgeBlobs(operation: operation)
            #expect(report.removedCount == 1)
            try await fixture.store.verifyKnowledgeBlobs(operation: operation)
            _ = try await fixture.authority.complete(operation, at: fixture.date)
            await #expect(throws: MiraError.self) {
                _ = try await fixture.store.collectKnowledgeBlobs(operation: operation)
            }

            let path = fixture.knowledgeDirectory.appendingPathComponent("Blobs", isDirectory: true)
                .appendingPathComponent(String(orphan.prefix(2)), isDirectory: true)
                .appendingPathComponent(String(orphan.dropFirst(2).prefix(2)), isDirectory: true)
                .appendingPathComponent(orphan)
            try Data("orphan body".utf8).write(to: path)
            let secondRequest = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: "knowledge.collect", revision: 1, scope: .library,
                requestedAt: fixture.date.addingTimeInterval(1))
            let second = try await fixture.authority.begin(
                secondRequest, expected: try await fixture.authority.authorization())
            await #expect(throws: MiraError.self) { try await fixture.store.verifyKnowledgeBlobs(operation: second) }
            await fixture.store.close()
            await #expect(throws: MiraError.self) { try await fixture.store.verifyKnowledgeBlobs(operation: second) }
        }
    }
}

private struct KnowledgeBlobFixture: Sendable {
    let root: URL
    let knowledgeDirectory: URL
    let database: DatabaseQueue
    let authority: SQLiteLibraryAuthority
    let workspaces: SQLiteWorkspaceStore
    let store: SQLiteKnowledgeStore
    let blobs: ManagedBlobStore
    let authorization: AgentLibraryAuthorization
    let date = Date(timeIntervalSince1970: 20_000)
}

private func withFixture(_ body: (KnowledgeBlobFixture) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mira-knowledge-gc-\(UUID().uuidString)")
    let knowledgeDirectory = root.appendingPathComponent("knowledge", isDirectory: true)
    try FileManager.default.createDirectory(at: knowledgeDirectory, withIntermediateDirectories: true)
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
    let database = try DatabaseQueue(
        path: root.appendingPathComponent("business.sqlite").path, configuration: configuration)
    let authority = try SQLiteLibraryAuthority(
        database: database, validators: SQLiteKnowledgeStore.maintenanceValidators)
    let workspaces = try SQLiteWorkspaceStore(database: database, libraryID: authority.libraryID)
    let store = try SQLiteKnowledgeStore(
        database: database, libraryID: authority.libraryID, directory: knowledgeDirectory)
    let blobs = try ManagedBlobStore(directory: knowledgeDirectory)
    let fixture = KnowledgeBlobFixture(
        root: root, knowledgeDirectory: knowledgeDirectory, database: database,
        authority: authority, workspaces: workspaces, store: store, blobs: blobs,
        authorization: try await authority.authorization())
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
