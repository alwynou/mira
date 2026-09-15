import Foundation

/// A value snapshot holds both the executable contribution and its immutable declaration.
/// Its owning registry lease must remain alive until every invocation has drained.
public struct AgentToolCatalog: Sendable {
    struct Entry: Sendable {
        let tool: AgentTool
        let descriptor: AgentToolDescriptor
        let effect: SessionEffectKind
        let businessNamespace: String?
        let policy: AgentToolPolicyRequirement
    }
    private let entries: [String: Entry]

    public init(_ tools: [AgentTool]) throws {
        guard tools.count <= 256 else { throw MiraError(.configuration, "The tool catalog exceeds its registration limit.") }
        var entries: [String: Entry] = [:]
        for tool in tools {
            let descriptor = tool.preparation.descriptor
            try descriptor.validate()
            let name = descriptor.definition.name
            guard entries[name] == nil,
                  tool.businessNamespace.map({ SessionState.validIdentifier($0, maximumBytes: 128) }) ?? true else {
                throw MiraError(.configuration, "The tool catalog contains conflicting identities.")
            }
            entries[name] = .init(tool: tool, descriptor: descriptor, effect: tool.effect,
                                  businessNamespace: tool.businessNamespace, policy: tool.preparation.policy)
        }
        self.entries = entries
    }

    public var definitions: [ToolDefinition] { entries.values.map(\.descriptor.definition).sorted { $0.name < $1.name } }
    public var effects: [String: SessionEffectKind] { entries.mapValues(\.effect) }
    func entry(named name: String) -> Entry? { entries[name] }
}
