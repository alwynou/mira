import Foundation
import GRDB
import MiraCore

extension SQLiteMiraStore {
    /// Cross-row validation runs before restoring or opening a library. A
    /// child row cannot erase its own purge marker to evade its parent's state.
    static func validateMemoryExtractionInvariants(in db: Database) throws {
        let invalid = MiraError(.storage, "The memory extraction audit is inconsistent.")
        guard let current = try Row.fetchOne(db, sql: "SELECT * FROM memory_capture_policy WHERE id = 1") else { throw invalid }
        let currentRevision = current["revision"] as Int
        let jobs = try Row.fetchAll(db, sql: "SELECT * FROM memory_extraction_jobs")
        for job in jobs {
            let jobID = job["id"] as String
            let sourceID = job["source_message_id"] as String
            let policy: MemoryCapturePolicy = try decode(job["policy_json"] as String)
            try policy.validate()
            guard policy.mode != .manualOnly, let enabledAt = policy.enabledAt,
                  policy.revision == (job["policy_revision"] as Int), policy.revision <= currentRevision,
                  (job["source_revision"] as Int) == 1, (job["extractor_version"] as Int) == 1,
                  let sourceRow = try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE id = ?", arguments: [sourceID]),
                  let execution = try Row.fetchOne(db, sql: "SELECT * FROM executions WHERE id = ?", arguments: [job["source_execution_id"] as String]) else { throw invalid }
            let message = try Self.message(sourceRow)
            let purged = (job["body_purged_at"] as Double?) != nil
            let state = job["state"] as String
            guard message.role == .user, message.status == .committed, message.bodyPurgedAt == nil,
                  message.conversationID.rawValue == UUID(uuidString: job["conversation_id"] as String),
                  (execution["trigger_message_id"] as String) == sourceID,
                  (execution["conversation_id"] as String) == (job["conversation_id"] as String),
                  (job["workspace_id"] as String?) == (try String.fetchOne(db, sql: "SELECT workspace_id FROM conversations WHERE id = ?", arguments: [job["conversation_id"] as String])) else { throw invalid }
            let retryAt = (job["explicit_retry_at"] as Double?).map(Date.init(timeIntervalSince1970:))
            guard message.createdAt >= enabledAt || memoryTimestampMatches(message.createdAt, enabledAt.timeIntervalSince1970) || retryAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= enabledAt }) == true else { throw invalid }
            if purged {
                guard state == "suppressed", (job["source_hash"] as String?) == nil,
                      (job["error_json"] as String?) == nil else { throw invalid }
            } else {
                guard !message.text.isEmpty, message.text.utf8.count <= 16_384,
                      extractionSourceHash(message.text) == (job["source_hash"] as String?),
                      (execution["status"] as String) == "completed" else { throw invalid }
                // A source whose foreground body was purged cannot retain an
                // independent extraction copy, even if it forgot its own marker.
                guard (execution["body_purged_at"] as Double?) == nil else { throw invalid }
            }
            for key in ["created_at", "updated_at"] { guard (job[key] as Double).isFinite else { throw invalid } }
            let attempts = try Row.fetchAll(db, sql: "SELECT * FROM memory_extraction_attempts WHERE job_id = ? ORDER BY ordinal", arguments: [jobID])
            guard attempts.count == (job["attempt_count"] as Int) else { throw invalid }
            let active = attempts.filter { ["claimed", "prepared", "dispatched"].contains($0["status"] as String) }
            if state == "running" {
                guard active.count == 1, let attempt = active.first, (attempt["ordinal"] as Int) == attempts.count,
                      (attempt["lease_id"] as String) == (job["lease_id"] as String?),
                      let expiry = job["lease_expires_at"] as Double?, expiry.isFinite,
                      (job["route_json"] as String?) != nil, !purged else { throw invalid }
            } else {
                guard active.isEmpty, (job["lease_id"] as String?) == nil, (job["lease_expires_at"] as Double?) == nil else { throw invalid }
            }
            if state == "completed" { guard (attempts.last?["status"] as String?) == "completed" else { throw invalid } }
            for (index, attempt) in attempts.enumerated() {
                guard (attempt["ordinal"] as Int) == index + 1 else { throw invalid }
                try validateExtractionAttempt(attempt, job: job, source: message, policy: policy, parentPurged: purged, invalid: invalid)
            }
            let decisions = try Row.fetchAll(db, sql: "SELECT * FROM memory_extraction_decisions WHERE job_id = ?", arguments: [jobID])
            if !decisions.isEmpty { guard state == "completed" || state == "suppressed" else { throw invalid } }
            var proposalsByKey: [String: MemoryExtractionProposal] = [:]
            if state == "completed" && !purged {
                guard let outputJSON = attempts.last?["output_json"] as String? else { throw invalid }
                let output: ModelOutput = try decode(outputJSON)
                let source = MemoryExtractionSource(message: message, executionID: ExecutionID(try uuid(job["source_execution_id"] as String)), workspaceID: try (job["workspace_id"] as String?).map { WorkspaceID(try uuid($0)) }, sourceHash: extractionSourceHash(message.text))
                let proposals: [MemoryExtractionProposal]
                do { proposals = try MemoryExtractionValidator.validate(output: output.text, source: source, mode: policy.mode) }
                catch { throw invalid }
                for proposal in proposals {
                    let draft = proposal.draft
                    let assertionHash = extractionSourceHash(draft.content.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased())
                    let key = extractionSourceHash([sourceID, "1", draft.scope.key, draft.subject.rawValue, assertionHash].joined(separator: "\n"))
                    proposalsByKey[key] = proposal
                }
                guard decisions.count == proposalsByKey.count else { throw invalid }
            }
            for decision in decisions {
                guard (decision["policy_revision"] as Int) == policy.revision,
                      (decision["source_revision"] as Int) == 1,
                      (decision["source_message_id"] as String) == sourceID else { throw invalid }
                let decisionPurged = (decision["body_purged_at"] as Double?) != nil
                if purged { guard decisionPurged else { throw invalid } }
                if decisionPurged {
                    guard (decision["excerpt"] as String?) == nil, (decision["source_hash"] as String?) == nil,
                          (decision["review_reason"] as String?) == nil else { throw invalid }
                } else {
                    guard let excerpt = decision["excerpt"] as String?, !excerpt.isEmpty, excerpt.utf8.count <= 8192,
                          message.text.range(of: excerpt) != nil,
                          (decision["source_hash"] as String?) == extractionSourceHash(message.text) else { throw invalid }
                    guard proposalsByKey[decision["candidate_key"] as String] != nil else { throw invalid }
                }
                if let memoryID = decision["memory_id"] as String? {
                    guard let memory = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [memoryID]),
                          let evidence = try Row.fetchOne(db, sql: "SELECT * FROM memory_evidence WHERE memory_id = ? AND source_kind = 'message' AND source_id = ? AND source_revision = 1", arguments: [memoryID, sourceID]) else { throw invalid }
                    if (memory["forgotten_at"] as Double?) != nil || (evidence["body_purged_at"] as Double?) != nil {
                        guard decisionPurged else { throw invalid }
                    }
                    if ["active", "candidate"].contains(decision["disposition"] as String) {
                        guard ["observedUserStatement", "agentInference"].contains(memory["origin"] as String),
                              let revision = try Row.fetchOne(db, sql: "SELECT * FROM memory_revisions WHERE memory_id = ? AND revision = 1", arguments: [memoryID]),
                              (revision["actor"] as String) == "memoryExtraction" else { throw invalid }
                        if !decisionPurged {
                            let draft: MemoryDraft = try decode(revision["draft_json"] as String)
                            let reviewedRevision = try Int.fetchOne(db, sql: "SELECT 1 FROM memory_revisions WHERE memory_id = ? AND revision > 1 AND actor = 'user' LIMIT 1", arguments: [memoryID])
                            let userReviewed = (memory["authority"] as String) == "explicitUser" && reviewedRevision != nil
                            guard let proposal = proposalsByKey[decision["candidate_key"] as String],
                                  draft == proposal.draft, (memory["origin"] as String) == proposal.origin.rawValue,
                                  (memory["authority"] as String) == proposal.authority.rawValue || userReviewed,
                                  (decision["disposition"] as String) != "active" || proposal.triage == .active else { throw invalid }
                            let assertionHash = extractionSourceHash(draft.content.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased())
                            let key = extractionSourceHash([sourceID, "1", draft.scope.key, draft.subject.rawValue, assertionHash].joined(separator: "\n"))
                            guard (decision["candidate_key"] as String) == key,
                                  (evidence["source_hash"] as String?) == (decision["source_hash"] as String?),
                                  (evidence["excerpt"] as String?) == (decision["excerpt"] as String?),
                                  draft.sensitivity != .sensitive || !draft.allowsRemoteUse,
                                  (decision["disposition"] as String) != "active" || policy.mode == .automaticWithUndo else { throw invalid }
                        }
                    }
                }
            }
        }
    }

    private static func validateExtractionAttempt(_ row: Row, job: Row, source: Message, policy: MemoryCapturePolicy, parentPurged: Bool, invalid: MiraError) throws {
        guard let attemptID = UUID(uuidString: row["id"] as String), let leaseID = UUID(uuidString: row["lease_id"] as String) else { throw invalid }
        let state = row["status"] as String
        let terminal = ["completed", "failed", "paused"].contains(state)
        let purged = (row["body_purged_at"] as Double?) != nil
        let sent = (row["dispatched_at"] as Double?) != nil
        let limit = row["reservation_limit"] as Int
        let reserved = row["reserved_tokens"] as Int
        let charged = row["charged_tokens"] as Int
        guard limit >= 0, limit <= 10_000_000, reserved >= 0, charged >= 0,
              terminal == ((row["completed_at"] as Double?) != nil),
              terminal ? reserved == 0 : charged == 0 else { throw invalid }
        if parentPurged { guard purged else { throw invalid } }
        if purged { guard terminal, (row["request_json"] as String?) == nil, (row["output_json"] as String?) == nil else { throw invalid } }
        if state == "claimed" { guard limit == 0, reserved == 0, !sent, (row["request_json"] as String?) == nil else { throw invalid } }
        if state == "prepared" || state == "dispatched" {
            guard limit > 0, reserved == limit, !purged, (row["request_json"] as String?) != nil,
                  sent == (state == "dispatched") else { throw invalid }
        }
        if sent { guard limit > 0 else { throw invalid } }
        if state == "completed" || state == "paused" { guard sent else { throw invalid } }
        if terminal {
            let input = row["usage_input"] as Int?
            let output = row["usage_output"] as Int?
            guard (input == nil) == (output == nil) else { throw invalid }
            if let input, let output {
                guard sent, input >= 0, input <= 100_000_000, output >= 0, output <= 100_000_000,
                      charged == input + output else { throw invalid }
            } else { guard charged == (sent ? limit : 0) else { throw invalid } }
        }
        let dayDate = Date(timeIntervalSince1970: (row["dispatched_at"] as Double?) ?? (row["created_at"] as Double))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: dayDate)
        let day = String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
        // Preparation may cross midnight before dispatch. Unsent day is a
        // persisted reservation date, checked for actual ISO calendar validity.
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = calendar.timeZone
        formatter.calendar = calendar; formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        let storedDay = row["budget_day"] as String
        guard let parsedDay = formatter.date(from: storedDay), formatter.string(from: parsedDay) == storedDay,
              !sent || storedDay == day else { throw invalid }
        if let requestJSON = row["request_json"] as String? {
            guard !purged, let routeJSON = row["route_json"] as String? else { throw invalid }
            let route = try decodeRoute(routeJSON)
            try route.validateForSending()
            guard route.purpose == .memoryExtraction else { throw invalid }
            if !terminal {
                guard let activeRoute = job["route_json"] as String?, try decodeRoute(activeRoute) == route else { throw invalid }
            }
            let sourceValue = MemoryExtractionSource(message: source, executionID: ExecutionID(try uuid(job["source_execution_id"] as String)), workspaceID: try (job["workspace_id"] as String?).map { WorkspaceID(try uuid($0)) }, sourceHash: extractionSourceHash(source.text))
            let jobValue = MemoryExtractionJob(id: MemoryExtractionJobID(try uuid(job["id"] as String)), sourceMessageID: source.id, conversationID: source.conversationID, policyRevision: policy.revision, state: .running, createdAt: .distantPast, updatedAt: .distantPast)
            let claim = MemoryExtractionClaim(job: jobValue, source: sourceValue, policy: policy, route: route, leaseID: leaseID, leaseExpiresAt: .distantFuture, attemptID: attemptID)
            let request: CanonicalModelRequest = try decode(requestJSON)
            guard request == (try MemoryExtractionRequestBuilder.request(for: claim)),
                  requestJSON.utf8.count <= 32_768, requestJSON.utf8.count + route.maxOutputTokens == limit else { throw invalid }
        }
        if let outputJSON = row["output_json"] as String? {
            let output: ModelOutput = try decode(outputJSON)
            guard !purged, sent, terminal, output.toolCalls.isEmpty, output.text.utf8.count <= 32_768 else { throw invalid }
            if state == "completed" { guard output.finishReason == .stop else { throw invalid } }
        } else if state == "completed" && !purged { throw invalid }
    }
}
