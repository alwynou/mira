import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue? { if case .object(let v) = self { v[key] } else { nil } }
    public var stringValue: String? { if case .string(let v) = self { v } else { nil } }
    public func jsonString() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public struct ToolDefinition: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var wireName: String { name.replacingOccurrences(of: ".", with: "_") }
    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }
}
public struct CanonicalToolCall: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// Original assembled JSON for audit; decoded and validated before dispatch.
    public var arguments: String
    public init(id: String, name: String, arguments: String) { self.id = id; self.name = name; self.arguments = arguments }
}
public enum ToolExecutionMode: String, Codable, Sendable { case parallelSafe, exclusive, ordered }
public enum ToolSideEffect: String, Codable, Sendable { case read, write }
public struct ToolDescriptor: Sendable {
    public var definition: ToolDefinition
    public var executionMode: ToolExecutionMode
    public var sideEffect: ToolSideEffect
    public var timeout: Duration
    public var maxResultBytes: Int
    public init(definition: ToolDefinition, executionMode: ToolExecutionMode = .parallelSafe, sideEffect: ToolSideEffect = .read, timeout: Duration = .seconds(30), maxResultBytes: Int = 32_768) {
        self.definition = definition; self.executionMode = executionMode; self.sideEffect = sideEffect
        self.timeout = timeout; self.maxResultBytes = maxResultBytes
    }
}
public struct ToolContext: Sendable {
    public var executionID: ExecutionID
    public var invocationID: UUID
    public var workspaceID: WorkspaceID?
    public var userMessageID: MessageID
    public var userText: String
    public init(executionID: ExecutionID, invocationID: UUID, workspaceID: WorkspaceID?, userMessageID: MessageID, userText: String) {
        self.executionID = executionID; self.invocationID = invocationID; self.workspaceID = workspaceID
        self.userMessageID = userMessageID; self.userText = userText
    }
}
public protocol ToolPort: Sendable {
    var descriptor: ToolDescriptor { get }
    /// Host-owned authorization, concrete targets and current revisions. Must cooperate with cancellation; a model cannot grant permission.
    func authorize(arguments: JSONValue, context: ToolContext) async throws
    /// Must cooperate with cancellation. Writes revalidate target revisions/authorization inside their commit transaction and use invocationID for idempotency.
    func execute(arguments: JSONValue, context: ToolContext) async throws -> String
}
public extension ToolPort {
    func authorize(arguments: JSONValue, context: ToolContext) async throws {
        guard descriptor.sideEffect == .read else { throw MiraError(.unauthorized, "此写入需要明确授权。") }
    }
}
public enum ToolResultStatus: String, Codable, Sendable {
    case succeeded, invalidArguments, notFound, denied, timedOut, cancelledBeforeDispatch, cancelled, failed, outputLimit, interrupted
}
public struct ToolResult: Codable, Sendable, Equatable {
    public var status: ToolResultStatus
    public var text: String
    public init(status: ToolResultStatus, text: String) { self.status = status; self.text = text }
    public func observation() throws -> String {
        try JSONValue.object(["status": .string(status.rawValue), "content": .string(text), "authority": .string("untrusted_tool_observation")]).jsonString()
    }
}
public struct ToolInvocation: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var attemptID: UUID
    public var modelOrder: Int
    public var call: CanonicalToolCall
    public var result: ToolResult?
    public var dispatchedAt: Date?
    public var completedAt: Date?
    public init(id: UUID, attemptID: UUID, modelOrder: Int, call: CanonicalToolCall, result: ToolResult? = nil, dispatchedAt: Date? = nil, completedAt: Date? = nil) {
        self.id = id; self.attemptID = attemptID; self.modelOrder = modelOrder; self.call = call
        self.result = result; self.dispatchedAt = dispatchedAt; self.completedAt = completedAt
    }
}
public struct ModelOutput: Codable, Sendable, Equatable {
    public var text: String
    public var toolCalls: [CanonicalToolCall]
    public var finishReason: StreamFinishReason
    public init(text: String, toolCalls: [CanonicalToolCall], finishReason: StreamFinishReason) {
        self.text = text; self.toolCalls = toolCalls; self.finishReason = finishReason
    }
}
public enum AttemptStatus: String, Codable, Sendable { case prepared, completed, failed, interrupted }
public struct ModelAttempt: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var executionID: ExecutionID
    public var stepID: UUID
    public var stepIndex: Int
    public var attemptIndex: Int
    public var request: CanonicalModelRequest
    public var status: AttemptStatus
    public var output: ModelOutput?
    public var usage: TokenUsage
    public var error: MiraError?
    public var createdAt: Date
    public var completedAt: Date?
    public init(id: UUID, executionID: ExecutionID, stepID: UUID, stepIndex: Int, attemptIndex: Int = 1, request: CanonicalModelRequest, createdAt: Date) {
        self.id = id; self.executionID = executionID; self.stepID = stepID; self.stepIndex = stepIndex
        self.attemptIndex = attemptIndex; self.request = request; self.createdAt = createdAt
        status = .prepared; usage = .init()
    }
}
public struct ExecutionAudit: Sendable {
    public var attempts: [ModelAttempt]
    public var invocations: [ToolInvocation]
    public init(attempts: [ModelAttempt], invocations: [ToolInvocation]) { self.attempts = attempts; self.invocations = invocations }
}
