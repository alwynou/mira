import Foundation
import CryptoKit
import MiraCore

/// Downloads a public catalog without access to model credentials or private identifiers.
public struct ModelsDevMetadataSource: AgentModelMetadataProvider {
    public static let sourceID = "mira.models-dev"
    public let identity = AgentAdapterIdentity(id: sourceID, revision: 1)
    private let transport: any HTTPStreamingTransport
    private let now: @Sendable () -> Date
    public init(transport: any HTTPStreamingTransport = URLSessionStreamingTransport(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport; self.now = now
    }
    public func fetch() -> AgentModelMetadataOperation {
        var request = URLRequest(url: URL(string: "https://models.dev/api.json")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let operation = transport.stream(request: request)
        let task = Task {
            do {
                var body = Data(), responseSeen = false, ended = false
                for try await event in operation.events {
                    try Task.checkCancellation()
                    guard !ended else { throw Self.invalid }
                    switch event {
                    case .response(let response):
                        guard !responseSeen, (200..<300).contains(response.statusCode) else {
                            throw MiraError(.network, "The public model metadata source could not be refreshed.")
                        }
                        responseSeen = true
                    case .bytes(let data):
                        guard responseSeen, data.count <= 16_777_216 - body.count else {
                            throw MiraError(.outputLimit, "The public model metadata response exceeded its limit.")
                        }
                        body.append(data)
                    case .end: guard responseSeen else { throw Self.invalid }; ended = true
                    }
                }
                guard ended else { throw Self.invalid }
                let revision = "sha256:" + SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
                let observed = now()
                let payload = try ModelsDevCatalogNormalizer.normalize(body, sourceRevision: revision, observedAt: observed)
                let document = AgentModelMetadataDocument(schema: .init(id: "mira.provider-catalog", revision: 2),
                                                         sourceRevision: revision, observedAt: observed, payload: payload)
                try document.validate()
                await operation.close()
                return document
            } catch {
                await operation.close()
                if error is CancellationError { throw MiraError(.cancelled, "The model metadata refresh was cancelled.") }
                throw error as? MiraError ?? MiraError(.network, "The public model metadata source could not be refreshed.")
            }
        }
        return .init(producer: task, cancelAndDrain: { await operation.close() })
    }
    public func updates(document: AgentModelMetadataDocument, connections: [AgentConfiguredConnection],
                        models: [AgentConfiguredModel]) throws -> [AgentModelMetadataUpdate] {
        guard document.schema == .init(id: "mira.provider-catalog", revision: 2) else { throw Self.invalid }
        let catalog = try ProviderModelCatalog(data: SessionCodec.encode(document.payload))
        let connections = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
        return try models.compactMap { model in
            guard let connection = connections[model.connectionID], model.revision < Int.max else { return nil }
            var specs: [AgentModelInvocationSpec] = []
            var facts = model.facts
            var changed = false
            for old in model.invocations {
                guard old.configuration.schema == .init(id: "mira.http.invocation", revision: 2),
                    let metadata = catalog.model(for: connection, modelID: model.modelID, endpointID: old.endpointID) else {
                    specs.append(old)
                    continue
                }
                guard old.revision < Int.max else { throw Self.invalid }
                // Reuse the already selected adapter, endpoint and dialect. No remote protocol recommendation redirects a saved model.
                let explicitConnection = AgentConfiguredConnection(
                    id: connection.id, revision: connection.revision, configurationRevision: connection.configurationRevision,
                    name: connection.name, isEnabled: connection.isEnabled, definitionID: connection.definitionID,
                    endpoints: connection.endpoints, discovery: connection.discovery,
                    defaultInvocation: .init(adapter: old.adapter, endpointID: old.endpointID, configuration: old.configuration))
                let fresh = try metadata.invocation(connection: explicitConnection, id: old.id)
                specs.append(.init(id: old.id, revision: old.revision + 1, adapter: old.adapter, endpointID: old.endpointID,
                                   contextWindow: fresh.contextWindow, maximumOutputTokens: fresh.maximumOutputTokens,
                                   capabilities: fresh.capabilities, configuration: fresh.configuration,
                                   parameterSchema: fresh.parameterSchema, maximumInputTokens: fresh.maximumInputTokens))
                facts.removeAll { $0.source == .catalog && $0.invocationID == old.id }
                facts += try metadata.metadataFacts(invocationID: old.id)
                changed = true
            }
            guard changed else { return nil }
            let updated = AgentConfiguredModel(id: model.id, revision: model.revision + 1,
                                               authorizationRevision: model.authorizationRevision, reference: model.reference,
                                               displayName: model.displayName, isEnabled: model.isEnabled, invocations: specs, facts: facts)
            let update = AgentModelMetadataUpdate(connection: connection, previous: model, updated: updated)
            try update.validate()
            return update
        }
    }
    private static var invalid: MiraError { .init(.malformedStream, "The public model metadata response is invalid or incomplete.") }
}

/// A whitelist normalization boundary. api/npm/body/headers are never copied from the remote document.
public enum ModelsDevCatalogNormalizer {
    public static func normalize(_ bytes: Data, sourceRevision: String, observedAt: Date) throws -> JSONValue {
        guard bytes.count <= 16_777_216,
            case .object(let source) = try SessionCodec.decode(JSONValue.self, from: bytes) else { throw invalid }
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: observedAt)
        var providers: [JSONValue] = []
        for definition in ProviderModelCatalog.bundled.providers {
            guard case .object(let raw) = source[definition.id],
                string(raw["id"]) == definition.id, case .object(let models) = raw["models"],
                models.count <= 2_000 else { throw invalid }
            var normalized: [JSONValue] = []
            for (id, value) in models.sorted(by: { $0.key < $1.key }) {
                guard case .object(let model) = value, string(model["id"]) == id,
                    case .object(let limits) = model["limit"], case .object(let modalities) = model["modalities"] else { throw invalid }
                let input = try strings(modalities["input"]), output = try strings(modalities["output"])
                let task: CatalogModelTask
                if string(model["family"]) == "text-embedding" { task = .embedding }
                else if output.contains("audio") { task = .audio }
                else if output.contains("image") { task = .imageGeneration }
                else if output.contains("text") { task = .textGeneration }
                else { task = .unknown }
                let options = try controls(model["reasoning_options"])
                let pricing = try price(model["cost"], definition: definition, task: task)
                let metadata = CatalogModelMetadata(
                    providerID: definition.id, modelID: id, displayName: string(model["name"]),
                    sourceURL: "https://models.dev/api.json", sourceRevision: sourceRevision, retrievedAt: stamp,
                    contextWindow: try limit(limits["context"]), maxOutputTokens: task == .textGeneration ? try limit(limits["output"]) : nil,
                    inputModalities: input, outputModalities: output, toolCall: try boolean(model["tool_call"]),
                    structuredOutput: try boolean(model["structured_output"]), reasoning: try boolean(model["reasoning"]),
                    requiresReasoningContinuation: try continuation(model["interleaved"]),
                    task: task, pricing: pricing, baseModelID: string(model["base_model"]), lifecycle: string(model["status"]),
                    reasoningOptions: options, maxInputTokens: try limit(limits["input"]))
                try metadata.validate()
                var protocolID = definition.protocolID
                if definition.id == "openai", model["provider"]?["shape"] == .string("completions") { protocolID = .chatCompletions }
                normalized.append(.object(["metadata": try json(metadata), "protocolID": .string(protocolID.rawValue),
                                           "dialectProfileID": .string(definition.dialectProfileID.rawValue)]))
            }
            providers.append(.object(["id": .string(definition.id), "name": .string(definition.name),
                "baseURL": .string(definition.baseURL), "documentationURL": .string(definition.documentationURL),
                "discoveryProtocol": try json(definition.discoveryProtocol), "protocolID": .string(definition.protocolID.rawValue),
                "dialectProfileID": .string(definition.dialectProfileID.rawValue), "models": .array(normalized)]))
        }
        let payload = JSONValue.object(["providers": .array(providers)])
        _ = try ProviderModelCatalog(data: SessionCodec.encode(payload))
        return payload
    }
    private static func controls(_ value: JSONValue?) throws -> [CatalogReasoningOption] {
        guard let value else { return [] }
        guard case .array(let array) = value, array.count <= 8 else { throw invalid }
        return try array.compactMap { value in
            guard let type = string(value["type"]) else { throw invalid }
            switch type {
            case "toggle": return .init(type: type)
            case "effort":
                guard case .array(let values) = value["values"] else { throw invalid }
                let strings = try values.compactMap { item -> String? in
                    if item == .null { return nil }
                    guard let value = string(item) else { throw invalid }
                    return value
                }
                return .init(type: type, values: strings)
            case "budget_tokens": return .init(type: type, min: try budget(value["min"]), max: try budget(value["max"]))
            default: return nil
            }
        }
    }
    private static func price(_ value: JSONValue?, definition: CatalogProvider, task: CatalogModelTask) throws -> ModelPricing? {
        guard let value, task == .textGeneration, definition.id != "kimi-for-coding" else { return nil }
        guard case .object(let cost) = value else { throw invalid }
        if cost["reasoning"] != nil || cost["input_audio"] != nil || cost["output_audio"] != nil { return nil }
        guard let input = try rate(cost["input"]), let output = try rate(cost["output"]) else { return nil }
        var maximumInput: Int?
        if let tiers = cost["tiers"] {
            guard case .array(let values) = tiers, values.count <= 32 else { throw invalid }
            for tier in values {
                guard tier["tier"]?["type"] == .string("context"), let size = try limit(tier["tier"]?["size"]) else { throw invalid }
                guard size > 1 else { return nil }
                maximumInput = min(maximumInput ?? Int.max, size - 1)
            }
        }
        if cost["context_over_200k"] != nil { maximumInput = min(maximumInput ?? Int.max, 199_999) }
        let addresses = definition.id == "deepseek" ? [definition.baseURL, definition.baseURL + "/v1"] : [definition.baseURL]
        return .init(input: input, output: output, cacheRead: try rate(cost["cache_read"]), baseURLs: addresses, maxInputTokens: maximumInput)
    }
    private static func rate(_ value: JSONValue?) throws -> Decimal? {
        guard let value else { return nil }
        guard case .number(let number) = value, number.isFinite, number >= 0, number <= 1_000_000 else { throw invalid }
        return Decimal(string: String(number))
    }
    private static func string(_ value: JSONValue?) -> String? { if case .string(let value) = value { value } else { nil } }
    private static func strings(_ value: JSONValue?) throws -> [String] {
        guard let value else { return [] }
        guard case .array(let values) = value, values.count <= 32 else { throw invalid }
        return try values.map { guard let value = string($0) else { throw invalid }; return value }
    }
    private static func boolean(_ value: JSONValue?) throws -> Bool? {
        guard let value, value != .null else { return nil }
        guard case .bool(let flag) = value else { throw invalid }; return flag
    }
    private static func budget(_ value: JSONValue?) throws -> Int? {
        guard let value else { return nil }
        guard case .number(let number) = value, number.rounded() == number, (-1...10_000_000).contains(number) else { throw invalid }
        return Int(number)
    }
    private static func continuation(_ value: JSONValue?) throws -> Bool {
        guard let value, value != .null, value != .bool(false) else { return false }
        if value == .bool(true) { return true }
        guard case .object = value, let field = string(value["field"]), !field.isEmpty, field.utf8.count <= 64 else { throw invalid }
        return true
    }
    private static func limit(_ value: JSONValue?) throws -> Int? {
        guard let value, value != .null else { return nil }
        guard case .number(let number) = value, number.rounded() == number, (0...10_000_000).contains(number) else { throw invalid }
        return number == 0 ? nil : Int(number)
    }
    private static func json<T: Encodable>(_ value: T) throws -> JSONValue { try SessionCodec.decode(JSONValue.self, from: SessionCodec.encode(value)) }
    private static var invalid: MiraError { .init(.configuration, "The public model catalog contains invalid metadata.") }
}
