import Foundation

/// The physical records written by the DSH aligned session log.  The header is
/// outside the event sequence and therefore does not consume a `seq` value.
public struct SessionLogHeader: Codable, Sendable, Equatable {
    public let type: String
    public let version: Int
    public let id: String
    public let createdAt: Int
    public let cwd: String?
    public let isSeeded: Bool
    public let delegationDepth: Int

    public init(id: String, createdAt: Int, version: Int = 3, cwd: String? = nil,
                isSeeded: Bool = false, delegationDepth: Int = 0) {
        self.type = "session"; self.version = version; self.id = id
        self.createdAt = createdAt; self.cwd = cwd; self.isSeeded = isSeeded
        self.delegationDepth = delegationDepth
    }

    private enum CodingKeys: String, CodingKey {
        case type, version, id, createdAt, cwd, isSeeded, delegationDepth
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .type) == "session" else {
            throw SessionLogCodecError.invalidHeader
        }
        type = "session"; version = try c.decode(Int.self, forKey: .version)
        id = try c.decode(String.self, forKey: .id)
        createdAt = try c.decode(Int.self, forKey: .createdAt)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        isSeeded = try c.decode(Bool.self, forKey: .isSeeded)
        delegationDepth = try c.decode(Int.self, forKey: .delegationDepth)
        guard version > 0, !id.isEmpty, createdAt >= 0, delegationDepth >= 0 else {
            throw SessionLogCodecError.invalidHeader
        }
    }
}

public enum SessionLogRecord: Codable, Sendable, Equatable {
    case header(SessionLogHeader)
    case event(SessionLogEvent)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let header = try? c.decode(SessionLogHeader.self) { self = .header(header); return }
        self = .event(try c.decode(SessionLogEvent.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .header(let value): try c.encode(value)
        case .event(let value): try c.encode(value)
        }
    }
}

/// Disposable reconstruction state derived exclusively from preceding log records.
public struct SessionLogState: Codable, Sendable, Equatable {
    public var sessionID: ConversationID?
    public var nextSeq = 0
    public var nextInternalSequence: Int64 = 0
    public var header: SessionLogHeader?
    var turns: [ExecutionID: Int] = [:]
    var plans: [ExecutionID: AgentExecutionPlan] = [:]
    var attempts: [UUID: SessionAttempt] = [:]
    var invocations: [UUID: SessionInvocation] = [:]
    var messages: [String: MessageEntry] = [:]
    var routes: [String: RouteEntry] = [:]
    var headers: [String: HeaderEntry] = [:]
    var activeHeaderID: String?
    var activeSystemID: String?
    var contents: [UUID: ContentEntry] = [:]
    var userMessages: [ExecutionID: String] = [:]
    var streams: [Int: SessionMessageStream] = [:]
    var openSteps: [Int: Int] = [:]
    var toolCalls: [Int: CanonicalToolCall] = [:]
    var trace = SessionLogTrace()
    var tracePrefixes: [Int: SessionLogTrace] = [:]
    struct MessageEntry: Codable, Sendable, Equatable { let seq: Int; let message: SessionMessage }
    struct RouteEntry: Codable, Sendable, Equatable { let seq: Int; let route: AgentModelRoute }
    struct HeaderEntry: Codable, Sendable, Equatable { let seq: Int; let value: JSONValue }
    struct ContentEntry: Codable, Sendable, Equatable { let seq: Int; let value: SessionContent }
    public static var initial: Self { .init() }
    public func forBatch(nextSeq: Int, nextInternalSequence: Int64) throws -> Self {
        var state = self
        guard let trace = tracePrefixes[nextSeq] else { throw SessionLogCodecError.missingAssociation }
        state.trace = trace
        state.openSteps = trace.turn.flatMap { turn in trace.step.map { [turn: $0] } } ?? [:]
        state.nextSeq = nextSeq; state.nextInternalSequence = nextInternalSequence
        state.turns = [:]; state.plans = [:]; state.attempts = [:]; state.invocations = [:]
        // Operational facts are self-describing; canonical definitions remain
        // addressable, but every reference is checked against the read watermark.
        return state
    }
}

public enum SessionLogCodecError: Error, Sendable, Equatable {
    case invalidHeader, invalidSequence, invalidRelation, wrongSession, missingAssociation, unsupportedPayload, malformedTime, duplicateIdentity
}

public enum SessionLogCodec {
    public static func encode(_ batch: SessionBatch, previous: SessionLogState = .initial) throws
        -> (records: [SessionLogRecord], state: SessionLogState) {
        try batch.validate()
        guard previous.sessionID == nil || previous.sessionID == batch.sessionID,
              batch.expectedSequence == previous.nextInternalSequence else { throw SessionLogCodecError.invalidSequence }
        let writer = SessionLogWriter(state: previous)
        writer.state.tracePrefixes[previous.nextSeq] = previous.trace
        if writer.state.header == nil {
            guard case .opened = batch.events.first?.fact, let event = batch.events.first else { throw SessionLogCodecError.invalidHeader }
            let header = SessionLogHeader(id: batch.sessionID.rawValue.uuidString, createdAt: try logTime(event.occurredAt), version: 3)
            writer.state.header = header; writer.state.sessionID = batch.sessionID
            writer.records.append(.header(header))
        }
        for event in batch.events { try writer.write(event) }
        writer.state.nextInternalSequence = batch.cursor.sequence
        return (writer.records, writer.state)
    }

    public static func decode(_ records: [SessionLogRecord], batchID: UUID, sessionID: ConversationID,
                              previous: SessionLogState = .initial) throws -> (batch: SessionBatch, state: SessionLogState) {
        var reader = SessionLogReader(state: previous)
        reader.state.tracePrefixes[previous.nextSeq] = previous.trace
        var events: [SessionEvent] = []
        for record in records {
            switch record {
            case .header(let header):
                guard header.version == 3, header.id == sessionID.rawValue.uuidString,
                      header.createdAt >= 0, header.createdAt < 9_007_199_254_740_992, header.delegationDepth >= 0,
                      reader.state.header == nil || reader.state.header == header,
                      reader.state.nextSeq == 0 else { throw SessionLogCodecError.invalidHeader }
                reader.state.header = header; reader.state.sessionID = sessionID
            case .event(let event):
                try event.validate()
                guard reader.state.header != nil, event.seq == reader.state.nextSeq else { throw SessionLogCodecError.invalidSequence }
                if let fact = try reader.read(event) {
                    guard fact.sequence == reader.state.nextInternalSequence + 1 else { throw SessionLogCodecError.invalidSequence }
                    events.append(fact); reader.state.nextInternalSequence = fact.sequence
                }
                reader.state.nextSeq += 1
            }
        }
        guard reader.state.sessionID == sessionID, !events.isEmpty else { throw SessionLogCodecError.wrongSession }
        let batch = SessionBatch(id: batchID, sessionID: sessionID, expectedSequence: previous.nextInternalSequence, events: events)
        try batch.validate()
        return (batch, reader.state)
    }
}

func logJSON<T: Encodable>(_ value: T) throws -> JSONValue { try SessionCodec.decode(JSONValue.self, from: SessionCodec.encode(value)) }
func logDecode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T { try SessionCodec.decode(type, from: SessionCodec.encode(value)) }
func logTime(_ date: Date) throws -> Int {
    let value = date.timeIntervalSince1970 * 1_000
    guard value.isFinite, value >= 0, value < 9_007_199_254_740_992 else { throw SessionLogCodecError.malformedTime }
    return Int(value.rounded(.towardZero))
}
func logString(_ value: JSONValue?, _ key: String? = nil) throws -> String {
    let item = key.flatMap { value?[$0] } ?? value
    guard case .string(let text)? = item else { throw SessionLogCodecError.unsupportedPayload }; return text
}
func logInt(_ value: JSONValue?, _ key: String? = nil) throws -> Int {
    let item = key.flatMap { value?[$0] } ?? value
    guard case .number(let number)? = item, number.isFinite, number.rounded() == number,
          abs(number) < 9_007_199_254_740_992 else { throw SessionLogCodecError.unsupportedPayload }; return Int(number)
}
func logUUID(_ value: JSONValue?, _ key: String? = nil) throws -> UUID {
    guard let id = UUID(uuidString: try logString(value, key)) else { throw SessionLogCodecError.unsupportedPayload }; return id
}
func logSet(_ value: JSONValue, path: [String], to replacement: JSONValue) throws -> JSONValue {
    guard let first = path.first else { return replacement }
    switch value {
    case .object(var object):
        guard let old = object[first] else { throw SessionLogCodecError.missingAssociation }
        object[first] = try logSet(old, path: Array(path.dropFirst()), to: replacement); return .object(object)
    case .array(var array):
        guard let index = Int(first), array.indices.contains(index) else { throw SessionLogCodecError.missingAssociation }
        array[index] = try logSet(array[index], path: Array(path.dropFirst()), to: replacement); return .array(array)
    default: throw SessionLogCodecError.missingAssociation
    }
}
func logGet(_ value: JSONValue, path: [String]) throws -> JSONValue {
    guard let first = path.first else { return value }
    switch value {
    case .object(let object): guard let next = object[first] else { throw SessionLogCodecError.missingAssociation }; return try logGet(next, path: Array(path.dropFirst()))
    case .array(let array): guard let index = Int(first), array.indices.contains(index) else { throw SessionLogCodecError.missingAssociation }; return try logGet(array[index], path: Array(path.dropFirst()))
    default: throw SessionLogCodecError.missingAssociation
    }
}
