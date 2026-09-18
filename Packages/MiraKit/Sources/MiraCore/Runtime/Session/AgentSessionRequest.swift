import Foundation

/// The admitted semantic request boundary. Transport JSON is transient and is
/// constructed only by the selected adapter; it is never a second journal model.
public struct AgentSessionRequest: Codable, Sendable, Equatable {
    public let request: AgentContextRequest
    public let instructions: String
    public let tools: [ToolDefinition]
    public let contextMessages: [AgentModelMessage]
    public let estimatedInputTokens: Int
    public let inheritedSources: [AgentSourceReference]
    public let evidence: [AgentContextEvidence]
    public let omissions: [AgentContextOmission]

    public init(request: AgentContextRequest, instructions: String, tools: [ToolDefinition],
                contextMessages: [AgentModelMessage], estimatedInputTokens: Int,
                inheritedSources: [AgentSourceReference], evidence: [AgentContextEvidence],
                omissions: [AgentContextOmission]) {
        self.request = request; self.instructions = instructions; self.tools = tools
        self.contextMessages = contextMessages; self.estimatedInputTokens = estimatedInputTokens
        self.inheritedSources = inheritedSources; self.evidence = evidence; self.omissions = omissions
    }

    public init(_ build: AgentContextBuild) {
        self.init(request: build.request, instructions: build.prepared.input.instructions,
                  tools: build.prepared.input.tools,
                  contextMessages: build.prepared.input.messages.filter { $0.role == .context },
                  estimatedInputTokens: build.prepared.estimatedInputTokens,
                  inheritedSources: build.inheritedSources, evidence: build.evidence,
                  omissions: build.omissions)
    }

    public var sources: [AgentSourceReference] {
        AgentContextBuild.orderedSources(inheritedSources + evidence.flatMap(\.sources))
    }

    public func validate(for route: AgentModelRoute) throws {
        guard request.destination == .model(route),
              estimatedInputTokens >= 0, sources.count <= 8_192 else {
            throw MiraError(.storage, "The committed model request evidence is inconsistent.")
        }
        guard contextMessages.allSatisfy({ $0.role == .context && $0.continuation == nil }), tools.count <= 128,
              Set(tools.map(\.name)).count == tools.count else {
            throw MiraError(.storage, "The committed model request evidence is inconsistent.")
        }
        for message in contextMessages { try message.validate(for: route.adapter, replay: false) }
        for source in sources { try source.validate() }
    }
}
