import Foundation
import MiraCore
import Testing

@Suite("Purpose routing presentation", .timeLimit(.minutes(1)))
@MainActor
struct PurposeRoutingModelTests {
    @Test func conversationPolicyPersistsWithoutReplacingItsFixedDefault() async throws {
        try await withRoutingLibrary { library, fixture in
            let suite = "mira-purpose-policy-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = ConversationModelPreferences(defaults: defaults)
            let group = try await library.workloads()
            try await group.modelSettings.saveBinding(.init(scope: .global,
                purpose: AgentModelPurposeID.conversation, routeID: fixture.textRoute, revision: 1), expectedRevision: nil)
            let model = PurposeRoutingModel(scope: .global, purpose: AgentModelPurposeID.conversation,
                library: library, isDemo: false, preferences: preferences)
            await model.refresh(options: fixture.options)
            model.followsLastSelection = true
            #expect(model.canSave)
            model.save(onSaved: {})
            await model.waitForSave()
            #expect(model.error == nil)
            #expect(preferences.followsLastSelection(libraryID: library.id, scope: .global) == true)
            #expect(try await group.modelSettings.bindings(scope: .global).first?.routeID == fixture.textRoute)
            let restored = PurposeRoutingModel(scope: .global, purpose: AgentModelPurposeID.conversation,
                library: library, isDemo: false, preferences: ConversationModelPreferences(defaults: defaults))
            await restored.refresh(options: fixture.options)
            #expect(restored.followsLastSelection)
            restored.followsLastSelection = false
            restored.routeID = fixture.jsonRoute
            restored.save(onSaved: {})
            await restored.waitForSave()
            #expect(restored.error == nil)
            #expect(try await group.modelSettings.bindings(scope: .global).first?.routeID == fixture.jsonRoute)
            #expect(ConversationModelPreferences(defaults: defaults).followsLastSelection(libraryID: library.id, scope: .global) == false)
        }
    }

    @Test func scopeAndPurposeFilterBindingsAndCapabilities() async throws {
        try await withRoutingLibrary { library, fixture in
            let group = try await library.workloads()
            try await group.modelSettings.saveBinding(
                .init(
                    scope: .global, purpose: AgentModelPurposeID.conversation,
                    routeID: fixture.textRoute, revision: 1), expectedRevision: nil)
            try await group.modelSettings.saveBinding(
                .init(
                    scope: .workspace(fixture.workspaceID), purpose: AgentModelPurposeID.memoryExtraction,
                    routeID: fixture.jsonRoute, revision: 1), expectedRevision: nil)

            let conversation = PurposeRoutingModel(
                scope: .global, purpose: AgentModelPurposeID.conversation, library: library, isDemo: false)
            await conversation.refresh(options: fixture.options)
            #expect(conversation.options.map(\.id) == [fixture.textRoute, fixture.jsonRoute])
            #expect(conversation.routeID == fixture.textRoute)

            let extraction = PurposeRoutingModel(
                scope: .workspace(fixture.workspaceID), purpose: AgentModelPurposeID.memoryExtraction,
                library: library, isDemo: false)
            await extraction.refresh(options: fixture.options)
            #expect(extraction.options.map(\.id) == [fixture.jsonRoute])
            #expect(extraction.routeID == fixture.jsonRoute)
        }
    }

    @Test func unusableBindingDoesNotFallbackToAnotherRoute() async throws {
        try await withRoutingLibrary { library, fixture in
            let group = try await library.workloads()
            try await group.modelSettings.saveBinding(
                .init(
                    scope: .global, purpose: AgentModelPurposeID.memoryExtraction,
                    routeID: fixture.textRoute, revision: 1), expectedRevision: nil)

            let model = PurposeRoutingModel(
                scope: .global, purpose: AgentModelPurposeID.memoryExtraction, library: library, isDemo: false)
            await model.refresh(options: fixture.options)

            #expect(model.options.map(\.id) == [fixture.jsonRoute])
            #expect(model.routeID == fixture.textRoute)
            #expect(model.canSave == false)
        }
    }

    @Test func saveConflictKeepsTheDraftSelection() async throws {
        try await withRoutingLibrary { library, fixture in
            let group = try await library.workloads()
            try await group.modelSettings.saveBinding(
                .init(
                    scope: .global, purpose: AgentModelPurposeID.conversation,
                    routeID: fixture.textRoute, revision: 1), expectedRevision: nil)
            let model = PurposeRoutingModel(
                scope: .global, purpose: AgentModelPurposeID.conversation, library: library, isDemo: false)
            await model.refresh(options: fixture.options)
            model.routeID = fixture.jsonRoute
            #expect(model.canSave)

            try await group.modelSettings.saveBinding(
                .init(
                    scope: .global, purpose: AgentModelPurposeID.conversation,
                    routeID: fixture.textRoute, revision: 2), expectedRevision: 1)
            model.save(onSaved: {})
            await model.waitForSave()

            #expect(model.error?.code == .conflict)
            #expect(model.routeID == fixture.jsonRoute)
            #expect(model.hasChanges)
        }
    }

    @Test func stopDrainsAcceptedSaveAndClearsReadState() async throws {
        try await withRoutingLibrary { library, fixture in
            let group = try await library.workloads()
            try await group.modelSettings.saveBinding(
                .init(
                    scope: .global, purpose: AgentModelPurposeID.conversation,
                    routeID: fixture.textRoute, revision: 1), expectedRevision: nil)
            let model = PurposeRoutingModel(
                scope: .global, purpose: AgentModelPurposeID.conversation, library: library, isDemo: false)
            await model.refresh(options: fixture.options)
            model.routeID = fixture.jsonRoute
            model.save(onSaved: {})
            try await eventually { model.isSaving }
            await model.stop()

            #expect(!model.isLoading)
            #expect(!model.isSaving)
            let binding = try #require(
                try await group.modelSettings.bindings(scope: .global)
                    .first(where: { $0.purpose == AgentModelPurposeID.conversation }))
            #expect(binding.routeID == fixture.jsonRoute)
        }
    }
}

private struct RoutingFixture {
    let workspaceID: WorkspaceID
    let textRoute: RouteID
    let jsonRoute: RouteID
    let options: [PurposeRoutingOption]
}

private func withRoutingLibrary(
    _ body: @escaping @MainActor (MacLibrary, RoutingFixture) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mira-purpose-routing-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try await MacLibrary.open(
        directory: directory, notifications: CompositionNotifications(),
        credentials: CompositionCredentials(), modules: { [RoutingModule(registry: $0)] })
    do {
        let group = try await library.workloads()
        let fixture = try await seedRoutingData(in: group)
        try await body(library, fixture)
        #expect(await library.close().isSettled)
    } catch {
        _ = await library.close()
        throw error
    }
}

private func seedRoutingData(in group: MacLibraryWorkloads) async throws -> RoutingFixture {
    let schema = AgentConfigurationValue(
        schema: RoutingModule.connectionSchema, value: .object([:]))
    let routeConfiguration = AgentConfigurationValue(
        schema: RoutingModule.routeSchema, value: .object([:]))
    let connection = try await group.credentialSettings.saveConnection(
        id: .init(), name: "Routing fixture", isEnabled: true,
        definitionID: nil,
        endpoints: [.init(id: "primary", configuration: schema, credential: nil)],
        discovery: nil, defaultInvocation: nil, previous: nil,
        credentialEndpointID: "primary", credential: .keep
    ).connection

    func model(_ id: String, capabilities: [String: CapabilityState]) -> AgentConfiguredModel {
        .init(id: .init(), revision: 1, authorizationRevision: 1,
              reference: .init(connectionID: connection.id, modelID: id), displayName: nil,
              isEnabled: true, invocations: [
                .init(id: "default", revision: 1, adapter: RoutingModule.identity,
                      endpointID: "primary", contextWindow: 4096, maximumOutputTokens: 1024,
                      capabilities: capabilities, configuration: routeConfiguration,
                      parameterSchema: .object([
                        "type": .string("object"), "properties": .object([:]),
                        "additionalProperties": .bool(false)
                      ]))
              ], facts: [])
    }
    let textModel = model("text", capabilities: [AgentModelCapabilityID.streamingText: .declared])
    let jsonModel = model("json", capabilities: [
        AgentModelCapabilityID.streamingText: .declared, AgentModelCapabilityID.jsonOutput: .declared
    ])
    let textPreset = AgentRoutePreset(
        id: .init(textModel.id.rawValue), revision: 1, name: "Text route",
        modelDescriptorID: textModel.id, invocationID: "default", maximumOutputTokens: 128, configuration: routeConfiguration)
    let jsonPreset = AgentRoutePreset(
        id: .init(jsonModel.id.rawValue), revision: 1, name: "JSON route",
        modelDescriptorID: jsonModel.id, invocationID: "default", maximumOutputTokens: 128, configuration: routeConfiguration)
    try await group.modelSettings.savePoolModel(
        textModel, preset: textPreset, expectedModelRevision: nil, expectedPresetRevision: nil)
    try await group.modelSettings.savePoolModel(
        jsonModel, preset: jsonPreset, expectedModelRevision: nil, expectedPresetRevision: nil)

    // These card tests establish explicit binding baselines; pool auto-initialization has separate data coverage.
    if let initial = try await group.modelSettings.bindings(scope: .global).first(where: { $0.purpose == AgentModelPurposeID.conversation }) {
        try await group.modelSettings.deleteBinding(scope: .global, purpose: initial.purpose, expectedRevision: initial.revision)
    }
    let workspace = Workspace(id: .init(), name: "Routing workspace")
    try await group.workspaces.save(workspace, expectedRevision: nil)
    return .init(
        workspaceID: workspace.id,
        textRoute: textPreset.id,
        jsonRoute: jsonPreset.id,
        options: [
            .init(id: textPreset.id, title: textPreset.name),
            .init(id: jsonPreset.id, title: jsonPreset.name),
        ])
}

private struct RoutingModule: RuntimeModule, Sendable {
    static let identity = AgentAdapterIdentity(id: "tests.routing.adapter", revision: 1)
    static let connectionSchema = AgentConfigurationIdentity(id: "tests.routing.connection", revision: 1)
    static let routeSchema = AgentConfigurationIdentity(id: "tests.routing.route", revision: 1)

    let id = "tests.routing.module"
    let dependencies: Set<String> = []
    let registry: RuntimeRegistry<AgentCapability>

    func activate(in scope: RuntimeScope) async throws {
        try await registry.register(
            id: "tests.routing.model", value: .model(RoutingAdapter()), scope: scope)
        try await registry.register(
            id: "tests.routing.configuration", value: .modelConfiguration(RoutingConfiguration()), scope: scope)
    }
}

private struct RoutingConfiguration: AgentModelConfigurationProvider {
    let identity = RoutingModule.identity

    func descriptor(for invocation: AgentModelInvocationSpec) throws -> AgentModelConfigurationDescriptor {
        .init(
            adapter: identity, title: "Routing fixture", credential: .none,
            connection: schema(RoutingModule.connectionSchema),
            route: schema(RoutingModule.routeSchema))
    }

    func configuration(for candidate: AgentModelRouteCandidate) throws -> JSONValue {
        let descriptor = try descriptor(for: candidate.invocation)
        try descriptor.connection.validate(candidate.endpoint.configuration)
        try descriptor.route.validate(candidate.preset.configuration)
        guard try candidate.endpoint.credential == nil else {
            throw MiraError(.credentialMissing, "The routing fixture does not use credentials.")
        }
        return .object([:])
    }

    private func schema(_ identity: AgentConfigurationIdentity) -> AgentConfigurationSchema {
        .init(
            identity: identity, title: "Routing fixture settings",
            schema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ]), defaults: .object([:]))
    }
}

private struct RoutingAdapter: AgentModelAdapter {
    let identity = RoutingModule.identity

    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        try input.validate(for: route)
        return .init(adapter: identity, input: input, wirePayload: .object([:]), estimatedInputTokens: 1)
    }

    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        let (events, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
        continuation.yield(.blockStarted(.init(id: "text", content: .text("OK"))))
        continuation.yield(.blockFinished(id: "text"))
        continuation.yield(.finished(.stop))
        continuation.finish()
        return .init(events: events) {}
    }

    func replay(
        _ messages: [AgentModelMessage], from source: AgentModelRoute,
        to target: AgentModelRoute, boundary: AgentReplayBoundary
    ) throws -> AgentReplayDecision { .include(messages) }
}

@MainActor
private func eventually(
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw MiraError(.timeout, "The purpose routing condition was not reached.")
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}
