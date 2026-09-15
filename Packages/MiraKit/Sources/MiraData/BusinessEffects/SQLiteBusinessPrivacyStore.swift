import Foundation
import GRDB
import MiraCore

/// Purges shared result bodies without removing committed receipt or outbox identities.
/// This library-scoped adapter remains open after application effect executors drain.
public final class SQLiteBusinessPrivacyStore: AgentBusinessPrivacyStore, @unchecked Sendable {
    private let owner: SQLiteDomainDatabase

    public init(database: DatabaseQueue, libraryID: UUID) throws {
        owner = try SQLiteDomainDatabase(database: database, libraryID: libraryID, label: "mira.business-privacy")
        do {
            try database.read { db in
                for table in [
                    "business_effects_metadata", "business_fences", "business_operations", "business_receipts",
                ] {
                    guard try db.tableExists(table) else { throw Self.invalid }
                }
                guard
                    try Int.fetchOne(db, sql: "SELECT format_version FROM business_effects_metadata WHERE id = 1") == 1
                else { throw Self.invalid }
            }
        } catch { throw error as? MiraError ?? Self.invalid }
    }

    public func close() async { await owner.close() }

    public func purgeSessionResults(plan: SessionPrivacyPlan) async throws {
        try plan.validate()
        try await owner.maintain(plan.operation) { db in
            try Self.visitSelectedOperations(plan: plan, in: db) { namespace, key in
                try db.execute(
                    sql:
                        "UPDATE business_operations SET result_blob = NULL, result_purged = 1 WHERE namespace = ? AND business_key = ?",
                    arguments: [namespace, key])
                guard db.changesCount == 1 else { throw Self.invalid }
            }
        }
    }

    public func verifySessionResultsPurged(plan: SessionPrivacyPlan) async throws {
        try plan.validate()
        try await owner.maintain(plan.operation) { db in
            try Self.visitSelectedOperations(plan: plan, in: db) { namespace, key in
                guard
                    let row = try Row.fetchOne(
                        db,
                        sql:
                            "SELECT result_blob IS NULL AS absent, result_purged FROM business_operations WHERE namespace = ? AND business_key = ?",
                        arguments: [namespace, key]),
                    row["absent"] as Int? == 1, row["result_purged"] as Int? == 1
                else { throw Self.invalid }
            }
        }
    }

    private struct ExecutionAddress: Hashable {
        let sessionID: ConversationID
        let executionID: ExecutionID
    }

    private static func visitSelectedOperations(
        plan: SessionPrivacyPlan, in db: Database,
        visit: (String, String) throws -> Void
    ) throws {
        let executions = Set(
            plan.changes.flatMap { change in
                change.dependencies.map {
                    ExecutionAddress(sessionID: change.batch.sessionID, executionID: $0.executionID)
                }
            })
        let heads = Dictionary(uniqueKeysWithValues: plan.heads.map { ($0.cursor.sessionID, $0.cursor.sequence) })
        // Read only bounded proof metadata, never all result bodies or an unbounded receipt array.
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT id, invocation_id, library_id, epoch, intent_digest, result_digest,
                       operation_namespace, operation_key, length(CAST(proof_json AS BLOB)) AS proof_bytes
                FROM business_receipts ORDER BY sequence
                """)
        while let row = try cursor.next() {
            guard let idText: String = row["id"], let id = UUID(uuidString: idText), id.uuidString == idText,
                let invocationText: String = row["invocation_id"], let invocationID = UUID(uuidString: invocationText),
                invocationID.uuidString == invocationText,
                let storedLibrary: String = row["library_id"],
                storedLibrary == plan.operation.authorization.libraryID.uuidString,
                let storedEpochText: String = row["epoch"], let storedEpoch = UInt64(storedEpochText),
                String(storedEpoch) == storedEpochText,
                storedEpoch <= plan.operation.previousAuthorization.epoch,
                let intentDigest: String = row["intent_digest"], let resultDigest: String = row["result_digest"],
                let namespace: String = row["operation_namespace"], (1...128).contains(namespace.utf8.count),
                let businessKey: String = row["operation_key"], (1...512).contains(businessKey.utf8.count),
                let proofBytes: Int = row["proof_bytes"],
                (1...SessionFormatLimits.maximumBatchBytes).contains(proofBytes)
            else { throw invalid }
            guard
                let proofJSON = try String.fetchOne(
                    db, sql: "SELECT proof_json FROM business_receipts WHERE id = ?", arguments: [idText]),
                proofJSON.utf8.count == proofBytes
            else { throw invalid }
            let proof: AgentEffectProof
            do {
                proof = try SessionCodec.decode(AgentEffectProof.self, from: Data(proofJSON.utf8))
                try proof.proposal.validate()
                try AgentBusinessReceiptReference(
                    id: id, invocationID: invocationID,
                    authorization: .init(libraryID: plan.operation.authorization.libraryID, epoch: storedEpoch),
                    intentDigest: intentDigest, resultDigest: resultDigest
                ).validate()
            } catch { throw invalid }
            guard proof.invocationID == invocationID, proof.authorization.libraryID.uuidString == storedLibrary,
                proof.authorization.epoch == storedEpoch, proof.proposal.digest == intentDigest,
                proof.proposal.kind == .effectIntent, proof.proposal.sessionID == proof.sessionID,
                proof.proposal.batchID == proof.intentBatchID, proof.intentSequence > 0
            else { throw invalid }
            guard executions.contains(.init(sessionID: proof.sessionID, executionID: proof.executionID)) else {
                continue
            }
            guard let head = heads[proof.sessionID], proof.intentSequence <= head,
                let operation = try Row.fetchOne(
                    db, sql: "SELECT result_digest FROM business_operations WHERE namespace = ? AND business_key = ?",
                    arguments: [namespace, businessKey]),
                operation["result_digest"] as String? == resultDigest
            else { throw invalid }
            // A business key can be shared by multiple receipts. Repeating this idempotent update
            // avoids retaining an unbounded operation set and purges every reader of the shared body.
            try visit(namespace, businessKey)
        }
    }

    private static var invalid: MiraError { .init(.storage, "The business privacy record is inconsistent.") }
}
