import Foundation
import GRDB
import MiraCore

extension SQLiteKnowledgeStore {
    /// Source revisions are checked before the pending operation and new epoch can commit.
    public static var maintenanceValidators: [SQLiteLibraryMaintenanceValidator] {
        ["knowledge.revoke", "knowledge.delete"].map { namespace in
            SQLiteLibraryMaintenanceValidator(identity: .init(namespace: namespace, revision: 1)) { request, db in
                guard request.namespace == namespace else { throw unavailable }
                _ = try captureKnowledgePrivacy(request, in: db)
            }
        }
    }
}
