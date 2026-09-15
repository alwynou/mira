import Foundation
import MiraCore

/// An open protocol identifier. The protocol implementation owns the wire
/// format; callers must not infer it from a model name or provider label.
public struct HTTPProtocolID: Codable, Sendable, Equatable, Hashable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let chatCompletions = Self(rawValue: "chat.completions")
    public static let anthropicMessages = Self(rawValue: "anthropic.messages")
    public static let responses = Self(rawValue: "openai.responses")
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self); self.init(rawValue: value)
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public func validate() throws {
        guard httpValidIdentifier(rawValue, maximumBytes: 128) else {
            throw MiraError(.configuration, "The HTTP protocol identifier is invalid.")
        }
    }
}

/// A constrained provider-scoped dialect. A dialect is data used by a
/// protocol codec, never a second protocol adapter.
public struct HTTPDialectProfileID: Codable, Sendable, Equatable, Hashable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let generic = Self(rawValue: "generic")
    public static let deepSeek = Self(rawValue: "deepseek.chat")
    public static let kimi = Self(rawValue: "kimi.chat")
    public static let openRouter = Self(rawValue: "openrouter.chat")
    public static let openAI = Self(rawValue: "openai.chat")
    public static let anthropic = Self(rawValue: "anthropic.messages")
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self); self.init(rawValue: value)
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public func validate() throws {
        guard httpValidIdentifier(rawValue, maximumBytes: 128) else {
            throw MiraError(.configuration, "The HTTP dialect profile identifier is invalid.")
        }
    }
}

public enum HTTPAdapterIdentity {
    public static let chatCompletions = AgentAdapterIdentity(id: "mira.http.chat-completions", revision: 1)
    public static let anthropicMessages = AgentAdapterIdentity(id: "mira.http.anthropic-messages", revision: 1)
    public static let responses = AgentAdapterIdentity(id: "mira.http.responses", revision: 1)
}

/// Internal codec routing. Provider differences remain data in the dialect
/// profile; this value is never exposed as a model-selection family axis.
struct HTTPInvocationKind: Equatable, Sendable {
    let protocolID: HTTPProtocolID
    let dialect: HTTPDialectProfileID

    var identity: AgentAdapterIdentity {
        switch protocolID {
        case .chatCompletions: return HTTPAdapterIdentity.chatCompletions
        case .anthropicMessages: return HTTPAdapterIdentity.anthropicMessages
        case .responses: return HTTPAdapterIdentity.responses
        default: return HTTPAdapterIdentity.chatCompletions
        }
    }
    var isAnthropic: Bool { protocolID == .anthropicMessages }
    var isResponses: Bool { protocolID == .responses }

    init(protocolID: HTTPProtocolID, dialectProfileID: HTTPDialectProfileID) throws {
        switch (protocolID, dialectProfileID) {
        case (.chatCompletions, .generic), (.chatCompletions, .deepSeek),
             (.chatCompletions, .kimi), (.chatCompletions, .openRouter),
             (.chatCompletions, .openAI), (.anthropicMessages, .anthropic),
             (.responses, .openAI):
            self.protocolID = protocolID
            self.dialect = dialectProfileID
        default:
            throw MiraError(.configuration, "The HTTP protocol and dialect combination is unavailable.")
        }
    }
}

/// Non-secret endpoint and invocation controls frozen into an execution route.
public struct HTTPModelConfiguration: Codable, Sendable, Equatable {
    public let baseURL: String
    public let allowsLoopbackHTTP: Bool
    public let protocolID: HTTPProtocolID
    public let dialectProfileID: HTTPDialectProfileID
    public let requestsUsage: Bool
    public let thinking: ThinkingSettings
    public let pricing: HTTPModelPricingSnapshot?
    public let storeResponses: Bool

    public init(baseURL: String, allowsLoopbackHTTP: Bool = false,
                protocolID: HTTPProtocolID = .chatCompletions,
                dialectProfileID: HTTPDialectProfileID = .generic,
                requestsUsage: Bool = true, thinking: ThinkingSettings = .init(),
                pricing: HTTPModelPricingSnapshot? = nil, storeResponses: Bool = false) {
        self.baseURL = baseURL; self.allowsLoopbackHTTP = allowsLoopbackHTTP
        self.protocolID = protocolID; self.dialectProfileID = dialectProfileID
        self.requestsUsage = requestsUsage; self.thinking = thinking
        self.pricing = pricing; self.storeResponses = storeResponses
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL, allowsLoopbackHTTP, protocolID, dialectProfileID, requestsUsage, thinking, pricing, storeResponses
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        allowsLoopbackHTTP = try container.decodeIfPresent(Bool.self, forKey: .allowsLoopbackHTTP) ?? false
        protocolID = try container.decodeIfPresent(HTTPProtocolID.self, forKey: .protocolID) ?? .chatCompletions
        dialectProfileID = try container.decodeIfPresent(HTTPDialectProfileID.self, forKey: .dialectProfileID) ?? .generic
        requestsUsage = try container.decodeIfPresent(Bool.self, forKey: .requestsUsage) ?? true
        thinking = try container.decodeIfPresent(ThinkingSettings.self, forKey: .thinking) ?? .init()
        pricing = try container.decodeIfPresent(HTTPModelPricingSnapshot.self, forKey: .pricing)
        storeResponses = try container.decodeIfPresent(Bool.self, forKey: .storeResponses) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(allowsLoopbackHTTP, forKey: .allowsLoopbackHTTP)
        try container.encode(protocolID, forKey: .protocolID)
        try container.encode(dialectProfileID, forKey: .dialectProfileID)
        try container.encode(requestsUsage, forKey: .requestsUsage)
        try container.encode(thinking, forKey: .thinking)
        try container.encodeIfPresent(pricing, forKey: .pricing)
        try container.encode(storeResponses, forKey: .storeResponses)
    }

    public func jsonValue() throws -> JSONValue {
        try SessionCodec.decode(JSONValue.self, from: SessionCodec.encode(self))
    }

    public func validatedEndpoint() throws -> URL {
        try protocolID.validate(); try dialectProfileID.validate()
        guard let components = URLComponents(string: baseURL),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw MiraError(.configuration, "Enter a service URL without credentials, query parameters, or fragments.")
        }
        let loopback = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
        let scheme = components.scheme?.lowercased()
        guard scheme == "https" || (scheme == "http" && loopback && allowsLoopbackHTTP) else {
            throw MiraError(.configuration, "Service URL must use HTTPS; explicitly enable HTTP for loopback services.")
        }
        guard var url = components.url else { throw MiraError(.configuration, "Service URL is invalid.") }
        let path = url.path.lowercased()
        guard !path.hasSuffix("/chat/completions"), !path.hasSuffix("/messages"), !path.hasSuffix("/responses") else {
            throw MiraError(.configuration, "Enter a base URL without an operation path.")
        }
        if protocolID == .anthropicMessages, url.lastPathComponent != "v1" { url.appendPathComponent("v1") }
        switch protocolID {
        case .chatCompletions: url.appendPathComponent("chat/completions")
        case .anthropicMessages: url.appendPathComponent("messages")
        case .responses: url.appendPathComponent("responses")
        default: throw MiraError(.configuration, "This HTTP protocol is not installed.")
        }
        return url
    }

    func validatedEndpoint(kind: HTTPInvocationKind) throws -> URL {
        guard protocolID == kind.protocolID, dialectProfileID == kind.dialect else {
            throw MiraError(.configuration, "The HTTP invocation does not match the frozen protocol configuration.")
        }
        return try validatedEndpoint()
    }
}

/// Public factory value used by connection templates and invocation specs.
/// Endpoint address and credential remain in `AgentModelEndpoint`; this value
/// contains only protocol and parameter controls.
public struct HTTPInvocationSettings: Codable, Sendable, Equatable {
    public var protocolID: HTTPProtocolID
    public var dialectProfileID: HTTPDialectProfileID
    public var requestsUsage: Bool
    public var thinking: ThinkingSettings
    public var pricing: HTTPModelPricingSnapshot?
    public var storeResponses: Bool
    public init(protocolID: HTTPProtocolID, dialectProfileID: HTTPDialectProfileID,
                requestsUsage: Bool = true, thinking: ThinkingSettings = .init(),
                pricing: HTTPModelPricingSnapshot? = nil, storeResponses: Bool = false) {
        self.protocolID = protocolID; self.dialectProfileID = dialectProfileID
        self.requestsUsage = requestsUsage; self.thinking = thinking
        self.pricing = pricing; self.storeResponses = storeResponses
    }

    private enum CodingKeys: String, CodingKey {
        case protocolID, dialectProfileID, requestsUsage, thinking, pricing, storeResponses
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolID = try container.decode(HTTPProtocolID.self, forKey: .protocolID)
        dialectProfileID = try container.decode(HTTPDialectProfileID.self, forKey: .dialectProfileID)
        requestsUsage = try container.decodeIfPresent(Bool.self, forKey: .requestsUsage) ?? true
        thinking = try container.decodeIfPresent(ThinkingSettings.self, forKey: .thinking) ?? .init()
        pricing = try container.decodeIfPresent(HTTPModelPricingSnapshot.self, forKey: .pricing)
        storeResponses = try container.decodeIfPresent(Bool.self, forKey: .storeResponses) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolID, forKey: .protocolID)
        try container.encode(dialectProfileID, forKey: .dialectProfileID)
        try container.encode(requestsUsage, forKey: .requestsUsage)
        try container.encode(thinking, forKey: .thinking)
        try container.encodeIfPresent(pricing, forKey: .pricing)
        try container.encode(storeResponses, forKey: .storeResponses)
    }
}

struct HTTPModelPolicy: Sendable {
    let protocolID: HTTPProtocolID
    let dialectProfileID: HTTPDialectProfileID
    private let invocationKind: HTTPInvocationKind
    let modelID: String
    let maximumOutputTokens: Int
    let configuration: HTTPModelConfiguration

    init(route: AgentModelRoute) throws {
        try route.validate()
        let configuration: HTTPModelConfiguration
        do { configuration = try SessionCodec.decode(HTTPModelConfiguration.self, from: SessionCodec.encode(route.configuration)) }
        catch { throw MiraError(.configuration, "The HTTP model configuration is invalid.") }
        guard try configuration.jsonValue() == route.configuration else {
            throw MiraError(.configuration, "The HTTP model configuration contains unsupported fields.")
        }
        guard route.maximumOutputTokens > 0, route.maximumOutputTokens < route.contextWindow else {
            throw MiraError(.configuration, "Configure a valid context window and maximum output token count.")
        }
        try configuration.pricing?.validate()
        if let pricing = configuration.pricing, pricing.modelID != route.modelID {
            throw MiraError(.configuration, "The model pricing metadata is invalid.")
        }
        _ = try configuration.validatedEndpoint()
        try HTTPInvocationRegistry.validate(protocolID: configuration.protocolID,
                                            dialect: configuration.dialectProfileID,
                                            controls: configuration.thinking,
                                            outputLimit: route.maximumOutputTokens)
        guard configuration.protocolID != .responses || !configuration.storeResponses else {
            throw MiraError(.configuration, "OpenAI Responses invocations must keep provider-side storage disabled.")
        }
        let invocationKind = try HTTPInvocationKind(protocolID: configuration.protocolID,
                                                    dialectProfileID: configuration.dialectProfileID)
        self.protocolID = configuration.protocolID; self.dialectProfileID = configuration.dialectProfileID
        self.invocationKind = invocationKind
        self.modelID = route.modelID; self.maximumOutputTokens = route.maximumOutputTokens
        self.configuration = configuration
    }
    var thinking: ThinkingSettings { configuration.thinking }
    var kind: HTTPInvocationKind {
        invocationKind
    }

    init(route: AgentModelRoute, kind: HTTPInvocationKind) throws {
        try self.init(route: route)
        guard self.kind == kind, route.adapter == kind.identity else {
            throw MiraError(.configuration, "The HTTP invocation does not match the frozen route.")
        }
    }
}

enum HTTPInvocationRegistry {
    static func validate(protocolID: HTTPProtocolID, dialect: HTTPDialectProfileID,
                         controls: ThinkingSettings, outputLimit: Int) throws {
        try protocolID.validate(); try dialect.validate()
        switch protocolID {
        case .chatCompletions:
            guard [.generic, .deepSeek, .kimi, .openRouter, .openAI].contains(dialect) else {
                throw MiraError(.configuration, "The selected Chat Completions dialect is unavailable.")
            }
            if dialect == .generic {
                guard controls.mode == .providerDefault, controls.effort == nil, controls.budgetTokens == nil else {
                    throw MiraError(.configuration, "The generic Chat Completions dialect does not support thinking controls.")
                }
            } else if dialect == .deepSeek || dialect == .kimi {
                guard controls.mode != .adaptive, controls.budgetTokens == nil else {
                    throw MiraError(.configuration, "This Chat Completions dialect does not support the selected thinking controls.")
                }
            } else if dialect == .openAI {
                guard controls.mode != .adaptive, controls.budgetTokens == nil else {
                    throw MiraError(.configuration, "The OpenAI Chat Completions dialect does not support the selected thinking controls.")
                }
            }
            if dialect == .openRouter, controls.effort != nil, controls.budgetTokens != nil {
                throw MiraError(.configuration, "Choose either reasoning effort or a token budget.")
            }
        case .anthropicMessages:
            guard dialect == .anthropic else {
                throw MiraError(.configuration, "The selected Anthropic Messages controls are unavailable.")
            }
        case .responses:
            guard dialect == .openAI else {
                throw MiraError(.configuration, "The Responses adapter requires the OpenAI dialect.")
            }
        default: throw MiraError(.configuration, "This HTTP protocol is not installed.")
        }
        if let budget = controls.budgetTokens {
            guard controls.mode != .disabled, budget >= 1_024, budget < outputLimit else {
                throw MiraError(.configuration, "The thinking budget must be at least 1024 tokens and smaller than maximum output tokens.")
            }
        }
        if protocolID == .anthropicMessages, controls.mode == .enabled, controls.budgetTokens == nil {
            guard 2_048 < outputLimit else {
                throw MiraError(.configuration, "Anthropic manual thinking requires an output budget larger than its default thinking budget.")
            }
        }
    }
}

/// Descriptor data is supplied by the invocation specification. It is not
/// derived from model-name prefixes.
public struct HTTPThinkingCapabilities: Sendable, Equatable {
    public let modes: [ThinkingMode]
    public let efforts: [ThinkingEffort]
    public let supportsBudget: Bool
    public init(modes: [ThinkingMode] = [.providerDefault, .enabled, .disabled],
                efforts: [ThinkingEffort] = [], supportsBudget: Bool = false) {
        self.modes = modes; self.efforts = efforts; self.supportsBudget = supportsBudget
    }
}

private func httpValidIdentifier(_ value: String, maximumBytes: Int) -> Bool {
    let bytes = value.utf8
    guard (1...maximumBytes).contains(bytes.count), let first = bytes.first,
          first >= 0x41 && first <= 0x7A || first == 0x5F else { return false }
    return bytes.dropFirst().allSatisfy {
        ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) ||
            ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x2E || $0 == 0x5F
    }
}
