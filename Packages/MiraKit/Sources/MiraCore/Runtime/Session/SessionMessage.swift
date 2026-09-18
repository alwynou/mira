import Foundation

/// The stable, provider-neutral identity of a DSH-aligned session message.
///
/// Message ids are strings on the wire. Keeping the scalar wrapped in a value
/// type prevents accidentally using a session, execution, or database id in a
/// message position while preserving the DSH JSON shape.
public struct SessionMessageID: Hashable, Codable, Sendable, Equatable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    public let value: String

    public init(_ value: String) { self.value = value }
    public init(stringLiteral value: String) { self.init(value) }
    public var description: String { value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public enum SessionMessageValidationError: Error, Sendable, Equatable {
    case emptyIdentifier
    case emptySourceField
    case roleSourceMismatch
    case invalidContent
    case excessiveNesting
}

/// The three roles supported by the shared session message shape.
public extension SessionMessage {
    enum Role: String, Codable, Sendable, Equatable {
        case system
        case user
        case assistant
    }
}

/// DSH content blocks. Tool arguments intentionally remain their original raw
/// JSON string, including whitespace and key order.
public indirect enum SessionMessageContent: Codable, Sendable, Equatable {
    case text(String)
    case reasoning(String)
    case toolCall(id: String, name: String, arguments: String)
    case toolResult(toolCallID: String, content: [SessionMessageContent], isError: Bool? = nil)

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, arguments, toolCallId, content, isError
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "reasoning":
            self = .reasoning(try container.decode(String.self, forKey: .text))
        case "tool-call":
            self = .toolCall(id: try container.decode(String.self, forKey: .id),
                             name: try container.decode(String.self, forKey: .name),
                             arguments: try container.decode(String.self, forKey: .arguments))
        case "tool-result":
            self = .toolResult(toolCallID: try container.decode(String.self, forKey: .toolCallId),
                               content: try container.decode([SessionMessageContent].self, forKey: .content),
                               isError: try container.decodeIfPresent(Bool.self, forKey: .isError))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                debugDescription: "Unsupported session message content type \(type).")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .reasoning(let text):
            try container.encode("reasoning", forKey: .type)
            try container.encode(text, forKey: .text)
        case .toolCall(let id, let name, let arguments):
            try container.encode("tool-call", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(arguments, forKey: .arguments)
        case .toolResult(let toolCallID, let content, let isError):
            try container.encode("tool-result", forKey: .type)
            try container.encode(toolCallID, forKey: .toolCallId)
            try container.encode(content, forKey: .content)
            try container.encodeIfPresent(isError, forKey: .isError)
        }
    }

    public func validate(depth: Int = 0) throws {
        guard depth <= 32 else { throw SessionMessageValidationError.excessiveNesting }
        switch self {
        case .text, .reasoning: break
        case .toolCall(let id, let name, let arguments):
            guard !id.isEmpty, !name.isEmpty, !arguments.isEmpty,
                  let data = arguments.data(using: .utf8),
                  (try? SessionCodec.decode(JSONValue.self, from: data)) != nil else {
                throw SessionMessageValidationError.invalidContent
            }
        case .toolResult(let callID, let content, _):
            guard !callID.isEmpty, !content.isEmpty else { throw SessionMessageValidationError.invalidContent }
            for value in content { try value.validate(depth: depth + 1) }
        }
    }
}

/// Required producer provenance for one message. `replayState` is opaque to
/// Mira and is kept inline as JSON so adapters can replay their own responses.
public enum SessionMessageSource: Codable, Sendable, Equatable {
    case user
    case plugin(plugin: String)
    case model(provider: String, model: String, replayState: JSONValue? = nil)
    case tool(callID: String)

    private enum CodingKeys: String, CodingKey {
        case kind, plugin, provider, model, replayState, callId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "user":
            self = .user
        case "plugin":
            self = .plugin(plugin: try container.decode(String.self, forKey: .plugin))
        case "model":
            self = .model(provider: try container.decode(String.self, forKey: .provider),
                          model: try container.decode(String.self, forKey: .model),
                          replayState: try container.decodeIfPresent(JSONValue.self, forKey: .replayState))
        case "tool":
            self = .tool(callID: try container.decode(String.self, forKey: .callId))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                debugDescription: "Unsupported session message source kind.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user:
            try container.encode("user", forKey: .kind)
        case .plugin(let plugin):
            try container.encode("plugin", forKey: .kind)
            try container.encode(plugin, forKey: .plugin)
        case .model(let provider, let model, let replayState):
            try container.encode("model", forKey: .kind)
            try container.encode(provider, forKey: .provider)
            try container.encode(model, forKey: .model)
            try container.encodeIfPresent(replayState, forKey: .replayState)
        case .tool(let callID):
            try container.encode("tool", forKey: .kind)
            try container.encode(callID, forKey: .callId)
        }
    }

    public func validate() throws {
        switch self {
        case .user: break
        case .plugin(let plugin): guard !plugin.isEmpty else { throw SessionMessageValidationError.emptySourceField }
        case .model(let provider, let model, _):
            guard !provider.isEmpty, !model.isEmpty else { throw SessionMessageValidationError.emptySourceField }
        case .tool(let callID): guard !callID.isEmpty else { throw SessionMessageValidationError.emptySourceField }
        }
    }
}

/// One identified message shared by durable history, projections, and model
/// request assembly.
public struct SessionMessage: Codable, Sendable, Equatable {
    public let id: SessionMessageID
    public let role: Role
    public let content: [SessionMessageContent]
    public let source: SessionMessageSource

    public init(id: SessionMessageID, role: Role, content: [SessionMessageContent], source: SessionMessageSource) {
        self.id = id
        self.role = role
        self.content = content
        self.source = source
    }

    public func validate() throws {
        guard !id.value.isEmpty else { throw SessionMessageValidationError.emptyIdentifier }
        try source.validate()
        if case .tool(_) = source, role != .user { throw SessionMessageValidationError.roleSourceMismatch }
        for value in content { try value.validate() }
        if role == .assistant {
            guard !content.contains(where: { if case .toolResult = $0 { return true }; return false }) else {
                throw SessionMessageValidationError.roleSourceMismatch
            }
        }
    }
}

// MARK: - Existing core value conversions

public extension SessionMessageContent {
    init(_ block: AgentModelBlock) {
        switch block.content {
        case .text(let text): self = .text(text)
        case .thinking(let text): self = .reasoning(text)
        case .toolCall(let call): self = .toolCall(id: call.id, name: call.name, arguments: call.arguments)
        case .toolResult(let callID, let text): self = .toolResult(toolCallID: callID, content: [.text(text)])
        }
    }

    func agentModelBlock(id: String) -> AgentModelBlock {
        switch self {
        case .text(let text): return AgentModelBlock(id: id, content: .text(text))
        case .reasoning(let text): return AgentModelBlock(id: id, content: .thinking(text))
        case .toolCall(let callID, let name, let arguments):
            return AgentModelBlock(id: id, content: .toolCall(CanonicalToolCall(id: callID, name: name, arguments: arguments)))
        case .toolResult(let callID, let content, _):
            let text = content.reduce(into: "") { result, block in
                if case .text(let value) = block { result += value }
            }
            return AgentModelBlock(id: id, content: .toolResult(callID: callID, text: text))
        }
    }
}
