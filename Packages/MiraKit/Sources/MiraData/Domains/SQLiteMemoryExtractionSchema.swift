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
                    "CREATE TABLE memory_extraction_jobs(id TEXT PRIMARY KEY NOT NULL, source_key TEXT NOT NULL, session_id TEXT NOT NULL, execution_id TEXT NOT NULL, workspace_id TEXT REFERENCES business_workspaces(id), policy_revision INTEGER NOT NULL CHECK(policy_revision>0), extractor_revision INTEGER NOT NULL CHECK(extractor_revision>0), state TEXT NOT NULL CHECK(state IN ('queued','running','paused','completed','failed','cancelled','suppressed')), attempt_count INTEGER NOT NULL CHECK(attempt_count BETWEEN 0 AND 100), created_at REAL NOT NULL, json BLOB NOT NULL CHECK(length(json)<=131072), UNIQUE(source_key, policy_revision, extractor_revision))"
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
                (
                    "memory_extraction_attempts",
                    "CREATE TABLE memory_extraction_attempts(id TEXT PRIMARY KEY NOT NULL, job_id TEXT NOT NULL REFERENCES memory_extraction_jobs(id), ordinal INTEGER NOT NULL CHECK(ordinal BETWEEN 1 AND 100), status TEXT NOT NULL CHECK(status IN ('claimed','prepared','dispatched','completed','failed','paused')), budget_day REAL, reserved_tokens INTEGER NOT NULL CHECK(reserved_tokens BETWEEN 0 AND 10000000), charged_tokens INTEGER NOT NULL CHECK(charged_tokens>=0), accounting_digest TEXT NOT NULL CHECK(length(accounting_digest)=64), accounting BLOB NOT NULL CHECK(length(accounting)<=131072), json BLOB NOT NULL CHECK(length(json)<=16777216), UNIQUE(job_id, ordinal))"
                ),
                (
                    "memory_extraction_one_live",
                    "CREATE UNIQUE INDEX memory_extraction_one_live ON memory_extraction_attempts((1)) WHERE status IN ('claimed','prepared','dispatched')"
                ),
                (
                    "memory_extraction_attempts_budget",
                    "CREATE INDEX memory_extraction_attempts_budget ON memory_extraction_attempts(budget_day, status)"
                ),
            ]

    static func initialize(in db: Database) throws {
        try SQLiteDomainDatabase.initialize(definitions, metadata: "memory_extraction_schema", in: db)
    }
}
