import Foundation
import GRDB
import MiraCore

/// Atomic, explicit withdrawal of the current assertion. Retraction archives the
/// same record and leaves its revisions available for local history inspection.
extension SQLiteMemoryStore {
    static func retractMemoryInTransaction(
        target: MemoryUsage, source: MemoryWriteSource, operationID: UUID,
        request: AgentContextRequest, at: Date, in db: Database,
        captureWasValidatedInTransaction: Bool = false
    ) throws -> MemoryWriteReceipt {
        try date(at)
        guard target.revision > 0, target.revision < Int.max else { throw invalid }
        try validateDestination(request, in: db)
        let current = try read(target.memoryID, workspaceID: request.workspaceID, in: db)
        guard let draft = current.draft else { throw unauthorized }
        let resolved = try resolve(source, draft: draft, in: db)
        do {
            try SQLiteWorkspaceStore.validatePolicy(
                resolved.workspaceID, connectionID: request.destination.modelRoute?.connectionID, in: db)
        } catch let error as MiraError where error.code == .notFound || error.code == .unauthorized {
            throw unauthorized
        }
        guard try !suppressedMemorySource(resolved.identity, in: db) else { throw unauthorized }
        struct Identity: Encodable { let target: MemoryUsage; let source: MemorySourceInput; let request: AgentContextRequest }
        let requestHash = try digest(encode(Identity(target: target, source: resolved.input, request: request)))
        if let prior = try operation(operationID, request: requestHash, in: db) {
            guard prior.memory.id == target.memoryID,
                  prior.memory.revision == current.revision,
                  prior.memory.retraction?.priorRevision == target.revision,
                  prior.memory.retraction?.revision == current.revision,
                  prior.disposition == .retracted else { throw conflict }
            let replayEvidence = try evidence(target.memoryID, in: db)
            guard replayEvidence.contains(where: {
                $0.source == resolved.identity && $0.retractionRevision == current.revision
            }) else { throw conflict }
            try validateMemoryContextSources(
                [.domain(namespace: "memories", id: target.memoryID.rawValue, revision: target.revision)],
                for: request, at: at, in: db)
            return prior
        }
        guard current.revision == target.revision, current.isCurrent else { throw conflict }
        try validateMemoryContextSources(
            [.domain(namespace: "memories", id: target.memoryID.rawValue, revision: target.revision)],
            for: request, at: at, in: db)
        _ = try recall(target.memoryID, request: request, at: at, in: db)
        // The batch reducer validates every incoming source under this same
        // writer transaction before any retraction. A second withdrawal may
        // share that source; its first withdrawal must not revoke the batch's
        // already validated action. Privacy and target checks still run above.
        if !captureWasValidatedInTransaction {
            guard try !memoryCaptureSuppressed(resolved.identity, in: db) else { throw unauthorized }
        }
        let priorEvidence = try evidence(target.memoryID, in: db)
        guard !priorEvidence.contains(where: { $0.source == resolved.identity }) else { throw conflict }
        try bindSource(resolved, in: db)

        var archived = try mutable(target.memoryID, workspaceID: request.workspaceID, expected: target.revision, in: db)
        let newRevision = archived.revision + 1
        archived.retraction = .init(priorRevision: target.revision, revision: newRevision, createdAt: at)
        archived.state = .archived
        archived.revision = newRevision
        archived.updatedAt = at
        try write(archived, insert: false, in: db)
        let withdrawal = MemoryEvidence(
            memoryID: archived.id, source: resolved.identity,
            sourceWorkspaceID: resolved.workspaceID, excerpt: resolved.excerpt, sourceHash: resolved.bodyHash,
            createdAt: at, retractionRevision: newRevision)
        try insertBoundedMemoryEvidence(withdrawal, in: db)
        let receipt = MemoryWriteReceipt(memory: archived, disposition: .retracted)
        try saveOperation(operationID, request: requestHash, receipt: receipt,
            dependencies: [archived.id], in: db)
        return receipt
    }
}
