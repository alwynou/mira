import Foundation

/// Revision changes require an explicit domain decision; they never silently reset a business cursor.
public struct AgentSessionConsumerIdentity: Codable, Hashable, Sendable {
    public let id: String
    public let revision: Int
    public init(id: String, revision: Int) { self.id = id; self.revision = revision }
    public func validate() throws {
        guard SessionState.validIdentifier(id, maximumBytes: 128), revision > 0 else {
            throw MiraError(.configuration, "The session consumer identity is invalid.")
        }
    }
}

/// A business checkpoint belongs to the same transaction as the consumer's local effects.
/// It is not query data and cannot be reset by rebuilding a session projection.
public struct AgentSessionConsumerCheckpoint: Codable, Sendable, Equatable {
    public let consumer: AgentSessionConsumerIdentity
    public let head: SessionJournalHead
    public init(consumer: AgentSessionConsumerIdentity, head: SessionJournalHead) {
        self.consumer = consumer; self.head = head
    }
    public func validate() throws { try consumer.validate(); try head.validate() }
}

/// One whole committed batch. References establish provenance, not present permission to use content.
public struct AgentSessionConsumerDelivery: Sendable, Equatable {
    public let consumer: AgentSessionConsumerIdentity
    public let previous: SessionJournalHead
    public let batch: SessionBatch
    public init(consumer: AgentSessionConsumerIdentity, previous: SessionJournalHead, batch: SessionBatch) {
        self.consumer = consumer; self.previous = previous; self.batch = batch
    }
    public var checkpoint: AgentSessionConsumerCheckpoint {
        .init(consumer: consumer, head: .init(cursor: batch.cursor, batchID: batch.id))
    }
    public func validate() throws {
        try consumer.validate(); try previous.validate(); try batch.validate()
        guard previous.cursor.sessionID == batch.sessionID, previous.cursor.sequence == batch.expectedSequence,
              previous.batchID != batch.id,
              try SessionCodec.encode(batch).count <= SessionFormatLimits.maximumBatchBytes else {
            throw MiraError(.storage, "The session consumer delivery is invalid.")
        }
    }
}

/// Implementations atomically commit local domain effects and the complete batch checkpoint.
/// No model, external side effect, or UI callback may execute as part of consumption. Enqueue a
/// durable domain job instead; its claim and final commit must revalidate current source authority.
/// A thrown commit result may be uncertain. checkpoint must wait for any original write to drain,
/// so the next invocation can discover the committed cursor instead of repeating effects blindly.
public protocol AgentSessionConsumer: Sendable {
    var identity: AgentSessionConsumerIdentity { get }
    func checkpoint(sessionID: ConversationID) async throws -> AgentSessionConsumerCheckpoint?
    func consume(_ delivery: AgentSessionConsumerDelivery) async throws -> AgentSessionConsumerCheckpoint
}

public struct AgentSessionConsumerProgress: Sendable, Equatable {
    public let checkpoint: AgentSessionConsumerCheckpoint
    public let target: SessionJournalHead
    public let processedBatches: Int
    public var hasMore: Bool { checkpoint.head.cursor.sequence < target.cursor.sequence }
}

/// Owns finite passes, one batch at a time. The caller schedules fair passes over sessions;
/// notifications are only wake-ups, never the durable delivery mechanism.
public actor AgentSessionConsumerCoordinator {
    private struct Key: Hashable { let consumerID: String; let sessionID: ConversationID }
    private struct Owner { let id: UUID; let task: Task<AgentSessionConsumerProgress, Error> }
    private let journal: any SessionJournal
    private let registry: RuntimeRegistry<AgentCapability>
    private let extensionSchemas: [String: Set<Int>]
    private let maximumConcurrentPasses: Int
    private var owners: [Key: Owner] = [:]
    private var closed = false
    private var closeTask: Task<Void, Never>?

    public init(journal: any SessionJournal, registry: RuntimeRegistry<AgentCapability>,
                extensionSchemas: [String: Set<Int>] = [:], maximumConcurrentPasses: Int = 32) throws {
        guard (1...128).contains(maximumConcurrentPasses) else {
            throw MiraError(.configuration, "The session consumer concurrency limit is invalid.")
        }
        self.journal = journal; self.registry = registry; self.extensionSchemas = extensionSchemas
        self.maximumConcurrentPasses = maximumConcurrentPasses
    }

    public func advance(consumerID: String, sessionID: ConversationID,
                        maximumBatches: Int = 32) async throws -> AgentSessionConsumerProgress {
        try requireOpen()
        let target = try await journal.head(sessionID: sessionID)
        return try await advance(consumerID: consumerID, through: target, maximumBatches: maximumBatches)
    }

    /// A captured prefix never grows during a pass. Returning hasMore lets the caller yield to other sessions.
    public func advance(consumerID: String, through target: SessionJournalHead,
                        maximumBatches: Int = 32) async throws -> AgentSessionConsumerProgress {
        try requireOpen(); try target.validate()
        guard SessionState.validIdentifier(consumerID, maximumBytes: 128),
              (1...SessionFormatLimits.maximumReadBatches).contains(maximumBatches) else {
            throw MiraError(.invalidInput, "The session consumer pass limits are invalid.")
        }
        let key = Key(consumerID: consumerID, sessionID: target.cursor.sessionID)
        while let owner = owners[key] {
            // Cancellation of a waiter does not abandon the original domain transaction.
            _ = try await owner.task.value
            if owners[key]?.id == owner.id { owners.removeValue(forKey: key) }
            try requireOpen()
        }
        guard owners.count < maximumConcurrentPasses else {
            throw MiraError(.busy, "Too many session consumers are being updated.")
        }
        let id = UUID(), journal = journal, registry = registry, schemas = extensionSchemas
        let task = Task {
            let snapshot = try await registry.freeze()
            let catalog: AgentRuntimeCatalog
            do { catalog = try AgentRuntimeCatalog(snapshot: snapshot) }
            catch { await snapshot.release(); throw error }
            do {
                let consumer = try catalog.consumer(id: consumerID)
                let progress = try await Self.replay(consumer: consumer, through: target,
                    maximumBatches: maximumBatches, journal: journal, extensionSchemas: schemas)
                await catalog.release()
                return progress
            } catch { await catalog.release(); throw error }
        }
        owners[key] = .init(id: id, task: task)
        do {
            let result = try await task.value
            if owners[key]?.id == id { owners.removeValue(forKey: key) }
            try Task.checkCancellation()
            return result
        } catch {
            if owners[key]?.id == id { owners.removeValue(forKey: key) }
            throw error
        }
    }

    /// Stop this coordinator before disposing modules or closing journal/domain adapters.
    public func close() async {
        if let closeTask { await closeTask.value; return }
        closed = true
        let tasks = owners.values.map(\.task)
        tasks.forEach { $0.cancel() }
        let task = Task { for task in tasks { _ = try? await task.value } }
        closeTask = task
        await task.value
        owners.removeAll()
    }

    private func requireOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw MiraError(.cancelled, "The session consumer coordinator is closed.") }
    }

    private nonisolated static func replay(consumer: any AgentSessionConsumer, through target: SessionJournalHead,
        maximumBatches: Int, journal: any SessionJournal, extensionSchemas: [String: Set<Int>]) async throws -> AgentSessionConsumerProgress {
        try await validate(target, journal: journal)
        try Task.checkCancellation()
        let identity = consumer.identity
        var checkpoint = try await consumer.checkpoint(sessionID: target.cursor.sessionID)
            ?? .init(consumer: identity, head: .init(cursor: .init(sessionID: target.cursor.sessionID, sequence: 0), batchID: nil))
        try checkpoint.validate()
        guard checkpoint.consumer == identity, checkpoint.head.cursor.sessionID == target.cursor.sessionID else {
            throw invalidCheckpoint
        }
        try await validate(checkpoint.head, journal: journal)
        var processed = 0
        while checkpoint.head.cursor.sequence < target.cursor.sequence, processed < maximumBatches {
            try Task.checkCancellation()
            let page = try await journal.read(sessionID: target.cursor.sessionID,
                                              after: checkpoint.head.cursor.sequence, limit: 1)
            guard page.count == 1, let batch = page.first,
                  batch.cursor.sequence <= target.cursor.sequence else { throw invalidCheckpoint }
            let delivery = AgentSessionConsumerDelivery(consumer: identity, previous: checkpoint.head, batch: batch)
            try delivery.validate()
            if batch.cursor.sequence == target.cursor.sequence, batch.id != target.batchID { throw invalidCheckpoint }
            for event in batch.events {
                if case .extensionRecorded(let namespace, let version, let required, _) = event.fact,
                   required, extensionSchemas[namespace]?.contains(version) != true {
                    throw MiraError(.configuration, "The session consumer requires an unavailable extension schema.")
                }
            }
            let committed = try await consumer.consume(delivery)
            guard committed == delivery.checkpoint else { throw invalidCheckpoint }
            checkpoint = committed; processed += 1
        }
        return .init(checkpoint: checkpoint, target: target, processedBatches: processed)
    }

    private nonisolated static func validate(_ head: SessionJournalHead, journal: any SessionJournal) async throws {
        try head.validate()
        let acknowledged = try await journal.head(sessionID: head.cursor.sessionID)
        try acknowledged.validate()
        guard acknowledged.cursor.sessionID == head.cursor.sessionID,
              head.cursor.sequence <= acknowledged.cursor.sequence else { throw invalidCheckpoint }
        if head.cursor.sequence == acknowledged.cursor.sequence, head != acknowledged { throw invalidCheckpoint }
        guard let batchID = head.batchID else { return }
        guard let batch = try await journal.batch(id: batchID, sessionID: head.cursor.sessionID),
              batch.id == batchID, batch.cursor == head.cursor else { throw invalidCheckpoint }
        try batch.validate()
    }

    private static var invalidCheckpoint: MiraError {
        .init(.storage, "The session consumer checkpoint does not match the committed journal.")
    }
}
