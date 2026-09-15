import Foundation

public enum KnowledgePrivacyAction: String, Codable, Sendable {
    case revokeRemoteUse, deleteSource
    public var namespace: String { self == .revokeRemoteUse ? "knowledge.revoke" : "knowledge.delete" }
    public var retention: SessionPrivacyRetention {
        self == .revokeRemoteUse ? .preserveVisibleHistory : .purgeGeneratedHistory
    }
    public var reason: SessionInvalidationReason { self == .revokeRemoteUse ? .permissionRevoked : .sourceDeleted }
}

/// Identities survive source deletion; no title, heading, quote or document body is copied here.
public struct KnowledgePrivacyVersion: Codable, Sendable, Equatable {
    public let id: SourceVersionID
    public let digest: String
    public let byteCount: Int
    public init(id: SourceVersionID, digest: String, byteCount: Int) {
        self.id = id
        self.digest = digest
        self.byteCount = byteCount
    }
}

public struct KnowledgePrivacyChunk: Codable, Sendable, Equatable {
    public let id: SourceChunkID
    public let versionID: SourceVersionID
    public init(id: SourceChunkID, versionID: SourceVersionID) {
        self.id = id
        self.versionID = versionID
    }
}

/// Persisted before any domain rows are removed, so restart never rediscovers a smaller scope.
public struct KnowledgePrivacyScope: Codable, Sendable, Equatable {
    public let action: KnowledgePrivacyAction
    public let sourceID: KnowledgeSourceID
    public let workspaceID: WorkspaceID?
    public let expectedRevision: Int
    public let currentVersionID: SourceVersionID?
    public let versions: [KnowledgePrivacyVersion]
    public let chunks: [KnowledgePrivacyChunk]
    public let operationIDs: [UUID]
    public static let maximumBytes = 2 * 1_024 * 1_024

    public init(
        action: KnowledgePrivacyAction, sourceID: KnowledgeSourceID, workspaceID: WorkspaceID?,
        expectedRevision: Int, currentVersionID: SourceVersionID?, versions: [KnowledgePrivacyVersion],
        chunks: [KnowledgePrivacyChunk], operationIDs: [UUID]
    ) {
        self.action = action
        self.sourceID = sourceID
        self.workspaceID = workspaceID
        self.expectedRevision = expectedRevision
        self.currentVersionID = currentVersionID
        self.versions = versions
        self.chunks = chunks
        self.operationIDs = operationIDs
    }
    public func validate(for operation: AgentLibraryMaintenanceOperation) throws {
        try operation.validate()
        guard operation.completedAt == nil else { throw Self.invalid }
        try validate(for: operation.request)
    }
    public func validate(for request: AgentLibraryMaintenanceRequest) throws {
        try request.validate()
        guard request.namespace == action.namespace, request.revision == 1,
            request.scope
                == .sources([
                    .domain(
                        namespace: KnowledgeSources.metadataNamespace,
                        id: sourceID.rawValue, revision: expectedRevision)
                ]),
            (1...8_192).contains(expectedRevision), chunks.count <= 8_192 - expectedRevision,
            Set(chunks.map(\.id)).count == chunks.count, operationIDs.count <= 8_192,
            Set(operationIDs).count == operationIDs.count, !versions.isEmpty, versions.count <= 8_192,
            Set(versions.map(\.id)).count == versions.count,
            currentVersionID.map({ id in versions.contains { $0.id == id } }) ?? true
        else { throw Self.invalid }
        let versionIDs = Set(versions.map(\.id))
        guard chunks.allSatisfy({ versionIDs.contains($0.versionID) }) else { throw Self.invalid }
        var sizes: [String: Int] = [:]
        for version in versions {
            let bytes = version.digest.utf8
            guard bytes.count == 64, bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                (0...10 * 1_024 * 1_024).contains(version.byteCount),
                sizes[version.digest].map({ $0 == version.byteCount }) ?? true
            else { throw Self.invalid }
            sizes[version.digest] = version.byteCount
        }
        guard try SessionCodec.encode(self).count <= Self.maximumBytes else { throw Self.invalid }
    }
    public func roots(for operation: AgentLibraryMaintenanceOperation) throws -> [AgentSourceReference] {
        try validate(for: operation)
        return (1...expectedRevision).map {
            .domain(namespace: KnowledgeSources.metadataNamespace, id: sourceID.rawValue, revision: $0)
        } + chunks.map { .domain(namespace: KnowledgeSources.chunkNamespace, id: $0.id.rawValue, revision: 1) }
    }
    private static var invalid: MiraError {
        .init(.storage, "The knowledge privacy scope is invalid or exceeds its limits.")
    }
}

public protocol KnowledgePrivacyStore: Sendable {
    /// Requires exact pending authority. Returns the immutable saved scope on every retry.
    func prepareKnowledgePrivacy(operation: AgentLibraryMaintenanceOperation) async throws -> KnowledgePrivacyScope
    func applyKnowledgePrivacy(_ scope: KnowledgePrivacyScope, operation: AgentLibraryMaintenanceOperation) async throws
    func verifyKnowledgePrivacy(_ scope: KnowledgePrivacyScope, operation: AgentLibraryMaintenanceOperation)
        async throws
}

public protocol KnowledgeBlobMaintenance: Sendable {
    /// Only after all library producers drain. Every retained version still owns its blob.
    func collectKnowledgeBlobs(operation: AgentLibraryMaintenanceOperation) async throws -> BlobCollectionReport
    func verifyKnowledgeBlobs(operation: AgentLibraryMaintenanceOperation) async throws
}
