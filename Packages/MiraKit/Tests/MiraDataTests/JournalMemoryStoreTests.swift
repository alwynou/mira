import Foundation
import GRDB
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("SQLite memory domain", .timeLimit(.minutes(1)))
struct JournalMemoryStoreTests {
    @Test func manualSourceIsIdempotentAndPayloadReuseConflicts() async throws {
        try await withMemoryFixture { f in
            let draft = MemoryDraft(content: "Prefers tea", scope: .global)
            let op = UUID(); let source = UUID()
            let a = try await f.store.createMemory(draft: draft, source: .manualEntry(id: source, statement: draft.content), operationID: op, replacing: nil, expectedRevision: nil, authorization: f.authorization, at: f.date)
            let b = try await f.store.createMemory(draft: draft, source: .manualEntry(id: source, statement: draft.content), operationID: op, replacing: nil, expectedRevision: nil, authorization: f.authorization, at: f.date)
            #expect(a.memory.id == b.memory.id)
            await #expect(throws: MiraError.self) {
                _ = try await f.store.createMemory(draft: .init(content: "Other", scope: .global), source: .manualEntry(id: source, statement: "Other"), operationID: op, replacing: nil, expectedRevision: nil, authorization: f.authorization, at: f.date)
            }
        }
    }

    @Test func reviseAndStateOperationReplayUsesFrozenResultAndCAS() async throws {
        try await withMemoryFixture { f in
            let m = try await f.create("one")
            let op = UUID(); let revised = try await f.store.reviseMemory(m.id, workspaceID: nil, draft: .init(content: "two", scope: .global), expectedRevision: 1, operationID: op, authorization: f.authorization, at: f.date)
            let replay = try await f.store.reviseMemory(m.id, workspaceID: nil, draft: .init(content: "two", scope: .global), expectedRevision: 1, operationID: op, authorization: f.authorization, at: f.date)
            #expect(revised == replay)
            let stateOp = UUID(); let archived = try await f.store.changeMemoryState(m.id, workspaceID: nil, state: .archived, expectedRevision: 2, operationID: stateOp, authorization: f.authorization, at: f.date)
            #expect(try await f.store.changeMemoryState(m.id, workspaceID: nil, state: .archived, expectedRevision: 2, operationID: stateOp, authorization: f.authorization, at: f.date) == archived)
            await #expect(throws: MiraError.self) { _ = try await f.store.changeMemoryState(m.id, workspaceID: nil, state: .active, expectedRevision: 2, operationID: UUID(), authorization: f.authorization, at: f.date) }
        }
    }

    @Test func sourceWorkspaceVisibilityAndStateFiltering() async throws {
        try await withMemoryFixture { f in
            let workspace = WorkspaceID(); try await f.saveWorkspace(Workspace(id: workspace, name: "Test"))
            _ = try await f.create("global")
            let scoped = try await f.store.createMemory(draft: .init(content: "private", scope: .workspace(workspace)), source: .manualEntry(id: UUID(), statement: "private"), operationID: UUID(), replacing: nil, expectedRevision: nil, authorization: f.authorization, at: f.date)
            #expect(try await f.store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 128).memories.contains(where: { $0.id == scoped.memory.id }) == false)
            #expect(try await f.store.memoryList(workspaceID: workspace, states: [.active], query: "", limit: 128).memories.contains(where: { $0.id == scoped.memory.id }))
            #expect(try await f.store.memoryList(workspaceID: workspace, states: [.archived], query: "", limit: 128).memories.isEmpty)
        }
    }

    @Test func replacementConfirmationUpdatesBothRevisions() async throws {
        try await withMemoryFixture { f in
            let original = try await f.create("old")
            let current = try await f.store.createMemory(draft: .init(content: "new", scope: .global), source: .manualEntry(id: UUID(), statement: "new"), operationID: UUID(), replacing: original.id, expectedRevision: original.revision, authorization: f.authorization, at: f.date)
            let candidate = try await f.store.createMemory(draft: .init(content: "newer", scope: .global), source: .manualEntry(id: UUID(), statement: "newer"), operationID: UUID(), replacing: original.id, expectedRevision: 2, authorization: f.authorization, at: f.date)
            let confirmed = try await f.store.confirmMemoryReplacement(candidate.memory.id, workspaceID: nil, replacingCurrent: current.memory.id, expectedCandidateRevision: 1, expectedCurrentRevision: 1, operationID: UUID(), authorization: f.authorization, at: f.date)
            #expect(confirmed.state == .active)
            #expect((try await f.store.memoryDetail(current.memory.id, workspaceID: nil)).memory.supersededBy == candidate.memory.id)
        }
    }

    @Test func boundedSearch() async throws {
        try await withMemoryFixture { f in
            _ = try await f.create("bounded")
            await #expect(throws: MiraError.self) { _ = try await f.store.memoryList(workspaceID: nil, states: [], query: "", limit: 0) }
        }
    }

    @Test func managementPageFiltersBeforeKeysetPaginationAndRetainsBodyFreeForgottenRows() async throws {
        try await withMemoryFixture { f in
            let workspace = WorkspaceID()
            try await f.saveWorkspace(Workspace(id: workspace, name: "Test"))
            let one = try await f.store.createMemory(draft: .init(content: "needle first", scope: .global), source: .manualEntry(id: UUID(), statement: "needle first"), operationID: UUID(), replacing: nil, expectedRevision: nil, authorization: f.authorization, at: f.date).memory
            let second = try await f.store.createMemory(draft: .init(content: "needle second", scope: .workspace(workspace)), source: .manualEntry(id: UUID(), statement: "needle second"), operationID: UUID(), replacing: nil, expectedRevision: nil, authorization: f.authorization, at: f.date).memory
            let third = try await f.store.createMemory(draft: .init(content: "needle third", scope: .global), source: .manualEntry(id: UUID(), statement: "needle third"), operationID: UUID(), replacing: nil, expectedRevision: nil, authorization: f.authorization, at: f.date).memory
            _ = try await f.store.reviseMemory(one.id, workspaceID: nil, draft: .init(content: "needle first revised", scope: .global), expectedRevision: 1, operationID: UUID(), authorization: f.authorization, at: f.date.addingTimeInterval(60))
            let unrelated = try await f.create("other text")
            _ = try await f.store.changeMemoryState(unrelated.id, workspaceID: nil, state: .archived, expectedRevision: 1, operationID: UUID(), authorization: f.authorization, at: f.date)

            let firstPage = try await f.store.memoryManagementPage(.init(scope: .all, query: "needle", limit: 1), at: f.date)
            #expect(firstPage.memories.count == 1)
            #expect(firstPage.memories[0].id == one.id)
            #expect(firstPage.nextCursor != nil)
            let next = try await f.store.memoryManagementPage(.init(scope: .all, query: "needle", limit: 1, cursor: firstPage.nextCursor), at: f.date)
            #expect(next.memories.count == 1)
            #expect(firstPage.memories[0].id != next.memories[0].id)
            let thirdPage = try await f.store.memoryManagementPage(.init(scope: .all, query: "needle", limit: 1, cursor: next.nextCursor), at: f.date)
            #expect(Set([one.id, second.id, third.id]) == Set([firstPage.memories[0].id, next.memories[0].id, thirdPage.memories[0].id]))

            let scoped = try await f.store.memoryManagementPage(.init(scope: .workspace(workspace)), at: f.date)
            #expect(scoped.memories.map(\.id) == [second.id])
            let global = try await f.store.memoryManagementPage(.init(scope: .global, query: "needle", order: .oldestFirst), at: f.date)
            #expect(global.memories.map(\.id) == [third.id, one.id])
            let history = try await f.store.memoryManagementPage(.init(section: .history), at: f.date)
            #expect(history.memories.map(\.id) == [unrelated.id])

            let expiring = try await f.store.createMemory(draft: .init(content: "expires", scope: .global, validUntil: f.date), source: .manualEntry(id: UUID(), statement: "expires"), operationID: UUID(), replacing: nil, expectedRevision: nil, authorization: f.authorization, at: f.date).memory
            let status = expiring.managementStatus(at: f.date)
            #expect(status == .expired)
            let invalidCursor = MemoryManagementCursor(timestamp: f.date, memoryID: one.id, queryKey: "different")
            await #expect(throws: MiraError.self) {
                _ = try await f.store.memoryManagementPage(.init(query: "different", cursor: invalidCursor), at: f.date)
            }
            await #expect(throws: MiraError.self) { _ = try await f.store.memoryManagementPage(.init(limit: 101), at: f.date) }
        }
    }

    @Test func managementPageFindsValidityTransitionsBeyondCurrentPage() async throws {
        try await withMemoryFixture { f in
            let workspace = WorkspaceID()
            try await f.saveWorkspace(Workspace(id: workspace, name: "Other"))
            let beginsSoon = try await f.store.createMemory(
                draft: .init(content: "transition begins", scope: .global,
                             validFrom: f.date.addingTimeInterval(60), validUntil: f.date.addingTimeInterval(300)),
                source: .manualEntry(id: UUID(), statement: "transition begins"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: f.authorization, at: f.date).memory
            _ = try await f.store.createMemory(
                draft: .init(content: "transition expires", scope: .global,
                             validUntil: f.date.addingTimeInterval(120)),
                source: .manualEntry(id: UUID(), statement: "transition expires"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: f.authorization, at: f.date)
            _ = try await f.store.createMemory(
                draft: .init(content: "unrelated", scope: .global, validFrom: f.date.addingTimeInterval(30)),
                source: .manualEntry(id: UUID(), statement: "unrelated"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: f.authorization, at: f.date)
            _ = try await f.store.createMemory(
                draft: .init(content: "transition other scope", scope: .workspace(workspace),
                             validFrom: f.date.addingTimeInterval(20)),
                source: .manualEntry(id: UUID(), statement: "transition other scope"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: f.authorization, at: f.date)
            let visible = try await f.store.createMemory(
                draft: .init(content: "transition visible", scope: .global),
                source: .manualEntry(id: UUID(), statement: "transition visible"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: f.authorization,
                at: f.date.addingTimeInterval(600)).memory

            let page = try await f.store.memoryManagementPage(
                .init(scope: .global, section: .current, query: "transition", limit: 1), at: f.date)
            #expect(page.memories.map(\.id) == [visible.id])
            #expect(page.nextTransitionAt == f.date.addingTimeInterval(60))
            #expect(beginsSoon.managementStatus(at: f.date) == .notYetValid)
        }
    }

    @Test func purgeRequiresPendingMaintenanceAndRemovesBody() async throws {
        try await withMemoryFixture { f in
            let m = try await f.create("forget me")
            let request = AgentLibraryMaintenanceRequest(id: UUID(), namespace: "memory.forget", revision: 1, scope: .sources([.domain(namespace: "memories", id: m.id.rawValue, revision: m.revision)]), requestedAt: f.date)
            let maintenance = try await f.authority.begin(request, expected: f.authorization)
            await #expect(throws: MiraError.self) { _ = try await f.store.memoryDetail(m.id, workspaceID: nil) }
            let forgotten = try await f.store.purgeMemory(m.id, workspaceID: nil, expectedRevision: m.revision, maintenance: maintenance, at: f.date)
            #expect(forgotten.memoryID == m.id)
            try await f.authority.complete(maintenance, at: f.date)
            let detail = try await f.store.memoryDetail(m.id, workspaceID: nil)
            #expect(detail.memory.draft == nil)
            #expect(detail.evidence.allSatisfy { $0.excerpt == nil })
            let management = try await f.store.memoryManagementPage(.init(section: .history), at: f.date)
            let retained = try #require(management.memories.first { $0.id == m.id })
            #expect(retained.draft == nil)
            #expect(retained.managementStatus(at: f.date) == .forgotten)
        }
    }
}

private struct MemoryFixture: Sendable {
    let directory: URL; let database: DatabaseQueue; let authority: SQLiteLibraryAuthority; let workspaceStore: SQLiteWorkspaceStore; let store: SQLiteMemoryStore; let authorization: AgentLibraryAuthorization
    let date = Date(timeIntervalSince1970: 10_000)
    func create(_ text: String) async throws -> Memory { try await store.createMemory(draft: .init(content: text, scope: .global), source: .manualEntry(id: UUID(), statement: text), operationID: UUID(), replacing: nil, expectedRevision: nil, authorization: authorization, at: date).memory }
    func saveWorkspace(_ workspace: Workspace) async throws { try await workspaceStore.saveWorkspace(workspace, expectedRevision: nil, authorization: authorization) }
}

private func withMemoryFixture(_ body: (MemoryFixture) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mira-memory-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("business.sqlite"); var config = Configuration(); config.foreignKeysEnabled = true; config.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
    let db = try DatabaseQueue(path: path.path, configuration: config); let authority = try SQLiteLibraryAuthority(database: db, validators: [SQLiteMemoryStore.maintenanceValidator]); let workspaceStore = try SQLiteWorkspaceStore(database: db, libraryID: authority.libraryID); let store = try SQLiteMemoryStore(database: db, libraryID: authority.libraryID)
    do { try await body(.init(directory: dir, database: db, authority: authority, workspaceStore: workspaceStore, store: store, authorization: try await authority.authorization())); await store.close(); await workspaceStore.close(); await authority.close(); try db.close(); try FileManager.default.removeItem(at: dir) }
    catch { await store.close(); await workspaceStore.close(); await authority.close(); try? db.close(); try? FileManager.default.removeItem(at: dir); throw error }
}
