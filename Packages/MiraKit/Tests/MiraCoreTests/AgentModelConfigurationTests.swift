import Foundation
import Testing

@testable import MiraCore

@Suite("Agent model configuration", .timeLimit(.minutes(1)))
struct AgentModelConfigurationTests {
    @Test func schemaDefaultsAndValuesAreValidatedAgainstTheSameRevision() throws {
        let schema = makeSchema(id: "config.test", revision: 1)
        try schema.validate()
        let settings = AgentConfigurationValue(
            schema: schema.identity,
            value: .object(["endpoint": .string("https://example.test")]))
        try schema.validate(settings)

        let wrongSchema = makeSchema(id: "config.test", revision: 2)
        let wrong = AgentConfigurationValue(schema: wrongSchema.identity, value: settings.value)
        #expect(throws: MiraError.self) { try schema.validate(wrong) }

        let invalidDefaults = AgentConfigurationSchema(
            identity: schema.identity, title: "Test",
            schema: schema.schema, defaults: .object(["unknown": .string("x")]))
        #expect(throws: MiraError.self) { try invalidDefaults.validate() }

        let unsupportedSchema = AgentConfigurationSchema(
            identity: schema.identity, title: "Test",
            schema: .object(["type": .string("array")]), defaults: .object([:]))
        #expect(throws: MiraError.self) { try unsupportedSchema.validate() }
    }

    @Test func schemaAndValueBoundsRejectMalformedOrOversizedObjects() throws {
        #expect(throws: MiraError.self) { try AgentConfigurationIdentity(id: "", revision: 1).validate() }
        #expect(throws: MiraError.self) { try AgentConfigurationIdentity(id: "config.test", revision: 0).validate() }
        #expect(throws: MiraError.self) {
            try AgentConfigurationSchema(
                identity: .init(id: "config.test", revision: 1), title: "",
                schema: .object(["type": .string("object")]), defaults: .object([:])
            ).validate()
        }
        let scalar = AgentConfigurationValue(schema: .init(id: "config.test", revision: 1), value: .string("scalar"))
        #expect(throws: MiraError.self) { try scalar.validate() }

        let huge = String(repeating: "x", count: 65_537)
        let value = AgentConfigurationValue(
            schema: .init(id: "config.test", revision: 1),
            value: .object(["endpoint": .string(huge)]))
        #expect(throws: MiraError.self) { try value.validate() }
    }

    @Test func descriptorValidatesBothSettingsFormsAndCredentialPolicy() throws {
        let descriptor = makeDescriptor(adapter: .init(id: "adapter.test", revision: 1), modelID: "model.test")
        try descriptor.validate()
        #expect(descriptor.credential == .required)

        let invalidTitle = AgentModelConfigurationDescriptor(
            adapter: descriptor.adapter, title: " ",
            credential: descriptor.credential, connection: descriptor.connection, route: descriptor.route)
        #expect(throws: MiraError.self) { try invalidTitle.validate() }
    }

    @Test func candidateRequiresEnabledRelationsAndCapabilities() throws {
        let candidate = makeCandidate()
        try candidate.validate(requiredCapabilities: [AgentModelCapabilityID.thinking])
        let route = try candidate.freeze(configuration: .object(["temperature": .number(0.2)]))
        try route.validate()
        #expect(route.adapter == candidate.model.invocations[0].adapter)
        #expect(route.configuration == .object(["temperature": .number(0.2)]))

        let staleModel = AgentConfiguredModel(id: candidate.model.id, revision: candidate.model.revision, authorizationRevision: 1, reference: .init(connectionID: .init(), modelID: candidate.model.modelID), displayName: nil, isEnabled: true, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: candidate.model.invocations[0].adapter, endpointID: "primary", contextWindow: candidate.model.invocations[0].contextWindow, maximumOutputTokens: nil, capabilities: candidate.model.invocations[0].capabilities, configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]))], facts: [])
        #expect(throws: MiraError.self) {
            try AgentModelRouteCandidate(connection: candidate.connection, model: staleModel, preset: candidate.preset).validate()
        }

        let disabled = AgentConfiguredConnection(id: candidate.connection.id, revision: candidate.connection.revision, configurationRevision: candidate.connection.configurationRevision, name: candidate.connection.name, isEnabled: false, definitionID: nil, endpoints: [.init(id: "primary", configuration: candidate.connection.endpoints[0].configuration, credential: candidate.connection.endpoints[0].credential)], discovery: nil, defaultInvocation: nil)
        #expect(throws: MiraError.self) {
            try AgentModelRouteCandidate(connection: disabled, model: candidate.model, preset: candidate.preset).validate()
        }
        #expect(throws: MiraError.self) {
            try candidate.validate(requiredCapabilities: ["mira.unknownCapability"])
        }
    }

    @Test func candidateRejectsMissingWindowAndIncompatibleRelationsWithoutFallback() throws {
        let candidate = makeCandidate()
        let noWindow = AgentConfiguredModel(id: candidate.model.id, revision: candidate.model.revision, authorizationRevision: 1, reference: .init(connectionID: candidate.model.connectionID, modelID: candidate.model.modelID), displayName: nil, isEnabled: true, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: candidate.model.invocations[0].adapter, endpointID: "primary", contextWindow: nil, maximumOutputTokens: nil, capabilities: candidate.model.invocations[0].capabilities, configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]))], facts: [])
        #expect(throws: MiraError.self) {
            try AgentModelRouteCandidate(connection: candidate.connection, model: noWindow, preset: candidate.preset).validate()
        }

        let otherModel = AgentConfiguredModel(id: .init(), revision: 1, authorizationRevision: 1, reference: .init(connectionID: candidate.connection.id, modelID: "other"), displayName: nil, isEnabled: true, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: candidate.model.invocations[0].adapter, endpointID: "primary", contextWindow: 32_000, maximumOutputTokens: nil, capabilities: candidate.model.invocations[0].capabilities, configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]))], facts: [])
        #expect(throws: MiraError.self) {
            try AgentModelRouteCandidate(connection: candidate.connection, model: otherModel, preset: candidate.preset).validate()
        }
    }

    @Test func providerIdentityAndOpaqueConfigurationRemainExplicit() throws {
        let provider = TestConfigurationProvider(identity: .init(id: "adapter.test", revision: 1))
        let candidate = makeCandidate()
        let descriptor = try provider.descriptor(for: candidate.invocation)
        #expect(descriptor.adapter == provider.identity)
        let configuration = try provider.configuration(for: candidate)
        #expect(configuration == .object(["provider": .string("test"), "model": .string(candidate.model.modelID)]))
        let route = try candidate.freeze(configuration: configuration)
        #expect(route.configuration == configuration)
    }

    @Test func catalogFreezesOnlyTheSelectedInvocationDescriptor() async throws {
        let scope = RuntimeScope(kind: .application)
        let registry = RuntimeRegistry<AgentCapability>()
        let adapter = TestModelAdapter(identity: .init(id: "adapter.test", revision: 1))
        try await registry.register(id: "model", value: .model(adapter), scope: scope)
        try await registry.register(
            id: "config-z",
            value: .modelConfiguration(
                TestConfigurationProvider(identity: .init(id: "adapter.z", revision: 1))), scope: scope)
        try await registry.register(
            id: "config-test",
            value: .modelConfiguration(
                TestConfigurationProvider(identity: adapter.identity)), scope: scope)
        try await registry.register(
            id: "config-a",
            value: .modelConfiguration(
                TestConfigurationProvider(identity: .init(id: "adapter.a", revision: 1))), scope: scope)

        let snapshot = try await registry.freeze()
        let catalog = try AgentRuntimeCatalog(snapshot: snapshot)
        let descriptors = try catalog.modelConfigurationDescriptors(for: makeCandidate().model.invocations[0])
        #expect(descriptors.map(\.adapter.id) == ["adapter.test"])

        let candidate = makeCandidate()
        let route = try catalog.configuredRoute(candidate)
        #expect(route.adapter == adapter.identity)
        #expect(route.id == candidate.preset.id)
        #expect(route.revision == candidate.preset.revision)
        #expect(route.connectionID == candidate.connection.id)
        #expect(route.connectionRevision == candidate.connection.configurationRevision)
        #expect(route.modelDescriptorID == candidate.model.id)
        #expect(route.modelRevision == candidate.model.revision)
        #expect(route.modelID == candidate.model.modelID)
        #expect(route.credential == candidate.connection.endpoints[0].credential)
        #expect(route.contextWindow == candidate.model.invocations[0].contextWindow)
        #expect(route.maximumOutputTokens == candidate.preset.maximumOutputTokens)
        #expect(route.capabilities == .init(streamsText: true, callsTools: false, producesThinking: true))
        #expect(route.configuration == .object(["provider": .string("test"), "model": .string("model.test")]))

        await catalog.release()
        await scope.dispose()
    }

    @Test func catalogRequiresExactProviderAndCredentialPolicy() async throws {
        let candidate = makeCandidate()

        // A registered model without a same-identity settings provider cannot
        // silently fall back to another provider.
        let missingProviderScope = RuntimeScope(kind: .application)
        let missingProviderRegistry = RuntimeRegistry<AgentCapability>()
        try await missingProviderRegistry.register(
            id: "model",
            value: .model(
                TestModelAdapter(identity: candidate.model.invocations[0].adapter)), scope: missingProviderScope)
        let missingProviderSnapshot = try await missingProviderRegistry.freeze()
        let missingProviderCatalog = try AgentRuntimeCatalog(snapshot: missingProviderSnapshot)
        #expect(throws: MiraError.self) { try missingProviderCatalog.configuredRoute(candidate) }
        await missingProviderCatalog.release()
        await missingProviderScope.dispose()

        // A provider without its matching executable adapter is equally
        // unusable; the catalog does not infer or substitute an adapter.
        let missingModelScope = RuntimeScope(kind: .application)
        let missingModelRegistry = RuntimeRegistry<AgentCapability>()
        try await missingModelRegistry.register(
            id: "config",
            value: .modelConfiguration(
                TestConfigurationProvider(identity: candidate.model.invocations[0].adapter)), scope: missingModelScope)
        let missingModelSnapshot = try await missingModelRegistry.freeze()
        let missingModelCatalog = try AgentRuntimeCatalog(snapshot: missingModelSnapshot)
        #expect(throws: MiraError.self) { try missingModelCatalog.configuredRoute(candidate) }
        await missingModelCatalog.release()
        await missingModelScope.dispose()

        // Credential policy is enforced by the frozen provider wrapper.
        let requiredScope = RuntimeScope(kind: .application)
        let requiredRegistry = RuntimeRegistry<AgentCapability>()
        try await requiredRegistry.register(
            id: "model",
            value: .model(
                TestModelAdapter(identity: candidate.model.invocations[0].adapter)), scope: requiredScope)
        try await requiredRegistry.register(
            id: "config",
            value: .modelConfiguration(
                TestConfigurationProvider(identity: candidate.model.invocations[0].adapter, credential: .required)), scope: requiredScope)
        let requiredSnapshot = try await requiredRegistry.freeze()
        let requiredCatalog = try AgentRuntimeCatalog(snapshot: requiredSnapshot)
        let withoutCredential = AgentConfiguredConnection(id: candidate.connection.id, revision: candidate.connection.revision, configurationRevision: candidate.connection.configurationRevision, name: candidate.connection.name, isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: candidate.connection.endpoints[0].configuration, credential: nil)], discovery: nil, defaultInvocation: nil)
        let missingCredentialCandidate = AgentModelRouteCandidate(
            connection: withoutCredential,
            model: candidate.model, preset: candidate.preset)
        #expect(throws: MiraError.self) { try requiredCatalog.configuredRoute(missingCredentialCandidate) }
        await requiredCatalog.release()
        await requiredScope.dispose()

        let noneScope = RuntimeScope(kind: .application)
        let noneRegistry = RuntimeRegistry<AgentCapability>()
        try await noneRegistry.register(
            id: "model",
            value: .model(
                TestModelAdapter(identity: candidate.model.invocations[0].adapter)), scope: noneScope)
        try await noneRegistry.register(
            id: "config",
            value: .modelConfiguration(
                TestConfigurationProvider(identity: candidate.model.invocations[0].adapter, credential: .none)), scope: noneScope)
        let noneSnapshot = try await noneRegistry.freeze()
        let noneCatalog = try AgentRuntimeCatalog(snapshot: noneSnapshot)
        #expect(throws: MiraError.self) { try noneCatalog.configuredRoute(candidate) }
        await noneCatalog.release()
        await noneScope.dispose()

        // Different revisions still share one stable provider namespace and
        // therefore cannot coexist in one immutable catalog.
        let duplicateScope = RuntimeScope(kind: .application)
        let duplicateRegistry = RuntimeRegistry<AgentCapability>()
        try await duplicateRegistry.register(
            id: "config-1",
            value: .modelConfiguration(
                TestConfigurationProvider(identity: .init(id: "adapter.duplicate", revision: 1))), scope: duplicateScope)
        try await duplicateRegistry.register(
            id: "config-2",
            value: .modelConfiguration(
                TestConfigurationProvider(identity: .init(id: "adapter.duplicate", revision: 2))), scope: duplicateScope)
        let duplicateSnapshot = try await duplicateRegistry.freeze()
        #expect(throws: MiraError.self) { try AgentRuntimeCatalog(snapshot: duplicateSnapshot) }
        await duplicateSnapshot.release()
        await duplicateScope.dispose()
    }

    @Test func catalogRejectsMutableDescriptorIdentityAndPinsScopeUntilRelease() async throws {
        let scope = RuntimeScope(kind: .application)
        let registry = RuntimeRegistry<AgentCapability>()
        let identity = AgentAdapterIdentity(id: "adapter.mutable", revision: 1)
        let provider = MutableConfigurationProvider(identity: identity)
        try await registry.register(id: "model", value: .model(TestModelAdapter(identity: identity)), scope: scope)
        try await registry.register(id: "config", value: .modelConfiguration(provider), scope: scope)
        let cleanup = ConfigurationCleanupProbe()
        try await scope.registerCleanup { await cleanup.mark() }

        let snapshot = try await registry.freeze()
        let catalog = try AgentRuntimeCatalog(snapshot: snapshot)
        provider.replaceDescriptorIdentity(.init(id: "adapter.attacker", revision: 1))
        #expect(throws: MiraError.self) {
            try catalog.modelConfigurationDescriptors(for: makeCandidate().model.invocations[0])
        }

        let disposal = Task { await scope.dispose() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await scope.isDisposed), ContinuousClock.now < deadline { await Task.yield() }
        let closingWasObserved = await scope.isDisposed
        #expect(await cleanup.count == 0)
        await catalog.release()
        await disposal.value
        #expect(closingWasObserved)
        #expect(await cleanup.count == 1)
    }

    private func makeSchema(id: String, revision: Int) -> AgentConfigurationSchema {
        .init(
            identity: .init(id: id, revision: revision), title: "Connection settings",
            schema: .object([
                "type": .string("object"),
                "properties": .object(["endpoint": .object(["type": .string("string")])]),
                "required": .array([.string("endpoint")]),
                "additionalProperties": .bool(false),
            ]),
            defaults: .object(["endpoint": .string("https://example.test")]))
    }

    private func makeDescriptor(adapter: AgentAdapterIdentity, modelID: String) -> AgentModelConfigurationDescriptor {
        makeTestDescriptor(adapter: adapter, modelID: modelID)
    }

    private func makeCandidate() -> AgentModelRouteCandidate {
        let adapter = AgentAdapterIdentity(id: "adapter.test", revision: 1)
        let connection = AgentConfiguredConnection(id: .init(), revision: 3, configurationRevision: 2, name: "Test connection", isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: .init(
                schema: .init(id: "connection.test", revision: 1),
                value: .object(["endpoint": .string("https://example.test")])), credential: .init(reference: "key.test", version: 1))], discovery: nil, defaultInvocation: nil)
        let model = AgentConfiguredModel(id: .init(), revision: 2, authorizationRevision: 1, reference: .init(connectionID: connection.id, modelID: "model.test"), displayName: nil, isEnabled: true, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: adapter, endpointID: "primary", contextWindow: 32_000, maximumOutputTokens: nil, capabilities: [
                AgentModelCapabilityID.streamingText: .verified,
                AgentModelCapabilityID.thinking: .declared,
            ], configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]))], facts: [])
        let preset = AgentRoutePreset(id: .init(), revision: 4, name: "Test route", modelDescriptorID: model.id, invocationID: "default", maximumOutputTokens: 2_048, configuration: .init(
                schema: .init(id: "route.test", revision: 1),
                value: .object(["temperature": .number(0.2)])))
        return .init(connection: connection, model: model, preset: preset)
    }
}

private struct TestConfigurationProvider: AgentModelConfigurationProvider {
    let identity: AgentAdapterIdentity
    let credential: AgentCredentialRequirement

    init(identity: AgentAdapterIdentity, credential: AgentCredentialRequirement = .required) {
        self.identity = identity
        self.credential = credential
    }

    func descriptor(for invocation: AgentModelInvocationSpec) throws -> AgentModelConfigurationDescriptor {
        let schema = AgentModelConfigurationTests().makeTestDescriptor(
            adapter: identity, modelID: invocation.id,
            credential: credential)
        return schema
    }

    func configuration(for candidate: AgentModelRouteCandidate) throws -> JSONValue {
        guard candidate.model.invocations[0].adapter == identity else {
            throw MiraError(.configuration, "The configuration provider does not own this model adapter.")
        }
        return .object(["provider": .string("test"), "model": .string(candidate.model.modelID)])
    }
}

private struct TestModelAdapter: AgentModelAdapter {
    let identity: AgentAdapterIdentity

    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        fatalError("configuration tests never execute a model")
    }

    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        fatalError("configuration tests never execute a model")
    }

    func replay(
        _ messages: [AgentModelMessage], from source: AgentModelRoute,
        to target: AgentModelRoute, boundary: AgentReplayBoundary
    ) throws -> AgentReplayDecision {
        fatalError("configuration tests never execute a model")
    }
}

private final class MutableConfigurationProvider: AgentModelConfigurationProvider, @unchecked Sendable {
    let identity: AgentAdapterIdentity
    private let lock = NSLock()
    private var descriptorIdentity: AgentAdapterIdentity

    init(identity: AgentAdapterIdentity) {
        self.identity = identity
        self.descriptorIdentity = identity
    }

    func replaceDescriptorIdentity(_ identity: AgentAdapterIdentity) {
        lock.lock()
        descriptorIdentity = identity
        lock.unlock()
    }

    func descriptor(for invocation: AgentModelInvocationSpec) throws -> AgentModelConfigurationDescriptor {
        lock.lock()
        let current = descriptorIdentity
        lock.unlock()
        return AgentModelConfigurationTests().makeTestDescriptor(adapter: current, modelID: invocation.id)
    }

    func configuration(for candidate: AgentModelRouteCandidate) throws -> JSONValue {
        .object(["provider": .string("mutable"), "model": .string(candidate.model.modelID)])
    }
}

private actor ConfigurationCleanupProbe {
    private(set) var count = 0
    func mark() { count += 1 }
}

extension AgentModelConfigurationTests {
    fileprivate func makeTestDescriptor(
        adapter: AgentAdapterIdentity, modelID: String,
        credential: AgentCredentialRequirement = .required
    ) -> AgentModelConfigurationDescriptor {
        let connection = makeSchema(id: "connection.test", revision: 1)
        let route = AgentConfigurationSchema(
            identity: .init(id: "route.test", revision: 1), title: "Route settings",
            schema: .object([
                "type": .string("object"), "properties": .object(["temperature": .object(["type": .string("number")])]),
                "additionalProperties": .bool(false),
            ]),
            defaults: .object(["temperature": .number(0.2)]))
        return .init(adapter: adapter, title: modelID, credential: credential, connection: connection, route: route)
    }
}
