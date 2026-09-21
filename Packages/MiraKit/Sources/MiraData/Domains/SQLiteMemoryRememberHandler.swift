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
        let assertion = try SQLiteMemoryStore.assertionKey(
            draft: proposal.draft,
            source: .userMessage(effect.context.evidence.reference)
        )
        struct Identity: Encodable { let assertion: String; let targets: [MemoryUsage]; let replacement: MemoryUsage? }
        return try SQLiteMemoryStore.digest(SQLiteMemoryStore.encode(
            Identity(assertion: assertion, targets: proposal.enrichmentTargets, replacement: proposal.replacementTarget)))
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
        let source = MemoryEvidenceSource.userMessage(effect.context.evidence.reference)
        if try SQLiteMemoryStore.suppressedMemorySource(source, in: db) {
            throw unauthorized
        }
        let targets = proposal.replacementTarget.map { [$0] } ?? proposal.enrichmentTargets
        if !targets.isEmpty {
            let context = effect.context
            let request = AgentContextRequest(sessionID: context.evidence.reference.sessionID, executionID: context.executionID,
                workspaceID: context.evidence.workspaceID, userText: context.evidence.text,
                authorizationEpoch: context.evidence.sessionAuthorizationEpoch, destination: .model(context.route))
            if isReplay {
                try SQLiteMemoryStore.validateMemoryContextSources(effect.proposal.plan.sources, for: request, at: now(), in: db)
            } else {
                let memories = try targets.map { target in
                    let memory = try SQLiteMemoryStore.recall(target.memoryID, request: request, at: now(), in: db)
                    guard memory.revision == target.revision else { throw SQLiteMemoryStore.conflict }
                    for evidence in try SQLiteMemoryStore.evidence(memory.id, in: db) {
                        guard try !SQLiteMemoryStore.suppressedMemorySource(evidence.source, in: db) else { throw unauthorized }
                    }
                    return memory
                }
                if proposal.replacementTarget != nil {
                    guard let existing = memories.first?.draft,
                          existing.scope == proposal.draft.scope,
                          existing.subject == proposal.draft.subject,
                          existing.kind == proposal.draft.kind,
                          existing.sensitivity == proposal.draft.sensitivity,
                          existing.allowsRemoteUse == proposal.draft.allowsRemoteUse,
                          existing.allowedConnectionIDs == proposal.draft.allowedConnectionIDs else { throw unauthorized }
                } else {
                    _ = try SQLiteMemoryStore.enrichmentDraft(proposal.draft, targets: memories, at: now())
                }
            }
        }
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
        if let target = proposal.replacementTarget {
            let receipt = try SQLiteMemoryStore.createMemoryInTransaction(
                draft: proposal.draft,
                source: .userMessage(evidence: effect.context.evidence, excerpt: proposal.quote),
                operationID: effect.context.invocationID,
                replacing: target.memoryID,
                expectedRevision: target.revision,
                at: date,
                in: db)
            return MemoryTools.result(receipt)
        }
        if !proposal.enrichmentTargets.isEmpty {
            let receipt = try SQLiteMemoryStore.enrichRememberedMemory(
                draft: proposal.draft, source: .userMessage(evidence: effect.context.evidence, excerpt: proposal.quote),
                targets: proposal.enrichmentTargets, operationID: effect.context.invocationID, at: date, in: db)
            return MemoryTools.result(receipt)
        }
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
              effect.proposal.descriptor.revision == 3,
              effect.proposal.descriptor.definition == MemoryTools.rememberDefinition,
              effect.proposal.descriptor.outputSchema == MemoryTools.rememberResultSchema else {
            throw unauthorized
        }
        let proposal = try MemoryTools.parsedProposal(arguments: effect.proposal.plan.input,
                                                     evidence: effect.context.evidence)
        let targets = proposal.replacementTarget.map { [$0] } ?? proposal.enrichmentTargets
        let references = targets.map {
            AgentSourceReference.domain(namespace: "memories", id: $0.memoryID.rawValue, revision: $0.revision)
        }
        guard effect.proposal.plan.sources == references, effect.proposal.plan.targets == references else { throw unauthorized }
        return proposal
    }

    private var unauthorized: MiraError {
        MiraError(.unauthorized, "The memory save is no longer authorized.")
    }

    private var invalidInput: MiraError {
        MiraError(.invalidInput, "The memory save date is invalid.")
    }
}
