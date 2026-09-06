import Foundation
import GRDB
import MiraCore

/// Persistence for extractor-owned semantic grouping metadata. This metadata
/// is deliberately separate from MemoryDraft: it is never user-visible
/// content and it cannot grant scope, disclosure, or replacement authority.
struct StoredMemoryAssertionMetadata: Codable, Equatable, Sendable {
    let memoryID: MemoryID
    let memoryRevision: Int
    let sourceMessageID: MessageID
    let sourceRevision: Int
    let semanticKey: String?
    let assertion: MemoryAssertionMetadata
    let sourceHash: String
    let createdAt: Date
    let bodyPurgedAt: Date?
}

extension SQLiteMiraStore {
    private static func assertionTimestampMatches(_ date: Date, _ stored: Double?) -> Bool {
        guard let stored, stored.isFinite, date.timeIntervalSince1970.isFinite else { return false }
        return abs(date.timeIntervalSince1970 - stored) <= max(date.timeIntervalSince1970.ulp, stored.ulp) * 4
    }

    func insertAssertionMetadata(_ assertion: MemoryAssertionMetadata, memoryID: MemoryID, memoryRevision: Int, source: MemoryExtractionSource, at: Date, in db: Database) throws {
        guard memoryRevision > 0, source.sourceRevision > 0, at.timeIntervalSince1970.isFinite, !source.sourceHash.isEmpty else {
            throw MiraError(.invalidInput, "Memory assertion metadata source binding is invalid.")
        }
        let value = StoredMemoryAssertionMetadata(memoryID: memoryID, memoryRevision: memoryRevision, sourceMessageID: source.message.id, sourceRevision: source.sourceRevision, semanticKey: assertion.aspectKey, assertion: assertion, sourceHash: source.sourceHash, createdAt: at, bodyPurgedAt: nil)
        try db.execute(sql: "INSERT INTO memory_assertion_metadata (memory_id, memory_revision, source_message_id, source_revision, semantic_key, assertion_mode, change_intent, source_hash, metadata_json, created_at, body_purged_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)", arguments: [memoryIDString(memoryID), memoryRevision, messageIDString(source.message.id), source.sourceRevision, assertion.aspectKey, assertion.mode.rawValue, assertion.changeIntent.rawValue, source.sourceHash, try Self.encode(value), at.timeIntervalSince1970])
    }

    func assertionMetadata(memoryID: MemoryID, revision: Int, in db: Database) throws -> StoredMemoryAssertionMetadata? {
        guard let row = try Row.fetchOne(db, sql: "SELECT memory_id, memory_revision, source_message_id, source_revision, semantic_key, assertion_mode, change_intent, source_hash, metadata_json, created_at, body_purged_at FROM memory_assertion_metadata WHERE memory_id = ? AND memory_revision = ? AND body_purged_at IS NULL", arguments: [memoryIDString(memoryID), revision]) else { return nil }
        guard let memoryUUID = UUID(uuidString: row["memory_id"] as String), let sourceUUID = UUID(uuidString: row["source_message_id"] as String),
              let mode = MemoryAssertionMode(rawValue: row["assertion_mode"] as String), let changeIntent = MemoryChangeIntent(rawValue: row["change_intent"] as String),
              let sourceHash = row["source_hash"] as String?, !sourceHash.isEmpty else { throw MiraError(.storage, "The memory assertion metadata is invalid.") }
        let assertion = MemoryAssertionMetadata(mode: mode, aspectKey: row["semantic_key"] as String?, changeIntent: changeIntent)
        let value: StoredMemoryAssertionMetadata = try Self.decode(row["metadata_json"] as String)
        guard value.memoryID == MemoryID(memoryUUID), value.memoryRevision == row["memory_revision"] as Int,
              value.sourceMessageID == MessageID(sourceUUID), value.sourceRevision == row["source_revision"] as Int,
              value.semanticKey == assertion.aspectKey, value.assertion == assertion, value.sourceHash == sourceHash,
              Self.assertionTimestampMatches(value.createdAt, row["created_at"] as Double?),
              ((value.bodyPurgedAt == nil && row["body_purged_at"] as Double? == nil) || (value.bodyPurgedAt.map { Self.assertionTimestampMatches($0, row["body_purged_at"] as Double?) } ?? false)) else { throw MiraError(.storage, "The memory assertion metadata is inconsistent.") }
        return value
    }

    /// Forget keeps the row identity for audit/recovery, but removes every
    /// classification value that could retain a body-derived assertion.
    func purgeAssertionMetadata(for memoryIDs: [MemoryID], at: Date, in db: Database) throws {
        guard !memoryIDs.isEmpty else { return }
        for memoryID in memoryIDs {
            try db.execute(sql: "UPDATE memory_assertion_metadata SET semantic_key = NULL, assertion_mode = NULL, change_intent = NULL, source_hash = NULL, metadata_json = NULL, body_purged_at = ? WHERE memory_id = ? AND body_purged_at IS NULL", arguments: [at.timeIntervalSince1970, memoryIDString(memoryID)])
        }
    }

    /// Creates the extractor-owned metadata table. The table is introduced by
    /// the store's schema-12 setup/migration and is kept separate from the
    /// user-visible memory payload.
    static func createMemoryAssertionMetadataSchema(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE memory_assertion_metadata (
          memory_id TEXT PRIMARY KEY NOT NULL REFERENCES memories(id) ON DELETE RESTRICT,
          memory_revision INTEGER NOT NULL CHECK(memory_revision > 0),
          source_message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE RESTRICT,
          source_revision INTEGER NOT NULL CHECK(source_revision > 0),
          semantic_key TEXT,
          assertion_mode TEXT,
          change_intent TEXT,
          source_hash TEXT,
          metadata_json TEXT,
          created_at REAL NOT NULL,
          body_purged_at REAL,
          CHECK(body_purged_at IS NULL OR (
            semantic_key IS NULL AND assertion_mode IS NULL AND change_intent IS NULL AND
            source_hash IS NULL AND metadata_json IS NULL
          )),
          CHECK(body_purged_at IS NOT NULL OR (
            assertion_mode IS NOT NULL AND change_intent IS NOT NULL AND
            source_hash IS NOT NULL AND metadata_json IS NOT NULL
          ))
        );
        CREATE INDEX memory_assertion_metadata_key
          ON memory_assertion_metadata(semantic_key, memory_revision);
        """)
    }

    static func validateMemoryAssertionMetadata(in db: Database) throws {
        for row in try Row.fetchAll(db, sql: "SELECT memory_id, memory_revision, source_message_id, source_revision, semantic_key, assertion_mode, change_intent, source_hash, metadata_json, created_at, body_purged_at FROM memory_assertion_metadata") {
            let invalid = MiraError(.storage, "The memory assertion metadata is invalid.")
            guard let memoryID = UUID(uuidString: row["memory_id"] as String), let sourceID = UUID(uuidString: row["source_message_id"] as String),
                  (row["memory_revision"] as Int) > 0, (row["source_revision"] as Int) > 0,
                  (row["created_at"] as Double).isFinite,
                  let memory = try Row.fetchOne(db, sql: "SELECT revision, source_kind, source_id, forgotten_at FROM memories WHERE id = ?", arguments: [row["memory_id"] as String]),
                  (memory["source_kind"] as String) == "message", (memory["source_id"] as String) == (row["source_message_id"] as String),
                  (row["body_purged_at"] as Double?).map({ $0.isFinite }) ?? true,
                  let boundRevision = try Row.fetchOne(db, sql: "SELECT draft_json, body_purged_at FROM memory_revisions WHERE memory_id = ? AND revision = ?", arguments: [row["memory_id"] as String, row["memory_revision"] as Int]) else { throw invalid }
            let purged = row["body_purged_at"] as Double? != nil
            if purged {
                guard (memory["forgotten_at"] as Double?) != nil,
                      (boundRevision["draft_json"] as String?) == nil,
                      (boundRevision["body_purged_at"] as Double?) != nil,
                      row["semantic_key"] as String? == nil, row["assertion_mode"] as String? == nil, row["change_intent"] as String? == nil, row["source_hash"] as String? == nil, row["metadata_json"] as String? == nil else { throw invalid }
                continue
            }
            // A user revision can supersede the extraction annotation. Keep
            // the original binding valid for audit; evolution checks the
            // binding against the current revision before auto-replacing.
            guard (memory["revision"] as Int) >= (row["memory_revision"] as Int),
                  let modeValue = row["assertion_mode"] as String?, MemoryAssertionMode(rawValue: modeValue) != nil,
                  let changeValue = row["change_intent"] as String?, MemoryChangeIntent(rawValue: changeValue) != nil,
                  let sourceHash = row["source_hash"] as String?, !sourceHash.isEmpty,
                  let metadataJSON = row["metadata_json"] as String?, !metadataJSON.isEmpty,
                  (boundRevision["draft_json"] as String?) != nil,
                  (boundRevision["body_purged_at"] as Double?) == nil,
                  let source = try Row.fetchOne(db, sql: "SELECT role, status, text, body_purged_at FROM messages WHERE id = ?", arguments: [row["source_message_id"] as String]),
                  (source["role"] as String) == MessageRole.user.rawValue, (source["status"] as String) == MessageStatus.committed.rawValue,
                  (memory["forgotten_at"] as Double?) == nil,
                  (source["body_purged_at"] as Double?) == nil else { throw invalid }
            let assertion: StoredMemoryAssertionMetadata
            do { assertion = try decode(metadataJSON) } catch { throw invalid }
            guard assertion.memoryID == MemoryID(memoryID), assertion.memoryRevision == row["memory_revision"] as Int,
                  assertion.sourceMessageID == MessageID(sourceID), assertion.sourceRevision == row["source_revision"] as Int,
                  assertion.assertion.mode.rawValue == modeValue, assertion.assertion.changeIntent.rawValue == changeValue,
                  assertion.assertion.aspectKey == (row["semantic_key"] as String?),
                  assertion.semanticKey == (row["semantic_key"] as String?), assertion.sourceHash == sourceHash,
                  Self.assertionTimestampMatches(assertion.createdAt, row["created_at"] as Double?), assertion.bodyPurgedAt == nil,
                  Self.extractionSourceHash(source["text"] as String) == sourceHash else { throw invalid }
        }
    }
}
