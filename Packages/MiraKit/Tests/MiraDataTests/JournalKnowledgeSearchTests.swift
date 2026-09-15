import Foundation
import GRDB
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Journal knowledge search", .timeLimit(.minutes(1)))
struct JournalKnowledgeSearchTests {
    @Test func literalAndSearchKeepsNonASCIIAndRanksExactPhrase() async throws {
        try await withKnowledgeFixture { f in
            _ = try await f.importSource("Phrase", text: "alpha beta appears together. alpha only appears here.")
            _ = try await f.importSource("Chinese", text: "知识库中的偏好与项目说明。") // i18n-fixture: Literal Unicode knowledge search coverage.

            let phrase = try await f.store.searchKnowledge(query: "alpha beta", scope: f.scope, limit: 20)
            #expect(phrase.hits.count == 1)
            #expect(phrase.hits.first?.source.title == "Phrase")
            #expect(phrase.hits.first?.snippet.contains("alpha beta") == true)

            let nonASCII = try await f.store.searchKnowledge(query: "知识", scope: f.scope, limit: 20) // i18n-fixture: Literal Unicode knowledge search coverage.
            #expect(nonASCII.hits.count == 1)
            #expect(nonASCII.hits.first?.source.title == "Chinese")
        }
    }

    @Test func scopeAndRemoteEligibilityFilterBeforeLimit() async throws {
        try await withKnowledgeFixture { f in
            let workspace = try await f.makeWorkspace("A")
            let other = try await f.makeWorkspace("B")
            _ = try await f.importSource("Global", text: "shared needle global")
            let local = try await f.importSource("Local", workspaceID: workspace, text: "shared needle local")
            _ = try await f.importSource("Other", workspaceID: other, text: "shared needle other")
            _ = try await f.importSource("Private", workspaceID: workspace, text: "shared needle private")

            let scope = KnowledgeReadScope(workspaceID: workspace, destination: .local)
            let result = try await f.store.searchKnowledge(query: "shared needle", scope: scope, limit: 20)
            #expect(result.hits.map(\.source.title).sorted() == ["Global", "Local", "Private"])

            let remoteScope = KnowledgeReadScope(workspaceID: workspace, destination: .model(f.route))
            let remote = try await f.store.allowSourceRemoteUse(local.source.id, workspaceID: workspace,
                                                                  expectedRevision: local.source.revision,
                                                                  operationID: UUID(), authorization: f.authorization, at: f.date)
            let remoteResult = try await f.store.searchKnowledge(query: "shared needle", scope: remoteScope, limit: 20)
            #expect(remoteResult.hits.contains(where: { $0.source.id == remote.id }))
            #expect(remoteResult.hits.contains(where: { $0.source.title == "Private" }) == false)
        }
    }

    @Test func onlyCurrentReadyVersionIsSearchable() async throws {
        try await withKnowledgeFixture { f in
            let first = try await f.importSource("Versioned", text: "old unique phrase")
            let second = try await f.importSource("Versioned", updating: first.source.id,
                                                  expectedRevision: first.source.revision,
                                                  text: "new unique phrase")
            #expect(second.source.currentVersionID == second.version.id)
            #expect(try await f.store.searchKnowledge(query: "old unique", scope: f.scope, limit: 20).hits.isEmpty)
            #expect(try await f.store.searchKnowledge(query: "new unique", scope: f.scope, limit: 20).hits.isEmpty == false)
        }
    }

    @Test func ineligibleRowsAreExcludedBeforeCandidateCap() async throws {
        try await withKnowledgeFixture { f in
            let target = try await f.makeWorkspace("Target")
            let privateWorkspace = try await f.makeWorkspace("Private")
            let hidden = try await f.importSource("Hidden", workspaceID: privateWorkspace, text: "needle hidden seed")
            let versionID = hidden.version.id

            // Populate more than the candidate cap with rows from a workspace
            // excluded by the requested scope. The eligible global row is
            // inserted afterwards, so a cap applied before scope filtering
            // would hide it.
            try await f.database.write { db in
                for sequence in 1...19_999 {
                    let text = "needle hidden \(sequence)"
                    let summary = SourceChunkSummary(
                        id: .init(), sourceID: hidden.source.id, sourceVersionID: versionID,
                        sequence: sequence, startLine: 1, endLine: 1,
                        startUTF8Offset: 0, endUTF8Offset: text.utf8.count,
                        headingPath: [], contentHash: SQLiteKnowledgeStore.hash(Data(text.utf8)))
                    let normalized = SQLiteKnowledgeStore.normalize(text)
                    try db.execute(
                        sql: "INSERT INTO knowledge_chunks(id, source_id, version_id, sequence, text, normalized_text, json) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        arguments: [SQLiteKnowledgeStore.key(summary.id), SQLiteKnowledgeStore.key(summary.sourceID),
                                     SQLiteKnowledgeStore.key(summary.sourceVersionID), sequence, text, normalized,
                                     try SQLiteKnowledgeStore.encode(summary)])
                    let rowID = db.lastInsertedRowID
                    try db.execute(sql: "INSERT INTO knowledge_words(rowid, content) VALUES (?, ?)",
                                   arguments: [rowID, normalized])
                    try db.execute(sql: "INSERT INTO knowledge_trigrams(rowid, content) VALUES (?, ?)",
                                   arguments: [rowID, normalized])
                }
            }
            let global = try await f.importSource("Eligible", text: "needle visible")
            let result = try await f.store.searchKnowledge(
                query: "needle", scope: .init(workspaceID: target, destination: .local), limit: 1)
            #expect(result.hits.count == 1)
            #expect(result.hits.first?.source.id == global.source.id)
        }
    }

    @Test func shortQueryPlanUsesRowIDOrderWithoutTemporarySort() async throws {
        try await withKnowledgeFixture { f in
            _ = try await f.importSource("Plan", text: "a row")
            let details = try await f.database.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    EXPLAIN QUERY PLAN
                    SELECT c.*
                    FROM knowledge_chunks c
                    CROSS JOIN knowledge_sources s ON s.id = c.source_id
                    JOIN knowledge_versions v ON v.id = c.version_id AND v.source_id = s.id
                    WHERE s.deleted_at IS NULL AND s.current_version_id = c.version_id
                      AND v.parse_state = 'ready' AND s.workspace_id IS NULL
                    ORDER BY c.rowid LIMIT 20001
                    """)
                return rows.map { $0["detail"] as String }
            }
            #expect(details.isEmpty == false)
            #expect(details.allSatisfy { !$0.localizedCaseInsensitiveContains("USE TEMP B-TREE") })
        }
    }
}

private struct KnowledgeFixture: Sendable {
    let directory: URL
    let database: DatabaseQueue
    let authority: SQLiteLibraryAuthority
    let workspaceStore: SQLiteWorkspaceStore
    let settings: SQLiteAgentModelSettings
    let store: SQLiteKnowledgeStore
    let authorization: AgentLibraryAuthorization
    let date = Date(timeIntervalSince1970: 20_000)
    let scope: KnowledgeReadScope
    let route: AgentModelRoute

    func makeWorkspace(_ name: String) async throws -> WorkspaceID {
        let id = WorkspaceID()
        try await workspaceStore.saveWorkspace(.init(id: id, name: name), expectedRevision: nil, authorization: authorization)
        return id
    }

    func importSource(_ title: String, workspaceID: WorkspaceID? = nil, updating: KnowledgeSourceID? = nil,
                      expectedRevision: Int? = nil, text: String) async throws -> KnowledgeImportReceipt {
        try await store.importMarkdown(.init(title: title, bytes: Data(text.utf8)), workspaceID: workspaceID,
                                       updating: updating, expectedRevision: expectedRevision, operationID: UUID(),
                                       authorization: authorization, at: date)
    }
}

private func withKnowledgeFixture(_ body: (KnowledgeFixture) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-knowledge-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("business.sqlite")
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
    let database: DatabaseQueue
    do { database = try DatabaseQueue(path: path.path, configuration: configuration) }
    catch { try? FileManager.default.removeItem(at: directory); throw error }
    var authority: SQLiteLibraryAuthority?
    var workspaceStore: SQLiteWorkspaceStore?
    var settings: SQLiteAgentModelSettings?
    var store: SQLiteKnowledgeStore?
    do {
        let createdAuthority = try SQLiteLibraryAuthority(database: database); authority = createdAuthority
        let createdWorkspaceStore = try SQLiteWorkspaceStore(database: database, libraryID: createdAuthority.libraryID); workspaceStore = createdWorkspaceStore
        let createdSettings = try SQLiteAgentModelSettings(database: database, libraryID: createdAuthority.libraryID); settings = createdSettings
        let settingsValue = AgentConfigurationValue(schema: .init(id: "knowledge.test", revision: 1), value: .object([:]))
        let connection = AgentConfiguredConnection(id: .init(), revision: 1, configurationRevision: 1, name: "Knowledge fixture", isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: settingsValue, credential: nil)], discovery: nil, defaultInvocation: nil)
        let model = AgentConfiguredModel(id: .init(), revision: 1, authorizationRevision: 1, reference: .init(connectionID: connection.id, modelID: "knowledge.model"), displayName: nil, isEnabled: true, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: .init(id: "knowledge.adapter", revision: 1), endpointID: "primary", contextWindow: 8_192, maximumOutputTokens: nil, capabilities: [AgentModelCapabilityID.streamingText: .declared], configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: modelParameterSchema)], facts: [])
        let preset = AgentRoutePreset(id: RouteID(model.id.rawValue), revision: 1, name: "Knowledge fixture", modelDescriptorID: model.id, invocationID: "default", maximumOutputTokens: 1_024, configuration: settingsValue)
        try await createdSettings.saveConnection(connection, expectedRevision: nil, authorization: createdAuthority.authorization())
        try await createdSettings.savePoolModel(model, preset: preset, expectedModelRevision: nil, expectedPresetRevision: nil, authorization: createdAuthority.authorization())
        let route = try AgentModelRouteCandidate(connection: connection, model: model, preset: preset).freeze(configuration: .object([:]))
        let createdStore = try SQLiteKnowledgeStore(database: database, libraryID: createdAuthority.libraryID, directory: directory); store = createdStore
        let authorization = try await createdAuthority.authorization()
        try await body(.init(directory: directory, database: database, authority: createdAuthority,
                             workspaceStore: createdWorkspaceStore, settings: createdSettings, store: createdStore, authorization: authorization,
                             scope: .init(workspaceID: nil, destination: .local), route: route))
        await createdStore.close(); await createdSettings.close(); await createdWorkspaceStore.close(); await createdAuthority.close(); try database.close()
        try FileManager.default.removeItem(at: directory)
    } catch {
        if let store { await store.close() }
        if let settings { await settings.close() }
        if let workspaceStore { await workspaceStore.close() }
        if let authority { await authority.close() }
        try? database.close()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}
