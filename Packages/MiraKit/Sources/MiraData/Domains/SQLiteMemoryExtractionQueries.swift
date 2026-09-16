import CryptoKit
import Foundation
import GRDB
import MiraCore

extension SQLiteMemoryExtractionStore {
    public func memoryExtractionStatus(
        sessionID: ConversationID, executionID: ExecutionID, workspaceID: WorkspaceID?,
        before: MemoryExtractionStatusCursor?, limit: Int
    ) async throws -> MemoryExtractionStatusPage {
        guard (1...32).contains(limit),
            before.map({
                $0.sessionID == sessionID && $0.executionID == executionID && $0.workspaceID == workspaceID
                    && $0.createdAt.timeIntervalSince1970.isFinite
            }) ?? true
        else { throw MiraError(.invalidInput, "The extraction status page request is invalid.") }
        return try await owner.read { db in
            var arguments: StatementArguments = [Self.key(sessionID), Self.key(executionID), workspaceID.map(Self.key)]
            var predicate = "session_id = ? AND EXISTS (SELECT 1 FROM memory_extraction_sources s WHERE s.job_id=memory_extraction_jobs.id AND s.execution_id=?) AND workspace_id IS ?"
            if let before {
                predicate += " AND (created_at, id) < (?, ?)"
                arguments += [before.createdAt.timeIntervalSince1970, Self.key(before.jobID)]
            }
            arguments += [limit + 1]
            let jobs = try Row.fetchAll(
                db,
                sql: "SELECT * FROM memory_extraction_jobs WHERE " + predicate
                    + " ORDER BY created_at DESC, id DESC LIMIT ?",
                arguments: arguments
            ).map(Self.job)
            guard jobs.allSatisfy({ $0.origin.completedExecutionID == executionID || $0.turns.contains { $0.completedExecutionID == executionID } }) else { throw Self.invalid }
            let visible = Array(jobs.prefix(limit))
            let cursor =
                jobs.count > limit
                ? visible.last.map {
                    MemoryExtractionStatusCursor(
                        workspaceID: workspaceID, sessionID: sessionID, executionID: executionID,
                        createdAt: $0.createdAt, jobID: $0.id)
                } : nil
            return .init(jobs: visible.map(MemoryExtractionJobSummary.init), nextCursor: cursor)
        }
    }

    public func memoryExtractionReport(
        _ id: MemoryExtractionJobID, sessionID: ConversationID, executionID: ExecutionID, workspaceID: WorkspaceID?
    ) async throws -> MemoryExtractionJobReport {
        try await owner.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql:
                        "SELECT * FROM memory_extraction_jobs WHERE id = ? AND session_id = ? AND EXISTS (SELECT 1 FROM memory_extraction_sources s WHERE s.job_id=memory_extraction_jobs.id AND s.execution_id=?) AND workspace_id IS ?",
                    arguments: [Self.key(id), Self.key(sessionID), Self.key(executionID), workspaceID.map(Self.key)])
            else { throw Self.missing }
            let job = try Self.job(row)
            guard job.origin.completedExecutionID == executionID || job.turns.contains(where: { $0.completedExecutionID == executionID }) else { throw Self.invalid }
            let attempts = try Row.fetchAll(
                db,
                sql: "SELECT " + Self.accountingColumns
                    + " FROM memory_extraction_attempts WHERE job_id = ? ORDER BY ordinal LIMIT 101",
                arguments: [Self.key(id)]
            ).map(Self.accounting)
            guard attempts.count == job.attemptCount,
                attempts.map(\.ordinal) == Array(1..<(job.attemptCount + 1)),
                attempts.allSatisfy({ $0.jobID == job.id }),
                job.state != .suppressed || attempts.allSatisfy({ $0.bodyPurgedAt != nil }),
                job.state != .running || attempts.last?.state.isLive == true,
                job.state != .completed || attempts.last?.state == .completed,
                job.state == .running || attempts.allSatisfy({ !$0.state.isLive })
            else { throw Self.invalid }
            return .init(job: .init(job: job), attempts: attempts)
        }
    }

    // Deliberately excludes the multi-megabyte request/output JSON column. The compact
    // record is written atomically with the attempt, and archive/mutation reads verify equality.
    static let accountingColumns =
        "id, job_id, ordinal, status, reserved_tokens, charged_tokens, accounting_digest, accounting"

    static func accounting(_ row: Row) throws -> MemoryExtractionAttemptUsage {
        let bytes: Data = row["accounting"]
        guard bytes.count <= 131_072,
            SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == row["accounting_digest"] as String
        else { throw invalid }
        let value = try decode(MemoryExtractionAttemptUsage.self, bytes)
        try value.validate()
        guard Self.key(value.id) == row["id"] as String,
            Self.key(value.jobID) == row["job_id"] as String,
            value.ordinal == row["ordinal"] as Int,
            value.state.rawValue == row["status"] as String,
            value.reservedTokens == row["reserved_tokens"] as Int,
            value.chargedTokens == row["charged_tokens"] as Int
        else { throw invalid }
        return value
    }
}
