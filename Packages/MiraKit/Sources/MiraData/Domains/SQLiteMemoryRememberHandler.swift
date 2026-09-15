import Foundation
import GRDB
import MiraCore

/// The memory remember command is executed by SQLiteBusinessEffects inside its
/// existing domain/receipt/outbox transaction. It never opens a second transaction
/// or reads session tables.
public struct SQLiteMemoryRememberHandler: SQLiteBusinessCommandHandler, SQLiteBusinessAuthorizationValidator {
    public let namespace = "memory.remember"
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    public func businessKey(for effect: AgentResolvedEffect) throws -> String {
        let proposal = try parsed(effect)
        return try SQLiteMemoryStore.assertionKey(
            draft: proposal.draft,
            source: .userMessage(effect.context.evidence.reference)
        )
    }

    public func validate(effect: AgentResolvedEffect, isReplay: Bool, in db: Database) throws {
        try SQLiteAgentModelSettings.validateFrozenIdentity(effect.context.route, in: db)
        try SQLiteWorkspaceStore.validatePolicy(effect.context.evidence.workspaceID,
                                               connectionID: effect.context.route.connectionID, in: db)
        if effect.proposal.effect == .read {
            try validateRead(effect: effect, in: db)
            return
        }
        let proposal = try parsed(effect)
        guard effect.proposal.plan.sources.isEmpty, effect.proposal.plan.targets.isEmpty else {
            throw unauthorized
        }
        let policy = try SQLiteMemoryStore.currentCapturePolicy(in: db)
        if policy.mode != .manualOnly && !proposal.hasExplicitIntent {
            throw unauthorized
        }
        let source = MemoryEvidenceSource.userMessage(effect.context.evidence.reference)
        if proposal.isDirectIntent, try SQLiteMemoryStore.suppressedMemorySource(source, in: db) {
            throw unauthorized
        }
        _ = isReplay
    }

    private func validateRead(effect: AgentResolvedEffect, in db: Database) throws {
        guard effect.proposal.businessNamespace == nil,
              effect.proposal.descriptor.revision == 1,
              effect.proposal.plan.targets.isEmpty,
              effect.proposal.descriptor.outputSchema == MemoryTools.searchResultSchema ||
                  effect.proposal.descriptor.outputSchema == MemoryTools.getResultSchema else {
            throw unauthorized
        }
        let definition = effect.proposal.descriptor.definition
        let isSearch = definition == MemoryTools.searchDefinition
        let isGet = definition == MemoryTools.getDefinition
        guard isSearch || isGet else { throw unauthorized }
        _ = try ToolSchemaValidator.decode(try effect.proposal.plan.input.jsonString(),
                                            schema: effect.proposal.descriptor.outputSchema)
        guard effect.proposal.plan.sources.count <= 8_192,
              Set(effect.proposal.plan.sources).count == effect.proposal.plan.sources.count else {
            throw unauthorized
        }
        let context = effect.context
        let request = AgentContextRequest(sessionID: context.evidence.reference.sessionID, executionID: context.executionID,
            workspaceID: context.evidence.workspaceID, userText: context.evidence.text,
            authorizationEpoch: context.evidence.sessionAuthorizationEpoch, destination: .model(context.route))
        for source in effect.proposal.plan.sources {
            guard case .domain(let namespace, let id, let revision) = source,
                  namespace == "memories", revision > 0 else { throw unauthorized }
            let memory = try SQLiteMemoryStore.recall(.init(id), request: request,
                                                      at: now(), in: db)
            guard memory.revision == revision else { throw unauthorized }
        }
        if isGet { guard effect.proposal.plan.sources.count == 1 else { throw unauthorized } }
    }

    public func apply(effect: AgentResolvedEffect, in db: Database) throws -> JSONValue {
        try validate(effect: effect, isReplay: false, in: db)
        let proposal = try parsed(effect)
        let date = now()
        guard date.timeIntervalSince1970.isFinite else { throw invalidInput }
        let receipt = try SQLiteMemoryStore.createMemoryInTransaction(
            draft: proposal.draft,
            source: .userMessage(evidence: effect.context.evidence, excerpt: proposal.quote),
            operationID: effect.context.invocationID,
            replacing: nil,
            expectedRevision: nil,
            at: date,
            in: db
        )
        return MemoryTools.result(receipt)
    }

    private func parsed(_ effect: AgentResolvedEffect) throws -> MemoryRememberProposal {
        guard effect.proposal.effect == .localWrite,
              effect.proposal.businessNamespace == namespace,
              effect.proposal.descriptor.revision == 1,
              effect.proposal.descriptor.definition == MemoryTools.rememberDefinition,
              effect.proposal.descriptor.outputSchema == MemoryTools.rememberResultSchema,
              effect.proposal.plan.sources.isEmpty,
              effect.proposal.plan.targets.isEmpty else {
            throw unauthorized
        }
        return try MemoryTools.parsedProposal(arguments: effect.proposal.plan.input,
                                               evidence: effect.context.evidence)
    }

    private var unauthorized: MiraError {
        MiraError(.unauthorized, "The memory save is no longer authorized.")
    }

    private var invalidInput: MiraError {
        MiraError(.invalidInput, "The memory save date is invalid.")
    }
}
