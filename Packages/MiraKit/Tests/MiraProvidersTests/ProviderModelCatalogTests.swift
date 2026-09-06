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
    let openAI = try #require(catalog.model(for: catalogConnection(.openAICompatible, baseURL: "https://api.openai.com/v1"), modelID: "gpt-4"))
    #expect(openAI.metadata.sourceURL == "https://models.dev/api.json")
    #expect(openAI.metadata.sourceRevision.hasPrefix("sha256:"))
    #expect(!openAI.metadata.retrievedAt.isEmpty)
    #expect(openAI.suggestedProtocolMode == .standard)
    let embedding = try #require(catalog.model(for: catalogConnection(.openAICompatible, baseURL: "https://api.openai.com/v1"), modelID: "text-embedding-3-small"))
    #expect(embedding.metadata.task == .embedding)
    #expect(embedding.metadata.maxOutputTokens == nil)
    #expect(catalog.model(for: catalogConnection(.openAICompatible, baseURL: "https://api.openai.com/v1"), modelID: "gpt-4-unknown") == nil)

    let deepSeek = try #require(catalog.model(for: catalogConnection(.openAICompatible, baseURL: "https://api.deepseek.com/v1"), modelID: "deepseek-v4-pro"))
    #expect(deepSeek.suggestedProtocolMode == .thinkingDisabled)
    let kimi = try #require(catalog.model(for: catalogConnection(.openAICompatible, baseURL: "https://api.moonshot.ai/v1"), modelID: "kimi-k2-thinking"))
    #expect(kimi.suggestedProtocolMode == .unsupportedReasoning)
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
        protocolMode: .thinkingDisabled
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
    for try await _ in standardProvider.stream(request: request, route: standardRoute) {}
    let standardBody = try #require(standardTransport.requests.first?.httpBody)
    let standardObject = try #require(JSONSerialization.jsonObject(with: standardBody) as? [String: Any])
    #expect(standardObject["thinking"] == nil)
}

@Test("Unsupported reasoning is rejected before credentials are read")
func unsupportedReasoningBoundary() async throws {
    let credentials = CatalogCredentials()
    let transport = CatalogTransport()
    let provider = HTTPModelProvider(credentials: credentials, transport: transport)
    let route = ResolvedModelRouteSnapshot(
        name: "Kimi",
        providerKind: .openAICompatible,
        baseURL: "https://api.moonshot.ai/v1",
        modelID: "kimi-k2-thinking",
        credentialReference: "fixture",
        contextWindow: 262_144,
        maxOutputTokens: 1_024,
        protocolMode: .unsupportedReasoning
    )
    do {
        for try await _ in provider.stream(request: CanonicalModelRequest(executionID: ExecutionID(), system: "", messages: [CanonicalMessage(role: .user, text: "Hello")]), route: route) {}
        Issue.record("expected unsupported reasoning failure")
    } catch let error as MiraError {
        #expect(error.code == .unsupported)
    }
    #expect(credentials.reads == 0)
    #expect(transport.requests.isEmpty)
}

@Test("Reasoning content from a peer is rejected without exposing it or yielding tool events")
func unexpectedReasoningContentBoundary() async throws {
    let response = Data("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"private reasoning\",\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"memory.search\",\"arguments\":\"{}\"}}]}}]}\n\n".utf8)
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
        protocolMode: .thinkingDisabled
    )
    route.toolCapability = .verified
    let request = CanonicalModelRequest(
        executionID: ExecutionID(), system: "System",
        messages: [CanonicalMessage(role: .user, text: "Hello")],
        tools: [ToolDefinition(name: "memory.search", description: "Search", inputSchema: .object([:]))]
    )
    var events: [CanonicalStreamEvent] = []
    do {
        for try await event in provider.stream(request: request, route: route) { events.append(event) }
        Issue.record("expected unsupported reasoning failure")
    } catch let error as MiraError {
        #expect(error.code == .unsupported)
        #expect(!error.message.contains("private reasoning"))
    }
    #expect(events.isEmpty)
    #expect(credentials.reads == 1)
    #expect(transport.requests.count == 1)
}
