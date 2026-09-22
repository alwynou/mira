import Foundation

/// A body-free, durable handoff from an exact-target tool commit to library maintenance.
public struct MemoryDeletionRequest: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable { case pending, completed, failed }
    public let id: UUID
    public let target: MemoryUsage
    public let source: SessionEvidenceReference
    public let executionID: ExecutionID
    public let workspaceID: WorkspaceID?
    public let requestedAt: Date
    public var state: State

    public init(id: UUID, target: MemoryUsage, source: SessionEvidenceReference, executionID: ExecutionID,
                workspaceID: WorkspaceID?, requestedAt: Date, state: State = .pending) {
        self.id = id; self.target = target; self.source = source; self.executionID = executionID
        self.workspaceID = workspaceID; self.requestedAt = requestedAt; self.state = state
    }

    public var maintenanceRequest: AgentLibraryMaintenanceRequest {
        .init(id: id, namespace: "memory.forget", revision: 1,
              scope: .sources([.domain(namespace: "memories", id: target.memoryID.rawValue, revision: target.revision)]),
              requestedAt: requestedAt)
    }

    public func validate() throws {
        try source.validate()
        guard (1...2_147_483_647).contains(target.revision), requestedAt.timeIntervalSince1970.isFinite else {
            throw MiraError(.invalidInput, "The memory deletion request is invalid.")
        }
        try maintenanceRequest.validate()
    }
}

/// The library processes requests outside execution leases. Completion requires durable
/// maintenance evidence; enqueueing alone never confirms that content was deleted.
public protocol MemoryDeletionStore: Sendable {
    func pendingMemoryDeletions(limit: Int) async throws -> [MemoryDeletionRequest]
    func memoryDeletions(sessionID: ConversationID, executionIDs: Set<ExecutionID>,
                         workspaceID: WorkspaceID?) async throws -> [MemoryDeletionRequest]
    func settleMemoryDeletion(_ request: MemoryDeletionRequest, state: MemoryDeletionRequest.State,
                              authorization: AgentLibraryAuthorization) async throws
}
