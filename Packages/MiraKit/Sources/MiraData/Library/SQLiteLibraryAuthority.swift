import Foundation
import CryptoKit
import GRDB
import MiraCore

public enum SQLiteLibraryAuthorityFaultPoint: Sendable {
    case afterBeginCommit, afterCompletionCommit
}

/// Durable library authorization and maintenance intent in the caller-owned business database.
/// Closing this adapter drains its accepted operations without closing the shared database.
public final class SQLiteLibraryAuthority: AgentLibraryMaintenanceStore, @unchecked Sendable {
    public let libraryID: UUID
    private let database: DatabaseQueue
    private let io = DispatchQueue(label: "mira.library-authority", qos: .userInitiated)
    private let afterCommit: (@Sendable (SQLiteLibraryAuthorityFaultPoint) throws -> Void)?
    private let validators: [AgentLibraryMaintenanceHandlerIdentity: SQLiteLibraryMaintenanceValidator]
    private let lock = NSLock()
    private var accepting = true
    private var active = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    var isClosing: Bool { lock.withLock { !accepting } }

    public init(database: DatabaseQueue,
                validators: [SQLiteLibraryMaintenanceValidator] = [],
                afterCommit: (@Sendable (SQLiteLibraryAuthorityFaultPoint) throws -> Void)? = nil) throws {
        guard validators.count <= 128, Set(validators.map(\.identity)).count == validators.count else {
            throw MiraError(.configuration, "The library maintenance validators are duplicated or exceed their limit.")
        }
        for validator in validators { try validator.identity.validate() }
        self.validators = Dictionary(uniqueKeysWithValues: validators.map { ($0.identity, $0) })
        self.database = database; self.afterCommit = afterCommit
        do {
            libraryID = try database.write { db in
                try Self.requireDurability(in: db)
                try Self.initialize(in: db)
                return try Self.readState(in: db).authorization.libraryID
            }
        } catch { throw Self.safe(error) }
    }

    public func state() async throws -> AgentLibraryMaintenanceState {
        try await perform { try self.database.read { try Self.readState(in: $0, libraryID: self.libraryID) } }
    }

    public func operation(id: UUID) async throws -> AgentLibraryMaintenanceOperation? {
        try await perform {
            try self.database.read { db in
                let state = try Self.readState(in: db, libraryID: self.libraryID)
                guard let operation = try Self.readOperation(id: id, in: db, libraryID: self.libraryID) else { return nil }
                guard operation.authorization.epoch <= state.authorization.epoch,
                      operation.completedAt != nil || state.pending == operation else { throw Self.corrupt }
                return operation
            }
        }
    }

    public func begin(_ request: AgentLibraryMaintenanceRequest,
                      expected: AgentLibraryAuthorization) async throws -> AgentLibraryMaintenanceOperation {
        try request.validate()
        guard expected.libraryID == libraryID else { throw Self.conflict }
        return try await perform {
            let result = try self.database.write { db -> (AgentLibraryMaintenanceOperation, Bool) in
                try Self.requireDurability(in: db)
                let state = try Self.readState(in: db, libraryID: self.libraryID)
                if let existing = try Self.readOperation(id: request.id, in: db, libraryID: self.libraryID) {
                    guard existing.request == request, existing.previousAuthorization == expected,
                          existing.authorization.epoch <= state.authorization.epoch else { throw Self.conflict }
                    return (existing, false)
                }
                guard state.pending == nil, state.authorization == expected else { throw Self.conflict }
                guard expected.epoch < UInt64.max else { throw Self.exhausted }
                let identity = AgentLibraryMaintenanceHandlerIdentity(namespace: request.namespace, revision: request.revision)
                if let validator = self.validators[identity] {
                    try validator.validate(request, db)
                } else if case .sources = request.scope {
                    throw MiraError(.configuration, "The source maintenance operation has no registered admission validator.")
                }
                let operation = AgentLibraryMaintenanceOperation(request: request, previousAuthorization: expected,
                    authorization: .init(libraryID: self.libraryID, epoch: expected.epoch + 1), completedAt: nil)
                let bytes = try Self.encode(operation)
                try db.execute(sql: """
                    INSERT INTO agent_library_maintenance(id, previous_epoch, epoch, phase, operation_json, digest)
                    VALUES (?, ?, ?, 'pending', ?, ?)
                    """, arguments: [request.id.uuidString, String(expected.epoch), String(operation.authorization.epoch), bytes, Self.digest(bytes)])
                try db.execute(sql: "UPDATE agent_library_metadata SET epoch = ?, current_operation_id = ? WHERE id = 1",
                               arguments: [String(operation.authorization.epoch), request.id.uuidString])
                return (operation, true)
            }
            if result.1 { try self.afterCommit?(.afterBeginCommit) }
            return result.0
        }
    }

    public func complete(_ operation: AgentLibraryMaintenanceOperation, at date: Date) async throws -> AgentLibraryMaintenanceOperation {
        try operation.validate()
        guard operation.authorization.libraryID == libraryID, date.timeIntervalSince1970.isFinite else { throw Self.conflict }
        return try await perform {
            let result = try self.database.write { db -> (AgentLibraryMaintenanceOperation, Bool) in
                try Self.requireDurability(in: db)
                let state = try Self.readState(in: db, libraryID: self.libraryID)
                guard let existing = try Self.readOperation(id: operation.request.id, in: db, libraryID: self.libraryID),
                      existing.request == operation.request,
                      existing.previousAuthorization == operation.previousAuthorization,
                      existing.authorization == operation.authorization else { throw Self.conflict }
                // Repeating an old completion must never reopen or clear a newer pending operation.
                if existing.completedAt != nil { return (existing, false) }
                guard state.pending == existing, state.authorization == existing.authorization,
                      operation.completedAt == nil else { throw Self.conflict }
                let completed = AgentLibraryMaintenanceOperation(request: existing.request,
                    previousAuthorization: existing.previousAuthorization, authorization: existing.authorization, completedAt: date)
                let bytes = try Self.encode(completed)
                try db.execute(sql: "UPDATE agent_library_maintenance SET phase = 'completed', operation_json = ?, digest = ? WHERE id = ?",
                               arguments: [bytes, Self.digest(bytes), existing.request.id.uuidString])
                return (completed, true)
            }
            if result.1 { try self.afterCommit?(.afterCompletionCommit) }
            return result.0
        }
    }

    public func close() async {
        await withCheckedContinuation { continuation in
            lock.lock(); accepting = false
            if active == 0 { lock.unlock(); continuation.resume() }
            else { closeWaiters.append(continuation); lock.unlock() }
        }
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let accepted = lock.withLock {
            guard accepting else { return false }
            active += 1; return true
        }
        guard accepted else { throw MiraError(.storage, "The library authority is closed.") }
        return try await withCheckedThrowingContinuation { continuation in
            io.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: Self.safe(error)) }
                self.finishOperation()
            }
        }
    }

    private func finishOperation() {
        lock.lock(); active -= 1
        guard active == 0, !accepting else { lock.unlock(); return }
        let waiters = closeWaiters; closeWaiters.removeAll(); lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    /// Other business adapters check this in the same SQL transaction as their mutation.
    static func availableAuthorization(in db: Database, libraryID: UUID) throws -> AgentLibraryAuthorization {
        let state = try readState(in: db, libraryID: libraryID)
        guard state.pending == nil else { throw MiraError(.unauthorized, "Library maintenance prevents new authorization.") }
        return state.authorization
    }

    static func requirePending(_ operation: AgentLibraryMaintenanceOperation, in db: Database, libraryID: UUID) throws {
        let state = try readState(in: db, libraryID: libraryID)
        guard operation.completedAt == nil, state.pending == operation else { throw conflict }
    }

    static func readState(in db: Database, libraryID expected: UUID? = nil) throws -> AgentLibraryMaintenanceState {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM agent_library_metadata WHERE id = 1"),
              (row["format_version"] as Int?) == 1,
              let idText: String = row["library_id"], let id = canonicalUUID(idText), expected == nil || expected == id,
              let epochText: String = row["epoch"], let epoch = canonicalEpoch(epochText) else { throw corrupt }
        let authorization = AgentLibraryAuthorization(libraryID: id, epoch: epoch)
        let currentID: String? = row["current_operation_id"]
        let pendingCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_library_maintenance WHERE phase = 'pending'")
        guard let pendingCount, (0...1).contains(pendingCount) else { throw corrupt }
        guard let currentID else {
            guard epoch == 0, pendingCount == 0,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_library_maintenance") == 0 else { throw corrupt }
            return .init(authorization: authorization, pending: nil)
        }
        guard let operationID = canonicalUUID(currentID),
              try String.fetchOne(db, sql: "SELECT id FROM agent_library_maintenance ORDER BY length(epoch) DESC, epoch DESC LIMIT 1") == currentID,
              let operation = try readOperation(id: operationID, in: db, libraryID: id),
              operation.authorization == authorization,
              pendingCount == (operation.completedAt == nil ? 1 : 0) else { throw corrupt }
        return .init(authorization: authorization, pending: operation.completedAt == nil ? operation : nil)
    }

    static func validateInitialized(in db: Database, libraryID: UUID) throws {
        try requireDurability(in: db)
        try validateSchema(in: db)
        _ = try readState(in: db, libraryID: libraryID)
    }

    static func readOperation(id: UUID, in db: Database, libraryID: UUID) throws -> AgentLibraryMaintenanceOperation? {
        guard let row = try Row.fetchOne(db, sql: "SELECT id, previous_epoch, epoch, phase, digest, length(operation_json) AS byte_count FROM agent_library_maintenance WHERE id = ?",
                                        arguments: [id.uuidString]) else { return nil }
        guard let count = row["byte_count"] as Int?, (1...SessionFormatLimits.maximumBatchBytes).contains(count),
              let bytes = try Data.fetchOne(db, sql: "SELECT operation_json FROM agent_library_maintenance WHERE id = ?", arguments: [id.uuidString]),
              bytes.count == count, digest(bytes) == (row["digest"] as String?) else { throw corrupt }
        let operation: AgentLibraryMaintenanceOperation
        do {
            operation = try SessionCodec.decode(AgentLibraryMaintenanceOperation.self, from: bytes)
            try operation.validate()
        } catch { throw corrupt }
        guard operation.request.id == id, operation.authorization.libraryID == libraryID,
              let previousText: String = row["previous_epoch"], canonicalEpoch(previousText) == operation.previousAuthorization.epoch,
              let epochText: String = row["epoch"], canonicalEpoch(epochText) == operation.authorization.epoch,
              (row["phase"] as String?) == (operation.completedAt == nil ? "pending" : "completed") else { throw corrupt }
        return operation
    }

    private static func initialize(in db: Database) throws {
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('agent_library_metadata', 'agent_library_maintenance')")
        if count == 0 {
            for (_, sql) in definitions { try db.execute(sql: sql) }
            try db.execute(sql: "INSERT INTO agent_library_metadata(id, format_version, library_id, epoch, current_operation_id) VALUES (1, 1, ?, '0', NULL)",
                           arguments: [UUID().uuidString])
        }
        try validateSchema(in: db)
    }

    private static func validateSchema(in db: Database) throws {
        for (name, sql) in definitions {
            guard let stored = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = ?", arguments: [name]),
                  canonicalSQL(stored) == canonicalSQL(sql) else { throw corrupt }
        }
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_library_metadata") == 1 else { throw corrupt }
    }

    static func archiveModule() throws -> SQLiteArchiveModule {
        try SQLiteArchiveModule(identity: .init(name: "library.authority", revision: 1),
            schemaStatements: definitions.map(\.1), restoration: .preserve) { db, _ in
                let state = try readState(in: db)
                guard state.pending == nil else { throw LibraryArchiveIO.invalid }
                let rows = try Row.fetchCursor(db, sql: "SELECT id FROM agent_library_maintenance ORDER BY length(epoch), epoch")
                var previous: UInt64 = 0
                var count = 0
                while let row = try rows.next() {
                    count += 1
                    guard count <= 100_000, let id = canonicalUUID(row["id"]),
                          let operation = try readOperation(id: id, in: db, libraryID: state.authorization.libraryID),
                          operation.previousAuthorization.epoch == previous, operation.completedAt != nil else {
                        throw LibraryArchiveIO.invalid
                    }
                    previous = operation.authorization.epoch
                }
                guard previous == state.authorization.epoch else { throw LibraryArchiveIO.invalid }
                return []
            }
    }

    private static let definitions: [(String, String)] = [
        ("agent_library_maintenance", """
        CREATE TABLE agent_library_maintenance (
          id TEXT PRIMARY KEY NOT NULL, previous_epoch TEXT NOT NULL, epoch TEXT NOT NULL UNIQUE,
          phase TEXT NOT NULL CHECK(phase IN ('pending', 'completed')), operation_json BLOB NOT NULL,
          digest TEXT NOT NULL, CHECK(length(operation_json) BETWEEN 1 AND 2097152))
        """),
        ("agent_library_metadata", """
        CREATE TABLE agent_library_metadata (
          id INTEGER PRIMARY KEY CHECK(id = 1), format_version INTEGER NOT NULL CHECK(format_version = 1),
          library_id TEXT NOT NULL UNIQUE, epoch TEXT NOT NULL, current_operation_id TEXT,
          FOREIGN KEY(current_operation_id) REFERENCES agent_library_maintenance(id))
        """),
        ("agent_library_maintenance_pending", "CREATE UNIQUE INDEX agent_library_maintenance_pending ON agent_library_maintenance(phase) WHERE phase = 'pending'"),
        ("agent_library_maintenance_latest", "CREATE INDEX agent_library_maintenance_latest ON agent_library_maintenance(length(epoch) DESC, epoch DESC)")
    ]
    private static func requireDurability(in db: Database) throws {
        let synchronous = try Int.fetchOne(db, sql: "PRAGMA synchronous")
        guard synchronous == 2 || synchronous == 3, try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1 else {
            throw MiraError(.configuration, "The library authority durability settings are insufficient.")
        }
    }
    private static func canonicalSQL(_ sql: String) -> String { sql.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private static func canonicalUUID(_ text: String) -> UUID? {
        guard let id = UUID(uuidString: text), id.uuidString == text else { return nil }; return id
    }
    private static func canonicalEpoch(_ text: String) -> UInt64? {
        guard let epoch = UInt64(text), String(epoch) == text else { return nil }; return epoch
    }
    private static func encode(_ operation: AgentLibraryMaintenanceOperation) throws -> Data {
        try operation.validate()
        let data = try SessionCodec.encode(operation)
        guard data.count <= SessionFormatLimits.maximumBatchBytes else {
            throw MiraError(.invalidInput, "The library maintenance record exceeds its storage limit.")
        }
        return data
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static var conflict: MiraError { .init(.conflict, "The library maintenance operation conflicts with current authority.") }
    private static var exhausted: MiraError { .init(.storage, "Library authorization has reached its limit.") }
    private static var corrupt: MiraError { .init(.storage, "The library authority metadata is invalid.") }
    private static func safe(_ error: any Error) -> MiraError {
        if error is CancellationError { return .init(.cancelled, "The library authority operation was cancelled.") }
        return (error as? MiraError) ?? .init(.storage, "The library authority operation failed.")
    }
}
