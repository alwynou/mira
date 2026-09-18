import Foundation

public enum SessionToolActivityStatus: String, Codable, Sendable, Equatable {
    case queued, waitingForApproval, running, succeeded, failed, stopped
}

public struct SessionToolActivity: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let toolName: String
    public let status: SessionToolActivityStatus
    public let arguments: SessionTextContent
    public let result: SessionTextContent

    public init(id: UUID, toolName: String, status: SessionToolActivityStatus,
                arguments: SessionTextContent = .absent, result: SessionTextContent = .absent) {
        self.id = id; self.toolName = toolName; self.status = status
        self.arguments = arguments; self.result = result
    }

}

public struct SessionActivityStep: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let stepIndex: Int
    public let blocks: [SessionActivityBlock]

    public init(id: UUID, stepIndex: Int, blocks: [SessionActivityBlock]) {
        self.id = id; self.stepIndex = stepIndex; self.blocks = blocks
    }
}

public struct SessionActivityBlock: Sendable, Equatable, Identifiable {
    public let id: String
    public let content: Content

    public enum Content: Sendable, Equatable {
        case thinking(SessionTextContent)
        case text(SessionTextContent)
        case tool(SessionToolActivity)
    }

    public init(id: String, content: Content) { self.id = id; self.content = content }
}

/// Bounded, read-only activity assembly from one journal snapshot. It exposes
/// model output blocks and tool exchanges, while never exposing requests or
/// continuation data.
struct SessionActivityReader: Sendable {
    static let maximumExecutionIDs = 128

    static func read(
        snapshot: SessionJournalSnapshot, sessionID: ConversationID,
        executionIDs: [ExecutionID], maximumPageBytes: Int,
        payloads: any SessionContentReader
    ) async throws -> [ExecutionID: [SessionActivityStep]] {
        guard snapshot.state.id == sessionID,
              executionIDs.count <= maximumExecutionIDs,
              Set(executionIDs).count == executionIDs.count,
              maximumPageBytes >= 0 else { throw invalidPage }
        var result: [ExecutionID: [SessionActivityStep]] = [:]
        var remaining = maximumPageBytes
        for executionID in executionIDs {
            guard let execution = snapshot.state.executions[executionID] else {
                result[executionID] = []
                continue
            }
            guard Set(execution.attemptIDs).count == execution.attemptIDs.count else { throw invalidPage }
            let attempts = try execution.attemptIDs.map { id -> SessionAttemptState in
                guard let attempt = snapshot.state.attempts[id], attempt.attempt.id == id,
                      attempt.attempt.executionID == executionID else { throw invalidPage }
                return attempt
            }.sorted {
                if $0.attempt.stepIndex != $1.attempt.stepIndex { return $0.attempt.stepIndex < $1.attempt.stepIndex }
                if $0.attempt.attemptIndex != $1.attempt.attemptIndex { return $0.attempt.attemptIndex < $1.attempt.attemptIndex }
                return $0.sequence < $1.sequence
            }

            var steps: [SessionActivityStep] = []
            for attempt in attempts {
                guard Set(attempt.invocationIDs).count == attempt.invocationIDs.count else { throw invalidPage }
                let invocations = try attempt.invocationIDs.map { id -> SessionInvocationState in
                    guard let invocation = snapshot.state.invocations[id], invocation.invocation.id == id,
                          invocation.invocation.attemptID == attempt.attempt.id else { throw invalidPage }
                    return invocation
                }.sorted { $0.invocation.modelOrder < $1.invocation.modelOrder }

                var blocks: [SessionActivityBlock] = []
                if let output = attempt.resolution?.output {
                    let decoded = try await decodedOutput(output, state: snapshot.state, payloads: payloads, remaining: &remaining)
                    if case .available(let modelOutput) = decoded {
                        var invocationIndex = 0
                        for modelBlock in modelOutput.blocks {
                            switch modelBlock.content {
                            case .thinking(let text): blocks.append(.init(id: modelBlock.id, content: .thinking(.available(text))))
                            case .text(let text): blocks.append(.init(id: modelBlock.id, content: .text(.available(text))))
                            case .toolCall(let call):
                                let order = invocationIndex
                                invocationIndex += 1
                                if let invocation = invocations.first(where: { $0.invocation.modelOrder == order }) {
                                    guard invocation.invocation.toolName == call.name else { throw invalidPage }
                                    blocks.append(.init(id: modelBlock.id, content: .tool(try await tool(
                                        invocation, expectedCall: call, state: snapshot.state,
                                        payloads: payloads, remaining: &remaining))))
                                } else {
                                    blocks.append(.init(id: modelBlock.id, content: .tool(.init(
                                        id: attempt.attempt.id, toolName: call.name,
                                        status: execution.completion == nil ? .queued : .stopped,
                                        arguments: .available(call.arguments), result: .absent))))
                                }
                            case .toolResult: break
                            }
                        }
                    }
                    if blocks.isEmpty {
                        blocks.append(.init(id: "attempt-\(attempt.attempt.id.uuidString)", content: .text(.absent)))
                    }
                }
                let existingToolIDs = Set(blocks.compactMap { block -> UUID? in
                    if case .tool(let tool) = block.content { return tool.id }; return nil
                })
                for invocation in invocations where !existingToolIDs.contains(invocation.invocation.id) {
                    let toolActivity = try await tool(invocation, state: snapshot.state, payloads: payloads, remaining: &remaining)
                    blocks.append(.init(id: invocation.invocation.id.uuidString, content: .tool(toolActivity)))
                }
                steps.append(.init(id: attempt.attempt.id, stepIndex: attempt.attempt.stepIndex, blocks: blocks))
            }
            result[executionID] = steps
        }
        return result
    }

    static func status(of invocation: SessionInvocationState) -> SessionToolActivityStatus {
        if let resolution = invocation.resolution {
            switch resolution.status {
            case .succeeded: return .succeeded
            case .cancelledBeforeDispatch, .cancelled, .interrupted: return .stopped
            case .invalidArguments, .notFound, .denied, .timedOut, .failed, .outputLimit: return .failed
            }
        }
        if let approval = invocation.approval, approval.approved == nil { return .waitingForApproval }
        if invocation.dispatchedAt != nil { return .running }
        return .queued
    }

    private static func tool(
        _ invocation: SessionInvocationState, expectedCall: CanonicalToolCall? = nil, state: SessionState,
        payloads: any SessionContentReader, remaining: inout Int
    ) async throws -> SessionToolActivity {
        let arguments = try await content(invocation.invocation.call, expectedKind: .toolCall,
            state: state, payloads: payloads, remaining: &remaining) {
            let call = try SessionCodec.decode(CanonicalToolCall.self, from: $0)
            guard call.name == invocation.invocation.toolName, expectedCall.map({ $0 == call }) ?? true else { throw invalidPage }
            return call.arguments
        }
        let result: SessionTextContent
        if let reference = invocation.resolution?.result {
            result = try await content(reference, expectedKind: .toolResult, state: state,
                payloads: payloads, remaining: &remaining) {
                let value = try SessionCodec.decode(JSONValue.self, from: $0)
                if let text = value.stringValue { return text }
                return try value.jsonString()
            }
        } else { result = .absent }
        return .init(id: invocation.invocation.id, toolName: invocation.invocation.toolName,
                     status: status(of: invocation), arguments: arguments, result: result)
    }

    private static func decodedOutput(
        _ reference: SessionContent, state: SessionState,
        payloads: any SessionContentReader, remaining: inout Int
    ) async throws -> SessionAuditContent<AgentModelOutput> {
        try reference.validate()
        guard reference.kind == .modelOutput, state.references[reference.id] == reference else { throw invalidPage }
        guard reference.byteCount <= remaining else { return .absent }
        remaining -= reference.byteCount
        let bytes = try await payloads.read(reference)
        guard bytes.count == reference.byteCount else { throw invalidPage }
        return .available(try SessionCodec.decode(AgentModelOutput.self, from: bytes))
    }

    private static func content(
        _ reference: SessionContent, expectedKind: SessionContentKind, state: SessionState,
        payloads: any SessionContentReader, remaining: inout Int,
        decode: (Data) throws -> String
    ) async throws -> SessionTextContent {
        try reference.validate()
        guard reference.kind == expectedKind, state.references[reference.id] == reference else { throw invalidPage }
        guard reference.byteCount <= remaining else { return .absent }
        remaining -= reference.byteCount
        let bytes = try await payloads.read(reference)
        guard bytes.count == reference.byteCount else { throw invalidPage }
        return .available(try decode(bytes))
    }

    private static var invalidPage: MiraError { .init(.storage, "The session activity is inconsistent.") }
}
