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
    /// Nil permits any configured connection; an empty set permits none.
    public var allowedConnectionIDs: Set<ConnectionID>?
    public var revision: Int
    public init(id: WorkspaceID, name: String, background: String = "", allowsRemoteSend: Bool = true, revision: Int = 1, allowedConnectionIDs: Set<ConnectionID>? = nil) {
        self.id = id; self.name = name; self.background = background
        self.allowsRemoteSend = allowsRemoteSend; self.revision = revision; self.allowedConnectionIDs = allowedConnectionIDs
    }
}

public enum ExecutionStatus: String, Codable, Sendable, CaseIterable {
    case queued, waitingForModel, completed, failed, cancelled, interrupted
    public var isTerminal: Bool { [.completed, .failed, .cancelled, .interrupted].contains(self) }
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
        if error is CancellationError { return .init(.cancelled, "Generation was stopped.") }
        return .init(.storage, "Operation did not complete. Retry; if the problem persists, back up the library.")
    }
}

public struct RuntimeEnvironment: Sendable {
    public var now: @Sendable () -> Date
    public var uuid: @Sendable () -> UUID
    public var clock: any RuntimeClock
    public init(now: @escaping @Sendable () -> Date = { Date() }, uuid: @escaping @Sendable () -> UUID = { UUID() }, sleep: (@Sendable (Duration) async throws -> Void)? = nil) {
        self.now = now; self.uuid = uuid
        self.clock = sleep.map { ClosureRuntimeClock(operation: $0) } ?? SystemRuntimeClock()
    }
}

public protocol RuntimeClock: Sendable {
    func sleep(for duration: Duration) async throws
}
private struct SystemRuntimeClock: RuntimeClock {
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}
private struct ClosureRuntimeClock: RuntimeClock {
    let operation: @Sendable (Duration) async throws -> Void
    func sleep(for duration: Duration) async throws { try await operation(duration) }
}
