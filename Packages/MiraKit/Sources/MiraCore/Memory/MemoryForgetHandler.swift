import Foundation

/// Library-scoped handler; normal memory applications and background extraction are work owners
/// of the outer maintenance coordinator and must drain before these methods run.
public struct MemoryForgetHandler: AgentLibraryMaintenanceHandler {
    public let identity = AgentLibraryMaintenanceHandlerIdentity(namespace: "memory.forget", revision: 1)
    private let memories: any MemoryPrivacyStore
    private let sessions: SessionPrivacyMaintenance
    private let plans: any SessionPrivacyPlanStore
    private let business: any AgentBusinessPrivacyStore
    private let projections: SessionPrivacyProjections

    public init(
        memories: any MemoryPrivacyStore, sessions: SessionPrivacyMaintenance,
        plans: any SessionPrivacyPlanStore, business: any AgentBusinessPrivacyStore,
        projections: SessionPrivacyProjections
    ) {
        self.memories = memories
        self.sessions = sessions
        self.plans = plans
        self.business = business
        self.projections = projections
    }
    public func apply(_ operation: AgentLibraryMaintenanceOperation) async throws {
        let scope = try await memories.memoryForgetScope(operation: operation)
        try scope.validate(for: operation)
        let plan = try await sessions.prepare(
            operation: operation, roots: scope.roots,
            retention: .preserveVisibleHistory, reason: .forgotten)
        // The complete provenance and every invalidation batch already have durable identities.
        try await business.purgeSessionResults(plan: plan)
        try await memories.purgeMemoryForget(scope, operation: operation)
        try await sessions.apply(operation: operation)
        try await projections.rebuild(plan: plan)
    }
    public func verify(_ operation: AgentLibraryMaintenanceOperation) async throws {
        let scope = try await memories.memoryForgetScope(operation: operation)
        try scope.validate(for: operation)
        guard let plan = try await plans.load(operation: operation), plan.operation == operation,
            Set(plan.roots) == Set(scope.roots), plan.retention == .preserveVisibleHistory,
            plan.reason == .forgotten
        else { throw MiraError(.storage, "The memory forget plan is unavailable or inconsistent.") }
        try await memories.verifyMemoryForgotten(scope, operation: operation)
        try await business.verifySessionResultsPurged(plan: plan)
        try await sessions.verify(operation: operation)
        try await projections.verify(plan: plan)
    }
}
