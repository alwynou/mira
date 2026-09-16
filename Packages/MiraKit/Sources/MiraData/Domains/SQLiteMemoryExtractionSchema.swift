import Foundation
import GRDB

/// Current business schema. There is no migration from the removed SQL session runtime.
enum SQLiteMemoryExtractionSchema {
    static let definitions: [(String, String)] = [
                (
                    "memory_extraction_schema",
                    "CREATE TABLE memory_extraction_schema(id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL CHECK(version=1))"
                ),
                (
                    "memory_extraction_jobs",
                    "CREATE TABLE memory_extraction_jobs(id TEXT PRIMARY KEY NOT NULL, source_key TEXT NOT NULL, session_id TEXT NOT NULL, execution_id TEXT NOT NULL, workspace_id TEXT REFERENCES business_workspaces(id), extractor_revision INTEGER NOT NULL CHECK(extractor_revision>0), state TEXT NOT NULL CHECK(state IN ('queued','running','paused','completed','failed','cancelled','suppressed')), attempt_count INTEGER NOT NULL CHECK(attempt_count BETWEEN 0 AND 100), created_at REAL NOT NULL, json BLOB NOT NULL CHECK(length(json)<=131072), UNIQUE(source_key, extractor_revision))"
                ),
                (
                    "memory_extraction_jobs_queue",
                    "CREATE INDEX memory_extraction_jobs_queue ON memory_extraction_jobs(state, created_at, id)"
                ),
                (
                    "memory_extraction_jobs_session",
                    "CREATE INDEX memory_extraction_jobs_session ON memory_extraction_jobs(session_id, created_at, id)"
                ),
                (
                    "memory_extraction_jobs_status",
                    "CREATE INDEX memory_extraction_jobs_status ON memory_extraction_jobs(session_id, execution_id, workspace_id, created_at, id)"
                ),
                (
                    "memory_extraction_jobs_fair_queue",
                    "CREATE INDEX memory_extraction_jobs_fair_queue ON memory_extraction_jobs(session_id, created_at, id) WHERE state = 'queued'"
                ),
                ("memory_extraction_sources", "CREATE TABLE memory_extraction_sources(job_id TEXT NOT NULL REFERENCES memory_extraction_jobs(id), source_key TEXT NOT NULL, execution_id TEXT NOT NULL, PRIMARY KEY(job_id, source_key))"),
                ("memory_extraction_sources_execution", "CREATE INDEX memory_extraction_sources_execution ON memory_extraction_sources(execution_id, job_id)"),
                ("memory_extraction_dependencies", "CREATE TABLE memory_extraction_dependencies(job_id TEXT NOT NULL REFERENCES memory_extraction_jobs(id), memory_id TEXT NOT NULL REFERENCES memory_records(id), revision INTEGER NOT NULL, PRIMARY KEY(job_id, memory_id))"),
                ("memory_extraction_sources_key", "CREATE INDEX memory_extraction_sources_key ON memory_extraction_sources(source_key, job_id)"),
                (
                    "memory_extraction_attempts",
                    "CREATE TABLE memory_extraction_attempts(id TEXT PRIMARY KEY NOT NULL, job_id TEXT NOT NULL REFERENCES memory_extraction_jobs(id), ordinal INTEGER NOT NULL CHECK(ordinal BETWEEN 1 AND 100), status TEXT NOT NULL CHECK(status IN ('claimed','prepared','dispatched','completed','failed','paused')), reserved_tokens INTEGER NOT NULL CHECK(reserved_tokens BETWEEN 0 AND 10000000), charged_tokens INTEGER NOT NULL CHECK(charged_tokens>=0), accounting_digest TEXT NOT NULL CHECK(length(accounting_digest)=64), accounting BLOB NOT NULL CHECK(length(accounting)<=131072), json BLOB NOT NULL CHECK(length(json)<=16777216), UNIQUE(job_id, ordinal))"
                ),
                (
                    "memory_extraction_one_live",
                    "CREATE UNIQUE INDEX memory_extraction_one_live ON memory_extraction_attempts((1)) WHERE status IN ('claimed','prepared','dispatched')"
                ),
                (
                    "memory_extraction_dirty",
                    "CREATE TABLE memory_extraction_dirty(source_key TEXT PRIMARY KEY NOT NULL, session_id TEXT NOT NULL, workspace_id TEXT, json BLOB NOT NULL CHECK(length(json)<=131072), created_at REAL NOT NULL, admission_sequence INTEGER NOT NULL CHECK(admission_sequence>0))"
                ),
                (
                    "memory_extraction_dirty_session",
                    "CREATE INDEX memory_extraction_dirty_session ON memory_extraction_dirty(session_id, admission_sequence)"
                ),
            ]

    static func initialize(in db: Database) throws {
        try SQLiteDomainDatabase.initialize(definitions, metadata: "memory_extraction_schema", in: db)
    }
}
