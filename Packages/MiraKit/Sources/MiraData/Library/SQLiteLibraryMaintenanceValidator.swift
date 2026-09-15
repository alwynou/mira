import Foundation
import GRDB
import MiraCore

/// Domain preconditions run in the same transaction as library maintenance admission.
/// This callback must only read the supplied database; it cannot perform external work.
public struct SQLiteLibraryMaintenanceValidator: Sendable {
    public let identity: AgentLibraryMaintenanceHandlerIdentity
    let validate: @Sendable (AgentLibraryMaintenanceRequest, Database) throws -> Void
    public init(
        identity: AgentLibraryMaintenanceHandlerIdentity,
        validate: @escaping @Sendable (AgentLibraryMaintenanceRequest, Database) throws -> Void
    ) {
        self.identity = identity
        self.validate = validate
    }
}
