import Foundation
import GRDB
import MiraCore

/// The memory domain's maintenance primitive. It owns only business rows; the
/// library coordinator owns journal invalidation and the final completion fact.
extension SQLiteMemoryStore: MemoryPrivacyStore {
    private static var maximumForgetRevisions: Int { 8_192 }

    public static var maintenanceValidator: SQLiteLibraryMaintenanceValidator {
        .init(identity: .init(namespace: "memory.forget", revision: 1)) { request, db in
            let target = try target(from: request)
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM memory_records WHERE id = ?", arguments: [key(target.id)])
            else {
                throw unauthorized
            }
            let memory = try record(row)
            guard memory.revision == target.revision, memory.forgottenAt == nil else { throw unauthorized }
            guard target.revision <= maximumForgetRevisions else { throw limit }
        }
    }

    public func memoryForgetScope(operation: AgentLibraryMaintenanceOperation) async throws -> MemoryForgetScope {
        try await owner.maintain(operation) { db in
            let target = try Self.target(from: operation.request)
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM memory_records WHERE id = ?", arguments: [Self.key(target.id)])
            else {
                throw Self.unavailable
            }
            let memory = try Self.record(row)
            let purge = try Row.fetchOne(
                db, sql: "SELECT * FROM memory_purges WHERE operation_id = ?",
                arguments: [Self.key(operation.request.id)])
            if let purge {
                let receipt: MemoryForgetReceipt = try Self.decode(purge["json"])
                guard receipt.memoryID == target.id,
                    purge["workspace_id"] as String? == memory.scope.workspaceID.map(Self.key),
                    purge["expected_revision"] as Int == target.revision
                else { throw Self.conflict }
            } else {
                guard memory.revision == target.revision, memory.forgottenAt == nil else { throw Self.conflict }
            }

            guard target.revision <= Self.maximumForgetRevisions else { throw Self.limit }
            let revisionRows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM memory_revisions WHERE memory_id = ? AND revision <= ? ORDER BY revision LIMIT ?",
                arguments: [Self.key(target.id), target.revision, Self.maximumForgetRevisions + 1])
            guard !revisionRows.isEmpty, revisionRows.count <= Self.maximumForgetRevisions else { throw Self.limit }
            var expectedRevision = 1
            var roots = Set<AgentSourceReference>()
            for row in revisionRows {
                let revision = try Self.revision(row, memoryID: target.id)
                guard revision.revision == expectedRevision else { throw Self.corrupt }
                roots.insert(.domain(namespace: "memories", id: target.id.rawValue, revision: revision.revision))
                expectedRevision += 1
            }
            guard expectedRevision == target.revision + 1 else { throw Self.corrupt }
            for evidence in try Self.evidence(target.id, in: db) {
                if case .userMessage(let reference) = evidence.source {
                    try reference.validate()
                    roots.insert(
                        .sessionExecution(sessionID: reference.sessionID, executionID: reference.originalExecutionID))
                }
            }
            let result = MemoryForgetScope(
                memoryID: target.id, workspaceID: memory.scope.workspaceID,
                expectedRevision: target.revision, roots: roots.sorted(by: Self.rootOrder))
            try result.validate(for: operation)
            return result
        }
    }

    public func purgeMemoryForget(
        _ scope: MemoryForgetScope,
        operation: AgentLibraryMaintenanceOperation
    ) async throws {
        try scope.validate(for: operation)
        let target = try Self.target(from: operation.request)
        guard target.id == scope.memoryID, target.revision == scope.expectedRevision else { throw Self.conflict }
        _ = try await purgeMemory(
            scope.memoryID, workspaceID: scope.workspaceID,
            expectedRevision: scope.expectedRevision,
            maintenance: operation, at: operation.request.requestedAt)
    }

    public func verifyMemoryForgotten(
        _ scope: MemoryForgetScope,
        operation: AgentLibraryMaintenanceOperation
    ) async throws {
        try scope.validate(for: operation)
        let target = try Self.target(from: operation.request)
        guard target.id == scope.memoryID, target.revision == scope.expectedRevision else { throw Self.conflict }
        try await owner.maintain(operation) { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM memory_records WHERE id = ?", arguments: [Self.key(target.id)])
            else {
                throw Self.unavailable
            }
            let memory = try Self.record(row)
            guard memory.scope.workspaceID == scope.workspaceID,
                target.revision <= Self.maximumForgetRevisions,
                memory.revision == target.revision + 1,
                memory.forgottenAt == operation.request.requestedAt,
                memory.draft == nil,
                (row["draft_json"] as Data?) == nil
            else { throw Self.conflict }

            let revisions = try Row.fetchAll(
                db, sql: "SELECT * FROM memory_revisions WHERE memory_id = ? ORDER BY revision LIMIT ?",
                arguments: [Self.key(target.id), Self.maximumForgetRevisions + 2])
            guard !revisions.isEmpty, revisions.count <= Self.maximumForgetRevisions + 1 else { throw Self.limit }
            var expectedRevision = 1
            for revisionRow in revisions {
                let revision = try Self.revision(revisionRow, memoryID: target.id)
                guard revision.revision == expectedRevision,
                    revision.draft == nil, revision.bodyPurgedAt == memory.forgottenAt
                else { throw Self.conflict }
                expectedRevision += 1
            }
            guard expectedRevision == target.revision + 2 else { throw Self.corrupt }

            let evidence = try Self.evidence(target.id, in: db)
            for value in evidence {
                guard value.excerpt == nil, value.sourceHash == nil, value.bodyPurgedAt != nil,
                    let sourceRow = try Row.fetchOne(
                        db, sql: "SELECT * FROM memory_sources WHERE source_key = ?",
                        arguments: [try Self.sourceKey(value.source)]),
                    try Self.sourceIdentity(sourceRow) == value.source,
                    sourceRow["suppression"] as Int == 3,
                    (sourceRow["body_hash"] as String?) == nil
                else { throw Self.conflict }
            }

            guard
                try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_embeddings WHERE memory_id=?", arguments: [Self.key(target.id)]) == 0,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_embedding_jobs WHERE memory_id=?", arguments: [Self.key(target.id)]) == 0,
                try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM memory_search WHERE memory_id = ?",
                    arguments: [Self.key(target.id)]) == 0,
                try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM memory_assertions WHERE memory_id = ?",
                    arguments: [Self.key(target.id)]) == 0,
                try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM memory_extraction_aspects WHERE memory_id = ?",
                    arguments: [Self.key(target.id)]) == 0
            else { throw Self.conflict }

            let operationRows = try Row.fetchAll(
                db,
                sql:
                    "SELECT o.request_hash, o.receipt_json FROM memory_operations o JOIN memory_operation_dependencies d ON d.operation_id = o.operation_id WHERE d.memory_id = ? LIMIT ?",
                arguments: [Self.key(target.id), Self.maximumForgetRevisions + 1])
            guard operationRows.count <= Self.maximumForgetRevisions else { throw Self.limit }
            for operationRow in operationRows {
                guard (operationRow["request_hash"] as String?) == nil,
                    (operationRow["receipt_json"] as Data?) == nil
                else { throw Self.conflict }
            }

            for value in evidence {
                let sourceKey = try Self.sourceKey(value.source)
                let jobs = try Row.fetchAll(
                    db, sql: "SELECT j.* FROM memory_extraction_jobs j JOIN memory_extraction_sources s ON s.job_id=j.id WHERE s.source_key = ? LIMIT ?",
                    arguments: [sourceKey, Self.maximumForgetRevisions + 1])
                guard jobs.count <= Self.maximumForgetRevisions else { throw Self.limit }
                for jobRow in jobs {
                    let job = try SQLiteMemoryExtractionStore.job(jobRow)
                    if case .userMessage(let reference) = value.source {
                        guard job.origin.source == reference || job.turns.contains(where: { $0.source == reference }),
                            job.workspaceID == value.sourceWorkspaceID
                        else { throw Self.corrupt }
                    }
                    guard job.state == .suppressed, job.error == nil else { throw Self.conflict }
                    let attempts = try Row.fetchAll(
                        db, sql: "SELECT * FROM memory_extraction_attempts WHERE job_id = ? ORDER BY ordinal LIMIT ?",
                        arguments: [Self.key(job.id), 101])
                    guard attempts.count <= 100 else { throw Self.limit }
                    for attemptRow in attempts {
                        let attempt = try SQLiteMemoryExtractionStore.attempt(attemptRow)
                        guard !attempt.status.isLive, attempt.request == nil, attempt.output == nil,
                            attempt.decisions == nil, attempt.error == nil,
                            attempt.bodyPurgedAt != nil
                        else { throw Self.conflict }
                    }
                }
            }

            guard
                let purgeRow = try Row.fetchOne(
                    db, sql: "SELECT * FROM memory_purges WHERE operation_id = ?",
                    arguments: [Self.key(operation.request.id)])
            else { throw Self.conflict }
            let receipt: MemoryForgetReceipt = try Self.decode(purgeRow["json"])
            guard purgeRow["memory_id"] as String? == Self.key(target.id),
                receipt.memoryID == target.id,
                purgeRow["workspace_id"] as String? == memory.scope.workspaceID.map(Self.key),
                purgeRow["expected_revision"] as Int == target.revision,
                receipt.suppressedSources == evidence.map(\.source)
            else { throw Self.conflict }
        }
    }

    private static func target(from request: AgentLibraryMaintenanceRequest) throws
        -> (id: MemoryID, revision: Int)
    {
        guard request.namespace == "memory.forget", request.revision == 1,
            case .sources(let sources) = request.scope, sources.count == 1,
            case .domain(let namespace, let id, let revision) = sources[0],
            namespace == "memories", revision > 0, revision < Int.max
        else { throw unauthorized }
        return (MemoryID(id), revision)
    }

    private static func rootOrder(_ lhs: AgentSourceReference, _ rhs: AgentSourceReference) -> Bool {
        switch (lhs, rhs) {
        case (.domain(let ln, let li, let lr), .domain(let rn, let ri, let rr)):
            if ln != rn { return ln < rn }
            if li != ri { return li.uuidString < ri.uuidString }
            return lr < rr
        case (.domain, .sessionExecution): return true
        case (.sessionExecution, .domain): return false
        case (.sessionExecution(let ls, let le), .sessionExecution(let rs, let re)):
            if ls != rs { return ls.rawValue.uuidString < rs.rawValue.uuidString }
            return le.rawValue.uuidString < re.rawValue.uuidString
        }
    }
}
