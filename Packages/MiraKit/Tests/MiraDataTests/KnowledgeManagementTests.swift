import Foundation
import GRDB
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Knowledge management reads", .timeLimit(.minutes(1)))
struct KnowledgeManagementTests {
    @Test func pagesMoreThanOneHundredSourcesWithStableCursor() async throws {
        try await withManagementStore { f in
            for index in 0..<101 {
                _ = try await f.store.importMarkdown(
                    .init(title: String(format: "Source %03d", index), bytes: Data("body-\(index)".utf8)),
                    workspaceID: nil, updating: nil, expectedRevision: nil, operationID: UUID(),
                    authorization: f.authorization, at: f.date.addingTimeInterval(Double(index)))
            }
            let first = try await f.store.knowledgeManagementPage(.init(limit: 100))
            #expect(first.items.count == 100)
            let cursor = try #require(first.nextCursor)
            let second = try await f.store.knowledgeManagementPage(.init(limit: 100, cursor: cursor))
            #expect(second.items.count == 1)
            #expect(Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)))
            await #expect(throws: MiraError.self) {
                _ = try await f.store.knowledgeManagementPage(.init(query: "different", cursor: cursor))
            }
        }
    }

    @Test func statusIncludesLatestFailedVersionAndSearchIgnoresHistory() async throws {
        try await withManagementStore { f in
            let first = try await f.store.importMarkdown(
                .init(title: "Status", bytes: Data("current phrase".utf8)), workspaceID: nil,
                updating: nil, expectedRevision: nil, operationID: UUID(), authorization: f.authorization, at: f.date)
            _ = try await f.store.importMarkdown(
                .init(title: "Status", bytes: Data([0xff, 0x00])), workspaceID: nil,
                updating: first.source.id, expectedRevision: first.source.revision, operationID: UUID(),
                authorization: f.authorization, at: f.date.addingTimeInterval(1))
            let attention = try await f.store.knowledgeManagementPage(.init(status: .needsAttention))
            let item = try #require(attention.items.first { $0.id == first.source.id })
            #expect(item.currentVersion?.id == first.version.id)
            #expect(item.latestVersion?.parseState == .failed)
            #expect(try await f.store.knowledgeManagementPage(.init(query: "current phrase")).items.count == 1)
            #expect(try await f.store.knowledgeManagementPage(.init(query: "binary")).items.isEmpty)
        }
    }

    @Test func scopesAreExactAndManagementRemainsLocalOnly() async throws {
        try await withManagementStore { f in
            let workspace = Workspace(id: .init(), name: "Project")
            try await f.workspaces.saveWorkspace(workspace, expectedRevision: nil, authorization: f.authorization)
            let inbox = try await f.store.importMarkdown(
                .init(title: "Inbox", bytes: Data("inbox".utf8)), workspaceID: nil,
                updating: nil, expectedRevision: nil, operationID: UUID(), authorization: f.authorization, at: f.date)
            _ = try await f.store.allowSourceRemoteUse(inbox.source.id, workspaceID: nil,
                expectedRevision: inbox.source.revision, operationID: UUID(), authorization: f.authorization, at: f.date)
            let project = try await f.store.importMarkdown(
                .init(title: "Project", bytes: Data("project".utf8)), workspaceID: workspace.id,
                updating: nil, expectedRevision: nil, operationID: UUID(), authorization: f.authorization, at: f.date)
            #expect(try await f.store.knowledgeManagementPage(.init(scope: .all)).items.count == 2)
            #expect(try await f.store.knowledgeManagementPage(.init(scope: .inbox)).items.map(\.id) == [inbox.source.id])
            #expect(try await f.store.knowledgeManagementPage(.init(scope: .workspace(workspace.id))).items.map(\.id) == [project.source.id])
            #expect(try await f.store.knowledgeManagementPage(.init(status: .localOnly)).items.map(\.id) == [project.source.id])
            await #expect(throws: MiraError.self) {
                _ = try await f.store.knowledgeManagementPage(.init(scope: .workspace(.init())))
            }
            await #expect(throws: MiraError.self) {
                _ = try await f.store.knowledgeDocumentPage(project.source.id, versionID: inbox.version.id,
                    scope: f.local, afterSequence: nil, limit: 16)
            }
        }
    }

    @Test func documentPagesPreserveExactCRLFAndRejectCorruptBlob() async throws {
        try await withManagementStore { f in
            let text = (0..<12).map { "## Section \($0)\r\n" + String(repeating: "value \($0) ", count: 260) }.joined(separator: "\r\n")
            let receipt = try await f.store.importMarkdown(
                .init(title: "Reader", bytes: Data(text.utf8)), workspaceID: nil,
                updating: nil, expectedRevision: nil, operationID: UUID(), authorization: f.authorization, at: f.date)
            let detail = try await f.store.knowledgeSource(receipt.source.id, versionID: receipt.version.id, scope: f.local)
            #expect(detail.chunks.count > 1)
            var after: Int?
            var all: [SourceChunk] = []
            repeat {
                let page = try await f.store.knowledgeDocumentPage(receipt.source.id, versionID: receipt.version.id,
                    scope: f.local, afterSequence: after, limit: 2)
                all += page.chunks
                after = page.nextSequence
            } while after != nil
            #expect(all.map { $0.summary.sequence } == detail.chunks.map { $0.sequence })
            #expect(all.contains { $0.text.contains("value 7") && $0.text.contains("\r\n") })
            try f.blobs.remove(receipt.version.contentHash)
            await #expect(throws: MiraError.self) {
                _ = try await f.store.knowledgeDocumentPage(receipt.source.id, versionID: receipt.version.id,
                    scope: f.local, afterSequence: nil, limit: 2)
            }
        }
    }

    @Test func detailReportsVersionHistoryTruncation() async throws {
        try await withManagementStore { f in
            var receipt = try await f.store.importMarkdown(
                .init(title: "History", bytes: Data("revision-0".utf8)), workspaceID: nil,
                updating: nil, expectedRevision: nil, operationID: UUID(), authorization: f.authorization, at: f.date)
            for index in 1...100 {
                receipt = try await f.store.importMarkdown(
                    .init(title: "History", bytes: Data("revision-\(index)".utf8)), workspaceID: nil,
                    updating: receipt.source.id, expectedRevision: receipt.source.revision, operationID: UUID(),
                    authorization: f.authorization, at: f.date.addingTimeInterval(Double(index)))
            }
            let detail = try await f.store.knowledgeSource(receipt.source.id, versionID: nil, scope: f.local)
            #expect(detail.versions.count == 100)
            #expect(detail.hasMoreVersions)
        }
    }

    @Test func multiTermSearchRequiresOneChunkAndFindsLateMatch() async throws {
        try await withManagementStore { f in
            let lateText = (0..<130).map { index in
                "## Section \(index)\n" + String(repeating: "alpha ", count: 900) + (index == 129 ? "late-target" : "")
            }.joined(separator: "\n")
            let late = try await f.store.importMarkdown(
                .init(title: "Late match", bytes: Data(lateText.utf8)), workspaceID: nil,
                updating: nil, expectedRevision: nil, operationID: UUID(), authorization: f.authorization, at: f.date)
            let splitText = "# First\n" + String(repeating: "alpha ", count: 900) + "\n# Second\n" + String(repeating: "target ", count: 900)
            _ = try await f.store.importMarkdown(
                .init(title: "Split terms", bytes: Data(splitText.utf8)), workspaceID: nil,
                updating: nil, expectedRevision: nil, operationID: UUID(), authorization: f.authorization, at: f.date)
            let result = try await f.store.knowledgeManagementPage(.init(query: "alpha late-target"))
            let item = try #require(result.items.first { $0.id == late.source.id })
            #expect(item.match?.sequence ?? -1 > 100)
            #expect(!result.items.contains { $0.source.title == "Split terms" })
        }
    }

    @Test func unicodeTitleSearchIncludesFailedSource() async throws {
        try await withManagementStore { f in
            let receipt = try await f.store.importMarkdown(
                .init(title: "中文资料", bytes: Data([0xff, 0x00])), workspaceID: nil, // i18n-fixture: Verify Unicode source title search.
                updating: nil, expectedRevision: nil, operationID: UUID(), authorization: f.authorization, at: f.date)
            let page = try await f.store.knowledgeManagementPage(.init(query: "中文资料")) // i18n-fixture: Verify Unicode source title search.
            let item = try #require(page.items.first { $0.id == receipt.source.id })
            #expect(item.latestVersion?.parseState == .failed)
            #expect(item.match == nil)
        }
    }
}

private struct ManagementStoreFixture: Sendable {
    let directory: URL
    let database: DatabaseQueue
    let authority: SQLiteLibraryAuthority
    let workspaces: SQLiteWorkspaceStore
    let store: SQLiteKnowledgeStore
    let authorization: AgentLibraryAuthorization
    let blobs: ManagedBlobStore
    let date = Date(timeIntervalSince1970: 10_000)
    var local: KnowledgeReadScope { .init(workspaceID: nil, destination: .local) }
}

private func withManagementStore(_ body: (ManagementStoreFixture) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-knowledge-management-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var configuration = Configuration(); configuration.foreignKeysEnabled = true
    let database = try DatabaseQueue(path: directory.appendingPathComponent("business.sqlite").path, configuration: configuration)
    let authority = try SQLiteLibraryAuthority(database: database, validators: SQLiteKnowledgeStore.maintenanceValidators)
    let workspaces = try SQLiteWorkspaceStore(database: database, libraryID: authority.libraryID)
    let store = try SQLiteKnowledgeStore(database: database, libraryID: authority.libraryID, directory: directory)
    let fixture = ManagementStoreFixture(directory: directory, database: database, authority: authority,
        workspaces: workspaces, store: store, authorization: try await authority.authorization(),
        blobs: try ManagedBlobStore(directory: directory))
    do {
        try await body(fixture)
        await store.close(); await workspaces.close(); await authority.close(); try database.close()
        try FileManager.default.removeItem(at: directory)
    } catch {
        await store.close(); await workspaces.close(); await authority.close(); try? database.close()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}
