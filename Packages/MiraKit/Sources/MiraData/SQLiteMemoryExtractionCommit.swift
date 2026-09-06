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
            // Same-kind memories can coexist. Only an exact extractor-owned
            // aspect key is a possible conflict; a missing or ambiguous key
            // remains a review candidate and never triggers replacement.
            let matching = try currentMemories(matching: proposal.assertion, draft: draft, in: db)
            let current = matching.count == 1 ? matching[0].memory : nil
            let canReplace = matching.count == 1 ? canAutomaticallyReplace(matching[0].memory, metadataRevision: matching[0].metadataRevision, with: proposal, source: source) : false
            let state: MemoryState = proposal.triage == .active && (matching.isEmpty || canReplace) ? .active : .candidate
            if !matching.isEmpty && !canReplace {
                reason = matching.count == 1 ? "Memory review required: this assertion may replace an existing memory." : "Memory review required: multiple memories share this assertion aspect."
            }
            let memory = Memory(draft: draft, scope: draft.scope, subject: draft.subject, state: state, origin: proposal.origin, authority: proposal.authority, createdAt: at, updatedAt: at)
            memoryID = memory.id
            disposition = state.rawValue
            try insertMemory(memory, sourceKind: .message, sourceID: source.message.id.rawValue, assertionHash: assertionHash, in: db)
            try insertMemoryEvidence(.init(memoryID: memory.id, sourceKind: .message, sourceID: source.message.id.rawValue, sourceRevision: source.sourceRevision, conversationID: source.message.conversationID, excerpt: proposal.quote, sourceHash: source.sourceHash, createdAt: at), in: db)
            try insertMemoryRevision(.init(memoryID: memory.id, revision: 1, draft: draft, actor: "memoryExtraction", changedAt: at), in: db)
            try insertAssertionMetadata(proposal.assertion, memoryID: memory.id, memoryRevision: memory.revision, source: source, at: at, in: db)
            if canReplace, let current {
                try insertMemoryReplacement(.init(replacementID: memory.id, previousID: current.id, state: .confirmed, createdAt: at), in: db)
                let oldUpdated = Memory(id: current.id, draft: current.draft, scope: current.scope, subject: current.subject, state: current.state, origin: current.origin, authority: current.authority, supersededBy: memory.id, revision: current.revision + 1, createdAt: current.createdAt, updatedAt: at, deletedAt: current.deletedAt, forgottenAt: current.forgottenAt)
                try updateMemory(oldUpdated, in: db)
                try insertMemoryRevision(.init(memoryID: current.id, revision: oldUpdated.revision, draft: current.draft, actor: "system", changedAt: at), in: db)
                try indexMemory(oldUpdated, in: db)
            } else {
                for match in matching {
                    try insertMemoryReplacement(.init(replacementID: memory.id, previousID: match.memory.id, state: .proposed, createdAt: at), in: db)
                }
            }
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

    private func currentMemories(matching assertion: MemoryAssertionMetadata, draft: MemoryDraft, in db: Database) throws -> [(memory: Memory, metadataRevision: Int?)] {
        var matching: [(memory: Memory, metadataRevision: Int?)] = []
        if let aspectKey = assertion.aspectKey {
            let rows = try Row.fetchAll(db, sql: "SELECT m.id, m.scope_key, m.scope_json, m.subject, m.state, m.origin, m.authority, m.superseded_by, m.revision, m.created_at, m.updated_at, m.deleted_at, m.forgotten_at, m.draft_json, m.source_kind, m.source_id, m.assertion_hash, m.memory_json, a.memory_revision AS assertion_memory_revision FROM memories m JOIN memory_assertion_metadata a ON a.memory_id = m.id WHERE m.scope_key = ? AND m.subject = ? AND m.state = 'active' AND m.superseded_by IS NULL AND m.forgotten_at IS NULL AND m.deleted_at IS NULL AND json_extract(m.draft_json, '$.kind') = ? AND a.semantic_key = ? AND a.body_purged_at IS NULL", arguments: [draft.scope.key, draft.subject.rawValue, draft.kind.rawValue, aspectKey])
            matching = try rows.map { (try memory($0), $0["assertion_memory_revision"] as Int?) }
        }
        let exactIDs = Set(matching.map { $0.memory.id })
        let rows = try Row.fetchAll(db, sql: "SELECT id, scope_key, scope_json, subject, state, origin, authority, superseded_by, revision, created_at, updated_at, deleted_at, forgotten_at, draft_json, source_kind, source_id, assertion_hash, memory_json FROM memories WHERE scope_key = ? AND subject = ? AND state = 'active' AND superseded_by IS NULL AND forgotten_at IS NULL AND deleted_at IS NULL AND json_extract(draft_json, '$.kind') = ? ORDER BY updated_at DESC, id LIMIT 200", arguments: [draft.scope.key, draft.subject.rawValue, draft.kind.rawValue])
        let newTopics = Set(MemoryRecallPlanner.expand(query: draft.content).matchedTopics)
        guard !newTopics.isEmpty else { return matching }
        for row in rows {
            let value = try memory(row)
            guard !exactIDs.contains(value.id), let oldDraft = value.draft else { continue }
            let oldTopics = Set(MemoryRecallPlanner.expand(query: oldDraft.content).matchedTopics)
            guard !newTopics.isDisjoint(with: oldTopics) else { continue }
            matching.append((value, nil))
        }
        return matching
    }

    private func canAutomaticallyReplace(_ current: Memory, metadataRevision: Int?, with proposal: MemoryExtractionProposal, source: MemoryExtractionSource) -> Bool {
        guard let metadataRevision, proposal.triage == .active,
              proposal.assertion.mode == .directStable,
              proposal.assertion.changeIntent == .explicitReplacement,
              metadataRevision == current.revision,
              current.authority == .observedUser,
              current.state == .active,
              current.supersededBy == nil,
              current.deletedAt == nil,
              current.forgottenAt == nil,
              let oldDraft = current.draft,
              oldDraft.scope == proposal.draft.scope,
              oldDraft.subject == proposal.draft.subject,
              oldDraft.kind == proposal.draft.kind,
              oldDraft.sensitivity == proposal.draft.sensitivity,
              oldDraft.allowsRemoteUse == proposal.draft.allowsRemoteUse,
              oldDraft.allowedConnectionIDs == proposal.draft.allowedConnectionIDs,
              compatibleMemoryValidity(oldDraft, proposal.draft),
              source.message.text == proposal.quote else { return false }
        return true
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
