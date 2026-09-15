import CryptoKit
import Foundation
import GRDB
import MiraCore

extension SQLiteBusinessEffects {
    /// The business module owns these exact tables and indexes. Keeping the statements
    /// shared with initialization prevents an archive from silently accepting another schema.
    static let archiveSchemaStatements: [String] = [
        "CREATE TABLE business_effects_metadata (id INTEGER PRIMARY KEY CHECK(id = 1), format_version INTEGER NOT NULL)",
        "CREATE TABLE business_fences (session_id TEXT NOT NULL, execution_id TEXT NOT NULL, PRIMARY KEY(session_id, execution_id))",
        """
        CREATE TABLE business_operations (namespace TEXT NOT NULL, business_key TEXT NOT NULL, command_digest TEXT NOT NULL,
          result_digest TEXT NOT NULL, result_blob BLOB, result_purged INTEGER NOT NULL CHECK(result_purged IN (0, 1)),
          PRIMARY KEY(namespace, business_key), CHECK((result_blob IS NULL AND result_purged = 1) OR (result_blob IS NOT NULL AND result_purged = 0)))
        """,
        """
        CREATE TABLE business_receipts (sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
          invocation_id TEXT NOT NULL UNIQUE, library_id TEXT NOT NULL, epoch TEXT NOT NULL,
          intent_digest TEXT NOT NULL, result_digest TEXT NOT NULL, operation_namespace TEXT NOT NULL, operation_key TEXT NOT NULL,
          proof_json TEXT NOT NULL, acknowledged INTEGER NOT NULL CHECK(acknowledged IN (0, 1)), publication_json TEXT,
          FOREIGN KEY(operation_namespace, operation_key) REFERENCES business_operations(namespace, business_key))
        """,
        "CREATE INDEX business_receipts_unpublished ON business_receipts(acknowledged, sequence)",
    ]

    static let archiveTableNames = [
        "business_effects_metadata", "business_fences", "business_operations", "business_receipts",
    ]

    public static func archiveModule() throws -> SQLiteArchiveModule {
        try SQLiteArchiveModule(
            identity: .init(name: "business.effects", revision: 1),
            schemaStatements: archiveSchemaStatements, restoration: .preserve
        ) { db, snapshot in
            try inspectArchive(db: db, snapshot: snapshot)
        }
    }

    private struct IntentRecord {
        let sessionID: ConversationID
        let batchID: UUID
        let sequence: Int64
        let proposal: SessionPayloadReference
        let authorization: AgentLibraryAuthorization
        let executionID: ExecutionID
        let invocation: SessionInvocation
    }

    private struct DispatchRecord {
        let sessionID: ConversationID
        let epoch: UInt64
    }

    private struct ResolutionRecord {
        let sessionID: ConversationID
        let sequence: Int64
        let receipt: AgentBusinessReceiptReference?
    }

    private struct JournalIndex {
        var sessions: Set<ConversationID> = []
        var executions: Set<String> = []
        var batchCursors: Set<String> = []
        var intents: [UUID: IntentRecord] = [:]
        var dispatches: [UUID: DispatchRecord] = [:]
        var resolutions: [UUID: ResolutionRecord] = [:]
    }

    private static func inspectArchive(db: Database, snapshot: FileSessionSnapshot) throws -> [LibraryArchiveAttachment]
    {
        let state = try SQLiteLibraryAuthority.readState(in: db)
        guard state.pending == nil,
            try SQLiteLibraryAuthority.availableAuthorization(in: db, libraryID: state.authorization.libraryID)
                == state.authorization,
            try Int.fetchOne(db, sql: "SELECT format_version FROM business_effects_metadata WHERE id = 1") == 1,
            try Int.fetchOne(db, sql: "SELECT count(*) FROM business_effects_metadata") == 1
        else { throw LibraryArchiveIO.invalid }

        let index = try makeIndex(snapshot)
        var receiptKeys = Set<String>()
        var receiptIDs = Set<UUID>()
        var receiptInvocations = Set<UUID>()
        var receiptCount = 0

        let receipts = try Row.fetchCursor(
            db,
            sql: """
                SELECT id, invocation_id, library_id, epoch, intent_digest, result_digest,
                       operation_namespace, operation_key, acknowledged,
                       length(CAST(proof_json AS BLOB)) AS proof_bytes,
                       length(CAST(publication_json AS BLOB)) AS publication_bytes
                FROM business_receipts ORDER BY sequence
                """)
        while let row = try receipts.next() {
            receiptCount += 1
            guard receiptCount <= LibraryArchiveLimits.maximumDomainRows,
                let idText: String = row["id"], let id = UUID(uuidString: idText), id.uuidString == idText,
                receiptIDs.insert(id).inserted,
                let invocationText: String = row["invocation_id"], let invocationID = UUID(uuidString: invocationText),
                invocationID.uuidString == invocationText,
                let libraryText: String = row["library_id"], let receiptLibrary = UUID(uuidString: libraryText),
                receiptLibrary == state.authorization.libraryID, receiptLibrary.uuidString == libraryText,
                let epochText: String = row["epoch"], let epoch = UInt64(epochText), String(epoch) == epochText,
                epoch <= state.authorization.epoch,
                let intentDigest: String = row["intent_digest"], validDigest(intentDigest),
                let resultDigest: String = row["result_digest"], validDigest(resultDigest),
                let namespace: String = row["operation_namespace"], validNamespace(namespace),
                let key: String = row["operation_key"], (1...512).contains(key.utf8.count),
                let acknowledged: Int = row["acknowledged"], acknowledged == 0 || acknowledged == 1,
                let proofBytes: Int = row["proof_bytes"],
                (1...SessionFormatLimits.maximumBatchBytes).contains(proofBytes)
            else { throw LibraryArchiveIO.invalid }

            guard
                let proofText: String = try String.fetchOne(
                    db,
                    sql: "SELECT proof_json FROM business_receipts WHERE id = ?", arguments: [idText]),
                proofText.utf8.count == proofBytes
            else { throw LibraryArchiveIO.invalid }
            let proof: AgentEffectProof
            do {
                proof = try SessionCodec.decode(AgentEffectProof.self, from: Data(proofText.utf8))
                try validateProof(proof, state: state.authorization)
            } catch { throw LibraryArchiveIO.invalid }
            guard proof.invocationID == invocationID,
                proof.authorization.libraryID == receiptLibrary,
                proof.authorization.epoch == epoch,
                proof.proposal.digest == intentDigest,
                let intent = index.intents[invocationID],
                intent.sessionID == proof.sessionID, intent.executionID == proof.executionID,
                intent.invocation.effect == .localWrite,
                intent.batchID == proof.intentBatchID,
                intent.sequence == proof.intentSequence,
                intent.proposal == proof.proposal,
                intent.authorization == proof.authorization,
                index.dispatches[invocationID]?.sessionID == proof.sessionID,
                index.dispatches[invocationID]?.epoch == epoch
            else { throw LibraryArchiveIO.invalid }

            let operationKey = namespace + "\u{0}" + key
            receiptKeys.insert(operationKey)
            receiptInvocations.insert(invocationID)
            guard
                let operation = try Row.fetchOne(
                    db,
                    sql:
                        "SELECT command_digest, result_digest FROM business_operations WHERE namespace = ? AND business_key = ?",
                    arguments: [namespace, key]), (operation["result_digest"] as String?) == resultDigest
            else { throw LibraryArchiveIO.invalid }
            if let url = snapshot.session(proof.sessionID)?.payloads[proof.proposal] {
                let bytes = try BackupFileIO.read(url, limit: proof.proposal.byteCount)
                guard bytes.count == proof.proposal.byteCount, digest(bytes) == proof.proposal.digest else {
                    throw LibraryArchiveIO.invalid
                }
                let proposal = try SessionCodec.decode(AgentToolProposal.self, from: bytes)
                try proposal.validate()
                guard proposal.businessNamespace == namespace, proposal.effect == .localWrite,
                    proposal.descriptor.definition.name == intent.invocation.toolName,
                    proposal.callDigest == intent.invocation.call.digest,
                    digest(try SessionCodec.encode(proposal.plan.input)) == (operation["command_digest"] as String?)
                else { throw LibraryArchiveIO.invalid }
            }
            let reference = AgentBusinessReceiptReference(
                id: id, invocationID: invocationID,
                authorization: proof.authorization, intentDigest: intentDigest, resultDigest: resultDigest)
            try reference.validate()

            if let resolution = index.resolutions[invocationID] {
                guard resolution.receipt == reference else { throw LibraryArchiveIO.invalid }
            }
            if acknowledged == 1 {
                guard let publicationBytes: Int = row["publication_bytes"], (1...16_384).contains(publicationBytes),
                    let publicationText: String = try String.fetchOne(
                        db,
                        sql: "SELECT publication_json FROM business_receipts WHERE id = ?", arguments: [idText]),
                    publicationText.utf8.count == publicationBytes,
                    let cursor = try? SessionCodec.decode(SessionCursor.self, from: Data(publicationText.utf8)),
                    cursor.sessionID == proof.sessionID,
                    index.batchCursors.contains(batchKey(cursor.sessionID, sequence: cursor.sequence)),
                    let resolution = index.resolutions[invocationID], resolution.receipt == reference,
                    resolution.sessionID == cursor.sessionID, resolution.sequence <= cursor.sequence,
                    cursor.sequence > 0
                else { throw LibraryArchiveIO.invalid }
            } else {
                let publicationBytes: Int? = row["publication_bytes"]
                guard publicationBytes == nil else { throw LibraryArchiveIO.invalid }
            }
        }

        let operations = try Row.fetchCursor(
            db,
            sql: """
                SELECT namespace, business_key, command_digest, result_digest, result_purged,
                       length(CAST(result_blob AS BLOB)) AS result_bytes
                FROM business_operations ORDER BY namespace, business_key
                """)
        var operationCount = 0
        while let row = try operations.next() {
            operationCount += 1
            guard operationCount <= LibraryArchiveLimits.maximumDomainRows,
                let namespace: String = row["namespace"], validNamespace(namespace),
                let key: String = row["business_key"], (1...512).contains(key.utf8.count),
                let commandDigest: String = row["command_digest"], validDigest(commandDigest),
                let resultDigest: String = row["result_digest"], validDigest(resultDigest),
                let purged: Int = row["result_purged"], purged == 0 || purged == 1,
                receiptKeys.contains(namespace + "\u{0}" + key)
            else { throw LibraryArchiveIO.invalid }
            if purged == 0 {
                guard let count: Int = row["result_bytes"], (1...65_536).contains(count),
                    let bytes = try Data.fetchOne(
                        db, sql: "SELECT result_blob FROM business_operations WHERE namespace = ? AND business_key = ?",
                        arguments: [namespace, key]),
                    bytes.count == count, digest(bytes) == resultDigest
                else { throw LibraryArchiveIO.invalid }
                _ = try SessionCodec.decode(JSONValue.self, from: bytes)
            } else {
                let resultBytes: Int? = row["result_bytes"]
                guard resultBytes == nil else { throw LibraryArchiveIO.invalid }
            }
        }
        guard operationCount == receiptKeys.count,
            Set(index.resolutions.filter { $0.value.receipt != nil }.keys).isSubset(of: receiptInvocations)
        else { throw LibraryArchiveIO.invalid }

        let fences = try Row.fetchCursor(db, sql: "SELECT session_id, execution_id FROM business_fences")
        var fenceCount = 0
        while let row = try fences.next() {
            fenceCount += 1
            guard fenceCount <= LibraryArchiveLimits.maximumDomainRows else { throw LibraryArchiveIO.invalid }
            guard let sessionText: String = row["session_id"], let sessionID = UUID(uuidString: sessionText),
                sessionID.uuidString == sessionText, index.sessions.contains(ConversationID(sessionID)),
                let executionText: String = row["execution_id"], let executionID = UUID(uuidString: executionText),
                executionID.uuidString == executionText,
                index.executions.contains(executionKey(ConversationID(sessionID), ExecutionID(executionID)))
            else {
                throw LibraryArchiveIO.invalid
            }
        }
        return []
    }

    private static func makeIndex(_ snapshot: FileSessionSnapshot) throws -> JournalIndex {
        var index = JournalIndex()
        var eventCount = 0
        for session in snapshot.sessions {
            var attempts: [UUID: ExecutionID] = [:]
            var invocations: [UUID: SessionInvocation] = [:]
            index.sessions.insert(session.id)
            let batches = try snapshot.readBatches(sessionID: session.id)
            for batch in batches {
                index.batchCursors.insert(batchKey(session.id, sequence: batch.cursor.sequence))
                for event in batch.events {
                    eventCount += 1
                    guard eventCount <= 1_000_000 else { throw LibraryArchiveIO.invalid }
                    switch event.fact {
                    case .admitted(let admission):
                        index.executions.insert(executionKey(session.id, admission.executionID))
                    case .attemptStarted(let attempt):
                        guard attempts[attempt.id] == nil,
                            index.executions.contains(executionKey(session.id, attempt.executionID))
                        else { throw LibraryArchiveIO.invalid }
                        attempts[attempt.id] = attempt.executionID
                    case .toolProposed(let invocation):
                        guard invocations[invocation.id] == nil, attempts[invocation.attemptID] != nil else {
                            throw LibraryArchiveIO.invalid
                        }
                        invocations[invocation.id] = invocation
                    case .toolPrepared(let intent):
                        guard index.intents[intent.invocationID] == nil,
                            let invocation = invocations[intent.invocationID],
                            let executionID = attempts[invocation.attemptID]
                        else { throw LibraryArchiveIO.invalid }
                        index.intents[intent.invocationID] = .init(
                            sessionID: session.id, batchID: batch.id,
                            sequence: event.sequence, proposal: intent.proposal, authorization: intent.authorization,
                            executionID: executionID, invocation: invocation)
                    case .toolDispatched(let invocationID, let epoch):
                        guard index.dispatches[invocationID] == nil else { throw LibraryArchiveIO.invalid }
                        index.dispatches[invocationID] = .init(sessionID: session.id, epoch: epoch)
                    case .toolResolved(let resolution):
                        guard index.resolutions[resolution.invocationID] == nil else { throw LibraryArchiveIO.invalid }
                        index.resolutions[resolution.invocationID] = .init(
                            sessionID: session.id, sequence: event.sequence, receipt: resolution.businessReceipt)
                    default: break
                    }
                }
            }
        }
        return index
    }

    private static func validateProof(_ proof: AgentEffectProof, state: AgentLibraryAuthorization) throws {
        try proof.proposal.validate()
        guard proof.intentSequence > 0, proof.proposal.kind == .effectIntent,
            proof.proposal.sessionID == proof.sessionID,
            proof.proposal.batchID == proof.intentBatchID,
            proof.authorization.libraryID == state.libraryID,
            proof.authorization.epoch <= state.epoch
        else { throw LibraryArchiveIO.invalid }
    }

    private static func validNamespace(_ value: String) -> Bool {
        let bytes = value.utf8
        guard (1...128).contains(bytes.count), let first = bytes.first, (97...122).contains(first) else { return false }
        return bytes.allSatisfy {
            (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 95
                || $0 == 45
        }
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func batchKey(_ sessionID: ConversationID, sequence: Int64) -> String {
        sessionID.rawValue.uuidString + ":" + String(sequence)
    }

    private static func executionKey(_ sessionID: ConversationID, _ executionID: ExecutionID) -> String {
        sessionID.rawValue.uuidString + ":" + executionID.rawValue.uuidString
    }
}
