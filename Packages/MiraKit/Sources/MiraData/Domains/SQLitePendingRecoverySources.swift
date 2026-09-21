import Foundation
import GRDB
import MiraCore

/// Builds short-lived source and policy capabilities for local restart recovery.
/// Each capability is bound to one persisted maintenance operation; it cannot
/// authorize model or ordinary work while the library is blocked.
extension SQLiteAgentContextPolicy {
    public func pendingRecoveryPolicy(_ operation: AgentLibraryMaintenanceOperation) -> any AgentContextPolicy {
        PendingRecoveryContextPolicy(owner: owner, operation: operation)
    }
}

extension SQLiteMemoryStore {
    public func pendingRecoveryAuthority(
        _ operation: AgentLibraryMaintenanceOperation,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> any AgentDomainSourceAuthority {
        PendingRecoveryDomainAuthority(namespace: "memories") { sources, request in
            guard
                sources.allSatisfy({
                    if case .domain(let namespace, _, let revision) = $0 {
                        return namespace == "memories" && revision > 0
                    }
                    return false
                })
            else { throw PendingRecoveryDomainAuthority.unavailable }
            try await self.owner.recoveryRead(for: operation) { db in
                try SQLiteMemoryStore.validateMemoryContextSources(sources, for: request, at: now(), in: db)
            }
        }
    }
}

extension SQLiteTaskStore {
    public func pendingRecoveryAuthority(
        _ operation: AgentLibraryMaintenanceOperation
    ) -> any AgentDomainSourceAuthority {
        PendingRecoveryDomainAuthority(namespace: "tasks") { sources, request in
            guard
                sources.allSatisfy({
                    if case .domain(let namespace, _, let revision) = $0 {
                        return namespace == "tasks" && revision > 0
                    }
                    return false
                })
            else { throw PendingRecoveryDomainAuthority.unavailable }
            try await self.owner.recoveryRead(for: operation) { db in
                for source in sources {
                    guard case .domain(_, let id, let revision) = source else {
                        throw PendingRecoveryDomainAuthority.unavailable
                    }
                    let task: MiraTask
                    do {
                        task = try SQLiteTaskStore.readTask(.init(id), workspaceID: request.workspaceID, in: db)
                    } catch let error as MiraError where error.code == .notFound {
                        throw PendingRecoveryDomainAuthority.unavailable
                    }
                    guard task.workspaceID == request.workspaceID, task.revision == revision else {
                        throw PendingRecoveryDomainAuthority.unavailable
                    }
                }
            }
        }
    }
}

extension SQLiteKnowledgeStore {
    public func pendingRecoveryAuthorities(
        _ operation: AgentLibraryMaintenanceOperation
    ) -> [any AgentDomainSourceAuthority] {
        [KnowledgeSources.metadataNamespace, KnowledgeSources.chunkNamespace].map { namespace in
            PendingRecoveryDomainAuthority(namespace: namespace) { sources, request in
                guard
                    sources.allSatisfy({
                        if case .domain(let sourceNamespace, _, let revision) = $0 {
                            return sourceNamespace == namespace && revision > 0
                        }
                        return false
                    })
                else { throw PendingRecoveryDomainAuthority.unavailable }
                try await self.owner.recoveryRead(for: operation) { db in
                    try self.validateKnowledgeSources(sources, for: request, in: db)
                }
            }
        }
    }
}

private struct PendingRecoveryContextPolicy: AgentContextPolicy {
    let owner: SQLiteDomainDatabase
    let operation: AgentLibraryMaintenanceOperation

    func validate(_ request: AgentContextRequest) async throws {
        guard request.destination == .local else { throw Self.nonLocal }
        try await owner.recoveryRead(for: operation) { db in
            do { try SQLiteWorkspaceStore.validatePolicy(request.workspaceID, connectionID: nil, in: db) } catch let
                error as MiraError where error.code == .notFound
            {
                throw MiraError(.unauthorized, "The workspace is no longer available for local recovery.")
            }
        }
    }

    private static var nonLocal: MiraError {
        .init(.unauthorized, "Pending recovery is available only for local work.")
    }
}

private struct PendingRecoveryDomainAuthority: AgentDomainSourceAuthority {
    let namespace: String
    let validateSources: @Sendable ([AgentSourceReference], AgentContextRequest) async throws -> Void

    init(
        namespace: String,
        validate: @escaping @Sendable ([AgentSourceReference], AgentContextRequest) async throws -> Void
    ) {
        self.namespace = namespace
        validateSources = validate
    }

    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {
        guard request.destination == .local else { throw Self.nonLocal }
        guard sources.count <= 8_192, Set(sources).count == sources.count else {
            throw MiraError(.invalidInput, "The context source selection is invalid.")
        }
        for source in sources { try source.validate() }
        try await validateSources(sources, request)
    }

    static var unavailable: MiraError {
        .init(.unauthorized, "The context source is unavailable for local recovery.")
    }

    private static var nonLocal: MiraError {
        .init(.unauthorized, "Pending recovery is available only for local work.")
    }
}
