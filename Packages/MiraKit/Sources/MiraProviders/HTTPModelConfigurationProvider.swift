import Foundation
import MiraCore

/// Provider-owned settings schemas and pure route assembly for HTTP
/// invocation specifications. Endpoint bindings and invocation controls remain
/// separate records in core; the frozen route receives their exact merge.
public struct HTTPModelConfigurationProvider: AgentModelConfigurationProvider {
    public let identity: AgentAdapterIdentity
    private let protocolID: HTTPProtocolID
    let defaultDialect: HTTPDialectProfileID

    public init(adapter: AgentAdapterIdentity = HTTPAdapterIdentity.chatCompletions,
                protocolID: HTTPProtocolID = .chatCompletions,
                dialectProfileID: HTTPDialectProfileID = .generic) {
        self.identity = adapter; self.protocolID = protocolID; self.defaultDialect = dialectProfileID
    }

    public func descriptor(for invocation: AgentModelInvocationSpec) throws -> AgentModelConfigurationDescriptor {
        guard invocation.adapter == identity else {
            throw MiraError(.configuration, "The invocation does not match this HTTP configuration provider.")
        }
        let invocationSettings = try decodeInvocationSettings(invocation.configuration.value)
        let routeIdentity = AgentConfigurationIdentity(id: "mira.http.invocation", revision: 2)
        let routeSchema = AgentConfigurationSchema(
            identity: routeIdentity,
            title: "HTTP invocation parameters",
            schema: routeSchemaValue(settings: invocationSettings, parameterSchema: invocation.parameterSchema),
            defaults: invocation.configuration.value)
        let descriptor = AgentModelConfigurationDescriptor(
            adapter: identity,
            title: title(for: protocolID),
            credential: .required,
            connection: HTTPConnectionSettings.schema,
            route: routeSchema)
        try descriptor.validate()
        return descriptor
    }

    public func configuration(for candidate: AgentModelRouteCandidate) throws -> JSONValue {
        try candidate.validate()
        let invocation = try candidate.invocation
        guard invocation.adapter == identity else {
            throw MiraError(.configuration, "The selected HTTP invocation does not match this provider.")
        }
        let endpoint = try candidate.endpoint
        guard endpoint.credential != nil else {
            throw MiraError(.credentialMissing, "The provider credential is unavailable.")
        }
        let descriptor = try descriptor(for: invocation)
        try descriptor.connection.validate(endpoint.configuration)
        try descriptor.route.validate(candidate.preset.configuration)
        let connection = try SessionCodec.decode(HTTPConnectionSettings.self,
                                                  from: SessionCodec.encode(endpoint.configuration.value))
        let base = try decodeInvocationSettings(invocation.configuration.value)
        let merged = try merge(base: base, overrideValue: candidate.preset.configuration.value)
        guard merged.protocolID == protocolID else {
            throw MiraError(.configuration, "The HTTP invocation protocol does not match its provider.")
        }
        let configuration = HTTPModelConfiguration(
            baseURL: connection.baseURL,
            allowsLoopbackHTTP: connection.allowsLoopbackHTTP,
            protocolID: merged.protocolID,
            dialectProfileID: merged.dialectProfileID,
            requestsUsage: merged.requestsUsage,
            thinking: merged.thinking,
            pricing: merged.pricing,
            storeResponses: merged.storeResponses)
        let value = try configuration.jsonValue()
        let frozen = try candidate.freeze(configuration: value)
        _ = try HTTPModelPolicy(route: frozen)
        return value
    }

    private func title(for protocolID: HTTPProtocolID) -> String {
        switch protocolID {
        case .chatCompletions: return "Chat Completions HTTP model"
        case .anthropicMessages: return "Anthropic Messages HTTP model"
        case .responses: return "OpenAI Responses HTTP model"
        default: return "HTTP model"
        }
    }

    private func decodeInvocationSettings(_ value: JSONValue) throws -> HTTPInvocationSettings {
        var object: [String: JSONValue]
        guard case .object(let raw) = value else { throw MiraError(.configuration, "The HTTP invocation configuration is invalid.") }
        object = raw
        do {
            return try SessionCodec.decode(HTTPInvocationSettings.self, from: SessionCodec.encode(JSONValue.object(object)))
        } catch {
            throw MiraError(.configuration, "The HTTP invocation controls are invalid.")
        }
    }

    private func merge(base: HTTPInvocationSettings, overrideValue: JSONValue) throws -> HTTPInvocationSettings {
        guard case .object(let override) = overrideValue else {
            throw MiraError(.configuration, "The HTTP route parameters are invalid.")
        }
        let forbidden = Set(["protocolID", "dialectProfileID"])
        guard forbidden.isDisjoint(with: override.keys) else {
            throw MiraError(.configuration, "An HTTP route preset cannot change its protocol or dialect.")
        }
        let allowed = Set(["requestsUsage", "thinking", "pricing", "storeResponses"])
        guard override.keys.allSatisfy(allowed.contains) else {
            throw MiraError(.configuration, "The HTTP route preset contains unsupported parameters.")
        }
        var merged: [String: JSONValue]
        guard case .object(let rawBase) = try SessionCodec.decode(JSONValue.self, from: SessionCodec.encode(base)) else {
            throw MiraError(.configuration, "The HTTP invocation controls are invalid.")
        }
        merged = rawBase
        for (key, value) in override {
            if key == "thinking", case .object(let baseThinking) = merged[key], case .object(let overrideThinking) = value {
                merged[key] = .object(baseThinking.merging(overrideThinking) { _, incoming in incoming })
            } else { merged[key] = value }
        }
        return try decodeInvocationSettings(.object(merged))
    }

    private func routeSchemaValue(settings: HTTPInvocationSettings, parameterSchema: JSONValue) -> JSONValue {
        var properties: [String: JSONValue] = [
                "protocolID": .object(["type": .string("string"), "enum": .array([.string(settings.protocolID.rawValue)])]),
                "dialectProfileID": .object(["type": .string("string"), "enum": .array([.string(settings.dialectProfileID.rawValue)])]),
                "requestsUsage": .object(["type": .string("boolean")]),
                "thinking": thinkingSchema(settings: settings, parameterSchema: parameterSchema),
                "pricing": HTTPModelPricingSnapshot.schema,
                "storeResponses": .object(["type": .string("boolean")])
            ]
        // The model invocation's parameter schema may narrow controls (for
        // example the effort enum), but cannot replace the protocol safety
        // fields or authorize arbitrary request keys.
        if case .object(let parameterObject) = parameterSchema,
           case .object(let parameterProperties) = parameterObject["properties"] {
            for key in ["requestsUsage", "thinking", "pricing", "storeResponses"] {
                if let narrowed = parameterProperties[key] {
                    if key == "thinking" {
                        properties[key] = intersectThinkingSchema(properties[key]!, narrowed)
                    } else {
                        properties[key] = narrowed
                    }
                }
            }
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array([]), "additionalProperties": .bool(false)
        ])
    }

    private func thinkingSchema(settings: HTTPInvocationSettings, parameterSchema: JSONValue) -> JSONValue {
        var properties: [String: JSONValue] = [
            "mode": .object(["type": .string("string"), "enum": .array(HTTPThinkingCapabilities().modes.map { .string($0.rawValue) })])
        ]
        // Reasoning effort values come from the selected invocation's frozen
        // metadata. There is intentionally no provider-wide allCases list.
        if case .object(let parameterObject) = parameterSchema,
           case .object(let parameterProperties) = parameterObject["properties"],
           case .object(let thinkingProperties) = parameterProperties["thinking"],
           let effort = thinkingProperties["properties"]?["effort"] {
            properties["effort"] = effort
        }
        if case .object(let parameterObject) = parameterSchema,
           case .object(let parameterProperties) = parameterObject["properties"],
           case .object(let thinkingProperties) = parameterProperties["thinking"],
           let budget = thinkingProperties["properties"]?["budgetTokens"] {
            properties["budgetTokens"] = budget
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array([.string("mode")]), "additionalProperties": .bool(false)
        ])
    }

    private func intersectThinkingSchema(_ base: JSONValue, _ narrowed: JSONValue) -> JSONValue {
        guard case .object(let baseObject) = base,
              case .object(let narrowedObject) = narrowed,
              case .object(let baseProperties) = baseObject["properties"],
              case .object(let narrowedProperties) = narrowedObject["properties"] else {
            return base
        }
        var properties = baseProperties
        for key in ["mode", "effort", "budgetTokens"] {
            if let value = narrowedProperties[key] { properties[key] = value }
        }
        var result = baseObject
        result["properties"] = .object(properties)
        return .object(result)
    }
}

public struct HTTPConnectionSettings: Codable, Sendable, Equatable {
    public let baseURL: String
    public let allowsLoopbackHTTP: Bool
    public init(baseURL: String, allowsLoopbackHTTP: Bool = false) {
        self.baseURL = baseURL; self.allowsLoopbackHTTP = allowsLoopbackHTTP
    }
    public static var schema: AgentConfigurationSchema {
        .init(identity: .init(id: "mira.http.connection", revision: 2), title: "HTTP connection", schema: schemaValue,
              defaults: .object(["baseURL": .string(""), "allowsLoopbackHTTP": .bool(false)]))
    }
    private static var schemaValue: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "baseURL": .object(["type": .string("string"), "maxLength": .number(2_048),
                                     "description": .string("HTTPS service base URL without credentials or query parameters.")]),
                "allowsLoopbackHTTP": .object(["type": .string("boolean"),
                                               "description": .string("Allow plain HTTP only for an explicit loopback endpoint.")])
            ]),
            "required": .array([.string("baseURL"), .string("allowsLoopbackHTTP")]), "additionalProperties": .bool(false)
        ])
    }
}
