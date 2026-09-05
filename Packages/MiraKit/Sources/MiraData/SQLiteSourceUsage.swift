import Foundation
import GRDB
import MiraCore

extension SQLiteMiraStore {
    public func recordSourceUsage(_ usages: [SourceUsage], executionID: ExecutionID, at: Date) throws {
        try safely { try pool.write { db in
            try validateSourceUsages(usages, executionID: executionID, in: db)
            for usage in Set(usages) { try persistSourceUsage(usage, executionID: executionID, at: at, in: db) }
        }}
    }

    public func validateSourceUsage(executionID: ExecutionID) throws {
        try safely { try pool.read { db in
            try validateSourceUsages(sourceUsages(executionID: executionID, in: db), executionID: executionID, in: db)
        }}
    }

    public func sourceCitation(_ reference: SourceCitationReference, executionID: ExecutionID, conversationID: ConversationID) throws -> SourceCitationDetail {
        try safely { try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT e.route_json, c.workspace_id FROM executions e JOIN conversations c ON c.id = e.conversation_id WHERE e.id = ? AND e.conversation_id = ? AND e.body_purged_at IS NULL", arguments: [Self.id(executionID), Self.id(conversationID)]),
                  try Int.fetchOne(db, sql: "SELECT 1 FROM source_usages WHERE execution_id = ? AND version_id = ? AND chunk_key = ?", arguments: [Self.id(executionID), Self.id(reference.versionID), Self.id(reference.chunkID)]) != nil else { throw MiraError(.unauthorized, "This source citation was not used by this reply or is no longer available.") }
            let workspaceID: WorkspaceID? = try (row["workspace_id"] as String?).map { value in
                guard let uuid = UUID(uuidString: value) else { throw MiraError(.storage, "The source workspace identifier is invalid.") }
                return .init(uuid)
            }
            let route = try Self.decodeRoute(row["route_json"])
            let chunk = try requireSourceChunk(reference.chunkID, in: db)
            guard chunk.summary.sourceVersionID == reference.versionID else { throw MiraError(.unauthorized, "The source citation version does not match its chunk.") }
            let source = try requireKnowledgeSource(chunk.summary.sourceID, workspaceID: workspaceID, connectionID: route.connectionID, in: db)
            let version = try requireSourceVersion(reference.versionID, sourceID: source.id, in: db)
            _ = try blobs.read(version.contentHash)
            return .init(source: source, version: version, chunk: chunk)
        }}
    }

    func sourceUsages(executionID: ExecutionID, in db: Database) throws -> [SourceUsage] {
        try Row.fetchAll(db, sql: "SELECT source_id, version_id, chunk_key FROM source_usages WHERE execution_id = ? ORDER BY source_id, version_id, chunk_key", arguments: [Self.id(executionID)]).map { row in
            guard let source = UUID(uuidString: row["source_id"]), let version = UUID(uuidString: row["version_id"]) else { throw MiraError(.storage, "The source usage identifiers are invalid.") }
            let key: String = row["chunk_key"]
            guard key.isEmpty || UUID(uuidString: key) != nil else { throw MiraError(.storage, "The source usage chunk identifier is invalid.") }
            return .init(sourceID: .init(source), sourceVersionID: .init(version), chunkID: UUID(uuidString: key).map { .init($0) })
        }
    }

    func validateSourceUsages(_ usages: [SourceUsage], executionID: ExecutionID, in db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT e.route_json, c.workspace_id FROM executions e JOIN conversations c ON c.id = e.conversation_id WHERE e.id = ? AND e.status IN ('queued','waitingForModel') AND e.body_purged_at IS NULL AND c.is_archived = 0", arguments: [Self.id(executionID)]) else { throw MiraError(.unauthorized, "The source tool context is no longer authorized.") }
        guard !usages.isEmpty else { return }
        let route = try Self.decodeRoute(row["route_json"])
        guard try currentRoute(for: route, in: db) == route else { throw MiraError(.connectionChanged, "Model configuration changed. Send the request again.") }
        let workspaceID: WorkspaceID? = try (row["workspace_id"] as String?).map { value in
            guard let id = UUID(uuidString: value) else { throw MiraError(.storage, "The source workspace identifier is invalid.") }
            return .init(id)
        }
        for usage in usages {
            _ = try requireKnowledgeSource(usage.sourceID, workspaceID: workspaceID, connectionID: route.connectionID, in: db)
            let version = try requireSourceVersion(usage.sourceVersionID, sourceID: usage.sourceID, in: db)
            guard version.parseState == .ready else { throw MiraError(.unauthorized, "The source version has no readable content.") }
            if let id = usage.chunkID {
                let chunk = try requireSourceChunk(id, in: db)
                guard chunk.summary.sourceID == usage.sourceID, chunk.summary.sourceVersionID == usage.sourceVersionID else { throw MiraError(.unauthorized, "The source usage does not match its chunk.") }
            }
        }
    }

    func persistSourceUsage(_ usage: SourceUsage, executionID: ExecutionID, at: Date, in db: Database) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO source_usages (execution_id,source_id,version_id,chunk_key,created_at) VALUES (?,?,?,?,?)", arguments: [Self.id(executionID), Self.id(usage.sourceID), Self.id(usage.sourceVersionID), usage.chunkID.map(Self.id) ?? "", at.timeIntervalSince1970])
    }

    /// Memory context has already validated and recorded the same canonical history dependencies.
    func prepareSourceContext(_ request: CanonicalModelRequest, executionID: ExecutionID, at: Date, in db: Database) throws -> [RequestContextInfo.Reference] {
        var usages = Set(try sourceUsages(executionID: executionID, in: db))
        for row in try Row.fetchAll(db, sql: "SELECT source_execution_id FROM execution_history_dependencies WHERE execution_id = ?", arguments: [Self.id(executionID)]) {
            guard let uuid = UUID(uuidString: row["source_execution_id"]) else { throw MiraError(.storage, "The source history dependency is invalid.") }
            usages.formUnion(try sourceUsages(executionID: .init(uuid), in: db))
        }
        for reference in request.contextInfo?.references ?? [] where reference.kind == "sourceChunk" || reference.kind == "sourceVersion" {
            let valid = usages.contains { reference.kind == "sourceChunk" ? $0.chunkID.map(Self.id) == reference.id.lowercased() : Self.id($0.sourceVersionID) == reference.id.lowercased() }
            guard valid else { throw MiraError(.unauthorized, "The request contains an unverified source reference.") }
        }
        try validateSourceUsages(Array(usages), executionID: executionID, in: db)
        for usage in usages { try persistSourceUsage(usage, executionID: executionID, at: at, in: db) }
        let versions = Set(usages.map { Self.id($0.sourceVersionID) }).sorted().map { RequestContextInfo.Reference(kind: "sourceVersion", id: $0) }
        let chunks = Set(usages.compactMap { $0.chunkID.map(Self.id) }).sorted().map { RequestContextInfo.Reference(kind: "sourceChunk", id: $0) }
        return versions + chunks
    }

    func purgeSourceConsumers(_ sourceID: KnowledgeSourceID, at: Date, in db: Database) throws {
        let executions = try String.fetchAll(db, sql: "WITH RECURSIVE affected(id) AS (SELECT execution_id FROM source_usages WHERE source_id = ? UNION SELECT d.execution_id FROM execution_history_dependencies d JOIN affected a ON d.source_execution_id = a.id) SELECT id FROM affected", arguments: [Self.id(sourceID)])
        for key in executions {
            for trigger in try String.fetchAll(db, sql: "SELECT trigger_message_id FROM executions WHERE id = ?", arguments: [key]) {
                if let uuid = UUID(uuidString: trigger) { try purgeMemoryExtractionForSourceMessage(.init(uuid), at: at, in: db) }
            }
            let time = at.timeIntervalSince1970
            try db.execute(sql: "UPDATE executions SET body_purged_at = ?, error_json = NULL, status = CASE WHEN status IN ('queued','waitingForModel') THEN 'interrupted' ELSE status END, updated_at = ? WHERE id = ?", arguments: [time, time, key])
            try db.execute(sql: "UPDATE model_attempts SET request_json = NULL, output_json = NULL, error_json = NULL, body_purged_at = ?, status = CASE WHEN status = 'prepared' THEN 'interrupted' ELSE status END, completed_at = CASE WHEN status = 'prepared' THEN COALESCE(completed_at, ?) ELSE completed_at END WHERE execution_id = ?", arguments: [time, time, key])
            try db.execute(sql: "UPDATE tool_invocations SET arguments_json = NULL, result_json = NULL, body_purged_at = ?, status = CASE WHEN status = 'pending' THEN 'cancelledBeforeDispatch' WHEN status = 'dispatched' THEN 'interrupted' ELSE status END, completed_at = CASE WHEN status IN ('pending','dispatched') THEN COALESCE(completed_at, ?) ELSE completed_at END WHERE execution_id = ?", arguments: [time, time, key])
            try db.execute(sql: "UPDATE execution_steps SET output_json = NULL, error_json = NULL, body_purged_at = ?, state = CASE WHEN state IN ('running','waitingForTool') THEN 'interrupted' ELSE state END, completed_at = CASE WHEN state IN ('running','waitingForTool') THEN COALESCE(completed_at, ?) ELSE completed_at END WHERE execution_id = ?", arguments: [time, time, key])
            try db.execute(sql: "UPDATE messages SET text = '', body_purged_at = ? WHERE execution_id = ? AND role = 'assistant'", arguments: [time, key])
            try db.execute(sql: "UPDATE assistant_drafts SET text = '', body_purged_at = ? WHERE execution_id = ?", arguments: [time, key])
        }
    }

    public func collectUnreferencedBlobs(at: Date) throws -> BlobCollectionReport {
        try blobs.withMaintenanceLock {
            try knowledgeFaultInjector(.beforeReferenceScan)
            let temporaryCount = try blobs.cleanTemporaryFiles()
            let digests = try blobs.digests()
            var removed = temporaryCount, retained = 0
            // The filesystem and all reference-creating transactions share this lock; no await occurs here.
            for digest in digests {
                let eligible = try pool.write { db -> Bool in
                    if try Int.fetchOne(db, sql: "SELECT 1 FROM source_versions WHERE content_hash = ? LIMIT 1", arguments: [digest]) != nil { return false }
                    if let pending = try Double.fetchOne(db, sql: "SELECT pending_deletion_at FROM managed_blobs WHERE digest = ?", arguments: [digest]) {
                        return at.timeIntervalSince1970 - pending >= 7 * 86_400
                    }
                    let bytes = try blobs.read(digest).count
                    try db.execute(sql: "INSERT INTO managed_blobs (digest,byte_count,created_at,pending_deletion_at) VALUES (?,?,?,?) ON CONFLICT(digest) DO UPDATE SET pending_deletion_at=excluded.pending_deletion_at", arguments: [digest, bytes, at.timeIntervalSince1970, at.timeIntervalSince1970])
                    return false
                }
                if eligible {
                    try knowledgeFaultInjector(.beforeBlobRemoval)
                    try blobs.remove(digest)
                    try knowledgeFaultInjector(.afterBlobRemoval)
                    try pool.write { db in try db.execute(sql: "DELETE FROM managed_blobs WHERE digest = ? AND NOT EXISTS (SELECT 1 FROM source_versions WHERE content_hash = ?)", arguments: [digest, digest]) }
                    removed += 1
                } else { retained += 1 }
            }
            return .init(removedCount: removed, retainedCount: retained)
        }
    }
}
