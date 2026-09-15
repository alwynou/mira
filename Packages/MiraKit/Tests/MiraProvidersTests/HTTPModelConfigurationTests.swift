import Foundation
import Testing
@testable import MiraCore
@testable import MiraProviders

@Suite("HTTP model configuration")
struct HTTPModelConfigurationTests {
    @Test func fixturesHaveDistinctStableIdentities() {
        let fixtures = ProtocolFixture.allCases
    #expect(Set(fixtures.map(\.identity)).count == 3)
        #expect(fixtures.allSatisfy { $0.identity.id.hasPrefix("mira.") && $0.identity.revision == 1 })
        #expect(ProtocolFixture.anthropic.isAnthropic)
        #expect(ProtocolFixture.anthropic.isAnthropic)
        #expect(!ProtocolFixture.openAI.isAnthropic)
    }

    @Test func configurationSerializesAndResolvesEndpoint() throws {
        let configuration = HTTPModelConfiguration(
            baseURL: "https://gateway.example.test/prefix",
            requestsUsage: false,
            thinking: .init(mode: .enabled, effort: .high))
        let value = try configuration.jsonValue()
        #expect(value["baseURL"]?.stringValue == configuration.baseURL)
        #expect(value["allowsLoopbackHTTP"] == .bool(false))
        #expect(value["requestsUsage"] == .bool(false))
        #expect(try configuration.validatedEndpoint(fixture: .openAI).absoluteString ==
                "https://gateway.example.test/prefix/chat/completions")
        #expect(try configuration.validatedEndpoint(fixture: .anthropic).absoluteString ==
                "https://gateway.example.test/prefix/v1/messages")
    }

    @Test(arguments: [
        "http://gateway.example.test",
        "https://gateway.example.test?token=secret",
        "https://user:password@gateway.example.test",
        "https://gateway.example.test/v1/chat/completions",
        "https://gateway.example.test/v1/messages"
    ])
    func endpointRejectsUnsafeOrAlreadyExpandedURL(_ baseURL: String) {
        let configuration = HTTPModelConfiguration(baseURL: baseURL)
        #expect(throws: MiraError.self) { try configuration.validatedEndpoint(fixture: .openAI) }
    }

    @Test func loopbackHTTPRequiresExplicitOptIn() throws {
        #expect(throws: MiraError.self) {
            try HTTPModelConfiguration(baseURL: "http://127.0.0.1:8080").validatedEndpoint(fixture: .standard)
        }
        let configuration = HTTPModelConfiguration(baseURL: "http://127.0.0.1:8080", allowsLoopbackHTTP: true)
        #expect(try configuration.validatedEndpoint(fixture: .standard).absoluteString ==
                "http://127.0.0.1:8080/chat/completions")
    }

    @Test func policyRequiresExactAdapterAndConfiguration() throws {
        let configuration = HTTPModelConfiguration(baseURL: "https://api.example.test/v1",
                                                    protocolID: .chatCompletions,
                                                    dialectProfileID: .openAI)
        let route = try makeRoute(fixture: .openAI, modelID: "gpt-5.5", configuration: configuration)
        let policy = try HTTPModelPolicy(route: route, fixture: .openAI)
        #expect(policy.modelID == "gpt-5.5")
        #expect(policy.maximumOutputTokens == route.maximumOutputTokens)
        #expect(policy.configuration == configuration)
        let wrongAdapter = AgentModelRoute(id: route.id, revision: route.revision,
            connectionID: route.connectionID, connectionRevision: route.connectionRevision,
            modelDescriptorID: route.modelDescriptorID, modelRevision: route.modelRevision,
            adapter: ProtocolFixture.anthropic.identity, modelID: route.modelID, credential: route.credential,
            contextWindow: route.contextWindow, maximumOutputTokens: route.maximumOutputTokens,
            capabilities: route.capabilities, configuration: route.configuration)
        #expect(throws: MiraError.self) { try HTTPModelPolicy(route: wrongAdapter, fixture: .openAI) }
        let extra = JSONValue.object(["baseURL": .string(configuration.baseURL), "unexpected": .bool(true),
                                      "allowsLoopbackHTTP": .bool(false), "requestsUsage": .bool(true),
                                      "thinking": .object(["mode": .string("providerDefault"), "effort": .null, "budgetTokens": .null])])
        let wrongConfiguration = AgentModelRoute(id: route.id, revision: route.revision,
            connectionID: route.connectionID, connectionRevision: route.connectionRevision,
            modelDescriptorID: route.modelDescriptorID, modelRevision: route.modelRevision,
            adapter: route.adapter, modelID: route.modelID, credential: route.credential,
            contextWindow: route.contextWindow, maximumOutputTokens: route.maximumOutputTokens,
            capabilities: route.capabilities, configuration: extra)
        #expect(throws: MiraError.self) { try HTTPModelPolicy(route: wrongConfiguration, fixture: .openAI) }
    }

    @Test func thinkingCapabilitiesPreserveVendorSpecificBoundaries() {
        #expect(HTTPThinkingCapabilities(fixture: .standard, modelID: "model").modes == [.providerDefault])
        #expect(HTTPThinkingCapabilities(fixture: .deepSeek, modelID: "deepseek").efforts == [.low, .high, .max])
        #expect(HTTPThinkingCapabilities(fixture: .kimi, modelID: "kimi-k3").efforts == [.low, .high, .max])
        #expect(HTTPThinkingCapabilities(fixture: .anthropic, modelID: "claude").supportsBudget)
        #expect(HTTPThinkingCapabilities(fixture: .openRouter, modelID: "model").supportsBudget)
        #expect(HTTPThinkingCapabilities(fixture: .openAI, modelID: "gpt-5.1").efforts == [.low, .medium, .high])
    }

    private func makeRoute(fixture: ProtocolFixture, modelID: String,
                           configuration: HTTPModelConfiguration) throws -> AgentModelRoute {
        .init(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
              modelDescriptorID: ModelDescriptorID(), modelRevision: 1, adapter: fixture.adapter,
              modelID: modelID, credential: nil, contextWindow: 4_096, maximumOutputTokens: 1_024,
              capabilities: .init(streamsText: true, callsTools: true, producesThinking: true),
              configuration: try configuration.jsonValue())
    }
}
