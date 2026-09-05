import CryptoKit
import Foundation
import GRDB
import MiraCore

private func memoryTimestampMatches(_ date: Date, _ stored: Double?) -> Bool {
    guard let stored else { return false }
    let seconds = date.timeIntervalSince1970
    guard seconds.isFinite, stored.isFinite else { return false }
    // JSON preserves fractional milliseconds. Allow only representational
    // rounding from the Date epoch conversion and milliseconds serialization.
    let tolerance = max(seconds.ulp, stored.ulp, date.timeIntervalSinceReferenceDate.ulp, (stored * 1_000).ulp / 1_000) * 4
    return abs(seconds - stored) <= tolerance
}
private func optionalMemoryTimestampMatches(_ date: Date?, _ stored: Double?) -> Bool {
    switch (date, stored) {
    case (nil, nil): return true
    case let (date?, stored?): return memoryTimestampMatches(date, stored)
    default: return false
    }
}

private struct MemoryOperationPayload: Encodable {
    let draft: MemoryDraft
    let source: MemorySourceInput
    let replacing: MemoryID?
    let expectedRevision: Int?
}

private struct StoredMemoryReceipt: Codable {
    let memoryID: MemoryID
    let disposition: MemoryWriteDisposition
}
private struct StoredMemorySuppression: Codable {
    let sourceKind: MemoryEvidenceKind
    let sourceID: UUID
    let reason: String
}
enum MemoryUsageKind: String {
    case recall, capture
}
private struct CanonicalMemoryOperationPayload: Encodable {
    let content: String
    let scope: MemoryScope
    let subject: MemorySubject
    let kind: MemoryKind
    let sensitivity: MemorySensitivity
    let allowsRemoteUse: Bool
    let allowedConnectionIDs: [String]?
    let validFrom: Date?
    let validUntil: Date?
    let source: MemorySourceInput
    let replacing: MemoryID?
    let expectedRevision: Int?
}

/// Normalized memory persistence layered on the store's one SQLite pool.
/// Every public operation below performs its validation and writes in one transaction.
extension SQLiteMiraStore: MemoryStore {
    public func memoryList(workspaceID: WorkspaceID?, states: Set<MemoryState>, query: String, limit: Int) throws -> MemorySearchResult {
        try safely {
            let limit = try memoryLimit(limit)
            return try pool.read { db in
                try validateSelectedWorkspace(workspaceID, in: db)
                return try memorySearch(in: db, workspaceID: workspaceID, states: states, query: query, limit: limit, enforcePolicy: false, connectionID: nil, at: nil)
            }
        }
    }

    public func memoryDetail(_ memoryID: MemoryID, workspaceID: WorkspaceID?) throws -> MemoryDetail {
        try safely { try pool.read { db in
            try validateSelectedWorkspace(workspaceID, in: db)
            guard let row = try Row.fetchOne(db, sql: "SELECT id, scope_key, scope_json, subject, state, origin, authority, superseded_by, revision, created_at, updated_at, deleted_at, forgotten_at, draft_json, source_kind, source_id, assertion_hash, memory_json FROM memories WHERE id = ?", arguments: [memoryIDString(memoryID)]) else {
                throw MiraError(.notFound, "The memory does not exist.")
            }
            let memory = try memory(row)
            guard memoryScopeVisible(memory.scope, in: workspaceID) else { throw MiraError(.notFound, "The memory does not exist.") }
            let evidence = try Row.fetchAll(db, sql: "SELECT id, memory_id, source_kind, source_id, source_revision, conversation_id, excerpt, source_hash, speaker_role, created_at, body_purged_at, evidence_json FROM memory_evidence WHERE memory_id = ? ORDER BY created_at, id LIMIT 200", arguments: [memoryIDString(memoryID)]).map { try memoryEvidence($0) }
            let revisions = try Row.fetchAll(db, sql: "SELECT memory_id, revision, draft_json, actor, changed_at, body_purged_at, revision_json FROM memory_revisions WHERE memory_id = ? ORDER BY revision DESC LIMIT 200", arguments: [memoryIDString(memoryID)]).map { row -> MemoryRevision in
                let revision = try memoryRevision(row)
                if let draft = revision.draft {
                    guard draft.scope == memory.scope, draft.subject == memory.subject else { throw MiraError(.storage, "The memory revision scope or subject is inconsistent.") }
                }
                return revision
            }
            let replacements = try Row.fetchAll(db, sql: "SELECT id, replacement_id, previous_id, state, created_at, replacement_json FROM memory_replacements WHERE replacement_id = ? OR previous_id = ? ORDER BY created_at, id LIMIT 200", arguments: [memoryIDString(memoryID), memoryIDString(memoryID)]).map { try memoryReplacement($0) }
            return MemoryDetail(memory: memory, evidence: evidence, revisions: revisions, replacements: replacements)
        }}
    }

    public func createMemory(draft: MemoryDraft, source: MemorySourceInput, operationID: UUID, replacing: MemoryID?, expectedRevision: Int?, at: Date) throws -> MemoryWriteReceipt {
        try safely {
            try draft.validate()
            return try pool.write { db in
                try createMemory(in: db, draft: draft, source: source, operationID: operationID, replacing: replacing, expectedRevision: expectedRevision, at: at)
            }
        }
    }

    func createMemory(in db: Database, draft: MemoryDraft, source: MemorySourceInput, operationID: UUID, replacing: MemoryID?, expectedRevision: Int?, at: Date) throws -> MemoryWriteReceipt {
        try draft.validate()
        try validateMemoryScope(draft.scope, in: db)
        let payloadHash = try memoryPayloadHash(MemoryOperationPayload(draft: draft, source: source, replacing: replacing, expectedRevision: expectedRevision))
        if let receiptRow = try Row.fetchOne(db, sql: "SELECT payload_hash, memory_id, disposition FROM memory_operation_receipts WHERE operation_id = ?", arguments: [uuidString(operationID)]) {
            guard receiptRow["payload_hash"] as String == payloadHash else { throw MiraError(.conflict, "The memory operation ID was already used with different content.") }
            let existingID = try memoryID(receiptRow["memory_id"] as String)
            guard let existingRow = try Row.fetchOne(db, sql: "SELECT id, scope_key, scope_json, subject, state, origin, authority, superseded_by, revision, created_at, updated_at, deleted_at, forgotten_at, draft_json, source_kind, source_id, assertion_hash, memory_json FROM memories WHERE id = ?", arguments: [memoryIDString(existingID)]) else { throw MiraError(.storage, "The memory operation receipt points to missing data.") }
            let existing = try memory(existingRow)
            guard existing.forgottenAt == nil else { throw MiraError(.conflict, "A forgotten memory cannot be recreated by reusing an operation.") }
            return MemoryWriteReceipt(memory: existing, disposition: MemoryWriteDisposition(rawValue: receiptRow["disposition"] as String) ?? .existing)
        }

        let sourceInfo = try resolveMemorySource(source, draft: draft, in: db)
        if sourceInfo.kind.rawValue == MemoryEvidenceKind.manualEntry.rawValue {
            for row in try Row.fetchAll(db, sql: "SELECT me.id, me.memory_id, me.source_kind, me.source_id, me.source_revision, me.conversation_id, me.excerpt, me.source_hash, me.speaker_role, me.created_at, me.body_purged_at, me.evidence_json FROM memory_evidence me WHERE me.source_kind = 'manualEntry' AND me.source_id = ?", arguments: [uuidString(sourceInfo.sourceID)]) {
                let prior = try memoryEvidence(row)
                guard prior.sourceRevision == 1, prior.bodyPurgedAt == nil, prior.excerpt == sourceInfo.excerpt, prior.sourceHash == sourceInfo.sourceHash else { throw MiraError(.conflict, "The manual memory source ID is already bound to different or purged content.") }
            }
        }
        let assertionHash = memoryHash(draft.content)
        let sourceID = uuidString(sourceInfo.sourceID)
        if let identity = try Row.fetchOne(db, sql: "SELECT id FROM memories WHERE forgotten_at IS NULL AND source_kind = ? AND source_id = ? AND subject = ? AND scope_key = ? AND assertion_hash = ?", arguments: [sourceInfo.kind.rawValue, sourceID, draft.subject.rawValue, draft.scope.key, assertionHash]) {
            let existingID = try memoryID(identity["id"] as String)
            guard let existingRow = try Row.fetchOne(db, sql: "SELECT id, scope_key, scope_json, subject, state, origin, authority, superseded_by, revision, created_at, updated_at, deleted_at, forgotten_at, draft_json, source_kind, source_id, assertion_hash, memory_json FROM memories WHERE id = ?", arguments: [memoryIDString(existingID)]) else { throw MiraError(.storage, "The memory identity points to missing data.") }
            let existing = try memory(existingRow)
            let disposition: MemoryWriteDisposition = .existing
            try insertMemoryReceipt(operationID: operationID, payloadHash: payloadHash, memory: existing, disposition: disposition, at: at, in: db)
            return MemoryWriteReceipt(memory: existing, disposition: disposition)
        }

        var state: MemoryState = .active
        var disposition: MemoryWriteDisposition = .created
        var previous: Memory?
        if let replacing {
            guard let oldRow = try Row.fetchOne(db, sql: "SELECT id, scope_key, scope_json, subject, state, origin, authority, superseded_by, revision, created_at, updated_at, deleted_at, forgotten_at, draft_json, source_kind, source_id, assertion_hash, memory_json FROM memories WHERE id = ?", arguments: [memoryIDString(replacing)]) else { throw MiraError(.notFound, "The memory to replace does not exist.") }
            let old = try memory(oldRow)
            previous = old
            guard old.forgottenAt == nil, old.deletedAt == nil else { throw MiraError(.conflict, "The memory to replace is no longer available.") }
            guard old.scope == draft.scope, old.subject == draft.subject else { throw MiraError(.invalidInput, "A replacement must keep the same memory scope and subject.") }
            guard expectedRevision == old.revision else { throw MiraError(.conflict, "The memory revision is out of date.") }
            guard compatibleMemoryValidity(old.draft, draft) else { throw MiraError(.invalidInput, "The replacement memory has incompatible validity dates.") }
            if old.supersededBy != nil {
                state = .candidate
                disposition = .replacementProposed
            }
        } else if expectedRevision != nil {
            throw MiraError(.conflict, "A new memory cannot include an expected revision.")
        }

        let memoryID = MemoryID()
        let memory = Memory(id: memoryID, draft: draft, scope: draft.scope, subject: draft.subject, state: state, origin: .explicitUser, authority: .explicitUser, revision: 1, createdAt: at, updatedAt: at)
        try insertMemory(memory, sourceKind: sourceInfo.kind, sourceID: sourceInfo.sourceID, assertionHash: assertionHash, in: db)
        let evidence = MemoryEvidence(memoryID: memoryID, sourceKind: sourceInfo.kind, sourceID: sourceInfo.sourceID, sourceRevision: sourceInfo.sourceRevision, conversationID: sourceInfo.conversationID, excerpt: sourceInfo.excerpt, sourceHash: sourceInfo.sourceHash, speakerRole: .user, createdAt: at)
        try insertMemoryEvidence(evidence, in: db)
        let revision = MemoryRevision(memoryID: memoryID, revision: 1, draft: draft, changedAt: at)
        try insertMemoryRevision(revision, in: db)

        if let old = previous {
            let relationState: MemoryReplacementState = disposition.rawValue == MemoryWriteDisposition.replacementProposed.rawValue ? .proposed : .confirmed
            let relation = MemoryReplacement(replacementID: memoryID, previousID: old.id, state: relationState, createdAt: at)
            try insertMemoryReplacement(relation, in: db)
            if relationState.rawValue == MemoryReplacementState.confirmed.rawValue {
                let nextRevision = old.revision + 1
                let oldUpdated = Memory(id: old.id, draft: old.draft, scope: old.scope, subject: old.subject, state: old.state, origin: old.origin, authority: old.authority, supersededBy: memoryID, revision: nextRevision, createdAt: old.createdAt, updatedAt: at, deletedAt: old.deletedAt, forgottenAt: old.forgottenAt)
                try updateMemory(oldUpdated, in: db)
                try insertMemoryRevision(MemoryRevision(memoryID: old.id, revision: nextRevision, draft: old.draft, actor: "system", changedAt: at), in: db)
                try indexMemory(oldUpdated, in: db)
            }
        }
        try insertMemoryReceipt(operationID: operationID, payloadHash: payloadHash, memory: memory, disposition: disposition, at: at, in: db)
        if sourceInfo.kind == .message {
            let sourceID = uuidString(sourceInfo.sourceID)
            var executionIDs = try String.fetchAll(db, sql: "SELECT execution_id FROM messages WHERE id = ? AND execution_id IS NOT NULL", arguments: [sourceID]).compactMap { try? executionID($0) }
            executionIDs.append(contentsOf: try String.fetchAll(db, sql: "SELECT id FROM executions WHERE trigger_message_id = ?", arguments: [sourceID]).compactMap { try? executionID($0) })
            for executionID in Set(executionIDs) {
                try persistMemoryUsages([MemoryUsage(memoryID: memory.id, revision: memory.revision)], executionID: executionID, at: at, kind: .capture, in: db)
            }
        }
        try indexMemory(memory, in: db)
        return MemoryWriteReceipt(memory: memory, disposition: disposition)
    }

    public func rememberMemory(draft: MemoryDraft, quote: String, invocationID: UUID, at: Date) throws -> MemoryWriteReceipt {
        try safely {
            try draft.validate()
            return try pool.write { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT ti.id, ti.attempt_id, ti.model_order, ti.provider_call_id, ti.tool_name,
                           ti.arguments_json, ti.status, ti.result_json, ti.body_purged_at,
                           ti.dispatched_at, ti.completed_at, ma.execution_id,
                           ma.status AS attempt_status, ma.body_purged_at AS attempt_body_purged_at,
                           e.conversation_id, e.status AS execution_status, e.route_json,
                           e.body_purged_at AS execution_body_purged_at, c.is_archived
                    FROM tool_invocations ti
                    JOIN model_attempts ma ON ma.id = ti.attempt_id AND ma.execution_id = ti.execution_id
                    JOIN executions e ON e.id = ti.execution_id
                    JOIN conversations c ON c.id = e.conversation_id
                    WHERE ti.id = ?
                    """, arguments: [uuidString(invocationID)]) else { throw MiraError(.notFound, "The memory tool invocation does not exist.") }
                guard (row["tool_name"] as String) == "memory.remember",
                      (row["status"] as String) == "dispatched",
                      (row["result_json"] as String?) == nil,
                      (row["completed_at"] as Double?) == nil,
                      (row["body_purged_at"] as Double?) == nil,
                      (row["attempt_body_purged_at"] as Double?) == nil,
                      (row["execution_body_purged_at"] as Double?) == nil,
                      (row["attempt_status"] as String) == AttemptStatus.completed.rawValue,
                      (row["execution_status"] as String) == ExecutionStatus.waitingForModel.rawValue,
                      (row["is_archived"] as Int) == 0 else { throw MiraError(.unauthorized, "The memory tool invocation is no longer authorized.") }
                guard let argumentsJSON = row["arguments_json"] as String? else { throw MiraError(.storage, "The memory tool invocation arguments are missing.") }
                let arguments: JSONValue = try Self.decode(argumentsJSON)
                guard let content = arguments["content"]?.stringValue,
                      let quoteValue = arguments["quote"]?.stringValue,
                      quoteValue == quote,
                      content == draft.content,
                      let kindValue = arguments["kind"]?.stringValue,
                      MemoryKind(rawValue: kindValue)?.rawValue == draft.kind.rawValue else { throw MiraError(.unauthorized, "The memory proposal does not match the reviewed content.") }
                guard case .bool(let sensitive) = arguments["sensitive"] else { throw MiraError(.unauthorized, "The memory proposal does not contain a valid sensitivity value.") }
                guard draft.subject.rawValue == MemorySubject.user.rawValue,
                      draft.sensitivity.rawValue == (sensitive ? MemorySensitivity.sensitive.rawValue : MemorySensitivity.standard.rawValue),
                      !draft.allowsRemoteUse,
                      draft.allowedConnectionIDs == nil,
                      draft.validFrom == nil,
                      draft.validUntil == nil else { throw MiraError(.unauthorized, "The memory disclosure policy does not match the reviewed content.") }
                let executionID = try executionID(row["execution_id"] as String)
                let conversationID = try conversationID(row["conversation_id"] as String)
                let workspaceID = try workspaceIDForConversation(conversationID, in: db)
                guard let scopeValue = arguments["scope"]?.stringValue else { throw MiraError(.unauthorized, "The memory proposal does not contain a valid scope value.") }
                let expectedScope: MemoryScope
                switch scopeValue {
                case "current": expectedScope = workspaceID.map(MemoryScope.workspace) ?? .global
                case "global": expectedScope = .global
                default: throw MiraError(.invalidInput, "The memory scope is invalid.")
                }
                guard draft.scope == expectedScope else { throw MiraError(.unauthorized, "The memory scope does not match the reviewed content.") }
                let route = try Self.decodeRoute(row["route_json"] as String)
                let currentRoute = try currentRoute(for: route, in: db)
                guard currentRoute == route else { throw MiraError(.conflict, "The provider route changed before the memory could be saved.") }
                try validateWorkspacePolicy(workspaceID, connectionID: route.connectionID, in: db)
                guard let trigger = try Row.fetchOne(db, sql: "SELECT id, role, status, text, body_purged_at FROM messages WHERE id = (SELECT trigger_message_id FROM executions WHERE id = ?)", arguments: [executionIDString(executionID)]),
                      (trigger["role"] as String) == MessageRole.user.rawValue,
                      (trigger["status"] as String) == MessageStatus.committed.rawValue,
                      (trigger["body_purged_at"] as Double?) == nil,
                      (trigger["text"] as String).contains(quote) else { throw MiraError(.unauthorized, "The current user message no longer authorizes this memory.") }
                let receipt = try createMemory(in: db, draft: draft, source: .message(id: MessageID(try uuid(trigger["id"] as String)), excerpt: quote), operationID: invocationID, replacing: nil, expectedRevision: nil, at: at)
                try persistMemoryUsages([MemoryUsage(memoryID: receipt.memory.id, revision: receipt.memory.revision)], executionID: executionID, at: at, kind: .capture, in: db)
                return receipt
            }
        }
    }

    public func reviseMemory(_ memoryID: MemoryID, workspaceID: WorkspaceID?, draft: MemoryDraft, expectedRevision: Int, at: Date) throws -> Memory {
        try safely {
            try draft.validate()
            return try pool.write { db in
                try validateMemoryScope(draft.scope, in: db)
                let current = try requireMemory(memoryID, workspaceID: workspaceID, in: db)
                guard current.forgottenAt == nil, current.state.rawValue != MemoryState.removed.rawValue else { throw MiraError(.conflict, "A forgotten memory cannot be revised.") }
                guard current.revision == expectedRevision else { throw MiraError(.conflict, "The memory revision is out of date.") }
                guard current.scope == draft.scope, current.subject == draft.subject else { throw MiraError(.invalidInput, "Memory revisions cannot change scope or subject.") }
                let updated = Memory(id: current.id, draft: draft, scope: current.scope, subject: current.subject, state: current.state, origin: current.origin, authority: current.authority, supersededBy: current.supersededBy, revision: current.revision + 1, createdAt: current.createdAt, updatedAt: at, deletedAt: current.deletedAt, forgottenAt: current.forgottenAt)
                try updateMemory(updated, in: db)
                try insertMemoryRevision(MemoryRevision(memoryID: memoryID, revision: updated.revision, draft: draft, changedAt: at), in: db)
                try indexMemory(updated, in: db)
                return updated
            }
        }
    }

    public func confirmMemoryReplacement(_ candidateID: MemoryID, workspaceID: WorkspaceID?, replacingCurrent currentID: MemoryID, expectedCandidateRevision: Int, expectedCurrentRevision: Int, at: Date) throws -> Memory {
        try safely { try pool.write { db in
            guard candidateID != currentID else { throw MiraError(.invalidInput, "A replacement must use distinct memories.") }
            let candidate = try requireMemory(candidateID, workspaceID: workspaceID, in: db)
            let current = try requireMemory(currentID, workspaceID: workspaceID, in: db)
            guard candidate.state == .candidate, candidate.forgottenAt == nil, candidate.deletedAt == nil, candidate.supersededBy == nil else { throw MiraError(.conflict, "The replacement candidate is no longer available.") }
            guard current.state == .active, current.forgottenAt == nil, current.deletedAt == nil, current.supersededBy == nil else { throw MiraError(.conflict, "The current memory is no longer available.") }
            guard let candidateDraft = candidate.draft,
                  candidate.scope == current.scope, candidate.subject == current.subject,
                  compatibleMemoryValidity(current.draft, candidateDraft) else { throw MiraError(.invalidInput, "The replacement memory has incompatible validity dates.") }
            guard candidate.revision == expectedCandidateRevision, current.revision == expectedCurrentRevision else { throw MiraError(.conflict, "The memory revision is out of date.") }
            guard let proposal = try Row.fetchOne(db, sql: "SELECT previous_id FROM memory_replacements WHERE replacement_id = ? AND state = 'proposed' ORDER BY created_at DESC, id DESC LIMIT 1", arguments: [memoryIDString(candidateID)]),
                  let previousID = try? memoryID(proposal["previous_id"] as String),
                  try successorChain(from: previousID, to: currentID, in: db) else { throw MiraError(.conflict, "The selected memory is not the proposed replacement successor.") }

            let nextCandidate = Memory(id: candidate.id, draft: candidate.draft, scope: candidate.scope, subject: candidate.subject, state: .active, origin: candidate.origin, authority: candidate.authority, supersededBy: nil, revision: candidate.revision + 1, createdAt: candidate.createdAt, updatedAt: at, deletedAt: nil, forgottenAt: nil)
            let nextCurrent = Memory(id: current.id, draft: current.draft, scope: current.scope, subject: current.subject, state: current.state, origin: current.origin, authority: current.authority, supersededBy: candidateID, revision: current.revision + 1, createdAt: current.createdAt, updatedAt: at, deletedAt: current.deletedAt, forgottenAt: current.forgottenAt)
            try updateMemory(nextCandidate, in: db)
            try updateMemory(nextCurrent, in: db)
            try insertMemoryRevision(MemoryRevision(memoryID: candidateID, revision: nextCandidate.revision, draft: nextCandidate.draft, actor: "user", changedAt: at), in: db)
            try insertMemoryRevision(MemoryRevision(memoryID: currentID, revision: nextCurrent.revision, draft: nextCurrent.draft, actor: "user", changedAt: at), in: db)
            try rejectProposedReplacements(for: candidateID, in: db)
            let confirmed = MemoryReplacement(replacementID: candidateID, previousID: currentID, state: .confirmed, createdAt: at)
            try insertMemoryReplacement(confirmed, in: db)
            try indexMemory(nextCandidate, in: db)
            try indexMemory(nextCurrent, in: db)
            return nextCandidate
        }}
    }

    public func changeMemoryState(_ memoryID: MemoryID, workspaceID: WorkspaceID?, state: MemoryState, expectedRevision: Int, at: Date) throws -> Memory {
        try safely { try pool.write { db in
            let current = try requireMemory(memoryID, workspaceID: workspaceID, in: db)
            guard current.forgottenAt == nil else { throw MiraError(.conflict, "A forgotten memory cannot change state.") }
            guard current.revision == expectedRevision else { throw MiraError(.conflict, "The memory revision is out of date.") }
            if state.rawValue == MemoryState.active.rawValue, try Int.fetchOne(db, sql: "SELECT 1 FROM memory_replacements WHERE replacement_id = ? AND state = 'proposed' LIMIT 1", arguments: [memoryIDString(memoryID)]) != nil {
                throw MiraError(.conflict, "A memory with an unresolved replacement cannot be approved.")
            }
            let updated = Memory(id: current.id, draft: current.draft, scope: current.scope, subject: current.subject, state: state, origin: current.origin, authority: current.authority, supersededBy: current.supersededBy, revision: current.revision + 1, createdAt: current.createdAt, updatedAt: at, deletedAt: state.rawValue == MemoryState.removed.rawValue ? at : nil, forgottenAt: current.forgottenAt)
            try updateMemory(updated, in: db)
            try insertMemoryRevision(MemoryRevision(memoryID: memoryID, revision: updated.revision, draft: current.draft, changedAt: at), in: db)
            if state.rawValue == MemoryState.rejected.rawValue || state.rawValue == MemoryState.removed.rawValue { try suppressSources(for: memoryID, at: at, reason: state.rawValue, in: db) }
            if state == .rejected { try rejectProposedReplacements(for: memoryID, in: db) }
            try indexMemory(updated, in: db)
            return updated
        }}
    }

    public func forgetMemory(_ memoryID: MemoryID, workspaceID: WorkspaceID?, expectedRevision: Int, at: Date) throws -> MemoryForgetReceipt {
        try safely { try pool.write { db in
            let current = try requireMemory(memoryID, workspaceID: workspaceID, in: db)
            guard current.forgottenAt == nil else { throw MiraError(.conflict, "The memory has already been forgotten.") }
            guard current.revision == expectedRevision else { throw MiraError(.conflict, "The memory revision is out of date.") }
            let updated = Memory(id: current.id, draft: nil, scope: current.scope, subject: current.subject, state: .removed, origin: current.origin, authority: current.authority, supersededBy: current.supersededBy, revision: current.revision + 1, createdAt: current.createdAt, updatedAt: at, deletedAt: at, forgottenAt: at)
            try updateMemory(updated, in: db)
            try insertMemoryRevision(MemoryRevision(memoryID: memoryID, revision: updated.revision, draft: nil, actor: "user", changedAt: at, bodyPurgedAt: at), in: db)
            try suppressSources(for: memoryID, at: at, reason: "forgotten", in: db)
            for row in try Row.fetchAll(db, sql: "SELECT id, memory_id, source_kind, source_id, source_revision, conversation_id, excerpt, source_hash, speaker_role, created_at, body_purged_at, evidence_json FROM memory_evidence WHERE memory_id = ?", arguments: [memoryIDString(memoryID)]) {
                let evidence = try memoryEvidence(row)
                let purged = MemoryEvidence(id: evidence.id, memoryID: evidence.memoryID, sourceKind: evidence.sourceKind, sourceID: evidence.sourceID, sourceRevision: evidence.sourceRevision, conversationID: evidence.conversationID, excerpt: nil, sourceHash: nil, speakerRole: evidence.speakerRole, createdAt: evidence.createdAt, bodyPurgedAt: at)
                try db.execute(sql: "UPDATE memory_evidence SET excerpt = NULL, source_hash = NULL, body_purged_at = ?, evidence_json = ? WHERE id = ?", arguments: [at.timeIntervalSince1970, try encodeMemory(purged), uuidString(evidence.id)])
            }
            for row in try Row.fetchAll(db, sql: "SELECT memory_id, revision, draft_json, actor, changed_at, body_purged_at, revision_json FROM memory_revisions WHERE memory_id = ?", arguments: [memoryIDString(memoryID)]) {
                let revision = try memoryRevision(row)
                let purged = MemoryRevision(memoryID: revision.memoryID, revision: revision.revision, draft: nil, actor: revision.actor, changedAt: revision.changedAt, bodyPurgedAt: at)
                try db.execute(sql: "UPDATE memory_revisions SET draft_json = NULL, body_purged_at = ?, revision_json = ? WHERE memory_id = ? AND revision = ?", arguments: [at.timeIntervalSince1970, try encodeMemory(purged), memoryIDString(memoryID), revision.revision])
            }
            try db.execute(sql: "DELETE FROM memory_search WHERE memory_id = ?", arguments: [memoryIDString(memoryID)])
            let executionRows = try Row.fetchAll(db, sql: "WITH RECURSIVE affected(id) AS (SELECT DISTINCT execution_id FROM memory_usages WHERE memory_id = ? UNION SELECT dependency.execution_id FROM execution_history_dependencies dependency JOIN affected ON dependency.source_execution_id = affected.id) SELECT id FROM affected", arguments: [memoryIDString(memoryID)])
            let executionIDs = Set(try executionRows.map { try executionID($0["id"] as String) })
            for executionID in executionIDs {
                let executionKey = executionIDString(executionID)
                try db.execute(sql: "UPDATE executions SET body_purged_at = ?, error_json = NULL, status = CASE WHEN status IN ('queued', 'waitingForModel') THEN 'interrupted' ELSE status END, updated_at = ? WHERE id = ?", arguments: [at.timeIntervalSince1970, at.timeIntervalSince1970, executionKey])
                try db.execute(sql: "UPDATE model_attempts SET request_json = NULL, output_json = NULL, error_json = NULL, body_purged_at = ?, status = CASE WHEN status = 'prepared' THEN 'interrupted' ELSE status END, completed_at = CASE WHEN status = 'prepared' THEN COALESCE(completed_at, ?) ELSE completed_at END WHERE execution_id = ?", arguments: [at.timeIntervalSince1970, at.timeIntervalSince1970, executionKey])
                try db.execute(sql: "UPDATE tool_invocations SET arguments_json = NULL, result_json = NULL, body_purged_at = ?, status = CASE WHEN status = 'pending' THEN 'cancelledBeforeDispatch' WHEN status = 'dispatched' THEN 'interrupted' ELSE status END, completed_at = CASE WHEN status IN ('pending', 'dispatched') THEN COALESCE(completed_at, ?) ELSE completed_at END WHERE execution_id = ?", arguments: [at.timeIntervalSince1970, at.timeIntervalSince1970, executionKey])
                try db.execute(sql: "UPDATE execution_steps SET output_json = NULL, error_json = NULL, body_purged_at = ?, state = CASE WHEN state IN ('running', 'waitingForTool') THEN 'interrupted' ELSE state END, completed_at = CASE WHEN state IN ('running', 'waitingForTool') THEN COALESCE(completed_at, ?) ELSE completed_at END WHERE execution_id = ?", arguments: [at.timeIntervalSince1970, at.timeIntervalSince1970, executionKey])
                try db.execute(sql: "UPDATE messages SET text = '', body_purged_at = ? WHERE execution_id = ? AND role = 'assistant'", arguments: [at.timeIntervalSince1970, executionKey])
                try db.execute(sql: "UPDATE assistant_drafts SET text = '', body_purged_at = ? WHERE execution_id = ?", arguments: [at.timeIntervalSince1970, executionKey])
            }
            return MemoryForgetReceipt(memoryID: memoryID, redactedExecutionIDs: executionIDs)
        }}
    }

    public func recallMemories(query: String, workspaceID: WorkspaceID?, connectionID: ConnectionID, limit: Int, at: Date) throws -> MemorySearchResult {
        try safely {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let limit = try memoryLimit(limit)
            return try pool.read { db in
                try validateWorkspacePolicy(workspaceID, connectionID: connectionID, in: db)
                guard !trimmed.isEmpty else { return MemorySearchResult(memories: []) }
                return try memorySearch(in: db, workspaceID: workspaceID, states: [.active], query: trimmed, limit: limit, enforcePolicy: true, connectionID: connectionID, at: at)
            }
        }
    }

    public func recallMemory(_ memoryID: MemoryID, workspaceID: WorkspaceID?, connectionID: ConnectionID, at: Date) throws -> Memory {
        try safely { try pool.read { db in
            try validateWorkspacePolicy(workspaceID, connectionID: connectionID, in: db)
            let memory = try requireMemory(memoryID, workspaceID: workspaceID, in: db)
            guard memory.canRecall(in: workspaceID, connectionID: connectionID, at: at), try memorySourcePolicyAllows(memory, connectionID: connectionID, in: db) else { throw MiraError(.notFound, "The memory is not available for recall.") }
            return memory
        }}
    }

    public func recordMemoryUsage(_ usages: [MemoryUsage], executionID: ExecutionID, at: Date) throws {
        try safely { try pool.write { db in
            guard !usages.isEmpty else { return }
            try validateExecutionMemoryContext(executionID, usages: usages, at: at, in: db, requireCurrentRevision: true)
            for usage in usages {
                if let row = try Row.fetchOne(db, sql: "SELECT revision, usage_kind, usage_json FROM memory_usages WHERE execution_id = ? AND memory_id = ?", arguments: [executionIDString(executionID), memoryIDString(usage.memoryID)]) {
                    let stored: MemoryUsage = try decodeMemory(row["usage_json"] as String)
                    guard stored.memoryID == usage.memoryID, stored.revision == row["revision"] as Int, stored == usage, let kind = MemoryUsageKind(rawValue: row["usage_kind"] as String) else { throw MiraError(.conflict, "The memory usage revision is out of date.") }
                    if kind == .capture {
                        try db.execute(sql: "UPDATE memory_usages SET usage_kind = 'recall' WHERE execution_id = ? AND memory_id = ?", arguments: [executionIDString(executionID), memoryIDString(usage.memoryID)])
                    }
                } else {
                    try db.execute(sql: "INSERT INTO memory_usages (execution_id, memory_id, revision, usage_kind, created_at, usage_json) VALUES (?, ?, ?, 'recall', ?, ?)", arguments: [executionIDString(executionID), memoryIDString(usage.memoryID), usage.revision, at.timeIntervalSince1970, try encodeMemory(usage)])
                }
            }
        }}
    }

    public func validateMemoryUsage(executionID: ExecutionID, at: Date) throws {
        try safely { try pool.read { db in
            let usagesWithKinds = try Row.fetchAll(db, sql: "SELECT memory_id, revision, usage_kind, usage_json FROM memory_usages WHERE execution_id = ?", arguments: [executionIDString(executionID)]).map { row -> (MemoryUsage, MemoryUsageKind) in
                let stored: MemoryUsage = try decodeMemory(row["usage_json"] as String)
                guard memoryIDString(stored.memoryID) == (row["memory_id"] as String), stored.revision == row["revision"] as Int, let kind = MemoryUsageKind(rawValue: row["usage_kind"] as String) else { throw MiraError(.storage, "The memory usage record is invalid.") }
                return (stored, kind)
            }
            try validateExecutionMemoryContext(executionID, usages: usagesWithKinds.map(\.0), usageKinds: Dictionary(uniqueKeysWithValues: usagesWithKinds.map { ($0.0.memoryID, $0.1) }), at: at, in: db)
        }}
    }

    public func suppressedMemorySourceMessageIDs() throws -> Set<MessageID> {
        try safely { try pool.read { db in
            let rows = try String.fetchAll(db, sql: "SELECT source_id FROM memory_source_suppressions WHERE source_kind = 'message'")
            return Set(try rows.map { try MessageID(UUID(uuidString: $0).unwrap(or: MiraError(.storage, "The suppressed memory source ID is invalid."))) })
        }}
    }
}

extension SQLiteMiraStore {
    struct MemorySourceInfo {
        let kind: MemoryEvidenceKind
        let sourceID: UUID
        let sourceRevision: Int
        let conversationID: ConversationID?
        let excerpt: String
        let sourceHash: String
    }

    func memoryLimit(_ value: Int) throws -> Int {
        guard value > 0 else { throw MiraError(.invalidInput, "Memory result limit must be positive.") }
        return min(value, 200)
    }

    func memorySearch(in db: Database, workspaceID: WorkspaceID?, states: Set<MemoryState>, query: String, limit: Int, enforcePolicy: Bool, connectionID: ConnectionID?, at: Date?) throws -> MemorySearchResult {
        guard !states.isEmpty else { return MemorySearchResult(memories: []) }
        guard query.unicodeScalars.count <= 500 else { throw MiraError(.invalidInput, "Memory search query is too long.") }
        let orderedStates = states.sorted { $0.rawValue < $1.rawValue }
        var conditions = ["m.state IN (\(orderedStates.map { _ in "?" }.joined(separator: ",")))"]
        var arguments = StatementArguments(orderedStates.map(\.rawValue))
        if let workspaceID {
            conditions.append("m.scope_key IN (?, ?)")
            _ = arguments.append(contentsOf: StatementArguments(["global", "workspace:\(workspaceID.rawValue.uuidString.lowercased())"]))
        } else {
            conditions.append("m.scope_key = ?")
            _ = arguments.append(contentsOf: StatementArguments(["global"]))
        }
        if enforcePolicy {
            conditions.append("m.forgotten_at IS NULL AND m.deleted_at IS NULL AND m.draft_json IS NOT NULL AND m.superseded_by IS NULL")
            conditions.append("json_extract(m.draft_json, '$.allowsRemoteUse') = 1")
            if let connectionID {
                // ConnectionID is a Codable EntityID, so each allowlist item is
                // an object with a rawValue field rather than a JSON string.
                conditions.append("(json_extract(m.draft_json, '$.allowedConnectionIDs') IS NULL OR EXISTS (SELECT 1 FROM json_each(json_extract(m.draft_json, '$.allowedConnectionIDs')) WHERE lower(json_extract(value, '$.rawValue')) = lower(?)))")
                _ = arguments.append(contentsOf: StatementArguments([Self.id(connectionID)]))
                // A global memory derived from a workspace message inherits
                // that source workspace's outbound policy. Apply this filter
                // before the result cap so a blocked source cannot leak into recall.
                conditions.append("""
                    NOT EXISTS (
                      SELECT 1
                      FROM memory_evidence me
                      JOIN conversations source_conversation ON source_conversation.id = me.conversation_id
                      JOIN workspaces source_workspace ON source_workspace.id = source_conversation.workspace_id
                      WHERE me.memory_id = m.id AND me.source_kind = 'message'
                        AND (source_workspace.allows_remote_send = 0 OR
                             (source_workspace.allowed_connection_ids_json IS NOT NULL AND NOT EXISTS (
                               SELECT 1 FROM json_each(json_extract(source_workspace.allowed_connection_ids_json, '$'))
                               WHERE lower(CAST(value AS TEXT)) = lower(?)
                             )))
                    )
                    """)
                _ = arguments.append(contentsOf: StatementArguments([Self.id(connectionID)]))
            }
            if let at {
                // Memory drafts are persisted with millisecondsSince1970 by the
                // store encoder. Apply temporal policy in SQL before the result
                // cap so expired rows cannot hide eligible memories.
                let epochMilliseconds = at.timeIntervalSince1970 * 1_000
                conditions.append("(json_extract(m.draft_json, '$.validFrom') IS NULL OR CAST(json_extract(m.draft_json, '$.validFrom') AS REAL) <= ?)")
                conditions.append("(json_extract(m.draft_json, '$.validUntil') IS NULL OR CAST(json_extract(m.draft_json, '$.validUntil') AS REAL) > ?)")
                _ = arguments.append(contentsOf: StatementArguments([epochMilliseconds, epochMilliseconds]))
            }
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var from = "memories m"
        var rank = "0.0"
        let terms = memorySearchTerms(trimmed)
        if !trimmed.isEmpty && enforcePolicy {
            if terms.isEmpty {
                // A stop-word-only recall query must not turn into a broad
                // metadata/content scan.
                conditions.append("0 = 1")
            } else if trimmed.count >= 3 {
                from += " JOIN memory_search ON memory_search.memory_id = m.id"
                let ftsQuery = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
                conditions.append("memory_search MATCH ?")
                _ = arguments.append(contentsOf: StatementArguments([ftsQuery]))
                rank = "bm25(memory_search)"
            } else {
                let escaped = trimmed.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                conditions.append("lower(COALESCE(json_extract(m.draft_json, '$.content'), '')) LIKE lower(?) ESCAPE '\\'")
                _ = arguments.append(contentsOf: StatementArguments(["%\(escaped)%"]))
            }
        } else if !trimmed.isEmpty {
            let escaped = trimmed.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            conditions.append("lower(COALESCE(json_extract(m.draft_json, '$.content'), '')) LIKE lower(?) ESCAPE '\\'")
            _ = arguments.append(contentsOf: StatementArguments(["%\(escaped)%"]))
        }
        let sql = "SELECT m.id, m.scope_key, m.scope_json, m.subject, m.state, m.origin, m.authority, m.superseded_by, m.revision, m.created_at, m.updated_at, m.deleted_at, m.forgotten_at, m.draft_json, m.source_kind, m.source_id, m.assertion_hash, m.memory_json, \(rank) AS search_rank FROM \(from) WHERE \(conditions.joined(separator: " AND ")) ORDER BY search_rank ASC, m.id ASC LIMIT 2001"
        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        var memories: [Memory] = []
        memories.reserveCapacity(min(limit, rows.count))
        for row in rows {
            let candidate = try memory(row)
            if enforcePolicy, let connectionID, let at, !candidate.canRecall(in: workspaceID, connectionID: connectionID, at: at) { continue }
            memories.append(candidate)
            if memories.count > limit { break }
        }
        return MemorySearchResult(memories: Array(memories.prefix(limit)), isTruncated: memories.count > limit || rows.count > limit)
    }

    /// Produces terms compatible with the trigram index while treating
    /// punctuation as a separator. CJK runs are emitted as bounded overlapping
    /// three-scalar grams; short CJK queries use the LIKE path above.
    func memorySearchTerms(_ query: String) -> [String] {
        let stopWords: Set<String> = ["a", "an", "and", "are", "for", "in", "is", "it", "my", "of", "on", "or", "the", "to"]
        var terms: [String] = []
        var latin = ""
        var cjkRun: [Character] = []

        func flushLatin() {
            guard !latin.isEmpty else { return }
            let normalized = latin.lowercased()
            if !stopWords.contains(normalized) { terms.append(normalized) }
            latin.removeAll(keepingCapacity: true)
        }
        func flushCJK() {
            guard !cjkRun.isEmpty else { return }
            if cjkRun.count < 3 {
                terms.append(String(cjkRun))
            } else {
                for index in 0...(cjkRun.count - 3) {
                    terms.append(String(cjkRun[index..<(index + 3)]))
                    if terms.count >= 24 { break }
                }
            }
            cjkRun.removeAll(keepingCapacity: true)
        }

        for character in query {
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
                flushLatin(); flushCJK(); continue
            }
            let value = scalar.value
            let isCJK = (0x3400...0x4DBF).contains(value) ||
                (0x4E00...0x9FFF).contains(value) ||
                (0xF900...0xFAFF).contains(value) ||
                (0x20000...0x2FA1F).contains(value)
            if isCJK {
                flushLatin()
                cjkRun.append(character)
            } else if CharacterSet.alphanumerics.contains(scalar) {
                flushCJK()
                latin.append(character)
            } else {
                flushLatin(); flushCJK()
            }
            if terms.count >= 24 { break }
        }
        flushLatin(); flushCJK()
        return Array(terms.prefix(24))
    }

    func resolveMemorySource(_ source: MemorySourceInput, draft: MemoryDraft, in db: Database) throws -> MemorySourceInfo {
        switch source {
        case .message(let messageID, let excerpt):
            guard !excerpt.isEmpty, excerpt.utf8.count <= 8_192 else { throw MiraError(.invalidInput, "Memory evidence excerpt is required and must be short.") }
            guard let row = try Row.fetchOne(db, sql: "SELECT conversation_id, role, status, text, body_purged_at FROM messages WHERE id = ?", arguments: [messageIDString(messageID)]) else { throw MiraError(.notFound, "The source message does not exist.") }
            guard row["role"] as String == MessageRole.user.rawValue, row["status"] as String == MessageStatus.committed.rawValue, (row["body_purged_at"] as Double?) == nil else { throw MiraError(.invalidInput, "Memory evidence must cite a committed user message.") }
            let text = row["text"] as String
            guard text.contains(excerpt) else { throw MiraError(.invalidInput, "Memory evidence must be an exact excerpt from the source message.") }
            let conversationID = try conversationID(row["conversation_id"] as String)
            let workspaceID = try workspaceIDForConversation(conversationID, in: db)
            if case .workspace(let scopeWorkspace) = draft.scope {
                guard workspaceID == scopeWorkspace else { throw MiraError(.invalidInput, "The source message is outside the memory workspace scope.") }
            }
            return MemorySourceInfo(kind: .message, sourceID: messageID.rawValue, sourceRevision: 1, conversationID: conversationID, excerpt: excerpt, sourceHash: memoryPayloadHashString(text))
        case .manualEntry(let id, let statement):
            guard !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, statement.utf8.count <= 8_192 else { throw MiraError(.invalidInput, "Manual memory evidence is required and must be at most 8 KiB.") }
            return MemorySourceInfo(kind: .manualEntry, sourceID: id, sourceRevision: 1, conversationID: nil, excerpt: statement, sourceHash: memoryPayloadHashString(statement))
        }
    }

    func validateSelectedWorkspace(_ workspaceID: WorkspaceID?, in db: Database) throws {
        guard let workspaceID else { return }
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM workspaces WHERE id = ?", arguments: [Self.id(workspaceID)]) != nil else { throw MiraError(.notFound, "The workspace does not exist.") }
    }

    func validateMemoryScope(_ scope: MemoryScope, in db: Database) throws {
        try validateSelectedWorkspace(scope.workspaceID, in: db)
    }

    func memoryScopeVisible(_ scope: MemoryScope, in workspaceID: WorkspaceID?) -> Bool { scope.isVisible(in: workspaceID) && (workspaceID != nil || scope == .global) }

    func memorySourcePolicyAllows(_ memory: Memory, connectionID: ConnectionID, in db: Database) throws -> Bool {
        let evidenceRows = try Row.fetchAll(db, sql: "SELECT conversation_id FROM memory_evidence WHERE memory_id = ? AND source_kind = 'message'", arguments: [memoryIDString(memory.id)])
        for row in evidenceRows {
            guard let conversationID = row["conversation_id"] as String?,
                  let workspaceID = try String.fetchOne(db, sql: "SELECT workspace_id FROM conversations WHERE id = ?", arguments: [conversationID]) else { continue }
            guard let workspace = try Row.fetchOne(db, sql: "SELECT allows_remote_send, allowed_connection_ids_json FROM workspaces WHERE id = ?", arguments: [workspaceID]),
                  (workspace["allows_remote_send"] as Int) != 0 else { return false }
            let allowlist = try Self.decodeConnectionAllowlist(workspace["allowed_connection_ids_json"] as String?)
            guard allowlist.map({ $0.contains(connectionID) }) ?? true else { return false }
        }
        return true
    }

    func requireMemory(_ memoryID: MemoryID, workspaceID: WorkspaceID?, in db: Database) throws -> Memory {
        guard let row = try Row.fetchOne(db, sql: "SELECT id, scope_key, scope_json, subject, state, origin, authority, superseded_by, revision, created_at, updated_at, deleted_at, forgotten_at, draft_json, source_kind, source_id, assertion_hash, memory_json FROM memories WHERE id = ?", arguments: [memoryIDString(memoryID)]) else { throw MiraError(.notFound, "The memory does not exist.") }
        let value = try memory(row)
        guard memoryScopeVisible(value.scope, in: workspaceID) else { throw MiraError(.notFound, "The memory does not exist.") }
        return value
    }

    func validateWorkspacePolicy(_ workspaceID: WorkspaceID?, connectionID: ConnectionID, in db: Database) throws {
        guard let workspaceID else { return }
        guard let row = try Row.fetchOne(db, sql: "SELECT allows_remote_send, allowed_connection_ids_json FROM workspaces WHERE id = ?", arguments: [workspaceID.rawValue.uuidString.lowercased()]) else { throw MiraError(.notFound, "The workspace does not exist.") }
        guard row["allows_remote_send"] as Int != 0 else { throw MiraError(.unauthorized, "This workspace does not allow sending to model services.") }
        let allowlist = try Self.decodeConnectionAllowlist(row["allowed_connection_ids_json"] as String?)
        guard allowlist.map({ $0.contains(connectionID) }) ?? true else { throw MiraError(.unauthorized, "This workspace does not allow the selected provider connection.") }
    }

    func currentRoute(for frozen: ResolvedModelRouteSnapshot, in db: Database) throws -> ResolvedModelRouteSnapshot {
        guard let routeRow = try Row.fetchOne(db, sql: "SELECT id, revision, name, model_descriptor_id, max_output_tokens, requests_usage, route_json FROM model_routes WHERE id = ?", arguments: [Self.id(frozen.id)]),
              let modelID: String = routeRow["model_descriptor_id"] else { throw MiraError(.conflict, "The provider route no longer exists.") }
        let route = try Self.modelRoute(routeRow)
        guard let modelRow = try Row.fetchOne(db, sql: "SELECT id, revision, connection_id, connection_revision, model_id, context_window, text_capability, tool_capability, probe_observation_json, model_json FROM model_descriptors WHERE id = ?", arguments: [modelID]) else { throw MiraError(.conflict, "The provider model no longer exists.") }
        let model = try Self.modelDescriptor(modelRow)
        guard let connectionRow = try Row.fetchOne(db, sql: "SELECT id, revision, name, provider_kind, base_url, credential_reference, credential_version, allows_loopback_http, connection_json FROM provider_connections WHERE id = ?", arguments: [Self.id(model.connectionID)]) else { throw MiraError(.conflict, "The provider connection no longer exists.") }
        let connection = try Self.providerConnection(connectionRow)
        return ResolvedModelRouteSnapshot(route: route, model: model, connection: connection, purpose: frozen.purpose, selection: frozen.selectionSource)
    }

    func validateExecutionMemoryContext(_ executionID: ExecutionID, usages: [MemoryUsage], usageKinds: [MemoryID: MemoryUsageKind] = [:], at: Date, in db: Database, requireCurrentRevision: Bool = true) throws {
        guard let execution = try Row.fetchOne(db, sql: "SELECT conversation_id, status, route_json FROM executions WHERE id = ?", arguments: [executionIDString(executionID)]) else { throw MiraError(.notFound, "The execution does not exist.") }
        guard let status = ExecutionStatus(rawValue: execution["status"] as String), !status.isTerminal else { throw MiraError(.conflict, "The execution has already finished.") }
        guard !usages.isEmpty else { return }
        let route = try Self.decodeRoute(execution["route_json"] as String)
        let conversationID = try conversationID(execution["conversation_id"] as String)
        let workspaceID = try workspaceIDForConversation(conversationID, in: db)
        if usages.contains(where: { usageKinds[$0.memoryID, default: .recall] == .recall }) {
            try validateWorkspacePolicy(workspaceID, connectionID: route.connectionID, in: db)
        }
        for usage in usages {
            let memory = try requireMemory(usage.memoryID, workspaceID: workspaceID, in: db)
            guard let revisionRow = try Row.fetchOne(db, sql: "SELECT memory_id, revision, draft_json, actor, changed_at, body_purged_at, revision_json FROM memory_revisions WHERE memory_id = ? AND revision = ?", arguments: [memoryIDString(usage.memoryID), usage.revision]) else { throw MiraError(.unauthorized, "The memory revision is no longer available for this execution.") }
            _ = try memoryRevision(revisionRow)
            if usageKinds[usage.memoryID, default: .recall] == .recall {
                if requireCurrentRevision {
                    guard usage.revision == memory.revision else { throw MiraError(.conflict, "The memory revision is out of date for this execution.") }
                }
                guard memory.canRecall(in: workspaceID, connectionID: route.connectionID, at: at), try memorySourcePolicyAllows(memory, connectionID: route.connectionID, in: db) else { throw MiraError(.unauthorized, "The memory is no longer authorized for this execution.") }
            } else {
                guard memory.forgottenAt == nil, memory.deletedAt == nil, memory.draft != nil else { throw MiraError(.unauthorized, "The captured memory is no longer available for this execution.") }
            }
        }
    }

    func compatibleMemoryValidity(_ old: MemoryDraft?, _ new: MemoryDraft) -> Bool {
        guard let old else { return true }
        let start = max(old.validFrom ?? .distantPast, new.validFrom ?? .distantPast)
        let end = min(old.validUntil ?? .distantFuture, new.validUntil ?? .distantFuture)
        return start < end
    }

    func successorChain(from previousID: MemoryID, to currentID: MemoryID, in db: Database) throws -> Bool {
        var seen: Set<MemoryID> = []
        var cursor = previousID
        for _ in 0..<64 {
            if cursor == currentID { return true }
            guard seen.insert(cursor).inserted,
                  let next = try String.fetchOne(db, sql: "SELECT superseded_by FROM memories WHERE id = ?", arguments: [memoryIDString(cursor)]),
                  let nextID = try? memoryID(next) else { return false }
            cursor = nextID
        }
        return false
    }

    func insertMemory(_ value: Memory, sourceKind: MemoryEvidenceKind, sourceID: UUID, assertionHash: String, in db: Database) throws {
        try db.execute(sql: "INSERT INTO memories (id, scope_key, scope_json, subject, state, origin, authority, superseded_by, revision, created_at, updated_at, deleted_at, forgotten_at, draft_json, source_kind, source_id, assertion_hash, memory_json) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, NULL, NULL, ?, ?, ?, ?, ?)", arguments: [memoryIDString(value.id), value.scope.key, try encodeMemory(value.scope), value.subject.rawValue, value.state.rawValue, value.origin.rawValue, value.authority.rawValue, value.revision, value.createdAt.timeIntervalSince1970, value.updatedAt.timeIntervalSince1970, value.draft.map { try encodeMemory($0) }, sourceKind.rawValue, uuidString(sourceID), assertionHash, try encodeMemory(value)])
    }

    func updateMemory(_ value: Memory, in db: Database) throws {
        let assertionHash: String
        if let draft = value.draft {
            assertionHash = memoryHash(draft.content)
        } else {
            guard let existing = try String.fetchOne(db, sql: "SELECT assertion_hash FROM memories WHERE id = ?", arguments: [memoryIDString(value.id)]) else { throw MiraError(.storage, "The memory does not exist.") }
            assertionHash = existing
        }
        try db.execute(sql: "UPDATE memories SET state = ?, superseded_by = ?, revision = ?, updated_at = ?, deleted_at = ?, forgotten_at = ?, draft_json = ?, assertion_hash = ?, memory_json = ? WHERE id = ? AND revision = ?", arguments: [value.state.rawValue, value.supersededBy.map(memoryIDString), value.revision, value.updatedAt.timeIntervalSince1970, value.deletedAt?.timeIntervalSince1970, value.forgottenAt?.timeIntervalSince1970, value.draft.map { try encodeMemory($0) }, assertionHash, try encodeMemory(value), memoryIDString(value.id), value.revision - 1])
        guard db.changesCount == 1 else { throw MiraError(.conflict, "The memory revision is out of date.") }
    }

    func insertMemoryEvidence(_ value: MemoryEvidence, in db: Database) throws {
        try db.execute(sql: "INSERT INTO memory_evidence (id, memory_id, source_kind, source_id, source_revision, conversation_id, excerpt, source_hash, speaker_role, created_at, body_purged_at, evidence_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [uuidString(value.id), memoryIDString(value.memoryID), value.sourceKind.rawValue, uuidString(value.sourceID), value.sourceRevision, value.conversationID.map(conversationIDString), value.excerpt, value.sourceHash, value.speakerRole.rawValue, value.createdAt.timeIntervalSince1970, value.bodyPurgedAt?.timeIntervalSince1970, try encodeMemory(value)])
    }

    func insertMemoryRevision(_ value: MemoryRevision, in db: Database) throws {
        try db.execute(sql: "INSERT INTO memory_revisions (memory_id, revision, draft_json, actor, changed_at, body_purged_at, revision_json) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [memoryIDString(value.memoryID), value.revision, value.draft.map { try encodeMemory($0) }, value.actor, value.changedAt.timeIntervalSince1970, value.bodyPurgedAt?.timeIntervalSince1970, try encodeMemory(value)])
    }

    func insertMemoryReplacement(_ value: MemoryReplacement, in db: Database) throws {
        try db.execute(sql: "INSERT INTO memory_replacements (id, replacement_id, previous_id, state, created_at, replacement_json) VALUES (?, ?, ?, ?, ?, ?)", arguments: [uuidString(value.id), memoryIDString(value.replacementID), memoryIDString(value.previousID), value.state.rawValue, value.createdAt.timeIntervalSince1970, try encodeMemory(value)])
    }

    func rejectProposedReplacements(for candidateID: MemoryID, in db: Database) throws {
        for row in try Row.fetchAll(db, sql: "SELECT id, replacement_id, previous_id, state, created_at, replacement_json FROM memory_replacements WHERE replacement_id = ? AND state = 'proposed'", arguments: [memoryIDString(candidateID)]) {
            let relation = try memoryReplacement(row)
            let rejected = MemoryReplacement(id: relation.id, replacementID: relation.replacementID, previousID: relation.previousID, state: .rejected, createdAt: relation.createdAt)
            try db.execute(sql: "UPDATE memory_replacements SET state = 'rejected', replacement_json = ? WHERE id = ? AND state = 'proposed'", arguments: [try encodeMemory(rejected), uuidString(relation.id)])
            guard db.changesCount == 1 else { throw MiraError(.conflict, "The memory replacement state is out of date.") }
        }
    }

    func insertMemoryReceipt(operationID: UUID, payloadHash: String, memory: Memory, disposition: MemoryWriteDisposition, at: Date, in db: Database) throws {
        let stored = StoredMemoryReceipt(memoryID: memory.id, disposition: disposition)
        try db.execute(sql: "INSERT INTO memory_operation_receipts (operation_id, payload_hash, memory_id, disposition, created_at, receipt_json) VALUES (?, ?, ?, ?, ?, ?)", arguments: [uuidString(operationID), payloadHash, memoryIDString(memory.id), disposition.rawValue, at.timeIntervalSince1970, try encodeMemory(stored)])
    }

    func suppressSources(for memoryID: MemoryID, at: Date, reason: String, in db: Database) throws {
        for row in try Row.fetchAll(db, sql: "SELECT source_kind, source_id FROM memory_evidence WHERE memory_id = ?", arguments: [memoryIDString(memoryID)]) {
            let kind: String = row["source_kind"]
            let sourceID: String = row["source_id"]
            guard let sourceKind = MemoryEvidenceKind(rawValue: kind), let sourceUUID = UUID(uuidString: sourceID) else { throw MiraError(.storage, "The memory suppression source is invalid.") }
            let payload = try encodeMemory(StoredMemorySuppression(sourceKind: sourceKind, sourceID: sourceUUID, reason: reason))
            try db.execute(sql: "INSERT INTO memory_source_suppressions (source_kind, source_id, suppressed_at, reason, suppression_json) VALUES (?, ?, ?, ?, ?) ON CONFLICT(source_kind, source_id) DO UPDATE SET suppressed_at = CASE WHEN CASE memory_source_suppressions.reason WHEN 'forgotten' THEN 3 WHEN 'rejected' THEN 2 ELSE 1 END >= CASE excluded.reason WHEN 'forgotten' THEN 3 WHEN 'rejected' THEN 2 ELSE 1 END THEN memory_source_suppressions.suppressed_at ELSE excluded.suppressed_at END, reason = CASE WHEN CASE memory_source_suppressions.reason WHEN 'forgotten' THEN 3 WHEN 'rejected' THEN 2 ELSE 1 END >= CASE excluded.reason WHEN 'forgotten' THEN 3 WHEN 'rejected' THEN 2 ELSE 1 END THEN memory_source_suppressions.reason ELSE excluded.reason END, suppression_json = CASE WHEN CASE memory_source_suppressions.reason WHEN 'forgotten' THEN 3 WHEN 'rejected' THEN 2 ELSE 1 END >= CASE excluded.reason WHEN 'forgotten' THEN 3 WHEN 'rejected' THEN 2 ELSE 1 END THEN memory_source_suppressions.suppression_json ELSE excluded.suppression_json END", arguments: [kind, sourceID, at.timeIntervalSince1970, reason, payload])
        }
    }

    func indexMemory(_ value: Memory, in db: Database) throws {
        try db.execute(sql: "DELETE FROM memory_search WHERE memory_id = ?", arguments: [memoryIDString(value.id)])
        guard let draft = value.draft, value.forgottenAt == nil else { return }
        try db.execute(sql: "INSERT INTO memory_search (memory_id, content) VALUES (?, ?)", arguments: [memoryIDString(value.id), draft.content])
    }

    func memory(_ row: Row) throws -> Memory {
        let value: Memory = try decodeMemory(row["memory_json"] as String)
        let scope: MemoryScope = try decodeMemory(row["scope_json"] as String)
        let draft: MemoryDraft? = try (row["draft_json"] as String?).map { try decodeMemory($0) }
        guard memoryIDString(value.id) == (row["id"] as String), value.scope == scope,
              value.scope.key == (row["scope_key"] as String), value.revision > 0,
              value.subject.rawValue == (row["subject"] as String), value.state.rawValue == (row["state"] as String),
              value.origin.rawValue == (row["origin"] as String), value.authority.rawValue == (row["authority"] as String),
              value.supersededBy.map(memoryIDString) == (row["superseded_by"] as String?), value.revision == row["revision"] as Int,
              memoryTimestampMatches(value.createdAt, row["created_at"] as Double?), memoryTimestampMatches(value.updatedAt, row["updated_at"] as Double?),
              optionalMemoryTimestampMatches(value.deletedAt, row["deleted_at"] as Double?), optionalMemoryTimestampMatches(value.forgottenAt, row["forgotten_at"] as Double?),
              value.draft == draft, value.forgottenAt != nil || draft != nil else { throw MiraError(.storage, "The memory contents are inconsistent.") }
        if let draft {
            try draft.validate()
            guard draft.scope == value.scope, draft.subject == value.subject else { throw MiraError(.storage, "The memory draft scope or subject is inconsistent.") }
        }
        guard value.state.rawValue != MemoryState.removed.rawValue || value.deletedAt != nil else { throw MiraError(.storage, "The memory deletion state is invalid.") }
        return value
    }

    func memoryEvidence(_ row: Row) throws -> MemoryEvidence {
        let value: MemoryEvidence = try decodeMemory(row["evidence_json"] as String)
        guard uuidString(value.id) == (row["id"] as String), memoryIDString(value.memoryID) == (row["memory_id"] as String),
              value.sourceKind.rawValue == (row["source_kind"] as String), uuidString(value.sourceID) == (row["source_id"] as String),
              value.sourceRevision == row["source_revision"] as Int, value.conversationID.map(conversationIDString) == (row["conversation_id"] as String?),
              value.excerpt == (row["excerpt"] as String?), value.sourceHash == (row["source_hash"] as String?), value.speakerRole.rawValue == (row["speaker_role"] as String),
              value.sourceRevision > 0, memoryTimestampMatches(value.createdAt, row["created_at"] as Double?),
              optionalMemoryTimestampMatches(value.bodyPurgedAt, row["body_purged_at"] as Double?),
              (value.bodyPurgedAt == nil) == (value.excerpt != nil && value.sourceHash != nil) else { throw MiraError(.storage, "The memory evidence contents are inconsistent.") }
        return value
    }

    func memoryRevision(_ row: Row) throws -> MemoryRevision {
        let value: MemoryRevision = try decodeMemory(row["revision_json"] as String)
        let draft: MemoryDraft? = try (row["draft_json"] as String?).map { try decodeMemory($0) }
        guard memoryIDString(value.memoryID) == (row["memory_id"] as String), value.revision == row["revision"] as Int,
              value.draft == draft, value.actor == (row["actor"] as String), memoryTimestampMatches(value.changedAt, row["changed_at"] as Double?),
              value.revision > 0, !value.actor.isEmpty,
              optionalMemoryTimestampMatches(value.bodyPurgedAt, row["body_purged_at"] as Double?),
              (value.bodyPurgedAt == nil) == (draft != nil) else { throw MiraError(.storage, "The memory revision contents are inconsistent.") }
        if let draft {
            try draft.validate()
        }
        return value
    }

    func memoryReplacement(_ row: Row) throws -> MemoryReplacement {
        let value: MemoryReplacement = try decodeMemory(row["replacement_json"] as String)
        guard uuidString(value.id) == (row["id"] as String), memoryIDString(value.replacementID) == (row["replacement_id"] as String), memoryIDString(value.previousID) == (row["previous_id"] as String), value.state.rawValue == (row["state"] as String), memoryTimestampMatches(value.createdAt, row["created_at"] as Double?) else { throw MiraError(.storage, "The memory replacement contents are inconsistent.") }
        return value
    }

    private func memoryPayloadHash(_ value: MemoryOperationPayload) throws -> String {
        let draft = value.draft
        let canonical = CanonicalMemoryOperationPayload(content: draft.content, scope: draft.scope, subject: draft.subject, kind: draft.kind, sensitivity: draft.sensitivity, allowsRemoteUse: draft.allowsRemoteUse, allowedConnectionIDs: draft.allowedConnectionIDs?.map { Self.id($0) }.sorted(), validFrom: draft.validFrom, validUntil: draft.validUntil, source: value.source, replacing: value.replacing, expectedRevision: value.expectedRevision)
        return try memoryPayloadHash(canonical)
    }
    func memoryPayloadHash<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func memoryHash(_ value: String) -> String { memoryPayloadHashString(normalizeMemoryAssertion(value)) }
    func normalizeMemoryAssertion(_ value: String) -> String { value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased() }
    func memoryPayloadHashString(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    func encodeMemory<T: Encodable>(_ value: T) throws -> String { try Self.encode(value) }
    func decodeMemory<T: Decodable>(_ value: String) throws -> T { try Self.decode(value) }
    func uuidString(_ value: UUID) -> String { value.uuidString.lowercased() }
    func memoryIDString(_ value: MemoryID) -> String { uuidString(value.rawValue) }
    func executionIDString(_ value: ExecutionID) -> String { uuidString(value.rawValue) }
    func messageIDString(_ value: MessageID) -> String { uuidString(value.rawValue) }
    func conversationIDString(_ value: ConversationID) -> String { uuidString(value.rawValue) }
    func memoryID(_ value: String) throws -> MemoryID { MemoryID(try uuid(value)) }
    func executionID(_ value: String) throws -> ExecutionID { ExecutionID(try uuid(value)) }
    func conversationID(_ value: String) throws -> ConversationID { ConversationID(try uuid(value)) }
    func workspaceIDForConversation(_ conversationID: ConversationID, in db: Database) throws -> WorkspaceID? {
        guard let row = try Row.fetchOne(db, sql: "SELECT workspace_id FROM conversations WHERE id = ?", arguments: [conversationIDString(conversationID)]) else { throw MiraError(.notFound, "The conversation does not exist.") }
        guard let value = row["workspace_id"] as String? else { return nil }
        return WorkspaceID(try uuid(value))
    }
    func uuid(_ value: String) throws -> UUID { guard let id = UUID(uuidString: value) else { throw MiraError(.storage, "The memory identifier is invalid.") }; return id }
}

extension SQLiteMiraStore {
    /// Validates memory rows and their duplicated typed payloads before a backup is installed.
    static func validateMemoryContents(in db: Database) throws {
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM memories WHERE scope_key LIKE 'workspace:%' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE 'workspace:' || id = memories.scope_key) LIMIT 1") == nil else { throw MiraError(.storage, "A memory refers to a missing workspace.") }
        for row in try Row.fetchAll(db, sql: "SELECT id, scope_key, scope_json, subject, state, origin, authority, superseded_by, revision, created_at, updated_at, deleted_at, forgotten_at, draft_json, source_kind, source_id, assertion_hash, memory_json FROM memories") {
            let value: Memory = try decode(row["memory_json"] as String)
            let scope: MemoryScope = try decode(row["scope_json"] as String)
            let draft: MemoryDraft? = try (row["draft_json"] as String?).map { try decode($0) }
            guard id(value.id) == (row["id"] as String), value.scope == scope, value.scope.key == (row["scope_key"] as String),
                  value.subject.rawValue == (row["subject"] as String), value.state.rawValue == (row["state"] as String),
                  value.origin.rawValue == (row["origin"] as String), value.authority.rawValue == (row["authority"] as String),
                  value.supersededBy.map(id) == (row["superseded_by"] as String?), value.revision == (row["revision"] as Int), value.revision > 0,
                  memoryTimestampMatches(value.createdAt, row["created_at"] as Double?), memoryTimestampMatches(value.updatedAt, row["updated_at"] as Double?),
                  optionalMemoryTimestampMatches(value.deletedAt, row["deleted_at"] as Double?), optionalMemoryTimestampMatches(value.forgottenAt, row["forgotten_at"] as Double?), value.draft == draft,
                  value.forgottenAt != nil || draft != nil,
                  MemoryEvidenceKind(rawValue: row["source_kind"] as String) != nil, UUID(uuidString: row["source_id"] as String) != nil else { throw MiraError(.storage, "The memory contents are inconsistent.") }
            if let draft {
                try draft.validate()
                guard draft.scope == value.scope, draft.subject == value.subject, memoryAssertionHash(draft.content) == (row["assertion_hash"] as String) else { throw MiraError(.storage, "The memory draft scope, subject, or assertion hash is inconsistent.") }
            }
            guard value.forgottenAt != nil || value.deletedAt == nil || value.state.rawValue == MemoryState.removed.rawValue else { throw MiraError(.storage, "The memory deletion state is invalid.") }

            let evidenceRows = try Row.fetchAll(db, sql: "SELECT id, memory_id, source_kind, source_id, source_revision, conversation_id, excerpt, source_hash, speaker_role, created_at, body_purged_at, evidence_json FROM memory_evidence WHERE memory_id = ?", arguments: [row["id"] as String])
            let evidence: [MemoryEvidence] = try evidenceRows.map { try decode($0["evidence_json"] as String) }
            guard evidence.contains(where: { $0.sourceKind.rawValue == (row["source_kind"] as String) && uuidString($0.sourceID) == (row["source_id"] as String) }) else { throw MiraError(.storage, "The memory source fields do not match its evidence.") }
            for item in evidence where item.sourceKind == .message {
                let evidenceConversationID = item.conversationID.map { Self.id($0) }
                guard let source = try Row.fetchOne(db, sql: "SELECT conversation_id, role, status FROM messages WHERE id = ?", arguments: [uuidString(item.sourceID)]),
                      (source["role"] as String) == MessageRole.user.rawValue,
                      (source["status"] as String) == MessageStatus.committed.rawValue,
                      (source["conversation_id"] as String) == evidenceConversationID else { throw MiraError(.storage, "The memory evidence source message is invalid.") }
                let sourceWorkspaceValue = try String.fetchOne(db, sql: "SELECT workspace_id FROM conversations WHERE id = ?", arguments: [source["conversation_id"] as String])
                let sourceWorkspace = try sourceWorkspaceValue.map { WorkspaceID(try uuid($0)) }
                if case .workspace(let memoryWorkspace) = value.scope {
                    guard memoryWorkspace == sourceWorkspace else { throw MiraError(.storage, "The memory evidence source is outside its workspace scope.") }
                }
            }
            let requiredSuppression: String? = value.forgottenAt != nil ? "forgotten" : (value.state == .rejected ? "rejected" : (value.state == .removed ? "removed" : nil))
            if let requiredSuppression {
                for item in evidence {
                    guard let suppression = try Row.fetchOne(db, sql: "SELECT source_kind, source_id, suppressed_at, reason, suppression_json FROM memory_source_suppressions WHERE source_kind = ? AND source_id = ?", arguments: [item.sourceKind.rawValue, uuidString(item.sourceID)]),
                          Self.suppressionRank(suppression["reason"] as String) >= Self.suppressionRank(requiredSuppression) else { throw MiraError(.storage, "The memory source suppression is missing.") }
                }
            }
            if value.forgottenAt != nil {
                guard draft == nil,
                      evidence.allSatisfy({ $0.bodyPurgedAt != nil && $0.excerpt == nil && $0.sourceHash == nil }),
                      try Int.fetchOne(db, sql: "SELECT 1 FROM memory_search WHERE memory_id = ?", arguments: [row["id"] as String]) == nil,
                      try Int.fetchOne(db, sql: "SELECT 1 FROM memory_revisions WHERE memory_id = ? AND (body_purged_at IS NULL OR draft_json IS NOT NULL)", arguments: [row["id"] as String]) == nil else { throw MiraError(.storage, "The forgotten memory still contains a body.") }
            }
        }
        for row in try Row.fetchAll(db, sql: "SELECT id, memory_id, source_kind, source_id, source_revision, conversation_id, excerpt, source_hash, speaker_role, created_at, body_purged_at, evidence_json FROM memory_evidence") {
            let value: MemoryEvidence = try decode(row["evidence_json"] as String)
            guard uuidString(value.id) == (row["id"] as String), id(value.memoryID) == (row["memory_id"] as String), value.sourceKind.rawValue == (row["source_kind"] as String),
                  uuidString(value.sourceID) == (row["source_id"] as String), value.sourceRevision == (row["source_revision"] as Int), value.sourceRevision > 0,
                  value.conversationID.map(id) == (row["conversation_id"] as String?), value.excerpt == (row["excerpt"] as String?), value.sourceHash == (row["source_hash"] as String?),
                  value.speakerRole.rawValue == (row["speaker_role"] as String), memoryTimestampMatches(value.createdAt, row["created_at"] as Double?),
                  optionalMemoryTimestampMatches(value.bodyPurgedAt, row["body_purged_at"] as Double?) else { throw MiraError(.storage, "The memory evidence contents are inconsistent.") }
            guard (value.bodyPurgedAt == nil) == (value.excerpt != nil && value.sourceHash != nil) else { throw MiraError(.storage, "The memory evidence purge marker is invalid.") }
        }
        for row in try Row.fetchAll(db, sql: "SELECT memory_id, revision, draft_json, actor, changed_at, body_purged_at, revision_json FROM memory_revisions") {
            let value: MemoryRevision = try decode(row["revision_json"] as String)
            let draft: MemoryDraft? = try (row["draft_json"] as String?).map { try decode($0) }
            guard id(value.memoryID) == (row["memory_id"] as String), value.revision == (row["revision"] as Int), value.revision > 0,
                  value.draft == draft, value.actor == (row["actor"] as String), !value.actor.isEmpty, memoryTimestampMatches(value.changedAt, row["changed_at"] as Double?),
                  optionalMemoryTimestampMatches(value.bodyPurgedAt, row["body_purged_at"] as Double?) else { throw MiraError(.storage, "The memory revision contents are inconsistent.") }
            if let draft { try draft.validate() }
            if let draft {
                guard let parent = try Row.fetchOne(db, sql: "SELECT scope_json, subject FROM memories WHERE id = ?", arguments: [row["memory_id"] as String]),
                      draft.scope == (try decode(parent["scope_json"] as String) as MemoryScope),
                      draft.subject.rawValue == (parent["subject"] as String) else { throw MiraError(.storage, "The memory revision scope or subject is inconsistent.") }
            }
        }
        for row in try Row.fetchAll(db, sql: "SELECT id, replacement_id, previous_id, state, created_at, replacement_json FROM memory_replacements") {
            let value: MemoryReplacement = try decode(row["replacement_json"] as String)
            guard uuidString(value.id) == (row["id"] as String), id(value.replacementID) == (row["replacement_id"] as String), id(value.previousID) == (row["previous_id"] as String),
                  value.state.rawValue == (row["state"] as String), memoryTimestampMatches(value.createdAt, row["created_at"] as Double?) else { throw MiraError(.storage, "The memory replacement contents are inconsistent.") }
        }
        for row in try Row.fetchAll(db, sql: "SELECT operation_id, payload_hash, memory_id, disposition, created_at, receipt_json FROM memory_operation_receipts") {
            let receipt: StoredMemoryReceipt = try decode(row["receipt_json"] as String)
            guard UUID(uuidString: row["operation_id"] as String) != nil, receipt.memoryID == MemoryID(try uuid(row["memory_id"] as String)), receipt.disposition.rawValue == (row["disposition"] as String), !(row["payload_hash"] as String).isEmpty, row["created_at"] as Double > 0 else { throw MiraError(.storage, "The memory operation receipt is invalid.") }
        }
        for row in try Row.fetchAll(db, sql: "SELECT source_kind, source_id, suppressed_at, reason, suppression_json FROM memory_source_suppressions") {
            guard let sourceKind = MemoryEvidenceKind(rawValue: row["source_kind"] as String), let sourceID = UUID(uuidString: row["source_id"] as String), (row["suppressed_at"] as Double) > 0, !(row["reason"] as String).isEmpty else { throw MiraError(.storage, "The memory suppression record is invalid.") }
            let payload: StoredMemorySuppression = try decode(row["suppression_json"] as String)
            guard payload.sourceKind == sourceKind, payload.sourceID == sourceID, payload.reason == (row["reason"] as String) else { throw MiraError(.storage, "The memory suppression record is inconsistent.") }
        }
        for row in try Row.fetchAll(db, sql: "SELECT execution_id, memory_id, revision, usage_kind, created_at, usage_json FROM memory_usages") {
            let usage: MemoryUsage = try decode(row["usage_json"] as String)
            _ = try executionIDValue(row["execution_id"] as String)
            guard id(usage.memoryID) == (row["memory_id"] as String), usage.revision == (row["revision"] as Int), usage.revision > 0, usage.memoryID == MemoryID(try uuid(row["memory_id"] as String)), MemoryUsageKind(rawValue: row["usage_kind"] as String) != nil, try Int.fetchOne(db, sql: "SELECT 1 FROM memory_revisions WHERE memory_id = ? AND revision = ?", arguments: [row["memory_id"] as String, row["revision"] as Int]) != nil, (row["created_at"] as Double) > 0 else { throw MiraError(.storage, "The memory usage record is invalid.") }
        }
        for row in try Row.fetchAll(db, sql: "SELECT execution_id, source_execution_id FROM execution_history_dependencies") {
            let childID = try executionIDValue(row["execution_id"] as String)
            let sourceID = try executionIDValue(row["source_execution_id"] as String)
            guard childID != sourceID,
                  let child = try Row.fetchOne(db, sql: "SELECT conversation_id, trigger_message_id FROM executions WHERE id = ?", arguments: [id(childID)]),
                  let source = try Row.fetchOne(db, sql: "SELECT conversation_id, trigger_message_id FROM executions WHERE id = ?", arguments: [id(sourceID)]),
                  (child["conversation_id"] as String) == (source["conversation_id"] as String),
                  let childTrigger = try Row.fetchOne(db, sql: "SELECT conversation_id, sequence FROM messages WHERE id = ?", arguments: [child["trigger_message_id"] as String]),
                  let sourceTrigger = try Row.fetchOne(db, sql: "SELECT conversation_id, sequence FROM messages WHERE id = ?", arguments: [source["trigger_message_id"] as String]),
                  (childTrigger["conversation_id"] as String) == (child["conversation_id"] as String),
                  (sourceTrigger["conversation_id"] as String) == (source["conversation_id"] as String),
                  (sourceTrigger["sequence"] as Int) < (childTrigger["sequence"] as Int) else {
                throw MiraError(.storage, "The execution history dependency is invalid.")
            }
        }
    }

    private static func memoryAssertionHash(_ value: String) -> String {
        let normalized = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func suppressionRank(_ value: String) -> Int {
        switch value { case "removed": return 1; case "rejected": return 2; case "forgotten": return 3; default: return 0 }
    }
    private static func uuidString(_ value: UUID) -> String { value.uuidString.lowercased() }
}

private extension Optional where Wrapped == UUID {
    func unwrap(or error: Error) throws -> UUID { guard let value = self else { throw error }; return value }
}
