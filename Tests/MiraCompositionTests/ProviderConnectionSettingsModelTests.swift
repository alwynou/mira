import Foundation
import MiraCore
import MiraProviders
import Testing

@Suite("provider connection settings model", .timeLimit(.minutes(2)))
@MainActor
struct ProviderConnectionSettingsModelTests {
    @Test func asynchronouslyLoadsStoredKeyAndRebuildsSavedOptions() async throws {
        try await withDirectory { directory in
            let credentials = CompositionCredentials()
            let library = try await openLibrary(directory: directory, credentials: credentials)
            defer { Task { _ = await library.close() } }
            let group = try await library.workloads()
            let saved = try await saveHTTPConnection(group: group, secret: "stored-secret")
            let configured = try await saveCatalogModel(group: group, connection: saved)
            let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
            let model = ProviderConnectionSettingsModel(existing: saved, template: provider, library: library, isDemo: false)
            model.update(existing: saved, models: [configured.model], presets: [configured.preset])
            await model.waitForCredentials()
            #expect(model.secret == "stored-secret")
            #expect(model.hasStoredKey)
            #expect(model.canTest)
            #expect(model.error == nil)
        }
    }

    @Test func savePublishesAnEchoingCallbackAfterTheAcceptedCommit() async throws {
        try await withDirectory { directory in
            let credentials = CompositionCredentials()
            let library = try await openLibrary(directory: directory, credentials: credentials)
            defer { Task { _ = await library.close() } }
            let group = try await library.workloads()
            let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
            let model = ProviderConnectionSettingsModel(existing: nil, template: provider, library: library, isDemo: false)
            model.secret = "new-secret"
            var callbackConnection: AgentConfiguredConnection?
            model.save { connection in callbackConnection = connection }
            await model.waitForAction()
            let callback = try #require(callbackConnection)
            #expect(model.baseline == callback)
            #expect(model.hasStoredKey)
            #expect(model.error == nil)
            #expect(try await group.modelSettings.connection(id: callback.id) == callback)
            #expect(try await group.credentialSettings.credential(
                for: callback, endpointID: callback.endpoints[0].id) == "new-secret")
        }
    }

    @Test func disablingRetainsUnsavedEndpointAndSecretDraftWhilePersistingOnlyTheToggle() async throws {
        try await withDirectory { directory in
            let credentials = CompositionCredentials()
            let library = try await openLibrary(directory: directory, credentials: credentials)
            defer { Task { _ = await library.close() } }
            let group = try await library.workloads()
            let saved = try await saveHTTPConnection(group: group, secret: "old-secret")
            let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
            let model = ProviderConnectionSettingsModel(existing: saved, template: provider, library: library, isDemo: false)
            model.update(existing: saved, models: [], presets: [])
            await model.waitForCredentials()
            model.baseURL = "https://example.invalid/v1"
            model.secret = "unsaved-secret"
            model.setEnabled(false) { _ in }
            await model.waitForAction()
            let persisted = try #require(await group.modelSettings.connection(id: saved.id))
            #expect(!persisted.isEnabled)
            #expect(persisted.endpoints == saved.endpoints)
            #expect(persisted.defaultInvocation == saved.defaultInvocation)
            #expect(model.baseline?.endpoints == saved.endpoints)
            #expect(model.baseURL == "https://example.invalid/v1")
            #expect(model.secret == "unsaved-secret")
            #expect(model.hasChanges)
            #expect(try await group.credentialSettings.credential(
                for: persisted, endpointID: persisted.endpoints[0].id) == "old-secret")
        }
    }

    @Test func saveReportsCASConflictAfterTheCurrentConnectionChanges() async throws {
        try await withDirectory { directory in
            let credentials = CompositionCredentials()
            let library = try await openLibrary(directory: directory, credentials: credentials)
            defer { Task { _ = await library.close() } }
            let group = try await library.workloads()
            let saved = try await saveHTTPConnection(group: group, secret: "old-secret")
            let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
            let model = ProviderConnectionSettingsModel(existing: saved, template: provider, library: library, isDemo: false)
            model.update(existing: saved, models: [], presets: [])
            await model.waitForCredentials()
            model.secret = "replacement-secret"
            let external = try await group.credentialSettings.saveConnection(
                id: saved.id, name: "Changed elsewhere", isEnabled: saved.isEnabled,
                definitionID: saved.definitionID, endpoints: saved.endpoints,
                discovery: saved.discovery, defaultInvocation: saved.defaultInvocation,
                previous: saved, credentialEndpointID: saved.endpoints[0].id, credential: .keep).connection
            model.save { _ in }
            await model.waitForAction()
            #expect(model.error?.code == .conflict)
            #expect(model.baseline == saved)
            #expect(try await group.modelSettings.connection(id: saved.id) == external)
            #expect(try await group.credentialSettings.credential(
                for: external, endpointID: external.endpoints[0].id) == "old-secret")
        }
    }

    @Test func stopClearsSecretButDrainsAnAcceptedSaveAndKeepsItsFrozenValue() async throws {
        try await withDirectory { directory in
            let credentials = CompositionCredentials()
            let library = try await openLibrary(directory: directory, credentials: credentials)
            defer { Task { _ = await library.close() } }
            let group = try await library.workloads()
            let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
            let model = ProviderConnectionSettingsModel(existing: nil, template: provider, library: library, isDemo: false)
            model.secret = "accepted-secret"
            credentials.block(.save)
            model.save { _ in }
            try await eventually { credentials.enteredOperations.contains(.save) }
            let stopping = Task { await model.stop() }
            try await eventually { model.secret.isEmpty && model.isWorking }
            credentials.release(.save)
            await stopping.value
            let saved = try #require(try await group.modelSettings.connections(after: nil, limit: 128).first)
            #expect(try await group.credentialSettings.credential(
                for: saved, endpointID: saved.endpoints[0].id) == "accepted-secret")
            #expect(!model.isWorking)
        }
    }

    @Test func cancellingTemporaryTestWaitsForAnActuallyBlockedCredentialRead() async throws {
        try await withDirectory { directory in
            let credentials = CompositionCredentials()
            let library = try await openLibrary(directory: directory, credentials: credentials)
            defer { Task { _ = await library.close() } }
            let group = try await library.workloads()
            let saved = try await saveHTTPConnection(group: group, secret: "test-secret")
            let configured = try await saveCatalogModel(group: group, connection: saved)
            let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
            let model = ProviderConnectionSettingsModel(existing: saved, template: provider, library: library, isDemo: false)
            model.update(existing: saved, models: [configured.model], presets: [configured.preset])
            await model.waitForCredentials()
            credentials.block(.read)
            model.test()
            try await eventually { model.isTesting && credentials.enteredOperations.contains(.read) }
            model.cancel()
            try await Task.sleep(for: .milliseconds(20))
            #expect(model.isTesting)
            credentials.release(.read)
            await model.waitForAction()
            #expect(!model.isTesting)
            #expect(model.error == nil)
        }
    }

    @Test func anOlderSnapshotCannotReplaceTheLatestConnection() async throws {
        try await withDirectory { directory in
            let credentials = CompositionCredentials()
            let library = try await openLibrary(directory: directory, credentials: credentials)
            defer { Task { _ = await library.close() } }
            let group = try await library.workloads()
            let original = try await saveHTTPConnection(group: group, secret: "snapshot-secret")
            let updated = try await group.credentialSettings.saveConnection(
                id: original.id, name: "Updated connection", isEnabled: original.isEnabled,
                definitionID: original.definitionID, endpoints: original.endpoints,
                discovery: original.discovery, defaultInvocation: original.defaultInvocation,
                previous: original, credentialEndpointID: original.endpoints[0].id, credential: .keep).connection
            let model = ProviderConnectionSettingsModel(existing: original, template: nil, library: library, isDemo: true)
            model.update(existing: updated, models: [], presets: [])
            model.update(existing: original, models: [], presets: [])
            #expect(model.baseline == updated)
            #expect(model.name == "Updated connection")
            await model.stop()
        }
    }

    @Test func editingConnectionPreservesSecondaryEndpointsAndInvocation() async throws {
        try await withDirectory { directory in
            let credentials = CompositionCredentials()
            let library = try await openLibrary(directory: directory, credentials: credentials)
            defer { Task { _ = await library.close() } }
            let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
            let template = try provider.makeConnection(credential: nil)
            let secondaryConfiguration = AgentConfigurationValue(
                schema: HTTPConnectionSettings.schema.identity,
                value: try SessionCodec.decode(
                    JSONValue.self,
                    from: SessionCodec.encode(HTTPConnectionSettings(baseURL: "https://secondary.example/v1"))))
            let secondary = AgentModelEndpoint(id: "secondary", configuration: secondaryConfiguration, credential: nil)
            let group = try await library.workloads()
            let saved = try await group.credentialSettings.saveConnection(
                id: template.id, name: template.name, isEnabled: true, definitionID: template.definitionID,
                endpoints: [template.endpoints[0], secondary], discovery: template.discovery,
                defaultInvocation: template.defaultInvocation, previous: nil,
                credentialEndpointID: template.endpoints[0].id, credential: .keep).connection
            let editor = ProviderConnectionSettingsModel(existing: saved, template: provider, library: library, isDemo: false)
            editor.update(existing: saved, models: [], presets: [])
            await editor.waitForCredentials()
            editor.secret = "fixture-secret"
            editor.baseURL = "https://primary.example/v1"
            editor.save { _ in }
            await editor.waitForAction()
            let updated = try #require(await group.modelSettings.connection(id: saved.id))
            #expect(updated.endpoints.map(\.id) == ["primary", "secondary"])
            #expect(updated.endpoints[1] == secondary)
            #expect(updated.defaultInvocation == saved.defaultInvocation)
            #expect(updated.discovery == saved.discovery)
        }
    }

    private func openLibrary(directory: URL, credentials: CompositionCredentials) async throws -> MacLibrary {
        try await MacLibrary.open(
            directory: directory, notifications: CompositionNotifications(), credentials: credentials,
            modules: { _ in [] })
    }

    private func saveHTTPConnection(group: MacLibraryWorkloads, secret: String) async throws -> AgentConfiguredConnection {
        let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
        let template = try provider.makeConnection(credential: nil)
        return try await group.credentialSettings.saveConnection(
            id: template.id, name: "Fixture connection", isEnabled: true,
            definitionID: template.definitionID, endpoints: template.endpoints,
            discovery: template.discovery, defaultInvocation: template.defaultInvocation,
            previous: nil, credentialEndpointID: template.endpoints[0].id,
            credential: .replace(secret)).connection
    }

    private func saveCatalogModel(group: MacLibraryWorkloads, connection: AgentConfiguredConnection) async throws -> ProviderConnectionTestModel {
        let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
        let catalog = try #require(provider.model(id: "gpt-4"))
        let configured = try ProviderConnectionTestModel(catalog: catalog, connection: connection)
        try await group.modelSettings.savePoolModel(
            configured.model, preset: configured.preset,
            expectedModelRevision: nil, expectedPresetRevision: nil)
        return configured
    }
}
