import Foundation
import MiraCore
import Testing
@testable import MiraProviders

@Suite("Public model metadata", .timeLimit(.minutes(1)))
struct ModelsDevMetadataSourceTests {
    @Test func normalizationKeepsReviewedEndpointsAndDynamicControls() throws {
        let catalog = try normalized()
        for provider in catalog.providers {
            let bundled = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == provider.id })
            #expect(provider.baseURL == bundled.baseURL)
            #expect(provider.protocolID == bundled.protocolID)
            let model = try #require(provider.model(id: "future-model"))
            #expect(model.metadata.maxInputTokens == 6000)
            #expect(model.metadata.reasoningOptions.first?.values == ["low", "future-effort"])
            #expect(model.metadata.requiresReasoningContinuation == false)
        }
    }

    @Test func malformedContinuationAndLimitsCannotPublishACatalog() throws {
        for change in [JSONValue.object(["interleaved": .object([:])]),
                       .object(["limit": .object(["context": .bool(true)])])] {
            #expect(throws: (any Error).self) {
                try ModelsDevCatalogNormalizer.normalize(source(overrides: change), sourceRevision: "fixture", observedAt: stamp)
            }
        }
    }

    @Test func fetchIsPublicOnlyAndDrainsOnSuccessAndPrematureEOF() async throws {
        let body = try source()
        let transport = MetadataTransport(events: [.response(.init(statusCode: 200)), .bytes(body), .end])
        let operation = ModelsDevMetadataSource(transport: transport, now: { stamp }).fetch()
        let document = try await operation.result()
        await operation.close()
        #expect(document.sourceRevision.hasPrefix("sha256:"))
        #expect(transport.closeCount == 1)
        let request = try #require(transport.request)
        #expect(request.url?.absoluteString == "https://models.dev/api.json")
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let partial = MetadataTransport(events: [.response(.init(statusCode: 200)), .bytes(body)])
        let failed = ModelsDevMetadataSource(transport: partial).fetch()
        await #expect(throws: MiraError.self) { try await failed.result() }
        await failed.close()
        #expect(partial.closeCount == 1)
    }

    @Test func unknownModelCanBeEnabledBeforeContextMetadataArrives() throws {
        let catalog = try normalized()
        let provider = try #require(catalog.providers.first { $0.id == "openai" })
        let connection = try provider.makeConnection(credential: nil)
        let configured = try catalog.configuration(connection: connection, modelID: "official-new-id")
        try configured.model.validate()
        #expect(configured.model.isEnabled)
        #expect(configured.model.modelID == "official-new-id")
        #expect(configured.model.invocations[0].contextWindow == nil)
        #expect(throws: MiraError.self) {
            try AgentModelRouteCandidate(connection: connection, model: configured.model, preset: configured.preset).validate()
        }
    }

    @Test func refreshPreservesUserFactsAndSelectedProtocolAndLeavesPrivateEndpointsAlone() throws {
        let catalog = try normalized()
        let provider = try #require(catalog.providers.first { $0.id == "openai" })
        let connection = try provider.makeConnection(credential: .init(reference: "fixture-reference", version: 1))
        let initial = try catalog.configuration(connection: connection, modelID: "future-model")
        let old = initial.model
        let user = AgentModelMetadataFact(field: AgentModelMetadataField.contextWindow, value: .number(12000),
                                         source: .user, sourceID: "settings", sourceRevision: "1", observedAt: stamp,
                                         invocationID: old.invocations[0].id)
        let configured = AgentConfiguredModel(id: old.id, revision: old.revision,
            authorizationRevision: old.authorizationRevision, reference: old.reference, displayName: "My model",
            isEnabled: true, invocations: old.invocations, facts: old.facts + [user])
        let payload = try ModelsDevCatalogNormalizer.normalize(source(overrides: .object([
            "limit": .object(["context": .number(24000), "output": .number(4000)]),
            "provider": .object(["shape": .string("completions")])])), sourceRevision: "new", observedAt: stamp)
        let document = AgentModelMetadataDocument(schema: .init(id: "mira.provider-catalog", revision: 2),
            sourceRevision: "new", observedAt: stamp, payload: payload)
        let update = try #require(ModelsDevMetadataSource().updates(document: document, connections: [connection], models: [configured]).first)
        #expect(update.updated.displayName == "My model")
        #expect(update.updated.authorizationRevision == old.authorizationRevision)
        #expect(update.updated.invocations[0].adapter == old.invocations[0].adapter)
        #expect(update.updated.invocations[0].endpointID == old.invocations[0].endpointID)
        #expect(update.updated.facts.contains(user))
        #expect(try AgentModelMetadataResolver.resolve(update.updated.invocations[0], facts: update.updated.facts).contextWindow == 12000)

        let privateConnection = try provider.makeConnection(credential: nil, baseURL: "https://private.example/v1")
        let privateModel = try catalog.configuration(connection: privateConnection, modelID: "future-model").model
        #expect(try ModelsDevMetadataSource().updates(document: document, connections: [privateConnection], models: [privateModel]).isEmpty)
    }

    @Test func unsupportedBudgetRangeDoesNotExpandProviderLimits() {
        let schema = CatalogModel.parameterSchema(options: [.init(type: "budget_tokens", min: -1, max: 512)], protocolID: .anthropicMessages)
        #expect(schema["properties"]?["thinking"]?["properties"]?["budgetTokens"] == nil)
    }

    private func normalized() throws -> ProviderModelCatalog {
        try ProviderModelCatalog(data: SessionCodec.encode(ModelsDevCatalogNormalizer.normalize(source(), sourceRevision: "fixture", observedAt: stamp)))
    }
    private func source(overrides: JSONValue = .object([:])) throws -> Data {
        var model: [String: JSONValue] = ["id": .string("future-model"), "name": .string("Future model"),
            "limit": .object(["context": .number(8192), "input": .number(6000), "output": .number(2048)]),
            "modalities": .object(["input": .array([.string("text")]), "output": .array([.string("text")])]),
            "reasoning": .bool(true), "tool_call": .bool(true), "interleaved": .null,
            "reasoning_options": .array([.object(["type": .string("effort"), "values": .array([.null, .string("low"), .string("future-effort")])])]),
            "provider": .object(["api": .string("https://untrusted.example")])]
        if case .object(let fields) = overrides { model.merge(fields) { _, new in new } }
        let providers = Dictionary(uniqueKeysWithValues: ProviderModelCatalog.bundled.providers.map { provider in
            (provider.id, JSONValue.object(["id": .string(provider.id), "api": .string("https://untrusted.example"),
                                           "models": .object(["future-model": .object(model)])]))
        })
        return try SessionCodec.encode(JSONValue.object(providers))
    }
}

private let stamp = Date(timeIntervalSince1970: 1_800_000_000)

private final class MetadataTransport: HTTPStreamingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let events: [HTTPTransportEvent]
    private var recorded: URLRequest?
    private var closed = 0
    var request: URLRequest? { lock.withLock { recorded } }
    var closeCount: Int { lock.withLock { closed } }
    init(events: [HTTPTransportEvent]) { self.events = events }
    func stream(request: URLRequest) -> HTTPTransportOperation {
        lock.withLock { recorded = request }
        return .init(events: .init { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }, cancelAndDrain: { self.lock.withLock { self.closed += 1 } })
    }
}
