import Foundation
import MiraCore

/// Fail the commit boundary without duplicating the production database implementation.
final class FaultInjectingStore: MiraStore, @unchecked Sendable {
    private let base: any MiraStore
    private let lock = NSLock()
    private var failFinalization = true
    init(_ base: any MiraStore) { self.base = base }
    func allowFinalization() { lock.withLock { failFinalization = false } }
    func workspaces() throws -> [Workspace] { try base.workspaces() }
    func saveWorkspace(_ workspace: Workspace, expectedRevision: Int?) throws { try base.saveWorkspace(workspace, expectedRevision: expectedRevision) }
    func conversations(includeArchived: Bool) throws -> [Conversation] { try base.conversations(includeArchived: includeArchived) }
    func createConversation(_ conversation: Conversation) throws { try base.createConversation(conversation) }
    func archiveConversation(_ id: ConversationID, at: Date) throws { try base.archiveConversation(id, at: at) }
    func messages(in id: ConversationID) throws -> [Message] { try base.messages(in: id) }
    func executions(in id: ConversationID) throws -> [Execution] { try base.executions(in: id) }
    func draft(for id: ExecutionID) throws -> Draft? { try base.draft(for: id) }
    func routes() throws -> [ModelRoute] { try base.routes() }
    func saveRoute(_ route: ModelRoute, expectedRevision: Int?) throws { try base.saveRoute(route, expectedRevision: expectedRevision) }
    func removeRoute(_ id: RouteID) throws { try base.removeRoute(id) }
    func enqueue(conversationID: ConversationID, text: String, route: ModelRoute, executionID: ExecutionID, messageID: MessageID, at: Date) throws -> Execution {
        try base.enqueue(conversationID: conversationID, text: text, route: route, executionID: executionID, messageID: messageID, at: at)
    }
    func retry(executionID: ExecutionID, newExecutionID: ExecutionID, route: ModelRoute, at: Date) throws -> Execution { try base.retry(executionID: executionID, newExecutionID: newExecutionID, route: route, at: at) }
    func prepare(executionID: ExecutionID, request: CanonicalModelRequest, at: Date) throws { try base.prepare(executionID: executionID, request: request, at: at) }
    func request(for id: ExecutionID) throws -> CanonicalModelRequest? { try base.request(for: id) }
    func prepareAttempt(_ attempt: ModelAttempt) throws { try base.prepareAttempt(attempt) }
    func attempts(for id: ExecutionID) throws -> [ModelAttempt] { try base.attempts(for: id) }
    func finishAttempt(_ id: UUID, output: ModelOutput?, invocations: [ToolInvocation], usage: TokenUsage, error: MiraError?, at: Date) throws {
        try base.finishAttempt(id, output: output, invocations: invocations, usage: usage, error: error, at: at)
    }
    func toolInvocations(for id: ExecutionID) throws -> [ToolInvocation] { try base.toolInvocations(for: id) }
    func markToolDispatched(_ id: UUID, at: Date) throws { try base.markToolDispatched(id, at: at) }
    @discardableResult
    func finishToolInvocation(_ id: UUID, result: ToolResult, at: Date) throws -> Bool {
        try base.finishToolInvocation(id, result: result, at: at)
    }
    func checkpoint(executionID: ExecutionID, text: String, at: Date) throws { try base.checkpoint(executionID: executionID, text: text, at: at) }
    func finish(executionID: ExecutionID, status: ExecutionStatus, text: String, usage: TokenUsage, error: MiraError?, assistantMessageID: MessageID, at: Date) throws -> Bool {
        if lock.withLock({ failFinalization }) { throw MiraError(.storage, "Synthetic finalization failure") }
        return try base.finish(executionID: executionID, status: status, text: text, usage: usage, error: error, assistantMessageID: assistantMessageID, at: at)
    }
    func recoverInterrupted(at: Date) throws { try base.recoverInterrupted(at: at) }
    func diagnostics() throws -> StorageDiagnostics { try base.diagnostics() }
    func exportBackup(to destination: URL) throws { try base.exportBackup(to: destination) }
    func restoreBackup(from source: URL, to directory: URL) throws { try base.restoreBackup(from: source, to: directory) }
}
