import Foundation

/// DSH token accounting used by a raw `usage` stream chunk. Input counters are
/// uncached; cache counters remain separate and optional.
public struct SessionMessageUsage: Codable, Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    public let reasoningTokens: Int?

    public init(inputTokens: Int, outputTokens: Int, totalTokens: Int? = nil,
                cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil,
                reasoningTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
    }

    /// A DSH usage record can be formed only when Mira has both required
    /// counters. Missing provider counters stay missing rather than becoming 0.
    public init?(tokenUsage: TokenUsage) {
        guard (try? tokenUsage.validate(maximumTokens: TokenUsage.maximumAggregateTokens)) != nil,
              let reportedInput = tokenUsage.inputTokens,
              let outputTokens = tokenUsage.outputTokens else { return nil }
        let inputTokens: Int
        switch tokenUsage.inputTokenBasis {
        case .excludesCache:
            inputTokens = reportedInput
        case .includesCache:
            let cache = (tokenUsage.cacheReadTokens ?? 0) + (tokenUsage.cacheWriteTokens ?? 0)
            guard cache <= reportedInput else { return nil }
            inputTokens = reportedInput - cache
        }
        self.init(inputTokens: inputTokens, outputTokens: outputTokens,
                  cacheReadTokens: tokenUsage.cacheReadTokens,
                  cacheWriteTokens: tokenUsage.cacheWriteTokens,
                  reasoningTokens: tokenUsage.reasoningTokens)
    }

    public var tokenUsage: TokenUsage {
        TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens,
                   cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens,
                   reasoningTokens: reasoningTokens, inputTokenBasis: .excludesCache)
    }

    public func validate() throws {
        guard inputTokens >= 0, outputTokens >= 0,
              totalTokens.map({ $0 >= 0 }) ?? true,
              cacheReadTokens.map({ $0 >= 0 }) ?? true,
              cacheWriteTokens.map({ $0 >= 0 }) ?? true,
              reasoningTokens.map({ $0 >= 0 && $0 <= outputTokens }) ?? true else {
            throw SessionMessageStreamError.invalidIndex
        }
    }
}

/// Provider-normalized chunks which are retained as raw `chunk` records.
public enum SessionMessageStreamChunk: Codable, Sendable, Equatable {
    case blockStart(index: Int, blockType: String)
    case textDelta(index: Int, text: String)
    case reasoningDelta(index: Int, text: String)
    case toolCallDelta(index: Int, id: String, name: String? = nil, argumentsDelta: String)
    case blockEnd(index: Int, block: SessionMessageContent)
    case usage(SessionMessageUsage)
    case finish(reason: SessionMessageStreamFinishReason, replayState: JSONValue? = nil)

    private enum CodingKeys: String, CodingKey {
        case type, index, blockType, text, id, name, argumentsDelta, block, usage, reason, replayState
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "block-start":
            self = .blockStart(index: try container.decode(Int.self, forKey: .index), blockType: try container.decode(String.self, forKey: .blockType))
        case "text-delta":
            self = .textDelta(index: try container.decode(Int.self, forKey: .index), text: try container.decode(String.self, forKey: .text))
        case "reasoning-delta":
            self = .reasoningDelta(index: try container.decode(Int.self, forKey: .index), text: try container.decode(String.self, forKey: .text))
        case "tool-call-delta":
            self = .toolCallDelta(index: try container.decode(Int.self, forKey: .index), id: try container.decode(String.self, forKey: .id), name: try container.decodeIfPresent(String.self, forKey: .name), argumentsDelta: try container.decode(String.self, forKey: .argumentsDelta))
        case "block-end":
            self = .blockEnd(index: try container.decode(Int.self, forKey: .index), block: try container.decode(SessionMessageContent.self, forKey: .block))
        case "usage":
            self = .usage(try container.decode(SessionMessageUsage.self, forKey: .usage))
        case "finish":
            self = .finish(reason: try container.decode(SessionMessageStreamFinishReason.self, forKey: .reason), replayState: try container.decodeIfPresent(JSONValue.self, forKey: .replayState))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                debugDescription: "Unsupported session stream chunk type \(type).")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .blockStart(let index, let blockType):
            try container.encode("block-start", forKey: .type); try container.encode(index, forKey: .index); try container.encode(blockType, forKey: .blockType)
        case .textDelta(let index, let text):
            try container.encode("text-delta", forKey: .type); try container.encode(index, forKey: .index); try container.encode(text, forKey: .text)
        case .reasoningDelta(let index, let text):
            try container.encode("reasoning-delta", forKey: .type); try container.encode(index, forKey: .index); try container.encode(text, forKey: .text)
        case .toolCallDelta(let index, let id, let name, let argumentsDelta):
            try container.encode("tool-call-delta", forKey: .type); try container.encode(index, forKey: .index); try container.encode(id, forKey: .id); try container.encodeIfPresent(name, forKey: .name); try container.encode(argumentsDelta, forKey: .argumentsDelta)
        case .blockEnd(let index, let block):
            try container.encode("block-end", forKey: .type); try container.encode(index, forKey: .index); try container.encode(block, forKey: .block)
        case .usage(let usage):
            try container.encode("usage", forKey: .type); try container.encode(usage, forKey: .usage)
        case .finish(let reason, let replayState):
            try container.encode("finish", forKey: .type); try container.encode(reason, forKey: .reason); try container.encodeIfPresent(replayState, forKey: .replayState)
        }
    }

    public func validate() throws {
        switch self {
        case .blockStart(let index, let blockType): guard index >= 0, !blockType.isEmpty else { throw SessionMessageStreamError.invalidIndex }
        case .textDelta(let index, _), .reasoningDelta(let index, _): guard index >= 0 else { throw SessionMessageStreamError.invalidIndex }
        case .toolCallDelta(let index, let id, let name, _): guard index >= 0, !id.isEmpty, name.map({ !$0.isEmpty }) ?? true else { throw SessionMessageStreamError.invalidIndex }
        case .blockEnd(let index, let block): guard index >= 0 else { throw SessionMessageStreamError.invalidIndex }; try block.validate()
        case .usage(let usage): try usage.validate()
        case .finish: break
        }
    }
}

public enum SessionMessageStreamFinishReason: Codable, Sendable, Equatable {
    case stop
    case toolCalls
    case maxTokens
    case aborted(failure: JSONValue)
    case error(failure: JSONValue)

    private enum CodingKeys: String, CodingKey { case kind, failure }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "stop": self = .stop
        case "tool-calls": self = .toolCalls
        case "max-tokens": self = .maxTokens
        case "aborted": self = .aborted(failure: try container.decode(JSONValue.self, forKey: .failure))
        case "error": self = .error(failure: try container.decode(JSONValue.self, forKey: .failure))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unsupported stream finish reason.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stop: try container.encode("stop", forKey: .kind)
        case .toolCalls: try container.encode("tool-calls", forKey: .kind)
        case .maxTokens: try container.encode("max-tokens", forKey: .kind)
        case .aborted(let failure): try container.encode("aborted", forKey: .kind); try container.encode(failure, forKey: .failure)
        case .error(let failure): try container.encode("error", forKey: .kind); try container.encode(failure, forKey: .failure)
        }
    }
}

public struct SessionMessageStreamTimedChunk: Codable, Sendable, Equatable {
    public let time: Int
    public let chunk: SessionMessageStreamChunk
    public init(time: Int, chunk: SessionMessageStreamChunk) { self.time = time; self.chunk = chunk }
}

/// One compact DSH assistant-stream record.
public enum SessionMessageStreamRecord: Codable, Sendable, Equatable {
    case textChunks(time0: Int, index: Int, dt: [Int], texts: [String])
    case reasoningChunks(time0: Int, index: Int, dt: [Int], texts: [String])
    case toolCallChunks(time0: Int, index: Int, dt: [Int], id: String, name: String? = nil, args: [String])
    case chunk(time: Int, chunk: SessionMessageStreamChunk)

    private enum CodingKeys: String, CodingKey { case type, time0, index, dt, texts, id, name, args, time, chunk }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text-chunks": self = .textChunks(time0: try container.decode(Int.self, forKey: .time0), index: try container.decode(Int.self, forKey: .index), dt: try container.decode([Int].self, forKey: .dt), texts: try container.decode([String].self, forKey: .texts))
        case "reasoning-chunks": self = .reasoningChunks(time0: try container.decode(Int.self, forKey: .time0), index: try container.decode(Int.self, forKey: .index), dt: try container.decode([Int].self, forKey: .dt), texts: try container.decode([String].self, forKey: .texts))
        case "tool-call-chunks": self = .toolCallChunks(time0: try container.decode(Int.self, forKey: .time0), index: try container.decode(Int.self, forKey: .index), dt: try container.decode([Int].self, forKey: .dt), id: try container.decode(String.self, forKey: .id), name: try container.decodeIfPresent(String.self, forKey: .name), args: try container.decode([String].self, forKey: .args))
        case "chunk": self = .chunk(time: try container.decode(Int.self, forKey: .time), chunk: try container.decode(SessionMessageStreamChunk.self, forKey: .chunk))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported session stream record.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .textChunks(let time0, let index, let dt, let texts):
            try container.encode("text-chunks", forKey: .type); try container.encode(time0, forKey: .time0); try container.encode(index, forKey: .index); try container.encode(dt, forKey: .dt); try container.encode(texts, forKey: .texts)
        case .reasoningChunks(let time0, let index, let dt, let texts):
            try container.encode("reasoning-chunks", forKey: .type); try container.encode(time0, forKey: .time0); try container.encode(index, forKey: .index); try container.encode(dt, forKey: .dt); try container.encode(texts, forKey: .texts)
        case .toolCallChunks(let time0, let index, let dt, let id, let name, let args):
            try container.encode("tool-call-chunks", forKey: .type); try container.encode(time0, forKey: .time0); try container.encode(index, forKey: .index); try container.encode(dt, forKey: .dt); try container.encode(id, forKey: .id); try container.encodeIfPresent(name, forKey: .name); try container.encode(args, forKey: .args)
        case .chunk(let time, let chunk):
            try container.encode("chunk", forKey: .type); try container.encode(time, forKey: .time); try container.encode(chunk, forKey: .chunk)
        }
    }
}

public typealias SessionMessageStream = [SessionMessageStreamRecord]
/// Short name used by session event payloads; the wire shape remains unchanged.
public typealias SessionStreamRecord = SessionMessageStreamRecord

public enum SessionMessageStreamError: Error, Sendable, Equatable {
    case emptyRun
    case deltaCountMismatch
    case invalidIndex
    case timestampOverflow
}

public extension SessionMessageStreamRecord {
    /// Expands one compact record while preserving each fragment and timestamp.
    func expanded() throws -> [SessionMessageStreamTimedChunk] {
        switch self {
        case .chunk(let time, let chunk): return [.init(time: time, chunk: chunk)]
        case .textChunks(let time0, let index, let dt, let texts):
            return try expandRun(time0: time0, index: index, dt: dt, members: texts) { .textDelta(index: index, text: $0) }
        case .reasoningChunks(let time0, let index, let dt, let texts):
            return try expandRun(time0: time0, index: index, dt: dt, members: texts) { .reasoningDelta(index: index, text: $0) }
        case .toolCallChunks(let time0, let index, let dt, let id, let name, let args):
            return try expandRun(time0: time0, index: index, dt: dt, members: args) { .toolCallDelta(index: index, id: id, name: name, argumentsDelta: $0) }
        }
    }

    func validate() throws {
        let chunks = try expanded()
        for value in chunks { try value.chunk.validate() }
    }

    private func expandRun(time0: Int, index: Int, dt: [Int], members: [String], make: (String) -> SessionMessageStreamChunk) throws -> [SessionMessageStreamTimedChunk] {
        guard !members.isEmpty else { throw SessionMessageStreamError.emptyRun }
        guard dt.count == members.count - 1 else { throw SessionMessageStreamError.deltaCountMismatch }
        guard index >= 0 else { throw SessionMessageStreamError.invalidIndex }
        var time = time0
        var result: [SessionMessageStreamTimedChunk] = []
        result.reserveCapacity(members.count)
        for (position, member) in members.enumerated() {
            if position > 0 {
                let (next, overflow) = time.addingReportingOverflow(dt[position - 1])
                guard !overflow else { throw SessionMessageStreamError.timestampOverflow }
                time = next
            }
            result.append(.init(time: time, chunk: make(member)))
        }
        return result
    }
}

public extension Array where Element == SessionMessageStreamRecord {
    func expanded() throws -> [SessionMessageStreamTimedChunk] {
        try flatMap { try $0.expanded() }
    }

    func validate() throws {
        for value in self { try value.validate() }
    }
}
