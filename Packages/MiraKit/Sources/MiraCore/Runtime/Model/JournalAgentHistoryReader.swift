import Foundation

/// A replayable user/model exchange retained as one indivisible history unit.
public struct AgentHistoryExchange: Sendable, Equatable {
    public let messages: [AgentModelMessage]
    public let sources: [AgentSourceReference]
    public let isIncomplete: Bool

    public init(messages: [AgentModelMessage], sources: [AgentSourceReference], isIncomplete: Bool = false) {
        self.messages = messages
        self.sources = sources
        self.isIncomplete = isIncomplete
    }
}

/// Historical exchanges in chronological order. Context flattening is derived
/// only after whole exchanges have been selected or removed.
public struct AgentSessionHistory: Sendable, Equatable {
    public let exchanges: [AgentHistoryExchange]

    public init(exchanges: [AgentHistoryExchange]) {
        self.exchanges = exchanges
    }

    public var isEmpty: Bool { exchanges.isEmpty }

    public var context: AgentContextHistory {
        var messages: [AgentModelMessage] = []
        var sources = Set<AgentSourceReference>()
        for exchange in exchanges {
            messages.append(contentsOf: exchange.messages)
            sources.formUnion(exchange.sources)
        }
        return .init(messages: messages, sources: sources.sorted(by: AgentSourceReference.ordered))
    }

    public func removingOldestExchange() -> AgentSessionHistory {
        guard !exchanges.isEmpty else { return self }
        return .init(exchanges: Array(exchanges.dropFirst()))
    }
}

/// Reconstructs replayable history from the authoritative session snapshot.
/// Exchanges are selected as whole user/replay units, newest first, and only
/// units that fit the message and source budgets are retained.
public struct JournalAgentHistoryReader: Sendable {
    private static let maximumAllowedMessages = 254
    private static let maximumAllowedBytes = 6 * 1_024 * 1_024
    private let payloads: any SessionContentReader

    public init(payloads: any SessionContentReader) {
        self.payloads = payloads
    }

    /// Returns the sources committed by model requests and tool proposals for an
    /// execution. Tool plans are part of the durable provenance even when their
    /// result is absent, so callers must authorize this complete set before
    /// exposing a replay or terminal content.
    func readExecutionSources(execution: SessionExecutionState, state: SessionState,
                              route: AgentModelRoute? = nil,
                              resolvedOnly: Bool = false) async throws -> [AgentSourceReference] {
        var sources: [AgentSourceReference] = []
        for attemptID in execution.attemptIDs {
            guard let attempt = state.attempts[attemptID], attempt.attempt.request.kind == .request else {
                throw MiraError(.storage, "The committed model request is unavailable.")
            }
            if resolvedOnly, attempt.resolution == nil { continue }
            let request = try await readBuild(attempt.attempt.request, state: state)
            guard request.request.sessionID == state.id,
                  request.request.executionID == execution.admission.executionID,
                  request.request.workspaceID == state.header?.workspaceID,
                  request.sources.count <= 8_192,
                  let buildRoute = request.request.destination.modelRoute,
                  route.map({ $0 == buildRoute }) ?? true else {
                throw MiraError(.storage, "The committed model request evidence is inconsistent.")
            }
            try request.validate(for: buildRoute)
            sources += request.sources
            for invocationID in attempt.invocationIDs {
                guard let invocation = state.invocations[invocationID] else {
                    throw MiraError(.storage, "The committed tool invocation is unavailable.")
                }
                if let reference = invocation.intent?.intent.proposal {
                    let proposal = try SessionCodec.decode(AgentToolProposal.self,
                        from: try await payloads.read(reference))
                    try proposal.validate()
                    sources += proposal.plan.sources
                }
            }
        }
        return AgentContextBuild.orderedSources(sources)
    }

    /// Rebuilds the active execution exchange from committed attempt and tool facts.
    /// An unsettled suffix is intentionally omitted; the kernel may only prepare a
    /// next step after the preceding tool exchange has committed completely.
    public func readCurrentExecution(state: SessionState, request: AgentContextRequest,
                                     route: AgentModelRoute,
                                     authorizer: (any AgentSourceAuthorizer)? = nil) async throws -> AgentContextHistory {
        guard request.destination == .model(route), state.id == request.sessionID,
              state.authorizationEpoch == request.authorizationEpoch,
              state.activeExecutionID == request.executionID,
              state.header?.workspaceID == request.workspaceID,
              !state.supersededExecutionIDs.contains(request.executionID),
              let execution = state.executions[request.executionID] else {
            throw MiraError(.unauthorized, "The current execution history request is stale.")
        }
        var messages: [AgentModelMessage] = []
        var sources: [AgentSourceReference] = []
        for attemptID in execution.attemptIDs {
            guard let attempt = state.attempts[attemptID],
                  let resolution = attempt.resolution,
                  resolution.status == .completed,
                  let outputReference = resolution.output,
                  outputReference.kind == .modelOutput else { break }
            let output = try SessionCodec.decode(AgentModelOutput.self, from: try await payloads.read(outputReference))
            try output.validate(for: route, replay: true)
            messages.append(output.message)
            let persisted = try await readBuild(attempt.attempt.request, state: state)
            guard persisted.request == request, persisted.request.destination == .model(route) else {
                throw MiraError(.storage, "The committed model request does not match the current execution.")
            }
            try persisted.validate(for: route)
            sources += persisted.sources

            guard attempt.invocationIDs.count == output.toolCalls.count else {
                throw MiraError(.storage, "The committed tool exchange is inconsistent with its model output.")
            }
            for invocationID in attempt.invocationIDs.sorted(by: { lhs, rhs in
                (state.invocations[lhs]?.invocation.modelOrder ?? .max) < (state.invocations[rhs]?.invocation.modelOrder ?? .max)
            }) {
                guard let invocation = state.invocations[invocationID],
                      let resolution = invocation.resolution,
                      invocation.invocation.modelOrder < output.toolCalls.count,
                      invocation.invocation.call.kind == .toolCall else {
                    throw MiraError(.conflict, "The current model step is waiting for committed tool results.")
                }
                let recordedCall = try SessionCodec.decode(CanonicalToolCall.self,
                    from: try await payloads.read(invocation.invocation.call))
                guard recordedCall == output.toolCalls[invocation.invocation.modelOrder] else {
                    throw MiraError(.storage, "The committed tool call differs from its model output.")
                }
                let call = output.toolCalls[invocation.invocation.modelOrder]
                if let reference = invocation.intent?.intent.proposal {
                    let proposal = try SessionCodec.decode(AgentToolProposal.self, from: try await payloads.read(reference))
                    try proposal.validate()
                    sources += proposal.plan.sources
                }
                let observation = try SessionToolObservation.value(resolution)
                messages.append(.init(role: .tool, blocks: [.init(
                    id: "result-\(call.id)",
                    content: .toolResult(callID: call.id, text: try observation.jsonString())
                )]))
            }
        }
        let orderedSources = AgentContextBuild.orderedSources(sources)
        if let authorizer, !orderedSources.isEmpty { try await authorizer.validate(orderedSources, for: request) }
        return .init(messages: messages, sources: orderedSources)
    }

    public func read(state: SessionState, request: AgentContextRequest,
                     route: AgentModelRoute, adapter: any AgentModelAdapter,
                     authorizer: any AgentSourceAuthorizer,
                     maximumMessages: Int = 254,
                     maximumBytes: Int = 6 * 1_024 * 1_024) async throws -> AgentSessionHistory {
        guard (0...Self.maximumAllowedMessages).contains(maximumMessages),
              (0...Self.maximumAllowedBytes).contains(maximumBytes) else {
            throw MiraError(.invalidInput, "The historical context budgets are invalid.")
        }
        guard request.destination == .model(route), state.id == request.sessionID, state.authorizationEpoch == request.authorizationEpoch,
              state.activeExecutionID == request.executionID,
              state.header?.workspaceID == request.workspaceID,
              !state.supersededExecutionIDs.contains(request.executionID),
              let currentExecution = state.executions[request.executionID],
              let currentIndex = state.executionOrder.firstIndex(of: request.executionID) else {
            throw MiraError(.unauthorized, "The session history request is stale.")
        }
        if maximumMessages == 0 || maximumBytes == 0 {
            return .init(exchanges: [])
        }
        try Task.checkCancellation()
        var latestByUser: [MessageID: Int] = [:]
        var originalBodies: [MessageID: SessionContent] = [:]
        for index in 0..<currentIndex {
            try Task.checkCancellation()
            let executionID = state.executionOrder[index]
            if let admission = state.executions[executionID]?.admission, let body = admission.userBody,
               originalBodies[admission.userMessageID] == nil {
                originalBodies[admission.userMessageID] = body
            }
            guard !state.supersededExecutionIDs.contains(executionID),
                  let execution = state.executions[executionID],
                  execution.admission.userMessageID != currentExecution.admission.userMessageID,
                  let completion = execution.completion else { continue }
            let hasCompletedReplay = completion.status == .completed
            let hasPartialAnswer = [.cancelled, .interrupted].contains(completion.status)
            guard hasCompletedReplay || hasPartialAnswer else { continue }
            if !hasCompletedReplay {
                if let answer = completion.answer {
                    guard answer.kind == .visibleAnswer,
                          completion.assistantMessageID != nil else { continue }
                } else {
                    if completion.visibleThinking == nil {
                        guard completion.assistantMessageID == nil else { continue }
                    } else {
                        guard completion.assistantMessageID != nil else { continue }
                    }
                }
            }
            latestByUser[execution.admission.userMessageID] = index
        }
        var selected: [(index: Int, exchange: AgentHistoryExchange)] = []
        var messageCount = 0
        var sourceSet = Set<AgentSourceReference>()
        var retainedMessageBytes = 0
        for index in latestByUser.values.sorted(by: >) {
            try Task.checkCancellation()
            if messageCount == maximumMessages { break }
            let executionID = state.executionOrder[index]
            guard let execution = state.executions[executionID],
                  let completion = execution.completion else { continue }
            let userBody = try await readOriginalUser(originalBodies[execution.admission.userMessageID], state: state)
            try Task.checkCancellation()
            var messages: [AgentModelMessage]
            let sources: [AgentSourceReference]
            if completion.status == .completed {
                if execution.attemptIDs.isEmpty {
                    guard let answer = completion.answer else { continue }
                    let text = try await readAnswer(answer, state: state)
                    guard !text.isEmpty else { continue }
                    sources = [.sessionExecution(sessionID: state.id, executionID: executionID)]
                    messages = [.init(role: .assistant,
                        blocks: [.init(id: "answer", content: .text(text))])]
                } else {
                    let derived = try await readCommittedExchange(execution: execution, state: state)
                    guard derived.complete else { continue }
                    sources = AgentContextBuild.orderedSources(derived.sources + [
                        .sessionExecution(sessionID: state.id, executionID: executionID)
                    ])
                    guard let sourceRoute = try await readRoute(execution.admission, state: state),
                          let transformed = try replayMessages(derived.messages, sourceRoute: sourceRoute,
                                                               route: route, adapter: adapter, executionID: executionID) else { continue }
                    messages = transformed
                }
            } else if [.cancelled, .interrupted].contains(completion.status) {
                guard let recorded = try await readRecordedSources(execution: execution, state: state) else { continue }
                sources = AgentContextBuild.orderedSources(recorded + [
                    .sessionExecution(sessionID: state.id, executionID: executionID)
                ])
                let derived = try await readCommittedExchange(execution: execution, state: state)
                if derived.messages.isEmpty {
                    messages = []
                } else {
                    guard let sourceRoute = try await readRoute(execution.admission, state: state),
                          let transformed = try replayMessages(derived.messages, sourceRoute: sourceRoute,
                                                               route: route, adapter: adapter,
                                                               executionID: executionID,
                                                               allowToolTerminated: !derived.complete) else { continue }
                    messages = transformed
                }
                var partialBlocks: [AgentModelBlock] = []
                if let thinking = completion.visibleThinking {
                    let text = try await readThinking(thinking, state: state)
                    if !text.isEmpty { partialBlocks.append(.init(id: "incomplete-thinking", content: .thinking(text))) }
                }
                if let answer = completion.answer {
                    let text = try await readAnswer(answer, state: state)
                    if !text.isEmpty { partialBlocks.append(.init(id: "incomplete-answer", content: .text(text))) }
                }
                if !partialBlocks.isEmpty { messages.append(.init(role: .assistant, blocks: partialBlocks)) }
                messages.append(.init(role: .assistant, blocks: [.init(id: "incomplete-history",
                    content: .text("[The preceding assistant response was interrupted and is incomplete.]"))]))
            } else { continue }
            // The exchange's own provenance consumes the same finite source budget as domain references.
            guard sources.count <= 8_192 else { continue }
            do {
                try await authorizer.validate(sources, for: request)
            } catch let error as MiraError where error.code == .unauthorized {
                // A historical domain source may have been revoked or advanced
                // since the exchange was committed. Omit that exchange rather
                // than turning a fresh request into a failed execution. The
                // session execution source remains a hard liveness boundary:
                // if it cannot be authorized, propagate the denial.
                let sessionSources = sources.filter {
                    if case .sessionExecution = $0 { return true }
                    return false
                }
                if !sessionSources.isEmpty {
                    try await authorizer.validate(sessionSources, for: request)
                }
                continue
            }
            try Task.checkCancellation()
            let exchange = AgentHistoryExchange(
                messages: [AgentModelMessage(role: .user, blocks: [AgentModelBlock(id: "user", content: .text(userBody))])] + messages,
                sources: sources, isIncomplete: completion.status != .completed)
            let nextSources = sourceSet.union(sources)
            let messageBytes = try SessionCodec.encode(exchange.messages).count
            let sourceBytes = try SessionCodec.encode(Array(nextSources)).count
            guard exchange.messages.count <= maximumMessages - messageCount,
                  nextSources.count <= 8_192,
                  messageBytes <= maximumBytes - retainedMessageBytes,
                  sourceBytes <= maximumBytes - retainedMessageBytes - messageBytes else { continue }
            selected.append((index: index, exchange: exchange)); messageCount += exchange.messages.count
            sourceSet = nextSources; retainedMessageBytes += messageBytes
        }
        return .init(exchanges: selected.sorted(by: { $0.index < $1.index }).map(\.exchange))
    }

    private func readOriginalUser(_ reference: SessionContent?, state: SessionState) async throws -> String {
        guard let reference else {
            throw MiraError(.storage, "The historical user message is unavailable.")
        }
        guard let body = String(data: try await payloads.read(reference), encoding: .utf8) else {
            throw MiraError(.storage, "The historical user message is not valid UTF-8.")
        }
        return body
    }

    private struct CommittedExchange: Sendable {
        let messages: [AgentModelMessage]
        let sources: [AgentSourceReference]
        let complete: Bool
    }

    private func readCommittedExchange(execution: SessionExecutionState, state: SessionState) async throws -> CommittedExchange {
        var messages: [AgentModelMessage] = []
        var sources: [AgentSourceReference] = []
        for attemptID in execution.attemptIDs {
            guard let attempt = state.attempts[attemptID], let resolution = attempt.resolution,
                  resolution.status == .completed, let outputReference = resolution.output,
                  outputReference.kind == .modelOutput else { return .init(messages: messages, sources: sources, complete: false) }
            let output = try SessionCodec.decode(AgentModelOutput.self, from: try await payloads.read(outputReference))
            guard let sourceRoute = try await readRoute(execution.admission, state: state) else {
                return .init(messages: messages, sources: sources, complete: false)
            }
            try output.validate(for: sourceRoute, replay: true)
            // Validate and assemble one model/tool round before publishing it to
            // the partial transcript. An interrupted suffix may contain an
            // assistant tool call without a committed result; that suffix is
            // not a replayable exchange and must not escape as history.
            var roundMessages: [AgentModelMessage] = [output.message]
            var roundSources: [AgentSourceReference] = []
            let request = try await readBuild(attempt.attempt.request, state: state)
            guard request.request.sessionID == state.id,
                  request.request.executionID == execution.admission.executionID,
                  request.request.workspaceID == state.header?.workspaceID,
                  request.request.destination.modelRoute == sourceRoute else {
                throw MiraError(.storage, "The committed model request evidence is inconsistent.")
            }
            try request.validate(for: sourceRoute)
            roundSources += request.sources
            guard attempt.invocationIDs.count == output.toolCalls.count else {
                throw MiraError(.storage, "The committed tool exchange is inconsistent with its model output.")
            }
            for invocationID in attempt.invocationIDs.sorted(by: { lhs, rhs in
                (state.invocations[lhs]?.invocation.modelOrder ?? .max) < (state.invocations[rhs]?.invocation.modelOrder ?? .max)
            }) {
                guard let invocation = state.invocations[invocationID],
                      let resolution = invocation.resolution,
                      invocation.invocation.modelOrder < output.toolCalls.count,
                      invocation.invocation.call.kind == .toolCall else {
                    return .init(messages: messages, sources: sources, complete: false)
                }
                let recordedCall = try SessionCodec.decode(CanonicalToolCall.self,
                    from: try await payloads.read(invocation.invocation.call))
                guard recordedCall == output.toolCalls[invocation.invocation.modelOrder] else {
                    return .init(messages: messages, sources: sources, complete: false)
                }
                if let reference = invocation.intent?.intent.proposal {
                    let proposal = try SessionCodec.decode(AgentToolProposal.self, from: try await payloads.read(reference))
                    try proposal.validate()
                    roundSources += proposal.plan.sources
                }
                let observation: JSONValue
                do {
                    observation = try SessionToolObservation.value(resolution)
                } catch {
                    return .init(messages: messages, sources: sources, complete: false)
                }
                roundMessages.append(.init(role: .tool, blocks: [.init(id: "result-\(recordedCall.id)",
                    content: .toolResult(callID: recordedCall.id, text: try observation.jsonString()))]))
            }
            messages.append(contentsOf: roundMessages)
            sources.append(contentsOf: roundSources)
        }
        return .init(messages: messages, sources: AgentContextBuild.orderedSources(sources), complete: true)
    }

    private func readBuild(_ reference: SessionContent, state: SessionState) async throws -> AgentSessionRequest {
        guard reference.kind == .request else {
            throw MiraError(.storage, "The committed model request is unavailable.")
        }
        return try SessionCodec.decode(AgentSessionRequest.self, from: try await payloads.read(reference))
    }

    private func readAnswer(_ reference: SessionContent, state: SessionState) async throws -> String {
        guard reference.kind == .visibleAnswer,
              let value = String(data: try await payloads.read(reference), encoding: .utf8) else {
            throw MiraError(.storage, "The incomplete historical answer is unavailable.")
        }
        return value
    }

    private func readThinking(_ reference: SessionContent, state: SessionState) async throws -> String {
        guard reference.kind == .visibleThinking,
              let value = String(data: try await payloads.read(reference), encoding: .utf8) else {
            throw MiraError(.storage, "The incomplete historical thinking is unavailable.")
        }
        return value
    }

    private func readRecordedSources(execution: SessionExecutionState, state: SessionState) async throws -> [AgentSourceReference]? {
        guard execution.attemptIDs.count <= 256 else { return nil }
        // Resolve the complete set of committed request and tool-proposal sources.
        let sources = try await readExecutionSources(execution: execution, state: state, resolvedOnly: true)
        guard sources.count <= 65_536 else { return nil }
        return sources
    }

    private func readRoute(_ admission: SessionAdmission, state: SessionState) async throws -> AgentModelRoute? {
        let reference = admission.plan
        guard reference.kind == .executionPlan else {
            throw MiraError(.storage, "The historical route reference is unavailable.")
        }
        return try await AgentExecutionPlan.read(for: admission, from: payloads).route
    }

    private func replayMessages(_ messages: [AgentModelMessage], sourceRoute: AgentModelRoute?,
                                route: AgentModelRoute, adapter: any AgentModelAdapter,
                                executionID: ExecutionID,
                                allowToolTerminated: Bool = false) throws -> [AgentModelMessage]? {
        guard !messages.isEmpty, messages.count <= 256,
              messages.allSatisfy({ $0.role == .assistant || $0.role == .tool }) else {
            throw MiraError(.malformedStream, "The historical replay transcript is invalid.")
        }
        if !allowToolTerminated {
            guard let last = messages.last, last.role == .assistant, last.toolCalls.isEmpty else {
                throw MiraError(.malformedStream, "The historical replay transcript is invalid.")
            }
        }
        let sourceInput = AgentModelInput(stepID: UUID(), executionID: executionID,
            instructions: "", messages: messages, tools: [])
        guard let sourceRoute else {
            guard messages.count == 1, let answer = messages.first, answer.role == .assistant,
                  answer.blocks.count == 1, !answer.text.isEmpty, answer.thinkingText.isEmpty,
                  answer.toolCalls.isEmpty, answer.toolResults.isEmpty, answer.continuation == nil else {
                throw MiraError(.malformedStream, "The local driver replay record is invalid.")
            }
            try sourceInput.validate(for: route)
            return messages
        }
        try sourceInput.validate(for: sourceRoute)
        guard case .include(let transformed) = try adapter.replay(messages, from: sourceRoute,
                                                                   to: route, boundary: .previousExecution) else { return nil }
        guard transformed.count == messages.count else {
            throw MiraError(.malformedStream, "The adapter changed the historical replay transcript.")
        }
        for (original, value) in zip(messages, transformed) {
            let thinkingOmitted = original.blocks.filter {
                if case .thinking = $0.content { return false }
                return true
            }
            guard original.role == value.role,
                  (value.blocks == original.blocks || value.blocks == thinkingOmitted),
                  value.continuation == nil || value.continuation == original.continuation,
                  value.role == .assistant || value.role == .tool else {
                throw MiraError(.malformedStream, "The adapter changed historical replay content.")
            }
        }
        try AgentModelInput(stepID: UUID(), executionID: executionID,
            instructions: "", messages: transformed, tools: []).validate(for: route)
        return transformed
    }
}
