import Foundation

/// Library-scoped composition; the generic coordinator and session engine do not know this domain.
public struct KnowledgePrivacyHandler: AgentLibraryMaintenanceHandler {
    public var identity: AgentLibraryMaintenanceHandlerIdentity { .init(namespace: action.namespace, revision: 1) }
    private let action: KnowledgePrivacyAction
    private let knowledge: any KnowledgePrivacyStore
    private let blobs: any KnowledgeBlobMaintenance
    private let sessions: SessionPrivacyMaintenance
    private let plans: any SessionPrivacyPlanStore
    private let business: any AgentBusinessPrivacyStore
    private let projections: SessionPrivacyProjections

    public init(
        action: KnowledgePrivacyAction, knowledge: any KnowledgePrivacyStore,
        blobs: any KnowledgeBlobMaintenance, sessions: SessionPrivacyMaintenance,
        plans: any SessionPrivacyPlanStore, business: any AgentBusinessPrivacyStore,
        projections: SessionPrivacyProjections
    ) {
        self.action = action
        self.knowledge = knowledge
        self.blobs = blobs
        self.sessions = sessions
        self.plans = plans
        self.business = business
        self.projections = projections
    }
    public func apply(_ operation: AgentLibraryMaintenanceOperation) async throws {
        let scope = try await knowledge.prepareKnowledgePrivacy(operation: operation)
        guard scope.action == action else { throw Self.invalid }
        let plan = try await sessions.prepare(
            operation: operation, roots: scope.roots(for: operation),
            retention: action.retention, reason: action.reason)
        try await business.purgeSessionResults(plan: plan)
        try await knowledge.applyKnowledgePrivacy(scope, operation: operation)
        try await sessions.apply(operation: operation)
        _ = try await blobs.collectKnowledgeBlobs(operation: operation)
        try await projections.rebuild(plan: plan)
    }
    public func verify(_ operation: AgentLibraryMaintenanceOperation) async throws {
        let scope = try await knowledge.prepareKnowledgePrivacy(operation: operation)
        guard scope.action == action,
            let plan = try await plans.load(operation: operation), plan.operation == operation,
            Set(plan.roots) == Set(try scope.roots(for: operation)),
            plan.retention == action.retention, plan.reason == action.reason
        else { throw Self.invalid }
        try await knowledge.verifyKnowledgePrivacy(scope, operation: operation)
        try await business.verifySessionResultsPurged(plan: plan)
        try await sessions.verify(operation: operation)
        try await blobs.verifyKnowledgeBlobs(operation: operation)
        try await projections.verify(plan: plan)
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
