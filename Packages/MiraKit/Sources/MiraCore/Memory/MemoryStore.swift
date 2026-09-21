import Foundation

/// A small always-relevant set of explicit preferences and communication preferences.
public protocol MemoryProfileStore: Sendable {
    func memoryProfile(request: AgentContextRequest, at: Date) async throws -> [Memory]
}

/// Business-domain reads only. Callers own a library lease; session queries are never SQL joins.
public protocol MemoryReadStore: Sendable {
    func memoryList(workspaceID: WorkspaceID?, states: Set<MemoryState>, query: String, limit: Int) async throws -> MemorySearchResult
    func memoryDetail(_ id: MemoryID, workspaceID: WorkspaceID?) async throws -> MemoryDetail
    /// Host-only management listing. This result is never a recall or tool input.
    func memoryManagementPage(_ query: MemoryManagementQuery, at: Date) async throws -> MemoryManagementPage
    /// Returns an exact local revision; the application must independently establish journal usage.
    func memoryCitationRevision(_ reference: MemoryCitationReference, workspaceID: WorkspaceID?) async throws -> MemoryCitationDetail
    /// Body-free current status for journal-proven historical use; never grants source access.
    func memoryContextNotices(references: [MemoryCitationReference], workspaceID: WorkspaceID?,
                             connectionID: ConnectionID?, at: Date) async throws -> [MemoryContextNotice]
    func recallMemories(query: String, request: AgentContextRequest, limit: Int, at: Date) async throws -> MemorySearchResult
    func recallMemory(_ id: MemoryID, request: AgentContextRequest, at: Date) async throws -> Memory
    func validateMemorySources(_ sources: [AgentSourceReference], for request: AgentContextRequest, at: Date) async throws
    /// Validates immutable sources already recorded in the current conversation history.
    /// Unlike a tool result check, this may accept a superseded record while its exact
    /// revision and current disclosure/privacy gates remain valid.
    func validateMemoryContextSources(_ sources: [AgentSourceReference], for request: AgentContextRequest, at: Date) async throws
    func suppressedMemorySources() async throws -> [MemoryEvidenceSource]
}

/// Each mutation is one guarded business transaction. Operation identity and assertion identity are separate.
public protocol MemoryStore: MemoryReadStore {
    func createMemory(draft: MemoryDraft, source: MemoryWriteSource, operationID: UUID,
                      replacing: MemoryID?, expectedRevision: Int?, authorization: AgentLibraryAuthorization,
                      at: Date) async throws -> MemoryWriteReceipt
    func reviseMemory(_ id: MemoryID, workspaceID: WorkspaceID?, draft: MemoryDraft, expectedRevision: Int,
                      operationID: UUID, authorization: AgentLibraryAuthorization, at: Date) async throws -> Memory
    func changeMemoryState(_ id: MemoryID, workspaceID: WorkspaceID?, state: MemoryState, expectedRevision: Int,
                           operationID: UUID, authorization: AgentLibraryAuthorization, at: Date) async throws -> Memory
    func confirmMemoryReplacement(_ candidateID: MemoryID, workspaceID: WorkspaceID?, replacingCurrent currentID: MemoryID,
                                  expectedCandidateRevision: Int, expectedCurrentRevision: Int, operationID: UUID,
                                  authorization: AgentLibraryAuthorization, at: Date) async throws -> Memory
    /// Called by maintenance after admission is closed and work has drained; this only purges domain data.
    func purgeMemory(_ id: MemoryID, workspaceID: WorkspaceID?, expectedRevision: Int,
                     maintenance: AgentLibraryMaintenanceOperation, at: Date) async throws -> MemoryForgetReceipt
}
