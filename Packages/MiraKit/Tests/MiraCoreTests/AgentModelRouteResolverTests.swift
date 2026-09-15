import Foundation
import Testing

@testable import MiraCore

@Suite("Agent model route resolver", .timeLimit(.minutes(1)))
struct AgentModelRouteResolverTests {
    @Test func resolveUsesExactSelectionInputsAndPreservesBinding() async throws {
        try await withResolverFixture { fixture in
            let binding = AgentRouteBinding(
                scope: .global,
                purpose: "mira.testPurpose", routeID: fixture.candidate.preset.id, revision: 7)
            let selection = AgentModelRouteSelection(candidate: fixture.candidate, binding: binding)
            let settings = ResolverSettingsStore(selection: selection, candidate: fixture.candidate)
            let resolver = AgentModelRouteResolver(settings: settings)
            let workspaceID = WorkspaceID()

            let resolved = try await resolver.resolve(
                purpose: "mira.testPurpose",
                explicitRouteID: nil, sessionSelection: .inherit,
                workspaceID: workspaceID, catalog: fixture.catalog,
                requiredCapabilities: [AgentModelCapabilityID.thinking])

            #expect(resolved.route == fixture.route)
            #expect(resolved.binding == binding)
            #expect(
                await settings.selectionArguments()
                    == .init(
                        purpose: "mira.testPurpose", explicitRouteID: nil,
                        workspaceID: workspaceID))
            #expect(await settings.selectCallCount() == 1)
        }
    }

    @Test func authorizationSurvivesMetadataEditsButRejectsCredentialRevocation() async throws {
        try await withResolverFixture { fixture in
            let settings = ResolverSettingsStore(
                selection: .init(candidate: fixture.candidate, binding: nil),
                candidate: fixture.candidate)
            let resolver = AgentModelRouteResolver(settings: settings)

            try await resolver.validateCurrent(fixture.route, catalog: fixture.catalog)
            #expect(await settings.selectCallCount() == 0)

            let changedConnection = AgentConfiguredConnection(id: fixture.candidate.connection.id, revision: fixture.candidate.connection.revision + 1, configurationRevision: fixture.candidate.connection.configurationRevision, name: "Renamed", isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: fixture.candidate.connection.endpoints[0].configuration, credential: fixture.candidate.connection.endpoints[0].credential)], discovery: nil, defaultInvocation: nil)
            let changedModelForConnection = AgentConfiguredModel(id: fixture.candidate.model.id, revision: fixture.candidate.model.revision, authorizationRevision: 1, reference: .init(connectionID: changedConnection.id, modelID: fixture.candidate.model.modelID), displayName: nil, isEnabled: true, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: fixture.candidate.model.invocations[0].adapter, endpointID: "primary", contextWindow: fixture.candidate.model.invocations[0].contextWindow, maximumOutputTokens: nil, capabilities: fixture.candidate.model.invocations[0].capabilities, configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]))], facts: [])
            await settings.setCandidate(
                .init(
                    connection: changedConnection,
                    model: changedModelForConnection, preset: fixture.candidate.preset))
            try await resolver.validateCurrent(fixture.route, catalog: fixture.catalog)

            let changedCredential = AgentConfiguredConnection(id: fixture.candidate.connection.id, revision: fixture.candidate.connection.revision + 1, configurationRevision: fixture.candidate.connection.configurationRevision + 1, name: fixture.candidate.connection.name, isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: fixture.candidate.connection.endpoints[0].configuration, credential: .init(reference: "changed.key", version: 2))], discovery: nil, defaultInvocation: nil)
            let changedCredentialModel = AgentConfiguredModel(id: fixture.candidate.model.id, revision: fixture.candidate.model.revision, authorizationRevision: 1, reference: .init(connectionID: changedCredential.id, modelID: fixture.candidate.model.modelID), displayName: nil, isEnabled: true, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: fixture.candidate.model.invocations[0].adapter, endpointID: "primary", contextWindow: fixture.candidate.model.invocations[0].contextWindow, maximumOutputTokens: nil, capabilities: fixture.candidate.model.invocations[0].capabilities, configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]))], facts: [])
            await settings.setCandidate(
                .init(
                    connection: changedCredential,
                    model: changedCredentialModel, preset: fixture.candidate.preset))
            await #expect(throws: MiraError.self) {
                try await resolver.validateCurrent(fixture.route, catalog: fixture.catalog)
            }

            let changedCapabilities = AgentConfiguredModel(id: fixture.candidate.model.id, revision: fixture.candidate.model.revision + 1, authorizationRevision: 1, reference: .init(connectionID: fixture.candidate.connection.id, modelID: fixture.candidate.model.modelID), displayName: nil, isEnabled: true, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: fixture.candidate.model.invocations[0].adapter, endpointID: "primary", contextWindow: fixture.candidate.model.invocations[0].contextWindow, maximumOutputTokens: nil, capabilities: [AgentModelCapabilityID.streamingText: .verified], configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]))], facts: [])
            await settings.setCandidate(
                .init(
                    connection: fixture.candidate.connection,
                    model: changedCapabilities, preset: fixture.candidate.preset))
            try await resolver.validateCurrent(fixture.route, catalog: fixture.catalog,
                                               requiredCapabilities: [AgentModelCapabilityID.thinking])

            await settings.removeCandidate()
            await #expect(throws: MiraError.self) {
                try await resolver.validateCurrent(fixture.route, catalog: fixture.catalog)
            }
            #expect(await settings.selectCallCount() == 0)
        }
    }

    @Test func resolveEnforcesRequiredCapabilitiesWithoutFallback() async throws {
        try await withResolverFixture { fixture in
            let settings = ResolverSettingsStore(
                selection: .init(candidate: fixture.candidate, binding: nil),
                candidate: fixture.candidate)
            let resolver = AgentModelRouteResolver(settings: settings)

            _ = try await resolver.resolve(
                purpose: "mira.testPurpose", explicitRouteID: nil,
                sessionSelection: .inherit, workspaceID: nil, catalog: fixture.catalog,
                requiredCapabilities: [AgentModelCapabilityID.thinking])
            await #expect(throws: MiraError.self) {
                _ = try await resolver.resolve(
                    purpose: "mira.testPurpose", explicitRouteID: nil,
                    sessionSelection: .inherit, workspaceID: nil, catalog: fixture.catalog,
                    requiredCapabilities: ["mira.unsupportedCapability"])
            }
            #expect(await settings.selectCallCount() == 2)
        }
    }

    @Test func cancelledCallerDoesNotAskSettingsToSelect() async throws {
        try await withResolverFixture { fixture in
            let settings = ResolverSettingsStore(
                selection: .init(candidate: fixture.candidate, binding: nil),
                candidate: fixture.candidate)
            let resolver = AgentModelRouteResolver(settings: settings)
            let gate = ResolverStartGate()
            let task = Task {
                await gate.wait()
                return try await resolver.resolve(
                    purpose: "mira.testPurpose", explicitRouteID: nil,
                    sessionSelection: .inherit, workspaceID: nil, catalog: fixture.catalog)
            }
            task.cancel()
            await gate.open()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(await settings.selectCallCount() == 0)
        }
    }
}

private struct ResolverFixture: Sendable {
    let scope: RuntimeScope
    let catalog: AgentRuntimeCatalog
    let candidate: AgentModelRouteCandidate
    let route: AgentModelRoute
    let sessionID: ConversationID

    static func make() async throws -> ResolverFixture {
        let scope = RuntimeScope(kind: .application)
        let registry = RuntimeRegistry<AgentCapability>()
        let identity = AgentAdapterIdentity(id: "resolver.adapter", revision: 1)
        let model = ResolverModelAdapter(identity: identity)
        let provider = ResolverConfigurationProvider(identity: identity)
        let candidate = makeCandidate(identity: identity)
        try await registry.register(id: "model", value: .model(model), scope: scope)
        try await registry.register(id: "configuration", value: .modelConfiguration(provider), scope: scope)
        do {
            let snapshot = try await registry.freeze()
            do {
                let catalog = try AgentRuntimeCatalog(snapshot: snapshot)
                let route = try catalog.configuredRoute(candidate)
                return .init(
                    scope: scope, catalog: catalog, candidate: candidate,
                    route: route, sessionID: ConversationID())
            } catch {
                await snapshot.release()
                await scope.dispose()
                throw error
            }
        } catch {
            await scope.dispose()
            throw error
        }
    }

    func close() async {
        await catalog.release()
        await scope.dispose()
    }

    private static func makeCandidate(identity: AgentAdapterIdentity) -> AgentModelRouteCandidate {
        let connection = AgentConfiguredConnection(id: .init(), revision: 3, configurationRevision: 2, name: "Resolver connection", isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: .init(
                schema: .init(id: "resolver.connection", revision: 1),
                value: .object(["endpoint": .string("https://resolver.example")])), credential: .init(reference: "resolver.key", version: 1))], discovery: nil, defaultInvocation: nil)
        let model = AgentConfiguredModel(id: .init(), revision: 2, authorizationRevision: 1, reference: .init(connectionID: connection.id, modelID: "resolver.model"), displayName: nil, isEnabled: true, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: identity, endpointID: "primary", contextWindow: 16_000, maximumOutputTokens: nil, capabilities: [
                AgentModelCapabilityID.streamingText: .verified,
                AgentModelCapabilityID.thinking: .verified,
            ], configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]))], facts: [])
        let preset = AgentRoutePreset(id: .init(), revision: 4, name: "Resolver route", modelDescriptorID: model.id, invocationID: "default", maximumOutputTokens: 1_024, configuration: .init(
                schema: .init(id: "resolver.route", revision: 1),
                value: .object(["temperature": .number(0.1)])))
        return .init(connection: connection, model: model, preset: preset)
    }
}

private actor ResolverSettingsStore: AgentModelSettingsStore {
    private var selection: AgentModelRouteSelection
    private var currentCandidate: AgentModelRouteCandidate?
    private var calls = 0
    private var lastArguments: ResolverSelectionArguments?

    init(selection: AgentModelRouteSelection, candidate: AgentModelRouteCandidate?) {
        self.selection = selection
        self.currentCandidate = candidate
    }

    func setCandidate(_ candidate: AgentModelRouteCandidate) { currentCandidate = candidate }
    func removeCandidate() { currentCandidate = nil }
    func selectCallCount() -> Int { calls }
    func selectionArguments() -> ResolverSelectionArguments? { lastArguments }

    func select(
        purpose: String, explicitRouteID: RouteID?,
        workspaceID: WorkspaceID?
    ) async throws -> AgentModelRouteSelection {
        calls += 1
        lastArguments = .init(
            purpose: purpose, explicitRouteID: explicitRouteID,
            workspaceID: workspaceID)
        return selection
    }

    func candidate(routeID: RouteID) async throws -> AgentModelRouteCandidate {
        guard let currentCandidate else {
            throw MiraError(.notFound, "The selected model route is unavailable.")
        }
        guard currentCandidate.preset.id == routeID else {
            throw MiraError(.notFound, "The selected model route is unavailable.")
        }
        return currentCandidate
    }

    func discoverySnapshot(connectionID: ConnectionID) async throws -> AgentModelDiscoverySnapshot? { throw unused() }
    func saveDiscoverySnapshot(_ value: AgentModelDiscoverySnapshot, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws { throw unused() }
    func connection(id: ConnectionID) async throws -> AgentConfiguredConnection? { throw unused() }
    func model(id: ModelDescriptorID) async throws -> AgentConfiguredModel? { throw unused() }
    func preset(id: RouteID) async throws -> AgentRoutePreset? { throw unused() }
    func connections(after: ConnectionID?, limit: Int) async throws -> [AgentConfiguredConnection] { throw unused() }
    func models(connectionID: ConnectionID?, after: ModelDescriptorID?, limit: Int) async throws -> [AgentConfiguredModel] {
        throw unused()
    }
    func presets(modelID: ModelDescriptorID?, after: RouteID?, limit: Int) async throws -> [AgentRoutePreset] { throw unused() }
    func ensureConversationDefault(authorization: AgentLibraryAuthorization) async throws -> AgentRouteBinding? { nil }
    func bindings(scope: AgentRouteScope) async throws -> [AgentRouteBinding] { throw unused() }
    func saveConnection(_ value: AgentConfiguredConnection, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws { throw unused() }
    func saveModel(_ value: AgentConfiguredModel, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws { throw unused() }
    func savePreset(_ value: AgentRoutePreset, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws { throw unused() }
    func savePoolModel(
        _ model: AgentConfiguredModel, preset: AgentRoutePreset,
        expectedModelRevision: Int?, expectedPresetRevision: Int?
    , authorization: AgentLibraryAuthorization) async throws { throw unused() }
    func saveBinding(_ value: AgentRouteBinding, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws { throw unused() }
    func deleteConnection(id: ConnectionID, expectedRevision: Int, authorization: AgentLibraryAuthorization) async throws { throw unused() }
    func deleteModel(id: ModelDescriptorID, expectedRevision: Int, authorization: AgentLibraryAuthorization) async throws { throw unused() }
    func deletePreset(id: RouteID, expectedRevision: Int, authorization: AgentLibraryAuthorization) async throws { throw unused() }
    func deleteBinding(scope: AgentRouteScope, purpose: String, expectedRevision: Int, authorization: AgentLibraryAuthorization) async throws { throw unused() }

}

private struct ResolverSelectionArguments: Sendable, Equatable {
    let purpose: String
    let explicitRouteID: RouteID?
    let workspaceID: WorkspaceID?
}

private actor ResolverStartGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            if isOpen { continuation.resume() } else { waiters.append(continuation) }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume() }
    }
}

private struct ResolverModelAdapter: AgentModelAdapter {
    let identity: AgentAdapterIdentity
    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        fatalError("route resolver tests never execute a model")
    }
    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        fatalError("route resolver tests never execute a model")
    }
    func replay(
        _ messages: [AgentModelMessage], from source: AgentModelRoute,
        to target: AgentModelRoute, boundary: AgentReplayBoundary
    ) throws -> AgentReplayDecision {
        fatalError("route resolver tests never execute a model")
    }
}

private struct ResolverConfigurationProvider: AgentModelConfigurationProvider {
    let identity: AgentAdapterIdentity
    func descriptor(for invocation: AgentModelInvocationSpec) throws -> AgentModelConfigurationDescriptor {
        let connection = AgentConfigurationSchema(
            identity: .init(id: "resolver.connection", revision: 1),
            title: "Resolver connection",
            schema: .object([
                "type": .string("object"),
                "properties": .object(["endpoint": .object(["type": .string("string")])]),
                "required": .array([.string("endpoint")]),
                "additionalProperties": .bool(false),
            ]), defaults: .object(["endpoint": .string("https://resolver.example")]))
        let route = AgentConfigurationSchema(
            identity: .init(id: "resolver.route", revision: 1),
            title: "Resolver route",
            schema: .object([
                "type": .string("object"),
                "properties": .object(["temperature": .object(["type": .string("number")])]),
                "additionalProperties": .bool(false),
            ]), defaults: .object(["temperature": .number(0.1)]))
        return .init(
            adapter: identity, title: invocation.id, credential: .required,
            connection: connection, route: route)
    }
    func configuration(for candidate: AgentModelRouteCandidate) throws -> JSONValue {
        .object(["provider": .string("resolver"), "model": .string(candidate.model.modelID)])
    }
}

private func unused() -> MiraError {
    MiraError(.configuration, "unused settings operation")
}

private func withResolverFixture(_ body: (ResolverFixture) async throws -> Void) async throws {
    let fixture = try await ResolverFixture.make()
    do { try await body(fixture) } catch {
        await fixture.close()
        throw error
    }
    await fixture.close()
}
