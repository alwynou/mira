import Foundation

public struct AgentModelOutput: Codable, Sendable, Equatable {
    public let blocks: [AgentModelBlock]
    public let continuation: AgentModelContinuation?
    public let usage: TokenUsage
    public let finishReason: StreamFinishReason

    public init(blocks: [AgentModelBlock], continuation: AgentModelContinuation?, usage: TokenUsage,
                finishReason: StreamFinishReason) {
        self.blocks = blocks
        self.continuation = continuation
        self.usage = usage
        self.finishReason = finishReason
    }

    public var text: String { Self.text(in: blocks) }
    public var thinkingText: String { Self.thinking(in: blocks) }
    public var toolCalls: [CanonicalToolCall] {
        blocks.compactMap { if case .toolCall(let call) = $0.content { return call }; return nil }
    }

    public var message: AgentModelMessage {
        AgentModelMessage(role: .assistant, blocks: blocks, continuation: continuation)
    }

    public func validate(for route: AgentModelRoute, replay: Bool = false) throws {
        var accumulator = try AgentModelAccumulator(route: route)
        for block in blocks {
            try accumulator.consume(.blockStarted(block))
            try accumulator.consume(.blockFinished(id: block.id))
        }
        if let continuation {
            try accumulator.consume(.continuation(continuation))
        }
        try accumulator.consume(.usage(usage))
        try accumulator.consume(.finished(finishReason))
        let reduced = try accumulator.finish()
        guard reduced == self, !replay || continuation?.isComplete != false else {
            throw MiraError(.malformedStream, "The model output is not a complete ordered replay.")
        }
    }

    static func text(in blocks: [AgentModelBlock]) -> String {
        blocks.compactMap { if case .text(let value) = $0.content { return value }; return nil }.joined()
    }

    static func thinking(in blocks: [AgentModelBlock]) -> String {
        blocks.compactMap { if case .thinking(let value) = $0.content { return value }; return nil }.joined()
    }
}

public struct AgentModelAccumulator: Sendable {
    private let route: AgentModelRoute
    private let maximumTextBytes: Int
    private let maximumToolCalls: Int
    private var blocksStorage: [AgentModelBlock] = []
    private var startedIDs: Set<String> = []
    private var finishedIDs: Set<String> = []
    private var toolCallIDs: Set<String> = []
    private var continuationStorage: AgentModelContinuation?
    private var usageStorage = TokenUsage()
    private var hasUsage = false
    private var finishReasonStorage: StreamFinishReason?
    private var latestVisibleBlockID: String?

    public init(route: AgentModelRoute, maximumTextBytes: Int = 2_097_152, maximumToolCalls: Int = 32) throws {
        try route.validate()
        guard (1...2_097_152).contains(maximumTextBytes), (1...32).contains(maximumToolCalls) else {
            throw MiraError(.configuration, "The model output bounds are invalid.")
        }
        self.route = route
        self.maximumTextBytes = maximumTextBytes
        self.maximumToolCalls = maximumToolCalls
    }

    public var blocks: [AgentModelBlock] { blocksStorage }
    public var continuation: AgentModelContinuation? { continuationStorage }
    public var text: String { AgentModelOutput.text(in: blocksStorage) }
    public var thinkingText: String { AgentModelOutput.thinking(in: blocksStorage) }
    public var toolCalls: [CanonicalToolCall] {
        blocksStorage.compactMap { if case .toolCall(let call) = $0.content { return call }; return nil }
    }
    public var usage: TokenUsage { usageStorage }

    public var outputPhase: SessionOutputPhase {
        guard let id = latestVisibleBlockID,
              let block = blocksStorage.last(where: { $0.id == id }) else { return .waiting }
        // Some protocols keep the thinking block open until the entire response
        // ends. The latest visible block, rather than all open blocks, owns activity.
        if case .toolCall = block.content { return .callingTool }
        guard !finishedIDs.contains(id) else { return .waiting }
        switch block.content {
        case .thinking: return .thinking
        case .text: return .answering
        default: return .waiting
        }
    }

    public mutating func consume(_ event: AgentModelStreamEvent) throws {
        guard finishReasonStorage == nil else { throw invalid("The model output contains data after completion.") }
        switch event {
        case .blockStarted(let block):
            try start(block)
            latestVisibleBlockID = block.id
        case .blockDelta(let id, let value):
            try delta(id: id, value: value)
            latestVisibleBlockID = id
        case .blockFinished(let id):
            guard startedIDs.contains(id), !finishedIDs.contains(id) else {
                throw invalid("The model finished an unknown or already finished block.")
            }
            finishedIDs.insert(id)
        case .continuation(let continuation):
            guard continuationStorage == nil else { throw invalid("The model returned more than one continuation.") }
            try continuation.validate()
            guard continuation.adapter == route.adapter else {
                throw invalid("The model continuation belongs to a different adapter.")
            }
            continuationStorage = continuation
        case .usage(let value):
            try value.validate()
            usageStorage = try mergeUsage(usageStorage, value, hasExisting: hasUsage)
            hasUsage = true
        case .finished(let reason):
            try finish(reason)
        }
    }

    public func finish() throws -> AgentModelOutput {
        guard let reason = finishReasonStorage else {
            throw MiraError(.malformedStream, "The model stream ended without a finish event.")
        }
        guard !blocksStorage.isEmpty || continuationStorage != nil else {
            throw invalid("The model returned no output blocks or continuation data.")
        }
        return AgentModelOutput(blocks: blocksStorage, continuation: continuationStorage,
                                usage: usageStorage, finishReason: reason)
    }

    private mutating func start(_ block: AgentModelBlock) throws {
        try block.validate()
        guard startedIDs.insert(block.id).inserted else {
            throw invalid("The model returned duplicate block identities.")
        }
        switch block.content {
        case .text(let value):
            guard AgentModelOutput.text(in: blocksStorage).utf8.count + value.utf8.count <= maximumTextBytes else {
                throw MiraError(.outputLimit, "The model output exceeded its text limit.")
            }
        case .thinking(let value):
            guard AgentModelOutput.thinking(in: blocksStorage).utf8.count + value.utf8.count <= maximumTextBytes else {
                throw MiraError(.outputLimit, "The model output exceeded its thinking limit.")
            }
        case .toolCall(let call):
            guard route.capabilities.callsTools else {
                throw MiraError(.unsupported, "The model returned tool calls for a route that does not support tools.")
            }
            guard toolCalls.count < maximumToolCalls else {
                throw MiraError(.outputLimit, "The model output exceeded its tool call limit.")
            }
            guard toolCallIDs.insert(call.id).inserted else {
                throw invalid("The model returned duplicate tool call identities.")
            }
        case .toolResult:
            throw invalid("A model output cannot start a tool result block.")
        }
        guard blocksStorage.count < 64 else {
            throw MiraError(.outputLimit, "The model output exceeded its block limit.")
        }
        blocksStorage.append(block)
    }

    private mutating func delta(id: String, value: String) throws {
        guard let index = blocksStorage.firstIndex(where: { $0.id == id }), !finishedIDs.contains(id) else {
            throw invalid("The model returned a delta for an unknown or finished block.")
        }
        let old = blocksStorage[index]
        switch old.content {
        case .text(let existing):
            guard !value.isEmpty else { return }
            let updated = existing + value
            guard AgentModelOutput.text(in: blocksStorage).utf8.count - existing.utf8.count + updated.utf8.count <= maximumTextBytes else {
                throw MiraError(.outputLimit, "The model output exceeded its text limit.")
            }
            blocksStorage[index] = .init(id: old.id, content: .text(updated))
        case .thinking(let existing):
            guard !value.isEmpty else { return }
            let updated = existing + value
            guard AgentModelOutput.thinking(in: blocksStorage).utf8.count - existing.utf8.count + updated.utf8.count <= maximumTextBytes else {
                throw MiraError(.outputLimit, "The model output exceeded its thinking limit.")
            }
            blocksStorage[index] = .init(id: old.id, content: .thinking(updated))
        case .toolCall, .toolResult:
            throw invalid("Only text and thinking blocks accept stream deltas.")
        }
    }

    private mutating func finish(_ reason: StreamFinishReason) throws {
        if reason != .outputLimit {
            guard finishedIDs.count == startedIDs.count else {
                throw invalid("The model finished before every output block was closed.")
            }
            guard continuationStorage?.isComplete != false else {
                throw invalid("The model stream ended before continuation data was complete.")
            }
        }
        guard reason == .toolCalls ? !toolCalls.isEmpty : toolCalls.isEmpty || reason == .outputLimit else {
            throw invalid("The model finish reason does not match its tool call blocks.")
        }
        if reason == .outputLimit, !toolCalls.isEmpty {
            throw invalid("Output-limited model results cannot dispatch tool calls.")
        }
        finishReasonStorage = reason
    }

    private func mergeUsage(_ old: TokenUsage, _ new: TokenUsage, hasExisting: Bool) throws -> TokenUsage {
        if hasExisting {
            for (previous, current) in [(old.inputTokens, new.inputTokens), (old.outputTokens, new.outputTokens),
                                         (old.cacheReadTokens, new.cacheReadTokens), (old.cacheWriteTokens, new.cacheWriteTokens),
                                         (old.reasoningTokens, new.reasoningTokens)] {
                if let previous, let current, current < previous { throw invalid("The model usage counters moved backwards.") }
            }
            guard old.inputTokenBasis == new.inputTokenBasis else {
                throw invalid("The model usage token basis changed during an attempt.")
            }
        }
        let merged = TokenUsage(inputTokens: new.inputTokens ?? old.inputTokens,
                                outputTokens: new.outputTokens ?? old.outputTokens,
                                cacheReadTokens: new.cacheReadTokens ?? old.cacheReadTokens,
                                cacheWriteTokens: new.cacheWriteTokens ?? old.cacheWriteTokens,
                                reasoningTokens: new.reasoningTokens ?? old.reasoningTokens,
                                inputTokenBasis: hasExisting ? old.inputTokenBasis : new.inputTokenBasis)
        try merged.validate()
        return merged
    }

    private func invalid(_ message: String) -> MiraError { .init(.malformedStream, message) }
}
