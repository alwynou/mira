import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("SQLite agent model settings", .timeLimit(.minutes(1)))
struct SQLiteAgentModelSettingsTests {
    @Test func firstEligiblePoolModelCreatesConversationDefaultOnce() async throws {
        try await withFixture { f in
            try await f.populate()

            let first = try #require(try await f.store.bindings(scope: .global).first {
                $0.purpose == AgentModelPurposeID.conversation
            })
            #expect(first.routeID == f.preset.id)
            #expect(first.revision == 1)

            let secondModel = f.model.copy(id: .init(), modelID: "second")
            let secondPreset = f.preset.copy(id: RouteID(secondModel.id.rawValue), modelID: secondModel.id)
            try await f.savePoolModel(secondModel, preset: secondPreset,
                                      expectedModelRevision: nil, expectedPresetRevision: nil)

            let conversation = try #require(try await f.store.bindings(scope: .global).first {
                $0.purpose == AgentModelPurposeID.conversation
            })
            #expect(conversation == first)
            #expect(try await f.store.bindings(scope: .global).filter { $0.purpose == AgentModelPurposeID.memoryExtraction }.isEmpty)
        }
    }

    @Test func enablingProviderSelectsFirstExistingEnabledModelInInsertionOrder() async throws {
        try await withFixture { f in
            let disabledConnection = AgentConfiguredConnection(
                id: f.connection.id, revision: 1, configurationRevision: 1, name: f.connection.name,
                isEnabled: false, definitionID: f.connection.definitionID, endpoints: f.connection.endpoints,
                discovery: f.connection.discovery, defaultInvocation: f.connection.defaultInvocation)
            try await f.saveConnection(disabledConnection, expectedRevision: nil)

            let disabledModel = f.model.copy(isEnabled: false)
            try await f.savePoolModel(disabledModel, preset: f.preset,
                                      expectedModelRevision: nil, expectedPresetRevision: nil)
            let enabledModel = f.model.copy(id: .init(), modelID: "enabled")
            let enabledPreset = f.preset.copy(id: RouteID(enabledModel.id.rawValue), modelID: enabledModel.id)
            try await f.savePoolModel(enabledModel, preset: enabledPreset,
                                      expectedModelRevision: nil, expectedPresetRevision: nil)
            let laterModel = f.model.copy(id: .init(), modelID: "later")
            let laterPreset = f.preset.copy(id: RouteID(laterModel.id.rawValue), modelID: laterModel.id)
            try await f.savePoolModel(laterModel, preset: laterPreset,
                                      expectedModelRevision: nil, expectedPresetRevision: nil)

            let enabledConnection = AgentConfiguredConnection(
                id: disabledConnection.id, revision: 2, configurationRevision: 2, name: disabledConnection.name,
                isEnabled: true, definitionID: disabledConnection.definitionID, endpoints: disabledConnection.endpoints,
                discovery: disabledConnection.discovery, defaultInvocation: disabledConnection.defaultInvocation)
            try await f.saveConnection(enabledConnection, expectedRevision: 1)

            let binding = try #require(try await f.store.bindings(scope: .global).first {
                $0.purpose == AgentModelPurposeID.conversation
            })
            #expect(binding.routeID == enabledPreset.id)
        }
    }

    @Test func discoverySnapshotsPersistWithCASAndNeverPartiallyReplaceValidData() async throws {
        try await withFixture { f in
            let adapter = AgentAdapterIdentity(id: "adapter.discovery", revision: 1)
            let configured = f.connection.copy(discovery: .init(adapter: adapter, endpointID: "primary"))
            try await f.saveConnection(configured, expectedRevision: nil)
            let first = AgentModelDiscoverySnapshot(
                connectionID: configured.id, configurationRevision: configured.configurationRevision,
                revision: 1, adapter: adapter, observedAt: Date(timeIntervalSince1970: 1_800_000_001),
                models: [.init(id: "alpha"), .init(id: "zeta")])
            try await f.store.saveDiscoverySnapshot(first, expectedRevision: nil, authorization: f.authorization)
            let persistedFirst = try await f.store.discoverySnapshot(connectionID: configured.id)
            #expect(persistedFirst == first)

            let second = AgentModelDiscoverySnapshot(
                connectionID: configured.id, configurationRevision: configured.configurationRevision,
                revision: 2, adapter: adapter, observedAt: Date(timeIntervalSince1970: 1_800_000_002),
                models: [.init(id: "beta")])
            try await f.store.saveDiscoverySnapshot(second, expectedRevision: 1, authorization: f.authorization)

            let malformed = AgentModelDiscoverySnapshot(
                connectionID: configured.id, configurationRevision: configured.configurationRevision,
                revision: 3, adapter: adapter, observedAt: Date(timeIntervalSince1970: 1_800_000_003),
                models: [.init(id: "zeta"), .init(id: "alpha")])
            await #expect(throws: MiraError.self) {
                try await f.store.saveDiscoverySnapshot(malformed, expectedRevision: 2, authorization: f.authorization)
            }
            let persistedSecond = try await f.store.discoverySnapshot(connectionID: configured.id)
            #expect(persistedSecond == second)

            let winnerA = AgentModelDiscoverySnapshot(
                connectionID: configured.id, configurationRevision: configured.configurationRevision,
                revision: 3, adapter: adapter, observedAt: Date(timeIntervalSince1970: 1_800_000_004),
                models: [.init(id: "winner-a")])
            let winnerB = AgentModelDiscoverySnapshot(
                connectionID: configured.id, configurationRevision: configured.configurationRevision,
                revision: 3, adapter: adapter, observedAt: Date(timeIntervalSince1970: 1_800_000_005),
                models: [.init(id: "winner-b")])
            let secondStore = try SQLiteAgentModelSettings(database: f.database, libraryID: f.authority.libraryID)
            let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                group.addTask {
                    do {
                        try await f.store.saveDiscoverySnapshot(winnerA, expectedRevision: 2, authorization: f.authorization)
                        return true
                    } catch { return false }
                }
                group.addTask {
                    do {
                        try await secondStore.saveDiscoverySnapshot(winnerB, expectedRevision: 2, authorization: f.authorization)
                        return true
                    } catch { return false }
                }
                var values: [Bool] = []
                for await value in group { values.append(value) }
                return values
            }
            #expect(results.filter { $0 }.count == 1)
            let final = try #require(try await f.store.discoverySnapshot(connectionID: configured.id))
            #expect(final.revision == 3)
            #expect(final.models.map(\.id) == ["winner-a"] || final.models.map(\.id) == ["winner-b"])
            await secondStore.close()
        }
    }

    @Test func unknownInvocationCapabilitiesCanBeSavedWithoutContextUntilSelectionValidatesLimits() async throws {
        try await withFixture { f in
            try await f.saveConnection(f.connection, expectedRevision: nil)
            let invocation = AgentModelInvocationSpec(
                id: "default", revision: 1, adapter: f.model.invocations[0].adapter,
                endpointID: "primary", contextWindow: nil, maximumOutputTokens: nil,
                capabilities: ["mira.futureCapability": .unknown],
                configuration: f.model.invocations[0].configuration,
                parameterSchema: f.model.invocations[0].parameterSchema)
            let model = AgentConfiguredModel(
                id: f.model.id, revision: 1, authorizationRevision: 1,
                reference: f.model.reference, displayName: nil, isEnabled: true,
                invocations: [invocation], facts: [])
            try await f.savePoolModel(model, preset: f.preset,
                                      expectedModelRevision: nil, expectedPresetRevision: nil)
            let saved = try await f.store.model(id: model.id)
            #expect(saved?.invocations.first?.capabilities["mira.futureCapability"] == .unknown)
            _ = try await f.store.candidate(routeID: f.preset.id)
            try await f.saveBinding(.init(scope: .global, purpose: "test.chat", routeID: f.preset.id, revision: 1), expectedRevision: nil)
            await #expect(throws: MiraError.self) {
                _ = try await f.store.select(purpose: "test.chat", explicitRouteID: nil, workspaceID: nil)
            }
        }
    }

    @Test func durableRowsSurviveDatabaseCloseAndReopen() async throws {
        try await withFixture { f in
            try await f.populate()
            let binding = AgentRouteBinding(scope: .global, purpose: "test.chat", routeID: f.preset.id, revision: 1)
            try await f.saveBinding(binding, expectedRevision: nil)
            await f.store.close()
            try f.database.close()
            let reopened = try DatabaseQueue(path: f.path.path, configuration: configuration())
            let second = try SQLiteAgentModelSettings(database: reopened, libraryID: f.authority.libraryID)
            do {
                #expect(try await second.connection(id: f.connection.id) == f.connection)
                #expect(try await second.model(id: f.model.id) == f.model)
                #expect(try await second.preset(id: f.preset.id) == f.preset)
                let bindings = try await second.bindings(scope: .global)
                #expect(bindings.contains(binding))
                #expect(bindings.contains { $0.purpose == AgentModelPurposeID.conversation })
                #expect(
                    try await second.candidate(routeID: f.preset.id) == .init(connection: f.connection, model: f.model, preset: f.preset))
            } catch {
                await second.close()
                try? reopened.close()
                throw error
            }
            await second.close()
            try reopened.close()
        }
    }

    @Test func poolCASFailureRollsBackModelInsertAndUpdate() async throws {
        try await withFixture { f in
            try await f.saveConnection(f.connection, expectedRevision: nil)
            await #expect(throws: MiraError.self) {
                try await f.savePoolModel(f.model, preset: f.preset, expectedModelRevision: nil, expectedPresetRevision: 2)
            }
            #expect(try await f.store.model(id: f.model.id) == nil)
            #expect(try await f.store.preset(id: f.preset.id) == nil)
            #expect(try await f.store.bindings(scope: .global).isEmpty)
            try await f.savePoolModel(f.model, preset: f.preset, expectedModelRevision: nil, expectedPresetRevision: nil)
            let model = f.model.copy(revision: 2, modelID: "changed")
            let preset = f.preset.copy(revision: 2)
            await #expect(throws: MiraError.self) {
                try await f.savePoolModel(model, preset: preset, expectedModelRevision: 1, expectedPresetRevision: 7)
            }
            #expect(try await f.store.model(id: f.model.id) == f.model)
            #expect(try await f.store.preset(id: f.preset.id) == f.preset)
        }
    }

    @Test func authorizationRevisionsInvalidateFrozenDispatchButLabelsAndMetadataDoNot() async throws {
        try await withFixture { f in
            try await f.populate()
            let frozen = try await f.store.candidate(routeID: f.preset.id).freeze(configuration: .object([:]))
            let renamed = f.connection.copy(revision: 2, name: "Renamed")
            try await f.saveConnection(renamed, expectedRevision: 1)
            try await f.store.candidate(routeID: f.preset.id).validateAuthorization(for: frozen)
            let changed = renamed.copy(revision: 3, configurationRevision: 2,
                                       credential: .init(reference: "credential.test", version: 1))
            await #expect(throws: MiraError.self) {
                try await f.saveConnection(renamed.copy(revision: 3, configurationRevision: 2), expectedRevision: 2)
            }
            try await f.saveConnection(changed, expectedRevision: 2)
            await #expect(throws: MiraError.self) {
                try await f.store.candidate(routeID: f.preset.id).validateAuthorization(for: frozen)
            }
            // Declarations are still editable; old probe evidence remains bound to its captured configuration.
            let updated = f.model.copy(revision: 2)
            try await f.saveModel(updated, expectedRevision: 1)
            #expect(try await f.store.candidate(routeID: f.preset.id).model == updated)
        }
    }

    @Test func replacingAnInvocationRequiresAuthorizationRevisionAndInvalidatesFrozenSelection() async throws {
        try await withFixture { f in
            try await f.populate()
            let frozen = try await f.store.candidate(routeID: f.preset.id).freeze(configuration: .object([:]))
            let original = f.model.invocations[0]
            let replacement = AgentModelInvocationSpec(
                id: "replacement", revision: original.revision, adapter: original.adapter,
                endpointID: original.endpointID, contextWindow: original.contextWindow,
                maximumOutputTokens: original.maximumOutputTokens, capabilities: original.capabilities,
                configuration: original.configuration, parameterSchema: original.parameterSchema,
                maximumInputTokens: original.maximumInputTokens)
            let revoked = AgentConfiguredModel(
                id: f.model.id, revision: 2, authorizationRevision: 1, reference: f.model.reference,
                displayName: f.model.displayName, isEnabled: f.model.isEnabled,
                invocations: [replacement], facts: f.model.facts)
            await #expect(throws: MiraError.self) {
                try await f.saveModel(revoked, expectedRevision: 1)
            }
            let accepted = AgentConfiguredModel(
                id: revoked.id, revision: revoked.revision, authorizationRevision: 2,
                reference: revoked.reference, displayName: revoked.displayName,
                isEnabled: revoked.isEnabled, invocations: revoked.invocations, facts: revoked.facts)
            try await f.saveModel(accepted, expectedRevision: 1)
            let staleCandidate = try await f.store.candidate(routeID: f.preset.id)
            await #expect(throws: MiraError.self) {
                _ = try staleCandidate.freeze(configuration: .object([:]))
            }
            // The route was frozen against the prior invocation identity and cannot be reused.
            #expect(frozen.invocationID == original.id)
        }
    }

    @Test func selectionPriorityNeverFallsThroughAnUnusableExplicitOrScopedRoute() async throws {
        try await withFixture { f in
            try await f.populate()
            let workspace = WorkspaceID()
            let purpose = "test.chat"
            let scopes: [AgentRouteScope] = [.global, .workspace(workspace)]
            for scope in scopes {
                try await f.saveBinding(
                    .init(scope: scope, purpose: purpose, routeID: f.preset.id, revision: 1), expectedRevision: nil)
                let selection = try await f.store.select(purpose: purpose, explicitRouteID: nil, workspaceID: workspace)
                #expect(selection.binding?.scope == scope)
            }
            let explicit = try await f.store.select(
                purpose: purpose, explicitRouteID: f.preset.id, workspaceID: workspace)
            #expect(explicit.binding == nil)
            await #expect(throws: MiraError.self) {
                try await f.store.select(purpose: purpose, explicitRouteID: .init(), workspaceID: workspace)
            }
            // The workspace selection must not fall back to the healthy global route.
            let disabled = f.model.copy(id: .init(), modelID: "disabled", isEnabled: false)
            let disabledPreset = f.preset.copy(id: RouteID(disabled.id.rawValue), modelID: disabled.id)
            try await f.savePoolModel(disabled, preset: disabledPreset, expectedModelRevision: nil, expectedPresetRevision: nil)
            try await f.saveBinding(
                .init(scope: .workspace(workspace), purpose: purpose, routeID: disabledPreset.id, revision: 2), expectedRevision: 1)
            #expect(try await f.store.candidate(routeID: f.preset.id).model.isEnabled)
            await #expect(throws: MiraError.self) {
                try await f.store.select(purpose: purpose, explicitRouteID: nil, workspaceID: workspace)
            }
            try await f.deleteBinding(scope: .workspace(workspace), purpose: purpose, expectedRevision: 2)
            #expect(
                try await f.store.select(purpose: purpose, explicitRouteID: nil, workspaceID: workspace).binding?.scope
                    == .global)
        }
    }

    @Test func keysetPagesFilterAndAdvanceWithoutRepeatingRows() async throws {
        try await withFixture { f in
            try await f.populate()
            let secondConnection = f.connection.copy(id: .init())
            try await f.saveConnection(secondConnection, expectedRevision: nil)
            let models = (0..<3).map { f.model.copy(id: .init(), modelID: "model.\($0)") }
            for model in models { try await f.saveModel(model, expectedRevision: nil) }
            let other = f.model.copy(id: .init(), connectionID: secondConnection.id)
            try await f.saveModel(other, expectedRevision: nil)
            let first = try await f.store.models(connectionID: f.connection.id, after: nil, limit: 2)
            let last = try #require(first.last)
            let next = try await f.store.models(connectionID: f.connection.id, after: last.id, limit: 2)
            #expect(
                (first + next).map(\.id) == ([f.model] + models).sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }.map(\.id))
            #expect(try await f.store.models(connectionID: secondConnection.id, after: nil, limit: 128) == [other])
            let routes = (0..<3).map { _ in f.preset.copy(id: .init()) }
            for preset in routes { try await f.savePreset(preset, expectedRevision: nil) }
            let page = try await f.store.presets(modelID: f.model.id, after: nil, limit: 2)
            let tail = try await f.store.presets(modelID: f.model.id, after: try #require(page.last).id, limit: 2)
            #expect(Set((page + tail).map(\.id)).count == 4)
            #expect(try await f.store.connections(after: nil, limit: 128).count == 2)
            for limit in [0, 129] {
                await #expect(throws: MiraError.self) { try await f.store.connections(after: nil, limit: limit) }
                await #expect(throws: MiraError.self) { try await f.store.models(connectionID: nil, after: nil, limit: limit) }
                await #expect(throws: MiraError.self) { try await f.store.presets(modelID: nil, after: nil, limit: limit) }
            }
        }
    }

    @Test func deletionPreservesSelectionAndRetiresConfigurationIdentity() async throws {
        try await withFixture { f in
            try await f.populate()
            let binding = AgentRouteBinding(scope: .global, purpose: "test.chat", routeID: f.preset.id, revision: 1)
            try await f.saveBinding(binding, expectedRevision: nil)
            await #expect(throws: MiraError.self) { try await f.deleteConnection(id: f.connection.id, expectedRevision: 2) }
            try await f.deletePreset(id: f.preset.id, expectedRevision: 1)
            #expect(try await f.store.bindings(scope: .global).contains(binding))
            await #expect(throws: MiraError.self) {
                try await f.store.select(purpose: "test.chat", explicitRouteID: nil, workspaceID: nil)
            }
            await #expect(throws: MiraError.self) { try await f.savePreset(f.preset, expectedRevision: nil) }
            let replacement = f.preset.copy(id: .init())
            try await f.savePreset(replacement, expectedRevision: nil)
            #expect(try await f.store.bindings(scope: .global).contains(binding))
            try await f.deleteConnection(id: f.connection.id, expectedRevision: 1)
            #expect(try await f.store.model(id: f.model.id) == nil)
            #expect(try await f.store.preset(id: replacement.id) == nil)
            #expect(try await f.store.bindings(scope: .global).contains(binding))
            await #expect(throws: MiraError.self) { try await f.saveConnection(f.connection, expectedRevision: nil) }
        }
    }

    @Test func deletedWorkspaceSelectionDoesNotFallBackToGlobal() async throws {
        try await withFixture { f in
            try await f.populate()
            let workspace = WorkspaceID()
            let scopedModel = f.model.copy(id: .init(), modelID: "scoped")
            let scopedPreset = f.preset.copy(id: .init(scopedModel.id.rawValue), modelID: scopedModel.id)
            try await f.savePoolModel(scopedModel, preset: scopedPreset, expectedModelRevision: nil, expectedPresetRevision: nil)
            try await f.saveBinding(.init(scope: .global, purpose: "test.chat", routeID: f.preset.id, revision: 1), expectedRevision: nil)
            try await f.saveBinding(.init(scope: .workspace(workspace), purpose: "test.chat", routeID: scopedPreset.id, revision: 1), expectedRevision: nil)
            try await f.deleteModel(id: scopedModel.id, expectedRevision: 1)
            await #expect(throws: MiraError.self) {
                try await f.store.select(purpose: "test.chat", explicitRouteID: nil, workspaceID: workspace)
            }
            #expect(try await f.store.select(purpose: "test.chat", explicitRouteID: nil, workspaceID: nil).candidate.model.id == f.model.id)
        }
    }

    @Test func malformedJSONAndSQLMirrorsFailOnAllReadPaths() async throws {
        try await withFixture { f in
            try await f.populate()
            let binding = AgentRouteBinding(scope: .global, purpose: "test.chat", routeID: f.preset.id, revision: 1)
            try await f.saveBinding(binding, expectedRevision: nil)
            try await f.database.write { try $0.execute(sql: "UPDATE settings_connections SET revision=2") }
            await #expect(throws: MiraError.self) { try await f.store.connection(id: f.connection.id) }
            await #expect(throws: MiraError.self) { try await f.store.connections(after: nil, limit: 1) }
            await #expect(throws: MiraError.self) { try await f.saveConnection(f.connection.copy(revision: 3), expectedRevision: 2) }
            try await f.database.write {
                try $0.execute(sql: "UPDATE settings_connections SET revision=1; UPDATE settings_models SET model_key='wrong'")
            }
            await #expect(throws: MiraError.self) { try await f.store.model(id: f.model.id) }
            await #expect(throws: MiraError.self) { try await f.store.models(connectionID: nil, after: nil, limit: 1) }
            try await f.database.write {
                try $0.execute(sql: "UPDATE settings_models SET model_key='model'; UPDATE settings_presets SET revision=2")
            }
            await #expect(throws: MiraError.self) { try await f.store.presets(modelID: nil, after: nil, limit: 1) }
            try await f.database.write {
                try $0.execute(sql: "UPDATE settings_presets SET revision=1; UPDATE settings_bindings SET purpose='changed' WHERE purpose='test.chat'")
            }
            await #expect(throws: MiraError.self) { try await f.store.bindings(scope: .global) }
            await #expect(throws: MiraError.self) {
                try await f.store.select(purpose: "changed", explicitRouteID: nil, workspaceID: nil)
            }
            try await f.database.write {
                try $0.execute(sql: "UPDATE settings_connections SET json=?", arguments: [Data("private fixture invalid JSON".utf8)])
            }
            do {
                _ = try await f.store.connection(id: f.connection.id)
                Issue.record("Malformed settings were accepted")
            } catch { #expect(!String(describing: error).contains("private fixture")) }
            await #expect(throws: MiraError.self) { try await f.store.connections(after: nil, limit: 1) }
        }
    }

    @Test func connectionAndScopeCapsAllowUpdatesAtCapacity() async throws {
        try await withFixture { f in
            try await f.populate()
            for _ in 1..<128 { try await f.saveConnection(f.connection.copy(id: .init()), expectedRevision: nil) }
            await #expect(throws: MiraError.self) {
                try await f.saveConnection(f.connection.copy(id: .init()), expectedRevision: nil)
            }
            try await f.saveConnection(f.connection.copy(revision: 2, name: "Still editable"), expectedRevision: 1)
            // The automatically-created conversation binding occupies one of the
            // 64 global binding slots.
            for index in 0..<63 {
                try await f.saveBinding(
                    .init(scope: .global, purpose: "test.\(index)", routeID: f.preset.id, revision: 1), expectedRevision: nil)
            }
            await #expect(throws: MiraError.self) {
                try await f.saveBinding(
                    .init(scope: .global, purpose: "test.extra", routeID: f.preset.id, revision: 1), expectedRevision: nil)
            }
            try await f.saveBinding(.init(scope: .global, purpose: "test.0", routeID: f.preset.id, revision: 2), expectedRevision: 1)
            #expect(try await f.store.bindings(scope: .global).count == 64)
        }
    }

    @Test func modelNamesAreUniqueWithinConnectionAndCASHasOneWinner() async throws {
        try await withFixture { f in
            try await f.populate()
            let duplicate = f.model.copy(id: .init())
            await #expect(throws: MiraError.self) { try await f.saveModel(duplicate, expectedRevision: nil) }
            await #expect(throws: MiraError.self) {
                try await f.savePoolModel(
                    duplicate, preset: f.preset.copy(id: RouteID(duplicate.id.rawValue), modelID: duplicate.id), expectedModelRevision: nil,
                    expectedPresetRevision: nil)
            }
            let second = try SQLiteAgentModelSettings(database: f.database, libraryID: f.authority.libraryID)
            let update = f.connection.copy(revision: 2, name: "Changed")
            let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                for store in [f.store, second] {
                    group.addTask {
                        do {
                            try await store.saveConnection(update, expectedRevision: 1, authorization: f.authorization)
                            return true
                        } catch { return false }
                    }
                }
                var results: [Bool] = []
                for await result in group { results.append(result) }
                return results
            }
            await second.close()
            #expect(results.filter { $0 }.count == 1)
            #expect(try await f.store.connection(id: f.connection.id) == update)
        }
    }

    @Test func readsAndWritesRequireReadySameLibraryAuthorization() async throws {
        try await withFixture { f in
            let request = AgentLibraryMaintenanceRequest(id: UUID(), namespace: "settings.test", revision: 1,
                scope: .library, requestedAt: Date(timeIntervalSince1970: 1_800_000_000))
            let pending = try await f.authority.begin(request, expected: f.authorization)
            await #expect(throws: MiraError.self) { try await f.store.connection(id: f.connection.id) }
            await #expect(throws: MiraError.self) {
                try await f.store.saveConnection(f.connection, expectedRevision: nil, authorization: f.authorization)
            }
            _ = try await f.authority.complete(pending, at: Date(timeIntervalSince1970: 1_800_000_001))
            let stale = f.authorization
            let next = try await f.authority.authorization()
            #expect(next.epoch == stale.epoch + 1)
            await #expect(throws: MiraError.self) {
                try await f.store.saveConnection(f.connection, expectedRevision: nil, authorization: stale)
            }
            await #expect(throws: MiraError.self) {
                try await f.store.saveConnection(f.connection, expectedRevision: nil,
                    authorization: .init(libraryID: UUID(), epoch: next.epoch))
            }
            #expect(throws: MiraError.self) {
                _ = try SQLiteAgentModelSettings(database: f.database, libraryID: UUID())
            }
            try await f.store.saveConnection(f.connection, expectedRevision: nil, authorization: next)
            #expect(try await f.store.connection(id: f.connection.id) == f.connection)
        }
    }

    @Test func unsupportedSchemaAndUnsafeDatabaseAreRejectedBeforeOwnedWrites() async throws {
        for pragma in ["PRAGMA synchronous=NORMAL", "PRAGMA foreign_keys=OFF"] {
            let db = try DatabaseQueue(configuration: configuration())
            defer { try? db.close() }
            let authority = try SQLiteLibraryAuthority(database: db)
            try await db.writeWithoutTransaction { try $0.execute(sql: pragma) }
            #expect(throws: MiraError.self) { try SQLiteAgentModelSettings(database: db, libraryID: authority.libraryID) }
            #expect(try await db.read { try !$0.tableExists("settings_schema") })
            await authority.close()
        }
        let partial = try DatabaseQueue(configuration: configuration())
        defer { try? partial.close() }
        let partialAuthority = try SQLiteLibraryAuthority(database: partial)
        try await partial.write { try $0.execute(sql: "CREATE TABLE settings_connections(id TEXT)") }
        #expect(throws: MiraError.self) { try SQLiteAgentModelSettings(database: partial, libraryID: partialAuthority.libraryID) }
        #expect(try await partial.read { try !$0.tableExists("settings_schema") })
        await partialAuthority.close()
        try await withFixture { f in
            await f.store.close()
            try await f.database.write { try $0.execute(sql: "DROP INDEX settings_models_page") }
            #expect(throws: MiraError.self) { try SQLiteAgentModelSettings(database: f.database, libraryID: f.authority.libraryID) }
        }
    }

    @Test func closeDrainsAcceptedSQLAndDoesNotCloseSharedDatabase() async throws {
        try await withFixture { f in
            let gate = SettingsSQLGate()
            try await f.database.write { db in
                db.add(
                    function: DatabaseFunction("settings_test_gate", argumentCount: 0) { _ in
                        gate.block()
                        return 1
                    })
                try db.execute(
                    sql: "CREATE TRIGGER settings_test_pause AFTER INSERT ON settings_connections BEGIN SELECT settings_test_gate(); END")
            }
            let write = Task { try await f.saveConnection(f.connection, expectedRevision: nil) }
            await gate.waitForEntry()
            let finished = SettingsCompletion()
            let closing = Task {
                await f.store.close()
                await finished.mark()
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while !f.store.isClosing, ContinuousClock.now < deadline { await Task.yield() }
            let isClosing = f.store.isClosing
            let returnedEarly = await finished.value
            gate.release()
            try await write.value
            await closing.value
            #expect(isClosing)
            #expect(!returnedEarly)
            await #expect(throws: MiraError.self) { try await f.store.connection(id: f.connection.id) }
            try await f.database.write { try $0.execute(sql: "CREATE TABLE sentinel(value TEXT); INSERT INTO sentinel VALUES('ok')") }
            #expect(try await f.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM settings_connections") } == 1)
            #expect(try await f.database.read { try String.fetchOne($0, sql: "SELECT value FROM sentinel") } == "ok")
        }
    }
}

private struct SettingsFixture: Sendable {
    let directory: URL
    let path: URL
    let database: DatabaseQueue
    let authority: SQLiteLibraryAuthority
    let authorization: AgentLibraryAuthorization
    let store: SQLiteAgentModelSettings
    let connection: AgentConfiguredConnection
    let model: AgentConfiguredModel
    let preset: AgentRoutePreset

    func populate() async throws {
        try await saveConnection(connection, expectedRevision: nil)
        try await savePoolModel(model, preset: preset, expectedModelRevision: nil, expectedPresetRevision: nil)
    }

    func saveConnection(_ value: AgentConfiguredConnection, expectedRevision: Int?) async throws {
        try await store.saveConnection(value, expectedRevision: expectedRevision, authorization: authorization)
    }
    func saveModel(_ value: AgentConfiguredModel, expectedRevision: Int?) async throws {
        try await store.saveModel(value, expectedRevision: expectedRevision, authorization: authorization)
    }
    func savePreset(_ value: AgentRoutePreset, expectedRevision: Int?) async throws {
        try await store.savePreset(value, expectedRevision: expectedRevision, authorization: authorization)
    }
    func savePoolModel(_ model: AgentConfiguredModel, preset: AgentRoutePreset,
                       expectedModelRevision: Int?, expectedPresetRevision: Int?) async throws {
        try await store.savePoolModel(model, preset: preset, expectedModelRevision: expectedModelRevision,
                                      expectedPresetRevision: expectedPresetRevision, authorization: authorization)
    }
    func saveBinding(_ value: AgentRouteBinding, expectedRevision: Int?) async throws {
        try await store.saveBinding(value, expectedRevision: expectedRevision, authorization: authorization)
    }
    func deleteConnection(id: ConnectionID, expectedRevision: Int) async throws {
        try await store.deleteConnection(id: id, expectedRevision: expectedRevision, authorization: authorization)
    }
    func deleteModel(id: ModelDescriptorID, expectedRevision: Int) async throws {
        try await store.deleteModel(id: id, expectedRevision: expectedRevision, authorization: authorization)
    }
    func deletePreset(id: RouteID, expectedRevision: Int) async throws {
        try await store.deletePreset(id: id, expectedRevision: expectedRevision, authorization: authorization)
    }
    func deleteBinding(scope: AgentRouteScope, purpose: String, expectedRevision: Int) async throws {
        try await store.deleteBinding(scope: scope, purpose: purpose, expectedRevision: expectedRevision, authorization: authorization)
    }
}

private func configuration(synchronous: String = "FULL", foreignKeys: Bool = true) -> Configuration {
    var config = Configuration()
    config.foreignKeysEnabled = foreignKeys
    config.prepareDatabase { db in try db.execute(sql: "PRAGMA synchronous=\(synchronous)") }
    return config
}

private func withFixture(_ body: (SettingsFixture) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("business.sqlite")
    let database = try DatabaseQueue(path: path.path, configuration: configuration())
    defer { try? database.close() }
    let authority = try SQLiteLibraryAuthority(database: database)
    let authorization = try await authority.authorization()
    let store = try SQLiteAgentModelSettings(database: database, libraryID: authority.libraryID)
    let settings = AgentConfigurationValue(schema: .init(id: "settings.test", revision: 1), value: .object([:]))
    let connection = AgentConfiguredConnection(id: .init(), revision: 1, configurationRevision: 1, name: "Test", isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: settings, credential: nil)], discovery: nil, defaultInvocation: nil)
    let model = AgentConfiguredModel(id: .init(), revision: 1, authorizationRevision: 1, reference: .init(connectionID: connection.id, modelID: "model"), displayName: nil, isEnabled: true, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: .init(id: "adapter.test", revision: 1), endpointID: "primary", contextWindow: 4096, maximumOutputTokens: nil, capabilities: [AgentModelCapabilityID.streamingText: .declared], configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: modelParameterSchema)], facts: [])
    let preset = AgentRoutePreset(id: RouteID(model.id.rawValue), revision: 1, name: "Route", modelDescriptorID: model.id, invocationID: "default", maximumOutputTokens: 100, configuration: settings)
    do {
        try await body(
            .init(directory: directory, path: path, database: database, authority: authority, authorization: authorization,
                  store: store, connection: connection, model: model, preset: preset))
    } catch {
        await store.close()
        await authority.close()
        throw error
    }
    await store.close()
    await authority.close()
}

extension AgentConfiguredConnection {
    fileprivate func copy(
        id: ConnectionID? = nil, revision: Int? = nil, configurationRevision: Int? = nil,
        name: String? = nil, credential: AgentCredentialReference? = nil,
        discovery: AgentConnectionDiscovery? = nil
    ) -> Self {
        .init(id: id ?? self.id, revision: revision ?? self.revision,
              configurationRevision: configurationRevision ?? self.configurationRevision,
              name: name ?? self.name, isEnabled: isEnabled, definitionID: definitionID,
              endpoints: endpoints.map { .init(id: $0.id, configuration: $0.configuration, credential: credential ?? $0.credential) },
              discovery: discovery ?? self.discovery, defaultInvocation: defaultInvocation)
    }
}

extension AgentConfiguredModel {
    fileprivate func copy(
        id: ModelDescriptorID? = nil, revision: Int? = nil, connectionID: ConnectionID? = nil,
        modelID: String? = nil, isEnabled: Bool? = nil
    ) -> Self {
        .init(id: id ?? self.id, revision: revision ?? self.revision, authorizationRevision: 1, reference: .init(connectionID: connectionID ?? self.connectionID, modelID: modelID ?? self.modelID), displayName: nil, isEnabled: isEnabled ?? self.isEnabled, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: invocations[0].adapter, endpointID: "primary", contextWindow: invocations[0].contextWindow, maximumOutputTokens: nil, capabilities: invocations[0].capabilities, configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: modelParameterSchema)], facts: [])
    }
}

extension AgentRoutePreset {
    fileprivate func copy(id: RouteID? = nil, revision: Int? = nil, modelID: ModelDescriptorID? = nil) -> Self {
        .init(id: id ?? self.id, revision: revision ?? self.revision, name: name, modelDescriptorID: modelID ?? modelDescriptorID, invocationID: "default", maximumOutputTokens: maximumOutputTokens, configuration: configuration)
    }
}

private final class SettingsSQLGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func block() {
        condition.lock()
        entered = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
        while !released { condition.wait() }
        condition.unlock()
    }
    func waitForEntry() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if entered {
                condition.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                condition.unlock()
            }
        }
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor SettingsCompletion {
    private(set) var value = false
    func mark() { value = true }
}
