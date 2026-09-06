import Foundation
import GRDB
import MiraCore

extension SQLiteMiraStore {
    public func completeMemoryExtraction(_ claim: MemoryExtractionClaim, output: ModelOutput, usage: TokenUsage, at: Date) throws -> MemoryExtractionJob {
        try Self.validateModelOutput(output)
        let outcome: Result<MemoryExtractionJob, MiraError> = try safely { try pool.write { db in
            let key = uuidString(claim.attemptID)
            guard let attempt = try Row.fetchOne(db, sql: "SELECT job_id, lease_id, status, body_purged_at FROM memory_extraction_attempts WHERE id = ?", arguments: [key]),
                  (attempt["job_id"] as String) == id(claim.job.id),
                  (attempt["lease_id"] as String) == uuidString(claim.leaseID),
                  (attempt["body_purged_at"] as Double?) == nil else {
                throw MiraError(.conflict, "The memory extraction attempt is no longer owned by this worker.")
            }
            if (attempt["status"] as String) == "completed" {
                return .success(try completedExtractionJob(claim.job.id, in: db))
            }
            guard (attempt["status"] as String) == "dispatched" else {
                throw MiraError(.conflict, "The memory extraction attempt was not dispatched or is already closed.")
            }
            let current = try loadRevalidateMemoryExtractionClaim(claim, at: at, in: db)
            let proposals: [MemoryExtractionProposal]
            do {
                guard output.toolCalls.isEmpty, output.finishReason == .stop else {
                    throw MiraError(.malformedStream, "Automatic memory requires a complete text-only response.")
                }
                proposals = try MemoryExtractionValidator.validate(output: output.text, source: current.source, mode: current.policy.mode)
            } catch {
                // A rejected model result still consumed tokens. Commit settlement
                // before returning its error; no Memory rows have been written.
                let safe = MiraError.safe(error)
                try settleMemoryExtractionAttempt(claim, usage: usage, at: at, in: db)
                try db.execute(sql: "UPDATE memory_extraction_attempts SET status = 'failed', output_json = ? WHERE id = ?", arguments: [output.text.utf8.count <= 32_768 && output.toolCalls.isEmpty ? try Self.encode(output) : nil, key])
                try closeExtractionJob(claim.job.id, state: .failed, error: safe, at: at, in: db)
                return .failure(safe)
            }

            for proposal in proposals {
                try commitExtractionProposal(proposal, claim: claim, source: current.source, at: at, in: db)
            }
            try settleMemoryExtractionAttempt(claim, usage: usage, at: at, in: db)
            try db.execute(sql: "UPDATE memory_extraction_attempts SET output_json = ? WHERE id = ?", arguments: [try Self.encode(output), key])
            try closeExtractionJob(claim.job.id, state: .completed, error: nil, at: at, in: db)
            return .success(try completedExtractionJob(claim.job.id, in: db))
        }}
        return try outcome.get()
    }

    private func commitExtractionProposal(_ proposal: MemoryExtractionProposal, claim: MemoryExtractionClaim, source: MemoryExtractionSource, at: Date, in db: Database) throws {
        let draft = proposal.draft
        let assertionHash = memoryHash(draft.content)
        // Deliberately independent of policy/extractor versions and wording in a
        // model's confidence explanation. Suppression is checked before here.
        let candidateKey = memoryPayloadHashString([messageIDString(source.message.id), String(source.sourceRevision), draft.scope.key, draft.subject.rawValue, assertionHash].joined(separator: "\n"))
        var memoryID: MemoryID?
        var disposition = "duplicate"
        var reason = proposal.reviewReason
        if let prior = try Row.fetchOne(db, sql: "SELECT memory_id FROM memory_extraction_decisions WHERE source_message_id = ? AND source_revision = ? AND candidate_key = ? ORDER BY changed_at, id LIMIT 1", arguments: [messageIDString(source.message.id), source.sourceRevision, candidateKey]) {
            memoryID = try (prior["memory_id"] as String?).map(self.memoryID)
        } else if let existing = try String.fetchOne(db, sql: "SELECT id FROM memories WHERE source_kind = 'message' AND source_id = ? AND subject = ? AND scope_key = ? AND assertion_hash = ? LIMIT 1", arguments: [messageIDString(source.message.id), draft.subject.rawValue, draft.scope.key, assertionHash]) {
            memoryID = try self.memoryID(existing)
        } else {
            // A second assertion in an occupied category is a review candidate.
            // This broad deterministic barrier intentionally sacrifices recall:
            // it cannot establish semantic agreement or supersede a user's fact.
            let hasExistingCategory = try Int.fetchOne(db, sql: "SELECT 1 FROM memories WHERE scope_key = ? AND subject = ? AND state = 'active' AND superseded_by IS NULL AND forgotten_at IS NULL AND deleted_at IS NULL AND json_extract(draft_json, '$.kind') = ? LIMIT 1", arguments: [draft.scope.key, draft.subject.rawValue, draft.kind.rawValue]) != nil
            let state: MemoryState = proposal.triage == .active && !hasExistingCategory ? .active : .candidate
            if hasExistingCategory { reason = "Memory review required: an existing memory may cover this category." }
            let memory = Memory(draft: draft, scope: draft.scope, subject: draft.subject, state: state, origin: proposal.origin, authority: proposal.authority, createdAt: at, updatedAt: at)
            memoryID = memory.id
            disposition = state.rawValue
            try insertMemory(memory, sourceKind: .message, sourceID: source.message.id.rawValue, assertionHash: assertionHash, in: db)
            try insertMemoryEvidence(.init(memoryID: memory.id, sourceKind: .message, sourceID: source.message.id.rawValue, sourceRevision: source.sourceRevision, conversationID: source.message.conversationID, excerpt: proposal.quote, sourceHash: source.sourceHash, createdAt: at), in: db)
            try insertMemoryRevision(.init(memoryID: memory.id, revision: 1, draft: draft, actor: "memoryExtraction", changedAt: at), in: db)
            try indexMemory(memory, in: db)
        }
        if let memoryID {
            guard let row = try Row.fetchOne(db, sql: "SELECT revision, forgotten_at FROM memories WHERE id = ?", arguments: [memoryIDString(memoryID)]), (row["forgotten_at"] as Double?) == nil else {
                throw MiraError(.conflict, "A forgotten memory cannot be recreated by extraction.")
            }
            // Capture binds the original source and every retry execution so
            // forgetting can purge dependent foreground and background bodies.
            let executions = try String.fetchAll(db, sql: "SELECT id FROM executions WHERE trigger_message_id = ? AND body_purged_at IS NULL", arguments: [messageIDString(source.message.id)])
            for execution in executions {
                try persistMemoryUsages([.init(memoryID: memoryID, revision: row["revision"] as Int)], executionID: try executionID(execution), at: at, kind: .capture, in: db)
            }
        }
        try db.execute(sql: "INSERT INTO memory_extraction_decisions (id, job_id, source_message_id, source_revision, candidate_key, disposition, memory_id, excerpt, source_hash, policy_revision, changed_at, body_purged_at, review_reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)", arguments: [uuidString(UUID()), id(claim.job.id), messageIDString(source.message.id), source.sourceRevision, candidateKey, disposition, memoryID.map(memoryIDString), proposal.quote, source.sourceHash, claim.policy.revision, at.timeIntervalSince1970, reason])
    }

    private func closeExtractionJob(_ jobID: MemoryExtractionJobID, state: MemoryExtractionJobState, error: MiraError?, at: Date, in db: Database) throws {
        try db.execute(sql: "UPDATE memory_extraction_jobs SET state = ?, lease_id = NULL, lease_expires_at = NULL, updated_at = ?, error_json = ? WHERE id = ? AND state = 'running'", arguments: [state.rawValue, at.timeIntervalSince1970, try error.map(Self.encode), id(jobID)])
        guard db.changesCount == 1 else { throw MiraError(.conflict, "The memory extraction claim is no longer active.") }
    }

    private func completedExtractionJob(_ jobID: MemoryExtractionJobID, in db: Database) throws -> MemoryExtractionJob {
        guard let row = try Row.fetchOne(db, sql: "SELECT id, source_message_id, conversation_id, policy_revision, extractor_version, state, attempt_count, created_at, updated_at, error_json FROM memory_extraction_jobs WHERE id = ?", arguments: [id(jobID)]) else {
            throw MiraError(.storage, "The memory extraction job is missing.")
        }
        return try extractionJob(row, in: db)
    }
}
