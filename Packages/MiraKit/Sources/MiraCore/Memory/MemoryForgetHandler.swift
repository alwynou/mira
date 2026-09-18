import Foundation

/// Library-scoped handler; normal memory applications and background extraction are work owners
/// of the outer maintenance coordinator and must drain before these methods run.
public struct MemoryForgetHandler: AgentLibraryMaintenanceHandler {
    public let identity = AgentLibraryMaintenanceHandlerIdentity(namespace: "memory.forget", revision: 1)
    private let memories: any MemoryPrivacyStore

    public init(memories: any MemoryPrivacyStore) {
        self.memories = memories
    }
    public func apply(_ operation: AgentLibraryMaintenanceOperation) async throws {
        let scope = try await memories.memoryForgetScope(operation: operation)
        try scope.validate(for: operation)
        try await memories.purgeMemoryForget(scope, operation: operation)
    }
    public func verify(_ operation: AgentLibraryMaintenanceOperation) async throws {
        let scope = try await memories.memoryForgetScope(operation: operation)
        try scope.validate(for: operation)
        try await memories.verifyMemoryForgotten(scope, operation: operation)
    }
}
