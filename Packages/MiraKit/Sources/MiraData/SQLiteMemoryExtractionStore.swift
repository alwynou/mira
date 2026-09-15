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
            guard try db.tableExists("memory_policy"), try db.tableExists("memory_sources") else { throw Self.invalid }
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

    public func memoryExtractionBudget(at: Date) async throws -> MemoryExtractionBudget {
        try await owner.read { try Self.budget(at: at, in: $0) }
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
            let policy = try SQLiteMemoryStore.currentCapturePolicy(in: db)
            guard policy.revision == job.policyRevision, policy.mode != .manualOnly,
                let enabledAt = policy.enabledAt, source.admittedAt >= enabledAt
            else { throw Self.unauthorized }
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
            let claim = MemoryExtractionClaim(
                job: job, source: source, policy: policy, selection: selection,
                leaseID: UUID(), leaseExpiresAt: at.addingTimeInterval(300), attemptID: UUID())
            try claim.validate()
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
            let requestBytes = try Self.encode(request).count
            let input = max(requestBytes, request.estimatedInputTokens)
            let (ceiling, overflow) = input.addingReportingOverflow(claim.route.maximumOutputTokens)
            guard !overflow, ceiling > 0, ceiling <= claim.route.contextWindow,
                ceiling <= (try Self.budget(at: at, in: db)).remainingTokens
            else { throw Self.limit }
            attempt.request = request
            attempt.reservedTokens = ceiling
            attempt.budgetDay = try Self.day(at)
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
            let today = try Self.day(at)
            if attempt.budgetDay != today {
                guard attempt.reservedTokens <= (try Self.budget(at: at, in: db)).remainingTokens else {
                    throw Self.limit
                }
                attempt.budgetDay = today
            }
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
            let proposals = try MemoryExtractionValidator.validate(
                output: output.text, source: source, mode: claim.policy.mode)
            let result = try SQLiteMemoryStore.commitExtractionProposals(
                proposals, claim: claim, source: source, at: at, in: db)
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
            let policy = try SQLiteMemoryStore.currentCapturePolicy(in: db)
            guard policy.mode != .manualOnly, let enabledAt = policy.enabledAt, source.admittedAt >= enabledAt else {
                throw Self.unauthorized
            }
            if policy.revision != job.policyRevision {
                guard let next = try Self.enqueue(origin: job.origin, source: source, at: at, in: db) else {
                    throw Self.unauthorized
                }
                return next.id
            }
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
            let policy = try SQLiteMemoryStore.currentCapturePolicy(in: db)
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
                if !sent && job.policyRevision == policy.revision && policy.mode != .manualOnly {
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
        let policy = try SQLiteMemoryStore.currentCapturePolicy(in: db)
        guard policy.mode != .manualOnly, let enabledAt = policy.enabledAt, source.admittedAt >= enabledAt,
            try !SQLiteMemoryStore.suppressedMemorySource(.userMessage(source.reference), in: db)
        else { return nil }
        let sourceKey = try sourceKey(source.reference)
        if let row = try Row.fetchOne(
            db,
            sql:
                "SELECT * FROM memory_extraction_jobs WHERE source_key = ? AND policy_revision = ? AND extractor_revision = ?",
            arguments: [sourceKey, policy.revision, MemoryExtractionRequestBuilder.revision])
        {
            let existing = try job(row)
            guard existing.origin.source == source.reference, existing.workspaceID == source.workspaceID else {
                throw invalid
            }
            return existing
        }
        let job = MemoryExtractionJob(
            id: .init(), origin: origin, workspaceID: source.workspaceID,
            policyRevision: policy.revision, createdAt: at, updatedAt: at)
        try validateSource(source, job: job, in: db)
        try write(job, insert: true, in: db)
        return job
    }

    static func invalidatePolicy(at: Date, in db: Database) throws {
        let policy = try SQLiteMemoryStore.currentCapturePolicy(in: db)
        // One live attempt, independent of queue size. The SQL queue update stores each bounded canonical job.
        for row in try Row.fetchAll(
            db,
            sql: "SELECT * FROM memory_extraction_attempts WHERE status IN ('claimed','prepared','dispatched') LIMIT 2")
        {
            var attempt = try Self.attempt(row)
            var job = try Self.job(attempt.identity.job.id, in: db)
            guard job.state == .running else { throw invalid }
            try settleFailure(&attempt, job: &job, error: unauthorized, at: at)
            job.state = .paused
            try write(attempt, in: db)
            try write(job, in: db)
        }
        let cursor = try Row.fetchCursor(
            db, sql: "SELECT * FROM memory_extraction_jobs WHERE state = 'queued' AND policy_revision != ?",
            arguments: [policy.revision])
        var ids: [MemoryExtractionJobID] = []
        while let row = try cursor.next() { ids.append(try job(row).id) }
        for id in ids {
            var job = try job(id, in: db)
            job.state = .paused
            job.error = unauthorized
            job.updatedAt = max(at, job.updatedAt)
            try write(job, in: db)
        }
    }

    /// The full library maintenance owner separately invalidates journal dependencies.
    static func purge(source: MemoryEvidenceSource, at: Date, in db: Database) throws {
        guard case .userMessage(let reference) = source else { return }
        let jobs = try Row.fetchAll(
            db, sql: "SELECT * FROM memory_extraction_jobs WHERE source_key = ?", arguments: [try sourceKey(reference)]
        ).map(job)
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
    static let limit = MiraError(.outputLimit, "Memory extraction exceeds the current request or daily token budget.")
}
