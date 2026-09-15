import Foundation
import CryptoKit
import GRDB
import MiraCore

/// Task mutations and reminder desired state are part of the caller's receipt/outbox transaction.
/// This handler never queries session tables, schedules notifications, or starts another transaction.
public struct SQLiteTaskCommandHandler: SQLiteBusinessCommandHandler, SQLiteBusinessAuthorizationValidator {
    public let namespace = "tasks.change"
    private let now: @Sendable () -> Date
    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    public func businessKey(for effect: AgentResolvedEffect) throws -> String {
        let input = try arguments(effect)
        struct Identity: Encodable { let source: SessionEvidenceReference; let input: JSONValue }
        let bytes = try SessionCodec.encode(Identity(source: effect.context.evidence.reference, input: input))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public func validate(effect: AgentResolvedEffect, isReplay: Bool, in db: Database) throws {
        try SQLiteAgentModelSettings.validateFrozenIdentity(effect.context.route, in: db)
        try SQLiteWorkspaceStore.validatePolicy(effect.context.evidence.workspaceID,
                                               connectionID: effect.context.route.connectionID, in: db)
        try TaskEvidence(effect.context.evidence).validate()
        if effect.proposal.descriptor.definition.name == "task.list" {
            guard effect.proposal.effect == .read, effect.proposal.businessNamespace == nil,
                  effect.proposal.plan.targets.isEmpty else { throw SQLiteTaskStore.taskUnauthorized }
            for source in effect.proposal.plan.sources {
                guard case .domain(let namespace, let id, let revision) = source, namespace == "tasks" else {
                    throw SQLiteTaskStore.taskUnauthorized
                }
                let current = try SQLiteTaskStore.readTask(.init(id), workspaceID: effect.context.evidence.workspaceID, in: db)
                guard current.revision == revision else { throw SQLiteTaskStore.taskConflict }
            }
            return
        }
        let input = try arguments(effect)
        let proposal = try interpretation(input, context: effect.context, at: effect.context.evidence.admittedAt)
        let targets: [AgentSourceReference]
        if let id = proposal.taskID, let revision = proposal.expectedRevision {
            let current = try SQLiteTaskStore.readTask(id, workspaceID: proposal.workspaceID, in: db)
            guard isReplay ? current.revision >= revision : current.revision == revision else { throw SQLiteTaskStore.taskConflict }
            targets = [.domain(namespace: "tasks", id: id.rawValue, revision: revision)]
        } else { targets = [] }
        guard effect.proposal.plan.targets == targets, effect.proposal.plan.sources.isEmpty else {
            throw SQLiteTaskStore.taskUnauthorized
        }
    }

    public func apply(effect: AgentResolvedEffect, in db: Database) throws -> JSONValue {
        try validate(effect: effect, isReplay: false, in: db)
        let input = try arguments(effect), date = now()
        guard date.timeIntervalSince1970.isFinite else { throw SQLiteTaskStore.taskConflict }
        var proposal = try interpretation(input, context: effect.context, at: date)
        let current = try proposal.taskID.map { try SQLiteTaskStore.readTask($0, workspaceID: proposal.workspaceID, in: db) }
        if let current, [.complete, .cancel].contains(proposal.operation) { proposal.draft = current.draft }
        let direct = TaskCommandInterpreter.canCommitDirectly(proposal, current: current, arguments: input)
            && !proposal.requiresTimeClarification
            && ([TaskOperation.complete, .cancel].contains(proposal.operation) || (proposal.draft.reminderAt.map { $0 > date } ?? true))
        if direct {
            let task = try SQLiteTaskStore.applyTaskProposal(proposal, draft: proposal.draft, actor: "agent", at: date, in: db)
            return .object(["record_saved": .bool(true), "task": try TaskTools.summary(task)])
        }
        guard try Int.fetchOne(db, sql: "SELECT count(*) FROM task_proposals WHERE state = 'pending'") ?? 0 < 100 else {
            throw MiraError(.outputLimit, "Review pending task proposals before creating more.")
        }
        try SQLiteTaskStore.writeTaskProposal(proposal, in: db)
        return .object([
            "record_saved": .bool(false), "proposal_id": .string(proposal.id.uuidString.lowercased()),
            "requires_review": .bool(true), "requires_time_clarification": .bool(proposal.requiresTimeClarification),
            "message": .string("A proposal requires review. No task change or notification has been committed.")
        ])
    }

    private func arguments(_ effect: AgentResolvedEffect) throws -> JSONValue {
        guard effect.proposal.effect == .localWrite, effect.proposal.businessNamespace == namespace,
              effect.proposal.descriptor.revision == 1,
              effect.proposal.descriptor.definition == TaskTools.mutationDefinition else {
            throw SQLiteTaskStore.taskUnauthorized
        }
        let input = try ToolSchemaValidator.decode(try effect.proposal.plan.input.jsonString(), schema: TaskTools.mutationDefinition.inputSchema)
        guard input["quote"]?.stringValue == effect.context.evidence.text else { throw SQLiteTaskStore.taskUnauthorized }
        return input
    }
    private func interpretation(_ input: JSONValue, context: AgentToolContext, at date: Date) throws -> TaskProposal {
        try TaskCommandInterpreter.proposal(arguments: input, reference: TaskEvidence(context.evidence),
            workspaceID: context.evidence.workspaceID, operationID: context.invocationID, at: date)
    }
}
