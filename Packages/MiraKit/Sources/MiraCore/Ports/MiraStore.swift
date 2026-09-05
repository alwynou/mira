import Foundation

public struct StorageDiagnostics: Sendable, Equatable {
    public var sqliteVersion: String
    public var supportsFTS5: Bool
    public var supportsTrigram: Bool
    public init(sqliteVersion: String, supportsFTS5: Bool, supportsTrigram: Bool) {
        self.sqliteVersion = sqliteVersion; self.supportsFTS5 = supportsFTS5; self.supportsTrigram = supportsTrigram
    }
}

/// Synchronous bounded transactions, called from the application actor, never directly from views.
public protocol MiraStore: Sendable {
    func workspaces() throws -> [Workspace]
    func saveWorkspace(_ workspace: Workspace, expectedRevision: Int?) throws
    func conversations(includeArchived: Bool) throws -> [Conversation]
    func createConversation(_ conversation: Conversation) throws
    func archiveConversation(_ id: ConversationID, at: Date) throws
    func messages(in conversationID: ConversationID) throws -> [Message]
    func executions(in conversationID: ConversationID) throws -> [Execution]
    func execution(_ id: ExecutionID) throws -> Execution?
    func draft(for executionID: ExecutionID) throws -> Draft?
    func modelConfiguration() throws -> ModelConfiguration
    func saveConnection(_ connection: ProviderConnection, expectedRevision: Int?) throws
    func removeConnection(_ id: ConnectionID) throws
    func saveModel(_ model: ModelDescriptor, expectedRevision: Int?) throws
    func removeModel(_ id: ModelDescriptorID) throws
    func saveRoute(_ route: ModelRoute, expectedRevision: Int?) throws
    func removeRoute(_ id: RouteID) throws
    func saveRouteBinding(_ binding: RouteBinding, expectedRevision: Int?) throws
    func removeRouteBinding(_ binding: RouteBinding) throws

    /// Atomically inserts the user message, advances sequence, and queues the execution.
    func enqueue(conversationID: ConversationID, text: String, route: ResolvedModelRouteSnapshot, executionID: ExecutionID, messageID: MessageID, at: Date) throws -> Execution
    /// Only retries the latest terminal failed/cancelled/interrupted execution with no later user message. Reuses its trigger.
    func retry(executionID: ExecutionID, newExecutionID: ExecutionID, route: ResolvedModelRouteSnapshot, at: Date) throws -> Execution
    func request(for executionID: ExecutionID) throws -> CanonicalModelRequest?
    /// Persists a step, model attempt, and exact request before network dispatch.
    func prepareAttempt(_ attempt: ModelAttempt) throws
    func attempts(for executionID: ExecutionID) throws -> [ModelAttempt]
    /// Atomically records model output and its ordered proposals. A completed call cannot be rewritten.
    func finishAttempt(_ id: UUID, output: ModelOutput?, invocations: [ToolInvocation], usage: TokenUsage, error: MiraError?, at: Date) throws
    func toolInvocations(for executionID: ExecutionID) throws -> [ToolInvocation]
    func markToolDispatched(_ id: UUID, at: Date) throws
    /// CAS: exactly one terminal result, including calls which were never dispatched.
    @discardableResult func finishToolInvocation(_ id: UUID, result: ToolResult, at: Date) throws -> Bool
    func checkpoint(executionID: ExecutionID, text: String, at: Date) throws
    /// CAS terminal transition. Returns false for an already-terminal execution. Inserts at most one assistant message; clears its draft.
    @discardableResult
    func finish(executionID: ExecutionID, status: ExecutionStatus, text: String, usage: TokenUsage, error: MiraError?, assistantMessageID: MessageID, at: Date) throws -> Bool
    /// Marks unfinished executions interrupted and materializes their last durable draft. Never sends requests.
    func recoverInterrupted(at: Date) throws
    func diagnostics() throws -> StorageDiagnostics
    /// SQLite backup API, destination must not exist. Credentials are outside this store.
    func exportBackup(to destination: URL) throws
    /// Validate and restore into an unused directory; never replace the live database.
    func restoreBackup(from source: URL, to directory: URL) throws
}
