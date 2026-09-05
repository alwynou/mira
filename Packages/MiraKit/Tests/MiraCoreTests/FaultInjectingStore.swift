import Foundation
import MiraCore

/// Fail the commit boundary without duplicating the production database implementation.
final class FaultInjectingStore: MiraStore, @unchecked Sendable {
    private let base: any MiraStore
    private let lock = NSLock()
    private var failFinalization = true
    init(_ base: any MiraStore) { self.base = base }
    func allowFinalization() { lock.withLock { failFinalization = false } }
    func knowledgeSources(workspaceID: WorkspaceID?, limit: Int) throws -> [KnowledgeSource] { try base.knowledgeSources(workspaceID: workspaceID, limit: limit) }
    func knowledgeSource(_ id: KnowledgeSourceID, versionID: SourceVersionID?, workspaceID: WorkspaceID?, connectionID: ConnectionID?) throws -> KnowledgeSourceDetail { try base.knowledgeSource(id, versionID: versionID, workspaceID: workspaceID, connectionID: connectionID) }
    func sourceChunk(_ id: SourceChunkID, workspaceID: WorkspaceID?, connectionID: ConnectionID?) throws -> SourceChunk { try base.sourceChunk(id, workspaceID: workspaceID, connectionID: connectionID) }
    func importMarkdownFile(_ url: URL, workspaceID: WorkspaceID?, updating: KnowledgeSourceID?, expectedRevision: Int?, at: Date) throws -> KnowledgeImportReceipt { try base.importMarkdownFile(url, workspaceID: workspaceID, updating: updating, expectedRevision: expectedRevision, at: at) }
    func setSourceRemoteUse(_ id: KnowledgeSourceID, workspaceID: WorkspaceID?, allowed: Bool, expectedRevision: Int, at: Date) throws -> KnowledgeSource { try base.setSourceRemoteUse(id, workspaceID: workspaceID, allowed: allowed, expectedRevision: expectedRevision, at: at) }
    func deleteKnowledgeSource(_ id: KnowledgeSourceID, workspaceID: WorkspaceID?, expectedRevision: Int, at: Date) throws { try base.deleteKnowledgeSource(id, workspaceID: workspaceID, expectedRevision: expectedRevision, at: at) }
    func searchKnowledge(query: String, workspaceID: WorkspaceID?, connectionID: ConnectionID?, limit: Int) throws -> KnowledgeSearchResult { try base.searchKnowledge(query: query, workspaceID: workspaceID, connectionID: connectionID, limit: limit) }
    func recordSourceUsage(_ usages: [SourceUsage], executionID: ExecutionID, at: Date) throws { try base.recordSourceUsage(usages, executionID: executionID, at: at) }
    func validateSourceUsage(executionID: ExecutionID) throws { try base.validateSourceUsage(executionID: executionID) }
    func sourceCitation(_ reference: SourceCitationReference, executionID: ExecutionID, conversationID: ConversationID) throws -> SourceCitationDetail { try base.sourceCitation(reference, executionID: executionID, conversationID: conversationID) }
    func collectUnreferencedBlobs(at: Date) throws -> BlobCollectionReport { try base.collectUnreferencedBlobs(at: at) }
    func memoryCapturePolicy() throws -> MemoryCapturePolicy { try base.memoryCapturePolicy() }
    func saveMemoryCapturePolicy(_ policy: MemoryCapturePolicy, expectedRevision: Int, at: Date) throws { try base.saveMemoryCapturePolicy(policy, expectedRevision: expectedRevision, at: at) }
    func memoryExtractionJobs(conversationID: ConversationID?, limit: Int) throws -> [MemoryExtractionJob] { try base.memoryExtractionJobs(conversationID: conversationID, limit: limit) }
    func memoryExtractionBudget(at: Date) throws -> MemoryExtractionBudget { try base.memoryExtractionBudget(at: at) }
    func claimMemoryExtraction(at: Date) throws -> MemoryExtractionClaim? { try base.claimMemoryExtraction(at: at) }
    func prepareMemoryExtraction(_ claim: MemoryExtractionClaim, request: CanonicalModelRequest, at: Date) throws -> Int { try base.prepareMemoryExtraction(claim, request: request, at: at) }
    func markMemoryExtractionDispatched(_ claim: MemoryExtractionClaim, at: Date) throws { try base.markMemoryExtractionDispatched(claim, at: at) }
    func completeMemoryExtraction(_ claim: MemoryExtractionClaim, output: ModelOutput, usage: TokenUsage, at: Date) throws -> MemoryExtractionJob { try base.completeMemoryExtraction(claim, output: output, usage: usage, at: at) }
    func failMemoryExtraction(_ claim: MemoryExtractionClaim, error: MiraError, at: Date) throws { try base.failMemoryExtraction(claim, error: error, at: at) }
    func retryMemoryExtraction(_ id: MemoryExtractionJobID, at: Date) throws -> MemoryExtractionJobID { try base.retryMemoryExtraction(id, at: at) }
    func recoverMemoryExtraction(at: Date) throws { try base.recoverMemoryExtraction(at: at) }
    func memoryList(workspaceID: WorkspaceID?, states: Set<MemoryState>, query: String, limit: Int) throws -> MemorySearchResult { try base.memoryList(workspaceID: workspaceID, states: states, query: query, limit: limit) }
    func memoryDetail(_ id: MemoryID, workspaceID: WorkspaceID?) throws -> MemoryDetail { try base.memoryDetail(id, workspaceID: workspaceID) }
    func memoryCitation(_ reference: MemoryCitationReference, executionID: ExecutionID, conversationID: ConversationID) throws -> MemoryCitationDetail { try base.memoryCitation(reference, executionID: executionID, conversationID: conversationID) }
    func createMemory(draft: MemoryDraft, source: MemorySourceInput, operationID: UUID, replacing: MemoryID?, expectedRevision: Int?, at: Date) throws -> MemoryWriteReceipt { try base.createMemory(draft: draft, source: source, operationID: operationID, replacing: replacing, expectedRevision: expectedRevision, at: at) }
    func rememberMemory(draft: MemoryDraft, quote: String, invocationID: UUID, at: Date) throws -> MemoryWriteReceipt { try base.rememberMemory(draft: draft, quote: quote, invocationID: invocationID, at: at) }
    func reviseMemory(_ id: MemoryID, workspaceID: WorkspaceID?, draft: MemoryDraft, expectedRevision: Int, at: Date) throws -> Memory { try base.reviseMemory(id, workspaceID: workspaceID, draft: draft, expectedRevision: expectedRevision, at: at) }
    func changeMemoryState(_ id: MemoryID, workspaceID: WorkspaceID?, state: MemoryState, expectedRevision: Int, at: Date) throws -> Memory { try base.changeMemoryState(id, workspaceID: workspaceID, state: state, expectedRevision: expectedRevision, at: at) }
    func forgetMemory(_ id: MemoryID, workspaceID: WorkspaceID?, expectedRevision: Int, at: Date) throws -> MemoryForgetReceipt { try base.forgetMemory(id, workspaceID: workspaceID, expectedRevision: expectedRevision, at: at) }
    func confirmMemoryReplacement(_ candidateID: MemoryID, workspaceID: WorkspaceID?, replacingCurrent currentID: MemoryID, expectedCandidateRevision: Int, expectedCurrentRevision: Int, at: Date) throws -> Memory { try base.confirmMemoryReplacement(candidateID, workspaceID: workspaceID, replacingCurrent: currentID, expectedCandidateRevision: expectedCandidateRevision, expectedCurrentRevision: expectedCurrentRevision, at: at) }
    func recallMemories(query: String, workspaceID: WorkspaceID?, connectionID: ConnectionID, limit: Int, at: Date) throws -> MemorySearchResult { try base.recallMemories(query: query, workspaceID: workspaceID, connectionID: connectionID, limit: limit, at: at) }
    func recallMemory(_ id: MemoryID, workspaceID: WorkspaceID?, connectionID: ConnectionID, at: Date) throws -> Memory { try base.recallMemory(id, workspaceID: workspaceID, connectionID: connectionID, at: at) }
    func recordMemoryUsage(_ usages: [MemoryUsage], executionID: ExecutionID, at: Date) throws { try base.recordMemoryUsage(usages, executionID: executionID, at: at) }
    func validateMemoryUsage(executionID: ExecutionID, at: Date) throws { try base.validateMemoryUsage(executionID: executionID, at: at) }
    func suppressedMemorySourceMessageIDs() throws -> Set<MessageID> { try base.suppressedMemorySourceMessageIDs() }
    func workspaces() throws -> [Workspace] { try base.workspaces() }
    func saveWorkspace(_ workspace: Workspace, expectedRevision: Int?) throws { try base.saveWorkspace(workspace, expectedRevision: expectedRevision) }
    func conversations(includeArchived: Bool) throws -> [Conversation] { try base.conversations(includeArchived: includeArchived) }
    func createConversation(_ conversation: Conversation) throws { try base.createConversation(conversation) }
    func archiveConversation(_ id: ConversationID, at: Date) throws { try base.archiveConversation(id, at: at) }
    func messages(in id: ConversationID) throws -> [Message] { try base.messages(in: id) }
    func executions(in id: ConversationID) throws -> [Execution] { try base.executions(in: id) }
    func draft(for id: ExecutionID) throws -> Draft? { try base.draft(for: id) }
    func execution(_ id: ExecutionID) throws -> Execution? { try base.execution(id) }
    func modelConfiguration() throws -> ModelConfiguration { try base.modelConfiguration() }
    func saveConnection(_ connection: ProviderConnection, expectedRevision: Int?) throws { try base.saveConnection(connection, expectedRevision: expectedRevision) }
    func removeConnection(_ id: ConnectionID) throws { try base.removeConnection(id) }
    func saveModel(_ model: ModelDescriptor, expectedRevision: Int?) throws { try base.saveModel(model, expectedRevision: expectedRevision) }
    func removeModel(_ id: ModelDescriptorID) throws { try base.removeModel(id) }
    func saveRoute(_ route: ModelRoute, expectedRevision: Int?) throws { try base.saveRoute(route, expectedRevision: expectedRevision) }
    func removeRoute(_ id: RouteID) throws { try base.removeRoute(id) }
    func saveRouteBinding(_ binding: RouteBinding, expectedRevision: Int?) throws { try base.saveRouteBinding(binding, expectedRevision: expectedRevision) }
    func removeRouteBinding(_ binding: RouteBinding) throws { try base.removeRouteBinding(binding) }
    func enqueue(conversationID: ConversationID, text: String, route: ResolvedModelRouteSnapshot, executionID: ExecutionID, messageID: MessageID, at: Date) throws -> Execution {
        try base.enqueue(conversationID: conversationID, text: text, route: route, executionID: executionID, messageID: messageID, at: at)
    }
    func retry(executionID: ExecutionID, newExecutionID: ExecutionID, route: ResolvedModelRouteSnapshot, at: Date) throws -> Execution { try base.retry(executionID: executionID, newExecutionID: newExecutionID, route: route, at: at) }
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
