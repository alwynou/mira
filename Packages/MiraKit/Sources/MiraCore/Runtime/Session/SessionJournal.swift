import Foundation

/// Operational bounds are checked before allocation and before durable publication.
public enum SessionFormatLimits {
    public static let version = 4
    public static let maximumBatchBytes = 2 * 1_024 * 1_024
    public static let maximumEventsPerBatch = 256
    public static let maximumPayloadBytes = 32 * 1_024 * 1_024
    public static let maximumReadBatches = 128
}

public enum SessionPayloadKind: String, Codable, Sendable {
    case title, userText, visibleAnswer, visibleThinking, executionPlan, request, modelOutput
    case toolCall, effectIntent, toolResult, replay, draft, error, module
}

public enum SessionPayloadStorage: String, Codable, Sendable {
    case inline, external
}

/// The digest describes bytes, not authorization. Retention groups never deduplicate each other.
public struct SessionPayloadReference: Codable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let sessionID: ConversationID
    public let batchID: UUID
    public let retentionGroup: UUID
    public let kind: SessionPayloadKind
    public let byteCount: Int
    public let digest: String
    public let storage: SessionPayloadStorage

    public init(id: UUID, sessionID: ConversationID, batchID: UUID, retentionGroup: UUID,
                kind: SessionPayloadKind, byteCount: Int, digest: String, storage: SessionPayloadStorage = .inline) {
        self.id = id; self.sessionID = sessionID; self.batchID = batchID
        self.retentionGroup = retentionGroup; self.kind = kind
        self.byteCount = byteCount; self.digest = digest; self.storage = storage
    }

    public func validate() throws {
        guard (0...SessionFormatLimits.maximumPayloadBytes).contains(byteCount), digest.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw MiraError(.storage, "The session payload reference is invalid.")
        }
    }
}

public struct SessionCursor: Codable, Sendable, Equatable {
    public let sessionID: ConversationID
    public let sequence: Int64
    public init(sessionID: ConversationID, sequence: Int64) {
        self.sessionID = sessionID; self.sequence = sequence
    }
}

/// An immutable committed prefix boundary. A sequence alone must not identify a different batch.
public struct SessionJournalHead: Codable, Sendable, Equatable {
    public let cursor: SessionCursor
    public let batchID: UUID?
    public init(cursor: SessionCursor, batchID: UUID?) { self.cursor = cursor; self.batchID = batchID }
    public func validate() throws {
        guard cursor.sequence >= 0, (cursor.sequence == 0) == (batchID == nil) else {
            throw MiraError(.storage, "The session journal head is invalid.")
        }
    }
}

public struct SessionEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sequence: Int64
    public let occurredAt: Date
    public let fact: SessionFact
    public init(id: UUID = UUID(), sequence: Int64, occurredAt: Date, fact: SessionFact) {
        self.id = id; self.sequence = sequence
        // Journal timestamps have millisecond precision, shared by all persistence adapters.
        let seconds = occurredAt.timeIntervalSince1970
        self.occurredAt = seconds.isFinite ? Date(timeIntervalSince1970: (seconds * 1_000).rounded() / 1_000) : occurredAt
        self.fact = fact
    }
}

/// One committed transaction publishes all events or none. The caller retains it across uncertainty.
public struct SessionBatch: Codable, Sendable, Equatable, Identifiable {
    public let version: Int
    public let id: UUID
    public let sessionID: ConversationID
    public let expectedSequence: Int64
    public let events: [SessionEvent]
    public var cursor: SessionCursor {
        .init(sessionID: sessionID, sequence: events.last?.sequence ?? expectedSequence)
    }

    public init(id: UUID, sessionID: ConversationID, expectedSequence: Int64, events: [SessionEvent]) {
        version = SessionFormatLimits.version; self.id = id; self.sessionID = sessionID
        self.expectedSequence = expectedSequence; self.events = events
    }

    public func validate() throws {
        guard version == SessionFormatLimits.version, expectedSequence >= 0,
              !events.isEmpty, events.count <= SessionFormatLimits.maximumEventsPerBatch,
              expectedSequence <= Int64.max - Int64(events.count),
              Set(events.map(\.id)).count == events.count else {
            throw MiraError(.storage, "The session batch envelope is invalid or unsupported.")
        }
        for (offset, event) in events.enumerated() {
            guard event.sequence == expectedSequence + Int64(offset) + 1,
                  event.occurredAt.timeIntervalSince1970.isFinite else {
                throw MiraError(.storage, "The session event sequence is invalid.")
            }
            for reference in event.fact.payloadReferences {
                try reference.validate()
                guard reference.sessionID == sessionID else {
                    throw MiraError(.storage, "A session cannot reference another session's private payload.")
                }
            }
        }
    }
}

public enum SessionAppendOutcome: Sendable, Equatable {
    case committed(SessionCursor)
    case notCommitted(MiraError)
    case indeterminate(MiraError)
}

/// No method may report success until its durability barrier has completed.
public protocol SessionJournal: Sendable {
    func append(_ batch: SessionBatch) async -> SessionAppendOutcome
    /// Resolve the original immutable batch, never dispatch a model or tool as part of recovery.
    func reconcile(_ batch: SessionBatch) async -> SessionAppendOutcome
    func batch(id: UUID, sessionID: ConversationID) async throws -> SessionBatch?
    /// Captures only committed records whose durability barrier has completed.
    /// Uncertain records remain excluded until reconciliation establishes their publication.
    /// An unopened session has sequence zero and no batch identity.
    func head(sessionID: ConversationID) async throws -> SessionJournalHead
    func read(sessionID: ConversationID, after sequence: Int64, limit: Int) async throws -> [SessionBatch]
    /// Canonical session IDs in strictly increasing UUID string order, excluding `after`.
    /// Return at most `limit` IDs; an empty page ends the scan. A later sweep discovers
    /// sessions inserted before the cursor. Projections cannot supply this inventory.
    func sessions(after: ConversationID?, limit: Int) async throws -> [ConversationID]
    func flush() async throws
    func close() async throws
}

public protocol SessionPayloadReader: Sendable {
    func read(_ reference: SessionPayloadReference) async throws -> Data
}

public protocol SessionPayloadStore: SessionPayloadReader {
    /// Staged bytes remain unreadable until a valid committed batch references them.
    func stage(_ data: Data, sessionID: ConversationID, batchID: UUID,
               retentionGroup: UUID, kind: SessionPayloadKind) async throws -> SessionPayloadReference
    /// Requires committed privacy invalidation facts for the selected groups before physical deletion.
    /// Logical retry retirement remains readable only as unavailable history until this explicit cleanup.
    func purge(sessionID: ConversationID, retentionGroups: Set<UUID>) async throws
}

public enum SessionCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
