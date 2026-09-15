import Foundation
import MiraCore

public extension HTTPProtocolID {
    var adapterIdentity: AgentAdapterIdentity {
        get throws {
            switch self {
            case .chatCompletions: HTTPAdapterIdentity.chatCompletions
            case .anthropicMessages: HTTPAdapterIdentity.anthropicMessages
            case .responses: HTTPAdapterIdentity.responses
            default: throw MiraError(.unsupported, "The selected model protocol implementation is not installed.")
            }
        }
    }
}

public extension CatalogProvider {
    func makeConnection(id: ConnectionID = .init(), name: String? = nil,
                        credential: AgentCredentialReference?, baseURL: String? = nil,
                        allowsLoopbackHTTP: Bool = false) throws -> AgentConfiguredConnection {
        let endpoint = AgentModelEndpoint(
            id: "primary", configuration: .init(schema: HTTPConnectionSettings.schema.identity,
                value: try json(HTTPConnectionSettings(baseURL: baseURL ?? self.baseURL,
                                                       allowsLoopbackHTTP: allowsLoopbackHTTP))), credential: credential)
        let template = AgentModelInvocationTemplate(
            adapter: try protocolID.adapterIdentity, endpointID: endpoint.id,
            configuration: .init(schema: .init(id: "mira.http.invocation", revision: 2),
                value: try json(HTTPInvocationSettings(protocolID: protocolID, dialectProfileID: dialectProfileID))))
        let value = AgentConfiguredConnection(
            id: id, revision: 1, configurationRevision: 1, name: name ?? self.name, isEnabled: true,
            definitionID: self.id, endpoints: [endpoint],
            discovery: .init(adapter: discoveryProtocol.identity, endpointID: endpoint.id), defaultInvocation: template)
        try value.validate()
        return value
    }
}

public extension CatalogModel {
    func invocation(connection: AgentConfiguredConnection, id: String = "default") throws -> AgentModelInvocationSpec {
        guard let template = connection.defaultInvocation else {
            throw MiraError(.configuration, "Choose a default protocol for this provider connection.")
        }
        let base = try SessionCodec.decode(HTTPInvocationSettings.self, from: SessionCodec.encode(template.configuration.value))
        // A catalog association provides parameters only for this exact serving protocol.
        let sameProtocol = base.protocolID == protocolID && base.dialectProfileID == dialectProfileID
        let options = sameProtocol ? metadata.reasoningOptions : []
        let pricing: HTTPModelPricingSnapshot? = metadata.pricing == nil ? nil : try .init(catalog: metadata)
        let settings = HTTPInvocationSettings(protocolID: base.protocolID, dialectProfileID: base.dialectProfileID,
                                              requestsUsage: base.requestsUsage, thinking: base.thinking, pricing: pricing)
        var capabilities: [String: CapabilityState] = [:]
        if metadata.task == .textGeneration { capabilities[AgentModelCapabilityID.streamingText] = .declared }
        for (id, supported) in [(AgentModelCapabilityID.toolCalls, metadata.toolCall),
                                (AgentModelCapabilityID.thinking, metadata.reasoning),
                                (AgentModelCapabilityID.jsonOutput, metadata.structuredOutput)] {
            if let supported { capabilities[id] = supported ? .declared : .failed }
        }
        let spec = AgentModelInvocationSpec(
            id: id, revision: 1, adapter: template.adapter, endpointID: template.endpointID,
            contextWindow: metadata.contextWindow, maximumOutputTokens: metadata.maxOutputTokens,
            capabilities: capabilities,
            configuration: .init(schema: template.configuration.schema, value: try json(settings)),
            parameterSchema: Self.parameterSchema(options: options, protocolID: base.protocolID), maximumInputTokens: metadata.maxInputTokens)
        try spec.validate()
        return spec
    }

    static func parameterSchema(options: [CatalogReasoningOption], protocolID: HTTPProtocolID) -> JSONValue {
        var modes = ["providerDefault"]
        var properties: [String: JSONValue] = [:]
        let efforts = options.filter { $0.type == "effort" }.flatMap { $0.values ?? [] }
        if !efforts.isEmpty {
            properties["effort"] = .object(["type": .string("string"), "enum": .array(efforts.map(JSONValue.string))])
            modes.append(protocolID == .anthropicMessages ? "adaptive" : "enabled")
        }
        if options.contains(where: { $0.type == "toggle" }) { modes += ["enabled", "disabled"] }
        if let budget = options.first(where: { $0.type == "budget_tokens" }) {
            // Negative provider sentinels require a separate semantic rule, never a fake positive budget.
            let minimum = max(1_024, budget.min ?? 1_024)
            let maximum = min(10_000_000, budget.max ?? 10_000_000)
            if minimum <= maximum {
                properties["budgetTokens"] = .object([
                    "type": .string("integer"), "minimum": .number(Double(minimum)), "maximum": .number(Double(maximum))])
                modes.append("enabled")
            }
        }
        properties["mode"] = .object(["type": .string("string"), "enum": .array(Array(Set(modes)).sorted().map(JSONValue.string))])
        return .object(["type": .string("object"), "properties": .object([
            "thinking": .object(["type": .string("object"), "properties": .object(properties), "additionalProperties": .bool(false)])
        ]), "additionalProperties": .bool(false)])
    }

    func metadataFacts(invocationID: String = "default") throws -> [AgentModelMetadataFact] {
        try metadata.validate()
        guard let observed = ISO8601DateFormatter().date(from: metadata.retrievedAt) else {
            throw MiraError(.configuration, "The model metadata observation date is invalid.")
        }
        var fields: [(String, JSONValue)] = [
            (AgentModelMetadataField.task, .string(metadata.task.rawValue)),
            (AgentModelMetadataField.inputModalities, .array(metadata.inputModalities.map(JSONValue.string))),
            (AgentModelMetadataField.outputModalities, .array(metadata.outputModalities.map(JSONValue.string)))
        ]
        for (key, value) in [(AgentModelMetadataField.contextWindow, metadata.contextWindow),
                             (AgentModelMetadataField.inputTokens, metadata.maxInputTokens),
                             (AgentModelMetadataField.outputTokens, metadata.maxOutputTokens)] {
            if let value { fields.append((key, .number(Double(value)))) }
        }
        for (id, supported) in [(AgentModelCapabilityID.toolCalls, metadata.toolCall),
                                (AgentModelCapabilityID.thinking, metadata.reasoning),
                                (AgentModelCapabilityID.jsonOutput, metadata.structuredOutput)] {
            if let supported { fields.append((AgentModelMetadataField.capability(id), .bool(supported))) }
        }
        fields.append((AgentModelMetadataField.capability(AgentModelCapabilityID.streamingText), .bool(metadata.task == .textGeneration)))
        return fields.map { .init(field: $0.0, value: $0.1, source: .catalog,
                                 sourceID: metadata.sourceURL, sourceRevision: metadata.sourceRevision,
                                 observedAt: observed, invocationID: invocationID) }
    }

    func makeModel(connection: AgentConfiguredConnection, isEnabled: Bool = true) throws
        -> (model: AgentConfiguredModel, preset: AgentRoutePreset) {
        try makeConfiguration(connection: connection, modelID: id, displayName: metadata.displayName,
                              discoveredFacts: [], isEnabled: isEnabled, catalogModel: self)
    }
}

public extension ProviderModelCatalog {
    /// Unknown IDs are first-class configurable entries. This operation performs no network request.
    func configuration(connection: AgentConfiguredConnection, modelID: String, displayName: String? = nil,
                       discoveredFacts: [AgentModelMetadataFact] = [], isEnabled: Bool = true) throws
        -> (model: AgentConfiguredModel, preset: AgentRoutePreset) {
        try makeConfiguration(connection: connection, modelID: modelID, displayName: displayName,
                              discoveredFacts: discoveredFacts, isEnabled: isEnabled,
                              catalogModel: model(for: connection, modelID: modelID))
    }
}

private func makeConfiguration(connection: AgentConfiguredConnection, modelID: String, displayName: String?,
                               discoveredFacts: [AgentModelMetadataFact], isEnabled: Bool, catalogModel: CatalogModel?) throws
    -> (model: AgentConfiguredModel, preset: AgentRoutePreset) {
        try connection.validate()
        let reference = AgentModelReference(connectionID: connection.id, modelID: modelID)
        try reference.validate()
        guard let template = connection.defaultInvocation else {
            throw MiraError(.configuration, "Choose a default protocol for this provider connection.")
        }
        let spec: AgentModelInvocationSpec
        if let catalogModel { spec = try catalogModel.invocation(connection: connection) }
        else {
            let settings = try SessionCodec.decode(HTTPInvocationSettings.self, from: SessionCodec.encode(template.configuration.value))
            spec = .init(id: "default", revision: 1, adapter: template.adapter, endpointID: template.endpointID,
                         contextWindow: nil, maximumOutputTokens: nil,
                         capabilities: [AgentModelCapabilityID.streamingText: .declared], configuration: template.configuration,
                         parameterSchema: CatalogModel.parameterSchema(options: [], protocolID: settings.protocolID))
        }
        let facts = try (catalogModel?.metadataFacts() ?? []) + discoveredFacts
        let model = AgentConfiguredModel(id: .init(), revision: 1, authorizationRevision: 1,
                                         reference: reference, displayName: displayName ?? catalogModel?.metadata.displayName,
                                         isEnabled: isEnabled, invocations: [spec], facts: facts)
        let resolved = try AgentModelMetadataResolver.resolve(spec, facts: facts)
        let budget = min(4_096, resolved.maximumOutputTokens ?? 4_096, max(1, (resolved.contextWindow ?? 8_192) - 1))
        let preset = AgentRoutePreset(id: .init(model.id.rawValue), revision: 1, name: displayName ?? modelID,
                                      modelDescriptorID: model.id, invocationID: spec.id, maximumOutputTokens: budget,
                                      configuration: .init(schema: spec.configuration.schema, value: .object([:])))
        try model.validate(); try preset.validate()
        return (model, preset)
}

private func json<T: Encodable>(_ value: T) throws -> JSONValue {
    try SessionCodec.decode(JSONValue.self, from: SessionCodec.encode(value))
}

/// Display the same saved declarations used by execution, including explicit negative facts.
/// Catalog modalities are only a fallback when no scoped declaration exists.
public struct ModelCapabilitySummary: Sendable, Equatable {
    public let vision: Bool
    public let tools: Bool
    public let thinking: Bool

    public init(model: AgentConfiguredModel, invocationID: String, catalog: CatalogModelMetadata? = nil) throws {
        guard let invocation = model.invocations.first(where: { $0.id == invocationID }) else {
            throw MiraError(.configuration, "The model invocation is unavailable.")
        }
        let effective = try AgentModelMetadataResolver.resolve(invocation, facts: model.facts)
        let facts = try AgentModelMetadataResolver.selectedFacts(for: invocationID, facts: model.facts)
        if let input = facts[AgentModelMetadataField.inputModalities] {
            guard case .array(let modalities) = input.value,
                  modalities.allSatisfy({ if case .string = $0 { true } else { false } }) else {
                throw MiraError(.configuration, "The model input modalities are invalid.")
            }
            vision = modalities.contains(.string("image"))
        } else {
            vision = catalog?.inputModalities.contains("image") == true
        }
        tools = effective.supports(AgentModelCapabilityID.toolCalls)
        thinking = effective.supports(AgentModelCapabilityID.thinking)
    }
}
