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
    private let payloads: any SessionPayloadReader

    public init(payloads: any SessionPayloadReader) {
        self.payloads = payloads
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
              !state.excludedExecutionIDs.contains(request.executionID),
              let currentExecution = state.executions[request.executionID],
              let currentIndex = state.executionOrder.firstIndex(of: request.executionID) else {
            throw MiraError(.unauthorized, "The session history request is stale.")
        }
        if maximumMessages == 0 || maximumBytes == 0 {
            return .init(exchanges: [])
        }
        try Task.checkCancellation()
        var latestByUser: [MessageID: Int] = [:]
        var originalBodies: [MessageID: SessionPayloadReference] = [:]
        for index in 0..<currentIndex {
            try Task.checkCancellation()
            let executionID = state.executionOrder[index]
            if let admission = state.executions[executionID]?.admission, let body = admission.userBody,
               originalBodies[admission.userMessageID] == nil {
                originalBodies[admission.userMessageID] = body
            }
            guard !state.excludedExecutionIDs.contains(executionID),
                  let execution = state.executions[executionID],
                  execution.admission.userMessageID != currentExecution.admission.userMessageID,
                  let completion = execution.completion else { continue }
            let hasCompletedReplay = completion.status == .completed && completion.replay != nil
            let hasPartialAnswer = [.cancelled, .interrupted].contains(completion.status)
            guard hasCompletedReplay || hasPartialAnswer else { continue }
            if hasCompletedReplay {
                guard let replayReference = completion.replay,
                      !state.invalidatedRetentionGroups.contains(replayReference.retentionGroup),
                      state.references[replayReference.id] == replayReference,
                      replayReference.kind == .replay else { continue }
            } else {
                if let answer = completion.answer {
                    guard state.references[answer.id] == answer,
                          !state.invalidatedRetentionGroups.contains(answer.retentionGroup),
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
            if completion.status == .completed, let replayReference = completion.replay,
               let value = try await readReplay(replayReference, state: state) {
                guard value.sources.count <= 8_192 else { throw MiraError(.storage, "The historical replay transcript is invalid.") }
                for source in value.sources { try source.validate() }
                sources = AgentContextBuild.orderedSources(value.sources + [
                    .sessionExecution(sessionID: state.id, executionID: executionID)
                ])
                guard let transformed = try replayMessages(value.messages, sourceRoute: try await readRoute(execution.admission, state: state),
                    route: route, adapter: adapter, executionID: executionID) else { continue }
                messages = transformed
            } else if [.cancelled, .interrupted].contains(completion.status) {
                guard let recorded = try await readRecordedSources(execution: execution, state: state) else { continue }
                sources = AgentContextBuild.orderedSources(recorded + [
                    .sessionExecution(sessionID: state.id, executionID: executionID)
                ])
                messages = []
                if let answer = completion.answer {
                    let text = try await readAnswer(answer, state: state)
                    guard !text.isEmpty else { continue }
                    messages.append(.init(role: .assistant,
                        blocks: [.init(id: "incomplete-answer", content: .text(text))]))
                }
                messages.append(.init(role: .assistant, blocks: [.init(id: "incomplete-history",
                    content: .text("[The preceding assistant response was interrupted and is incomplete.]"))]))
            } else { continue }
            // The exchange's own provenance consumes the same finite source budget as domain references.
            guard sources.count <= 8_192 else { continue }
            try await authorizer.validate(sources, for: request)
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

    private func readOriginalUser(_ reference: SessionPayloadReference?, state: SessionState) async throws -> String {
        guard let reference, state.references[reference.id] == reference,
              !state.invalidatedRetentionGroups.contains(reference.retentionGroup) else {
            throw MiraError(.storage, "The historical user message is unavailable.")
        }
        guard let body = String(data: try await payloads.read(reference), encoding: .utf8) else {
            throw MiraError(.storage, "The historical user message is not valid UTF-8.")
        }
        return body
    }

    private func readReplay(_ reference: SessionPayloadReference, state: SessionState) async throws -> AgentReplayRecord? {
        guard let committed = state.references[reference.id], committed == reference else { return nil }
        guard reference.kind == .replay else { throw MiraError(.storage, "The historical replay reference has the wrong kind.") }
        return try SessionCodec.decode(AgentReplayRecord.self, from: try await payloads.read(reference))
    }

    private func readAnswer(_ reference: SessionPayloadReference, state: SessionState) async throws -> String {
        guard let committed = state.references[reference.id], committed == reference,
              reference.kind == .visibleAnswer,
              !state.invalidatedRetentionGroups.contains(reference.retentionGroup),
              let value = String(data: try await payloads.read(reference), encoding: .utf8) else {
            throw MiraError(.storage, "The incomplete historical answer is unavailable.")
        }
        return value
    }

    private func readRecordedSources(execution: SessionExecutionState, state: SessionState) async throws -> [AgentSourceReference]? {
        guard execution.attemptIDs.count <= 256 else { return nil }
        // Check every reference before reading any hidden request payload. A partial
        // exchange must never resurrect a request invalidated by privacy maintenance.
        for attemptID in execution.attemptIDs {
            guard let attempt = state.attempts[attemptID],
                  attempt.resolution != nil,
                  state.references[attempt.attempt.request.id] == attempt.attempt.request,
                  attempt.attempt.request.kind == .request,
                  !state.invalidatedRetentionGroups.contains(attempt.attempt.request.retentionGroup) else {
                return nil
            }
        }
        var sources = Set<AgentSourceReference>()
        for attemptID in execution.attemptIDs {
            guard let attempt = state.attempts[attemptID] else { return nil }
            let build = try SessionCodec.decode(AgentContextBuild.self,
                from: try await payloads.read(attempt.attempt.request))
            guard build.request.sessionID == state.id,
                  build.request.executionID == execution.admission.executionID,
                  build.request.workspaceID == state.header?.workspaceID,
                  build.sources.count <= 8_192 else {
                throw MiraError(.storage, "The incomplete historical request evidence is inconsistent.")
            }
            guard let sourceRoute = build.request.destination.modelRoute else {
                throw MiraError(.storage, "The incomplete historical request destination is unavailable.")
            }
            try build.prepared.validate(for: sourceRoute)
            for source in build.sources { try source.validate() }
            sources.formUnion(build.sources)
            guard sources.count <= 65_536 else { return nil }
        }
        return sources.sorted(by: AgentSourceReference.ordered)
    }

    private func readRoute(_ admission: SessionAdmission, state: SessionState) async throws -> AgentModelRoute? {
        let reference = admission.plan
        guard state.references[reference.id] == reference, reference.kind == .executionPlan else {
            throw MiraError(.storage, "The historical route reference is unavailable.")
        }
        return try await AgentExecutionPlan.read(for: admission, from: payloads).route
    }

    private func replayMessages(_ messages: [AgentModelMessage], sourceRoute: AgentModelRoute?,
                                route: AgentModelRoute, adapter: any AgentModelAdapter,
                                executionID: ExecutionID) throws -> [AgentModelMessage]? {
        guard !messages.isEmpty, messages.count <= 256,
              let last = messages.last, last.role == .assistant, last.toolCalls.isEmpty,
              messages.allSatisfy({ $0.role == .assistant || $0.role == .tool }) else {
            throw MiraError(.malformedStream, "The historical replay transcript is invalid.")
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
