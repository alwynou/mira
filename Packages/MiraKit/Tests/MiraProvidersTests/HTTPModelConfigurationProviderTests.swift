import Foundation
import Testing

@testable import MiraCore
@testable import MiraProviders

@Suite("HTTP model configuration provider")
struct HTTPModelConfigurationProviderTests {
    @Test(arguments: ProtocolFixture.allCases)
    func everyFamilyPublishesValidatedDescriptor(_ fixture: ProtocolFixture) throws {
        let provider = HTTPModelConfigurationProvider(fixture: fixture)
        let descriptor = try provider.descriptor(modelID: modelID(for: fixture))
        try descriptor.validate()
        #expect(descriptor.adapter == fixture.adapter)
        #expect(descriptor.credential == .required)
        #expect(descriptor.connection.identity == .init(id: "mira.http.connection", revision: 2))
        #expect(descriptor.route.identity == .init(id: "mira.http.invocation", revision: 2))
        #expect(descriptor.connection.defaults["baseURL"] == .string(""))
        #expect(descriptor.route.defaults["thinking"]?["mode"] == .string("providerDefault"))
    }

    @Test func thinkingSchemaTracksModelSpecificCapabilities() throws {
        let standard = try HTTPModelConfigurationProvider(fixture: .standard).descriptor(modelID: "model")
        #expect(standard.route.schema["properties"]?["thinking"]?["properties"]?["mode"]?["enum"] == .array([.string("providerDefault")]))
        #expect(standard.route.schema["properties"]?["thinking"]?["properties"]?["effort"] == nil)
        #expect(standard.route.schema["properties"]?["thinking"]?["properties"]?["budgetTokens"] == nil)

        let openRouter = try HTTPModelConfigurationProvider(fixture: .openRouter).descriptor(modelID: "model")
        let thinking = try #require(openRouter.route.schema["properties"]?["thinking"])
        #expect(thinking["properties"]?["effort"]?["enum"] == .array([.string("low"), .string("medium"), .string("high"), .string("xhigh"), .string("max")]))
        #expect(thinking["properties"]?["budgetTokens"] != nil)

        let kimi = try HTTPModelConfigurationProvider(fixture: .kimi).descriptor(modelID: "kimi-k2.5")
        #expect(
            kimi.route.schema["properties"]?["thinking"]?["properties"]?["mode"]?["enum"]
                == .array([.string("providerDefault"), .string("enabled"), .string("disabled")]))
    }

    @Test func priceProvenanceIsFrozenLocallyAndNeverSentOnTheWire() throws {
        let provider = HTTPModelConfigurationProvider(fixture: .standard)
        let quote = HTTPModelPricingSnapshot(modelID: "model", sourceURL: "https://catalog.test/data.json",
            sourceRevision: "fixture-1", retrievedAt: "2026-09-13T00:00:00Z",
            pricing: .init(input: 2, output: 10, cacheRead: 0.1, baseURLs: ["https://example.test"]))
        let pricing = try SessionCodec.decode(JSONValue.self, from: SessionCodec.encode(quote))
        func configured(_ price: JSONValue) throws -> AgentModelRouteCandidate {
            try candidate(fixture: .standard, modelID: "model", route: [
                "requestsUsage": .bool(true), "thinking": .object(["mode": .string("providerDefault")]), "pricing": price
            ])
        }
        let selected = try configured(pricing)
        let frozen = try selected.freeze(configuration: provider.configuration(for: selected))
        let saved = try SessionCodec.decode(AgentModelRoute.self, from: SessionCodec.encode(frozen))
        #expect(saved.configuration["pricing"] == pricing)
        let prepared = try HTTPModelAdapter(fixture: .standard, credentials: NoReadCredential()).prepare(
            .init(stepID: UUID(), executionID: ExecutionID(), instructions: "Fixture",
                  messages: [.init(role: .user, text: "Hello")], tools: []), route: saved)
        let wire = try prepared.wirePayload.jsonString()
        #expect(!wire.contains("catalog.test"))
        #expect(!wire.contains("pricing"))
        let usage = TokenUsage(inputTokens: 1_000, outputTokens: 200, cacheReadTokens: 800)
        #expect(ModelCostEstimate.estimate(usage: usage, route: saved) == .available(Decimal(string: "0.00248")!))
        guard case .object(var changed) = pricing else { Issue.record("Invalid fixture"); return }
        changed["modelID"] = .string("another-model")
        #expect(throws: MiraError.self) { try provider.configuration(for: configured(.object(changed))) }
        changed["modelID"] = .string("model")
        changed["unknown"] = .bool(true)
        #expect(throws: MiraError.self) { try provider.configuration(for: configured(.object(changed))) }
    }

    @Test func configurationFreezesCandidateWithoutSecretLookup() throws {
        let fixture = ProtocolFixture.openAI
        let provider = HTTPModelConfigurationProvider(fixture: fixture)
        let candidate = try candidate(
            fixture: fixture, modelID: "gpt-5.5",
            credential: .init(reference: "keychain.fixture", version: 4),
            connection: [
                "baseURL": .string("https://api.example.test/v1"),
                "allowsLoopbackHTTP": .bool(false),
            ],
            route: [
                "requestsUsage": .bool(false),
                "thinking": .object(["mode": .string("enabled"), "effort": .string("high")]),
            ])
        let value = try provider.configuration(for: candidate)
        let frozen = try candidate.freeze(configuration: value)
        #expect(frozen.adapter == fixture.adapter)
        #expect(frozen.connectionID == candidate.connection.id)
        #expect(frozen.connectionRevision == candidate.connection.configurationRevision)
        #expect(frozen.modelDescriptorID == candidate.model.id)
        #expect(frozen.credential == candidate.connection.credential)
        #expect(frozen.configuration == value)
    }

    @Test(arguments: ProtocolFixture.allCases)
    func invalidEndpointAndSchemaValuesAreRejected(_ fixture: ProtocolFixture) throws {
        let model = modelID(for: fixture)
        let badURLs = [
            "http://api.example.test", "https://user:pass@example.test", "https://example.test?x=1",
            "https://example.test/v1/chat/completions",
        ]
        for baseURL in badURLs {
            let value = try candidate(
                fixture: fixture, modelID: model,
                connection: ["baseURL": .string(baseURL), "allowsLoopbackHTTP": .bool(false)],
                route: ["requestsUsage": .bool(true), "thinking": .object(["mode": .string("providerDefault")])])
            #expect(throws: MiraError.self) { try HTTPModelConfigurationProvider(fixture: fixture).configuration(for: value) }
        }
        let extra = try candidate(
            fixture: fixture, modelID: model,
            connection: ["baseURL": .string("https://example.test"), "allowsLoopbackHTTP": .bool(false), "unknown": .bool(true)],
            route: ["requestsUsage": .bool(true), "thinking": .object(["mode": .string("providerDefault")])])
        #expect(throws: MiraError.self) { try HTTPModelConfigurationProvider(fixture: fixture).configuration(for: extra) }
    }

    @Test func loopbackEffortAndBudgetBoundariesAreValidated() throws {
        let unsupportedGeneric = try candidate(
            fixture: .standard, modelID: "model",
            route: ["requestsUsage": .bool(true), "thinking": .object(["mode": .string("enabled"), "effort": .string("high")])])
        #expect(throws: MiraError.self) { try HTTPModelConfigurationProvider(fixture: .standard).configuration(for: unsupportedGeneric) }

        let implicitAnthropicBudget = try candidate(
            fixture: .anthropic, modelID: "claude", maxOutputTokens: 2_048,
            connection: ["baseURL": .string("https://api.example.test"), "allowsLoopbackHTTP": .bool(false)],
            route: ["requestsUsage": .bool(true), "thinking": .object(["mode": .string("enabled")])])
        #expect(throws: MiraError.self) { try HTTPModelConfigurationProvider(fixture: .anthropic).configuration(for: implicitAnthropicBudget) }

        let loopback = try candidate(
            fixture: .openRouter, modelID: "model",
            connection: ["baseURL": .string("http://127.0.0.1:8080"), "allowsLoopbackHTTP": .bool(false)],
            route: ["requestsUsage": .bool(true), "thinking": .object(["mode": .string("providerDefault")])])
        #expect(throws: MiraError.self) { try HTTPModelConfigurationProvider(fixture: .openRouter).configuration(for: loopback) }

        let enabledLoopback = try candidate(
            fixture: .openRouter, modelID: "model",
            connection: ["baseURL": .string("http://127.0.0.1:8080"), "allowsLoopbackHTTP": .bool(true)],
            route: ["requestsUsage": .bool(true), "thinking": .object(["mode": .string("enabled"), "effort": .string("high")])])
        #expect(
            try HTTPModelConfigurationProvider(fixture: .openRouter).configuration(for: enabledLoopback)["baseURL"]
                == .string("http://127.0.0.1:8080"))

        let badBudget = try candidate(
            fixture: .anthropic, modelID: "claude",
            maxOutputTokens: 4_096,
            connection: ["baseURL": .string("https://api.example.test"), "allowsLoopbackHTTP": .bool(false)],
            route: ["requestsUsage": .bool(true), "thinking": .object(["mode": .string("enabled"), "budgetTokens": .number(1_023)])])
        #expect(throws: MiraError.self) { try HTTPModelConfigurationProvider(fixture: .anthropic).configuration(for: badBudget) }

        let minimumBudget = try candidate(
            fixture: .anthropic, modelID: "claude", maxOutputTokens: 4_096,
            connection: ["baseURL": .string("https://api.example.test"), "allowsLoopbackHTTP": .bool(false)],
            route: ["requestsUsage": .bool(true), "thinking": .object(["mode": .string("enabled"), "budgetTokens": .number(1_024)])])
        #expect(
            try HTTPModelConfigurationProvider(fixture: .anthropic).configuration(for: minimumBudget)["thinking"]?["budgetTokens"]
                == .number(1_024))

        let routerBudget = try candidate(
            fixture: .openRouter, modelID: "model", maxOutputTokens: 4_096,
            route: ["requestsUsage": .bool(true), "thinking": .object(["mode": .string("enabled"), "budgetTokens": .number(1_024)])])
        #expect(
            try HTTPModelConfigurationProvider(fixture: .openRouter).configuration(for: routerBudget)["thinking"]?["budgetTokens"]
                == .number(1_024))

        let collision = try candidate(
            fixture: .openRouter, modelID: "model", maxOutputTokens: 4_096,
            route: [
                "requestsUsage": .bool(true),
                "thinking": .object(["mode": .string("enabled"), "effort": .string("high"), "budgetTokens": .number(1_024)]),
            ])
        #expect(throws: MiraError.self) { try HTTPModelConfigurationProvider(fixture: .openRouter).configuration(for: collision) }
    }

    @Test func missingCredentialOrWrongAdapterIsRejected() throws {
        let noCredential = try candidate(fixture: .standard, modelID: "model", credential: nil)
        #expect(
            try #require(throws: MiraError.self) { try HTTPModelConfigurationProvider(fixture: .standard).configuration(for: noCredential) }
                .code == .credentialMissing)
        let wrong = try candidate(fixture: .standard, modelID: "model", adapter: ProtocolFixture.anthropic.identity)
        #expect(throws: MiraError.self) { try HTTPModelConfigurationProvider(fixture: .standard).configuration(for: wrong) }
    }

    @Test func schemaIdentityAndRevisionAreExact() throws {
        let wrongConnection = try candidate(
            fixture: .standard, modelID: "model",
            connectionSchemaID: .init(id: "mira.http.other", revision: 1))
        #expect(throws: MiraError.self) { try HTTPModelConfigurationProvider(fixture: .standard).configuration(for: wrongConnection) }
        let wrongRoute = try candidate(
            fixture: .standard, modelID: "model",
            routeSchemaID: .init(id: "mira.http.invocation", revision: 1))
        #expect(throws: MiraError.self) { try HTTPModelConfigurationProvider(fixture: .standard).configuration(for: wrongRoute) }
    }

    @Test(arguments: ProtocolFixture.allCases)
    func configuredRoutePreparesWirePayloadForEveryFamily(_ fixture: ProtocolFixture) throws {
        let provider = HTTPModelConfigurationProvider(fixture: fixture)
        let candidate = try candidate(fixture: fixture, modelID: modelID(for: fixture))
        let configuration = try provider.configuration(for: candidate)
        let route = try candidate.freeze(configuration: configuration)
        let adapter = HTTPModelAdapter(fixture: fixture, credentials: NoReadCredential())
        let input = AgentModelInput(
            stepID: UUID(), executionID: ExecutionID(), instructions: "Fixture",
            messages: [.init(role: .user, text: "Hello")], tools: [])
        let prepared = try adapter.prepare(input, route: route)
        #expect(prepared.adapter == fixture.adapter)
        #expect(prepared.input == input)
        #expect(prepared.wirePayload["model"] == .string(route.modelID))
    }

    private func candidate(
        fixture: ProtocolFixture, modelID: String, credential: AgentCredentialReference? = .init(reference: "fixture", version: 1),
        adapter: AgentAdapterIdentity? = nil,
        maxOutputTokens: Int = 1_024,
        connectionSchemaID: AgentConfigurationIdentity = .init(id: "mira.http.connection", revision: 2),
        routeSchemaID: AgentConfigurationIdentity = .init(id: "mira.http.invocation", revision: 2),
        connection: [String: JSONValue] = ["baseURL": .string("https://example.test"), "allowsLoopbackHTTP": .bool(false)],
        route: [String: JSONValue] = ["requestsUsage": .bool(true), "thinking": .object(["mode": .string("providerDefault")])]
    ) throws -> AgentModelRouteCandidate {
        let connectionID = ConnectionID()
        let modelDescriptorID = ModelDescriptorID()
        let routeID = RouteID()
        let connection = AgentConfiguredConnection(
            id: connectionID, revision: 2, configurationRevision: 1,
            name: "Fixture", isEnabled: true, credential: credential,
            configuration: .init(schema: connectionSchemaID, value: .object(connection)))
        var caps: [String: CapabilityState] = [AgentModelCapabilityID.streamingText: .verified]
        if fixture != .standard { caps[AgentModelCapabilityID.thinking] = .declared }
        let model = AgentConfiguredModel(
            id: modelDescriptorID, revision: 3, connectionID: connectionID,
            connectionConfigurationRevision: connection.configurationRevision,
            adapter: adapter ?? fixture.adapter, modelID: modelID,
            isEnabled: true, contextWindow: 8_192, capabilities: caps, dialect: fixture.dialect)
        let preset = AgentRoutePreset(
            id: routeID, revision: 4, name: "Fixture route",
            modelDescriptorID: modelDescriptorID, invocationID: "default", maximumOutputTokens: maxOutputTokens,
            configuration: .init(schema: routeSchemaID, value: .object(route)))
        return .init(connection: connection, model: model, preset: preset)
    }

    private func modelID(for fixture: ProtocolFixture) -> String {
        switch fixture {
        case .standard: "model"
        case .deepSeek: "deepseek-reasoner"
        case .kimi: "kimi-k3"
        case .anthropic: "claude-sonnet-5"
        case .openAI: "gpt-5.5"
        case .openRouter: "openrouter-model"
        case .responses: "gpt-5"
        }
    }
}

private struct NoReadCredential: CredentialReader {
    func read(reference: String, version: Int) throws -> String {
        throw MiraError(.credentialMissing, "Credential access is not expected during preparation.")
    }
}
