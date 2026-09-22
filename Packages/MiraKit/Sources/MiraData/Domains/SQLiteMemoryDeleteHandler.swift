import Foundation
import GRDB
import MiraCore

/// Queues an exact memory deletion request. The library maintenance owner later
/// performs the irreversible purge under its own admission boundary.
public struct SQLiteMemoryDeleteHandler: SQLiteBusinessCommandHandler, SQLiteBusinessAuthorizationValidator {
    public let namespace = "memory.delete"
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    public func businessKey(for effect: AgentResolvedEffect) throws -> String {
        let proposal = try parsed(effect)
        struct Identity: Encodable { let target: MemoryUsage; let source: SessionEvidenceReference }
        return SQLiteMemoryStore.digest(try SQLiteMemoryStore.encode(.init(target: proposal.target, source: effect.context.evidence.reference) as Identity))
    }

    public func validate(effect: AgentResolvedEffect, isReplay: Bool, in db: Database) throws {
        try SQLiteAgentModelSettings.validateFrozenIdentity(effect.context.route, in: db)
        try SQLiteWorkspaceStore.validatePolicy(effect.context.evidence.workspaceID,
                                                connectionID: effect.context.route.connectionID, in: db)
        let proposal = try parsed(effect)
        let source = MemoryEvidenceSource.userMessage(effect.context.evidence.reference)
        if isReplay {
            if try SQLiteMemoryStore.suppressedMemorySource(source, in: db) { throw SQLiteMemoryStore.unauthorized }
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM memory_deletion_requests WHERE id = ?",
                                             arguments: [SQLiteMemoryStore.key(effect.context.invocationID)]) else { throw SQLiteMemoryStore.conflict }
            let stored = try SQLiteMemoryStore.deletionRequest(row, in: db)
            let expected = try request(for: effect)
            guard SQLiteMemoryStore.sameDeletionTarget(stored, expected) else { throw SQLiteMemoryStore.conflict }
        } else {
            if try SQLiteMemoryStore.memoryCaptureSuppressed(source, in: db) { throw SQLiteMemoryStore.unauthorized }
            let context = effect.context
            let request = AgentContextRequest(sessionID: context.evidence.reference.sessionID,
                                              executionID: context.executionID,
                                              workspaceID: context.evidence.workspaceID,
                                              userText: context.evidence.text,
                                              authorizationEpoch: context.evidence.sessionAuthorizationEpoch,
                                              destination: .model(context.route))
            let memory = try SQLiteMemoryStore.recall(proposal.target.memoryID,
                                                      request: request, at: now(), in: db)
            guard memory.revision == proposal.target.revision, memory.state == .active,
                  memory.isCurrent, memory.draft != nil else { throw SQLiteMemoryStore.conflict }
        }
        let reference = AgentSourceReference.domain(namespace: "memories", id: proposal.target.memoryID.rawValue,
                                                    revision: proposal.target.revision)
        guard effect.proposal.plan.sources == [reference], effect.proposal.plan.targets == [reference] else {
            throw SQLiteMemoryStore.unauthorized
        }
        _ = try request(for: effect)
    }

    public func apply(effect: AgentResolvedEffect, in db: Database) throws -> JSONValue {
        try validate(effect: effect, isReplay: false, in: db)
        let request = try self.request(for: effect)
        let queued = try SQLiteMemoryStore.enqueueDeletionInTransaction(request, in: db)
        return MemoryTools.deletionResult(queued)
    }

    private func request(for effect: AgentResolvedEffect) throws -> MemoryDeletionRequest {
        let proposal = try parsed(effect)
        let request = MemoryDeletionRequest(id: effect.context.invocationID, target: proposal.target,
                                            source: effect.context.evidence.reference,
                                            executionID: effect.context.executionID,
                                            workspaceID: effect.context.evidence.workspaceID, requestedAt: now())
        try request.validate()
        return request
    }

    private func parsed(_ effect: AgentResolvedEffect) throws -> MemoryDeletionProposal {
        guard effect.proposal.effect == .localWrite,
              effect.proposal.businessNamespace == namespace,
              effect.proposal.descriptor.revision == 1,
              effect.proposal.descriptor.definition == MemoryTools.deleteDefinition,
              effect.proposal.descriptor.outputSchema == MemoryTools.deleteResultSchema else {
            throw SQLiteMemoryStore.unauthorized
        }
        return try MemoryTools.parsedDeletion(arguments: effect.proposal.plan.input, evidence: effect.context.evidence)
    }
}
