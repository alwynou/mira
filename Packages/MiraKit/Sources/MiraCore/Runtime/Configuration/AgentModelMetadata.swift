import Foundation

public enum AgentModelMetadataSourceKind: String, Codable, Sendable {
    case provider, catalog, user, probe, module
}

/// A fact records what a source actually said; a successful probe is not a blanket capability claim.
public struct AgentModelMetadataFact: Codable, Sendable, Equatable {
    public let field: String
    public let value: JSONValue
    public let source: AgentModelMetadataSourceKind
    public let sourceID: String
    public let sourceRevision: String
    public let observedAt: Date
    public let invocationID: String?
    /// Probe observations are useful only for the exact invocation configuration tested.
    public let configurationFingerprint: String?
    public init(field: String, value: JSONValue, source: AgentModelMetadataSourceKind,
                sourceID: String, sourceRevision: String, observedAt: Date,
                invocationID: String?, configurationFingerprint: String? = nil) {
        self.field = field; self.value = value; self.source = source; self.sourceID = sourceID
        self.sourceRevision = sourceRevision; self.observedAt = observedAt; self.invocationID = invocationID
        self.configurationFingerprint = configurationFingerprint
    }
    public func validate() throws {
        guard SessionState.validIdentifier(field, maximumBytes: 128),
            !sourceID.isEmpty, sourceID.utf8.count <= 2_048,
            !sourceRevision.isEmpty, sourceRevision.utf8.count <= 256,
            observedAt.timeIntervalSince1970.isFinite,
            invocationID.map({ SessionState.validIdentifier($0, maximumBytes: 128) }) ?? true,
            configurationFingerprint.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
            try SessionCodec.encode(value).count <= 16_384 else {
            throw MiraError(.configuration, "The model metadata fact is invalid.")
        }
        if source == .probe, configurationFingerprint == nil {
            throw MiraError(.configuration, "A model probe observation requires its configuration fingerprint.")
        }
    }
}

public enum AgentModelMetadataField {
    public static let contextWindow = "limit.context"
    public static let inputTokens = "limit.input"
    public static let outputTokens = "limit.output"
    public static let task = "task"
    public static let inputModalities = "modalities.input"
    public static let outputModalities = "modalities.output"
    public static let reasoningControls = "controls.reasoning"
    public static func capability(_ id: String) -> String { "capability.\(id)" }
}

/// Pure, bounded field resolution. Endpoint, authentication, adapter identity and request bodies
/// are deliberately outside the metadata field set consumed here.
public enum AgentModelMetadataResolver {
    public static func selectedFacts(for invocationID: String, facts: [AgentModelMetadataFact]) throws
        -> [String: AgentModelMetadataFact] {
        guard facts.count <= 256 else { throw MiraError(.configuration, "The model metadata exceeds its fact limit.") }
        var grouped: [String: [AgentModelMetadataFact]] = [:]
        for fact in facts {
            try fact.validate()
            guard fact.invocationID == nil || fact.invocationID == invocationID else { continue }
            // A probe result is diagnostic evidence. It never replaces declarations or numeric limits.
            guard fact.source != .probe else { continue }
            grouped[fact.field, default: []].append(fact)
        }
        var selected: [String: AgentModelMetadataFact] = [:]
        for (field, candidates) in grouped {
            let rank = candidates.map(priority).max()!
            let bySource = Dictionary(grouping: candidates.filter { priority($0) == rank }, by: \.sourceID)
            var winners: [AgentModelMetadataFact] = []
            for source in bySource.values {
                let latest = source.map(\.observedAt).max()!
                let current = source.filter { $0.observedAt == latest }.sorted { $0.sourceRevision < $1.sourceRevision }
                guard current.allSatisfy({ $0.value == current[0].value }) else { throw conflict }
                winners.append(current[0])
            }
            winners.sort { $0.sourceID < $1.sourceID }
            guard winners.allSatisfy({ $0.value == winners[0].value }) else { throw conflict }
            selected[field] = winners[0]
        }
        return selected
    }

    public static func resolve(_ invocation: AgentModelInvocationSpec, facts: [AgentModelMetadataFact]) throws
        -> AgentModelInvocationSpec {
        let values = try selectedFacts(for: invocation.id, facts: facts)
        var capabilities = invocation.capabilities
        for (field, fact) in values where field.hasPrefix("capability.") {
            guard case .bool(let supported) = fact.value else {
                throw MiraError(.configuration, "A model capability declaration is invalid.")
            }
            let capability = String(field.dropFirst("capability.".count))
            capabilities[capability] = supported ? .declared : .failed
        }
        let result = AgentModelInvocationSpec(
            id: invocation.id, revision: invocation.revision, adapter: invocation.adapter,
            endpointID: invocation.endpointID,
            contextWindow: try limit(values[AgentModelMetadataField.contextWindow]) ?? invocation.contextWindow,
            maximumOutputTokens: try limit(values[AgentModelMetadataField.outputTokens]) ?? invocation.maximumOutputTokens,
            capabilities: capabilities, configuration: invocation.configuration,
            parameterSchema: invocation.parameterSchema,
            maximumInputTokens: try limit(values[AgentModelMetadataField.inputTokens]) ?? invocation.maximumInputTokens)
        try result.validate()
        return result
    }

    private static func priority(_ fact: AgentModelMetadataFact) -> Int {
        let source: Int
        switch fact.source {
        case .user: source = 40
        case .provider: source = 30
        case .catalog: source = 20
        case .module: source = 10
        case .probe: source = 0
        }
        return source + (fact.invocationID == nil ? 0 : 1)
    }
    private static func limit(_ fact: AgentModelMetadataFact?) throws -> Int? {
        guard let fact else { return nil }
        guard case .number(let value) = fact.value, value.isFinite,
            value.rounded() == value, (1...10_000_000).contains(value) else {
            throw MiraError(.configuration, "The model metadata contains an invalid token limit.")
        }
        return Int(value)
    }
    private static var conflict: MiraError {
        .init(.configuration, "Equally authoritative model metadata sources disagree about a field.")
    }
}
