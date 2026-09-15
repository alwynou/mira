import Foundation
import MiraCore

/// Provider-owned synthetic probes. The core only sees open probe identities
/// and executes their typed input/evaluator closures.
public struct HTTPModelProbeProvider: AgentModelProbeProvider {
    public init() {}

    public func probes() throws -> [AgentModelProbeDefinition] {
        [try Self.text(), try Self.tools(), try Self.json()]
    }

    private static func text() throws -> AgentModelProbeDefinition {
        try AgentModelProbeDefinition(
            identity: .init(
                id: "mira.probe.text", revision: 1, title: "Text response",
                capabilityIDs: [AgentModelCapabilityID.streamingText]),
            preparationCapabilityIDs: [AgentModelCapabilityID.streamingText],
            prepareCandidate: { candidate in
                try Self.prepare(candidate, capabilities: [AgentModelCapabilityID.streamingText])
            },
            makeInput: { stepID, executionID, _ in
                .init(
                    stepID: stepID, executionID: executionID,
                    instructions: "Reply with a short plain-text acknowledgement.",
                    messages: [Self.userMessage("Capability probe: reply with exactly OK.")], tools: [])
            },
            evaluate: { output in
                output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .unsupported : .verified
            })
    }

    private static func tools() throws -> AgentModelProbeDefinition {
        try AgentModelProbeDefinition(
            identity: .init(
                id: "mira.probe.tools", revision: 1, title: "Tool call response",
                capabilityIDs: [AgentModelCapabilityID.toolCalls]),
            preparationCapabilityIDs: [AgentModelCapabilityID.streamingText, AgentModelCapabilityID.toolCalls],
            prepareCandidate: { candidate in
                try Self.prepare(
                    candidate, capabilities: [AgentModelCapabilityID.streamingText, AgentModelCapabilityID.toolCalls])
            },
            makeInput: { stepID, executionID, _ in
                let schema: JSONValue = .object([
                    "type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false),
                ])
                return .init(
                    stepID: stepID, executionID: executionID,
                    instructions: "Call the probe tool exactly once with an empty object.",
                    messages: [Self.userMessage("Capability probe: call probe.echo.")],
                    tools: [
                        .init(
                            name: "probe.echo", description: "A synthetic capability probe tool.", inputSchema: schema)
                    ])
            },
            evaluate: { output in
                guard output.toolCalls.count == 1, let call = output.toolCalls.first,
                    call.name == "probe.echo", let data = call.arguments.data(using: .utf8),
                    let arguments = try? SessionCodec.decode(JSONValue.self, from: data),
                    arguments == .object([:])
                else { return .unsupported }
                return .verified
            })
    }

    private static func json() throws -> AgentModelProbeDefinition {
        try AgentModelProbeDefinition(
            identity: .init(
                id: "mira.probe.json", revision: 1, title: "JSON response",
                capabilityIDs: [AgentModelCapabilityID.jsonOutput]),
            preparationCapabilityIDs: [AgentModelCapabilityID.streamingText],
            prepareCandidate: { candidate in
                try Self.prepare(candidate, capabilities: [AgentModelCapabilityID.streamingText])
            },
            makeInput: { stepID, executionID, _ in
                .init(
                    stepID: stepID, executionID: executionID,
                    instructions: "Return one JSON object with the key result and value OK.",
                    messages: [Self.userMessage("Capability probe: return {\"result\":\"OK\"}.")], tools: [])
            },
            evaluate: { output in
                guard let data = output.text.data(using: .utf8),
                    let value = try? SessionCodec.decode(JSONValue.self, from: data),
                    case .object(let object) = value,
                    object["result"] == .string("OK")
                else { return .unsupported }
                return .verified
            })
    }

    private static func userMessage(_ text: String) -> AgentModelMessage {
        .init(role: .user, blocks: [.init(id: "probe-user", content: .text(text))])
    }

    private static func prepare(_ candidate: AgentModelRouteCandidate, capabilities: Set<String>) throws
        -> AgentModelRouteCandidate
    {
        let selected = try candidate.invocation
        var values = selected.capabilities
        // A failed or unknown attestation may be retried for this probe. A
        // verified attestation is immutable until an explicit configuration
        // change, so preparation never downgrades or rewrites it.
        for capability in capabilities where values[capability] != .verified {
            values[capability] = .declared
        }
        let invocation = AgentModelInvocationSpec(
            id: selected.id, revision: selected.revision, adapter: selected.adapter,
            endpointID: selected.endpointID, contextWindow: selected.contextWindow,
            maximumOutputTokens: selected.maximumOutputTokens, capabilities: values,
            configuration: selected.configuration, parameterSchema: selected.parameterSchema)
        let model = AgentConfiguredModel(
            id: candidate.model.id, revision: candidate.model.revision,
            authorizationRevision: candidate.model.authorizationRevision,
            reference: candidate.model.reference, displayName: candidate.model.displayName,
            isEnabled: candidate.model.isEnabled, invocations: [invocation], facts: candidate.model.facts)
        return AgentModelRouteCandidate(connection: candidate.connection, model: model, preset: candidate.preset)
    }
}
