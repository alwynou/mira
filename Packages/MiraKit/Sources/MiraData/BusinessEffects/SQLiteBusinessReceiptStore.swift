import Foundation
import GRDB
import MiraCore

/// Read/publication access to business receipts for an offline-restored library.
/// It never resolves intents, invokes handlers, or commits a business operation.
public final class SQLiteBusinessReceiptStore: AgentBusinessReceipts, @unchecked Sendable {
    private let database: DatabaseQueue
    private let libraryID: UUID
    private let resolver: JournalAgentEffectResolver
    private let io = DispatchQueue(label: "mira.business-receipts", qos: .utility)
    private let lock = NSLock()
    private var accepting = true
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        database: DatabaseQueue, libraryID: UUID, journal: any SessionJournal,
        payloads: any SessionContentReader, extensionSchemas: [String: Set<Int>] = [:]
    ) throws {
        self.database = database
        self.libraryID = libraryID
        self.resolver = JournalAgentEffectResolver(
            journal: journal, payloads: payloads, extensionSchemas: extensionSchemas)
        do {
            let schema = try SQLiteBusinessEffects.archiveModule().schema
            try database.read { db in
                try SQLiteDomainDatabase.requireDurability(db)
                try SQLiteLibraryAuthority.validateInitialized(in: db, libraryID: libraryID)
                guard try Int.fetchOne(db, sql: "SELECT count(*) FROM business_effects_metadata") == 1,
                    try Int.fetchOne(db, sql: "SELECT format_version FROM business_effects_metadata WHERE id = 1") == 2
                else { throw MiraError(.unsupported, "The business receipt schema is unsupported.") }
                let owned = Set(SQLiteBusinessEffects.archiveTableNames)
                guard try SQLiteArchiveSchemaObject.read(in: db).filter({ owned.contains($0.table) }) == schema else {
                    throw Self.corrupt
                }
            }
        } catch { throw Self.safe(error) }
    }

    public func fenceExecution(sessionID: ConversationID, executionID: ExecutionID) async throws {
        try await write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO business_fences(session_id, execution_id) VALUES (?, ?)",
                arguments: [sessionID.rawValue.uuidString, executionID.rawValue.uuidString])
        }
    }

    public func receipt(for proof: AgentEffectProof) async -> AgentBusinessReceiptLookup {
        guard begin() else { return .unavailable(Self.closed) }
        defer { finish() }
        do {
            try SQLiteBusinessEffects.validateProof(proof)
            guard proof.authorization.libraryID == self.libraryID else {
                throw MiraError(.unauthorized, "Business authorization is stale.")
            }
            return try await enqueueOwned {
                try self.database.read { db in
                    guard let row = try SQLiteBusinessEffects.receiptRow(invocationID: proof.invocationID, in: db)
                    else { return .absent }
                    guard (row["library_id"] as String?) == self.libraryID.uuidString,
                        try SQLiteBusinessEffects.decode(AgentEffectProof.self, row["proof_json"]) == proof
                    else {
                        return .unavailable(.init(.conflict, "The business receipt proof does not match."))
                    }
                    return .committed(try SQLiteBusinessEffects.receipt(row, in: db))
                }
            }
        } catch { return .unavailable(Self.safe(error)) }
    }

    public func unpublished(after receiptID: UUID?, limit: Int) async throws -> [AgentReceiptPublication] {
        guard (1...1_000).contains(limit) else {
            throw MiraError(.invalidInput, "The publication page size is invalid.")
        }
        return try await read { db in
            let sequence: Int64
            if let receiptID {
                guard
                    let value = try Int64.fetchOne(
                        db, sql: "SELECT sequence FROM business_receipts WHERE id = ?",
                        arguments: [receiptID.uuidString])
                else {
                    throw MiraError(.notFound, "The business publication cursor is unavailable.")
                }
                sequence = value
            } else {
                sequence = 0
            }
            return try Row.fetchAll(
                db,
                sql:
                    "SELECT * FROM business_receipts WHERE acknowledged = 0 AND sequence > ? ORDER BY sequence LIMIT ?",
                arguments: [sequence, limit]
            ).map { row in
                guard (row["library_id"] as String?) == self.libraryID.uuidString else { throw Self.corrupt }
                let proof = try SQLiteBusinessEffects.decode(AgentEffectProof.self, row["proof_json"])
                let receipt = try SQLiteBusinessEffects.receipt(row, in: db)
                try SQLiteBusinessEffects.validateProof(proof)
                guard proof.authorization.libraryID == self.libraryID,
                    proof.authorization == receipt.reference.authorization,
                    proof.invocationID == receipt.reference.invocationID,
                    proof.proposal.digest == receipt.reference.intentDigest
                else { throw Self.corrupt }
                return .init(proof: proof, receipt: receipt)
            }
        }
    }

    public func acknowledge(_ receipt: AgentBusinessReceiptReference, at cursor: SessionCursor) async throws {
        guard begin() else { throw Self.closed }
        defer { finish() }
        try receipt.validate()
        guard receipt.authorization.libraryID == libraryID else {
            throw MiraError(.unauthorized, "Business authorization is stale.")
        }
        try await resolver.validatePublication(receipt, at: cursor)
        try await writeOwned { db in
            guard let row = try SQLiteBusinessEffects.receiptRow(invocationID: receipt.invocationID, in: db),
                (row["library_id"] as String?) == self.libraryID.uuidString,
                try SQLiteBusinessEffects.receipt(row, in: db).reference == receipt,
                try SQLiteBusinessEffects.decode(AgentEffectProof.self, row["proof_json"]).sessionID == cursor.sessionID
            else {
                throw MiraError(.conflict, "The business receipt does not match its publication acknowledgement.")
            }
            try db.execute(
                sql: "UPDATE business_receipts SET acknowledged = 1, publication_json = ? WHERE id = ?",
                arguments: [try SQLiteBusinessEffects.encode(cursor), receipt.id.uuidString])
        }
    }

    public func close() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            accepting = false
            if active == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func read<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await enqueue { try self.database.read(body) }
    }
    private func write<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await enqueue { try self.database.write(body) }
    }
    private func writeOwned<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await enqueueOwned { try self.database.write(body) }
    }
    private func enqueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        guard begin() else { throw Self.closed }
        defer { finish() }
        return try await enqueueOwned(body)
    }
    private func enqueueOwned<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            io.async {
                let result: Result<T, Error>
                do { result = .success(try body()) } catch { result = .failure(Self.safe(error)) }
                continuation.resume(with: result)
            }
        }
    }
    private func begin() -> Bool {
        lock.withLock {
            guard accepting else { return false }
            active += 1
            return true
        }
    }
    private func finish() {
        lock.lock()
        active -= 1
        let pending = active == 0 && !accepting ? waiters : []
        if !pending.isEmpty { waiters.removeAll() }
        lock.unlock()
        pending.forEach { $0.resume() }
    }
    private static func safe(_ error: Error) -> MiraError {
        error as? MiraError ?? .init(.storage, "The business receipt store could not access its database.")
    }
    private static let corrupt = MiraError(.storage, "The business receipt metadata is invalid.")
    private static let closed = MiraError(.cancelled, "The business receipt store is closed.")
}
