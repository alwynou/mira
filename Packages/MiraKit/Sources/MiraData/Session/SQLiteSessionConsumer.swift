import CryptoKit
import Foundation
import GRDB
import MiraCore

/// Synchronous domain work performed inside the consumer transaction.
public protocol SQLiteSessionConsumerTransaction: Sendable {
    func apply(in db: Database) throws
    func close() async
}

public protocol SQLiteSessionConsumerHandler: Sendable {
    func prepare(_ delivery: AgentSessionConsumerDelivery) async throws -> any SQLiteSessionConsumerTransaction
}

/// A durable consumer checkpoint backed by the caller-owned business database.
/// The database is never closed by this adapter.
public final class SQLiteSessionConsumer: AgentSessionConsumer, @unchecked Sendable {
    public let identity: AgentSessionConsumerIdentity
    private let database: DatabaseQueue
    private let handler: any SQLiteSessionConsumerHandler
    private let afterCommitHook: (@Sendable () throws -> Void)?
    private let io = DispatchQueue(label: "mira.session-consumer", qos: .utility)
    private let stateLock = NSLock()
    private var accepting = true
    private var inFlight = 0
    private var preparations: [UUID: Task<any SQLiteSessionConsumerTransaction, any Error>] = [:]
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    /// The admission fence is published before close waits for outstanding I/O.
    internal var isClosing: Bool { stateLock.withLock { !accepting } }

    public init(
        database: DatabaseQueue, identity: AgentSessionConsumerIdentity,
        handler: any SQLiteSessionConsumerHandler,
        afterCommitHook: (@Sendable () throws -> Void)? = nil
    ) throws {
        try identity.validate()
        self.database = database
        self.identity = identity
        self.handler = handler
        self.afterCommitHook = afterCommitHook
        do {
            let synchronous = try database.read { db in try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? 0 }
            guard synchronous == 2 || synchronous == 3 else {
                throw MiraError(.configuration, "The session consumer requires durable database synchronization.")
            }
            try database.write { db in
                try Self.initialize(db)
                if let row = try Row.fetchOne(
                    db, sql: "SELECT revision FROM mira_session_consumers WHERE consumer_id = ?",
                    arguments: [identity.id])
                {
                    guard let revision: Int = row["revision"], revision == identity.revision else {
                        throw Self.identityConflict
                    }
                } else {
                    try db.execute(
                        sql: "INSERT INTO mira_session_consumers(consumer_id, revision) VALUES (?, ?)",
                        arguments: [identity.id, identity.revision])
                }
            }
        } catch { throw Self.safe(error) }
    }

    public func checkpoint(sessionID: ConversationID) async throws -> AgentSessionConsumerCheckpoint? {
        try await enqueue { db in try self.readCheckpoint(sessionID: sessionID, in: db)?.checkpoint }
    }

    public func consume(_ delivery: AgentSessionConsumerDelivery) async throws -> AgentSessionConsumerCheckpoint {
        try delivery.validate()
        guard delivery.consumer == identity else { throw Self.identityConflict }
        try beginOperation()
        do {
            let digest = Self.digest(try SessionCodec.encode(delivery.batch))
            if let stored = try await databaseRead({ db in
                try self.readCheckpoint(sessionID: delivery.batch.sessionID, in: db)
            }) {
                if stored.checkpoint.head == delivery.checkpoint.head {
                    guard stored.digest == digest else { throw Self.conflict }
                    self.finishInFlight()
                    return stored.checkpoint
                }
                guard stored.checkpoint.head == delivery.previous else { throw Self.conflict }
            } else {
                guard delivery.previous.cursor.sequence == 0, delivery.previous.batchID == nil else {
                    throw Self.conflict
                }
            }

            let preparationID = UUID()
            let preparation = Task.detached { [handler] in try await handler.prepare(delivery) }
            let cancelPreparation = stateLock.withLock {
                preparations[preparationID] = preparation
                return !accepting
            }
            if cancelPreparation { preparation.cancel() }
            let transaction: any SQLiteSessionConsumerTransaction
            do {
                transaction = try await withTaskCancellationHandler(
                    operation: { try await preparation.value }, onCancel: {})
            } catch {
                _ = stateLock.withLock { preparations.removeValue(forKey: preparationID) }
                throw error
            }
            _ = stateLock.withLock { preparations.removeValue(forKey: preparationID) }
            let result: Consumption
            do {
                result = try await databaseWrite { db -> Consumption in
                    let latest = try self.readCheckpoint(sessionID: delivery.batch.sessionID, in: db)
                    if let latest, latest.checkpoint.head == delivery.checkpoint.head {
                        guard latest.digest == digest else { throw Self.conflict }
                        return Consumption(checkpoint: latest.checkpoint, didWrite: false)
                    }
                    if let latest {
                        guard latest.checkpoint.head == delivery.previous else { throw Self.conflict }
                    } else {
                        guard delivery.previous.cursor.sequence == 0, delivery.previous.batchID == nil else {
                            throw Self.conflict
                        }
                    }
                    try transaction.apply(in: db)
                    try self.requireIdentity(in: db)
                    let session = Self.sessionID(delivery.batch.sessionID)
                    if latest != nil {
                        try db.execute(
                            sql:
                                "UPDATE mira_session_consumer_checkpoints SET head_sequence = ?, head_batch_id = ?, batch_digest = ? WHERE consumer_id = ? AND session_id = ? AND revision = ?",
                            arguments: [
                                delivery.batch.cursor.sequence, delivery.batch.id.uuidString, digest, self.identity.id,
                                session, self.identity.revision,
                            ])
                        guard db.changesCount == 1 else { throw Self.conflict }
                    } else {
                        try db.execute(
                            sql:
                                "INSERT INTO mira_session_consumer_checkpoints(consumer_id, session_id, revision, head_sequence, head_batch_id, batch_digest) VALUES (?, ?, ?, ?, ?, ?)",
                            arguments: [
                                self.identity.id, session, self.identity.revision, delivery.batch.cursor.sequence,
                                delivery.batch.id.uuidString, digest,
                            ])
                    }
                    return Consumption(checkpoint: delivery.checkpoint, didWrite: true)
                }
                if result.didWrite { do { try afterCommitHook?() } catch { throw Self.uncertain } }
            } catch {
                await transaction.close()
                throw error
            }
            await transaction.close()
            self.finishInFlight()
            return result.checkpoint
        } catch {
            self.finishInFlight()
            throw Self.safe(error)
        }
    }

    private func databaseRead<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            io.async {
                do { continuation.resume(returning: try self.database.read(body)) } catch {
                    continuation.resume(throwing: Self.safe(error))
                }
            }
        }
    }
    private func databaseWrite<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            io.async {
                do { continuation.resume(returning: try self.database.write(body)) } catch {
                    continuation.resume(throwing: Self.safe(error))
                }
            }
        }
    }

    private struct Consumption: Sendable {
        let checkpoint: AgentSessionConsumerCheckpoint
        let didWrite: Bool
    }
    private struct StoredCheckpoint: Sendable {
        let checkpoint: AgentSessionConsumerCheckpoint
        let digest: String
    }

    private func requireIdentity(in db: Database) throws {
        guard
            let revision = try Int.fetchOne(
                db, sql: "SELECT revision FROM mira_session_consumers WHERE consumer_id = ?",
                arguments: [identity.id]), revision == identity.revision
        else { throw Self.identityConflict }
    }

    private func readCheckpoint(sessionID: ConversationID, in db: Database) throws -> StoredCheckpoint? {
        try requireIdentity(in: db)
        guard
            let row = try Row.fetchOne(
                db,
                sql:
                    "SELECT revision, head_sequence, head_batch_id, batch_digest FROM mira_session_consumer_checkpoints WHERE consumer_id = ? AND session_id = ?",
                arguments: [identity.id, Self.sessionID(sessionID)])
        else { return nil }
        guard let revision: Int = row["revision"], revision == identity.revision else { throw Self.identityConflict }
        guard let sequence: Int64 = row["head_sequence"], sequence > 0,
            let rawID: String = row["head_batch_id"], let batchID = UUID(uuidString: rawID),
            let digest: String = row["batch_digest"], Self.validDigest(digest)
        else { throw Self.invalidData }
        let checkpoint = AgentSessionConsumerCheckpoint(
            consumer: identity,
            head: .init(cursor: .init(sessionID: sessionID, sequence: sequence), batchID: batchID))
        try checkpoint.validate()
        return .init(checkpoint: checkpoint, digest: digest)
    }

    public func close() async {
        await withCheckedContinuation { continuation in
            stateLock.lock()
            guard accepting else {
                if inFlight == 0 {
                    stateLock.unlock()
                    continuation.resume()
                    return
                }
                closeWaiters.append(continuation)
                stateLock.unlock()
                return
            }
            accepting = false
            let preparations = Array(self.preparations.values)
            if inFlight == 0 {
                stateLock.unlock()
                continuation.resume()
                return
            }
            closeWaiters.append(continuation)
            stateLock.unlock()
            for preparation in preparations { preparation.cancel() }
        }
    }

    private func enqueue<T: Sendable>(
        write: Bool = false, afterCommit: (@Sendable (T) throws -> Void)? = nil,
        _ body: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        try beginOperation()
        return try await withCheckedThrowingContinuation { continuation in
            io.async {
                defer { self.finishInFlight() }
                do {
                    let value = try write ? self.database.write(body) : self.database.read(body)
                    try afterCommit?(value)
                    continuation.resume(returning: value)
                } catch { continuation.resume(throwing: Self.safe(error)) }
            }
        }
    }

    private func beginOperation() throws {
        stateLock.lock()
        guard accepting else {
            stateLock.unlock()
            throw Self.closed
        }
        inFlight += 1
        stateLock.unlock()
    }

    private func finishInFlight() {
        stateLock.lock()
        inFlight -= 1
        guard inFlight == 0, !accepting else {
            stateLock.unlock()
            return
        }
        let waiters = closeWaiters
        closeWaiters.removeAll()
        stateLock.unlock()
        waiters.forEach { $0.resume() }
    }

    static let archiveSchemaStatements: [String] = [
        "CREATE TABLE mira_session_consumer_schema (id INTEGER PRIMARY KEY CHECK(id = 1), version INTEGER NOT NULL CHECK(version = 1))",
        "INSERT INTO mira_session_consumer_schema(id, version) VALUES (1, 1)",
        "CREATE TABLE mira_session_consumers (consumer_id TEXT PRIMARY KEY, revision INTEGER NOT NULL CHECK(revision > 0))",
        "CREATE TABLE mira_session_consumer_checkpoints (consumer_id TEXT NOT NULL, session_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0), head_sequence INTEGER NOT NULL CHECK(head_sequence > 0), head_batch_id TEXT NOT NULL, batch_digest TEXT NOT NULL CHECK(length(batch_digest) = 64), PRIMARY KEY(consumer_id, session_id), FOREIGN KEY(consumer_id) REFERENCES mira_session_consumers(consumer_id))",
    ]

    static func initialize(_ db: Database) throws {
        let exists = try db.tableExists("mira_session_consumer_schema")
        if exists {
            guard
                let version = try Int.fetchOne(
                    db, sql: "SELECT version FROM mira_session_consumer_schema WHERE id = 1"), version == 1,
                try db.tableExists("mira_session_consumers"), try db.tableExists("mira_session_consumer_checkpoints")
            else { throw unsupported }
            return
        }
        for statement in archiveSchemaStatements { try db.execute(sql: statement) }
    }

    private static func sessionID(_ value: ConversationID) -> String { value.rawValue.uuidString }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func safe(_ error: Error) -> MiraError {
        error as? MiraError ?? MiraError(.storage, "The session consumer could not access its business database.")
    }
    private static let invalidData = MiraError(.storage, "The session consumer data is invalid.")
    private static let unsupported = MiraError(.unsupported, "The session consumer schema is unsupported.")
    private static let identityConflict = MiraError(
        .conflict, "The session consumer identity conflicts with its stored revision.")
    private static let conflict = MiraError(
        .conflict, "The session consumer checkpoint conflicts with the delivered batch.")
    private static let uncertain = MiraError(.storage, "The session consumer commit outcome is uncertain.")
    private static let closed = MiraError(.cancelled, "The session consumer is closed.")
}
