import Foundation
import GRDB
import MiraCore

/// A domain adapter owns accepted I/O, while the composition root owns the shared database.
/// Session reads happen before these bounded transactions; only durable library authority lives here.
final class SQLiteDomainDatabase: @unchecked Sendable {
    let database: DatabaseQueue
    let libraryID: UUID
    private let io: DispatchQueue
    private let lock = NSLock()
    private var accepting = true
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(database: DatabaseQueue, libraryID: UUID, label: String) throws {
        self.database = database; self.libraryID = libraryID; io = DispatchQueue(label: label, qos: .utility)
        try database.read { try Self.requireDurability($0); try SQLiteLibraryAuthority.validateInitialized(in: $0, libraryID: libraryID) }
    }
    func read<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await enqueue { try self.database.read { db in
            _ = try SQLiteLibraryAuthority.availableAuthorization(in: db, libraryID: self.libraryID)
            return try body(db)
        } }
    }
    /// A narrowly scoped read used only while the exact persisted maintenance
    /// operation is pending. Ordinary reads remain blocked by the authority gate.
    func recoveryRead<T: Sendable>(for operation: AgentLibraryMaintenanceOperation,
                                   _ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try operation.validate()
        return try await enqueue { try self.database.read { db in
            try SQLiteLibraryAuthority.requirePending(operation, in: db, libraryID: self.libraryID)
            return try body(db)
        } }
    }
    func write<T: Sendable>(authorization: AgentLibraryAuthorization,
                           _ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await enqueue { try self.database.write { db in
            try Self.requireDurability(db)
            guard try SQLiteLibraryAuthority.availableAuthorization(in: db, libraryID: self.libraryID) == authorization else {
                throw MiraError(.unauthorized, "Business authorization is stale.")
            }
            return try body(db)
        } }
    }
    func close() async {
        await withCheckedContinuation { continuation in
            lock.lock(); accepting = false
            if active == 0 { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
    /// Maintenance owns a distinct admission boundary: ordinary reads and writes remain blocked.
    func maintain<T: Sendable>(_ operation: AgentLibraryMaintenanceOperation,
                              afterCommit: (@Sendable (T) throws -> Void)? = nil,
                              _ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try operation.validate()
        return try await enqueue {
            let result = try self.database.write { db in
                try Self.requireDurability(db)
                try SQLiteLibraryAuthority.requirePending(operation, in: db, libraryID: self.libraryID)
                return try body(db)
            }
            try afterCommit?(result)
            return result
        }
    }
    private func enqueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard lock.withLock({ if !accepting { return false }; active += 1; return true }) else {
            throw MiraError(.storage, "The business effect store is closed.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            io.async {
                let result: Result<T, any Error>
                do { result = .success(try body()) }
                catch { result = .failure(error as? MiraError ?? MiraError(.storage, "The business record is inconsistent.")) }
                self.lock.lock(); self.active -= 1
                let pending = self.active == 0 && !self.accepting ? self.waiters : []
                if !pending.isEmpty { self.waiters.removeAll() }
                self.lock.unlock(); pending.forEach { $0.resume() }
                continuation.resume(with: result)
            }
        }
    }
    static func requireDurability(_ db: Database) throws {
        guard [2, 3].contains(try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? 0),
              try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1 else {
            throw MiraError(.configuration, "The business database durability settings are insufficient.")
        }
    }
    static func initialize(_ definitions: [(String, String)], metadata: String, in db: Database) throws {
        try requireDurability(db)
        let present = try definitions.filter { try String.fetchOne(db, sql: "SELECT name FROM sqlite_master WHERE name = ?", arguments: [$0.0]) != nil }
        guard present.isEmpty || present.count == definitions.count else { throw invalidSchema }
        if present.isEmpty {
            for (_, sql) in definitions { try db.execute(sql: sql) }
            try db.execute(sql: "INSERT INTO \(metadata)(id, version) VALUES (1, 1)")
        }
        for (name, sql) in definitions {
            guard try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = ?", arguments: [name]) == sql else { throw invalidSchema }
        }
        guard try Int.fetchOne(db, sql: "SELECT count(*) FROM \(metadata)") == 1,
              try Int.fetchOne(db, sql: "SELECT version FROM \(metadata) WHERE id = 1") == 1 else { throw invalidSchema }
    }
    static var invalidSchema: MiraError { .init(.storage, "The business effect schema is unsupported.") }
}
