import Foundation

/// The completed execution references its settled messages; it never copies the transcript.
struct AgentReplayManifest: Codable, Sendable {
    enum Item: Codable, Sendable {
        case content(AgentRequestManifest.Entry)
        case local(AgentModelMessage)
    }
    let executionID: ExecutionID
    let sources: [AgentSourceReference]
    let items: [Item]

    static func stage(_ replay: AgentReplayRecord, execution: SessionExecutionState,
                      context: SessionCommandContext) async throws -> SessionPayloadReference {
        var messages: [(AgentModelMessage, AgentRequestManifest.Entry)] = []
        for id in execution.attemptIDs {
            guard let attempt = context.state.attempts[id], attempt.resolution?.status == .completed,
                  let reference = attempt.resolution?.output else { continue }
            let output = try SessionCodec.decode(AgentModelOutput.self, from: await context.payloads.read(reference))
            messages.append((output.message, .init(reference: reference, representation: .modelOutput)))
            for invocationID in attempt.invocationIDs {
                guard let invocation = context.state.invocations[invocationID], let resolution = invocation.resolution,
                      let result = resolution.result else { continue }
                let call = try SessionCodec.decode(CanonicalToolCall.self, from: await context.payloads.read(invocation.invocation.call))
                let entry = AgentRequestManifest.Entry(reference: result, representation: .toolResult,
                    blockID: "result-\(call.id)", callID: call.id, toolStatus: resolution.status)
                messages.append((try entry.materialize(await context.payloads.read(result)), entry))
            }
        }
        var items: [Item] = []
        for message in replay.messages {
            if let existing = messages.first(where: { $0.0 == message }) {
                items.append(.content(existing.1))
            } else {
                // Local responses and tool denials without a result payload have no
                // earlier message body. Persist their small semantic message here.
                guard execution.attemptIDs.isEmpty || message.role == .tool else { throw invalid }
                items.append(.local(message))
            }
        }
        let manifest = Self(executionID: execution.admission.executionID, sources: replay.sources, items: items)
        return try await context.stage(manifest, kind: .replay, retentionGroup: UUID())
    }

    static func read(_ reference: SessionPayloadReference, state: SessionState,
                     payloads: any SessionPayloadReader) async throws -> AgentReplayRecord {
        let manifest = try await metadata(reference, payloads: payloads)
        guard let execution = state.executions[manifest.executionID], execution.completion?.replay == reference,
              !state.excludedExecutionIDs.contains(manifest.executionID) else { throw invalid }
        let owned = Set(execution.attemptIDs.flatMap { id -> [SessionPayloadReference] in
            guard let attempt = state.attempts[id] else { return [] }
            return [attempt.resolution?.output].compactMap { $0 } + attempt.invocationIDs.compactMap {
                state.invocations[$0]?.resolution?.result
            }
        })
        var messages: [AgentModelMessage] = []
        var bytes = 0
        for item in manifest.items {
            switch item {
            case .local(let message): messages.append(message)
            case .content(let entry):
                try entry.validate(sessionID: state.id)
                guard owned.contains(entry.reference), state.references[entry.reference.id] == entry.reference,
                      !state.invalidatedRetentionGroups.contains(entry.reference.retentionGroup) else { throw invalid }
                bytes += entry.reference.byteCount
                guard bytes <= SessionFormatLimits.maximumPayloadBytes else { throw invalid }
                messages.append(try entry.materialize(await payloads.read(entry.reference)))
            }
        }
        return .init(messages: messages, sources: manifest.sources)
    }

    static func metadata(_ reference: SessionPayloadReference, payloads: any SessionPayloadReader) async throws -> Self {
        guard reference.kind == .replay else { throw invalid }
        let value = try SessionCodec.decode(Self.self, from: await payloads.read(reference))
        guard !value.items.isEmpty, value.items.count <= 256, value.sources.count <= 8_192 else { throw invalid }
        for source in value.sources { try source.validate() }
        return value
    }

    private static var invalid: MiraError { .init(.storage, "The execution replay manifest is inconsistent.") }
}
