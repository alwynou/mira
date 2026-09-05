import Foundation
import GRDB
import MiraCore

extension SQLiteMiraStore {
    public func memoryCitation(_ reference: MemoryCitationReference, executionID: ExecutionID, conversationID: ConversationID) throws -> MemoryCitationDetail {
        try safely { try pool.read { db in
            guard reference.revision > 0,
                  let execution = try Row.fetchOne(db, sql: "SELECT conversation_id, body_purged_at FROM executions WHERE id = ?", arguments: [executionIDString(executionID)]),
                  execution["conversation_id"] as String == conversationIDString(conversationID),
                  execution["body_purged_at"] as Double? == nil,
                  try Int.fetchOne(db, sql: "SELECT 1 FROM memory_usages WHERE execution_id = ? AND memory_id = ? AND revision = ?", arguments: [executionIDString(executionID), memoryIDString(reference.memoryID), reference.revision]) != nil else {
                throw MiraError(.notFound, "This memory reference was not used in this reply or is no longer available.")
            }
            let workspaceID = try workspaceIDForConversation(conversationID, in: db)
            let memory = try requireMemory(reference.memoryID, workspaceID: workspaceID, in: db)
            guard memory.forgottenAt == nil,
                  let row = try Row.fetchOne(db, sql: "SELECT memory_id, revision, draft_json, actor, changed_at, body_purged_at, revision_json FROM memory_revisions WHERE memory_id = ? AND revision = ?", arguments: [memoryIDString(reference.memoryID), reference.revision]) else {
                throw MiraError(.notFound, "This memory reference was not used in this reply or is no longer available.")
            }
            let revision = try memoryRevision(row)
            guard revision.bodyPurgedAt == nil, let draft = revision.draft, draft.scope == memory.scope, draft.subject == memory.subject else {
                throw MiraError(.notFound, "The referenced memory revision is no longer available.")
            }
            let evidence = try Row.fetchAll(db, sql: "SELECT id, memory_id, source_kind, source_id, source_revision, conversation_id, excerpt, source_hash, speaker_role, created_at, body_purged_at, evidence_json FROM memory_evidence WHERE memory_id = ? ORDER BY created_at, id LIMIT 200", arguments: [memoryIDString(reference.memoryID)]).map { try memoryEvidence($0) }
            return MemoryCitationDetail(memory: memory, revision: revision, evidence: evidence)
        }}
    }
}
