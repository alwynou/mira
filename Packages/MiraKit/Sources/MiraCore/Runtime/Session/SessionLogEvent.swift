import Foundation

/// A DSH surface placement operation carried by a message-producing event.
public enum SessionLogSurfaceOperation: Codable, Sendable, Equatable {
    case append
    case replace(startSeq: Int, endSeq: Int)

    private enum CodingKeys: String, CodingKey { case op, startSeq, endSeq }

    public init(from decoder: any Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self), value == "append" {
            self = .append
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .op) == "replace" else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Unsupported session surface operation."))
        }
        self = .replace(startSeq: try container.decode(Int.self, forKey: .startSeq),
                        endSeq: try container.decode(Int.self, forKey: .endSeq))
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .append:
            var value = encoder.singleValueContainer()
            try value.encode("append")
        case .replace(let startSeq, let endSeq):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("replace", forKey: .op)
            try container.encode(startSeq, forKey: .startSeq)
            try container.encode(endSeq, forKey: .endSeq)
        }
    }

    public func validate() throws {
        if case .replace(let startSeq, let endSeq) = self,
           startSeq < 0 || endSeq < startSeq {
            throw SessionLogEventError.invalidSurfaceOperation
        }
    }
}

public enum SessionLogEventError: Error, Sendable, Equatable {
    case invalidSurfaceOperation
    case invalidSequence
    case invalidTime
    case missingSurfaceOperation
    case invalidSourceReferences
    case unsupportedMiraEvent
}

public struct SessionLogToolError: Codable, Sendable, Equatable {
    public let name: String
    public let code: String
    public let reason: String?

    public init(name: String, code: String, reason: String? = nil) {
        self.name = name; self.code = code; self.reason = reason
    }
}

public enum SessionLogCancellationReason: Codable, Sendable, Equatable {
    case user
    case parent
    case hook(reason: String)
    case disposed

    private enum CodingKeys: String, CodingKey { case kind, reason }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "user": self = .user
        case "parent": self = .parent
        case "hook": self = .hook(reason: try c.decode(String.self, forKey: .reason))
        case "disposed": self = .disposed
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unsupported cancellation cause.")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user: try c.encode("user", forKey: .kind)
        case .parent: try c.encode("parent", forKey: .kind)
        case .hook(let reason): try c.encode("hook", forKey: .kind); try c.encode(reason, forKey: .reason)
        case .disposed: try c.encode("disposed", forKey: .kind)
        }
    }
}

public enum SessionLogTurnEndReason: Codable, Sendable, Equatable {
    case completed
    case blocked
    case maxTokens
    case interrupted
    case aborted(reason: SessionLogCancellationReason)
    case error(error: JSONValue)

    private enum CodingKeys: String, CodingKey { case kind, reason, error }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "completed": self = .completed
        case "blocked": self = .blocked
        case "max-tokens": self = .maxTokens
        case "interrupted": self = .interrupted
        case "aborted":
            self = .aborted(reason: try container.decode(SessionLogCancellationReason.self, forKey: .reason))
        case "error":
            self = .error(error: try container.decode(JSONValue.self, forKey: .error))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                debugDescription: "Unsupported turn-end reason.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .completed: try container.encode("completed", forKey: .kind)
        case .blocked: try container.encode("blocked", forKey: .kind)
        case .maxTokens: try container.encode("max-tokens", forKey: .kind)
        case .interrupted: try container.encode("interrupted", forKey: .kind)
        case .aborted(let reason):
            try container.encode("aborted", forKey: .kind); try container.encode(reason, forKey: .reason)
        case .error(let error):
            try container.encode("error", forKey: .kind); try container.encode(error, forKey: .error)
        }
    }
}

/// Typed payloads for the DSH shared event names. Mira extension facts remain
/// opaque JSON until their own contract is installed by the runtime layer.
public enum SessionLogEventData: Codable, Sendable, Equatable {
    case turnStart(turn: Int)
    case stepStart(turn: Int, step: Int)
    case systemMessage(turn: Int, step: Int, message: SessionMessage)
    case userMessage(SessionMessage)
    case requestHeader(header: JSONValue, reason: String, startsSeries: Bool? = nil)
    case requestContext(provider: String, model: String, contextWindow: Int? = nil, systemPromptUpdate: String? = nil)
    case assistantMessage(turn: Int, step: Int, message: SessionMessage, stream: SessionMessageStream,
                          usage: SessionMessageUsage? = nil, interrupted: Bool? = nil)
    case assistantAttempt(turn: Int, step: Int, stream: SessionMessageStream)
    case toolCall(turn: Int, step: Int, callID: String, name: String, arguments: String)
    case toolResult(turn: Int, step: Int, message: SessionMessage, error: SessionLogToolError? = nil, meta: JSONValue? = nil)
    case stepEnd(turn: Int, step: Int)
    case turnEnd(turn: Int, reason: SessionLogTurnEndReason)
    /// Mira-owned operational facts use explicit registered names and a typed
    /// JSON value body. The registry prevents arbitrary unknown extensions from
    /// being accepted as required reconstruction facts.
    case mira(name: String, data: JSONValue)
    case unknown(type: String, data: JSONValue)

    fileprivate enum CodingKeys: String, CodingKey {
        case turn, step, message, header, reason, startsSeries, provider, model, contextWindow, systemPromptUpdate
        case stream, usage, interrupted, callId, name, arguments, error, meta, type, data
        case id, role, content, source
    }

    public var eventType: String {
        switch self {
        case .turnStart: return "turn/start"
        case .stepStart: return "step/start"
        case .systemMessage: return "system/message"
        case .userMessage: return "user/message"
        case .requestHeader: return "request/header"
        case .requestContext: return "request/context"
        case .assistantMessage: return "assistant/message"
        case .assistantAttempt: return "assistant/attempt"
        case .toolCall: return "tool/call"
        case .toolResult: return "tool/result"
        case .stepEnd: return "step/end"
        case .turnEnd: return "turn/end"
        case .mira(let name, _): return name
        case .unknown(let type, _): return type
        }
    }

    public func validate() throws {
        switch self {
        case .turnStart(let turn): guard turn > 0 else { throw SessionLogEventError.invalidSequence }
        case .stepStart(let turn, let step), .stepEnd(let turn, let step):
            guard turn > 0, step > 0 else { throw SessionLogEventError.invalidSequence }
        case .systemMessage(let turn, let step, let message):
            guard turn > 0, step > 0, message.role == .system else { throw SessionLogEventError.invalidSequence }
            try message.validate()
        case .userMessage(let message):
            guard message.role == .user else { throw SessionLogEventError.invalidSequence }
            try message.validate()
        case .requestHeader(_, let reason, _):
            guard ["initial", "resume", "change", "series"].contains(reason) else { throw SessionLogEventError.invalidSequence }
        case .requestContext(let provider, let model, let contextWindow, _):
            guard !provider.isEmpty, !model.isEmpty, contextWindow.map({ $0 > 0 }) ?? true else { throw SessionLogEventError.invalidSequence }
        case .assistantMessage(let turn, let step, let message, let stream, _, let interrupted):
            guard turn > 0, step > 0, message.role == .assistant, interrupted != false else { throw SessionLogEventError.invalidSequence }
            try message.validate(); try stream.validate()
        case .assistantAttempt(let turn, let step, let stream):
            guard turn > 0, step > 0 else { throw SessionLogEventError.invalidSequence }; try stream.validate()
        case .toolCall(let turn, let step, let callID, let name, let arguments):
            guard turn > 0, step > 0, !callID.isEmpty, !name.isEmpty, !arguments.isEmpty else { throw SessionLogEventError.invalidSequence }
        case .toolResult(let turn, let step, let message, _, _):
            guard turn > 0, step > 0, message.role == .user else { throw SessionLogEventError.invalidSequence }
            try message.validate()
        case .turnEnd(let turn, _): guard turn > 0 else { throw SessionLogEventError.invalidSequence }
        case .mira(let name, _): guard Self.supportedMiraNames.contains(name) else { throw SessionLogEventError.unsupportedMiraEvent }
        case .unknown: break
        }
    }

    fileprivate static let supportedMiraNames: Set<String> = [
        "mira/session-opened", "mira/session-renamed", "mira/session-archived",
        "mira/model-selection", "mira/route-snapshot", "mira/turn-admitted", "mira/phase-changed",
        "mira/request-start", "mira/attempt-resolved", "mira/tool-proposed",
        "mira/tool-prepared", "mira/tool-approval-requested", "mira/tool-approval-resolved",
        "mira/tool-dispatched", "mira/tool-resolved",
        "mira/turn-finished", "mira/turn-retry", "mira/extension",
    ]

    fileprivate static func isKnown(_ type: String) -> Bool {
        ["turn/start", "step/start", "system/message", "user/message", "request/header",
         "request/context", "assistant/message", "assistant/attempt", "tool/call",
         "tool/result", "step/end", "turn/end"].contains(type)
    }

    public init(from decoder: any Decoder) throws {
        // The event decoder supplies the type through this private envelope.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        self = try Self.decode(type: type, from: container)
    }

    fileprivate static func decode(type: String, from container: KeyedDecodingContainer<CodingKeys>) throws -> Self {
        switch type {
        case "turn/start": return .turnStart(turn: try container.decode(Int.self, forKey: .turn))
        case "step/start": return .stepStart(turn: try container.decode(Int.self, forKey: .turn), step: try container.decode(Int.self, forKey: .step))
        case "system/message": return .systemMessage(turn: try container.decode(Int.self, forKey: .turn), step: try container.decode(Int.self, forKey: .step), message: try container.decode(SessionMessage.self, forKey: .message))
        case "user/message":
            return .userMessage(SessionMessage(id: try container.decode(SessionMessageID.self, forKey: .id),
                                               role: try container.decode(SessionMessage.Role.self, forKey: .role),
                                               content: try container.decode([SessionMessageContent].self, forKey: .content),
                                               source: try container.decode(SessionMessageSource.self, forKey: .source)))
        case "request/header": return .requestHeader(header: try container.decode(JSONValue.self, forKey: .header), reason: try container.decode(String.self, forKey: .reason), startsSeries: try container.decodeIfPresent(Bool.self, forKey: .startsSeries))
        case "request/context": return .requestContext(provider: try container.decode(String.self, forKey: .provider), model: try container.decode(String.self, forKey: .model), contextWindow: try container.decodeIfPresent(Int.self, forKey: .contextWindow), systemPromptUpdate: try container.decodeIfPresent(String.self, forKey: .systemPromptUpdate))
        case "assistant/message": return .assistantMessage(turn: try container.decode(Int.self, forKey: .turn), step: try container.decode(Int.self, forKey: .step), message: try container.decode(SessionMessage.self, forKey: .message), stream: try container.decode(SessionMessageStream.self, forKey: .stream), usage: try container.decodeIfPresent(SessionMessageUsage.self, forKey: .usage), interrupted: try container.decodeIfPresent(Bool.self, forKey: .interrupted))
        case "assistant/attempt": return .assistantAttempt(turn: try container.decode(Int.self, forKey: .turn), step: try container.decode(Int.self, forKey: .step), stream: try container.decode(SessionMessageStream.self, forKey: .stream))
        case "tool/call": return .toolCall(turn: try container.decode(Int.self, forKey: .turn), step: try container.decode(Int.self, forKey: .step), callID: try container.decode(String.self, forKey: .callId), name: try container.decode(String.self, forKey: .name), arguments: try container.decode(String.self, forKey: .arguments))
        case "tool/result": return .toolResult(turn: try container.decode(Int.self, forKey: .turn), step: try container.decode(Int.self, forKey: .step), message: try container.decode(SessionMessage.self, forKey: .message), error: try container.decodeIfPresent(SessionLogToolError.self, forKey: .error), meta: try container.decodeIfPresent(JSONValue.self, forKey: .meta))
        case "step/end": return .stepEnd(turn: try container.decode(Int.self, forKey: .turn), step: try container.decode(Int.self, forKey: .step))
        case "turn/end": return .turnEnd(turn: try container.decode(Int.self, forKey: .turn), reason: try container.decode(SessionLogTurnEndReason.self, forKey: .reason))
        default:
            if supportedMiraNames.contains(type) {
                return .mira(name: type, data: try JSONValue(from: container.superDecoder()))
            }
            throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath,
                debugDescription: "Session event data has no known type."))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        // This method is used only for direct payload encoding. SessionLogEvent
        // supplies the type discriminator and calls encodePayload below.
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventType, forKey: .type)
        try encodePayload(into: &container)
    }

    fileprivate func encodePayload(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch self {
        case .turnStart(let turn): try container.encode(turn, forKey: .turn)
        case .stepStart(let turn, let step), .stepEnd(let turn, let step):
            try container.encode(turn, forKey: .turn); try container.encode(step, forKey: .step)
        case .systemMessage(let turn, let step, let message):
            try container.encode(turn, forKey: .turn); try container.encode(step, forKey: .step); try container.encode(message, forKey: .message)
        case .userMessage(let message):
            try container.encode(message.id, forKey: .id)
            try container.encode(message.role, forKey: .role)
            try container.encode(message.content, forKey: .content)
            try container.encode(message.source, forKey: .source)
        case .requestHeader(let header, let reason, let startsSeries):
            try container.encode(header, forKey: .header); try container.encode(reason, forKey: .reason); try container.encodeIfPresent(startsSeries, forKey: .startsSeries)
        case .requestContext(let provider, let model, let contextWindow, let systemPromptUpdate):
            try container.encode(provider, forKey: .provider); try container.encode(model, forKey: .model); try container.encodeIfPresent(contextWindow, forKey: .contextWindow); try container.encodeIfPresent(systemPromptUpdate, forKey: .systemPromptUpdate)
        case .assistantMessage(let turn, let step, let message, let stream, let usage, let interrupted):
            try container.encode(turn, forKey: .turn); try container.encode(step, forKey: .step); try container.encode(message, forKey: .message); try container.encode(stream, forKey: .stream); try container.encodeIfPresent(usage, forKey: .usage); try container.encodeIfPresent(interrupted, forKey: .interrupted)
        case .assistantAttempt(let turn, let step, let stream):
            try container.encode(turn, forKey: .turn); try container.encode(step, forKey: .step); try container.encode(stream, forKey: .stream)
        case .toolCall(let turn, let step, let callID, let name, let arguments):
            try container.encode(turn, forKey: .turn); try container.encode(step, forKey: .step); try container.encode(callID, forKey: .callId); try container.encode(name, forKey: .name); try container.encode(arguments, forKey: .arguments)
        case .toolResult(let turn, let step, let message, let error, let meta):
            try container.encode(turn, forKey: .turn); try container.encode(step, forKey: .step); try container.encode(message, forKey: .message); try container.encodeIfPresent(error, forKey: .error); try container.encodeIfPresent(meta, forKey: .meta)
        case .turnEnd(let turn, let reason): try container.encode(turn, forKey: .turn); try container.encode(reason, forKey: .reason)
        case .mira(_, let data): try container.encode(data, forKey: .data)
        case .unknown(_, let data): try container.encode(data, forKey: .data)
        }
    }

    fileprivate func encodeUnknownData(to encoder: any Encoder) throws {
        guard case .unknown(_, let data) = self else { return }
        try data.encode(to: encoder)
    }
}

/// One logical DSH event. `seq` is zero-based and `time` is Unix epoch ms.
public struct SessionLogEvent: Codable, Sendable, Equatable {
    public let type: String
    public let seq: Int
    public let time: Int
    public let data: SessionLogEventData
    public let surfaceOp: SessionLogSurfaceOperation?
    public let sourceEventSeqs: [Int]?
    public let ignorable: Bool?

    public init(seq: Int, time: Int, data: SessionLogEventData,
                surfaceOp: SessionLogSurfaceOperation? = nil,
                sourceEventSeqs: [Int]? = nil, ignorable: Bool? = nil) {
        self.type = data.eventType; self.seq = seq; self.time = time; self.data = data
        self.surfaceOp = surfaceOp; self.sourceEventSeqs = sourceEventSeqs; self.ignorable = ignorable
    }

    public func validate() throws {
        guard seq >= 0, seq < 9_007_199_254_740_992 else { throw SessionLogEventError.invalidSequence }
        guard time >= 0, time < 9_007_199_254_740_992 else { throw SessionLogEventError.invalidTime }
        try data.validate()
        if let surfaceOp { try surfaceOp.validate() }
        let requiresSurface = ["system/message", "user/message", "assistant/message", "tool/result"].contains(type)
        if requiresSurface && surfaceOp == nil { throw SessionLogEventError.missingSurfaceOperation }
        if !requiresSurface && (surfaceOp != nil || sourceEventSeqs != nil) { throw SessionLogEventError.invalidSurfaceOperation }
        if case .replace(let start, let end) = surfaceOp {
            guard end < seq, sourceEventSeqs?.contains(start) == true,
                  sourceEventSeqs?.contains(end) == true else { throw SessionLogEventError.invalidSourceReferences }
        }
        if let references = sourceEventSeqs {
            guard type != "assistant/message", type != "assistant/attempt",
                  !references.isEmpty, references.allSatisfy({ $0 >= 0 && $0 < seq }) else {
                throw SessionLogEventError.invalidSourceReferences
            }
        }
        if ignorable == false { throw SessionLogEventError.invalidSequence }
    }

    private enum CodingKeys: String, CodingKey { case type, seq, time, data, surfaceOp, sourceEventSeqs, ignorable }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        seq = try container.decode(Int.self, forKey: .seq)
        time = try container.decode(Int.self, forKey: .time)
        surfaceOp = try container.decodeIfPresent(SessionLogSurfaceOperation.self, forKey: .surfaceOp)
        sourceEventSeqs = try container.decodeIfPresent([Int].self, forKey: .sourceEventSeqs)
        ignorable = try container.decodeIfPresent(Bool.self, forKey: .ignorable)
        let dataDecoder = try container.superDecoder(forKey: .data)
        if SessionLogEventData.isKnown(type) {
            let dataContainer = try dataDecoder.container(keyedBy: SessionLogEventData.CodingKeys.self)
            data = try SessionLogEventData.decode(type: type, from: dataContainer)
        } else if SessionLogEventData.supportedMiraNames.contains(type) {
            data = .mira(name: type, data: try JSONValue(from: dataDecoder))
        } else if ignorable == true {
            data = .unknown(type: type, data: try JSONValue(from: dataDecoder))
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Unknown required session event \(type)."))
        }
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type); try container.encode(seq, forKey: .seq); try container.encode(time, forKey: .time)
        try container.encodeIfPresent(surfaceOp, forKey: .surfaceOp); try container.encodeIfPresent(sourceEventSeqs, forKey: .sourceEventSeqs); try container.encodeIfPresent(ignorable, forKey: .ignorable)
        if case .unknown = data {
            try data.encodeUnknownData(to: container.superEncoder(forKey: .data))
        } else if case .mira(_, let miraData) = data {
            try miraData.encode(to: container.superEncoder(forKey: .data))
        } else {
            var dataContainer = container.nestedContainer(keyedBy: SessionLogEventData.CodingKeys.self, forKey: .data)
            try data.encodePayload(into: &dataContainer)
        }
    }
}

public enum SessionLogEventCodec {
    public static func encode(_ event: SessionLogEvent) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(event)
    }

    public static func decode(_ data: Data) throws -> SessionLogEvent {
        try JSONDecoder().decode(SessionLogEvent.self, from: data)
    }
}
