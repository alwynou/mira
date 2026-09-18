import Foundation

/// Library-scoped composition; the generic coordinator and session engine do not know this domain.
public struct KnowledgePrivacyHandler: AgentLibraryMaintenanceHandler {
    public var identity: AgentLibraryMaintenanceHandlerIdentity { .init(namespace: action.namespace, revision: 1) }
    private let action: KnowledgePrivacyAction
    private let knowledge: any KnowledgePrivacyStore
    private let blobs: any KnowledgeBlobMaintenance

    public init(
        action: KnowledgePrivacyAction, knowledge: any KnowledgePrivacyStore,
        blobs: any KnowledgeBlobMaintenance
    ) {
        self.action = action
        self.knowledge = knowledge
        self.blobs = blobs
    }
    public func apply(_ operation: AgentLibraryMaintenanceOperation) async throws {
        let scope = try await knowledge.prepareKnowledgePrivacy(operation: operation)
        guard scope.action == action else { throw Self.invalid }
        try await knowledge.applyKnowledgePrivacy(scope, operation: operation)
        _ = try await blobs.collectKnowledgeBlobs(operation: operation)
    }
    public func verify(_ operation: AgentLibraryMaintenanceOperation) async throws {
        let scope = try await knowledge.prepareKnowledgePrivacy(operation: operation)
        guard scope.action == action else { throw Self.invalid }
        try await knowledge.verifyKnowledgePrivacy(scope, operation: operation)
        try await blobs.verifyKnowledgeBlobs(operation: operation)
    }
    private static var invalid: MiraError {
        .init(.storage, "The knowledge privacy plan is unavailable or inconsistent.")
    }
}

/// Explicit collection also supports startup orphan cleanup under the same maintenance ownership.
public struct KnowledgeBlobCollectionHandler: AgentLibraryMaintenanceHandler {
    public let identity = AgentLibraryMaintenanceHandlerIdentity(namespace: "knowledge.collect", revision: 1)
    private let store: any KnowledgeBlobMaintenance
    public init(store: any KnowledgeBlobMaintenance) { self.store = store }
    public func apply(_ operation: AgentLibraryMaintenanceOperation) async throws {
        try validate(operation)
        _ = try await store.collectKnowledgeBlobs(operation: operation)
    }
    public func verify(_ operation: AgentLibraryMaintenanceOperation) async throws {
        try validate(operation)
        try await store.verifyKnowledgeBlobs(operation: operation)
    }
    private func validate(_ operation: AgentLibraryMaintenanceOperation) throws {
        try operation.validate()
        guard operation.completedAt == nil, operation.request.namespace == identity.namespace,
            operation.request.revision == 1, operation.request.scope == .library
        else {
            throw MiraError(.invalidInput, "The knowledge collection operation is invalid.")
        }
    }
}
