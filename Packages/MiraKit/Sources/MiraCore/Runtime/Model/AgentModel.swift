import Foundation

public struct AgentAdapterIdentity: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let revision: Int
    public init(id: String, revision: Int) { self.id = id; self.revision = revision }
    public func validate() throws {
        guard SessionState.validIdentifier(id, maximumBytes: 128), revision > 0 else {
            throw MiraError(.configuration, "The model adapter identity is invalid.")
        }
    }
}

public struct AgentCredentialReference: Codable, Sendable, Equatable {
    public let reference: String
    public let version: Int
    public init(reference: String, version: Int) { self.reference = reference; self.version = version }
}

public struct AgentModelCapabilities: Codable, Sendable, Equatable {
    public let streamsText: Bool
    public let callsTools: Bool
    public let producesThinking: Bool
    public init(streamsText: Bool, callsTools: Bool, producesThinking: Bool) {
        self.streamsText = streamsText; self.callsTools = callsTools; self.producesThinking = producesThinking
    }
}

/// Adapter-owned configuration is frozen data. It never includes a credential value.
public struct AgentModelRoute: Codable, Sendable, Equatable {
    public let id: RouteID
    public let revision: Int
    public let connectionID: ConnectionID
    public let connectionRevision: Int
    public let modelDescriptorID: ModelDescriptorID
    public let modelRevision: Int
    public let modelAuthorizationRevision: Int
    public let adapter: AgentAdapterIdentity
    public let invocationID: String
    public let invocationRevision: Int
    public let endpointID: String
    public let metadataEvidence: [AgentModelMetadataFact]
    public let modelID: String
    public let credential: AgentCredentialReference?
    public let contextWindow: Int
    public let maximumInputTokens: Int?
    public let maximumOutputTokens: Int
    public let capabilities: AgentModelCapabilities
    public let configuration: JSONValue

    public init(id: RouteID, revision: Int, connectionID: ConnectionID, connectionRevision: Int,
                modelDescriptorID: ModelDescriptorID, modelRevision: Int, modelAuthorizationRevision: Int, adapter: AgentAdapterIdentity,
                invocationID: String, invocationRevision: Int, endpointID: String,
                metadataEvidence: [AgentModelMetadataFact],
                modelID: String, credential: AgentCredentialReference?, contextWindow: Int,
                maximumOutputTokens: Int, capabilities: AgentModelCapabilities, configuration: JSONValue, maximumInputTokens: Int? = nil) {
        self.id = id; self.revision = revision; self.connectionID = connectionID
        self.connectionRevision = connectionRevision; self.modelDescriptorID = modelDescriptorID
        self.modelAuthorizationRevision = modelAuthorizationRevision
        self.modelRevision = modelRevision; self.adapter = adapter; self.modelID = modelID
        self.credential = credential; self.contextWindow = contextWindow
        self.maximumOutputTokens = maximumOutputTokens; self.capabilities = capabilities
        self.configuration = configuration
        self.maximumInputTokens = maximumInputTokens
        self.invocationID = invocationID; self.invocationRevision = invocationRevision
        self.endpointID = endpointID; self.metadataEvidence = metadataEvidence
    }

    public func validate() throws {
        try adapter.validate()
        for fact in metadataEvidence { try fact.validate() }
        guard revision > 0, connectionRevision > 0, modelRevision > 0, modelAuthorizationRevision > 0, modelAuthorizationRevision <= modelRevision, invocationRevision > 0,
              SessionState.validIdentifier(invocationID, maximumBytes: 128),
              SessionState.validIdentifier(endpointID, maximumBytes: 128), metadataEvidence.count <= 256,
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, modelID.utf8.count <= 512,
              (1...10_000_000).contains(contextWindow), maximumOutputTokens > 0,
              maximumInputTokens.map({ (1...10_000_000).contains($0) }) ?? true,
              maximumOutputTokens < contextWindow, capabilities.streamsText,
              case .object = configuration, try SessionCodec.encode(configuration).count <= 65_536 else {
            throw MiraError(.configuration, "The frozen model route is invalid.")
        }
        if let credential {
            guard credential.version > 0, !credential.reference.isEmpty, credential.reference.utf8.count <= 512 else {
                throw MiraError(.configuration, "The frozen credential reference is invalid.")
            }
        }
    }
}

/// Only the adapter interprets this payload. The kernel enforces identity, completeness, bounds and retention.
public struct AgentModelContinuation: Codable, Sendable, Equatable {
    public let adapter: AgentAdapterIdentity
    public let format: String
    public let payload: JSONValue
    public let isComplete: Bool
    public init(adapter: AgentAdapterIdentity, format: String, payload: JSONValue, isComplete: Bool) {
        self.adapter = adapter; self.format = format; self.payload = payload; self.isComplete = isComplete
    }
    public func validate() throws {
        try adapter.validate()
        guard SessionState.validIdentifier(format, maximumBytes: 128),
              try SessionCodec.encode(payload).count <= 4_194_304 else {
            throw MiraError(.outputLimit, "The model continuation exceeds its supported bounds.")
        }
    }
}

public enum AgentModelBlockContent: Codable, Sendable, Equatable {
    case text(String)
    case thinking(String)
    case toolCall(CanonicalToolCall)
    case toolResult(callID: String, text: String)
}

public struct AgentModelBlock: Codable, Sendable, Equatable {
    public let id: String
    public let content: AgentModelBlockContent

    public init(id: String, content: AgentModelBlockContent) {
        self.id = id
        self.content = content
    }

    public func validate() throws {
        guard SessionState.validIdentifier(id, maximumBytes: 256) else {
            throw MiraError(.malformedStream, "The model block identity is invalid.")
        }
        switch content {
        case .text(let value), .thinking(let value):
            guard value.utf8.count <= SessionFormatLimits.maximumPayloadBytes else {
                throw MiraError(.outputLimit, "The model block exceeds its text limit.")
            }
        case .toolCall(let call):
            try Self.validate(call)
        case .toolResult(let callID, let text):
            guard !callID.isEmpty, callID.utf8.count <= 256,
                  text.utf8.count <= SessionFormatLimits.maximumPayloadBytes else {
                throw MiraError(.malformedStream, "The model tool result is invalid.")
            }
        }
    }

    static func validate(_ call: CanonicalToolCall) throws {
        guard !call.id.isEmpty, call.id.utf8.count <= 256,
              SessionState.validIdentifier(call.name, maximumBytes: 64),
              call.arguments.utf8.count <= 65_536,
              let bytes = call.arguments.data(using: .utf8),
              let arguments = try? SessionCodec.decode(JSONValue.self, from: bytes),
              case .object = arguments else {
            throw MiraError(.malformedStream, "The model returned malformed tool call arguments.")
        }
    }
}

public struct AgentModelMessage: Codable, Sendable, Equatable {
    public let role: CanonicalRole
    public let blocks: [AgentModelBlock]
    public let continuation: AgentModelContinuation?

    public init(role: CanonicalRole, blocks: [AgentModelBlock], continuation: AgentModelContinuation? = nil) {
        self.role = role
        self.blocks = blocks
        self.continuation = continuation
    }

    public var text: String { blocks.compactMap { if case .text(let value) = $0.content { return value }; return nil }.joined() }
    public var thinkingText: String {
        blocks.compactMap { if case .thinking(let value) = $0.content { return value }; return nil }.joined()
    }
    public var toolCalls: [CanonicalToolCall] {
        blocks.compactMap { if case .toolCall(let value) = $0.content { return value }; return nil }
    }
    public var toolResults: [(callID: String, text: String)] {
        blocks.compactMap {
            if case .toolResult(let callID, let text) = $0.content { return (callID: callID, text: text) }
            return nil
        }
    }

    public func validate(for adapter: AgentAdapterIdentity, replay: Bool) throws {
        try adapter.validate()
        guard (1...64).contains(blocks.count) || (blocks.isEmpty && role == .assistant && continuation != nil) else {
            throw MiraError(.malformedStream, "The model message must contain a bounded ordered block list.")
        }
        var IDs = Set<String>()
        for block in blocks {
            try block.validate()
            guard IDs.insert(block.id).inserted else {
                throw MiraError(.malformedStream, "The model message contains duplicate block identities.")
            }
            switch (role, block.content) {
            case (.assistant, .text), (.assistant, .thinking), (.assistant, .toolCall),
                 (.user, .text), (.context, .text):
                break
            case (.tool, .toolResult):
                break
            default:
                throw MiraError(.malformedStream, "The model message contains a block that does not match its role.")
            }
        }
        if role != .assistant {
            guard continuation == nil else { throw MiraError(.malformedStream, "Only assistant messages may carry model continuation data.") }
        } else if let continuation {
            try continuation.validate()
            guard continuation.adapter == adapter,
                  !replay || continuation.isComplete else {
                throw MiraError(.malformedStream, "The model continuation identity or completion state is invalid.")
            }
        }
    }
}

public struct AgentModelInput: Codable, Sendable, Equatable {
    public let stepID: UUID
    public let executionID: ExecutionID
    public let instructions: String
    public let messages: [AgentModelMessage]
    public let tools: [ToolDefinition]
    public init(stepID: UUID, executionID: ExecutionID, instructions: String,
                messages: [AgentModelMessage], tools: [ToolDefinition]) {
        self.stepID = stepID; self.executionID = executionID; self.instructions = instructions
        self.messages = messages; self.tools = tools
    }

    public func validate(for route: AgentModelRoute) throws {
        try route.validate()
        let contextIndices = messages.indices.filter { messages[$0].role == .context }
        guard contextIndices.count <= 1,
              contextIndices.first.map({ messages.lastIndex(where: { $0.role == .user }) == $0 + 1 }) ?? true else {
            throw MiraError(.malformedStream, "Retrieved context must be one data-only message immediately before the current user message.")
        }
        guard !messages.isEmpty, messages.count <= 256, tools.count <= 256,
              tools.isEmpty || route.capabilities.callsTools,
              Set(tools.map(\.name)).count == tools.count,
              tools.allSatisfy({ SessionState.validIdentifier($0.name, maximumBytes: 64) }),
              try SessionCodec.encode(self).count <= 8_388_608 else {
            throw MiraError(.contextLimit, "The model input exceeds its supported bounds.")
        }
        var pending: [String] = []
        var usedIDs: Set<String> = []
        for message in messages {
            try message.validate(for: route.adapter, replay: true)
            guard try SessionCodec.encode(message).count <= SessionFormatLimits.maximumPayloadBytes else {
                throw MiraError(.contextLimit, "The model input exceeds its supported bounds.")
            }
            if !pending.isEmpty {
                guard message.role == .tool else { throw Self.invalidTranscript() }
            } else if message.role == .tool {
                throw Self.invalidTranscript()
            }
            if message.role == .tool {
                for result in message.toolResults {
                    guard result.callID == pending.first else { throw Self.invalidTranscript() }
                    pending.removeFirst()
                }
            } else {
                guard message.toolResults.isEmpty else { throw Self.invalidTranscript() }
                for call in message.toolCalls {
                    guard usedIDs.insert(call.id).inserted else { throw Self.invalidTranscript() }
                    pending.append(call.id)
                }
            }
        }
        guard pending.isEmpty else { throw Self.invalidTranscript() }
    }

    private static func invalidTranscript() -> MiraError {
        .init(.malformedStream, "The model transcript contains an incomplete or invalid tool exchange.")
    }
}

/// Preparation is pure and secret-free. The journal persists this before stream() can run.
public struct AgentPreparedModelRequest: Codable, Sendable, Equatable {
    public let adapter: AgentAdapterIdentity
    public let input: AgentModelInput
    public let wirePayload: JSONValue
    public let estimatedInputTokens: Int
    public init(adapter: AgentAdapterIdentity, input: AgentModelInput, wirePayload: JSONValue, estimatedInputTokens: Int) {
        self.adapter = adapter; self.input = input; self.wirePayload = wirePayload
        self.estimatedInputTokens = estimatedInputTokens
    }
    public func validate(for route: AgentModelRoute) throws {
        try input.validate(for: route)
        guard adapter == route.adapter, estimatedInputTokens >= 0,
              estimatedInputTokens <= min(route.contextWindow - route.maximumOutputTokens, route.maximumInputTokens ?? Int.max),
              try SessionCodec.encode(self).count <= SessionFormatLimits.maximumPayloadBytes else {
            throw MiraError(.contextLimit, "The prepared model request exceeds the frozen route budget.")
        }
    }
}

public enum AgentModelStreamEvent: Sendable, Equatable {
    case blockStarted(AgentModelBlock)
    case blockDelta(id: String, text: String)
    case blockFinished(id: String)
    case continuation(AgentModelContinuation)
    case usage(TokenUsage)
    case finished(StreamFinishReason)
}

public enum AgentReplayBoundary: Sendable { case sameExecution, previousExecution }
public enum AgentReplayDecision: Sendable {
    case include([AgentModelMessage])
    case omit
}

/// A model stream paired with the transport cleanup needed to stop and drain it.
/// The cleanup is coalesced and runs independently of caller cancellation.
public final class AgentModelOperation: Sendable {
    public let events: AsyncThrowingStream<AgentModelStreamEvent, any Error>
    private let release: RuntimeRelease

    public init(events: AsyncThrowingStream<AgentModelStreamEvent, any Error>,
                cancelAndDrain: @escaping @Sendable () async -> Void) {
        self.events = events
        self.release = RuntimeRelease(cancelAndDrain)
    }

    public func close() async {
        await release.release()
    }
}

public protocol AgentModelAdapter: Sendable {
    var identity: AgentAdapterIdentity { get }
    /// Pure request construction and token estimation; no credentials, network calls or side effects.
    /// Long computations must check task cancellation. The kernel discards late results but cannot kill synchronous code.
    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest
    /// EOF without a finished event is a protocol failure. Closing must cancel and drain the actual transport.
    /// Stream failures use AgentModelFailure for explicit retry advice. Unclassified errors never enable a retry.
    /// Creates an owned producer without blocking or performing synchronous I/O.
    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation
    /// Eligibility and source authorization are checked by the kernel before adapter-specific replay.
    func replay(_ messages: [AgentModelMessage], from source: AgentModelRoute,
                to target: AgentModelRoute, boundary: AgentReplayBoundary) throws -> AgentReplayDecision
}
