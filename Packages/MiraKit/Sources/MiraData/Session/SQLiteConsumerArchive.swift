import Foundation
import GRDB
import MiraCore

extension SQLiteSessionConsumer {
    public static func archiveModule() throws -> SQLiteArchiveModule {
        try SQLiteArchiveModule(
            identity: .init(name: "session.consumer", revision: 1),
            schemaStatements: archiveSchemaStatements,
            restoration: .preserve
        ) { db, snapshot in
            try validateConsumerArchive(in: db, snapshot: snapshot)
            return []
        }
    }

    private static func validateConsumerArchive(in db: Database, snapshot: FileSessionSnapshot) throws {
        guard try Int.fetchOne(db, sql: "SELECT version FROM mira_session_consumer_schema WHERE id = 1") == 1,
            try Int.fetchOne(db, sql: "SELECT count(*) FROM mira_session_consumer_schema") == 1
        else {
            throw LibraryArchiveIO.invalid
        }
        var revisions: [String: Int] = [:]
        try SQLiteArchiveValidation.rows(in: db, table: "mira_session_consumers") { row in
            guard revisions.count < LibraryArchiveLimits.maximumDomainRows,
                let id: String = row["consumer_id"],
                let revision: Int = row["revision"], revision > 0,
                revisions[id] == nil
            else { throw LibraryArchiveIO.invalid }
            try AgentSessionConsumerIdentity(id: id, revision: revision).validate()
            revisions[id] = revision
        }

        var sessions: [String: [UUID: (sequence: Int64, digest: String)]] = [:]
        var recordCount = 0
        var checkpointCount = 0
        try SQLiteArchiveValidation.rows(in: db, table: "mira_session_consumer_checkpoints") { row in
            guard checkpointCount < LibraryArchiveLimits.maximumDomainRows,
                let consumerID: String = row["consumer_id"],
                let consumerRevision = revisions[consumerID],
                let revision: Int = row["revision"], revision == consumerRevision,
                let sessionRaw: String = row["session_id"],
                let sessionUUID = UUID(uuidString: sessionRaw), sessionUUID.uuidString == sessionRaw,
                let session = snapshot.session(ConversationID(sessionUUID)),
                let sequence: Int64 = row["head_sequence"], sequence > 0,
                let batchRaw: String = row["head_batch_id"],
                let batchID = UUID(uuidString: batchRaw), batchID.uuidString == batchRaw,
                let digest: String = row["batch_digest"], validDigest(digest)
            else {
                throw LibraryArchiveIO.invalid
            }
            checkpointCount += 1
            if sessions[sessionRaw] == nil {
                var records: [UUID: (sequence: Int64, digest: String)] = [:]
                for batch in try snapshot.readBatches(sessionID: session.id) {
                    recordCount += 1
                    guard recordCount <= 1_000_000 else { throw LibraryArchiveIO.invalid }
                    records[batch.id] = (batch.cursor.sequence, self.digest(try SessionCodec.encode(batch)))
                }
                sessions[sessionRaw] = records
            }
            guard let record = sessions[sessionRaw]?[batchID], record.sequence == sequence,
                sequence <= session.head.cursor.sequence, digest == record.digest
            else {
                throw LibraryArchiveIO.invalid
            }
        }
    }
}
