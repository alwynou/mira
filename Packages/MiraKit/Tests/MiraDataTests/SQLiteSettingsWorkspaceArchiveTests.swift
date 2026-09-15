import Foundation
import GRDB
import MiraCore
import Testing

@testable import MiraData

@Suite("Settings and workspace archive modules")
struct SQLiteSettingsWorkspaceArchiveTests {
    @Test func modulesDeclareCurrentSchemasAndRestorationPolicies() throws {
        let settings = try SQLiteAgentModelSettings.archiveModule()
        let workspace = try SQLiteWorkspaceStore.archiveModule()
        #expect(settings.identity.name == "model.settings")
        #expect(workspace.identity.name == "workspace.store")
        #expect(settings.identity.revision == 2)
        #expect(workspace.identity.revision == 1)
    }

    @Test func settingsArchiveRestorationDisablesConnectionsAndClearsCredentials() async throws {
        let db = try DatabaseQueue(configuration: archiveConfiguration())
        defer { try? db.close() }
        let authority = try SQLiteLibraryAuthority(database: db)
        let store = try SQLiteAgentModelSettings(database: db, libraryID: authority.libraryID)
        let value = AgentConfigurationValue(schema: .init(id: "archive.test", revision: 1), value: .object([:]))
        let id = ConnectionID()
        let initial = AgentConfiguredConnection(id: id, revision: 1, configurationRevision: 1, name: "Archived", isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: value, credential: nil)], discovery: nil, defaultInvocation: nil)
        let connection = AgentConfiguredConnection(id: id, revision: 2, configurationRevision: 2, name: "Archived", isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: value, credential: .init(reference: "credential.ref", version: 4))], discovery: nil, defaultInvocation: nil)
        try await store.saveConnection(initial, expectedRevision: nil, authorization: authority.authorization())
        try await store.saveConnection(connection, expectedRevision: 1, authorization: authority.authorization())
        let module = try SQLiteAgentModelSettings.archiveModule()
        guard case .prepare(let apply, let verify) = module.restoration else {
            Issue.record("expected restoration preparation")
            return
        }
        try await db.write { try apply($0, Date()) }
        try await db.read { try verify($0) }
        let restored = try await store.connection(id: connection.id)
        #expect(restored?.revision == 2)
        #expect(restored?.configurationRevision == 2)
        #expect(restored?.isEnabled == false)
        #expect(restored?.endpoints.allSatisfy { $0.credential == nil } == true)
        await store.close()
        await authority.close()
    }

    @Test func settingsArchiveAcceptsStaleHistoricalModelConfigurationRevision() async throws {
        let db = try DatabaseQueue(configuration: archiveConfiguration())
        defer { try? db.close() }
        let authority = try SQLiteLibraryAuthority(database: db)
        let store = try SQLiteAgentModelSettings(database: db, libraryID: authority.libraryID)
        let settings = AgentConfigurationValue(schema: .init(id: "archive.test", revision: 1), value: .object([:]))
        let connection = AgentConfiguredConnection(id: .init(), revision: 1, configurationRevision: 1, name: "Historical", isEnabled: false, definitionID: nil, endpoints: [.init(id: "primary", configuration: settings, credential: nil)], discovery: nil, defaultInvocation: nil)
        try await store.saveConnection(connection, expectedRevision: nil, authorization: authority.authorization())
        let model = AgentConfiguredModel(id: .init(), revision: 1, authorizationRevision: 1, reference: .init(connectionID: connection.id, modelID: "historical"), displayName: nil, isEnabled: false, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: .init(id: "archive.adapter", revision: 1), endpointID: "primary", contextWindow: 1024, maximumOutputTokens: nil, capabilities: [:], configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: modelParameterSchema)], facts: [])
        try await store.saveModel(model, expectedRevision: nil, authorization: authority.authorization())
        let updated = AgentConfiguredConnection(id: connection.id, revision: 2, configurationRevision: 2, name: connection.name, isEnabled: false, definitionID: nil, endpoints: [.init(id: "primary", configuration: settings, credential: .init(reference: "synthetic.reference", version: 1))], discovery: nil, defaultInvocation: nil)
        try await store.saveConnection(updated, expectedRevision: 1, authorization: authority.authorization())
        let module = try SQLiteAgentModelSettings.archiveModule()
        _ = try await db.read { try module.inspect($0, FileSessionSnapshot(sessions: [])) }
        await store.close()
        await authority.close()
    }

    @Test func settingsArchiveRejectsMissingMetadata() async throws {
        let db = try DatabaseQueue(configuration: archiveConfiguration())
        defer { try? db.close() }
        let authority = try SQLiteLibraryAuthority(database: db)
        let store = try SQLiteAgentModelSettings(database: db, libraryID: authority.libraryID)
        try await db.write { try $0.execute(sql: "DELETE FROM settings_schema") }
        let module = try SQLiteAgentModelSettings.archiveModule()
        await #expect(throws: MiraError.self) {
            _ = try await db.read { try module.inspect($0, FileSessionSnapshot(sessions: [])) }
        }
        await store.close()
        await authority.close()
    }

    @Test func workspaceArchiveRejectsMissingMetadata() async throws {
        let db = try DatabaseQueue(configuration: archiveConfiguration())
        defer { try? db.close() }
        try await db.write { database in
            try database.execute(
                sql:
                    "CREATE TABLE workspace_schema(id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL CHECK(version=1))"
            )
            try database.execute(
                sql:
                    "CREATE TABLE business_workspaces(id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL CHECK(revision>0), json BLOB NOT NULL CHECK(length(json)<=131072))"
            )
        }
        let module = try SQLiteWorkspaceStore.archiveModule()
        await #expect(throws: MiraError.self) {
            _ = try await db.read { try module.inspect($0, FileSessionSnapshot(sessions: [])) }
        }
    }

    @Test func settingsArchiveRejectsOversizedMirroredIdentifier() async throws {
        let db = try DatabaseQueue(configuration: archiveConfiguration())
        defer { try? db.close() }
        let authority = try SQLiteLibraryAuthority(database: db)
        let store = try SQLiteAgentModelSettings(database: db, libraryID: authority.libraryID)
        let settings = AgentConfigurationValue(schema: .init(id: "archive.test", revision: 1), value: .object([:]))
        let connection = AgentConfiguredConnection(id: .init(), revision: 1, configurationRevision: 1, name: "Bounded", isEnabled: false, definitionID: nil, endpoints: [.init(id: "primary", configuration: settings, credential: nil)], discovery: nil, defaultInvocation: nil)
        try await store.saveConnection(connection, expectedRevision: nil, authorization: authority.authorization())
        try await db.write {
            try $0.execute(
                sql: "UPDATE settings_connections SET id = ?", arguments: [String(repeating: "x", count: 129)])
        }
        let module = try SQLiteAgentModelSettings.archiveModule()
        await #expect(throws: MiraError.self) {
            _ = try await db.read { try module.inspect($0, FileSessionSnapshot(sessions: [])) }
        }
        await store.close()
        await authority.close()
    }

    @Test func settingsAndWorkspaceValidateJournalScopes() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]]) { fixture in
            let workspace = Workspace(id: .init(), name: "Archive workspace")
            try await fixture.workspaces.saveWorkspace(
                workspace, expectedRevision: nil, authorization: fixture.authority.authorization())
            _ = try await fixture.run("Scoped source", workspaceID: workspace.id)
            try await fixture.settings.saveBinding(
                .init(scope: .global, purpose: "chat", routeID: fixture.route.id, revision: 1),
                expectedRevision: nil, authorization: fixture.authority.authorization())
            try await fixture.settings.saveBinding(
                .init(scope: .workspace(workspace.id), purpose: "workspace-chat", routeID: fixture.route.id, revision: 1),
                expectedRevision: nil, authorization: fixture.authority.authorization())
            let settings = try SQLiteAgentModelSettings.archiveModule()
            let workspaces = try SQLiteWorkspaceStore.archiveModule()
            try await fixture.library.withSnapshot { snapshot in
                try fixture.database.read { db in
                    _ = try settings.inspect(db, snapshot)
                    _ = try workspaces.inspect(db, snapshot)
                }
            }
            try await fixture.database.write { db in
                try db.execute(
                    sql: "DELETE FROM business_workspaces WHERE id = ?",
                    arguments: [workspace.id.rawValue.uuidString.lowercased()])
            }
            await #expect(throws: MiraError.self) {
                try await fixture.library.withSnapshot { snapshot in
                    try fixture.database.read { db in _ = try settings.inspect(db, snapshot) }
                }
            }
            await #expect(throws: MiraError.self) {
                try await fixture.library.withSnapshot { snapshot in
                    try fixture.database.read { db in _ = try workspaces.inspect(db, snapshot) }
                }
            }
        }
    }

    private func archiveConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA synchronous=FULL") }
        return configuration
    }
}
