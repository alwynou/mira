import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("SQLite model metadata store", .timeLimit(.minutes(1)))
struct SQLiteAgentModelMetadataStoreTests {
    @Test func publishAtomicallyPersistsSnapshotAndCatalogModelUpdates() async throws {
        try await withFixture { f in
            let initial = try await f.settings.model(id: f.model.id)
            let previous = try #require(initial)
            let updated = f.updatedModel(previous, revision: 2)
            let snapshot = f.snapshot(revision: 1, marker: "first")

            try await f.store.publish(
                snapshot, expectedRevision: nil,
                updates: [.init(connection: f.connection, previous: previous, updated: updated)],
                authorization: f.authorization)

            #expect(try await f.store.snapshot(sourceID: snapshot.sourceID, authorization: f.authorization) == snapshot)
            #expect(try await f.settings.model(id: f.model.id) == updated)
        }
    }

    @Test func staleModelOrConnectionRejectsWholePublishWithoutOverwritingCache() async throws {
        try await withFixture { f in
            let previous = try #require(try await f.settings.model(id: f.model.id))
            let updated = f.updatedModel(previous, revision: 2)
            let first = f.snapshot(revision: 1, marker: "first")
            try await f.store.publish(
                first, expectedRevision: nil,
                updates: [.init(connection: f.connection, previous: previous, updated: updated)],
                authorization: f.authorization)

            let staleModelUpdate = AgentModelMetadataUpdate(
                connection: f.connection, previous: previous, updated: updated)
            let staleSnapshot = f.snapshot(revision: 2, marker: "stale-model")
            await #expect(throws: MiraError.self) {
                try await f.store.publish(
                    staleSnapshot, expectedRevision: 1, updates: [staleModelUpdate],
                    authorization: f.authorization)
            }
            #expect(try await f.store.snapshot(sourceID: first.sourceID, authorization: f.authorization) == first)
            #expect(try await f.settings.model(id: f.model.id) == updated)

            let next = f.updatedModel(updated, revision: 3)
            let staleConnection = f.connection.copy(name: "stale connection")
            let staleConnectionUpdate = AgentModelMetadataUpdate(
                connection: staleConnection, previous: updated, updated: next)
            let second = f.snapshot(revision: 2, marker: "stale-connection")
            await #expect(throws: MiraError.self) {
                try await f.store.publish(
                    second, expectedRevision: 1, updates: [staleConnectionUpdate],
                    authorization: f.authorization)
            }
            #expect(try await f.store.snapshot(sourceID: first.sourceID, authorization: f.authorization) == first)
            #expect(try await f.settings.model(id: f.model.id) == updated)
        }
    }

    @Test func snapshotCASRejectsCompetingRevisionAndStaleAuthorization() async throws {
        try await withFixture { f in
            let previous = try #require(try await f.settings.model(id: f.model.id))
            let updated = f.updatedModel(previous, revision: 2)
            let first = f.snapshot(revision: 1, marker: "first")
            try await f.store.publish(
                first, expectedRevision: nil,
                updates: [.init(connection: f.connection, previous: previous, updated: updated)],
                authorization: f.authorization)

            let second = f.snapshot(revision: 2, marker: "second")
            await #expect(throws: MiraError.self) {
                try await f.store.publish(second, expectedRevision: nil, updates: [], authorization: f.authorization)
            }
            let staleAuthorization = AgentLibraryAuthorization(
                libraryID: f.authorization.libraryID, epoch: f.authorization.epoch + 1)
            await #expect(throws: MiraError.self) {
                try await f.store.snapshot(sourceID: first.sourceID, authorization: staleAuthorization)
            }
            #expect(try await f.store.snapshot(sourceID: first.sourceID, authorization: f.authorization) == first)
        }
    }

    @Test func snapshotReopensAndArchiveInspectionDoesNotExposeCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mira-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("business.sqlite")
        let database = try DatabaseQueue(path: path.path, configuration: metadataConfiguration())
        let authority = try SQLiteLibraryAuthority(database: database)
        let authorization = try await authority.authorization()
        let settings = try SQLiteAgentModelSettings(database: database, libraryID: authority.libraryID)
        let metadata = try SQLiteAgentModelMetadataStore(database: database, libraryID: authority.libraryID)
        let snapshot = AgentModelMetadataSnapshot(
            sourceID: "catalog.test", revision: 1,
            document: .init(schema: .init(id: "metadata.document", revision: 1), sourceRevision: "v1",
                             observedAt: Date(timeIntervalSince1970: 1_800_000_000),
                             payload: .object(["credential": .string("absent")])))
        try await metadata.publish(snapshot, expectedRevision: nil, updates: [], authorization: authorization)
        await settings.close()
        await authority.close()
        try database.close()

        let reopened = try DatabaseQueue(path: path.path, configuration: metadataConfiguration())
        let reopenedAuthority = try SQLiteLibraryAuthority(database: reopened)
        let reopenedMetadata = try SQLiteAgentModelMetadataStore(database: reopened, libraryID: reopenedAuthority.libraryID)
        let reopenedAuthorization = try await reopenedAuthority.authorization()
        #expect(try await reopenedMetadata.snapshot(sourceID: snapshot.sourceID, authorization: reopenedAuthorization) == snapshot)
        let archive = try SQLiteAgentModelMetadataStore.archiveModule()
        _ = try await reopened.read { try archive.inspect($0, FileSessionSnapshot(sessions: [])) }
        await reopenedAuthority.close()
        try reopened.close()
    }
}

private struct MetadataFixture: Sendable {
    let database: DatabaseQueue
    let authority: SQLiteLibraryAuthority
    let authorization: AgentLibraryAuthorization
    let settings: SQLiteAgentModelSettings
    let store: SQLiteAgentModelMetadataStore
    let connection: AgentConfiguredConnection
    let model: AgentConfiguredModel

    func snapshot(revision: Int, marker: String) -> AgentModelMetadataSnapshot {
        .init(sourceID: "catalog.test", revision: revision,
              document: .init(schema: .init(id: "metadata.document", revision: 1), sourceRevision: "v1",
                               observedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(revision)),
                               payload: .object(["marker": .string(marker)])))
    }

    func updatedModel(_ previous: AgentConfiguredModel, revision: Int) -> AgentConfiguredModel {
        let invocation = previous.invocations[0]
        let updatedInvocation = AgentModelInvocationSpec(
            id: invocation.id, revision: invocation.revision, adapter: invocation.adapter,
            endpointID: invocation.endpointID, contextWindow: (invocation.contextWindow ?? 0) + 1024,
            maximumOutputTokens: invocation.maximumOutputTokens, capabilities: invocation.capabilities,
            configuration: invocation.configuration, parameterSchema: invocation.parameterSchema,
            maximumInputTokens: invocation.maximumInputTokens)
        let fact = AgentModelMetadataFact(
            field: AgentModelMetadataField.contextWindow, value: .number(Double(updatedInvocation.contextWindow ?? 0)),
            source: .catalog, sourceID: "catalog.test", sourceRevision: "v1",
            observedAt: Date(timeIntervalSince1970: 1_800_000_010), invocationID: invocation.id)
        return .init(id: previous.id, revision: revision, authorizationRevision: previous.authorizationRevision,
                     reference: previous.reference, displayName: previous.displayName, isEnabled: previous.isEnabled,
                     invocations: [updatedInvocation], facts: [fact])
    }
}

private func withFixture(_ body: (MetadataFixture) async throws -> Void) async throws {
    let database = try DatabaseQueue(configuration: metadataConfiguration())
    let authority = try SQLiteLibraryAuthority(database: database)
    let authorization = try await authority.authorization()
    let settings = try SQLiteAgentModelSettings(database: database, libraryID: authority.libraryID)
    let store = try SQLiteAgentModelMetadataStore(database: database, libraryID: authority.libraryID)
    let configuration = AgentConfigurationValue(schema: .init(id: "metadata.connection", revision: 1), value: .object([:]))
    let connection = AgentConfiguredConnection(
        id: .init(), revision: 1, configurationRevision: 1, name: "Metadata fixture", isEnabled: true,
        definitionID: nil, endpoints: [.init(id: "primary", configuration: configuration, credential: nil)],
        discovery: nil, defaultInvocation: nil)
    let invocation = AgentModelInvocationSpec(
        id: "default", revision: 1, adapter: .init(id: "metadata.adapter", revision: 1), endpointID: "primary",
        contextWindow: 4096, maximumOutputTokens: nil,
        capabilities: [AgentModelCapabilityID.streamingText: .declared],
        configuration: .init(schema: .init(id: "metadata.invocation", revision: 1), value: .object([:])),
        parameterSchema: modelParameterSchema)
    let model = AgentConfiguredModel(
        id: .init(), revision: 1, authorizationRevision: 1,
        reference: .init(connectionID: connection.id, modelID: "metadata-model"), displayName: nil,
        isEnabled: true, invocations: [invocation], facts: [])
    try await settings.saveConnection(connection, expectedRevision: nil, authorization: authorization)
    try await settings.saveModel(model, expectedRevision: nil, authorization: authorization)
    let fixture = MetadataFixture(database: database, authority: authority, authorization: authorization,
                                  settings: settings, store: store, connection: connection, model: model)
    do {
        try await body(fixture)
    } catch {
        await settings.close(); await authority.close(); try? database.close(); throw error
    }
    await settings.close(); await authority.close(); try database.close()
}

private func metadataConfiguration() -> Configuration {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
    return configuration
}

private extension AgentConfiguredConnection {
    func copy(name: String) -> AgentConfiguredConnection {
        .init(id: id, revision: revision, configurationRevision: configurationRevision, name: name,
              isEnabled: isEnabled, definitionID: definitionID, endpoints: endpoints,
              discovery: discovery, defaultInvocation: defaultInvocation)
    }
}
