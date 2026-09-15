import Foundation

/// Canonical, content-free identities resolved before destructive work. Domain revision and
/// source identities remain available in tombstones so the same operation can resume after purge.
public struct MemoryForgetScope: Sendable, Equatable {
    public let memoryID: MemoryID
    public let workspaceID: WorkspaceID?
    public let expectedRevision: Int
    public let roots: [AgentSourceReference]
    public init(memoryID: MemoryID, workspaceID: WorkspaceID?, expectedRevision: Int, roots: [AgentSourceReference]) {
        self.memoryID = memoryID
        self.workspaceID = workspaceID
        self.expectedRevision = expectedRevision
        self.roots = roots
    }
    public func validate(for operation: AgentLibraryMaintenanceOperation) throws {
        try operation.validate()
        guard operation.completedAt == nil, operation.request.namespace == "memory.forget",
            operation.request.revision == 1,
            operation.request.scope
                == .sources([.domain(namespace: "memories", id: memoryID.rawValue, revision: expectedRevision)]),
            expectedRevision > 0, expectedRevision < Int.max,
            !roots.isEmpty, roots.count <= 8_192, Set(roots).count == roots.count,
            roots.contains(.domain(namespace: "memories", id: memoryID.rawValue, revision: expectedRevision))
        else {
            throw MiraError(.invalidInput, "The memory forget scope is invalid.")
        }
        for source in roots { try source.validate() }
    }
}

/// Owned by the library, independently of application-scoped memory readers and producers.
public protocol MemoryPrivacyStore: Sendable {
    func memoryForgetScope(operation: AgentLibraryMaintenanceOperation) async throws -> MemoryForgetScope
    func purgeMemoryForget(_ scope: MemoryForgetScope, operation: AgentLibraryMaintenanceOperation) async throws
    func verifyMemoryForgotten(_ scope: MemoryForgetScope, operation: AgentLibraryMaintenanceOperation) async throws
}
