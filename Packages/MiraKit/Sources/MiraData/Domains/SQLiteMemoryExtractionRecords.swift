import CryptoKit
import Foundation
import GRDB
import MiraCore

extension SQLiteMemoryExtractionStore {
    struct ClaimIdentity: Codable, Equatable, Sendable {
        let job: MemoryExtractionJob
        let route: AgentModelRoute
        let leaseID: UUID
        let leaseExpiresAt: Date
        let attemptID: UUID
        let admittedAt: Date
        let timeZoneIdentifier: String
        let sourceEpoch: UInt64
        let existingMemories: [MemoryUsage]

        init(_ claim: MemoryExtractionClaim) throws {
            try claim.validate()
            job = claim.job
            route = claim.route
            leaseID = claim.leaseID
            leaseExpiresAt = claim.leaseExpiresAt
            attemptID = claim.attemptID
            admittedAt = claim.source.admittedAt
            timeZoneIdentifier = claim.source.timeZoneIdentifier
            sourceEpoch = claim.source.sessionAuthorizationEpoch
            existingMemories = claim.existingMemories.map { .init(memoryID: $0.id, revision: $0.revision) }
        }
        func validate() throws {
            try job.validate()
            try route.validate()
            guard job.state == .running, job.attemptCount > 0,
                leaseExpiresAt.timeIntervalSince1970.isFinite, leaseExpiresAt > job.updatedAt,
                admittedAt.timeIntervalSince1970.isFinite, TimeZone(identifier: timeZoneIdentifier) != nil
            else { throw Self.invalid }
        }
        private static var invalid: MiraError { SQLiteMemoryExtractionStore.invalid }
    }

    typealias AttemptStatus = MemoryExtractionAttemptState
    struct Attempt: Codable, Equatable, Sendable {
        let identity: ClaimIdentity
        var status: AttemptStatus = .claimed
        var request: AgentPreparedModelRequest?
        var reservedTokens = 0
        var chargedTokens = 0
        var dispatchedAt: Date?
        var settledAt: Date?
        var reportedUsage: TokenUsage?
        var output: AgentModelOutput?
        var decisions: [MemoryExtractionDecision]?
        var error: MiraError?
        var bodyPurgedAt: Date?

        var accounting: MemoryExtractionAttemptUsage {
            .init(id: identity.attemptID, jobID: identity.job.id, ordinal: identity.job.attemptCount,
                  state: status, startedAt: identity.job.updatedAt, dispatchedAt: dispatchedAt,
                  settledAt: settledAt, reservedTokens: reservedTokens,
                  chargedTokens: chargedTokens, usage: reportedUsage,
                  route: bodyPurgedAt == nil ? identity.route : nil, bodyPurgedAt: bodyPurgedAt)
        }

        func validate() throws {
            try identity.validate()
            try accounting.validate()
            guard (0...10_000_000).contains(reservedTokens), chargedTokens >= 0,
                chargedTokens <= TokenUsage.maximumAggregateTokens,
                (status.isLive && settledAt == nil) || (!status.isLive && settledAt != nil),
                [dispatchedAt, settledAt, bodyPurgedAt].allSatisfy({
                    $0.map { $0.timeIntervalSince1970.isFinite } ?? true
                }),
                bodyPurgedAt == nil
                    || (!status.isLive && request == nil && output == nil && decisions == nil && error == nil)
            else { throw Self.invalid }
            if status == .failed || status == .paused {
                guard bodyPurgedAt != nil || error != nil else { throw Self.invalid }
            }
            if status == .completed { guard error == nil else { throw Self.invalid } }
            if status == .claimed {
                guard request == nil, reservedTokens == 0, dispatchedAt == nil else {
                    throw Self.invalid
                }
            }
            if status == .prepared { guard dispatchedAt == nil else { throw Self.invalid } }
            if status == .dispatched || status == .completed || status == .paused {
                guard dispatchedAt != nil else { throw Self.invalid }
            }
            if status == .failed { guard dispatchedAt == nil, chargedTokens == 0 else { throw Self.invalid } }
            if status.isLive { guard chargedTokens == 0, output == nil, error == nil else { throw Self.invalid } }
            if reservedTokens > 0 {
                guard bodyPurgedAt != nil || request != nil else { throw Self.invalid }
            } else {
                guard request == nil else { throw Self.invalid }
            }
            if let request {
                try request.validate(for: identity.route)
                guard request.input.executionID == ExecutionID(identity.attemptID),
                    request.input.stepID == identity.attemptID,
                    !request.input.allowsToolCalls
                else { throw Self.invalid }
            }
            if status == .completed {
                guard bodyPurgedAt != nil || (output != nil && decisions != nil) else { throw Self.invalid }
                if let decisions {
                    guard decisions.count <= 6, decisions.map(\.proposalIndex) == decisions.map(\.proposalIndex).sorted(),
                          Set(decisions.map(\.proposalIndex)).count == decisions.count else {
                        throw Self.invalid
                    }
                    for decision in decisions { try decision.validate() }
                }
                if let output {
                    guard output.usage == reportedUsage else { throw Self.invalid }
                    try SQLiteMemoryExtractionStore.validate(output, route: identity.route)
                    let value = try SessionCodec.decode(JSONValue.self, from: Data(output.text.utf8))
                    guard case .object(let object) = value, case .array(let items) = object["items"],
                        case .array(let retractions) = object["retractions"],
                        items.count + retractions.count <= 6,
                        decisions?.allSatisfy({ (0..<(items.count + retractions.count)).contains($0.proposalIndex) }) == true
                    else { throw Self.invalid }
                }
            } else {
                guard output == nil, decisions == nil else { throw Self.invalid }
            }
        }
        private static var invalid: MiraError { SQLiteMemoryExtractionStore.invalid }
    }

    static func key<Tag>(_ id: EntityID<Tag>) -> String { key(id.rawValue) }
    static func key(_ id: UUID) -> String { id.uuidString.lowercased() }
    static func date(_ at: Date) throws { guard at.timeIntervalSince1970.isFinite else { throw invalid } }
    static func encode<T: Encodable>(_ value: T, maximum: Int = 131_072) throws -> Data {
        let bytes = try SessionCodec.encode(value)
        guard bytes.count <= maximum else { throw limit }
        return bytes
    }
    static func decode<T: Decodable>(_ type: T.Type, _ bytes: Data, maximum: Int = 131_072) throws -> T {
        guard !bytes.isEmpty, bytes.count <= maximum else { throw invalid }
        do { return try SessionCodec.decode(type, from: bytes) } catch { throw invalid }
    }
    static func sourceKey(_ reference: SessionEvidenceReference) throws -> String {
        try SQLiteMemoryStore.sourceKey(.userMessage(reference))
    }
    static func job(_ row: Row) throws -> MemoryExtractionJob {
        let job = try decode(MemoryExtractionJob.self, row["json"])
        try job.validate()
        guard key(job.id) == row["id"] as String, try sourceKey(job.origin.source) == row["source_key"] as String,
            key(job.origin.source.sessionID) == row["session_id"] as String,
            key(job.origin.completedExecutionID) == row["execution_id"] as String,
            job.workspaceID.map(key) == row["workspace_id"] as String?,
            job.extractorRevision == row["extractor_revision"] as Int,
            job.state.rawValue == row["state"] as String, job.attemptCount == row["attempt_count"] as Int,
            job.createdAt.timeIntervalSince1970 == row["created_at"] as Double
        else { throw invalid }
        return job
    }
    static func job(_ id: MemoryExtractionJobID, in db: Database) throws -> MemoryExtractionJob {
        guard
            let row = try Row.fetchOne(
                db, sql: "SELECT * FROM memory_extraction_jobs WHERE id = ?", arguments: [key(id)])
        else { throw missing }
        return try job(row)
    }
    static func write(_ job: MemoryExtractionJob, insert: Bool = false, in db: Database) throws {
        try job.validate()
        if insert {
            try db.execute(
                sql:
                    "INSERT INTO memory_extraction_jobs(id, source_key, session_id, execution_id, workspace_id, extractor_revision, state, attempt_count, created_at, json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    key(job.id), try sourceKey(job.origin.source), key(job.origin.source.sessionID), key(job.origin.completedExecutionID),
                    job.workspaceID.map(key), job.extractorRevision, job.state.rawValue,
                    job.attemptCount, job.createdAt.timeIntervalSince1970, try encode(job),
                ])
            let references = job.turns.isEmpty ? [job.origin.source] : job.turns.map(\.source)
            for reference in references {
                let executionID = job.turns.first(where: { $0.source == reference })?.completedExecutionID ?? job.origin.completedExecutionID
                try db.execute(sql: "INSERT INTO memory_extraction_sources(job_id, source_key, execution_id) VALUES (?, ?, ?)", arguments: [key(job.id), try sourceKey(reference), key(executionID)])
            }
        } else {
            try db.execute(
                sql: "UPDATE memory_extraction_jobs SET state = ?, attempt_count = ?, json = ? WHERE id = ?",
                arguments: [job.state.rawValue, job.attemptCount, try encode(job), key(job.id)])
            guard db.changesCount == 1 else { throw conflict }
        }
    }
    static func attempt(_ row: Row) throws -> Attempt {
        let attempt = try decode(Attempt.self, row["json"], maximum: 16_777_216)
        try attempt.validate()
        guard attempt.accounting == (try accounting(row)) else { throw invalid }
        return attempt
    }
    static func attempt(_ id: UUID, in db: Database) throws -> Attempt {
        guard
            let row = try Row.fetchOne(
                db, sql: "SELECT * FROM memory_extraction_attempts WHERE id = ?", arguments: [key(id)])
        else { throw missing }
        return try attempt(row)
    }
    static func write(_ attempt: Attempt, insert: Bool = false, in db: Database) throws {
        try attempt.validate()
        let bytes = try encode(attempt, maximum: 16_777_216)
        let accounting = try encode(attempt.accounting)
        let digest = SHA256.hash(data: accounting).map { String(format: "%02x", $0) }.joined()
        if insert {
            try db.execute(
                sql:
                "INSERT INTO memory_extraction_attempts(id, job_id, ordinal, status, reserved_tokens, charged_tokens, accounting_digest, accounting, json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    key(attempt.identity.attemptID), key(attempt.identity.job.id), attempt.identity.job.attemptCount,
                    attempt.status.rawValue, attempt.reservedTokens,
                    attempt.chargedTokens, digest, accounting, bytes,
                ])
        } else {
            try db.execute(
                sql:
                "UPDATE memory_extraction_attempts SET status = ?, reserved_tokens = ?, charged_tokens = ?, accounting_digest = ?, accounting = ?, json = ? WHERE id = ?",
                arguments: [
                    attempt.status.rawValue, attempt.reservedTokens,
                    attempt.chargedTokens, digest, accounting, bytes, key(attempt.identity.attemptID),
                ])
            guard db.changesCount == 1 else { throw conflict }
        }
    }
    static func validateSource(_ source: SessionUserEvidence, job: MemoryExtractionJob, in db: Database) throws {
        try MemoryExtractionRequestBuilder.validate(source: source)
        guard source.reference == job.origin.source, source.workspaceID == job.workspaceID,
            source.observedHead.cursor.sequence >= job.origin.completionHead.cursor.sequence,
            try !SQLiteMemoryStore.memoryCaptureSuppressed(.userMessage(source.reference), in: db)
        else { throw unauthorized }
        if let workspaceID = source.workspaceID { _ = try SQLiteWorkspaceStore.read(workspaceID, in: db) }
    }
    static func validateSelection(_ selection: AgentModelRouteResolution, job: MemoryExtractionJob, in db: Database)
        throws
    {
        guard selection.binding == nil else { throw unauthorized }
        try selection.route.validate()
        try SQLiteAgentModelSettings.validateFrozenIdentity(selection.route, in: db)
        try SQLiteWorkspaceStore.validatePolicy(job.workspaceID, connectionID: selection.route.connectionID, in: db)
    }
    static func current(_ claim: MemoryExtractionClaim, source: SessionUserEvidence, at: Date, in db: Database) throws
        -> (MemoryExtractionJob, Attempt)
    {
        try claim.validate()
        try date(at)
        let job = try job(claim.job.id, in: db)
        let attempt = try attempt(claim.attemptID, in: db)
        guard attempt.identity == (try ClaimIdentity(claim)), job.state == .running,
            job.attemptCount == claim.job.attemptCount, attempt.status.isLive,
            at >= claim.job.updatedAt, at < claim.leaseExpiresAt,
            at >= (attempt.dispatchedAt ?? claim.job.updatedAt),
            source.admittedAt == claim.source.admittedAt, source.timeZoneIdentifier == claim.source.timeZoneIdentifier,
            source.sessionAuthorizationEpoch == claim.source.sessionAuthorizationEpoch,
            source.text == claim.source.text
        else { throw conflict }
        try validateSource(source, job: job, in: db)
        let references = job.turns.isEmpty ? [job.origin.source] : job.turns.map(\.source)
        guard claim.batchSources.map(\.reference) == references else { throw unauthorized }
        for evidence in claim.batchSources {
            try MemoryExtractionRequestBuilder.validate(source: evidence)
            guard evidence.workspaceID == job.workspaceID,
                  evidence.sessionAuthorizationEpoch == source.sessionAuthorizationEpoch,
                  evidence.admittedAt.timeIntervalSince1970.isFinite,
                  try !SQLiteMemoryStore.memoryCaptureSuppressed(.userMessage(evidence.reference), in: db)
            else { throw unauthorized }
        }
        let request = AgentContextRequest(sessionID: source.reference.sessionID, executionID: claim.executionID,
            workspaceID: source.workspaceID, userText: source.text,
            authorizationEpoch: source.sessionAuthorizationEpoch, destination: .model(claim.route))
        guard claim.existingMemories.count <= 32 else { throw invalid }
        for memory in claim.existingMemories {
            let current = try SQLiteMemoryStore.recall(memory.id, request: request, at: at, in: db)
            guard current == memory else { throw conflict }
        }
        try validateSelection(claim.selection, job: job, in: db)
        return (job, attempt)
    }
    static func validate(_ output: AgentModelOutput, route: AgentModelRoute) throws {
        guard output.toolCalls.isEmpty, output.finishReason == .stop else { throw invalid }
        var accumulator = try AgentModelAccumulator(route: route, maximumTextBytes: 32_768)
        for block in output.blocks {
            try accumulator.consume(.blockStarted(block))
            try accumulator.consume(.blockFinished(id: block.id))
        }
        if let continuation = output.continuation {
            try accumulator.consume(.continuation(continuation))
        }
        try accumulator.consume(.usage(output.usage))
        try accumulator.consume(.finished(output.finishReason))
        guard try accumulator.finish() == output else { throw invalid }
    }
    static func settleFailure(_ attempt: inout Attempt, job: inout MemoryExtractionJob, error: MiraError, at: Date)
        throws
    {
        try date(at)
        attempt.status = attempt.dispatchedAt == nil ? .failed : .paused
        attempt.chargedTokens = attempt.dispatchedAt == nil ? 0 : attempt.reservedTokens
        let settledAt = max(at, attempt.dispatchedAt ?? attempt.identity.job.updatedAt)
        attempt.settledAt = settledAt
        attempt.error = error
        job.state = attempt.dispatchedAt == nil ? .failed : .paused
        job.error = error
        job.updatedAt = max(job.updatedAt, settledAt)
    }
}
