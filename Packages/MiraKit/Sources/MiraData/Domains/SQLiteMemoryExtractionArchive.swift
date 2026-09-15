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
            let policy = try SQLiteMemoryStore.currentCapturePolicy(in: db)
            var jobs: [MemoryExtractionJobID: MemoryExtractionJob] = [:]
            try SQLiteArchiveValidation.rows(in: db, table: "memory_extraction_jobs") { row in
                let value = try job(row)
                try journal.validate(value.origin, workspaceID: value.workspaceID)
                guard value.policyRevision <= policy.revision else { throw invalid }
                for id in value.memoryIDs {
                    guard
                        try Bool.fetchOne(
                            db, sql: "SELECT EXISTS(SELECT 1 FROM memory_records WHERE id = ?)",
                            arguments: [key(id)]) == true
                    else { throw invalid }
                }
                jobs[value.id] = value
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
                    admitted.workspaceID == current.workspaceID, admitted.policyRevision == current.policyRevision,
                    admitted.extractorRevision == current.extractorRevision, admitted.createdAt == current.createdAt,
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
                switch value.identity.binding.scope {
                case .global: break
                case .workspace(let id): guard id == admitted.workspaceID else { throw invalid }
                }
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

    private static func prepareArchiveRestoration(_ db: Database, _ at: Date) throws {
        try date(at)
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
