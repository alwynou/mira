import Foundation

/// All mutations are bounded atomic transactions. UI access is local; recall also enforces current connection policy.
public protocol MemoryStore: Sendable {
    func memoryList(workspaceID: WorkspaceID?, states: Set<MemoryState>, query: String, limit: Int) throws -> MemorySearchResult
    func memoryDetail(_ id: MemoryID, workspaceID: WorkspaceID?) throws -> MemoryDetail
    /// Resolves a locally viewed citation against actual persisted usage, scope, and the exact historical revision.
    func memoryCitation(_ reference: MemoryCitationReference, executionID: ExecutionID, conversationID: ConversationID) throws -> MemoryCitationDetail
    /// Current invalidation notices for direct and inherited memory dependencies.
    /// Historical reply bodies remain local; affected turns must not be replayed.
    func memoryContextNotices(in conversationID: ConversationID, at: Date) throws -> [ExecutionID: [MemoryContextNotice]]
    /// Explicit, reviewed user save. The operation ID is durable and reusing it with a different payload fails.
    func createMemory(draft: MemoryDraft, source: MemorySourceInput, operationID: UUID, replacing: MemoryID?, expectedRevision: Int?, at: Date) throws -> MemoryWriteReceipt
    /// A tool commit derives its source from the persisted invocation and rechecks live dispatch authorization atomically.
    func rememberMemory(draft: MemoryDraft, quote: String, invocationID: UUID, at: Date) throws -> MemoryWriteReceipt
    /// Wording/metadata edits preserve identity. Scope and subject changes require a separate explicit save.
    func reviseMemory(_ id: MemoryID, workspaceID: WorkspaceID?, draft: MemoryDraft, expectedRevision: Int, at: Date) throws -> Memory
    func changeMemoryState(_ id: MemoryID, workspaceID: WorkspaceID?, state: MemoryState, expectedRevision: Int, at: Date) throws -> Memory
    /// Confirms the exact candidate and current successor snapshots that the user reviewed.
    func confirmMemoryReplacement(_ candidateID: MemoryID, workspaceID: WorkspaceID?, replacingCurrent currentID: MemoryID, expectedCandidateRevision: Int, expectedCurrentRevision: Int, at: Date) throws -> Memory
    /// Clears memory/cache bodies and blocks late writes, while retaining historical messages and suppression metadata.
    func forgetMemory(_ id: MemoryID, workspaceID: WorkspaceID?, expectedRevision: Int, at: Date) throws -> MemoryForgetReceipt
    /// Deterministic relevance order with a stable ID tie-break; the context builder preserves this ranking.
    func recallMemories(query: String, workspaceID: WorkspaceID?, connectionID: ConnectionID, limit: Int, at: Date) throws -> MemorySearchResult
    func recallMemory(_ id: MemoryID, workspaceID: WorkspaceID?, connectionID: ConnectionID, at: Date) throws -> Memory
    /// Store validates source scope, revision and disclosure policy again when recording a use.
    func recordMemoryUsage(_ usages: [MemoryUsage], executionID: ExecutionID, at: Date) throws
    func validateMemoryUsage(executionID: ExecutionID, at: Date) throws
    /// Original user messages remain visible locally but must not reenter automatic history/extraction after suppression.
    func suppressedMemorySourceMessageIDs() throws -> Set<MessageID>
}
