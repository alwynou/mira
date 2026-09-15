import Foundation
import MiraCore
import Testing

@testable import MiraProviders

private func catalogConnection(baseURL: String) -> AgentConfiguredConnection {
    AgentConfiguredConnection(
        id: ConnectionID(), revision: 1, configurationRevision: 1,
        name: "Fixture", isEnabled: true,
        credential: .init(reference: "fixture", version: 1),
        configuration: .init(
            schema: HTTPConnectionSettings.schema.identity,
            value: .object([
                "baseURL": .string(baseURL),
                "allowsLoopbackHTTP": .bool(false),
            ])
        )
    )
}

private func minimalCatalogJSON() -> Data {
    Data(
        #"{"providers":[{"id":"fixture","name":"Fixture","baseURL":"https://fixture.test/v1","documentationURL":"https://fixture.test/docs","discoveryProtocol":"openAI","protocolID":"chat.completions","dialectProfileID":"generic","models":[{"metadata":{"providerID":"fixture","modelID":"model","displayName":null,"sourceURL":"https://models.dev/api.json","sourceRevision":"sha256:test","retrievedAt":"2026-09-06T00:00:00Z","baseModelID":null,"lifecycle":null,"reasoningOptions":[],"maxInputTokens":null,"contextWindow":null,"maxOutputTokens":null,"inputModalities":[],"outputModalities":[],"toolCall":null,"structuredOutput":null,"reasoning":null,"requiresReasoningContinuation":false,"task":"unknown"},"protocolID":"chat.completions","dialectProfileID":"generic"}]}]}"#
            .utf8)
}

private final class CatalogCredentials: CredentialReader, @unchecked Sendable {
    let value: String
    private(set) var reads = 0
    init(_ value: String = "fixture-secret") { self.value = value }
    func read(reference: String, version: Int) throws -> String {
        reads += 1
        return value
    }
}

private final class CatalogTransport: HTTPStreamingTransport, @unchecked Sendable {
    let responseBytes: Data
    private(set) var requests: [URLRequest] = []
    init(responseBytes: Data? = nil) {
        self.responseBytes =
            responseBytes
            ?? Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)
    }
    func stream(request: URLRequest) -> HTTPTransportOperation {
        requests.append(request)
        let events = AsyncThrowingStream<HTTPTransportEvent, any Error> { continuation in
            continuation.yield(.response(HTTPTransportResponse(statusCode: 200)))
            continuation.yield(.bytes(responseBytes))
            continuation.yield(.end)
            continuation.finish()
        }
        return HTTPTransportOperation(events: events, cancelAndDrain: {})
    }
}

private func adapterRoute(
    _ fixture: ProtocolFixture,
    baseURL: String,
    modelID: String,
    contextWindow: Int,
    maximumOutputTokens: Int,
    thinking: ThinkingSettings = .init()
) throws -> AgentModelRoute {
    let configuration = HTTPModelConfiguration(baseURL: baseURL, protocolID: fixture.protocolID,
                                                dialectProfileID: fixture.dialect,
                                                requestsUsage: true, thinking: thinking)
    return AgentModelRoute(
        id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
        modelDescriptorID: ModelDescriptorID(), modelRevision: 1, adapter: fixture.adapter,
        modelID: modelID, credential: .init(reference: "fixture", version: 1),
        contextWindow: contextWindow, maximumOutputTokens: maximumOutputTokens,
        capabilities: .init(streamsText: true, callsTools: true, producesThinking: true),
        configuration: try configuration.jsonValue()
    )
}

private func adapterInput(
    messages: [AgentModelMessage] = [.init(role: .user, text: "Hello")],
    tools: [ToolDefinition] = []
) -> AgentModelInput {
    AgentModelInput(
        stepID: UUID(), executionID: ExecutionID(), instructions: "System",
        messages: messages, tools: tools)
}

private func streamAdapter(
    _ adapter: any AgentModelAdapter,
    input: AgentModelInput,
    route: AgentModelRoute
) async throws -> [AgentModelStreamEvent] {
    let prepared = try adapter.prepare(input, route: route)
    let operation = adapter.stream(prepared, route: route)
    var events: [AgentModelStreamEvent] = []
    do {
        for try await event in operation.events { events.append(event) }
        await operation.close()
        return events
    } catch {
        await operation.close()
        throw error
    }
}

@Test("Bundled catalog preserves provenance and reviewed protocol modes")
func bundledCatalogProvenanceAndModes() throws {
    let catalog = ProviderModelCatalog.bundled
    #expect(
        catalog.providers.map(\.id) == [
            "openai", "anthropic", "kimi-for-coding", "moonshotai-cn", "moonshotai", "deepseek", "openrouter",
        ])
    #expect(
        catalog.directoryProviders.map(\.id) == [
            "openai", "anthropic", "kimi-for-coding", "moonshotai-cn", "deepseek", "openrouter",
        ])
    #expect(catalog.providers.first?.discoveryProtocol == .openAI)
    #expect(catalog.providers.dropFirst().first?.discoveryProtocol == .anthropic)
    let openAI = try #require(
        catalog.model(for: catalogConnection(baseURL: "https://api.openai.com/v1"), modelID: "gpt-5.1"))
    #expect(openAI.metadata.sourceURL.contains("models.dev"))
    #expect(openAI.metadata.sourceRevision.hasPrefix("sha256:"))
    #expect(!openAI.metadata.retrievedAt.isEmpty)
    let embedding = try #require(
        catalog.model(for: catalogConnection(baseURL: "https://api.openai.com/v1"), modelID: "text-embedding-3-small"))
    #expect(embedding.metadata.task == .embedding)
    #expect(embedding.metadata.maxOutputTokens == nil)
    #expect(
        catalog.model(for: catalogConnection(baseURL: "https://api.openai.com/v1"), modelID: "gpt-4-unknown") == nil)

    let deepSeek = try #require(
        catalog.model(for: catalogConnection(baseURL: "https://api.deepseek.com/v1"), modelID: "deepseek-v4-pro"))
    let kimi = try #require(
        catalog.model(for: catalogConnection(baseURL: "https://api.moonshot.ai/v1"), modelID: "kimi-k3"))
    let kimiCode = try #require(
        catalog.model(for: catalogConnection(baseURL: "https://api.kimi.com/coding/v1"), modelID: "k3"))
    #expect(kimiCode.metadata.providerID == "kimi-for-coding")
    #expect(
        catalog.matchingProvider(for: catalogConnection(baseURL: "https://api.kimi.com/coding/v1/"))?.id
            == "kimi-for-coding")
    #expect(catalog.matchingProvider(for: catalogConnection(baseURL: "https://api.kimi.com/v1")) == nil)

    let priced = try #require(
        catalog.model(for: catalogConnection(baseURL: "https://api.openai.com/v1"), modelID: "gpt-5"))
    #expect(priced.metadata.pricing?.input == Decimal(string: "1.25"))
    #expect(priced.metadata.pricing?.output == Decimal(string: "10"))
    #expect(priced.metadata.pricing?.cacheRead == Decimal(string: "0.125"))
    #expect(priced.metadata.pricing?.baseURLs == ["https://api.openai.com/v1"])
    #expect(
        catalog.model(for: catalogConnection(baseURL: "https://api.anthropic.com/v1"), modelID: "claude-sonnet-4-6")?
            .metadata.pricing
            == ModelPricing(
                input: 3, output: 15, cacheRead: Decimal(string: "0.3"), baseURLs: ["https://api.anthropic.com/v1"]))
    #expect(
        catalog.model(for: catalogConnection(baseURL: "https://api.deepseek.com/v1"), modelID: "deepseek-v4-pro")?
            .metadata.pricing == nil)
}

@Test("Catalog matching requires exact canonical endpoints and supports only DeepSeek's /v1 alias")
func catalogEndpointMatching() {
    let catalog = ProviderModelCatalog.bundled
    #expect(catalog.matchingProvider(for: catalogConnection(baseURL: "HTTPS://API.OPENAI.COM:443/v1/"))?.id == "openai")
    #expect(catalog.matchingProvider(for: catalogConnection(baseURL: "https://api.openai.com/custom")) == nil)
    #expect(catalog.matchingProvider(for: catalogConnection(baseURL: "https://sub.api.openai.com/v1")) == nil)
    #expect(catalog.matchingProvider(for: catalogConnection(baseURL: "https://api.deepseek.com"))?.id == "deepseek")
    #expect(catalog.matchingProvider(for: catalogConnection(baseURL: "https://api.deepseek.com/"))?.id == "deepseek")
    #expect(catalog.matchingProvider(for: catalogConnection(baseURL: "https://api.deepseek.com/v1"))?.id == "deepseek")
    #expect(catalog.matchingProvider(for: catalogConnection(baseURL: "https://api.deepseek.com//v1")) == nil)
    #expect(catalog.matchingProvider(for: catalogConnection(baseURL: "https://api.deepseek.com/%76%31")) == nil)
    #expect(
        catalog.matchingProvider(for: catalogConnection(baseURL: "https://api.anthropic.com/v1"))?.id == "anthropic")
}

@Test("DeepSeek published pricing is endpoint and model scoped")
func deepSeekPublishedPricing() throws {
    let catalog = ProviderModelCatalog.bundled
    let connection = catalogConnection(baseURL: "https://api.deepseek.com/v1")
    let flash = try #require(catalog.publishedPricing(for: connection, modelID: "deepseek-v4-flash"))
    #expect(flash.inputMinimum == Decimal(string: "0.15"))
    #expect(flash.inputMaximum == Decimal(string: "0.30"))
    #expect(flash.outputMinimum == Decimal(string: "0.60"))
    #expect(flash.outputMaximum == Decimal(string: "1.20"))
    #expect(flash.cacheReadMinimum == Decimal(string: "0.003"))
    #expect(flash.cacheReadMaximum == Decimal(string: "0.006"))
    #expect(catalog.publishedPricing(for: connection, modelID: "deepseek-flash") == flash)
    #expect(catalog.publishedPricing(for: connection, modelID: "deepseek-v4-flash-vision-exp") == flash)

    let pro = try #require(catalog.publishedPricing(for: connection, modelID: "deepseek-v4-pro"))
    #expect(pro.inputMinimum == Decimal(string: "0.66"))
    #expect(pro.inputMaximum == Decimal(string: "1.32"))
    #expect(pro.outputMinimum == Decimal(string: "1.98"))
    #expect(pro.outputMaximum == Decimal(string: "3.96"))
    #expect(pro.cacheReadMinimum == Decimal(string: "0.022"))
    #expect(pro.cacheReadMaximum == Decimal(string: "0.044"))
    #expect(pro.sourceURL == "https://api-docs.deepseek.com/quick_start/pricing/")
    #expect(pro.checkedAt == "2026-09-14")

    let customEndpoint = AgentModelEndpoint(id: "gateway", configuration: .init(
        schema: HTTPConnectionSettings.schema.identity,
        value: .object(["baseURL": .string("https://private.example/v1"), "allowsLoopbackHTTP": .bool(false)])), credential: nil)
    let multiEndpoint = AgentConfiguredConnection(id: connection.id, revision: 1, configurationRevision: 1,
        name: connection.name, isEnabled: true, definitionID: connection.definitionID, endpoints: connection.endpoints + [customEndpoint],
        discovery: connection.discovery, defaultInvocation: connection.defaultInvocation)
    #expect(catalog.publishedPricing(for: multiEndpoint, modelID: "deepseek-flash",
        endpointID: connection.endpoints[0].id) == flash)
    #expect(catalog.publishedPricing(for: multiEndpoint, modelID: "deepseek-flash", endpointID: "gateway") == nil)
    #expect(catalog.publishedPricing(for: connection, modelID: "deepseek-flash", endpointID: "missing") == nil)

    #expect(catalog.publishedPricing(for: connection, modelID: "unknown") == nil)
    #expect(catalog.publishedPricing(
        for: catalogConnection(baseURL: "https://private.example/v1"), modelID: "deepseek-v4-pro") == nil)

    let flashModel = try #require(catalog.model(for: connection, modelID: "deepseek-v4-flash"))
    let proModel = try #require(catalog.model(for: connection, modelID: "deepseek-v4-pro"))
    #expect(flashModel.metadata.inputModalities.contains("image"))
    #expect(!proModel.metadata.inputModalities.contains("image"))
}

@Test("Malformed catalog snapshots are rejected and missing optional metadata stays unknown")
func malformedCatalogAndUnknownMetadata() throws {
    #expect(throws: ProviderModelCatalogError.malformed) {
        try ProviderModelCatalog(data: Data(#"{"providers":[]}"#.utf8))
    }
    let catalog = try ProviderModelCatalog(data: minimalCatalogJSON())
    let model = try #require(
        catalog.model(for: catalogConnection(baseURL: "https://fixture.test/v1"), modelID: "model"))
    #expect(model.metadata.contextWindow == nil)
    #expect(model.metadata.maxOutputTokens == nil)
    #expect(model.metadata.toolCall == nil)
}

@Test("Catalog pricing provenance is restricted to the registered provider endpoint")
func pricingProvenanceMatchesProviderEndpoint() throws {
    var object = try #require(JSONSerialization.jsonObject(with: minimalCatalogJSON()) as? [String: Any])
    var providers = try #require(object["providers"] as? [[String: Any]])
    var provider = try #require(providers.first)
    var models = try #require(provider["models"] as? [[String: Any]])
    var model = try #require(models.first)
    var metadata = try #require(model["metadata"] as? [String: Any])
    metadata["pricing"] = ["input": 1.0, "output": 2.0, "baseURLs": ["https://other.example/v1"]]
    model["metadata"] = metadata
    models[0] = model
    provider["models"] = models
    providers[0] = provider
    object["providers"] = providers
    let tampered = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ProviderModelCatalogError.malformed) {
        try ProviderModelCatalog(data: tampered)
    }

    metadata["task"] = "textGeneration"
    metadata["pricing"] = [
        "input": 1.0, "output": 2.0,
        "baseURLs": ["https://fixture.test/v1"],
        "maxInputTokens": 199_999,
    ]
    model["metadata"] = metadata
    models[0] = model
    provider["models"] = models
    providers[0] = provider
    object["providers"] = providers
    let scoped = try ProviderModelCatalog(data: JSONSerialization.data(withJSONObject: object))
    let scopedModel = try #require(
        scoped.model(for: catalogConnection(baseURL: "https://fixture.test/v1"), modelID: "model"))
    #expect(scopedModel.metadata.pricing?.maxInputTokens == 199_999)
}

@Test("Thinking-disabled OpenAI requests add only the approved top-level thinking object")
func thinkingDisabledRequestBody() async throws {
    let credentials = CatalogCredentials()
    let transport = CatalogTransport()
    let route = try adapterRoute(
        .deepSeek, baseURL: "https://api.deepseek.com/v1", modelID: "deepseek-v4-pro",
        contextWindow: 1_000_000, maximumOutputTokens: 1_024,
        thinking: .init(mode: .disabled))
    let adapter = HTTPModelAdapter(fixture: .deepSeek, credentials: credentials, transport: transport)
    _ = try await streamAdapter(adapter, input: adapterInput(), route: route)
    let body = try #require(transport.requests.first?.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect((object["thinking"] as? [String: String]) == ["type": "disabled"])
    #expect(object["max_tokens"] as? Int == 1_024)
    #expect(object["max_completion_tokens"] == nil)
    #expect(object["extra_body"] == nil)
    #expect(credentials.reads == 1)

    let standardTransport = CatalogTransport()
    let standardRoute = try adapterRoute(
        .standard, baseURL: "https://api.deepseek.com/v1", modelID: "deepseek-v4-pro",
        contextWindow: 1_000_000, maximumOutputTokens: 1_024)
    let standardAdapter = HTTPModelAdapter(
        fixture: .standard, credentials: CatalogCredentials(), transport: standardTransport)
    _ = try await streamAdapter(standardAdapter, input: adapterInput(), route: standardRoute)
    let standardBody = try #require(standardTransport.requests.first?.httpBody)
    let standardObject = try #require(JSONSerialization.jsonObject(with: standardBody) as? [String: Any])
    #expect(standardObject["thinking"] == nil)
}

@Test("Native OpenAI thinking uses developer instructions and completion-token controls")
func nativeOpenAIThinkingRequestBody() async throws {
    let credentials = CatalogCredentials()
    let transport = CatalogTransport()
    let route = try adapterRoute(
        .openAI, baseURL: "https://api.openai.com/v1", modelID: "gpt-5.1",
        contextWindow: 400_000, maximumOutputTokens: 2_048,
        thinking: .init(mode: .enabled, effort: .high))
    let adapter = HTTPModelAdapter(fixture: .openAI, credentials: credentials, transport: transport)
    _ = try await streamAdapter(adapter, input: adapterInput(), route: route)
    let body = try #require(transport.requests.first?.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try #require(object["messages"] as? [[String: Any]])
    #expect(messages.first?["role"] as? String == "developer")
    #expect(object["max_completion_tokens"] as? Int == 2_048)
    #expect(object["max_tokens"] == nil)
    #expect(object["reasoning_effort"] as? String == "high")
}

@Test("OpenRouter reasoning details retain arrival order and raw text replay")
func openRouterReasoningReplay() async throws {
    let detailStream = Data(
        #"""
        data: {"choices":[{"delta":{"reasoning_content":"plan","reasoning":"plan","reasoning_details":[{"type":"text","text":"plan"}]}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """#.utf8)
    let transport = CatalogTransport(responseBytes: detailStream)
    let route = try adapterRoute(
        .openRouter, baseURL: "https://openrouter.ai/api/v1", modelID: "openai/gpt-5",
        contextWindow: 400_000, maximumOutputTokens: 2_048)
    let adapter = HTTPModelAdapter(fixture: .openRouter, credentials: CatalogCredentials(), transport: transport)
    let events = try await streamAdapter(adapter, input: adapterInput(), route: route)
    let complete = try #require(
        thinkingSnapshots(events).last)
    #expect(complete.continuation?.format == "openrouter.details")
    #expect(complete.isComplete)
    #expect(complete.text == "plan")
    guard case .array(let blocks) = try #require(complete.continuation?.payload) else {
        Issue.record("OpenRouter continuation was not an array")
        return
    }
    #expect(blocks.count == 1)
    #expect(blocks[0]["type"]?.stringValue == "text")

    let aliasStream = Data(
        #"""
        data: {"choices":[{"delta":{"reasoning":"raw plan"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """#.utf8)
    let aliasTransport = CatalogTransport(responseBytes: aliasStream)
    let aliasAdapter = HTTPModelAdapter(
        fixture: .openRouter, credentials: CatalogCredentials(), transport: aliasTransport)
    let aliasEvents = try await streamAdapter(aliasAdapter, input: adapterInput(), route: route)
    let alias = try #require(
        thinkingSnapshots(aliasEvents).last)
    guard case .array(let aliasBlocks) = try #require(alias.continuation?.payload) else {
        Issue.record("OpenRouter alias continuation was not an array")
        return
    }
    #expect(aliasBlocks.isEmpty)
    #expect(alias.text == "raw plan")
    let replayInput = adapterInput(messages: [.init(role: .assistant, text: "answer", thinking: alias)])
    let replayTransport = CatalogTransport()
    let replayAdapter = HTTPModelAdapter(
        fixture: .openRouter, credentials: CatalogCredentials(), transport: replayTransport)
    _ = try await streamAdapter(replayAdapter, input: replayInput, route: route)
    let replayBody = try #require(replayTransport.requests.first?.httpBody)
    let replayObject = try #require(JSONSerialization.jsonObject(with: replayBody) as? [String: Any])
    let replayMessages = try #require(replayObject["messages"] as? [[String: Any]])
    #expect(replayMessages.last?["reasoning"] as? String == "raw plan")
}

@Test("Anthropic manual thinking sends an explicit budget and preserves ordered reasoning blocks")
func anthropicThinkingRequestAndReplay() async throws {
    let response = Data(
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{}}}\n\nevent: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"plan\"}}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig\"}}\n\nevent: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\nevent: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"answer\"}}\n\nevent: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
            .utf8)
    let transport = CatalogTransport(responseBytes: response)
    let route = try adapterRoute(
        .anthropic, baseURL: "https://api.anthropic.com/v1", modelID: "claude-sonnet-4-5",
        contextWindow: 200_000, maximumOutputTokens: 4_096,
        thinking: .init(mode: .enabled, budgetTokens: 2_048))
    let adapter = HTTPModelAdapter(fixture: .anthropic, credentials: CatalogCredentials(), transport: transport)
    let events = try await streamAdapter(adapter, input: adapterInput(), route: route)
    let body = try #require(transport.requests.first?.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect((object["thinking"] as? [String: Any])?["type"] as? String == "enabled")
    #expect((object["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 2_048)
    let thinking = try #require(
        thinkingSnapshots(events).last)
    #expect(thinking.isComplete)
    #expect(thinking.text == "plan")
    guard case .array(let blocks) = try #require(thinking.continuation?.payload) else {
        Issue.record("Anthropic continuation was not an array")
        return
    }
    #expect(blocks.count == 2)
    #expect(blocks[0]["type"]?.stringValue == "thinking")
    #expect(blocks[0]["signature"]?.stringValue == "sig")
    #expect(blocks[1]["type"]?.stringValue == "text")
    let replayInput = adapterInput(messages: [.init(role: .assistant, text: "answer", thinking: thinking)])
    let replayTransport = CatalogTransport(responseBytes: response)
    let replayAdapter = HTTPModelAdapter(
        fixture: .anthropic, credentials: CatalogCredentials(), transport: replayTransport)
    _ = try await streamAdapter(replayAdapter, input: replayInput, route: route)
    let replayBody = try #require(replayTransport.requests.first?.httpBody)
    let replayObject = try #require(JSONSerialization.jsonObject(with: replayBody) as? [String: Any])
    let messages = try #require(replayObject["messages"] as? [[String: Any]])
    #expect(messages.last?["content"] as? [[String: Any]] != nil)
}

@Test("Reasoning content is assembled even when a peer ignores the disabled control")
func unexpectedReasoningContentBoundary() async throws {
    let response = Data(
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"private reasoning\",\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"memory.search\",\"arguments\":\"{}\"}}]}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n"
            .utf8)
    let credentials = CatalogCredentials()
    let transport = CatalogTransport(responseBytes: response)
    let route = try adapterRoute(
        .deepSeek, baseURL: "https://api.deepseek.com/v1", modelID: "deepseek-v4-pro",
        contextWindow: 1_000_000, maximumOutputTokens: 1_024,
        thinking: .init(mode: .disabled))
    let adapter = HTTPModelAdapter(fixture: .deepSeek, credentials: credentials, transport: transport)
    let tools = [ToolDefinition(name: "memory.search", description: "Search", inputSchema: .object([:]))]
    let events = try await streamAdapter(adapter, input: adapterInput(tools: tools), route: route)
    let reasoning = thinkingSnapshots(events)
    #expect(reasoning.last?.text == "private reasoning")
    #expect(reasoning.last?.isComplete == true)
    #expect(containsToolCall(events, id: "call-1", name: "memory.search", arguments: "{}"))
}
