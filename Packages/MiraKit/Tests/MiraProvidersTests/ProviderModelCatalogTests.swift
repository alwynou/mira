import Foundation
import Testing
import MiraCore
@testable import MiraProviders

private func catalogConnection(
    _ kind: ProviderKind,
    baseURL: String,
    modelID: String = "gpt-4"
) -> ProviderConnection {
    ProviderConnection(name: "Fixture", providerKind: kind, baseURL: baseURL, credentialReference: "fixture")
}

private func minimalCatalogJSON() -> Data {
    Data(#"{"providers":[{"id":"fixture","name":"Fixture","baseURL":"https://fixture.test/v1","documentationURL":"https://fixture.test/docs","providerKind":"openAICompatible","models":[{"metadata":{"providerID":"fixture","modelID":"model","displayName":null,"sourceURL":"https://models.dev/api.json","sourceRevision":"sha256:test","retrievedAt":"2026-09-06T00:00:00Z","contextWindow":null,"maxOutputTokens":null,"inputModalities":[],"outputModalities":[],"toolCall":null,"structuredOutput":null,"reasoning":null,"requiresReasoningContinuation":false,"task":"unknown"},"suggestedProtocolMode":"standard"}]}]}"#.utf8)
}

private final class CatalogCredentials: CredentialReader, @unchecked Sendable {
    let value: String
    private(set) var reads = 0
    init(_ value: String = "fixture-secret") { self.value = value }
    func read(reference: String, version: Int) throws -> String { reads += 1; return value }
}

private final class CatalogTransport: HTTPStreamingTransport, @unchecked Sendable {
    let responseBytes: Data
    private(set) var requests: [URLRequest] = []
    init(responseBytes: Data? = nil) {
        self.responseBytes = responseBytes ?? Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)
    }
    func stream(request: URLRequest) -> AsyncThrowingStream<HTTPTransportEvent, any Error> {
        requests.append(request)
        return AsyncThrowingStream { continuation in
            continuation.yield(.response(HTTPTransportResponse(statusCode: 200)))
            continuation.yield(.bytes(responseBytes))
            continuation.yield(.end)
            continuation.finish()
        }
    }
}

@Test("Bundled catalog preserves provenance and reviewed protocol modes")
func bundledCatalogProvenanceAndModes() throws {
    let catalog = ProviderModelCatalog.bundled
    #expect(catalog.providers.map(\.id) == ["openai", "anthropic", "deepseek", "moonshotai-cn", "moonshotai", "siliconflow-cn", "siliconflow", "openrouter"])
    let openAI = try #require(catalog.model(for: catalogConnection(.openAICompatible, baseURL: "https://api.openai.com/v1"), modelID: "gpt-5.1"))
    #expect(openAI.metadata.sourceURL == "https://models.dev/api.json")
    #expect(openAI.metadata.sourceRevision.hasPrefix("sha256:"))
    #expect(!openAI.metadata.retrievedAt.isEmpty)
    #expect(openAI.suggestedProtocolMode == .openAI)
    #expect(catalog.model(for: catalogConnection(.openAICompatible, baseURL: "https://api.openai.com/v1"), modelID: "gpt-4")?.suggestedProtocolMode == .standard)
    let embedding = try #require(catalog.model(for: catalogConnection(.openAICompatible, baseURL: "https://api.openai.com/v1"), modelID: "text-embedding-3-small"))
    #expect(embedding.metadata.task == .embedding)
    #expect(embedding.metadata.maxOutputTokens == nil)
    #expect(catalog.model(for: catalogConnection(.openAICompatible, baseURL: "https://api.openai.com/v1"), modelID: "gpt-4-unknown") == nil)

    let deepSeek = try #require(catalog.model(for: catalogConnection(.openAICompatible, baseURL: "https://api.deepseek.com/v1"), modelID: "deepseek-v4-pro"))
    #expect(deepSeek.suggestedProtocolMode == .deepSeek)
    let kimi = try #require(catalog.model(for: catalogConnection(.openAICompatible, baseURL: "https://api.moonshot.ai/v1"), modelID: "kimi-k2-thinking"))
    #expect(kimi.suggestedProtocolMode == .kimi)

    let priced = try #require(catalog.model(for: catalogConnection(.openAICompatible, baseURL: "https://api.openai.com/v1"), modelID: "gpt-5"))
    #expect(priced.metadata.pricing?.input == Decimal(string: "1.25"))
    #expect(priced.metadata.pricing?.output == Decimal(string: "10"))
    #expect(priced.metadata.pricing?.cacheRead == Decimal(string: "0.125"))
    #expect(priced.metadata.pricing?.baseURLs == ["https://api.openai.com/v1"])
    #expect(catalog.model(for: catalogConnection(.openAICompatible, baseURL: "https://api.anthropic.com/v1"), modelID: "claude-sonnet-4-6")?.metadata.pricing == nil)
    #expect(catalog.model(for: catalogConnection(.openAICompatible, baseURL: "https://api.deepseek.com/v1"), modelID: "deepseek-v4-pro")?.metadata.pricing == nil)
}

@Test("Catalog matching requires exact canonical endpoints and supports only DeepSeek's /v1 alias")
func catalogEndpointMatching() {
    let catalog = ProviderModelCatalog.bundled
    #expect(catalog.matchingProvider(for: catalogConnection(.openAICompatible, baseURL: "HTTPS://API.OPENAI.COM:443/v1/"))?.id == "openai")
    #expect(catalog.matchingProvider(for: catalogConnection(.openAICompatible, baseURL: "https://api.openai.com/custom")) == nil)
    #expect(catalog.matchingProvider(for: catalogConnection(.openAICompatible, baseURL: "https://sub.api.openai.com/v1")) == nil)
    #expect(catalog.matchingProvider(for: catalogConnection(.openAICompatible, baseURL: "https://api.deepseek.com"))?.id == "deepseek")
    #expect(catalog.matchingProvider(for: catalogConnection(.openAICompatible, baseURL: "https://api.deepseek.com/"))?.id == "deepseek")
    #expect(catalog.matchingProvider(for: catalogConnection(.openAICompatible, baseURL: "https://api.deepseek.com/v1"))?.id == "deepseek")
    #expect(catalog.matchingProvider(for: catalogConnection(.openAICompatible, baseURL: "https://api.deepseek.com//v1")) == nil)
    #expect(catalog.matchingProvider(for: catalogConnection(.openAICompatible, baseURL: "https://api.deepseek.com/%76%31")) == nil)
    #expect(catalog.matchingProvider(for: catalogConnection(.anthropic, baseURL: "https://api.anthropic.com/v1"))?.id == "anthropic")
}

@Test("Malformed catalog snapshots are rejected and missing optional metadata stays unknown")
func malformedCatalogAndUnknownMetadata() throws {
    #expect(throws: ProviderModelCatalogError.malformed) {
        try ProviderModelCatalog(data: Data(#"{"providers":[]}"#.utf8))
    }
    let catalog = try ProviderModelCatalog(data: minimalCatalogJSON())
    let model = try #require(catalog.model(for: catalogConnection(.openAICompatible, baseURL: "https://fixture.test/v1"), modelID: "model"))
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
    let scopedModel = try #require(scoped.model(for: catalogConnection(.openAICompatible, baseURL: "https://fixture.test/v1"), modelID: "model"))
    #expect(scopedModel.metadata.pricing?.maxInputTokens == 199_999)
}

@Test("Thinking-disabled OpenAI requests add only the approved top-level thinking object")
func thinkingDisabledRequestBody() async throws {
    let credentials = CatalogCredentials()
    let transport = CatalogTransport()
    let provider = HTTPModelProvider(credentials: credentials, transport: transport)
    let route = ResolvedModelRouteSnapshot(
        name: "DeepSeek",
        providerKind: .openAICompatible,
        baseURL: "https://api.deepseek.com/v1",
        modelID: "deepseek-v4-pro",
        credentialReference: "fixture",
        contextWindow: 1_000_000,
        maxOutputTokens: 1_024,
        protocolMode: .deepSeek,
        thinking: ThinkingSettings(mode: .disabled)
    )
    let request = CanonicalModelRequest(executionID: ExecutionID(), system: "System", messages: [CanonicalMessage(role: .user, text: "Hello")])
    for try await _ in provider.stream(request: request, route: route) {}
    let body = try #require(transport.requests.first?.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect((object["thinking"] as? [String: String]) == ["type": "disabled"])
    #expect(object["extra_body"] == nil)
    #expect(credentials.reads == 1)

    let standardTransport = CatalogTransport()
    let standardProvider = HTTPModelProvider(credentials: CatalogCredentials(), transport: standardTransport)
    var standardRoute = route
    standardRoute.protocolMode = .standard
    standardRoute.thinking = ThinkingSettings()
    for try await _ in standardProvider.stream(request: request, route: standardRoute) {}
    let standardBody = try #require(standardTransport.requests.first?.httpBody)
    let standardObject = try #require(JSONSerialization.jsonObject(with: standardBody) as? [String: Any])
    #expect(standardObject["thinking"] == nil)
}

@Test("Native OpenAI thinking uses developer instructions and completion-token controls")
func nativeOpenAIThinkingRequestBody() async throws {
    let credentials = CatalogCredentials()
    let transport = CatalogTransport()
    let provider = HTTPModelProvider(credentials: credentials, transport: transport)
    let route = ResolvedModelRouteSnapshot(
        name: "OpenAI", providerKind: .openAICompatible, baseURL: "https://api.openai.com/v1",
        modelID: "gpt-5.1", credentialReference: "fixture", contextWindow: 400_000,
        maxOutputTokens: 2_048, protocolMode: .openAI,
        thinking: ThinkingSettings(mode: .enabled, effort: .high)
    )
    let request = CanonicalModelRequest(executionID: ExecutionID(), system: "System", messages: [CanonicalMessage(role: .user, text: "Hello")])
    for try await _ in provider.stream(request: request, route: route) {}
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
    let detailStream = Data(#"""
data: {"choices":[{"delta":{"reasoning_content":"plan","reasoning":"plan","reasoning_details":[{"type":"text","text":"plan"}]}}]}

data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

data: [DONE]

"""#.utf8)
    let transport = CatalogTransport(responseBytes: detailStream)
    let provider = HTTPModelProvider(credentials: CatalogCredentials(), transport: transport)
    let route = ResolvedModelRouteSnapshot(
        name: "OpenRouter", providerKind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1",
        modelID: "openai/gpt-5", credentialReference: "fixture", contextWindow: 400_000,
        maxOutputTokens: 2_048, protocolMode: .openRouter
    )
    let request = CanonicalModelRequest(executionID: ExecutionID(), system: "System", messages: [CanonicalMessage(role: .user, text: "Hello")])
    var events: [CanonicalStreamEvent] = []
    for try await event in provider.stream(request: request, route: route) { events.append(event) }
    let complete = try #require(events.compactMap { event -> ReasoningContent? in
        guard case .reasoning(let value) = event else { return nil }; return value
    }.last)
    #expect(complete.format == .openRouterDetails)
    #expect(complete.isComplete)
    #expect(complete.text == "plan")
    #expect(complete.blocks.count == 1)
    #expect(complete.blocks[0]["type"]?.stringValue == "text")

    let aliasStream = Data(#"""
data: {"choices":[{"delta":{"reasoning":"raw plan"}}]}

data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

data: [DONE]

"""#.utf8)
    let aliasTransport = CatalogTransport(responseBytes: aliasStream)
    let aliasProvider = HTTPModelProvider(credentials: CatalogCredentials(), transport: aliasTransport)
    var aliasEvents: [CanonicalStreamEvent] = []
    for try await event in aliasProvider.stream(request: request, route: route) { aliasEvents.append(event) }
    let alias = try #require(aliasEvents.compactMap { event -> ReasoningContent? in
        guard case .reasoning(let value) = event else { return nil }; return value
    }.last)
    #expect(alias.blocks.isEmpty)
    #expect(alias.text == "raw plan")
    var replay = request
    replay.messages = [CanonicalMessage(role: .assistant, text: "answer", reasoning: alias)]
    let replayTransport = CatalogTransport()
    let replayProvider = HTTPModelProvider(credentials: CatalogCredentials(), transport: replayTransport)
    for try await _ in replayProvider.stream(request: replay, route: route) {}
    let replayBody = try #require(replayTransport.requests.first?.httpBody)
    let replayObject = try #require(JSONSerialization.jsonObject(with: replayBody) as? [String: Any])
    let replayMessages = try #require(replayObject["messages"] as? [[String: Any]])
    #expect(replayMessages.last?["reasoning"] as? String == "raw plan")
}

@Test("Anthropic manual thinking sends an explicit budget and preserves ordered reasoning blocks")
func anthropicThinkingRequestAndReplay() async throws {
    let response = Data("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{}}}\n\nevent: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"plan\"}}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig\"}}\n\nevent: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\nevent: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"answer\"}}\n\nevent: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8)
    let transport = CatalogTransport(responseBytes: response)
    let provider = HTTPModelProvider(credentials: CatalogCredentials(), transport: transport)
    let route = ResolvedModelRouteSnapshot(
        name: "Claude", providerKind: .anthropic, baseURL: "https://api.anthropic.com/v1", modelID: "claude-sonnet-4-5",
        credentialReference: "fixture", contextWindow: 200_000, maxOutputTokens: 4_096,
        protocolMode: .anthropicManual, thinking: ThinkingSettings(mode: .enabled, budgetTokens: 2_048)
    )
    var request = CanonicalModelRequest(executionID: ExecutionID(), system: "System", messages: [CanonicalMessage(role: .user, text: "Hello")])
    var events: [CanonicalStreamEvent] = []
    for try await event in provider.stream(request: request, route: route) { events.append(event) }
    let body = try #require(transport.requests.first?.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect((object["thinking"] as? [String: Any])?["type"] as? String == "enabled")
    #expect((object["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 2_048)
    let reasoning = try #require(events.compactMap { event -> ReasoningContent? in
        guard case .reasoning(let value) = event else { return nil }; return value
    }.last)
    #expect(reasoning.isComplete)
    #expect(reasoning.text == "plan")
    #expect(reasoning.blocks.count == 2)
    #expect(reasoning.blocks[0]["type"]?.stringValue == "thinking")
    #expect(reasoning.blocks[0]["signature"]?.stringValue == "sig")
    #expect(reasoning.blocks[1]["type"]?.stringValue == "text")
    request.messages = [CanonicalMessage(role: .assistant, text: "answer", reasoning: reasoning)]
    let replayTransport = CatalogTransport(responseBytes: response)
    let replayProvider = HTTPModelProvider(credentials: CatalogCredentials(), transport: replayTransport)
    for try await _ in replayProvider.stream(request: request, route: route) {}
    let replayBody = try #require(replayTransport.requests.first?.httpBody)
    let replayObject = try #require(JSONSerialization.jsonObject(with: replayBody) as? [String: Any])
    let messages = try #require(replayObject["messages"] as? [[String: Any]])
    #expect(messages.last?["content"] as? [[String: Any]] != nil)
}

@Test("Reasoning content is assembled even when a peer ignores the disabled control")
func unexpectedReasoningContentBoundary() async throws {
    let response = Data("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"private reasoning\",\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"memory.search\",\"arguments\":\"{}\"}}]}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n".utf8)
    let credentials = CatalogCredentials()
    let transport = CatalogTransport(responseBytes: response)
    let provider = HTTPModelProvider(credentials: credentials, transport: transport)
    var route = ResolvedModelRouteSnapshot(
        name: "DeepSeek",
        providerKind: .openAICompatible,
        baseURL: "https://api.deepseek.com/v1",
        modelID: "deepseek-v4-pro",
        credentialReference: "fixture",
        contextWindow: 1_000_000,
        maxOutputTokens: 1_024,
        protocolMode: .deepSeek,
        thinking: ThinkingSettings(mode: .disabled)
    )
    route.toolCapability = .verified
    let request = CanonicalModelRequest(
        executionID: ExecutionID(), system: "System",
        messages: [CanonicalMessage(role: .user, text: "Hello")],
        tools: [ToolDefinition(name: "memory.search", description: "Search", inputSchema: .object([:]))]
    )
    var events: [CanonicalStreamEvent] = []
    for try await event in provider.stream(request: request, route: route) { events.append(event) }
    let reasoning = events.compactMap { event -> ReasoningContent? in
        guard case .reasoning(let value) = event else { return nil }
        return value
    }
    #expect(reasoning.last?.text == "private reasoning")
    #expect(reasoning.last?.isComplete == true)
    #expect(events.contains(.toolCalls([CanonicalToolCall(id: "call-1", name: "memory.search", arguments: "{}")])) == true)
    #expect(credentials.reads == 1)
    #expect(transport.requests.count == 1)
}
