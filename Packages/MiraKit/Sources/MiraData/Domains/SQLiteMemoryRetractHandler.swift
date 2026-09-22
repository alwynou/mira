import Foundation
import GRDB
import MiraCore

/// Validates and commits the dedicated exact-target memory withdrawal command.
public struct SQLiteMemoryRetractHandler: SQLiteBusinessCommandHandler, SQLiteBusinessAuthorizationValidator {
    public let namespace = "memory.retract"
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    public func businessKey(for effect: AgentResolvedEffect) throws -> String {
        let proposal = try parsed(effect)
        struct Identity: Encodable { let target: MemoryUsage; let quote: String; let source: MemoryEvidenceSource }
        return try SQLiteMemoryStore.digest(SQLiteMemoryStore.encode(Identity(
            target: proposal.target, quote: proposal.quote,
            source: .userMessage(effect.context.evidence.reference))))
    }

    public func validate(effect: AgentResolvedEffect, isReplay: Bool, in db: Database) throws {
        try SQLiteAgentModelSettings.validateFrozenIdentity(effect.context.route, in: db)
        try SQLiteWorkspaceStore.validatePolicy(effect.context.evidence.workspaceID,
                                                connectionID: effect.context.route.connectionID, in: db)
        let proposal = try parsed(effect)
        let currentSource = MemoryEvidenceSource.userMessage(effect.context.evidence.reference)
        if isReplay {
            if try SQLiteMemoryStore.suppressedMemorySource(currentSource, in: db) { throw SQLiteMemoryStore.unauthorized }
        } else if try SQLiteMemoryStore.memoryCaptureSuppressed(currentSource, in: db) {
            throw SQLiteMemoryStore.unauthorized
        }
        let reference = AgentSourceReference.domain(namespace: "memories", id: proposal.target.memoryID.rawValue,
                                                    revision: proposal.target.revision)
        guard effect.proposal.plan.sources == [reference], effect.proposal.plan.targets == [reference] else { throw SQLiteMemoryStore.unauthorized }
        let context = effect.context
        let request = AgentContextRequest(sessionID: context.evidence.reference.sessionID,
            executionID: context.executionID, workspaceID: context.evidence.workspaceID,
            userText: context.evidence.text, authorizationEpoch: context.evidence.sessionAuthorizationEpoch,
            destination: .model(context.route))
        if isReplay {
            try SQLiteMemoryStore.validateMemoryContextSources(effect.proposal.plan.sources, for: request, at: now(), in: db)
        } else {
            let memory = try SQLiteMemoryStore.recall(proposal.target.memoryID, request: request, at: now(), in: db)
            guard memory.revision == proposal.target.revision, memory.state == .active, memory.isCurrent,
                  memory.draft != nil else { throw SQLiteMemoryStore.conflict }
            for evidence in try SQLiteMemoryStore.evidence(memory.id, in: db) {
                guard try !SQLiteMemoryStore.suppressedMemorySource(evidence.source, in: db) else { throw SQLiteMemoryStore.unauthorized }
            }
        }
    }

    public func apply(effect: AgentResolvedEffect, in db: Database) throws -> JSONValue {
        try validate(effect: effect, isReplay: false, in: db)
        let proposal = try parsed(effect)
        let context = effect.context
        let request = AgentContextRequest(sessionID: context.evidence.reference.sessionID,
            executionID: context.executionID, workspaceID: context.evidence.workspaceID,
            userText: context.evidence.text, authorizationEpoch: context.evidence.sessionAuthorizationEpoch,
            destination: .model(context.route))
        let receipt = try SQLiteMemoryStore.retractMemoryInTransaction(
            target: proposal.target,
            source: .userMessage(evidence: context.evidence, excerpt: proposal.quote),
            operationID: context.invocationID, request: request, at: now(), in: db)
        return MemoryTools.retractionResult(receipt)
    }

    private func parsed(_ effect: AgentResolvedEffect) throws -> MemoryRetractionProposal {
        guard effect.proposal.effect == .localWrite,
              effect.proposal.businessNamespace == namespace,
              effect.proposal.descriptor.revision == 1,
              effect.proposal.descriptor.definition == MemoryTools.retractDefinition,
              effect.proposal.descriptor.outputSchema == MemoryTools.retractResultSchema else { throw SQLiteMemoryStore.unauthorized }
        return try MemoryTools.parsedRetraction(arguments: effect.proposal.plan.input, evidence: effect.context.evidence)
    }
}
