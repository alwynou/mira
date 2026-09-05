import Foundation

public struct EntityID<Tag: Sendable>: Hashable, Codable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: Self { self }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
public enum WorkspaceTag: Sendable {}
public enum ConversationTag: Sendable {}
public enum MessageTag: Sendable {}
public enum ExecutionTag: Sendable {}
public enum RouteTag: Sendable {}
public typealias WorkspaceID = EntityID<WorkspaceTag>
public typealias ConversationID = EntityID<ConversationTag>
public typealias MessageID = EntityID<MessageTag>
public typealias ExecutionID = EntityID<ExecutionTag>
public typealias RouteID = EntityID<RouteTag>

public struct Workspace: Identifiable, Codable, Sendable, Equatable {
    public var id: WorkspaceID
    public var name: String
    public var background: String
    public var allowsRemoteSend: Bool
    public var revision: Int
    public init(id: WorkspaceID, name: String, background: String = "", allowsRemoteSend: Bool = true, revision: Int = 1) {
        self.id = id; self.name = name; self.background = background
        self.allowsRemoteSend = allowsRemoteSend; self.revision = revision
    }
}

public struct Conversation: Identifiable, Codable, Sendable, Equatable {
    public var id: ConversationID
    public var workspaceID: WorkspaceID?
    public var title: String
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int
    public init(id: ConversationID, workspaceID: WorkspaceID?, title: String, isArchived: Bool = false, createdAt: Date, updatedAt: Date, revision: Int = 1) {
        self.id = id; self.workspaceID = workspaceID; self.title = title; self.isArchived = isArchived
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.revision = revision
    }
}

public enum MessageRole: String, Codable, Sendable { case user, assistant }
public enum MessageStatus: String, Codable, Sendable { case committed, interrupted, failed }
public struct Message: Identifiable, Codable, Sendable, Equatable {
    public var id: MessageID
    public var conversationID: ConversationID
    public var executionID: ExecutionID?
    public var sequence: Int
    public var role: MessageRole
    public var status: MessageStatus
    public var text: String
    public var createdAt: Date
    public init(id: MessageID, conversationID: ConversationID, executionID: ExecutionID?, sequence: Int, role: MessageRole, status: MessageStatus, text: String, createdAt: Date) {
        self.id = id; self.conversationID = conversationID; self.executionID = executionID
        self.sequence = sequence; self.role = role; self.status = status; self.text = text; self.createdAt = createdAt
    }
}

public enum ExecutionStatus: String, Codable, Sendable, CaseIterable {
    case queued, waitingForModel, completed, failed, cancelled, interrupted
    public var isTerminal: Bool { [.completed, .failed, .cancelled, .interrupted].contains(self) }
}
public struct TokenUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}
public struct Execution: Identifiable, Codable, Sendable, Equatable {
    public var id: ExecutionID
    public var conversationID: ConversationID
    public var triggerMessageID: MessageID
    public var retryOfExecutionID: ExecutionID?
    public var status: ExecutionStatus
    public var route: ModelRoute
    public var usage: TokenUsage
    public var error: MiraError?
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: ExecutionID, conversationID: ConversationID, triggerMessageID: MessageID, retryOfExecutionID: ExecutionID? = nil, status: ExecutionStatus = .queued, route: ModelRoute, usage: TokenUsage = .init(), error: MiraError? = nil, createdAt: Date, updatedAt: Date) {
        self.id = id; self.conversationID = conversationID; self.triggerMessageID = triggerMessageID
        self.retryOfExecutionID = retryOfExecutionID; self.status = status; self.route = route
        self.usage = usage; self.error = error; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}
public struct Draft: Codable, Sendable, Equatable {
    public var executionID: ExecutionID
    public var text: String
    public var updatedAt: Date
    public init(executionID: ExecutionID, text: String, updatedAt: Date) {
        self.executionID = executionID; self.text = text; self.updatedAt = updatedAt
    }
}

public struct MiraError: Error, LocalizedError, Codable, Sendable, Equatable {
    public enum Code: String, Codable, Sendable {
        case configuration, credentialMissing, connectionChanged, busy, notFound, conflict, invalidInput
        case contextLimit, unauthorized, network, rateLimited, providerRejected, malformedStream
        case outputLimit, cancelled, interrupted, storage, unsupported, timeout
    }
    public var code: Code
    public var message: String
    public var errorDescription: String? { message }
    public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
    public static func safe(_ error: any Error) -> Self {
        if let error = error as? Self { return error }
        if error is CancellationError { return .init(.cancelled, "已停止生成。") }
        return .init(.storage, "操作未完成。请重试；如果问题持续，请备份资料库。")
    }
}

public struct RuntimeEnvironment: Sendable {
    public var now: @Sendable () -> Date
    public var uuid: @Sendable () -> UUID
    public init(now: @escaping @Sendable () -> Date = { Date() }, uuid: @escaping @Sendable () -> UUID = { UUID() }) {
        self.now = now; self.uuid = uuid
    }
}
