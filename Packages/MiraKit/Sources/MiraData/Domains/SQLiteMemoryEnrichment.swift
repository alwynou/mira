import Foundation
import GRDB
import MiraCore

extension SQLiteMemoryStore {
    /// Foreground enrichment is part of the caller's business receipt transaction.
    /// Targets are explicit semantic decisions; the host owns revisions and policy.
    static func enrichRememberedMemory(
        draft: MemoryDraft, source: MemoryWriteSource, targets: [MemoryUsage],
        operationID: UUID, at: Date, in db: Database
    ) throws -> MemoryWriteReceipt {
        try draft.validate()
        try date(at)
        guard !targets.isEmpty, targets.count <= 6,
            Set(targets.map(\.memoryID)).count == targets.count,
            targets.allSatisfy({ $0.revision > 0 && $0.revision < Int.max })
        else { throw invalid }
        let resolved = try resolve(source, draft: draft, in: db)
        guard try !memoryCaptureSuppressed(resolved.identity, in: db) else { throw unauthorized }
        struct Identity: Encodable { let draftAndSource: String; let targets: [MemoryUsage] }
        let request = try digest(encode(Identity(
            draftAndSource: fingerprint(kind: "enrich", draft: draft, source: resolved.input), targets: targets)))
        if let prior = try operation(operationID, request: request, in: db) { return prior }

        let previous = try targets.map {
            try mutable($0.memoryID, workspaceID: draft.scope.workspaceID, expected: $0.revision, in: db)
        }
        let complete = try enrichmentDraft(draft, targets: previous, at: at)
        try bindSource(resolved, in: db)
        let assertion = try assertionKey(draft: complete, source: resolved.identity)
        // A different target set must not silently reuse an unrelated prior operation.
        guard try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_assertions WHERE assertion_key = ?",
            arguments: [assertion]) == 0 else { throw conflict }
        let memory = Memory(draft: complete, scope: complete.scope, subject: complete.subject,
            state: .active, createdAt: at, updatedAt: at)
        try write(memory, insert: true, in: db)
        for old in previous { try inheritMemoryEvidence(from: old.id, into: memory.id, in: db) }
        try insertBoundedMemoryEvidence(.init(memoryID: memory.id, source: resolved.identity,
            sourceWorkspaceID: resolved.workspaceID, excerpt: resolved.excerpt,
            sourceHash: resolved.bodyHash, createdAt: at), in: db)
        try db.execute(sql: "INSERT INTO memory_assertions(assertion_key, memory_id, source_key) VALUES (?, ?, ?)",
            arguments: [assertion, key(memory.id), try sourceKey(resolved.identity)])
        for var old in previous {
            try writeRelation(.init(replacementID: memory.id, previousID: old.id, state: .confirmed, createdAt: at), in: db)
            old.supersededBy = memory.id
            old.revision += 1
            old.updatedAt = at
            try write(old, insert: false, in: db)
        }
        let receipt = MemoryWriteReceipt(memory: memory, disposition: .created)
        try saveOperation(operationID, request: request, receipt: receipt,
            dependencies: [memory.id] + previous.map(\.id), in: db)
        return receipt
    }

    static func enrichmentDraft(_ draft: MemoryDraft, targets: [Memory], at: Date) throws -> MemoryDraft {
        guard let first = targets.first?.draft else { throw conflict }
        for memory in targets {
            guard memory.lifecycleStatus(at: at) == .active, let prior = memory.draft,
                prior.scope == draft.scope, prior.subject == draft.subject, prior.kind == draft.kind,
                prior.sensitivity == draft.sensitivity, prior.allowsRemoteUse == draft.allowsRemoteUse,
                prior.allowedConnectionIDs == draft.allowedConnectionIDs,
                prior.validFrom == first.validFrom, prior.validUntil == first.validUntil
            else { throw conflict }
        }
        var complete = draft
        complete.validFrom = first.validFrom
        complete.validUntil = first.validUntil
        try complete.validate()
        return complete
    }

    static func inheritMemoryEvidence(from previous: MemoryID, into current: MemoryID, in db: Database) throws {
        for item in try evidence(previous, in: db) {
            guard item.retractionRevision == nil else { continue }
            guard item.bodyPurgedAt == nil,
                  try !suppressedMemorySource(item.source, in: db) else { throw unauthorized }
            try insertBoundedMemoryEvidence(.init(memoryID: current, source: item.source,
                sourceWorkspaceID: item.sourceWorkspaceID, excerpt: item.excerpt,
                sourceHash: item.sourceHash, createdAt: item.createdAt), in: db)
        }
    }

    static func insertBoundedMemoryEvidence(_ value: MemoryEvidence, in db: Database) throws {
        let source = try sourceKey(value.source)
        if try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_evidence WHERE memory_id = ? AND source_key = ?",
            arguments: [key(value.memoryID), source]) == 1 { return }
        guard try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_evidence WHERE memory_id = ?",
            arguments: [key(value.memoryID)]) ?? 0 < 100 else { throw limit }
        try db.execute(sql: "INSERT INTO memory_evidence(id, memory_id, source_key, source_workspace_id, json) VALUES (?, ?, ?, ?, ?)",
            arguments: [key(value.id), key(value.memoryID), source, value.sourceWorkspaceID.map(key), try encode(value)])
    }

    static func memoryCaptureSuppressed(_ source: MemoryEvidenceSource, in db: Database) throws -> Bool {
        if try suppressedMemorySource(source, in: db) { return true }
        if try deletionCaptureSuppressed(source, in: db) { return true }
        return try Int.fetchOne(db, sql: """
            SELECT count(*) FROM memory_evidence e
            JOIN memory_records m ON m.id = e.memory_id
            WHERE e.source_key = ?
              AND json_extract(CAST(m.json AS TEXT), '$.retraction') IS NOT NULL
            """, arguments: [try sourceKey(source)]) ?? 0 > 0
    }
}
