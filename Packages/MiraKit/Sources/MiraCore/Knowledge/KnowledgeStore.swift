import Foundation

/// Local UI reads use nil connection; tools must use the frozen execution connection.
public protocol KnowledgeStore: Sendable {
    func knowledgeSources(workspaceID: WorkspaceID?, limit: Int) throws -> [KnowledgeSource]
    func knowledgeSource(_ id: KnowledgeSourceID, versionID: SourceVersionID?, workspaceID: WorkspaceID?, connectionID: ConnectionID?) throws -> KnowledgeSourceDetail
    func sourceChunk(_ id: SourceChunkID, workspaceID: WorkspaceID?, connectionID: ConnectionID?) throws -> SourceChunk
    func importMarkdownFile(_ url: URL, workspaceID: WorkspaceID?, updating: KnowledgeSourceID?, expectedRevision: Int?, at: Date) throws -> KnowledgeImportReceipt
    func setSourceRemoteUse(_ id: KnowledgeSourceID, workspaceID: WorkspaceID?, allowed: Bool, expectedRevision: Int, at: Date) throws -> KnowledgeSource
    /// Purges versions/chunks and derived execution bodies; the source tombstone and body-free usages survive.
    func deleteKnowledgeSource(_ id: KnowledgeSourceID, workspaceID: WorkspaceID?, expectedRevision: Int, at: Date) throws
    func searchKnowledge(query: String, workspaceID: WorkspaceID?, connectionID: ConnectionID?, limit: Int) throws -> KnowledgeSearchResult
    func recordSourceUsage(_ usages: [SourceUsage], executionID: ExecutionID, at: Date) throws
    func validateSourceUsage(executionID: ExecutionID) throws
    func sourceCitation(_ reference: SourceCitationReference, executionID: ExecutionID, conversationID: ConversationID) throws -> SourceCitationDetail
    func collectUnreferencedBlobs(at: Date) throws -> BlobCollectionReport
}
