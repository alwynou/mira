import Foundation
import GRDB
import MiraCore
import Testing
@testable import MiraData

@Suite("Knowledge snapshots and local search")
struct KnowledgeStoreTests {
    @Test func duplicateContentAndSameNamesHaveDistinctRules() throws {
        let fixture = try KnowledgeStoreFixture()
        defer { fixture.cleanup() }
        let first = try fixture.importText("# Original\nStable body", name: "same.md")
        let duplicate = try fixture.importText("# Original\nStable body", name: "renamed.md")
        #expect(duplicate.reused && duplicate.source.id == first.source.id)
        let different = try fixture.importText("# Different\nAnother body", name: "same.md")
        #expect(!different.reused && different.source.id != first.source.id)
        #expect(try fixture.store.knowledgeSources(workspaceID: nil, limit: 100).count == 2)
        let detail = try fixture.detail(first.source.id)
        let chunk = try #require(detail.chunks.first)
        #expect(try fixture.store.sourceChunk(chunk.id, workspaceID: nil, connectionID: nil).text == "# Original\nStable body")
    }

    @Test func explicitUpdateKeepsHistoricalBytesAndFailedVersion() throws {
        let fixture = try KnowledgeStoreFixture()
        defer { fixture.cleanup() }
        let first = try fixture.importText("# History\nPrevious assertion")
        let old = try #require(fixture.detail(first.source.id).chunks.first)
        let next = try fixture.importText("# History\nCurrent assertion", updating: first.source)
        #expect(next.source.id == first.source.id && next.version.id != first.version.id)
        #expect(next.source.currentVersionID == next.version.id)
        #expect(try fixture.store.sourceChunk(old.id, workspaceID: nil, connectionID: nil).text.contains("Previous"))
        #expect(try fixture.store.searchKnowledge(query: "Previous", workspaceID: nil, connectionID: nil, limit: 20).hits.isEmpty)
        let bad = fixture.root.appendingPathComponent("bad.md")
        try Data([0xFF, 0xFE]).write(to: bad)
        let failure = try fixture.store.importMarkdownFile(bad, workspaceID: nil, updating: next.source.id, expectedRevision: next.source.revision, at: fixture.date)
        #expect(failure.version.parseState == .failed && failure.version.parseError != nil)
        #expect(failure.source.currentVersionID == next.version.id)
        #expect(try fixture.store.blobs.read(failure.version.contentHash) == Data([0xFF, 0xFE]))
        #expect(try fixture.detail(first.source.id).versions.count == 3)
        #expect(throws: MiraError.self) { try fixture.importText("Stale edit", updating: first.source) }
        try fixture.store.pool.read { try SQLiteMiraStore.validateKnowledgeContents(in: $0) }
    }

    @Test func globalWorkspaceAndRemotePermissionFilterBeforeResults() throws {
        let fixture = try KnowledgeStoreFixture()
        defer { fixture.cleanup() }
        let a = Workspace(id: .init(), name: "A"), b = Workspace(id: .init(), name: "B")
        try fixture.store.saveWorkspace(a, expectedRevision: nil)
        try fixture.store.saveWorkspace(b, expectedRevision: nil)
        let global = try fixture.importText("shared visibility global")
        let local = try fixture.importText("shared visibility workspace", workspaceID: a.id)
        _ = try fixture.importText("shared visibility hidden", workspaceID: b.id)
        #expect(try fixture.store.searchKnowledge(query: "shared", workspaceID: nil, connectionID: nil, limit: 20).hits.map(\.source.id) == [global.source.id])
        let visible = try fixture.store.searchKnowledge(query: "shared", workspaceID: a.id, connectionID: nil, limit: 20)
        #expect(Set(visible.hits.map(\.source.id)) == [global.source.id, local.source.id])
        let connection = ConnectionID()
        #expect(try fixture.store.searchKnowledge(query: "shared", workspaceID: a.id, connectionID: connection, limit: 20).hits.isEmpty)
        _ = try fixture.store.setSourceRemoteUse(local.source.id, workspaceID: a.id, allowed: true, expectedRevision: local.source.revision, at: fixture.date)
        #expect(try fixture.store.searchKnowledge(query: "shared", workspaceID: a.id, connectionID: connection, limit: 1).hits.map(\.source.id) == [local.source.id])
        let chunk = try #require(fixture.store.knowledgeSource(local.source.id, versionID: nil, workspaceID: a.id, connectionID: nil).chunks.first)
        #expect(throws: MiraError.self) { try fixture.store.sourceChunk(chunk.id, workspaceID: b.id, connectionID: nil) }
    }

    @Test func multilingualCodeAndLiteralSearchWorkWithAndWithoutTrigrams() throws {
        let fixture = try KnowledgeStoreFixture()
        defer { fixture.cleanup() }
        // Unicode search fixture: two/three-character Chinese, mixed text, width folding, and literal operators.
        let source = try fixture.importText("# Retrieval\n记忆库 中文检索 SwiftDataStore Sources/MiraCore/App.swift ＡＰＩ literal_% OR \"quoted\" C++") // i18n-fixture: CJK and mixed literal search coverage.
        for useTrigram in [true, false] {
            if !useTrigram { try fixture.store.pool.write { try $0.execute(sql: "DROP TABLE knowledge_trigrams") } }
            for query in ["记忆", "记忆库", "中文检索 Swift", "DataStore", "Sources/MiraCore", "api", "literal_%", "OR", "\"quoted\"", "C++"] { // i18n-fixture: CJK and mixed literal search coverage.
                let result = try fixture.store.searchKnowledge(query: query, workspaceID: nil, connectionID: nil, limit: 20)
                #expect(result.hits.first?.source.id == source.source.id, "Literal query did not match in the selected index path.")
            }
            #expect(try fixture.store.searchKnowledge(query: "absent_%", workspaceID: nil, connectionID: nil, limit: 20).hits.isEmpty)
        }
    }

    @Test func shortChineseFallbackUsesChunkOrderAndCurrentScope() throws {
        let fixture = try KnowledgeStoreFixture()
        defer { fixture.cleanup() }
        let workspaceA = Workspace(id: .init(), name: "A")
        let workspaceB = Workspace(id: .init(), name: "B")
        try fixture.store.saveWorkspace(workspaceA, expectedRevision: nil)
        try fixture.store.saveWorkspace(workspaceB, expectedRevision: nil)
        let current = try fixture.importText("知识 first current", workspaceID: workspaceA.id) // i18n-fixture: short Chinese query plan regression.
        _ = try fixture.importText("知识 hidden workspace", workspaceID: workspaceB.id) // i18n-fixture: hidden Chinese source.
        let replaced = try fixture.importText("知识 previous version") // i18n-fixture: historical Chinese source.
        _ = try fixture.importText("replacement without the query", updating: replaced.source)

        let query = SQLiteMiraStore.knowledgeCandidateQuery(
            words: ["知识"], workspaceID: workspaceA.id, connectionID: nil, indexed: false // i18n-fixture: Chinese fallback plan.
        )
        let details = try fixture.store.pool.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(query.sql)", arguments: query.arguments).map { row in
                row["detail"] as String
            }
        }
        #expect(details.contains { $0.contains("SCAN c") })
        #expect(details.allSatisfy { !$0.localizedCaseInsensitiveContains("USE TEMP B-TREE") })

        let result = try fixture.store.searchKnowledge(query: "知识", workspaceID: workspaceA.id, connectionID: nil, limit: 20) // i18n-fixture: two-scalar Chinese fallback.
        #expect(result.hits.first?.source.id == current.source.id)
        #expect(result.hits.allSatisfy { $0.source.id != replaced.source.id })
        let connectionID = ConnectionID()
        #expect(try fixture.store.searchKnowledge(query: "知识", workspaceID: workspaceA.id, connectionID: connectionID, limit: 20).hits.isEmpty) // i18n-fixture: local-only short-query source.
        _ = try fixture.store.setSourceRemoteUse(current.source.id, workspaceID: workspaceA.id, allowed: true, expectedRevision: current.source.revision, at: fixture.date)
        #expect(try fixture.store.searchKnowledge(query: "知识", workspaceID: workspaceA.id, connectionID: connectionID, limit: 20).hits.map(\.source.id) == [current.source.id]) // i18n-fixture: explicitly disclosed short-query source.
    }

    @Test func importFaultsLeaveExistingCanonicalVersionsIntact() throws {
        let control = KnowledgeFaultControl()
        let fixture = try KnowledgeStoreFixture(faults: control)
        defer { fixture.cleanup() }
        let existing = try fixture.importText("Trusted original")
        for stage in [KnowledgeStorageFaultStage.afterBlobInstall, .beforeImportCommit] {
            control.set(stage)
            #expect(throws: MiraError.self) { try fixture.importText("Uncommitted \(stage)", updating: existing.source) }
            control.set(nil)
            let detail = try fixture.detail(existing.source.id)
            #expect(detail.source.currentVersionID == existing.version.id && detail.versions.count == 1)
            #expect(try fixture.store.blobs.read(existing.version.contentHash) == Data("Trusted original".utf8))
        }
        #expect(try fixture.store.blobs.digests().count == 3)
        _ = try fixture.store.collectUnreferencedBlobs(at: fixture.date)
        let collected = try fixture.store.collectUnreferencedBlobs(at: fixture.date.addingTimeInterval(7 * 86_400))
        #expect(collected.removedCount == 2 && collected.retainedCount == 1)
    }

    @Test func garbageCollectionHonorsAllHistoricalAndSharedReferences() throws {
        let control = KnowledgeFaultControl()
        let fixture = try KnowledgeStoreFixture(faults: control)
        defer { fixture.cleanup() }
        let workspace = Workspace(id: .init(), name: "Shared bytes")
        try fixture.store.saveWorkspace(workspace, expectedRevision: nil)
        let first = try fixture.importText("Shared original")
        let shared = try fixture.importText("Shared original", workspaceID: workspace.id)
        let updated = try fixture.importText("Current version", updating: first.source)
        try fixture.store.deleteKnowledgeSource(shared.source.id, workspaceID: workspace.id, expectedRevision: 1, at: fixture.date)
        #expect(try fixture.store.collectUnreferencedBlobs(at: fixture.date).retainedCount == 2)
        #expect(try fixture.store.collectUnreferencedBlobs(at: fixture.date.addingTimeInterval(9 * 86_400)).removedCount == 0)
        try fixture.store.deleteKnowledgeSource(updated.source.id, workspaceID: nil, expectedRevision: updated.source.revision, at: fixture.date)
        _ = try fixture.store.collectUnreferencedBlobs(at: fixture.date)
        for stage in [KnowledgeStorageFaultStage.beforeReferenceScan, .beforeBlobRemoval] {
            control.set(stage)
            #expect(throws: MiraError.self) { try fixture.store.collectUnreferencedBlobs(at: fixture.date.addingTimeInterval(8 * 86_400)) }
            control.set(nil)
            #expect(try fixture.store.blobs.digests().count == 2)
        }
        #expect(try fixture.store.collectUnreferencedBlobs(at: fixture.date.addingTimeInterval(8 * 86_400)).removedCount == 2)
        #expect(try fixture.store.knowledgeSources(workspaceID: workspace.id, limit: 100).isEmpty)
    }

    @Test func shortQueryDisclosesBoundedCandidateScan() throws {
        let fixture = try KnowledgeStoreFixture()
        defer { fixture.cleanup() }
        let initial = try fixture.importText("Initial source")
        let chunk = try #require(fixture.detail(initial.source.id).chunks.first)
        // Synthetic projection load isolates the search budget from parser/import throughput.
        try fixture.store.pool.write { db in
            for sequence in 1...20_001 {
                var summary = chunk
                summary.id = .init(); summary.sequence = sequence
                try db.execute(sql: "INSERT INTO source_chunks (id,source_id,version_id,sequence,text,normalized_text,summary_json) VALUES (?,?,?,?,?,?,?)", arguments: [summary.id.rawValue.uuidString.lowercased(), initial.source.id.rawValue.uuidString.lowercased(), initial.version.id.rawValue.uuidString.lowercased(), sequence, "Synthetic candidate", "synthetic candidate", try SQLiteMiraStore.encode(summary)])
            }
        }
        let result = try fixture.store.searchKnowledge(query: "zz", workspaceID: nil, connectionID: nil, limit: 100)
        #expect(result.hits.isEmpty && result.isTruncated && result.scannedCandidates <= 20_000)
    }
}

private final class KnowledgeFaultControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stage: KnowledgeStorageFaultStage?
    func set(_ value: KnowledgeStorageFaultStage?) { lock.withLock { stage = value } }
    func check(_ value: KnowledgeStorageFaultStage) throws {
        if lock.withLock({ stage == value }) { throw MiraError(.storage, "Synthetic knowledge storage failure.") }
    }
}

private struct KnowledgeStoreFixture {
    let root: URL
    let store: SQLiteMiraStore
    let date = Date(timeIntervalSince1970: 1_000.125)
    init(faults: KnowledgeFaultControl? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mira-knowledge-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteMiraStore(directory: root.appendingPathComponent("library"), knowledgeFaultInjector: { try faults?.check($0) })
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func importText(_ text: String, name: String = "source.md", workspaceID: WorkspaceID? = nil, updating: KnowledgeSource? = nil) throws -> KnowledgeImportReceipt {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return try store.importMarkdownFile(url, workspaceID: workspaceID, updating: updating?.id, expectedRevision: updating?.revision, at: date)
    }
    func detail(_ id: KnowledgeSourceID) throws -> KnowledgeSourceDetail {
        try store.knowledgeSource(id, versionID: nil, workspaceID: nil, connectionID: nil)
    }
}
