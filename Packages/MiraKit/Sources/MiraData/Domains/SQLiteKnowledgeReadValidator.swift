import Foundation
import GRDB
import MiraCore

/// Rechecks Knowledge's canonical disclosure policy in the effect authorization transaction.
/// Blob integrity is checked by the read adapter before returning the captured result.
public struct SQLiteKnowledgeReadValidator: SQLiteBusinessAuthorizationValidator {
    public init() {}
    public func validate(effect: AgentResolvedEffect, isReplay: Bool, in db: Database) throws {
        let proposal = effect.proposal
        guard proposal.effect == .read, proposal.businessNamespace == nil,
              proposal.descriptor.revision == 1, proposal.plan.targets.isEmpty else { throw denied }
        let definition = proposal.descriptor.definition
        let schema: JSONValue
        switch definition {
        case KnowledgeTools.searchDefinition: schema = KnowledgeTools.searchResultSchema
        case KnowledgeTools.openDefinition: schema = KnowledgeTools.openResultSchema
        case KnowledgeTools.readChunkDefinition: schema = KnowledgeTools.chunkResultSchema
        default: throw denied
        }
        guard proposal.descriptor.outputSchema == schema else { throw denied }
        _ = try ToolSchemaValidator.decode(try proposal.plan.input.jsonString(), schema: schema)
        let scope = KnowledgeReadScope(workspaceID: effect.context.evidence.workspaceID, destination: .model(effect.context.route))
        try SQLiteKnowledgeStore.validateScope(scope, in: db)
        let sources = proposal.plan.sources
        guard sources.count <= 6, Set(sources).count == sources.count else { throw denied }
        do {
            for source in sources {
                guard case .domain(let namespace, let id, let revision) = source else { throw denied }
                if definition == KnowledgeTools.openDefinition {
                    guard sources.count == 1, namespace == KnowledgeSources.metadataNamespace else { throw denied }
                    let value = try SQLiteKnowledgeStore.source(.init(id), scope: scope, in: db)
                    guard value.revision == revision else { throw denied }
                } else {
                    guard namespace == KnowledgeSources.chunkNamespace, revision == 1 else { throw denied }
                    let chunk = try SQLiteKnowledgeStore.chunk(.init(id), in: db)
                    let source = try SQLiteKnowledgeStore.source(chunk.summary.sourceID, scope: scope, in: db)
                    let version = try SQLiteKnowledgeStore.version(chunk.summary.sourceVersionID, sourceID: source.id, in: db)
                    guard version.parseState == .ready else { throw denied }
                }
            }
            if definition != KnowledgeTools.searchDefinition { guard sources.count == 1 else { throw denied } }
        } catch let error as MiraError where error.code == .notFound { throw denied }
        _ = isReplay
    }
    private var denied: MiraError { .init(.unauthorized, "The knowledge read is no longer authorized.") }
}
