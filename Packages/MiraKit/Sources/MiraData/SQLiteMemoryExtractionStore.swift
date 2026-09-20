import Foundation
import GRDB
import MiraCore

/// Durable business jobs. Session provenance is verified by the journal-facing module;
/// this adapter checks current business authority in the transaction that changes state.
public final class SQLiteMemoryExtractionStore: MemoryExtractionStore, MemoryExtractionInspectionStore, MemoryExtractionStatusReader,
    @unchecked Sendable
{
    let owner: SQLiteDomainDatabase
    public init(database: DatabaseQueue, libraryID: UUID) throws {
        owner = try SQLiteDomainDatabase(database: database, libraryID: libraryID, label: "mira.memory-extraction")
        try database.write { db in
            guard try db.tableExists("memory_sources") else { throw Self.invalid }
            try SQLiteMemoryExtractionSchema.initialize(in: db)
        }
    }
    public func close() async { await owner.close() }

    public func memoryExtractionJobs(sessionID: ConversationID?, state: MemoryExtractionJobState?, limit: Int)
        async throws -> [MemoryExtractionJob]
    {
        guard (1...128).contains(limit) else { throw Self.limit }
        return try await owner.read { db in
            var clauses: [String] = []
            var arguments = StatementArguments()
            if let sessionID {
                clauses.append("session_id = ?")
                arguments += [Self.key(sessionID)]
            }
            if let state {
                clauses.append("state = ?")
                arguments += [state.rawValue]
            }
            let filter = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
            arguments += [limit]
            return try Row.fetchAll(
                db, sql: "SELECT * FROM memory_extraction_jobs" + filter + " ORDER BY created_at, id LIMIT ?",
                arguments: arguments
            ).map(Self.job)
        }
    }
    static func queuedJobSQL(afterSession: Bool) -> String {
        "SELECT * FROM memory_extraction_jobs INDEXED BY memory_extraction_jobs_fair_queue WHERE state = 'queued'"
            + (afterSession ? " AND session_id > ?" : "")
            + " ORDER BY session_id, created_at, id LIMIT 1"
    }

    public func nextQueuedMemoryExtraction(after sessionID: ConversationID?) async throws -> MemoryExtractionJob? {
        try await owner.read { db in
            if let sessionID,
                let row = try Row.fetchOne(
                    db,
                    sql:
                        Self.queuedJobSQL(afterSession: true),
                    arguments: [Self.key(sessionID)])
            {
                return try Self.job(row)
            }
            return try Row.fetchOne(
                db,
                sql:
                    Self.queuedJobSQL(afterSession: false)
            )
            .map(Self.job)
        }
    }

    public func memoryExtractionDecisionReport(
        _ id: MemoryExtractionJobID, ordinal: Int, workspaceID: WorkspaceID?
    ) async throws -> MemoryExtractionDecisionReport? {
        guard (1...100).contains(ordinal) else { throw Self.invalid }
        return try await owner.read { db in
            let job = try Self.job(id, in: db)
            guard job.workspaceID == workspaceID else { throw Self.missing }
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM memory_extraction_attempts WHERE job_id = ? AND ordinal = ?",
                    arguments: [Self.key(id), ordinal])
            else { throw Self.missing }
            let attempt = try Self.attempt(row)
            guard attempt.status == .completed else { return nil }
            return .init(
                jobID: id, attemptID: attempt.identity.attemptID, ordinal: ordinal,
                decisions: attempt.decisions, bodyPurgedAt: attempt.bodyPurgedAt)
        }
    }


    public func flushDirtyMemoryExtraction(at: Date, authorization: AgentLibraryAuthorization) async throws {
        try Self.date(at)
        try await owner.write(authorization: authorization) { db in
            let sessions = try String.fetchAll(db, sql: "SELECT DISTINCT session_id FROM memory_extraction_dirty ORDER BY session_id LIMIT 128")
            for session in sessions {
                let rows = try Row.fetchAll(db, sql: "SELECT json, workspace_id FROM memory_extraction_dirty WHERE session_id = ? ORDER BY admission_sequence LIMIT ?", arguments: [session, MemoryExtractionBatching.maximumTurns])
                let turns = try rows.map { try Self.decode(MemoryExtractionTurn.self, $0["json"]) }
                guard let trigger = MemoryExtractionBatching.trigger(turns: turns, now: at) else { continue }
                let bounded = MemoryExtractionBatching.bounded(turns)
                guard let first = bounded.first else { continue }
                let origin = MemoryExtractionOrigin(source: first.source, completedExecutionID: first.completedExecutionID, completionEventID: first.completionEventID, completionHead: first.completionHead)
                let workspace: WorkspaceID? = (rows.first?["workspace_id"] as String?)
                    .flatMap { UUID(uuidString: $0) }.map { WorkspaceID($0) }
                let job = MemoryExtractionJob(id: .init(), origin: origin, workspaceID: workspace,
                    createdAt: at, updatedAt: at, turns: bounded)
                try Self.write(job, insert: true, in: db)
                _ = trigger
                for turn in bounded { try db.execute(sql: "DELETE FROM memory_extraction_dirty WHERE source_key = ?", arguments: [try Self.sourceKey(turn.source)]) }
            }
        }
    }

    public func claimMemoryExtraction(
        _ id: MemoryExtractionJobID, expectedAttemptCount: Int,
        source: SessionUserEvidence, selection: AgentModelRouteResolution,
        authorization: AgentLibraryAuthorization, at: Date
    ) async throws -> MemoryExtractionClaim? {
        try Self.date(at)
        return try await owner.write(authorization: authorization) { db in
            var job = try Self.job(id, in: db)
            guard job.state == .queued, job.attemptCount == expectedAttemptCount else { return nil }
            guard job.attemptCount < 100 else { throw Self.limit }
            try Self.validateSource(source, job: job, in: db)
            try Self.validateSelection(selection, job: job, in: db)
            guard
                try Int.fetchOne(
                    db,
                    sql:
                        "SELECT count(*) FROM memory_extraction_attempts WHERE status IN ('claimed','prepared','dispatched')"
                ) == 0
            else { return nil }
            job.state = .running
            job.attemptCount += 1
            job.updatedAt = max(at, job.updatedAt)
            job.error = nil
            var claim = MemoryExtractionClaim(
                job: job, source: source, selection: selection,
                leaseID: UUID(), leaseExpiresAt: at.addingTimeInterval(300), attemptID: UUID())
            let request = AgentContextRequest(sessionID: source.reference.sessionID, executionID: claim.executionID,
                workspaceID: source.workspaceID, userText: source.text,
                authorizationEpoch: source.sessionAuthorizationEpoch, destination: .model(claim.route))
            // Correction/replacement decisions need memories related to the
            // committed user text, not an arbitrary UUID-ordered prefix of the
            // library. Prefer relevance search and use a small recent fallback
            // only when the statement has no searchable terms.
            let relevant = try SQLiteMemoryStore.search(query: source.text, workspaceID: source.workspaceID,
                states: [.active], request: request, limit: 32, at: at, in: db).memories
            let candidates = relevant.isEmpty
                ? try SQLiteMemoryStore.recentActiveMemories(workspaceID: source.workspaceID,
                    request: request, limit: 32, at: at, in: db)
                : relevant
            var contextBytes = 0
            claim.existingMemories = candidates.filter { memory in
                contextBytes += memory.draft?.content.utf8.count ?? 0
                return contextBytes <= 8_192
            }
            try claim.validate()
            for memory in claim.existingMemories {
                try db.execute(sql: "INSERT OR REPLACE INTO memory_extraction_dependencies(job_id, memory_id, revision) VALUES (?, ?, ?)", arguments: [Self.key(job.id), Self.key(memory.id), memory.revision])
            }
            let attempt = Attempt(identity: try ClaimIdentity(claim))
            try Self.write(job, in: db)
            try Self.write(attempt, insert: true, in: db)
            return claim
        }
    }

    public func prepareMemoryExtraction(
        _ claim: MemoryExtractionClaim, request: AgentPreparedModelRequest,
        source: SessionUserEvidence, authorization: AgentLibraryAuthorization, at: Date
    ) async throws -> Int {
        try await owner.write(authorization: authorization) { db in
            let (_, prior) = try Self.current(claim, source: source, at: at, in: db)
            var attempt = prior
            try request.validate(for: claim.route)
            guard request.input == (try MemoryExtractionRequestBuilder.input(for: claim)) else { throw Self.conflict }
            if attempt.status == .prepared {
                guard attempt.request == request else { throw Self.conflict }
                return attempt.reservedTokens
            }
            guard attempt.status == .claimed else { throw Self.conflict }
            // Byte count is a conservative estimate independent of adapter-specific token heuristics.
            let requestBytes = try Self.encode(request.wirePayload, maximum: 4_194_304).count
            let input = max(requestBytes, request.estimatedInputTokens)
            let outputLimit = request.input.outputTokenLimit ?? claim.route.maximumOutputTokens
            let (ceiling, overflow) = input.addingReportingOverflow(outputLimit)
            guard !overflow, ceiling > 0, ceiling <= claim.route.contextWindow
            else { throw Self.limit }
            attempt.request = request
            attempt.reservedTokens = ceiling
            attempt.status = .prepared
            try Self.write(attempt, in: db)
            return ceiling
        }
    }

    public func markMemoryExtractionDispatched(
        _ claim: MemoryExtractionClaim, source: SessionUserEvidence,
        authorization: AgentLibraryAuthorization, at: Date
    ) async throws {
        try await owner.write(authorization: authorization) { db in
            let (_, prior) = try Self.current(claim, source: source, at: at, in: db)
            var attempt = prior
            guard attempt.status == .prepared, attempt.request != nil else { throw Self.conflict }
            attempt.dispatchedAt = at
            attempt.status = .dispatched
            try Self.write(attempt, in: db)
        }
    }

    public func completeMemoryExtraction(
        _ claim: MemoryExtractionClaim, source: SessionUserEvidence,
        output: AgentModelOutput, authorization: AgentLibraryAuthorization, at: Date
    ) async throws -> MemoryExtractionJob {
        try await owner.write(authorization: authorization) { db in
            let existing = try Self.attempt(claim.attemptID, in: db)
            guard existing.identity == (try ClaimIdentity(claim)) else { throw Self.conflict }
            if existing.status == .completed {
                guard existing.bodyPurgedAt == nil, existing.output == output else { throw Self.conflict }
                return try Self.job(claim.job.id, in: db)
            }
            var (job, attempt) = try Self.current(claim, source: source, at: at, in: db)
            guard attempt.status == .dispatched else { throw Self.conflict }
            try Self.validate(output, route: claim.route)
            let batchSources = claim.batchSources
            let proposals = try MemoryExtractionValidator.validate(output: output.text, sources: batchSources)
            let result = try SQLiteMemoryStore.commitExtractionBatchProposals(
                proposals, claim: claim, sources: batchSources, at: at, in: db)
            let charge: Int
            if let input = output.usage.totalInputTokens, let count = output.usage.outputTokens {
                let (sum, overflow) = input.addingReportingOverflow(count)
                charge = overflow ? attempt.reservedTokens : sum
            } else {
                charge = attempt.reservedTokens
            }
            attempt.reportedUsage = output.usage
            attempt.output = output
            attempt.decisions = result.decisions
            attempt.status = .completed
            attempt.chargedTokens = charge
            attempt.settledAt = at
            job.state = .completed
            job.error = nil
            job.updatedAt = at
            job.memoryIDs = result.memoryIDs
            job.candidateMemoryIDs = result.candidateMemoryIDs
            try Self.write(attempt, in: db)
            try Self.write(job, in: db)
            return job
        }
    }

    public func failMemoryExtraction(
        _ claim: MemoryExtractionClaim, error: MiraError,
        authorization: AgentLibraryAuthorization, at: Date
    ) async throws {
        try await owner.write(authorization: authorization) { db in
            var attempt = try Self.attempt(claim.attemptID, in: db)
            guard attempt.identity == (try ClaimIdentity(claim)) else { throw Self.conflict }
            guard attempt.status.isLive else { return }
            var job = try Self.job(claim.job.id, in: db)
            guard job.state == .running, job.attemptCount == claim.job.attemptCount else { throw Self.invalid }
            try Self.settleFailure(&attempt, job: &job, error: error, at: at)
            try Self.write(attempt, in: db)
            try Self.write(job, in: db)
        }
    }

    public func pauseMemoryExtraction(
        _ id: MemoryExtractionJobID, expectedAttemptCount: Int, error: MiraError,
        authorization: AgentLibraryAuthorization, at: Date
    ) async throws {
        try Self.date(at)
        try await owner.write(authorization: authorization) { db in
            var job = try Self.job(id, in: db)
            guard job.state == .queued, job.attemptCount == expectedAttemptCount else { return }
            job.state = .paused
            job.error = error
            job.updatedAt = max(at, job.updatedAt)
            try Self.write(job, in: db)
        }
    }

    public func retryMemoryExtraction(
        _ id: MemoryExtractionJobID, source: SessionUserEvidence,
        authorization: AgentLibraryAuthorization, at: Date
    ) async throws -> MemoryExtractionJobID {
        try Self.date(at)
        return try await owner.write(authorization: authorization) { db in
            var job = try Self.job(id, in: db)
            guard [.paused, .failed].contains(job.state), job.attemptCount < 100 else { throw Self.conflict }
            try Self.validateSource(source, job: job, in: db)
            job.state = .queued
            job.error = nil
            job.updatedAt = max(at, job.updatedAt)
            try Self.write(job, in: db)
            return job.id
        }
    }

    public func recoverMemoryExtraction(authorization: AgentLibraryAuthorization, at: Date) async throws {
        try Self.date(at)
        try await owner.write(authorization: authorization) { db in
            let rows = try Row.fetchAll(
                db,
                sql:
                    "SELECT * FROM memory_extraction_attempts WHERE status IN ('claimed','prepared','dispatched') LIMIT 2"
            )
            guard rows.count <= 1 else { throw Self.invalid }
            for row in rows {
                var attempt = try Self.attempt(row)
                var job = try Self.job(attempt.identity.job.id, in: db)
                guard job.state == .running, job.attemptCount == attempt.identity.job.attemptCount else {
                    throw Self.invalid
                }
                let sent = attempt.dispatchedAt != nil
                try Self.settleFailure(
                    &attempt, job: &job,
                    error: .init(.interrupted, "Memory extraction was interrupted before settlement."), at: at)
                if !sent {
                    job.state = .queued
                    job.error = nil
                }
                try Self.write(attempt, in: db)
                try Self.write(job, in: db)
            }
            guard try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_extraction_jobs WHERE state = 'running'") == 0
            else { throw Self.invalid }
        }
    }

    /// Called only by an authenticated journal delivery inside the checkpoint transaction.
    static func enqueue(origin: MemoryExtractionOrigin, source: SessionUserEvidence, at: Date, in db: Database) throws
        -> MemoryExtractionJob?
    {
        try origin.validate()
        try date(at)
        try MemoryExtractionRequestBuilder.validate(source: source)
        guard origin.source == source.reference else { throw conflict }
        guard try !SQLiteMemoryStore.suppressedMemorySource(.userMessage(source.reference), in: db)
        else { return nil }
        let sourceKey = try sourceKey(source.reference)
        if let row = try Row.fetchOne(
            db,
            sql:
                "SELECT * FROM memory_extraction_jobs WHERE source_key = ? AND extractor_revision = ?",
            arguments: [sourceKey, MemoryExtractionRequestBuilder.revision])
        {
            let existing = try job(row)
            guard existing.origin.source == source.reference, existing.workspaceID == source.workspaceID else {
                throw invalid
            }
            return existing
        }
        let job = MemoryExtractionJob(
            id: .init(), origin: origin, workspaceID: source.workspaceID,
            createdAt: at, updatedAt: at)
        try validateSource(source, job: job, in: db)
        try write(job, insert: true, in: db)
        return job
    }

    /// Records completed turns durably and emits one bounded job only when the
    /// deterministic coalescing policy says the session is ready. The journal
    /// consumer calls this inside its checkpoint transaction, so a crash cannot
    /// lose a dirty turn or advance it twice.
    static func enqueueBatch(turns: [(origin: MemoryExtractionOrigin, source: SessionUserEvidence, completedAt: Date)], at: Date, in db: Database) throws -> MemoryExtractionJob? {
        guard !turns.isEmpty else { return nil }
        try date(at)
        for item in turns {
            try item.origin.validate(); try MemoryExtractionRequestBuilder.validate(source: item.source)
            guard item.origin.source == item.source.reference,
                  item.source.admittedAt.timeIntervalSince1970.isFinite,
                  !item.source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  try !SQLiteMemoryStore.suppressedMemorySource(.userMessage(item.source.reference), in: db) else { continue }
            let durableSourceKey = try sourceKey(item.source.reference)
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM memory_extraction_sources WHERE source_key=?)", arguments: [durableSourceKey]) != true else { continue }
            let tokenEstimate = max(1, (item.source.text.utf8.count + 3) / 4)
            let turn = MemoryExtractionTurn(source: item.source.reference,
                completedExecutionID: item.origin.completedExecutionID,
                completionEventID: item.origin.completionEventID,
                completionHead: item.origin.completionHead,
                admittedAt: item.source.admittedAt, completedAt: item.completedAt,
                inputTokenEstimate: tokenEstimate)
            try turn.validate()
            let bytes = try encode(turn)
            try db.execute(sql: "INSERT OR IGNORE INTO memory_extraction_dirty(source_key, session_id, workspace_id, json, created_at, admission_sequence) VALUES (?, ?, ?, ?, ?, ?)", arguments: [try sourceKey(item.source.reference), key(item.source.reference.sessionID), item.source.workspaceID.map(key), bytes, item.completedAt.timeIntervalSince1970, item.source.reference.admissionSequence])
        }
        guard let session = turns.first?.source.reference.sessionID else { return nil }
        let rows = try Row.fetchAll(db, sql: "SELECT json FROM memory_extraction_dirty WHERE session_id = ? ORDER BY admission_sequence LIMIT ?", arguments: [key(session), MemoryExtractionBatching.maximumTurns])
        let pending = try rows.map { try decode(MemoryExtractionTurn.self, $0["json"]) }
        guard let trigger = MemoryExtractionBatching.trigger(turns: pending, now: at) else { return nil }
        let bounded = MemoryExtractionBatching.bounded(pending)
        guard let first = bounded.first,
              let originRow = try Row.fetchOne(db, sql: "SELECT json FROM memory_extraction_dirty WHERE source_key = ?", arguments: [try sourceKey(first.source)]) else { return nil }
        _ = trigger // persisted by the job's deterministic turn set; no model triage is performed.
        let originTurn = try decode(MemoryExtractionTurn.self, originRow["json"])
        let origin = MemoryExtractionOrigin(source: originTurn.source, completedExecutionID: originTurn.completedExecutionID, completionEventID: originTurn.completionEventID, completionHead: originTurn.completionHead)
        let job = MemoryExtractionJob(id: .init(), origin: origin, workspaceID: turns.first?.source.workspaceID,
            createdAt: at, updatedAt: at, turns: bounded)
        try write(job, insert: true, in: db)
        for turn in bounded { try db.execute(sql: "DELETE FROM memory_extraction_dirty WHERE source_key = ?", arguments: [try sourceKey(turn.source)]) }
        return job
    }


    /// The full library maintenance owner separately invalidates journal dependencies.
    static func purge(source: MemoryEvidenceSource, at: Date, in db: Database) throws {
        guard case .userMessage(let reference) = source else { return }
        try db.execute(sql: "DELETE FROM memory_extraction_dirty WHERE source_key=?", arguments: [try sourceKey(reference)])
        let jobs = try Row.fetchAll(
            db, sql: "SELECT j.* FROM memory_extraction_jobs j JOIN memory_extraction_sources s ON s.job_id=j.id WHERE s.source_key=?", arguments: [try sourceKey(reference)]
        ).map(job)
        try purgeJobs(jobs, at: at, in: db)
    }

    static func purgeMemoryDependencies(_ memoryID: MemoryID, at: Date, in db: Database) throws {
        let jobs = try Row.fetchAll(db, sql: "SELECT j.* FROM memory_extraction_jobs j JOIN memory_extraction_dependencies d ON d.job_id=j.id WHERE d.memory_id=?", arguments: [key(memoryID)]).map(job)
        try purgeJobs(jobs, at: at, in: db)
    }

    private static func purgeJobs(_ jobs: [MemoryExtractionJob], at: Date, in db: Database) throws {
        for var job in jobs {
            for row in try Row.fetchAll(
                db, sql: "SELECT * FROM memory_extraction_attempts WHERE job_id = ? ORDER BY ordinal",
                arguments: [key(job.id)])
            {
                var attempt = try self.attempt(row)
                if attempt.status.isLive { try settleFailure(&attempt, job: &job, error: unauthorized, at: at) }
                attempt.request = nil
                attempt.output = nil
                attempt.decisions = nil
                attempt.error = nil
                attempt.bodyPurgedAt = max(at, attempt.settledAt ?? attempt.identity.job.updatedAt)
                try write(attempt, in: db)
            }
            job.state = .suppressed
            job.error = nil
            job.updatedAt = max(at, job.updatedAt)
            try write(job, in: db)
        }
    }

    static let invalid = MiraError(.storage, "The memory extraction record is inconsistent.")
    static let conflict = MiraError(.conflict, "The memory extraction attempt is out of date.")
    static let unauthorized = MiraError(.unauthorized, "The memory extraction source or policy is no longer available.")
    static let missing = MiraError(.notFound, "The memory extraction record is unavailable.")
    static let limit = MiraError(.outputLimit, "Memory extraction exceeds the current request context limit.")
}
