import Foundation
import MiraCore
import MiraProviders
import Testing

@Suite("pool model editor contracts")
@MainActor
struct PoolModelEditorModelTests {
    @Test func newPoolModelUsesOneAtomicSettingsSave() async throws {
        try await withHTTPLibrary { library in
            let group = try await library.workloads()
            let connection = try await saveConnection(in: group)
            var callbackCount = 0
            let editor = PoolModelEditorModel(
                existing: nil, connection: connection, preset: nil, initialModelID: "gpt-4",
                library: library, isDemo: false, onSaved: { callbackCount += 1 })
            await editor.observe()
            editor.contextWindowText = "16384"
            editor.maxOutputTokensText = "4096"
            editor.textDeclared = true
            editor.startSave()
            try await eventually { !editor.isSaving && editor.saveConfirmation > 0 }
            let models = try await group.modelSettings.models(connectionID: connection.id, after: nil, limit: 128)
            let saved = try #require(models.first(where: { $0.modelID == "gpt-4" }))
            let preset = try #require(await group.modelSettings.preset(id: RouteID(saved.id.rawValue)))
            #expect(preset.maximumOutputTokens == 4096)
            #expect(try AgentModelMetadataResolver.resolve(saved.invocations[0], facts: saved.facts).contextWindow == 16_384)
            #expect(callbackCount == 1)
            await editor.stop()
        }
    }

    @Test func staleEditorRevisionIsRejectedBySettingsCAS() async throws {
        try await withHTTPLibrary { library in
            let group = try await library.workloads()
            let connection = try await saveConnection(in: group)
            let configured = try ProviderModelCatalog.bundled.configuration(
                connection: connection, modelID: "gpt-4", isEnabled: true)
            try await group.modelSettings.savePoolModel(
                configured.model, preset: configured.preset,
                expectedModelRevision: nil, expectedPresetRevision: nil)
            let first = PoolModelEditorModel(
                existing: configured.model, connection: connection, preset: configured.preset,
                initialModelID: configured.model.modelID, library: library, isDemo: false, onSaved: {})
            let second = PoolModelEditorModel(
                existing: configured.model, connection: connection, preset: configured.preset,
                initialModelID: configured.model.modelID, library: library, isDemo: false, onSaved: {})
            await first.observe(); await second.observe()
            try await eventually { !first.isLoading && !second.isLoading && first.canSave && second.canSave }
            first.maxOutputTokensText = "2048"
            first.startSave()
            try await eventually { !first.isSaving && first.saveConfirmation > 0 }
            second.maxOutputTokensText = "1024"
            second.startSave()
            try await eventually { !second.isSaving && second.error != nil }
            #expect(second.error?.code == .conflict)
            let saved = try #require(await group.modelSettings.preset(id: configured.preset.id))
            #expect(saved.maximumOutputTokens == 2048)
            await first.stop(); await second.stop()
        }
    }

    @Test func savedModelIdentityCannotBeChangedByThisEditor() async throws {
        try await withHTTPLibrary { library in
            let group = try await library.workloads()
            let connection = try await saveConnection(in: group)
            let configured = try ProviderModelCatalog.bundled.configuration(
                connection: connection, modelID: "gpt-4", isEnabled: true)
            try await group.modelSettings.savePoolModel(
                configured.model, preset: configured.preset,
                expectedModelRevision: nil, expectedPresetRevision: nil)
            let editor = PoolModelEditorModel(
                existing: configured.model, connection: connection, preset: configured.preset,
                initialModelID: configured.model.modelID, library: library, isDemo: false, onSaved: {})
            await editor.observe()
            editor.modelIDChanged("gpt-4-renamed")
            try await eventually { !editor.isLoading && editor.invocation != nil && editor.canSave }
            editor.startSave()
            try await eventually { !editor.isSaving && editor.error != nil }
            #expect(editor.error?.code == .conflict)
            #expect(try await group.modelSettings.model(id: configured.model.id) == configured.model)
            await editor.stop()
        }
    }

    @Test func catalogLoadsMetadataAndInvocationFactsForNewModels() async throws {
        try await withHTTPLibrary { library in
            let group = try await library.workloads()
            let connection = try await saveConnection(in: group)
            let editor = PoolModelEditorModel(
                existing: nil, connection: connection, preset: nil, initialModelID: "gpt-4",
                library: library, isDemo: false, onSaved: {})
            await editor.observe()
            try await eventually { editor.catalogMetadata != nil && editor.invocation != nil }
            #expect(editor.catalogMetadata?.displayName == "GPT-4")
            #expect(editor.catalogMetadata?.pricing != nil)
            #expect(!editor.contextWindowText.isEmpty)
            #expect(editor.thinkingModes.contains("providerDefault"))
            await editor.stop()
            _ = group
        }
    }

    @Test func stopDrainsAcceptedSaveWithoutLateCallback() async throws {
        try await withHTTPLibrary { library in
            let group = try await library.workloads()
            let connection = try await saveConnection(in: group)
            let configured = try ProviderModelCatalog.bundled.configuration(
                connection: connection, modelID: "gpt-4", isEnabled: true)
            try await group.modelSettings.savePoolModel(
                configured.model, preset: configured.preset,
                expectedModelRevision: nil, expectedPresetRevision: nil)
            var callbackCount = 0
            let editor = PoolModelEditorModel(
                existing: configured.model, connection: connection, preset: configured.preset,
                initialModelID: configured.model.modelID, library: library, isDemo: false,
                onSaved: { callbackCount += 1 })
            await editor.observe()
            try await eventually { editor.canSave }
            editor.maxOutputTokensText = "2048"
            editor.startSave()
            try await eventually { editor.isSaving }
            await editor.stop()
            #expect(callbackCount == 0)
            #expect(editor.isStopped)
            #expect(!editor.isSaving)
        }
    }

    @Test func selectedInvocationAndPartialPresetConfigurationArePersistedTogether() async throws {
        try await withHTTPLibrary { library in
            let group = try await library.workloads()
            let connection = try await saveConnection(in: group)
            let configured = try ProviderModelCatalog.bundled.configuration(
                connection: connection, modelID: "gpt-4", isEnabled: true)
            let first = try #require(configured.model.invocations.first)
            let second = AgentModelInvocationSpec(
                id: "secondary", revision: first.revision, adapter: first.adapter,
                endpointID: first.endpointID, contextWindow: first.contextWindow,
                maximumOutputTokens: first.maximumOutputTokens, capabilities: first.capabilities,
                configuration: first.configuration, parameterSchema: first.parameterSchema,
                maximumInputTokens: first.maximumInputTokens)
            let model = AgentConfiguredModel(
                id: configured.model.id, revision: configured.model.revision,
                authorizationRevision: configured.model.authorizationRevision,
                reference: configured.model.reference, displayName: configured.model.displayName,
                isEnabled: configured.model.isEnabled, invocations: [first, second],
                facts: configured.model.facts)
            let preset = AgentRoutePreset(
                id: configured.preset.id, revision: configured.preset.revision,
                name: configured.preset.name, modelDescriptorID: model.id,
                invocationID: second.id, maximumOutputTokens: configured.preset.maximumOutputTokens,
                configuration: .init(schema: configured.preset.configuration.schema, value: .object([
                    "requestsUsage": .bool(false),
                    "thinking": .object(["mode": .string("enabled"), "effort": .string("high")]),
                ])))
            try await group.modelSettings.savePoolModel(
                model, preset: preset, expectedModelRevision: nil, expectedPresetRevision: nil)
            let editor = PoolModelEditorModel(
                existing: model, connection: connection, preset: preset,
                initialModelID: model.modelID, library: library, isDemo: false, onSaved: {})
            await editor.observe()
            try await eventually { editor.selectedInvocationID == second.id && editor.canSave }
            #expect(editor.invocationChoices.map(\.id) == [first.id, second.id])
            editor.requestsUsage = true
            editor.startSave()
            try await eventually { !editor.isSaving && editor.saveConfirmation > 0 }

            let savedModel = try #require(await group.modelSettings.model(id: model.id))
            let savedPreset = try #require(await group.modelSettings.preset(id: preset.id))
            #expect(savedModel.invocations == [first, second])
            #expect(savedPreset.invocationID == second.id)
            guard case .object(let values) = savedPreset.configuration.value,
                  case .bool(let requestsUsage) = values["requestsUsage"],
                  case .object(let thinking) = values["thinking"],
                  case .string(let mode) = thinking["mode"],
                  case .string(let effort) = thinking["effort"] else {
                throw MiraError(.configuration, "The selected invocation configuration was not preserved.")
            }
            #expect(requestsUsage)
            #expect(mode == "enabled")
            #expect(effort == "high")
            await editor.stop()
        }
    }

    @Test func unknownModelFactoryAllowsSavingBeforeContextMetadataArrives() throws {
        let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
        let connection = try provider.makeConnection(credential: .init(reference: "fixture", version: 1))
        let result = try ProviderModelCatalog.bundled.configuration(
            connection: connection, modelID: "provider-returned-later", isEnabled: true)
        #expect(result.model.invocations.first?.contextWindow == nil)
        #expect(result.model.isEnabled)
        try result.model.validate()
        try result.preset.validate()
    }

    @Test func userLimitFactWinsOverCatalogInvocation() throws {
        let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
        let connection = try provider.makeConnection(credential: .init(reference: "fixture", version: 1))
        let catalog = try #require(provider.model(id: "gpt-4"))
        let invocation = try catalog.invocation(connection: connection)
        let model = AgentConfiguredModel(
            id: .init(), revision: 1, authorizationRevision: 1,
            reference: .init(connectionID: connection.id, modelID: catalog.id), displayName: nil,
            isEnabled: true, invocations: [invocation], facts: [
                .init(field: AgentModelMetadataField.contextWindow, value: .number(8_192), source: .user,
                      sourceID: "mira.mac.settings", sourceRevision: "1", observedAt: .now, invocationID: invocation.id)
            ])
        let resolved = try AgentModelMetadataResolver.resolve(invocation, facts: model.facts)
        #expect(resolved.contextWindow == 8_192)
    }

    @Test func invalidLimitAndThinkingBudgetTextCannotBeSaved() async throws {
        try await withHTTPLibrary { library in
            let group = try await library.workloads()
            let connection = try await saveConnection(in: group)
            let editor = PoolModelEditorModel(
                existing: nil, connection: connection, preset: nil, initialModelID: "gpt-4",
                library: library, isDemo: false, onSaved: {})
            await editor.observe()
            editor.maxOutputTokensText = "not-a-number"
            #expect(!editor.canSave)
            editor.maxOutputTokensText = "1024"
            editor.thinkingBudgetText = "not-a-number"
            #expect(!editor.canSave)
        }
    }

    @Test func editingOneRouteControlPreservesOtherPresetParameters() async throws {
        try await withHTTPLibrary { library in
            let group = try await library.workloads()
            let connection = try await saveConnection(in: group)
            let configured = try ProviderModelCatalog.bundled.configuration(
                connection: connection, modelID: "gpt-4", isEnabled: true)
            let existingPreset = AgentRoutePreset(
                id: configured.preset.id, revision: 1, name: configured.preset.name,
                modelDescriptorID: configured.model.id, invocationID: configured.preset.invocationID,
                maximumOutputTokens: configured.preset.maximumOutputTokens,
                configuration: .init(schema: configured.preset.configuration.schema, value: .object([
                    "requestsUsage": .bool(false),
                    "thinking": .object(["mode": .string("enabled"), "effort": .string("high")])
                ])))
            try await group.modelSettings.savePoolModel(
                configured.model, preset: existingPreset,
                expectedModelRevision: nil, expectedPresetRevision: nil)
            let editor = PoolModelEditorModel(
                existing: configured.model, connection: connection, preset: existingPreset,
                initialModelID: configured.model.modelID, library: library, isDemo: false, onSaved: {})
            await editor.observe()
            editor.requestsUsage = true
            editor.startSave()
            try await eventually { !editor.isSaving }
            let saved = try #require(await group.modelSettings.preset(id: existingPreset.id))
            guard case .object(let values) = saved.configuration.value,
                  case .bool(let usage) = values["requestsUsage"],
                  case .object(let thinking) = values["thinking"],
                  case .string(let mode) = thinking["mode"],
                  case .string(let effort) = thinking["effort"] else {
                throw MiraError(.configuration, "The saved route parameters were not preserved.")
            }
            #expect(usage)
            #expect(mode == "enabled")
            #expect(effort == "high")
        }
    }

    @Test func metadataOnlyEditDoesNotRevokeAuthorizationRevision() throws {
        let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
        let connection = try provider.makeConnection(credential: .init(reference: "fixture", version: 1))
        let configured = try ProviderModelCatalog.bundled.configuration(
            connection: connection, modelID: "gpt-4", isEnabled: true)
        let changed = AgentConfiguredModel(
            id: configured.model.id, revision: configured.model.revision + 1,
            authorizationRevision: configured.model.authorizationRevision,
            reference: configured.model.reference, displayName: "Renamed", isEnabled: true,
            invocations: configured.model.invocations, facts: configured.model.facts)
        #expect(try changed.authorizationRevision(replacing: configured.model) == configured.model.authorizationRevision)
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw MiraError(.timeout, "The pool model editor condition was not reached.")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func withHTTPLibrary(_ body: (MacLibrary) async throws -> Void) async throws {
        try await withDirectory { directory in
            let credentials = CompositionCredentials()
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: directory, notifications: CompositionNotifications(), credentials: credentials,
                modules: { [MacHTTPModule(registry: $0, credentials: credentials)] })
            do {
                try await body(library)
                _ = await library.close()
            } catch {
                _ = await library.close()
                throw error
            }
        }
    }

    private func saveConnection(in group: MacLibraryWorkloads) async throws -> AgentConfiguredConnection {
        let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
        let template = try provider.makeConnection(credential: .init(reference: "fixture", version: 1))
        return try await group.credentialSettings.saveConnection(
            id: template.id, name: template.name, isEnabled: true,
            definitionID: template.definitionID, endpoints: template.endpoints,
            discovery: template.discovery, defaultInvocation: template.defaultInvocation,
            previous: nil, credentialEndpointID: template.endpoints[0].id, credential: .keep).connection
    }
}
