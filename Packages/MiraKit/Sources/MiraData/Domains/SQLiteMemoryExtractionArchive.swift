import Foundation
import GRDB
import MiraCore

extension SQLiteMemoryExtractionStore {
    public static func archiveModule() throws -> SQLiteArchiveModule {
        try SQLiteArchiveModule(
            identity: .init(name: "memory.extraction", revision: 1),
            schemaStatements: SQLiteMemoryExtractionSchema.definitions.map(\.1),
            restoration: .prepare(apply: prepareArchiveRestoration, verify: verifyArchiveRestoration)
        ) { db, snapshot in
            try SQLiteArchiveValidation.metadata("memory_extraction_schema", in: db)
            let journal = try SQLiteArchiveSessions(snapshot)
            var jobs: [MemoryExtractionJobID: MemoryExtractionJob] = [:]
            try SQLiteArchiveValidation.rows(in: db, table: "memory_extraction_jobs") { row in
                let value = try job(row)
                try journal.validate(value.origin, workspaceID: value.workspaceID)
                for turn in value.turns { try validateTurn(turn, workspaceID: value.workspaceID, journal: journal) }
                let expectedSources = try Set((value.turns.isEmpty ? [value.origin.source] : value.turns.map(\.source)).map(sourceKey))
                let actualSources = try Set(String.fetchAll(db, sql: "SELECT source_key FROM memory_extraction_sources WHERE job_id=?", arguments: [key(value.id)]))
                guard expectedSources == actualSources else { throw invalid }
                for sourceRow in try Row.fetchAll(db, sql: "SELECT source_key, execution_id FROM memory_extraction_sources WHERE job_id=?", arguments: [key(value.id)]) {
                    let sourceKey: String = sourceRow["source_key"]
                    let turn = try value.turns.first { try Self.sourceKey($0.source) == sourceKey }
                    guard sourceRow["execution_id"] as String == key(turn?.completedExecutionID ?? value.origin.completedExecutionID) else { throw invalid }
                }
                for id in value.memoryIDs {
                    guard
                        try Bool.fetchOne(
                            db, sql: "SELECT EXISTS(SELECT 1 FROM memory_records WHERE id = ?)",
                            arguments: [key(id)]) == true
                    else { throw invalid }
                }
                jobs[value.id] = value
            }
            try SQLiteArchiveValidation.rows(in: db, table: "memory_extraction_dirty") { row in
                let turn = try decode(MemoryExtractionTurn.self, row["json"])
                let workspace = try (row["workspace_id"] as String?).map { WorkspaceID(try SQLiteMemoryStore.uuid($0)) }
                try validateTurn(turn, workspaceID: workspace, journal: journal)
                guard row["source_key"] as String == (try sourceKey(turn.source)),
                      row["session_id"] as String == key(turn.source.sessionID),
                      row["admission_sequence"] as Int64 == turn.source.admissionSequence,
                      row["created_at"] as Double == turn.completedAt.timeIntervalSince1970,
                      try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM memory_extraction_sources WHERE source_key=?)", arguments: [try sourceKey(turn.source)]) != true else { throw invalid }
            }
            try SQLiteArchiveValidation.rows(in: db, table: "memory_extraction_dependencies") { row in
                guard jobs[MemoryExtractionJobID(try SQLiteMemoryStore.uuid(row["job_id"]))] != nil,
                      try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM memory_revisions WHERE memory_id=? AND revision=?)", arguments: [row["memory_id"] as String, row["revision"] as Int]) == true else { throw invalid }
            }
            var ordinals: [MemoryExtractionJobID: Set<Int>] = [:]
            var latest: [MemoryExtractionJobID: AttemptStatus] = [:]
            var liveCount = 0
            try SQLiteArchiveValidation.rows(
                in: db, table: "memory_extraction_attempts",
                maximumRows: 1_000_000, maximumBytes: ["json": 16_777_216]
            ) { row in
                let value = try attempt(row)
                let admitted = value.identity.job
                guard let current = jobs[admitted.id], admitted.origin == current.origin,
                    admitted.workspaceID == current.workspaceID,
                    admitted.extractorRevision == current.extractorRevision, admitted.createdAt == current.createdAt,
                    admitted.turns == current.turns,
                    admitted.updatedAt <= current.updatedAt, admitted.attemptCount <= current.attemptCount,
                    value.identity.attemptID != current.origin.completedExecutionID.rawValue,
                    value.identity.attemptID != current.origin.source.originalExecutionID.rawValue
                else { throw invalid }
                let user = try journal.validate(admitted.origin.source, workspaceID: admitted.workspaceID)
                guard value.identity.admittedAt == user.admittedAt,
                    value.identity.timeZoneIdentifier == user.timeZoneIdentifier,
                    value.identity.sourceEpoch >= user.authorizationEpoch,
                    value.identity.sourceEpoch <= journal.sessions[admitted.origin.source.sessionID]!.authorizationEpoch
                else { throw invalid }
                if value.status.isLive {
                    liveCount += 1
                    guard liveCount <= 1, current.state == .running,
                        admitted.attemptCount == current.attemptCount
                    else { throw invalid }
                }
                if current.state == .suppressed { guard value.bodyPurgedAt != nil else { throw invalid } }
                if admitted.attemptCount == current.attemptCount { latest[current.id] = value.status }
                guard ordinals[current.id, default: []].insert(admitted.attemptCount).inserted else { throw invalid }
            }
            for current in jobs.values {
                let expected = current.attemptCount == 0 ? Set<Int>() : Set(1...current.attemptCount)
                guard ordinals[current.id, default: []] == expected else { throw invalid }
                if current.state == .running { guard latest[current.id]?.isLive == true else { throw invalid } }
                if current.state == .completed { guard latest[current.id] == .completed else { throw invalid } }
            }
            return []
        }
    }

    private static func validateTurn(_ turn: MemoryExtractionTurn, workspaceID: WorkspaceID?, journal: SQLiteArchiveSessions) throws {
        try turn.validate()
        let origin = MemoryExtractionOrigin(source: turn.source, completedExecutionID: turn.completedExecutionID,
            completionEventID: turn.completionEventID, completionHead: turn.completionHead)
        try journal.validate(origin, workspaceID: workspaceID)
        let user = try journal.validate(turn.source, workspaceID: workspaceID)
        guard user.admittedAt == turn.admittedAt,
              journal.sessions[turn.source.sessionID]?.completions[turn.completionEventID]?.occurredAt == turn.completedAt else { throw invalid }
    }

    private static func prepareArchiveRestoration(_ db: Database, _ at: Date) throws {
        try date(at)
        try db.execute(sql: "DELETE FROM memory_extraction_dirty")
        let error = MiraError(.interrupted, "Memory extraction was interrupted before settlement.")
        try SQLiteArchiveValidation.rows(
            in: db, table: "memory_extraction_attempts",
            maximumRows: 1_000_000, maximumBytes: ["json": 16_777_216]
        ) { row in
            var value = try attempt(row)
            guard value.status.isLive else { return }
            var current = try job(value.identity.job.id, in: db)
            try settleFailure(&value, job: &current, error: error, at: at)
            // Preserve pre-dispatch failure vs dispatched uncertainty in the attempt ledger.
            // Neither kind of unfinished job is admitted automatically after restoration.
            current.state = .paused
            try write(value, in: db)
            try write(current, in: db)
        }
        try SQLiteArchiveValidation.rows(in: db, table: "memory_extraction_jobs") { row in
            var value = try job(row)
            guard [.queued, .running, .failed, .paused].contains(value.state) else { return }
            value.state = .paused
            value.error = error
            value.updatedAt = max(at, value.updatedAt)
            try write(value, in: db)
        }
        try verifyArchiveRestoration(db)
    }

    private static func verifyArchiveRestoration(_ db: Database) throws {
        guard
            try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_extraction_dirty") == 0,
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM memory_extraction_jobs WHERE state IN ('queued','running','failed')") == 0,
            try Int.fetchOne(
                db,
                sql:
                    "SELECT count(*) FROM memory_extraction_attempts WHERE status IN ('claimed','prepared','dispatched')"
            ) == 0
        else { throw invalid }
    }
}
