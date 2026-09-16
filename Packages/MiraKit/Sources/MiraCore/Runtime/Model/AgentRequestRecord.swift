import Foundation

/// Durable semantic input and authorization evidence. Provider wire JSON belongs
/// to ephemeral preparation and is checked by the adapter before dispatch.
public struct AgentRequestRecord: Codable, Sendable, Equatable {
    public let request: AgentContextRequest
    public let input: AgentModelInput
    public let inheritedSources: [AgentSourceReference]
    public let evidence: [AgentContextEvidence]
    public let omissions: [AgentContextOmission]
    public let adapter: AgentAdapterIdentity
    public let estimatedInputTokens: Int
    private let currentUserMessageIndex: Int

    public var sources: [AgentSourceReference] {
        AgentContextBuild.orderedSources(inheritedSources + evidence.flatMap(\.sources))
    }

    public func validate(for route: AgentModelRoute) throws {
        try validate()
        try input.validate(for: route)
        let outputLimit = input.outputTokenLimit ?? route.maximumOutputTokens
        guard request.destination == .model(route), adapter == route.adapter,
              estimatedInputTokens <= min(route.contextWindow - outputLimit, route.maximumInputTokens ?? Int.max),
              try SessionCodec.encode(self).count <= SessionFormatLimits.maximumPayloadBytes else {
            throw MiraError(.contextLimit, "The model input exceeds its supported bounds.")
        }
    }

    public init(_ build: AgentContextBuild) throws {
        guard let index = build.prepared.input.messages.lastIndex(where: { $0.role == .user }) else {
            throw Self.invalid
        }
        request = build.request
        input = build.prepared.input
        inheritedSources = build.inheritedSources
        evidence = build.evidence
        omissions = build.omissions
        adapter = build.prepared.adapter
        estimatedInputTokens = build.prepared.estimatedInputTokens
        currentUserMessageIndex = index
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, workspaceID, authorizationEpoch, route, input, currentUserMessageIndex
        case inheritedSources, evidence, omissions, adapter, estimatedInputTokens
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(request.sessionID, forKey: .sessionID)
        try values.encodeIfPresent(request.workspaceID, forKey: .workspaceID)
        try values.encode(request.authorizationEpoch, forKey: .authorizationEpoch)
        try values.encode(request.destination.modelRoute, forKey: .route)
        try values.encode(input, forKey: .input)
        try values.encode(currentUserMessageIndex, forKey: .currentUserMessageIndex)
        try values.encode(inheritedSources, forKey: .inheritedSources)
        try values.encode(evidence, forKey: .evidence)
        try values.encode(omissions, forKey: .omissions)
        try values.encode(adapter, forKey: .adapter)
        try values.encode(estimatedInputTokens, forKey: .estimatedInputTokens)
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        input = try values.decode(AgentModelInput.self, forKey: .input)
        currentUserMessageIndex = try values.decode(Int.self, forKey: .currentUserMessageIndex)
        guard input.messages.indices.contains(currentUserMessageIndex) else { throw Self.invalid }
        request = .init(sessionID: try values.decode(ConversationID.self, forKey: .sessionID),
            executionID: input.executionID, workspaceID: try values.decodeIfPresent(WorkspaceID.self, forKey: .workspaceID),
            userText: input.messages[currentUserMessageIndex].text,
            authorizationEpoch: try values.decode(UInt64.self, forKey: .authorizationEpoch),
            destination: .model(try values.decode(AgentModelRoute.self, forKey: .route)))
        inheritedSources = try values.decode([AgentSourceReference].self, forKey: .inheritedSources)
        evidence = try values.decode([AgentContextEvidence].self, forKey: .evidence)
        omissions = try values.decode([AgentContextOmission].self, forKey: .omissions)
        adapter = try values.decode(AgentAdapterIdentity.self, forKey: .adapter)
        estimatedInputTokens = try values.decode(Int.self, forKey: .estimatedInputTokens)
        try validate()
    }

    private func validate() throws {
        guard input.messages.indices.contains(currentUserMessageIndex),
              currentUserMessageIndex == input.messages.lastIndex(where: { $0.role == .user }),
              input.executionID == request.executionID,
              request.destination.modelRoute?.adapter == adapter, estimatedInputTokens >= 0 else { throw Self.invalid }
        let current = input.messages[currentUserMessageIndex]
        guard !current.blocks.isEmpty, current.continuation == nil,
              current.blocks.allSatisfy({ if case .text = $0.content { true } else { false } }),
              current.text == request.userText else { throw Self.invalid }
    }

    private static var invalid: MiraError {
        .init(.storage, "The execution request evidence is inconsistent.")
    }
}
