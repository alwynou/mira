#if DEBUG
import Foundation
import MiraCore
import MiraProviders
import Testing

@Suite("provider library model contracts")
@MainActor
struct ProviderLibraryModelTests {
    @Test func savesCatalogModelAndPublishesUpdatedPool() async throws {
        try await withDirectory { directory in
            let launch = MacLibraryLaunchConfiguration(directory: directory, isDemo: false, stress: false)
            let container = AppContainer(launch: launch) { launch in
                try await MacLibrary.open(
                    directory: launch.directory, notifications: CompositionNotifications(),
                    credentials: CompositionCredentials(), modules: { _ in [] })
            }
            await container.start()
            do {
                let group = try #require(container.workgroup)
                let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
                let template = try provider.makeConnection(name: "Fixture", credential: nil)
                let connection = try await group.credentialSettings.saveConnection(
                    id: template.id, name: template.name, isEnabled: true,
                    definitionID: template.definitionID, endpoints: template.endpoints,
                    discovery: template.discovery, defaultInvocation: template.defaultInvocation,
                    previous: nil, credentialEndpointID: template.endpoints[0].id, credential: .keep).connection
                let model = ProviderLibraryModel(container: container)
                await model.refresh()
                model.selectedConnectionID = connection.id
                let catalog = try #require(model.newCatalogModels.first(where: { $0.id == "gpt-4" }))
                let before = model.revision
                await model.addCatalogModel(catalog, connection: connection)
                #expect(model.revision > before)
                #expect(model.models.contains { $0.modelID == catalog.id })
                #expect(model.presets.contains { $0.modelDescriptorID == model.models.first { $0.modelID == catalog.id }?.id })
                #expect(model.newCatalogModels.allSatisfy { $0.id != catalog.id })
                #expect(await container.close().isSettled)
            } catch {
                _ = await container.close()
                throw error
            }
        }
    }

    @Test func probeObservationIsEphemeralAndMaintenanceClearsGenerationCaches() async throws {
        try await withDirectory { directory in
            let container = makeContainer(
                directory: directory,
                modules: { [MacDemoModule(registry: $0), LibraryProbeModule(registry: $0)] },
                seedDemo: true)
            await container.start()
            let model = ProviderLibraryModel(container: container)
            let observation = Task { await model.observe(includeRoutingScopes: false) }
            do {
                try await eventually {
                    container.status.phase == .ready
                        && model.models.contains(where: { $0.modelID == MacDemoModule.modelID })
                        && model.probeDescriptors.contains(where: { $0.id == "tests.probe.text" })
                }
                let configured = try #require(model.models.first { $0.modelID == MacDemoModule.modelID })
                let persistedBefore = try await container.workgroup?.modelSettings.model(id: configured.id)
                model.probe(configured, probeID: "tests.probe.text")
                try await eventually { !model.isProbing && model.probeObservation != nil }
                #expect(model.probeObservation?.outcome == .verified)
                #expect(try await container.workgroup?.modelSettings.model(id: configured.id) == persistedBefore)
                model.selectedConnectionID = nil
                #expect(model.probeObservation == nil)
                model.selectedConnectionID = MacDemoModule.connectionID
                try await eventually { model.selectedConnectionID == MacDemoModule.connectionID }
                let before = model.revision
                let request = AgentLibraryMaintenanceRequest(
                    id: UUID(), namespace: "knowledge.collect", revision: 1, scope: .library, requestedAt: Date())
                _ = try await container.library?.maintain(request)
                try await eventually { model.revision > before && model.probeObservation == nil && model.discoveredModels.isEmpty }
                #expect(model.error == nil)
                #expect(await container.close().isSettled)
            } catch {
                observation.cancel()
                await observation.value
                _ = await container.close()
                throw error
            }
            observation.cancel()
            await observation.value
        }
    }

    @Test func unknownDiscoveredIDsUseTheConfigurationBuilder() throws {
        let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
        let connection = try provider.makeConnection(credential: .init(reference: "fixture", version: 1))
        let configured = try ProviderModelCatalog.bundled.configuration(
            connection: connection, modelID: "discovered-without-catalog-facts", displayName: "Discovered", isEnabled: true)
        #expect(configured.model.modelID == "discovered-without-catalog-facts")
        #expect(configured.model.displayName == "Discovered")
        #expect(configured.model.isEnabled)
        #expect(configured.model.invocations.first?.contextWindow == nil)
    }

    @Test func disabledModelRequiresExplicitReenable() throws {
        let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
        let connection = try provider.makeConnection(credential: .init(reference: "fixture", version: 1))
        let configured = try ProviderModelCatalog.bundled.configuration(
            connection: connection, modelID: "model", isEnabled: false)
        #expect(configured.model.isEnabled == false)
        #expect(configured.model.authorizationRevision == 1)
    }

    @Test func stopRequestsDrainsRefreshAndClearsActivity() async throws {
        try await withDirectory { directory in
            let launch = MacLibraryLaunchConfiguration(directory: directory, isDemo: false, stress: false)
            let container = AppContainer(launch: launch) { launch in
                try await MacLibrary.open(
                    directory: launch.directory, notifications: CompositionNotifications(),
                    credentials: CompositionCredentials(), modules: { _ in [] })
            }
            await container.start()
            let model = ProviderLibraryModel(container: container)
            let observer = Task { await model.observe(includeRoutingScopes: true) }
            try await eventually { container.status.phase == .ready && model.revision > 0 }
            let pending = Task { await model.refresh() }
            await model.stopRequests()
            await pending.value
            #expect(!model.isWorking)
            #expect(!model.isDiscovering)
            #expect(!model.isProbing)
            observer.cancel()
            await observer.value
            #expect(await container.close().isSettled)
        }
    }

    @Test func businessRefreshPreservesPreviouslyLoadedConversationPages() async throws {
        try await withDirectory { directory in
            let container = makeContainer(
                directory: directory, modules: { [MacDemoModule(registry: $0)] }, seedDemo: true)
            await container.start()
            let model = ProviderLibraryModel(container: container)
            let observer = Task { await model.observe(includeRoutingScopes: true) }
            do {
                try await eventually { container.status.phase == .ready && container.library != nil }
                let group = try #require(container.workgroup)
                for index in 0..<128 {
                    let sessionID = ConversationID()
                    try committed(await group.application.createSession(
                        id: sessionID, commandID: UUID(), title: "Synthetic \(index)", workspaceID: nil))
                    try await group.application.releaseSession(id: sessionID)
                }
                try await eventually { model.conversations.count == 128 && model.hasMoreConversations }
                let lateSessionID = ConversationID()
                try committed(await group.application.createSession(
                    id: lateSessionID, commandID: UUID(), title: "Synthetic late", workspaceID: nil))
                try await group.application.releaseSession(id: lateSessionID)
                try await eventually { model.conversations.contains { $0.id == lateSessionID } }
                await model.loadMoreConversations()
                try await eventually { model.conversations.count == 129 && !model.hasMoreConversations }
                let loadedIDs = model.conversations.map(\.id)
                #expect(Set(loadedIDs).count == 129)
                let connection = try #require(await group.modelSettings.connection(id: MacDemoModule.connectionID))
                _ = try await group.credentialSettings.saveConnection(
                    id: connection.id, name: "Mira Local Demo Refreshed", isEnabled: connection.isEnabled,
                    definitionID: connection.definitionID, endpoints: connection.endpoints,
                    discovery: connection.discovery, defaultInvocation: connection.defaultInvocation,
                    previous: connection, credentialEndpointID: connection.endpoints[0].id, credential: .keep)
                try await eventually {
                    model.connections.first(where: { $0.id == connection.id })?.name == "Mira Local Demo Refreshed"
                        && model.conversations.count == 129
                }
                #expect(model.conversations.map(\.id) == loadedIDs)
                #expect(Set(model.conversations.map(\.id)).count == 129)
                #expect(await container.close().isSettled)
            } catch {
                observer.cancel()
                await observer.value
                _ = await container.close()
                throw error
            }
            observer.cancel()
            await observer.value
        }
    }

    private func makeContainer(
        directory: URL, modules: @escaping MacLibrary.ModuleFactory, seedDemo: Bool = false
    ) -> AppContainer {
        let launch = MacLibraryLaunchConfiguration(directory: directory, isDemo: false, stress: false)
        return AppContainer(launch: launch) { launch in
            let library = try await MacLibrary.open(
                directory: launch.directory, notifications: CompositionNotifications(),
                credentials: CompositionCredentials(), modules: modules)
            guard seedDemo else { return library }
            do {
                try await MacDemoModule.seed(in: library.workloads())
                return library
            } catch {
                _ = await library.close()
                throw error
            }
        }
    }
}

private struct LibraryProbeModule: RuntimeModule {
    let id = "tests.probe.module"
    let dependencies: Set<String> = []
    let registry: RuntimeRegistry<AgentCapability>

    func activate(in scope: RuntimeScope) async throws {
        try await registry.register(
            id: "tests.probe.provider", value: .modelProbe(LibraryProbeProvider()), scope: scope)
    }
}

private struct LibraryProbeProvider: AgentModelProbeProvider, Sendable {
    func probes() throws -> [AgentModelProbeDefinition] {
        [try AgentModelProbeDefinition(
            identity: .init(id: "tests.probe.text", revision: 1, title: "Synthetic text",
                capabilityIDs: [AgentModelCapabilityID.streamingText]),
            preparationCapabilityIDs: [AgentModelCapabilityID.streamingText],
            prepareCandidate: { $0 },
            makeInput: { stepID, executionID, _ in
                .init(stepID: stepID, executionID: executionID,
                    instructions: "Reply with a short acknowledgement.",
                    messages: [.init(role: .user, blocks: [.init(id: "probe-user", content: .text("Reply with exactly OK."))])], tools: [])
            },
            evaluate: { output in output.text.isEmpty ? .unsupported : .verified })]
    }
}
#endif
