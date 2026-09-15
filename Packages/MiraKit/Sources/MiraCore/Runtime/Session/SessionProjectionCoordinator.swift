import Foundation

/// Owns finite query catch-up tasks. Notification delivery and caller lifetimes do not own replay.
public actor SessionProjectionCoordinator {
    private struct Owner {
        let id: UUID
        let task: Task<SessionJournalHead, Error>
    }
    private let journal: any SessionJournal
    private let projection: any SessionProjectionStore
    private let extensionSchemas: [String: Set<Int>]
    private let maximumConcurrentSessions: Int
    private var owners: [ConversationID: Owner] = [:]
    private var closed = false
    private var closeTask: Task<Void, Never>?

    public init(journal: any SessionJournal, projection: any SessionProjectionStore,
                extensionSchemas: [String: Set<Int>] = [:], maximumConcurrentSessions: Int = 64) throws {
        guard (1...128).contains(maximumConcurrentSessions) else {
            throw MiraError(.configuration, "The session projection concurrency limit is invalid.")
        }
        self.journal = journal; self.projection = projection; self.extensionSchemas = extensionSchemas
        self.maximumConcurrentSessions = maximumConcurrentSessions
    }

    /// Captures one acknowledged head; concurrent appends do not extend this operation indefinitely.
    public func catchUp(sessionID: ConversationID) async throws -> SessionJournalHead {
        try requireOpen()
        let head = try await journal.head(sessionID: sessionID)
        return try await catchUp(through: head)
    }

    /// Ensures at least this verified prefix. An already newer valid projection is not rolled back.
    public func catchUp(through head: SessionJournalHead) async throws -> SessionJournalHead {
        try await perform(through: head, rebuilding: false)
    }

    /// Explicitly discards only query data. It cannot reset business consumer checkpoints.
    public func rebuild(sessionID: ConversationID) async throws -> SessionJournalHead {
        try requireOpen()
        let head = try await journal.head(sessionID: sessionID)
        return try await perform(through: head, rebuilding: true)
    }

    /// The host closes the projection and journal adapters only after this drain completes.
    public func close() async {
        if let closeTask { await closeTask.value; return }
        closed = true
        let tasks = owners.values.map(\.task)
        for task in tasks { task.cancel() }
        let closeTask = Task { for task in tasks { _ = try? await task.value } }
        self.closeTask = closeTask
        await closeTask.value
        owners.removeAll()
    }

    private func perform(through head: SessionJournalHead, rebuilding: Bool) async throws -> SessionJournalHead {
        try requireOpen(); try head.validate()
        let sessionID = head.cursor.sessionID
        while let owner = owners[sessionID] {
            // The original owner always drains. A cancelled waiter must not cancel shared replay.
            do { _ = try await owner.task.value }
            catch { if !rebuilding { throw error } }
            if owners[sessionID]?.id == owner.id { owners.removeValue(forKey: sessionID) }
            try requireOpen()
        }
        guard owners.count < maximumConcurrentSessions else {
            throw MiraError(.conflict, "Too many session projections are being updated.")
        }
        let journal = journal, projection = projection, schemas = extensionSchemas
        let id = UUID()
        let task = Task {
            try await Self.replay(through: head, rebuilding: rebuilding, journal: journal,
                                  projection: projection, extensionSchemas: schemas)
        }
        owners[sessionID] = .init(id: id, task: task)
        do {
            let result = try await task.value
            if owners[sessionID]?.id == id { owners.removeValue(forKey: sessionID) }
            try Task.checkCancellation()
            return result
        } catch {
            if owners[sessionID]?.id == id { owners.removeValue(forKey: sessionID) }
            throw error
        }
    }

    private func requireOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw MiraError(.cancelled, "The session projection coordinator is closed.") }
    }

    private nonisolated static func replay(through target: SessionJournalHead, rebuilding: Bool,
        journal: any SessionJournal, projection: any SessionProjectionStore,
        extensionSchemas: [String: Set<Int>]) async throws -> SessionJournalHead {
        try await validate(target, journal: journal)
        try Task.checkCancellation()
        if rebuilding { try await projection.reset(sessionID: target.cursor.sessionID) }
        var checkpoint = try await projection.head(sessionID: target.cursor.sessionID)
            ?? .init(cursor: .init(sessionID: target.cursor.sessionID, sequence: 0), batchID: nil)
        guard checkpoint.cursor.sessionID == target.cursor.sessionID else { throw invalidCheckpoint }
        try await validate(checkpoint, journal: journal)
        if checkpoint.cursor.sequence >= target.cursor.sequence { return checkpoint }

        while checkpoint.cursor.sequence < target.cursor.sequence {
            try Task.checkCancellation()
            let page = try await journal.read(sessionID: target.cursor.sessionID, after: checkpoint.cursor.sequence,
                                              limit: SessionFormatLimits.maximumReadBatches)
            guard !page.isEmpty, page.count <= SessionFormatLimits.maximumReadBatches else { throw invalidCheckpoint }
            for batch in page {
                try Task.checkCancellation(); try batch.validate()
                guard batch.sessionID == target.cursor.sessionID, batch.expectedSequence == checkpoint.cursor.sequence,
                      batch.cursor.sequence <= target.cursor.sequence else { throw invalidCheckpoint }
                if batch.cursor.sequence == target.cursor.sequence, batch.id != target.batchID { throw invalidCheckpoint }
                for event in batch.events {
                    if case .extensionRecorded(let namespace, let version, let required, _) = event.fact,
                       required, extensionSchemas[namespace]?.contains(version) != true {
                        throw MiraError(.configuration, "The session projection requires an unavailable extension schema.")
                    }
                }
                try await projection.apply(batch)
                checkpoint = .init(cursor: batch.cursor, batchID: batch.id)
                if checkpoint.cursor.sequence == target.cursor.sequence { return checkpoint }
            }
        }
        return checkpoint
    }

    private nonisolated static func validate(_ head: SessionJournalHead, journal: any SessionJournal) async throws {
        try head.validate()
        guard let batchID = head.batchID else { return }
        guard let batch = try await journal.batch(id: batchID, sessionID: head.cursor.sessionID),
              batch.cursor == head.cursor, batch.id == batchID else { throw invalidCheckpoint }
        try batch.validate()
    }

    private static var invalidCheckpoint: MiraError {
        .init(.storage, "The session projection checkpoint does not match the committed journal.")
    }
}
