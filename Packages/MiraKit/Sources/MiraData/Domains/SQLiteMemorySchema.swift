import Foundation
import GRDB
import MiraCore

extension SQLiteMemoryStore {
    private static let baseArchiveSchemaDefinitions: [(String, String)] = [
        ("memory_schema", "CREATE TABLE memory_schema(id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL CHECK(version=1))"),
        ("memory_records", "CREATE TABLE memory_records(id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL CHECK(revision>0), scope TEXT NOT NULL, workspace_id TEXT REFERENCES business_workspaces(id), state TEXT NOT NULL CHECK(state IN ('active','candidate','archived','rejected','removed')), superseded_by TEXT REFERENCES memory_records(id), deleted_at REAL, forgotten_at REAL, draft_json BLOB CHECK(length(draft_json)<=131072), json BLOB NOT NULL CHECK(length(json)<=131072))"),
        ("memory_records_scope", "CREATE INDEX memory_records_scope ON memory_records(scope, state, id)"),
        ("memory_sources", "CREATE TABLE memory_sources(source_key TEXT PRIMARY KEY NOT NULL, workspace_id TEXT REFERENCES business_workspaces(id), identity_json BLOB NOT NULL CHECK(length(identity_json)<=131072), body_hash TEXT, suppression INTEGER NOT NULL CHECK(suppression BETWEEN 0 AND 3))"),
        ("memory_evidence", "CREATE TABLE memory_evidence(id TEXT PRIMARY KEY NOT NULL, memory_id TEXT NOT NULL REFERENCES memory_records(id), source_key TEXT NOT NULL REFERENCES memory_sources(source_key), source_workspace_id TEXT REFERENCES business_workspaces(id), json BLOB NOT NULL CHECK(length(json)<=131072), UNIQUE(memory_id, source_key))"),
        ("memory_evidence_source", "CREATE INDEX memory_evidence_source ON memory_evidence(source_key, memory_id)"),
        ("memory_assertions", "CREATE TABLE memory_assertions(assertion_key TEXT PRIMARY KEY NOT NULL, memory_id TEXT NOT NULL REFERENCES memory_records(id), source_key TEXT NOT NULL REFERENCES memory_sources(source_key))"),
        ("memory_extraction_aspects", "CREATE TABLE memory_extraction_aspects(memory_id TEXT PRIMARY KEY NOT NULL REFERENCES memory_records(id), memory_revision INTEGER NOT NULL CHECK(memory_revision>0), source_key TEXT NOT NULL REFERENCES memory_sources(source_key), source_json BLOB NOT NULL CHECK(length(source_json)<=131072), source_hash TEXT NOT NULL CHECK(length(source_hash)=64), semantic_key TEXT, assertion_mode TEXT NOT NULL, change_intent TEXT NOT NULL, metadata_json BLOB NOT NULL CHECK(length(metadata_json)<=131072), created_at REAL NOT NULL, body_purged_at REAL)"),
        ("memory_extraction_aspects_key", "CREATE INDEX memory_extraction_aspects_key ON memory_extraction_aspects(semantic_key, memory_revision)"),
        ("memory_revisions", "CREATE TABLE memory_revisions(memory_id TEXT NOT NULL REFERENCES memory_records(id), revision INTEGER NOT NULL CHECK(revision>0), json BLOB NOT NULL CHECK(length(json)<=131072), PRIMARY KEY(memory_id, revision))"),
        ("memory_replacements", "CREATE TABLE memory_replacements(id TEXT PRIMARY KEY NOT NULL, replacement_id TEXT NOT NULL REFERENCES memory_records(id), previous_id TEXT NOT NULL REFERENCES memory_records(id), state TEXT NOT NULL CHECK(state IN ('proposed','confirmed','rejected')), json BLOB NOT NULL CHECK(length(json)<=131072))"),
        ("memory_replacements_pending", "CREATE UNIQUE INDEX memory_replacements_pending ON memory_replacements(replacement_id, previous_id) WHERE state = 'proposed'"),
        ("memory_operations", "CREATE TABLE memory_operations(operation_id TEXT PRIMARY KEY NOT NULL, request_hash TEXT, memory_id TEXT NOT NULL REFERENCES memory_records(id), receipt_json BLOB CHECK(length(receipt_json)<=131072), CHECK((request_hash IS NULL) = (receipt_json IS NULL)))"),
        ("memory_operation_dependencies", "CREATE TABLE memory_operation_dependencies(operation_id TEXT NOT NULL REFERENCES memory_operations(operation_id), memory_id TEXT NOT NULL REFERENCES memory_records(id), PRIMARY KEY(operation_id, memory_id))"),
        ("memory_purges", "CREATE TABLE memory_purges(operation_id TEXT PRIMARY KEY NOT NULL, memory_id TEXT NOT NULL REFERENCES memory_records(id), workspace_id TEXT REFERENCES business_workspaces(id), expected_revision INTEGER NOT NULL CHECK(expected_revision>0), json BLOB NOT NULL CHECK(length(json)<=131072))"),
        ("memory_search", "CREATE VIRTUAL TABLE memory_search USING fts5(memory_id UNINDEXED, content, tokenize='trigram')")
    ] + vectorSchemaDefinitions

    /// Deletion requests are a separate schema family so the queue can be
    /// initialized independently while still travelling with memory archives.
    static let deletionSchemaDefinitions: [(String, String)] = [
        ("memory_deletion_schema", "CREATE TABLE memory_deletion_schema(id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL CHECK(version=1))"),
        ("memory_deletion_requests", "CREATE TABLE memory_deletion_requests(id TEXT PRIMARY KEY NOT NULL, memory_id TEXT NOT NULL REFERENCES memory_records(id), expected_revision INTEGER NOT NULL CHECK(expected_revision>0), source_key TEXT NOT NULL, source_json BLOB NOT NULL CHECK(length(source_json)<=131072), session_id TEXT NOT NULL, execution_id TEXT NOT NULL, workspace_id TEXT REFERENCES business_workspaces(id), requested_at REAL NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','completed','failed')), json BLOB NOT NULL CHECK(length(json)<=131072))"),
        ("memory_deletion_pending_memory", "CREATE UNIQUE INDEX memory_deletion_pending_memory ON memory_deletion_requests(memory_id) WHERE state = 'pending'"),
        ("memory_deletion_state", "CREATE INDEX memory_deletion_state ON memory_deletion_requests(state, requested_at, id)"),
        ("memory_deletion_session", "CREATE INDEX memory_deletion_session ON memory_deletion_requests(session_id, execution_id, workspace_id, requested_at, id)"),
        ("memory_deletion_source", "CREATE INDEX memory_deletion_source ON memory_deletion_requests(source_key, state, id)")
    ]

    static let archiveSchemaDefinitions: [(String, String)] = baseArchiveSchemaDefinitions + deletionSchemaDefinitions

    static func initialize(in db: Database) throws {
        try SQLiteDomainDatabase.initialize(baseArchiveSchemaDefinitions, metadata: "memory_schema", in: db)
        try SQLiteDomainDatabase.initialize(deletionSchemaDefinitions, metadata: "memory_deletion_schema", in: db)
    }
}
