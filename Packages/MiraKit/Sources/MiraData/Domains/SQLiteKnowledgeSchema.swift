import Foundation
import GRDB
import MiraCore

extension SQLiteKnowledgeStore {
    /// The archive module and the live store must agree on every object, including
    /// virtual tables. Keeping the definitions in one place prevents a restore from
    /// silently accepting a different knowledge schema.
    static let archiveSchemaDefinitions: [(String, String)] = [
        ("knowledge_schema", "CREATE TABLE knowledge_schema(id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL CHECK(version=1))"),
        ("knowledge_blobs", "CREATE TABLE knowledge_blobs(digest TEXT PRIMARY KEY NOT NULL CHECK(length(digest)=64), byte_count INTEGER NOT NULL CHECK(byte_count BETWEEN 0 AND 10485760), created_at REAL NOT NULL, pending_deletion_at REAL)"),
        ("knowledge_sources", "CREATE TABLE knowledge_sources(id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT REFERENCES business_workspaces(id), title TEXT NOT NULL CHECK(length(CAST(title AS BLOB)) BETWEEN 1 AND 1024), current_version_id TEXT, allows_remote_use INTEGER NOT NULL CHECK(allows_remote_use IN (0,1)), revision INTEGER NOT NULL CHECK(revision>0), updated_at REAL NOT NULL, deleted_at REAL, json BLOB NOT NULL CHECK(length(json)<=131072), FOREIGN KEY(current_version_id,id) REFERENCES knowledge_versions(id,source_id))"),
        ("knowledge_versions", "CREATE TABLE knowledge_versions(id TEXT PRIMARY KEY NOT NULL, source_id TEXT NOT NULL REFERENCES knowledge_sources(id), content_hash TEXT NOT NULL REFERENCES knowledge_blobs(digest), byte_count INTEGER NOT NULL CHECK(byte_count BETWEEN 0 AND 10485760), parse_state TEXT NOT NULL CHECK(parse_state IN ('ready','failed')), created_at REAL NOT NULL, json BLOB NOT NULL CHECK(length(json)<=131072), UNIQUE(id,source_id))"),
        ("knowledge_chunks", "CREATE TABLE knowledge_chunks(id TEXT UNIQUE NOT NULL, source_id TEXT NOT NULL REFERENCES knowledge_sources(id), version_id TEXT NOT NULL, sequence INTEGER NOT NULL CHECK(sequence>=0), text TEXT NOT NULL CHECK(length(CAST(text AS BLOB))<=8192), normalized_text TEXT NOT NULL, json BLOB NOT NULL CHECK(length(json)<=131072), UNIQUE(version_id,sequence), FOREIGN KEY(version_id,source_id) REFERENCES knowledge_versions(id,source_id))"),
        ("knowledge_sources_scope", "CREATE INDEX knowledge_sources_scope ON knowledge_sources(workspace_id,deleted_at,updated_at,id)"),
        ("knowledge_versions_source", "CREATE INDEX knowledge_versions_source ON knowledge_versions(source_id,created_at,id)"),
        ("knowledge_versions_blob", "CREATE INDEX knowledge_versions_blob ON knowledge_versions(content_hash)"),
        ("knowledge_chunks_source", "CREATE INDEX knowledge_chunks_source ON knowledge_chunks(source_id,version_id,sequence)"),
        ("knowledge_operations", "CREATE TABLE knowledge_operations(operation_id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('import','allow')), request_hash TEXT, source_id TEXT NOT NULL REFERENCES knowledge_sources(id), receipt_json BLOB CHECK(length(receipt_json)<=131072), CHECK((request_hash IS NULL)=(receipt_json IS NULL)))"),
        ("knowledge_maintenance", "CREATE TABLE knowledge_maintenance(operation_id TEXT PRIMARY KEY NOT NULL, namespace TEXT NOT NULL CHECK(namespace IN ('knowledge.revoke','knowledge.delete')), source_id TEXT NOT NULL REFERENCES knowledge_sources(id), workspace_id TEXT REFERENCES business_workspaces(id), expected_revision INTEGER NOT NULL CHECK(expected_revision>0))"),
        ("knowledge_privacy_scopes", "CREATE TABLE knowledge_privacy_scopes(operation_id TEXT PRIMARY KEY NOT NULL REFERENCES agent_library_maintenance(id), library_id TEXT NOT NULL, byte_count INTEGER NOT NULL CHECK(byte_count BETWEEN 1 AND 2097152), digest TEXT NOT NULL CHECK(length(digest)=64), scope_json BLOB NOT NULL CHECK(length(scope_json) BETWEEN 1 AND 2097152))"),
        ("knowledge_words", "CREATE VIRTUAL TABLE knowledge_words USING fts5(content, tokenize='unicode61')"),
        ("knowledge_trigrams", "CREATE VIRTUAL TABLE knowledge_trigrams USING fts5(content, tokenize='trigram')")
    ]

    static func initialize(in db: Database) throws {
        try SQLiteDomainDatabase.initialize(archiveSchemaDefinitions, metadata: "knowledge_schema", in: db)
    }
}
