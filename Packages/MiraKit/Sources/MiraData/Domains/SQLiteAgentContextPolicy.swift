import Foundation
import GRDB
import MiraCore

/// Rechecks destination permissions and the current frozen model identity against the
/// authoritative business database. The shared database remains owned by the composition root.
public final class SQLiteAgentContextPolicy: AgentContextPolicy, @unchecked Sendable {
    let owner: SQLiteDomainDatabase

    public init(database: DatabaseQueue, libraryID: UUID) throws {
        owner = try SQLiteDomainDatabase(database: database, libraryID: libraryID, label: "mira.agent-context-policy")
    }

    public func close() async { await owner.close() }

    public func validate(_ request: AgentContextRequest) async throws {
        try await owner.read { db in
            let route = request.destination.modelRoute
            try route?.validate()
            do {
                try SQLiteWorkspaceStore.validatePolicy(request.workspaceID, connectionID: route?.connectionID, in: db)
            } catch let error as MiraError where error.code == .notFound {
                throw MiraError(.unauthorized, "The workspace is no longer available for this destination.")
            }
            if let route { try SQLiteAgentModelSettings.validateFrozenIdentity(route, in: db) }
        }
    }
}
