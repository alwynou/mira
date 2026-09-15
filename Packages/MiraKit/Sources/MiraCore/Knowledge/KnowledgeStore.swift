import Foundation

/// A domain read has an explicit destination. This value selects policy; it is not a library lease.
public struct KnowledgeReadScope: Sendable, Equatable {
    public let workspaceID: WorkspaceID?
    public let destination: AgentContextDestination
    public init(workspaceID: WorkspaceID?, destination: AgentContextDestination) {
        self.workspaceID = workspaceID; self.destination = destination
    }
    public init(_ request: AgentContextRequest) {
        self.init(workspaceID: request.workspaceID, destination: request.destination)
    }
}

/// Selected-file access belongs to the platform adapter. Only the bounded snapshot enters the domain.
public struct KnowledgeImport: Sendable {
    /// Suggested label for a new source. Updating an identified source retains that source's label.
    public let title: String
    public let bytes: Data
    public init(title: String, bytes: Data) { self.title = title; self.bytes = bytes }
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 1_024, bytes.count <= MarkdownChunker.maxFileBytes else {
            throw MiraError(.invalidInput, "The Markdown import metadata is invalid.")
        }
    }
}

/// Canonical domain reads. Historical usage is independently proved by the session journal.
public protocol KnowledgeReadStore: Sendable {
    func knowledgeSources(scope: KnowledgeReadScope, limit: Int) async throws -> [KnowledgeSource]
    func knowledgeSource(_ id: KnowledgeSourceID, versionID: SourceVersionID?, scope: KnowledgeReadScope) async throws -> KnowledgeSourceDetail
    func sourceChunk(_ id: SourceChunkID, scope: KnowledgeReadScope) async throws -> SourceChunk
    func searchKnowledge(query: String, scope: KnowledgeReadScope, limit: Int) async throws -> KnowledgeSearchResult
    func sourceCitation(_ reference: SourceCitationReference, scope: KnowledgeReadScope) async throws -> SourceCitationDetail
    func validateKnowledgeSources(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws
}

/// Mutations own one guarded business transaction. Privacy revocation is a separate maintenance operation.
public protocol KnowledgeStore: KnowledgeReadStore {
    func importMarkdown(_ input: KnowledgeImport, workspaceID: WorkspaceID?, updating: KnowledgeSourceID?,
                        expectedRevision: Int?, operationID: UUID, authorization: AgentLibraryAuthorization,
                        at: Date) async throws -> KnowledgeImportReceipt
    func allowSourceRemoteUse(_ id: KnowledgeSourceID, workspaceID: WorkspaceID?, expectedRevision: Int,
                             operationID: UUID, authorization: AgentLibraryAuthorization, at: Date) async throws -> KnowledgeSource
    /// Domain-only cleanup; the maintenance coordinator also invalidates dependent journal payloads.
    func revokeSourceRemoteUse(_ id: KnowledgeSourceID, workspaceID: WorkspaceID?, expectedRevision: Int,
                              maintenance: AgentLibraryMaintenanceOperation, at: Date) async throws -> KnowledgeSource
    func purgeKnowledgeSource(_ id: KnowledgeSourceID, workspaceID: WorkspaceID?, expectedRevision: Int,
                              maintenance: AgentLibraryMaintenanceOperation, at: Date) async throws
}

/// Metadata and chunk body provenance are deliberately distinct. Versions/chunks are immutable.
public enum KnowledgeSources {
    public static let metadataNamespace = "knowledge.sources"
    public static let chunkNamespace = "knowledge.chunks"
    public static func metadata(_ source: KnowledgeSource) -> AgentSourceReference {
        .domain(namespace: metadataNamespace, id: source.id.rawValue, revision: source.revision)
    }
    public static func chunk(_ summary: SourceChunkSummary) -> AgentSourceReference {
        .domain(namespace: chunkNamespace, id: summary.id.rawValue, revision: 1)
    }
}
