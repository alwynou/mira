import Foundation
import CryptoKit
import GRDB
import MiraCore

private let extractionLeaseDuration: TimeInterval = 120
private let extractionMaxSourceBytes = 16 * 1024
private let extractionMaxRequestBytes = 32 * 1024

extension SQLiteMiraStore: MemoryExtractionStore {
    public func memoryCapturePolicy() throws -> MemoryCapturePolicy {
        try safely { try pool.read { db in try extractionPolicy(in: db) } }
    }

    public func saveMemoryCapturePolicy(_ policy: MemoryCapturePolicy, expectedRevision: Int, at: Date) throws {
        try safely {
            let normalizedPolicy = MemoryCapturePolicy(revision: policy.revision, mode: policy.mode, dailyTokenLimit: policy.dailyTokenLimit, enabledAt: policy.mode == .manualOnly ? nil : (policy.enabledAt ?? at))
            try normalizedPolicy.validate()
            try pool.write { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT revision FROM memory_capture_policy WHERE id = 1") else { throw MiraError(.storage, "The memory capture policy is missing.") }
                let current = row["revision"] as Int
                guard current == expectedRevision, current < Int.max, policy.revision == current + 1 else { throw MiraError(.conflict, "The memory capture policy revision is out of date.") }
                try db.execute(sql: "UPDATE memory_capture_policy SET revision = ?, mode = ?, daily_token_limit = ?, enabled_at = ? WHERE id = 1", arguments: [normalizedPolicy.revision, normalizedPolicy.mode.rawValue, normalizedPolicy.dailyTokenLimit, normalizedPolicy.enabledAt?.timeIntervalSince1970])
                try db.execute(sql: "UPDATE memory_extraction_jobs SET state = CASE WHEN state IN ('queued','running') THEN 'paused' ELSE state END, lease_id = NULL, lease_expires_at = NULL, updated_at = ? WHERE state IN ('queued','running')", arguments: [at.timeIntervalSince1970])
                try db.execute(sql: "UPDATE memory_extraction_attempts SET status = CASE WHEN status IN ('claimed','prepared') THEN 'failed' WHEN status = 'dispatched' THEN 'paused' ELSE status END, charged_tokens = CASE WHEN status = 'dispatched' THEN reserved_tokens ELSE charged_tokens END, reserved_tokens = 0, completed_at = CASE WHEN status IN ('claimed','prepared','dispatched') THEN COALESCE(completed_at, ?) ELSE completed_at END WHERE status IN ('claimed','prepared','dispatched')", arguments: [at.timeIntervalSince1970])
            }
        }
    }

    public func memoryExtractionJobs(conversationID: ConversationID?, limit: Int) throws -> [MemoryExtractionJob] {
        try safely {
            guard limit > 0 else { throw MiraError(.invalidInput, "Memory extraction job limit must be positive.") }
            return try pool.read { db in
                var sql = "SELECT id, source_message_id, conversation_id, policy_revision, extractor_version, state, attempt_count, created_at, updated_at, error_json FROM memory_extraction_jobs"
                var args = StatementArguments()
                if let conversationID { sql += " WHERE conversation_id = ?"; _ = args.append(contentsOf: StatementArguments([id(conversationID)])) }
                sql += " ORDER BY created_at DESC, id DESC LIMIT ?"; _ = args.append(contentsOf: StatementArguments([min(limit, 200)]))
                return try Row.fetchAll(db, sql: sql, arguments: args).map { try extractionJob($0, in: db) }
            }
        }
    }

    public func memoryExtractionBudget(at: Date) throws -> MemoryExtractionBudget {
        try safely { try pool.read { db in
            let policy = try extractionPolicy(in: db)
            let day = extractionDay(at)
            let row = try Row.fetchOne(db, sql: "SELECT COALESCE(SUM(CASE WHEN budget_day = ? THEN reserved_tokens ELSE 0 END), 0) AS reserved, COALESCE(SUM(CASE WHEN budget_day = ? THEN charged_tokens ELSE 0 END), 0) AS charged FROM memory_extraction_attempts WHERE status IN ('claimed','prepared','dispatched','completed','failed','paused')", arguments: [day, day])!
            return MemoryExtractionBudget(dayStart: extractionDayStart(at), tokenLimit: policy.dailyTokenLimit, reservedTokens: row["reserved"] as Int, chargedTokens: row["charged"] as Int)
        }}
    }

    public func claimMemoryExtraction(at: Date) throws -> MemoryExtractionClaim? {
        try safely { try pool.write { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM executions WHERE status NOT IN ('completed','failed','cancelled','interrupted') AND body_purged_at IS NULL LIMIT 1") == nil else { return nil }
            let policy = try extractionPolicy(in: db)
            guard policy.mode != .manualOnly, let enabledAt = policy.enabledAt, at >= enabledAt else { return nil }
            try recoverExpiredMemoryExtraction(in: db, at: at)
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM memory_extraction_jobs WHERE state = 'running' AND lease_expires_at > ? LIMIT 1", arguments: [at.timeIntervalSince1970]) == nil else { return nil }
            // A bad source or missing purpose route must not block other jobs.
            // Persist its reason before continuing this bounded queue scan.
            let rows = try Row.fetchAll(db, sql: "SELECT id, source_message_id, conversation_id, policy_revision, extractor_version, state, attempt_count, created_at, updated_at, error_json FROM memory_extraction_jobs WHERE state = 'queued' AND policy_revision = ? ORDER BY created_at, id LIMIT 200", arguments: [policy.revision])
            for row in rows {
            let job = try extractionJob(row, in: db)
            let source: MemoryExtractionSource
            let route: ResolvedModelRouteSnapshot
            do {
                source = try extractionSource(job, in: db)
                try validateExtractionAuthorization(job, source: source, policy: policy, at: at, in: db)
                route = try extractionRoute(conversationID: job.conversationID, in: db)
            } catch {
                let safe = MiraError.safe(error)
                if safe.code == .storage { throw safe }
                try db.execute(sql: "UPDATE memory_extraction_jobs SET state = 'paused', error_json = ?, updated_at = ? WHERE id = ?", arguments: [try Self.encode(safe), at.timeIntervalSince1970, id(job.id)])
                continue
            }
            let leaseID = UUID(), attemptID = UUID(), expires = at.addingTimeInterval(extractionLeaseDuration)
            try db.execute(sql: "UPDATE memory_extraction_jobs SET state = 'running', attempt_count = attempt_count + 1, lease_id = ?, lease_expires_at = ?, route_json = ?, updated_at = ? WHERE id = ? AND state = 'queued'", arguments: [leaseID.uuidString.lowercased(), expires.timeIntervalSince1970, try Self.encode(route), at.timeIntervalSince1970, id(job.id)])
            guard db.changesCount == 1 else { return nil }
            try db.execute(sql: "INSERT INTO memory_extraction_attempts (id, job_id, ordinal, lease_id, route_json, status, request_json, output_json, reserved_tokens, charged_tokens, usage_input, usage_output, budget_day, created_at, dispatched_at, completed_at, body_purged_at) VALUES (?, ?, ?, ?, ?, 'claimed', NULL, NULL, 0, 0, NULL, NULL, ?, ?, NULL, NULL, NULL)", arguments: [attemptID.uuidString.lowercased(), id(job.id), job.attemptCount + 1, leaseID.uuidString.lowercased(), try Self.encode(route), extractionDay(at), at.timeIntervalSince1970])
            let claimedJob = try extractionJob(try Row.fetchOne(db, sql: "SELECT id, source_message_id, conversation_id, policy_revision, extractor_version, state, attempt_count, created_at, updated_at, error_json FROM memory_extraction_jobs WHERE id = ?", arguments: [id(job.id)])!, in: db)
            return MemoryExtractionClaim(job: claimedJob, source: source, policy: policy, route: route, leaseID: leaseID, leaseExpiresAt: expires, attemptID: attemptID)
            }
            return nil
        }}
    }

    public func prepareMemoryExtraction(_ claim: MemoryExtractionClaim, request: CanonicalModelRequest, at: Date) throws -> Int {
        try safely { try pool.write { db in
            let context = try loadRevalidateMemoryExtractionClaim(claim, at: at, in: db)
            let expectedRequest = try MemoryExtractionRequestBuilder.request(for: claim)
            guard request == expectedRequest else { throw MiraError(.invalidInput, "The memory extraction request is invalid.") }
            let requestJSON = try Self.encode(request)
            let bytes = requestJSON.utf8.count
            guard bytes <= extractionMaxRequestBytes else { throw MiraError(.invalidInput, "The memory extraction request is too large.") }
            let reserved = bytes + context.route.maxOutputTokens
            guard reserved > 0, reserved <= 10_000_000 else { throw MiraError(.invalidInput, "The memory extraction reservation is invalid.") }
            if let window = context.route.contextWindow { guard reserved <= window else { throw MiraError(.invalidInput, "The memory extraction request exceeds the route context window.") } }
            let budget = try extractionBudget(policy: context.policy, day: extractionDay(at), excluding: claim.attemptID, in: db)
            guard reserved <= budget.remainingTokens else { throw MiraError(.conflict, "The memory extraction daily token budget is exhausted.") }
            try db.execute(sql: "UPDATE memory_extraction_attempts SET status = 'prepared', request_json = ?, reserved_tokens = ?, reservation_limit = ?, budget_day = ? WHERE id = ? AND job_id = ? AND lease_id = ? AND status = 'claimed' AND body_purged_at IS NULL", arguments: [requestJSON, reserved, reserved, extractionDay(at), claim.attemptID.uuidString.lowercased(), id(claim.job.id), claim.leaseID.uuidString.lowercased()])
            guard db.changesCount == 1 else { throw MiraError(.conflict, "The memory extraction claim is no longer active.") }
            return reserved
        }}
    }

    public func markMemoryExtractionDispatched(_ claim: MemoryExtractionClaim, at: Date) throws {
        try safely { try pool.write { db in
            let context = try loadRevalidateMemoryExtractionClaim(claim, at: at, in: db)
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM executions WHERE status IN ('queued','waitingForModel') AND body_purged_at IS NULL LIMIT 1") == nil else { throw MiraError(.busy, "Foreground work takes priority over automatic memory extraction.") }
            let currentDay = extractionDay(at)
            let attempt = try Row.fetchOne(db, sql: "SELECT status, reserved_tokens, budget_day FROM memory_extraction_attempts WHERE id = ? AND job_id = ? AND lease_id = ?", arguments: [claim.attemptID.uuidString.lowercased(), id(claim.job.id), claim.leaseID.uuidString.lowercased()])
            guard let attempt, (attempt["status"] as String) == "prepared" else { throw MiraError(.conflict, "The memory extraction attempt is not prepared.") }
            let reserved = attempt["reserved_tokens"] as Int
            if (attempt["budget_day"] as String) != currentDay {
                let budget = try extractionBudget(policy: context.policy, day: currentDay, excluding: claim.attemptID, in: db)
                guard reserved <= budget.remainingTokens else { throw MiraError(.conflict, "The memory extraction daily token budget is exhausted.") }
            }
            try db.execute(sql: "UPDATE memory_extraction_attempts SET status = 'dispatched', dispatched_at = ?, budget_day = ? WHERE id = ? AND status = 'prepared' AND lease_id = ?", arguments: [at.timeIntervalSince1970, currentDay, claim.attemptID.uuidString.lowercased(), claim.leaseID.uuidString.lowercased()])
            guard db.changesCount == 1 else { throw MiraError(.conflict, "The memory extraction attempt is no longer active.") }
        }}
    }

    public func failMemoryExtraction(_ claim: MemoryExtractionClaim, error: MiraError, at: Date) throws {
        try safely { try pool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT status, reserved_tokens FROM memory_extraction_attempts WHERE id = ? AND job_id = ? AND lease_id = ?", arguments: [claim.attemptID.uuidString.lowercased(), id(claim.job.id), claim.leaseID.uuidString.lowercased()]) else { return }
            let status = row["status"] as String
            guard status == "claimed" || status == "prepared" || status == "dispatched" else { return }
            let dispatched = status == "dispatched"
            let charge = dispatched ? (row["reserved_tokens"] as Int) : 0
            try db.execute(sql: "UPDATE memory_extraction_attempts SET status = ?, charged_tokens = ?, reserved_tokens = 0, completed_at = ?, output_json = NULL WHERE id = ? AND lease_id = ?", arguments: [dispatched ? "paused" : "failed", charge, at.timeIntervalSince1970, claim.attemptID.uuidString.lowercased(), claim.leaseID.uuidString.lowercased()])
            try db.execute(sql: "UPDATE memory_extraction_jobs SET state = ?, lease_id = NULL, lease_expires_at = NULL, error_json = ?, updated_at = ? WHERE id = ? AND lease_id = ?", arguments: [dispatched ? "paused" : "failed", try Self.encode(error), at.timeIntervalSince1970, id(claim.job.id), claim.leaseID.uuidString.lowercased()])
        }}
    }

    public func retryMemoryExtraction(_ id: MemoryExtractionJobID, at: Date) throws -> MemoryExtractionJobID {
        try safely { try pool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT id, source_message_id, conversation_id, policy_revision, extractor_version, state, attempt_count, created_at, updated_at, error_json FROM memory_extraction_jobs WHERE id = ?", arguments: [Self.id(id)]) else { throw MiraError(.notFound, "The memory extraction job does not exist.") }
            let job = try extractionJob(row, in: db)
            let policy = try extractionPolicy(in: db)
            guard policy.mode != .manualOnly, let enabledAt = policy.enabledAt, at >= enabledAt else { throw MiraError(.unauthorized, "Automatic memory capture is not enabled.") }
            let source = try extractionSource(job, in: db)
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM memory_source_suppressions WHERE source_kind = 'message' AND source_id = ?", arguments: [Self.id(source.message.id)]) == nil else { throw MiraError(.conflict, "The memory extraction source is suppressed.") }
            _ = try extractionRoute(conversationID: job.conversationID, in: db)
            guard [.failed, .paused, .cancelled].contains(job.state) else { throw MiraError(.conflict, "The memory extraction job cannot be retried in its current state.") }
            if job.policyRevision != policy.revision {
                if let existing = try Row.fetchOne(db, sql: "SELECT id, state FROM memory_extraction_jobs WHERE source_message_id = ? AND source_revision = ? AND extractor_version = 1 AND policy_revision = ?", arguments: [Self.id(source.message.id), source.sourceRevision, policy.revision]) {
                    let existingID = MemoryExtractionJobID(try uuid(existing["id"] as String))
                    if ["queued", "running", "completed"].contains(existing["state"] as String) { return existingID }
                    guard ["failed", "paused", "cancelled"].contains(existing["state"] as String) else { throw MiraError(.conflict, "The memory extraction source is suppressed.") }
                    try db.execute(sql: "UPDATE memory_extraction_jobs SET state = 'queued', explicit_retry_at = ?, lease_id = NULL, lease_expires_at = NULL, error_json = NULL, updated_at = ? WHERE id = ?", arguments: [at.timeIntervalSince1970, at.timeIntervalSince1970, Self.id(existingID)])
                    return existingID
                }
                return try insertExtractionJob(source: source, policy: policy, explicitRetryAt: at, at: at, in: db)
            }
            try db.execute(sql: "UPDATE memory_extraction_jobs SET state = 'queued', explicit_retry_at = ?, lease_id = NULL, lease_expires_at = NULL, error_json = NULL, updated_at = ? WHERE id = ? AND state IN ('failed','paused','cancelled')", arguments: [at.timeIntervalSince1970, at.timeIntervalSince1970, Self.id(id)])
            guard db.changesCount == 1 else { throw MiraError(.conflict, "The memory extraction job cannot be retried in its current state.") }
            return id
        }}
    }

    public func recoverMemoryExtraction(at: Date) throws {
        try safely { try pool.write { db in
            // Startup recovery must not wait for a lease to expire. A process
            // that disappeared may have left an unexpired claim behind.
            try recoverAllMemoryExtraction(in: db, at: at)
        }}
    }

    // Internal transaction helpers used by the atomic extraction commit file.
    func loadRevalidateMemoryExtractionClaim(_ claim: MemoryExtractionClaim, at: Date, in db: Database) throws -> (source: MemoryExtractionSource, policy: MemoryCapturePolicy, route: ResolvedModelRouteSnapshot) {
        let policy = try extractionPolicy(in: db)
        guard policy.revision == claim.policy.revision, policy.mode != .manualOnly, let enabledAt = policy.enabledAt, at >= enabledAt else { throw MiraError(.unauthorized, "Automatic memory capture policy is no longer current.") }
        guard let jobRow = try Row.fetchOne(db, sql: "SELECT id, source_message_id, conversation_id, policy_revision, extractor_version, state, attempt_count, created_at, updated_at, error_json, lease_id, lease_expires_at, route_json FROM memory_extraction_jobs WHERE id = ?", arguments: [id(claim.job.id)]),
              (jobRow["state"] as String) == "running", (jobRow["policy_revision"] as Int) == policy.revision,
              (jobRow["lease_id"] as String?) == claim.leaseID.uuidString.lowercased(), let expiry = jobRow["lease_expires_at"] as Double?, expiry > at.timeIntervalSince1970,
              let routeJSON = jobRow["route_json"] as String? else { throw MiraError(.conflict, "The memory extraction claim is no longer active.") }
        let job = try extractionJob(jobRow, in: db)
        guard job.id == claim.job.id, job.sourceMessageID == claim.job.sourceMessageID,
              job.conversationID == claim.job.conversationID, job.policyRevision == claim.job.policyRevision,
              job.extractorVersion == claim.job.extractorVersion, job.attemptCount == claim.job.attemptCount else { throw MiraError(.conflict, "The memory extraction claim does not match the current job.") }
        let source = try extractionSource(job, in: db)
        guard source.message.id == claim.source.message.id, source.executionID == claim.source.executionID,
              source.workspaceID == claim.source.workspaceID, source.sourceRevision == claim.source.sourceRevision,
              source.sourceHash == claim.source.sourceHash, source.message == claim.source.message,
              expiry == claim.leaseExpiresAt.timeIntervalSince1970 else { throw MiraError(.conflict, "The memory extraction source has changed.") }
        try validateExtractionAuthorization(job, source: source, policy: policy, at: at, in: db)
        guard let attempt = try Row.fetchOne(db, sql: "SELECT ordinal, status, lease_id FROM memory_extraction_attempts WHERE id = ? AND job_id = ?", arguments: [claim.attemptID.uuidString.lowercased(), id(claim.job.id)]),
              (attempt["ordinal"] as Int) == job.attemptCount, (attempt["lease_id"] as String) == claim.leaseID.uuidString.lowercased(),
              ["claimed", "prepared", "dispatched"].contains(attempt["status"] as String) else { throw MiraError(.conflict, "The memory extraction attempt is no longer active.") }
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM memory_source_suppressions WHERE source_kind = 'message' AND source_id = ?", arguments: [id(source.message.id)]) == nil else { throw MiraError(.unauthorized, "The memory extraction source is suppressed.") }
        let route = try Self.decodeRoute(routeJSON)
        guard route.purpose == .memoryExtraction, route == (try extractionRoute(conversationID: job.conversationID, in: db)), route == claim.route, policy == claim.policy else { throw MiraError(.conflict, "The memory extraction route is no longer current.") }
        return (source, policy, route)
    }

    @discardableResult
    func settleMemoryExtractionAttempt(_ claim: MemoryExtractionClaim, usage: TokenUsage, at: Date, in db: Database) throws -> Int {
        let row = try Row.fetchOne(db, sql: "SELECT status, reserved_tokens, lease_id FROM memory_extraction_attempts WHERE id = ? AND job_id = ?", arguments: [claim.attemptID.uuidString.lowercased(), id(claim.job.id)])
        guard let row, (row["lease_id"] as String) == claim.leaseID.uuidString.lowercased() else { throw MiraError(.conflict, "The memory extraction attempt is no longer owned by this worker.") }
        let status = row["status"] as String
        guard status == "dispatched" else { throw MiraError(.conflict, "The memory extraction attempt is not settleable.") }
        let reserved = row["reserved_tokens"] as Int
        let input = usage.inputTokens ?? -1
        let output = usage.outputTokens ?? -1
        let (actual, overflow) = input.addingReportingOverflow(output)
        let validActual = input >= 0 && output >= 0 && input <= 100_000_000 && output <= 100_000_000 && !overflow
        let charged = validActual ? actual : reserved
        try db.execute(sql: "UPDATE memory_extraction_attempts SET status = 'completed', usage_input = ?, usage_output = ?, charged_tokens = ?, reserved_tokens = 0, completed_at = ? WHERE id = ? AND lease_id = ? AND status = 'dispatched'", arguments: [validActual ? input : nil, validActual ? output : nil, charged, at.timeIntervalSince1970, claim.attemptID.uuidString.lowercased(), claim.leaseID.uuidString.lowercased()])
        guard db.changesCount == 1 else { throw MiraError(.conflict, "The memory extraction attempt is no longer settleable.") }
        return charged
    }

    func enqueueMemoryExtractionIfEligible(executionID: ExecutionID, at: Date, in db: Database) throws {
        let policy = try extractionPolicy(in: db)
        guard policy.mode != .manualOnly, let enabledAt = policy.enabledAt, at >= enabledAt,
              let execution = try execution(executionID, in: db), execution.status == .completed, execution.bodyPurgedAt == nil,
              let row = try Row.fetchOne(db, sql: "SELECT id, conversation_id, execution_id, sequence, role, status, text, created_at, body_purged_at FROM messages WHERE id = ?", arguments: [id(execution.triggerMessageID)]) else { return }
        let message = try Self.message(row)
        guard message.role == .user, message.status == .committed, message.bodyPurgedAt == nil,
              message.createdAt >= enabledAt, !message.text.isEmpty, message.text.utf8.count <= extractionMaxSourceBytes,
              try Int.fetchOne(db, sql: "SELECT 1 FROM memory_source_suppressions WHERE source_kind = 'message' AND source_id = ?", arguments: [id(message.id)]) == nil,
              try Int.fetchOne(db, sql: "SELECT 1 FROM memory_extraction_jobs WHERE source_message_id = ? AND source_revision = 1 AND extractor_version = 1 AND policy_revision = ?", arguments: [id(message.id), policy.revision]) == nil else { return }
        let workspaceID = try workspaceIDForConversation(message.conversationID, in: db)
        let source = MemoryExtractionSource(message: message, executionID: executionID, workspaceID: workspaceID, sourceHash: memoryPayloadHashString(message.text))
        _ = try insertExtractionJob(source: source, policy: policy, explicitRetryAt: nil, at: at, in: db)
    }

    private func insertExtractionJob(source: MemoryExtractionSource, policy: MemoryCapturePolicy, explicitRetryAt: Date?, at: Date, in db: Database) throws -> MemoryExtractionJobID {
        let jobID = MemoryExtractionJobID()
        try db.execute(sql: "INSERT INTO memory_extraction_jobs (id, source_message_id, source_execution_id, source_revision, source_hash, conversation_id, workspace_id, policy_revision, policy_json, explicit_retry_at, extractor_version, state, attempt_count, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 'queued', 0, ?, ?)", arguments: [id(jobID), id(source.message.id), id(source.executionID), source.sourceRevision, source.sourceHash, id(source.message.conversationID), source.workspaceID.map(Self.id), policy.revision, try Self.encode(policy), explicitRetryAt?.timeIntervalSince1970, at.timeIntervalSince1970, at.timeIntervalSince1970])
        return jobID
    }

    private func validateExtractionAuthorization(_ job: MemoryExtractionJob, source: MemoryExtractionSource, policy: MemoryCapturePolicy, at: Date, in db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT policy_json, explicit_retry_at, body_purged_at FROM memory_extraction_jobs WHERE id = ?", arguments: [id(job.id)]),
              (row["body_purged_at"] as Double?) == nil else { throw MiraError(.conflict, "The memory extraction source is no longer available.") }
        let frozen: MemoryCapturePolicy = try Self.decode(row["policy_json"] as String)
        guard frozen.revision == policy.revision, frozen.mode == policy.mode, frozen.dailyTokenLimit == policy.dailyTokenLimit,
              let enabledAt = frozen.enabledAt, memoryTimestampMatches(enabledAt, policy.enabledAt?.timeIntervalSince1970),
              frozen.mode != .manualOnly else { throw MiraError(.unauthorized, "Automatic memory capture policy is no longer current.") }
        let retryAt = (row["explicit_retry_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        guard source.message.createdAt >= enabledAt || memoryTimestampMatches(source.message.createdAt, enabledAt.timeIntervalSince1970) || retryAt.map({ $0 >= enabledAt && $0 <= at }) == true else { throw MiraError(.unauthorized, "The memory extraction source predates automatic capture activation.") }
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM memory_source_suppressions WHERE source_kind = 'message' AND source_id = ?", arguments: [id(source.message.id)]) == nil else { throw MiraError(.unauthorized, "The memory extraction source is suppressed.") }
    }

    func prepareRestoredMemoryExtractionState(in db: Database, at: Date) throws {
        let current = try extractionPolicy(in: db)
        let next = MemoryCapturePolicy(revision: current.revision + 1, mode: .manualOnly, dailyTokenLimit: current.dailyTokenLimit, enabledAt: nil)
        try db.execute(sql: "UPDATE memory_capture_policy SET revision = ?, mode = 'manualOnly', enabled_at = NULL WHERE id = 1", arguments: [next.revision])
        try db.execute(sql: "UPDATE memory_extraction_jobs SET state = CASE WHEN state IN ('queued','running') THEN 'paused' ELSE state END, lease_id = NULL, lease_expires_at = NULL, updated_at = ? WHERE state IN ('queued','running')", arguments: [at.timeIntervalSince1970])
        try db.execute(sql: "UPDATE memory_extraction_attempts SET status = CASE WHEN status IN ('claimed','prepared') THEN 'failed' WHEN status = 'dispatched' THEN 'paused' ELSE status END, charged_tokens = CASE WHEN status = 'dispatched' THEN reserved_tokens ELSE charged_tokens END, reserved_tokens = 0, completed_at = CASE WHEN status IN ('claimed','prepared','dispatched') THEN COALESCE(completed_at, ?) ELSE completed_at END WHERE status IN ('claimed','prepared','dispatched')", arguments: [at.timeIntervalSince1970])
    }

    /// Called by the memory forget transaction. It leaves source/job identity
    /// and accounting intact while making every extraction body unrecoverable.
    func purgeMemoryExtractionForSourceMessage(_ sourceMessageID: MessageID, at: Date, in db: Database) throws {
        let jobs = try String.fetchAll(db, sql: "SELECT id FROM memory_extraction_jobs WHERE source_message_id = ?", arguments: [Self.id(sourceMessageID)])
        for jobID in jobs {
            try purgeMemoryExtractionJob(jobID, at: at, in: db)
        }
    }

    /// Removal and rejection suppress future automatic extraction while
    /// retaining request/output bodies for audit. Open reservations are closed
    /// exactly once, with dispatched work charged at its reserved ceiling.
    func suppressMemoryExtractionForSourceMessage(_ sourceMessageID: MessageID, at: Date, in db: Database) throws {
        let jobs = try String.fetchAll(db, sql: "SELECT id FROM memory_extraction_jobs WHERE source_message_id = ? AND state IN ('queued', 'running')", arguments: [Self.id(sourceMessageID)])
        for jobID in jobs {
            try db.execute(sql: """
                UPDATE memory_extraction_attempts
                SET status = CASE WHEN status = 'dispatched' THEN 'paused' ELSE 'failed' END,
                    charged_tokens = CASE WHEN status = 'dispatched' THEN reserved_tokens ELSE 0 END,
                    reserved_tokens = 0,
                    completed_at = COALESCE(completed_at, ?)
                WHERE job_id = ? AND status IN ('claimed', 'prepared', 'dispatched')
                """, arguments: [at.timeIntervalSince1970, jobID])
            try db.execute(sql: "UPDATE memory_extraction_jobs SET state = 'suppressed', lease_id = NULL, lease_expires_at = NULL, error_json = NULL, updated_at = ? WHERE id = ? AND state IN ('queued', 'running')", arguments: [at.timeIntervalSince1970, jobID])
        }
    }

    private func recoverExpiredMemoryExtraction(in db: Database, at: Date) throws {
        let expired = try Row.fetchAll(db, sql: "SELECT a.id, a.job_id, a.status, a.reserved_tokens FROM memory_extraction_attempts a JOIN memory_extraction_jobs j ON j.id = a.job_id WHERE j.state = 'running' AND j.lease_expires_at IS NOT NULL AND j.lease_expires_at <= ?", arguments: [at.timeIntervalSince1970])
        for row in expired {
            let dispatched = (row["status"] as String) == "dispatched"
            let charge = dispatched ? (row["reserved_tokens"] as Int) : 0
            try db.execute(sql: "UPDATE memory_extraction_attempts SET status = ?, charged_tokens = ?, reserved_tokens = 0, completed_at = ? WHERE id = ? AND status IN ('claimed','prepared','dispatched')", arguments: [dispatched ? "paused" : "failed", charge, at.timeIntervalSince1970, row["id"] as String])
            try db.execute(sql: "UPDATE memory_extraction_jobs SET state = ?, lease_id = NULL, lease_expires_at = NULL, error_json = NULL, updated_at = ? WHERE id = ? AND state = 'running'", arguments: [dispatched ? "paused" : "queued", at.timeIntervalSince1970, row["job_id"] as String])
        }
    }

    private func recoverAllMemoryExtraction(in db: Database, at: Date) throws {
        // Claimed and prepared attempts never reached the provider, so their
        // reservation is released and the job may be claimed again. A
        // dispatched request is uncertain after a crash; charge its ceiling
        // and pause it so retry remains an explicit user action.
        try db.execute(sql: """
            UPDATE memory_extraction_attempts
            SET status = CASE WHEN status = 'dispatched' THEN 'paused' ELSE 'failed' END,
                charged_tokens = CASE WHEN status = 'dispatched' THEN reserved_tokens ELSE 0 END,
                reserved_tokens = 0,
                completed_at = COALESCE(completed_at, ?)
            WHERE job_id IN (SELECT id FROM memory_extraction_jobs WHERE state = 'running')
              AND status IN ('claimed', 'prepared', 'dispatched')
            """, arguments: [at.timeIntervalSince1970])
        try db.execute(sql: """
            UPDATE memory_extraction_jobs
            SET state = CASE WHEN EXISTS (
                    SELECT 1 FROM memory_extraction_attempts a
                    WHERE a.job_id = memory_extraction_jobs.id
                      AND a.ordinal = (SELECT MAX(latest.ordinal) FROM memory_extraction_attempts latest WHERE latest.job_id = memory_extraction_jobs.id)
                      AND a.status = 'paused'
                ) THEN 'paused' ELSE 'queued' END,
                lease_id = NULL,
                lease_expires_at = NULL,
                error_json = NULL,
                updated_at = ?
            WHERE state = 'running'
            """, arguments: [at.timeIntervalSince1970])
    }

    /// Decisions can outlive a memory record for audit purposes. Forgetting a
    /// memory therefore also redacts decision excerpts and hashes directly.
    func purgeMemoryExtractionForMemory(_ memoryID: MemoryID, at: Date, in db: Database) throws {
        try db.execute(sql: "UPDATE memory_extraction_decisions SET excerpt = NULL, source_hash = NULL, review_reason = NULL, body_purged_at = ? WHERE memory_id = ?", arguments: [at.timeIntervalSince1970, Self.id(memoryID)])
    }

    private func purgeMemoryExtractionJob(_ jobID: String, at: Date, in db: Database) throws {
        try db.execute(sql: "UPDATE memory_extraction_jobs SET state = 'suppressed', error_json = NULL, lease_id = NULL, lease_expires_at = NULL, source_hash = NULL, body_purged_at = ?, updated_at = ? WHERE id = ?", arguments: [at.timeIntervalSince1970, at.timeIntervalSince1970, jobID])
        try db.execute(sql: "UPDATE memory_extraction_attempts SET status = CASE WHEN status IN ('claimed','prepared') THEN 'failed' WHEN status = 'dispatched' THEN 'paused' ELSE status END, charged_tokens = CASE WHEN status = 'dispatched' THEN reserved_tokens ELSE charged_tokens END, reserved_tokens = 0, request_json = NULL, output_json = NULL, body_purged_at = ?, completed_at = CASE WHEN status IN ('claimed','prepared','dispatched') THEN COALESCE(completed_at, ?) ELSE completed_at END WHERE job_id = ? AND body_purged_at IS NULL", arguments: [at.timeIntervalSince1970, at.timeIntervalSince1970, jobID])
        try db.execute(sql: "UPDATE memory_extraction_decisions SET excerpt = NULL, source_hash = NULL, review_reason = NULL, body_purged_at = ? WHERE job_id = ? AND body_purged_at IS NULL", arguments: [at.timeIntervalSince1970, jobID])
    }
}

extension SQLiteMiraStore {
    static func createMemoryExtractionSchema(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE memory_capture_policy (
          id INTEGER PRIMARY KEY CHECK(id = 1),
          revision INTEGER NOT NULL CHECK(revision > 0),
          mode TEXT NOT NULL CHECK(mode IN ('manualOnly', 'candidateOnly', 'automaticWithUndo')),
          daily_token_limit INTEGER NOT NULL CHECK(daily_token_limit > 0),
          enabled_at REAL
        );
        INSERT INTO memory_capture_policy (id, revision, mode, daily_token_limit, enabled_at) VALUES (1, 1, 'manualOnly', 10000, NULL);
        CREATE TABLE memory_extraction_jobs (
          id TEXT PRIMARY KEY NOT NULL,
          source_message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
          source_execution_id TEXT NOT NULL REFERENCES executions(id) ON DELETE CASCADE,
          source_revision INTEGER NOT NULL CHECK(source_revision > 0),
          source_hash TEXT CHECK(source_hash IS NULL OR length(source_hash) > 0),
          conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
          workspace_id TEXT REFERENCES workspaces(id) ON DELETE RESTRICT,
          policy_revision INTEGER NOT NULL CHECK(policy_revision > 0),
          policy_json TEXT NOT NULL,
          explicit_retry_at REAL,
          extractor_version INTEGER NOT NULL CHECK(extractor_version > 0),
          state TEXT NOT NULL CHECK(state IN ('queued','running','paused','completed','failed','cancelled','suppressed')),
          attempt_count INTEGER NOT NULL CHECK(attempt_count >= 0),
          lease_id TEXT,
          lease_expires_at REAL,
          route_json TEXT,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          error_json TEXT,
          body_purged_at REAL,
          CHECK(body_purged_at IS NULL OR source_hash IS NULL),
          UNIQUE(source_message_id, source_revision, extractor_version, policy_revision)
        );
        CREATE UNIQUE INDEX memory_extraction_one_running ON memory_extraction_jobs(state) WHERE state = 'running';
        CREATE INDEX memory_extraction_jobs_conversation ON memory_extraction_jobs(conversation_id, created_at, id);
        CREATE TABLE memory_extraction_attempts (
          id TEXT PRIMARY KEY NOT NULL,
          job_id TEXT NOT NULL REFERENCES memory_extraction_jobs(id) ON DELETE CASCADE,
          ordinal INTEGER NOT NULL CHECK(ordinal > 0),
          lease_id TEXT NOT NULL,
          route_json TEXT NOT NULL,
          status TEXT NOT NULL CHECK(status IN ('claimed','prepared','dispatched','completed','failed','paused')),
          request_json TEXT,
          output_json TEXT,
          reserved_tokens INTEGER NOT NULL CHECK(reserved_tokens >= 0),
          reservation_limit INTEGER NOT NULL DEFAULT 0 CHECK(reservation_limit >= 0),
          charged_tokens INTEGER NOT NULL CHECK(charged_tokens >= 0),
          usage_input INTEGER,
          usage_output INTEGER,
          budget_day TEXT NOT NULL,
          created_at REAL NOT NULL,
          dispatched_at REAL,
          completed_at REAL,
          body_purged_at REAL,
          UNIQUE(job_id, ordinal),
          UNIQUE(id, job_id),
          CHECK((status IN ('claimed') AND request_json IS NULL) OR status NOT IN ('claimed')),
          CHECK((status = 'dispatched' AND dispatched_at IS NOT NULL) OR status != 'dispatched'),
          CHECK((status IN ('completed','failed','paused') AND completed_at IS NOT NULL) OR status IN ('claimed','prepared','dispatched')),
          CHECK(body_purged_at IS NULL OR (request_json IS NULL AND output_json IS NULL))
        );
        CREATE INDEX memory_extraction_attempts_budget ON memory_extraction_attempts(budget_day, status);
        CREATE TABLE memory_extraction_decisions (
          id TEXT PRIMARY KEY NOT NULL,
          job_id TEXT NOT NULL REFERENCES memory_extraction_jobs(id) ON DELETE CASCADE,
          source_message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE RESTRICT,
          source_revision INTEGER NOT NULL CHECK(source_revision > 0),
          candidate_key TEXT NOT NULL CHECK(length(candidate_key) > 0),
          disposition TEXT NOT NULL CHECK(disposition IN ('active','candidate','duplicate','rejected')),
          memory_id TEXT REFERENCES memories(id) ON DELETE RESTRICT,
          excerpt TEXT,
          source_hash TEXT,
          review_reason TEXT,
          policy_revision INTEGER NOT NULL CHECK(policy_revision > 0),
          changed_at REAL NOT NULL,
          body_purged_at REAL,
          UNIQUE(job_id, candidate_key),
          CHECK(body_purged_at IS NULL OR (excerpt IS NULL AND source_hash IS NULL)),
          CHECK(disposition IN ('duplicate','rejected') OR memory_id IS NOT NULL)
        );
        CREATE INDEX memory_extraction_decisions_memory ON memory_extraction_decisions(memory_id, changed_at);
        """)
    }

    func extractionPolicy(in db: Database) throws -> MemoryCapturePolicy {
        guard let row = try Row.fetchOne(db, sql: "SELECT revision, mode, daily_token_limit, enabled_at FROM memory_capture_policy WHERE id = 1"),
              let mode = MemoryCaptureMode(rawValue: row["mode"] as String) else { throw MiraError(.storage, "The memory capture policy is invalid.") }
        let value = MemoryCapturePolicy(revision: row["revision"] as Int, mode: mode, dailyTokenLimit: row["daily_token_limit"] as Int, enabledAt: (row["enabled_at"] as Double?).map(Date.init(timeIntervalSince1970:)))
        try value.validate()
        return value
    }

    func extractionJob(_ row: Row, in db: Database) throws -> MemoryExtractionJob {
        guard let state = MemoryExtractionJobState(rawValue: row["state"] as String), let id = UUID(uuidString: row["id"] as String), let messageID = UUID(uuidString: row["source_message_id"] as String), let conversationID = UUID(uuidString: row["conversation_id"] as String) else { throw MiraError(.storage, "The memory extraction job is invalid.") }
        let error: MiraError? = try (row["error_json"] as String?).map { try Self.decode($0) }
        let memoryIDs = try String.fetchAll(db, sql: "SELECT DISTINCT memory_id FROM memory_extraction_decisions WHERE job_id = ? AND memory_id IS NOT NULL ORDER BY memory_id", arguments: [row["id"] as String]).compactMap(UUID.init(uuidString:)).map(MemoryID.init)
        let candidateMemoryIDs = try String.fetchAll(db, sql: "SELECT DISTINCT d.memory_id FROM memory_extraction_decisions d JOIN memories m ON m.id = d.memory_id WHERE d.job_id = ? AND d.memory_id IS NOT NULL AND m.state = 'candidate' AND m.forgotten_at IS NULL ORDER BY d.memory_id", arguments: [row["id"] as String]).compactMap(UUID.init(uuidString:)).map(MemoryID.init)
        return MemoryExtractionJob(id: MemoryExtractionJobID(id), sourceMessageID: MessageID(messageID), conversationID: ConversationID(conversationID), policyRevision: row["policy_revision"] as Int, extractorVersion: row["extractor_version"] as Int, state: state, attemptCount: row["attempt_count"] as Int, createdAt: Date(timeIntervalSince1970: row["created_at"] as Double), updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double), error: error, memoryIDs: memoryIDs, candidateMemoryIDs: candidateMemoryIDs)
    }

    func extractionSource(_ job: MemoryExtractionJob, in db: Database) throws -> MemoryExtractionSource {
        guard let jobRow = try Row.fetchOne(db, sql: "SELECT source_execution_id, source_revision, source_hash, workspace_id, body_purged_at FROM memory_extraction_jobs WHERE id = ?", arguments: [id(job.id)]),
              (jobRow["body_purged_at"] as Double?) == nil, (jobRow["source_revision"] as Int) == 1,
              let row = try Row.fetchOne(db, sql: "SELECT id, conversation_id, execution_id, sequence, role, status, text, created_at, body_purged_at FROM messages WHERE id = ?", arguments: [id(job.sourceMessageID)]) else { throw MiraError(.conflict, "The memory extraction source is no longer available.") }
        let message = try Self.message(row)
        let sourceExecutionID = ExecutionID(try uuid(jobRow["source_execution_id"] as String))
        guard message.conversationID == job.conversationID, message.role == .user, message.status == .committed,
              message.bodyPurgedAt == nil, !message.text.isEmpty, message.text.utf8.count <= extractionMaxSourceBytes,
              let execution = try execution(sourceExecutionID, in: db), execution.status == .completed,
              execution.triggerMessageID == message.id, execution.conversationID == message.conversationID, execution.bodyPurgedAt == nil else { throw MiraError(.conflict, "The memory extraction source is no longer available.") }
        let hash = memoryPayloadHashString(message.text)
        let workspaceID = try workspaceIDForConversation(message.conversationID, in: db)
        guard hash == (jobRow["source_hash"] as String?), workspaceID.map(Self.id) == (jobRow["workspace_id"] as String?) else { throw MiraError(.storage, "The memory extraction source identity is invalid.") }
        return MemoryExtractionSource(message: message, executionID: sourceExecutionID, workspaceID: workspaceID, sourceRevision: 1, sourceHash: hash)
    }

    func extractionRoute(conversationID: ConversationID, in db: Database) throws -> ResolvedModelRouteSnapshot {
        let conversation = try conversationValue(conversationID, in: db)
        guard !conversation.isArchived else { throw MiraError(.notFound, "Conversation is no longer available.") }
        let workspace = try conversation.workspaceID.map { try workspaceValue($0, in: db) }
        let configuration = ModelConfiguration(
            connections: try Row.fetchAll(db, sql: "SELECT id, revision, name, provider_kind, base_url, credential_reference, credential_version, allows_loopback_http, connection_json FROM provider_connections ORDER BY id").map { try Self.providerConnection($0) },
            models: try Row.fetchAll(db, sql: "SELECT id, revision, connection_id, connection_revision, model_id, context_window, text_capability, tool_capability, probe_observation_json, model_json FROM model_descriptors ORDER BY id").map { try Self.modelDescriptor($0) },
            routes: try Row.fetchAll(db, sql: "SELECT id, revision, name, model_descriptor_id, max_output_tokens, requests_usage, route_json FROM model_routes ORDER BY id").map { try Self.modelRoute($0) },
            bindings: try Row.fetchAll(db, sql: "SELECT id, scope_key, purpose, route_id, revision, binding_json FROM route_bindings ORDER BY id").map { try Self.routeBinding($0) }
        )
        return try configuration.resolve(purpose: .memoryExtraction, conversation: conversation, workspace: workspace)
    }

    private func execution(_ executionID: ExecutionID, in db: Database) throws -> Execution? {
        guard let row = try Row.fetchOne(db, sql: "SELECT id, conversation_id, trigger_message_id, retry_of_execution_id, status, route_json, usage_input, usage_output, error_json, created_at, updated_at, body_purged_at FROM executions WHERE id = ?", arguments: [id(executionID)]) else { return nil }
        return try Self.execution(row)
    }

    func conversationValue(_ id: ConversationID, in db: Database) throws -> Conversation {
        guard let row = try Row.fetchOne(db, sql: "SELECT id, workspace_id, title, is_archived, created_at, updated_at, revision FROM conversations WHERE id = ?", arguments: [Self.id(id)]) else { throw MiraError(.notFound, "The conversation does not exist.") }
        return try Self.conversation(row)
    }

    func workspaceValue(_ id: WorkspaceID, in db: Database) throws -> Workspace {
        guard let row = try Row.fetchOne(db, sql: "SELECT id, name, background, allows_remote_send, allowed_connection_ids_json, revision FROM workspaces WHERE id = ?", arguments: [Self.id(id)]) else { throw MiraError(.notFound, "The workspace does not exist.") }
        return try Self.workspace(row)
    }

    func extractionBudget(policy: MemoryCapturePolicy, day: String, excluding attemptID: UUID?, in db: Database) throws -> MemoryExtractionBudget {
        var args = StatementArguments([day])
        var whereSQL = "budget_day = ?"
        if let attemptID { whereSQL += " AND id != ?"; _ = args.append(contentsOf: StatementArguments([attemptID.uuidString.lowercased()])) }
        let row = try Row.fetchOne(db, sql: "SELECT COALESCE(SUM(reserved_tokens),0) AS reserved, COALESCE(SUM(charged_tokens),0) AS charged FROM memory_extraction_attempts WHERE \(whereSQL) AND status IN ('claimed','prepared','dispatched','completed','failed','paused')", arguments: args)!
        return MemoryExtractionBudget(dayStart: extractionDayStart(Date()), tokenLimit: policy.dailyTokenLimit, reservedTokens: row["reserved"] as Int, chargedTokens: row["charged"] as Int)
    }

    static func validateMemoryExtractionContents(in db: Database) throws {
        try validateMemoryExtractionInvariants(in: db)
        guard let policy = try Row.fetchOne(db, sql: "SELECT id, revision, mode, daily_token_limit, enabled_at FROM memory_capture_policy WHERE id = 1"),
              (policy["revision"] as Int) > 0, let mode = MemoryCaptureMode(rawValue: policy["mode"] as String), (policy["daily_token_limit"] as Int) > 0 else { throw MiraError(.storage, "The memory capture policy is invalid.") }
        try MemoryCapturePolicy(revision: policy["revision"] as Int, mode: mode, dailyTokenLimit: policy["daily_token_limit"] as Int, enabledAt: (policy["enabled_at"] as Double?).map(Date.init(timeIntervalSince1970:))).validate()
        for row in try Row.fetchAll(db, sql: "SELECT id, source_message_id, source_execution_id, source_revision, source_hash, conversation_id, workspace_id, policy_revision, extractor_version, state, attempt_count, lease_id, lease_expires_at, route_json, created_at, updated_at, error_json, body_purged_at FROM memory_extraction_jobs") {
            guard UUID(uuidString: row["id"] as String) != nil, UUID(uuidString: row["source_message_id"] as String) != nil, UUID(uuidString: row["source_execution_id"] as String) != nil, UUID(uuidString: row["conversation_id"] as String) != nil,
                  (row["source_revision"] as Int) > 0, (row["policy_revision"] as Int) > 0, (row["extractor_version"] as Int) > 0,
                  MemoryExtractionJobState(rawValue: row["state"] as String) != nil, (row["attempt_count"] as Int) >= 0, (row["created_at"] as Double) > 0, (row["updated_at"] as Double) > 0 else { throw MiraError(.storage, "The memory extraction job is invalid.") }
            let sourceHash = row["source_hash"] as String?
            let bodyPurged = row["body_purged_at"] as Double?
            guard (bodyPurged == nil && sourceHash.map { !$0.isEmpty } == true) || (bodyPurged != nil && sourceHash == nil) else { throw MiraError(.storage, "The memory extraction job body marker is invalid.") }
            if let routeJSON = row["route_json"] as String? { guard try decodeRoute(routeJSON).purpose == .memoryExtraction else { throw MiraError(.storage, "The memory extraction route is invalid.") } }
            if (row["state"] as String) == "running" { guard row["lease_id"] as String? != nil, row["lease_expires_at"] as Double? != nil else { throw MiraError(.storage, "The memory extraction lease is invalid.") } }
            if bodyPurged == nil {
                guard let source = try Row.fetchOne(db, sql: "SELECT conversation_id, execution_id, role, status, text, body_purged_at FROM messages WHERE id = ?", arguments: [row["source_message_id"] as String]),
                      (source["conversation_id"] as String) == (row["conversation_id"] as String),
                      (try String.fetchOne(db, sql: "SELECT trigger_message_id FROM executions WHERE id = ?", arguments: [row["source_execution_id"] as String])) == (row["source_message_id"] as String),
                      (source["role"] as String) == MessageRole.user.rawValue,
                      (source["status"] as String) == MessageStatus.committed.rawValue,
                      (source["body_purged_at"] as Double?) == nil,
                      extractionSourceHash(source["text"] as String) == sourceHash,
                      ((row["workspace_id"] as String?) == (try String.fetchOne(db, sql: "SELECT workspace_id FROM conversations WHERE id = ?", arguments: [row["conversation_id"] as String]))) else { throw MiraError(.storage, "The memory extraction source identity is invalid.") }
            }
        }
        for row in try Row.fetchAll(db, sql: "SELECT id, job_id, ordinal, lease_id, status, request_json, output_json, reserved_tokens, charged_tokens, usage_input, usage_output, budget_day, created_at, dispatched_at, completed_at, body_purged_at FROM memory_extraction_attempts") {
            guard UUID(uuidString: row["id"] as String) != nil, UUID(uuidString: row["job_id"] as String) != nil, (row["ordinal"] as Int) > 0, !(row["lease_id"] as String).isEmpty,
                  (row["reserved_tokens"] as Int) >= 0, (row["charged_tokens"] as Int) >= 0, (row["budget_day"] as String).count == 10,
                  (row["created_at"] as Double) > 0 else { throw MiraError(.storage, "The memory extraction attempt is invalid.") }
            if let requestJSON = row["request_json"] as String? {
                let request: CanonicalModelRequest = try decode(requestJSON)
                guard let job = try Row.fetchOne(db, sql: "SELECT source_execution_id FROM memory_extraction_jobs WHERE id = ?", arguments: [row["job_id"] as String]), request.executionID == ExecutionID(try uuid(job["source_execution_id"] as String)), request.requestID == UUID(uuidString: row["id"] as String) else { throw MiraError(.storage, "The memory extraction request identity is invalid.") }
            }
            if row["body_purged_at"] as Double? != nil { guard row["request_json"] as String? == nil, row["output_json"] as String? == nil else { throw MiraError(.storage, "The purged memory extraction attempt still contains a body.") } }
        }
        for row in try Row.fetchAll(db, sql: "SELECT id, job_id, source_message_id, source_revision, candidate_key, disposition, memory_id, excerpt, source_hash, review_reason, policy_revision, changed_at, body_purged_at FROM memory_extraction_decisions") {
            guard UUID(uuidString: row["id"] as String) != nil, UUID(uuidString: row["job_id"] as String) != nil, UUID(uuidString: row["source_message_id"] as String) != nil, (row["source_revision"] as Int) > 0,
                  !(row["candidate_key"] as String).isEmpty, ["active", "candidate", "duplicate", "rejected"].contains(row["disposition"] as String), (row["policy_revision"] as Int) > 0, (row["changed_at"] as Double) > 0 else { throw MiraError(.storage, "The memory extraction decision is invalid.") }
            if row["body_purged_at"] as Double? != nil { guard row["excerpt"] as String? == nil, row["source_hash"] as String? == nil, row["review_reason"] as String? == nil else { throw MiraError(.storage, "The purged memory extraction decision still contains a body.") } }
            guard let job = try Row.fetchOne(db, sql: "SELECT source_message_id, source_revision FROM memory_extraction_jobs WHERE id = ?", arguments: [row["job_id"] as String]),
                  (job["source_message_id"] as String) == (row["source_message_id"] as String),
                  (job["source_revision"] as Int) == (row["source_revision"] as Int) else { throw MiraError(.storage, "The memory extraction decision source is invalid.") }
        }
    }

    static func extractionSourceHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private func extractionDay(_ date: Date) -> String {
    let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date)
}
private func extractionDayStart(_ date: Date) -> Date {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; return calendar.startOfDay(for: date)
}
