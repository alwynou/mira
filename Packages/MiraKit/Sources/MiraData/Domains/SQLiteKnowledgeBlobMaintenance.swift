import Foundation
import GRDB
import MiraCore

extension SQLiteKnowledgeStore: KnowledgeBlobMaintenance {
    public func collectKnowledgeBlobs(operation: AgentLibraryMaintenanceOperation) async throws -> BlobCollectionReport
    {
        try Self.validateCollection(operation)
        return try await owner.maintain(operation) { db in
            try self.blobs.withMaintenanceLock {
                try self.fault(.beforeReferenceScan)
                let retained = try Self.retainedKnowledgeBlobs(in: db)
                let inventory = try self.blobs.inventory()
                try Self.requireRetained(retained, in: inventory)
                let removing = inventory.blobs.keys.filter { retained[$0] == nil }.sorted()
                // The durable pending operation and absence of every version reference authorize
                // deletion. A crash after unlink can leave an unreferenced row, never a live reference.
                for digest in removing {
                    try self.fault(.beforeBlobRemoval)
                    try self.blobs.remove(digest)
                    try self.fault(.afterBlobRemoval)
                    try self.blobs.verifyAbsent(digest)
                }
                _ = try self.blobs.cleanTemporaryFiles()
                try db.execute(
                    sql:
                        "DELETE FROM knowledge_blobs WHERE NOT EXISTS (SELECT 1 FROM knowledge_versions WHERE content_hash = knowledge_blobs.digest)"
                )
                let remaining = try self.blobs.inventory()
                guard remaining.temporaryCount == 0, remaining.blobs == retained else { throw Self.corrupt }
                return .init(removedCount: removing.count, retainedCount: retained.count)
            }
        }
    }

    public func verifyKnowledgeBlobs(operation: AgentLibraryMaintenanceOperation) async throws {
        try Self.validateCollection(operation)
        try await owner.maintain(operation) { db in
            try self.blobs.withMaintenanceLock {
                try self.fault(.beforeReferenceScan)
                let retained = try Self.retainedKnowledgeBlobs(in: db)
                guard
                    try Bool.fetchOne(
                        db,
                        sql:
                            "SELECT EXISTS(SELECT 1 FROM knowledge_blobs WHERE NOT EXISTS (SELECT 1 FROM knowledge_versions WHERE content_hash = knowledge_blobs.digest))"
                    ) == false
                else { throw Self.corrupt }
                let inventory = try self.blobs.inventory()
                guard inventory.temporaryCount == 0, inventory.blobs == retained else { throw Self.corrupt }
            }
        }
    }

    private static func validateCollection(_ operation: AgentLibraryMaintenanceOperation) throws {
        try operation.validate()
        guard operation.completedAt == nil, operation.request.revision == 1 else { throw invalid }
        switch operation.request.namespace {
        case "knowledge.collect":
            guard operation.request.scope == .library else { throw invalid }
        case "knowledge.revoke", "knowledge.delete":
            guard case .sources(let sources) = operation.request.scope, sources.count == 1,
                case .domain(let namespace, _, _) = sources[0], namespace == KnowledgeSources.metadataNamespace
            else { throw invalid }
        default: throw unauthorized
        }
    }

    private static func requireRetained(_ retained: [String: Int], in inventory: ManagedBlobInventory) throws {
        for (digest, bytes) in retained { guard inventory.blobs[digest] == bytes else { throw corrupt } }
    }

    /// Reads domain identity metadata only; failed and historical versions are equally authoritative.
    /// No current-version, scope or remote-use filter may make a referenced blob collectible.
    private static func retainedKnowledgeBlobs(in db: Database) throws -> [String: Int] {
        var metadata: [String: (bytes: Int, pending: Bool)] = [:]
        let blobs = try Row.fetchCursor(
            db, sql: "SELECT digest, byte_count, created_at, pending_deletion_at FROM knowledge_blobs ORDER BY digest")
        while let row = try blobs.next() {
            guard metadata.count < 100_000, let digest: String = row["digest"], isHash(digest),
                let count: Int = row["byte_count"], (0...10 * 1_024 * 1_024).contains(count),
                let created: Double = row["created_at"], created.isFinite,
                (row["pending_deletion_at"] as Double?).map(\.isFinite) ?? true,
                metadata[digest] == nil
            else { throw corrupt }
            metadata[digest] = (count, (row["pending_deletion_at"] as Double?) != nil)
        }
        var retained: [String: Int] = [:]
        var count = 0
        let versions = try Row.fetchCursor(db, sql: "SELECT * FROM knowledge_versions ORDER BY id")
        while let row = try versions.next() {
            guard count < 100_000 else { throw corrupt }
            count += 1
            let value = try version(row)
            guard let blob = metadata[value.contentHash], blob.bytes == value.byteCount, !blob.pending else {
                throw corrupt
            }
            retained[value.contentHash] = value.byteCount
        }
        return retained
    }
}
