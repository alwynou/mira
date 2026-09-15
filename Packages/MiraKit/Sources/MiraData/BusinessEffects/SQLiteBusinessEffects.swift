import Foundation
import CryptoKit
import GRDB
import MiraCore

public protocol SQLiteBusinessCommandHandler: Sendable {
    var namespace: String { get }
    func businessKey(for effect: AgentResolvedEffect) throws -> String
    func apply(effect: AgentResolvedEffect, in db: Database) throws -> JSONValue
}

public protocol SQLiteBusinessAuthorizationValidator: Sendable {
    /// Authorization and sources remain current for replay; target CAS rules can account for the original committed mutation.
    func validate(effect: AgentResolvedEffect, isReplay: Bool, in db: Database) throws
}

/// Owns one serial I/O queue. No handler can suspend inside the domain/receipt/outbox transaction.
public final class SQLiteBusinessEffects: AgentBusinessEffects, AgentEffectAuthority, @unchecked Sendable {
    private let database: DatabaseQueue
    private let libraryID: UUID
    private let io = DispatchQueue(label: "mira.business-effects", qos: .userInitiated)
    private let resolver: any AgentEffectIntentResolver
    private let handlers: [String: any SQLiteBusinessCommandHandler]
    private let validator: any SQLiteBusinessAuthorizationValidator
    private let afterCommitHook: (@Sendable () throws -> Void)?
    private let commits = BusinessCommitOwners()
    private let lifecycleLock = NSLock()
    private var accepting = true
    private var activeOperations = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false

    var isClosing: Bool { lifecycleLock.withLock { !accepting } }

    public init(database: DatabaseQueue, libraryID: UUID, resolver: any AgentEffectIntentResolver, handlers: [any SQLiteBusinessCommandHandler],
                validator: any SQLiteBusinessAuthorizationValidator, afterCommitHook: (@Sendable () throws -> Void)? = nil) throws {
        guard handlers.count <= 256, handlers.allSatisfy({ Self.validNamespace($0.namespace) }),
              Set(handlers.map(\.namespace)).count == handlers.count else {
            throw MiraError(.configuration, "Business effect handlers have invalid or duplicate namespaces.")
        }
        self.database = database; self.libraryID = libraryID
        self.resolver = resolver; self.handlers = Dictionary(uniqueKeysWithValues: handlers.map { ($0.namespace, $0) })
        self.validator = validator; self.afterCommitHook = afterCommitHook
        do {
            let synchronous = try database.read { db in try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? 0 }
            let foreignKeys = try database.read { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0 }
            guard synchronous == 2 || synchronous == 3, foreignKeys == 1 else {
                throw MiraError(.configuration, "The business database durability settings are insufficient.")
            }
            try database.write { db in
                try SQLiteLibraryAuthority.validateInitialized(in: db, libraryID: libraryID)
                try Self.initialize(db)
            }
        } catch { throw Self.safe(error) }
    }

    public func authorization(for proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentLibraryAuthorization {
        try proposal.validate()
        return try await read { db in
            let authorization = try SQLiteLibraryAuthority.availableAuthorization(in: db, libraryID: self.libraryID)
            try Self.requireUnfenced(context, in: db)
            try self.validator.validate(effect: .init(proposal: proposal, context: context), isReplay: false, in: db)
            return authorization
        }
    }

    public func validate(_ authorization: AgentLibraryAuthorization, proposal: AgentToolProposal, context: AgentToolContext) async throws {
        try proposal.validate()
        try await read { db in
            guard try SQLiteLibraryAuthority.availableAuthorization(in: db, libraryID: self.libraryID) == authorization else { throw MiraError(.unauthorized, "Business authorization is stale.") }
            try Self.requireUnfenced(context, in: db)
            try self.validator.validate(effect: .init(proposal: proposal, context: context), isReplay: false, in: db)
        }
    }

    public func fenceExecution(sessionID: ConversationID, executionID: ExecutionID) async throws {
        try await write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO business_fences(session_id, execution_id) VALUES (?, ?)",
                           arguments: [sessionID.rawValue.uuidString, executionID.rawValue.uuidString])
        }
    }

    /// The maintenance owner has already advanced the epoch and durably blocked new authorization.
    public func purgeResults(receiptIDs: Set<UUID>, maintenance: AgentLibraryMaintenanceOperation) async throws {
        guard receiptIDs.count <= 10_000 else { throw MiraError(.invalidInput, "Too many business receipts were selected.") }
        try maintenance.validate()
        try await write { db in
            try SQLiteLibraryAuthority.requirePending(maintenance, in: db, libraryID: self.libraryID)
            for id in receiptIDs {
                // Results exist only on the shared operation, so all associated receipts observe this purge.
                try db.execute(sql: """
                    UPDATE business_operations SET result_blob = NULL, result_purged = 1
                    WHERE (namespace, business_key) =
                      (SELECT operation_namespace, operation_key FROM business_receipts WHERE id = ?)
                    """, arguments: [id.uuidString])
            }
        }
    }

    public func commit(_ proof: AgentEffectProof) async -> AgentBusinessCommitOutcome {
        guard beginOperation() else { return .notCommitted(.init(.storage, "The business effect store is closed.")) }
        defer { finishOperation() }
        do { try Self.validateProof(proof); try Task.checkCancellation() }
        catch { return .notCommitted(Self.safe(error)) }
        return await commits.perform(proof) { await self.commitOnce(proof) }
    }

    private func commitOnce(_ proof: AgentEffectProof) async -> AgentBusinessCommitOutcome {
        switch await readReceipt(for: proof, allowClosing: true) {
        case .committed(let receipt): return .committed(receipt)
        case .unavailable(let error): return error.code == .conflict ? .notCommitted(error) : .indeterminate(error)
        case .absent: break
        }
        let effect: AgentResolvedEffect
        do {
            // Avoid resolving new body content while maintenance is already pending.
            // The transaction repeats this check to close the journal-read-to-SQL race.
            try await read(allowClosing: true) { db in
                guard try SQLiteLibraryAuthority.availableAuthorization(in: db, libraryID: self.libraryID) == proof.authorization else {
                    throw MiraError(.unauthorized, "Business authorization is stale.")
                }
            }
            effect = try await resolver.resolve(proof, requireEligible: true)
            try Task.checkCancellation(); try effect.proposal.validate()
            guard effect.proposal.effect == .localWrite, effect.context.evidence.reference.sessionID == proof.sessionID,
                  effect.context.executionID == proof.executionID, effect.context.invocationID == proof.invocationID else {
                throw MiraError(.conflict, "The resolved business command does not match its proof.")
            }
        } catch { return .notCommitted(Self.safe(error)) }
        do {
            let receipt = try await write(allowClosing: true) { db in try self.commit(proof, effect: effect, in: db) }
            do { try afterCommitHook?() }
            catch { return .indeterminate(.init(.storage, "The business commit outcome is uncertain.")) }
            return .committed(receipt)
        } catch {
            // The read is queued behind the original transaction. Never infer rollback from a failed acknowledgement alone.
            switch await readReceipt(for: proof, allowClosing: true) {
            case .committed(let receipt): return .committed(receipt)
            case .absent: return .notCommitted(Self.safe(error))
            case .unavailable(let lookupError): return .indeterminate(lookupError)
            }
        }
    }

    public func receipt(for proof: AgentEffectProof) async -> AgentBusinessReceiptLookup {
        guard beginOperation() else { return .unavailable(.init(.storage, "The business effect store is closed.")) }
        defer { finishOperation() }
        // A resolver can still be suspended before its SQL transaction is enqueued.
        // Waiting only for the database queue would incorrectly report absence in that interval.
        await commits.drain(invocationID: proof.invocationID)
        return await readReceipt(for: proof, allowClosing: true)
    }

    private func readReceipt(for proof: AgentEffectProof, allowClosing: Bool = false) async -> AgentBusinessReceiptLookup {
        do {
            try Self.validateProof(proof)
            return try await read(allowClosing: allowClosing) { db in
                guard let row = try Self.receiptRow(invocationID: proof.invocationID, in: db) else { return .absent }
                guard try Self.decode(AgentEffectProof.self, row["proof_json"]) == proof else {
                    return .unavailable(.init(.conflict, "The business receipt proof does not match."))
                }
                return .committed(try Self.receipt(row, in: db))
            }
        } catch { return .unavailable(Self.safe(error)) }
    }

    public func unpublished(after receiptID: UUID?, limit: Int) async throws -> [AgentReceiptPublication] {
        guard (1...1_000).contains(limit) else { throw MiraError(.invalidInput, "The publication page size is invalid.") }
        return try await read { db in
            let sequence: Int64
            if let receiptID {
                guard let value = try Int64.fetchOne(db, sql: "SELECT sequence FROM business_receipts WHERE id = ?", arguments: [receiptID.uuidString]) else {
                    throw MiraError(.notFound, "The business publication cursor is unavailable.")
                }
                sequence = value
            } else { sequence = 0 }
            return try Row.fetchAll(db, sql: "SELECT * FROM business_receipts WHERE acknowledged = 0 AND sequence > ? ORDER BY sequence LIMIT ?", arguments: [sequence, limit]).map { row in
                .init(proof: try Self.decode(AgentEffectProof.self, row["proof_json"]), receipt: try Self.receipt(row, in: db))
            }
        }
    }

    public func acknowledge(_ receipt: AgentBusinessReceiptReference, at cursor: SessionCursor) async throws {
        guard beginOperation() else { throw MiraError(.storage, "The business effect store is closed.") }
        defer { finishOperation() }
        try receipt.validate()
        try await resolver.validatePublication(receipt, at: cursor)
        try await write(allowClosing: true) { db in
            guard let row = try Self.receiptRow(invocationID: receipt.invocationID, in: db),
                  try Self.receipt(row, in: db).reference == receipt,
                  try Self.decode(AgentEffectProof.self, row["proof_json"]).sessionID == cursor.sessionID else {
                throw MiraError(.conflict, "The business receipt does not match its publication acknowledgement.")
            }
            try db.execute(sql: "UPDATE business_receipts SET acknowledged = 1, publication_json = ? WHERE id = ?",
                           arguments: [try Self.encode(cursor), receipt.id.uuidString])
        }
    }

    public func close() async throws {
        let drained = markClosing()
        await commits.close()
        if drained { return }
        await withCheckedContinuation { continuation in
            lifecycleLock.lock()
            if activeOperations == 0 {
                closed = true; lifecycleLock.unlock(); continuation.resume()
            } else {
                closeWaiters.append(continuation); lifecycleLock.unlock()
            }
        }
    }

    private func commit(_ proof: AgentEffectProof, effect: AgentResolvedEffect, in db: Database) throws -> AgentBusinessReceipt {
        if let row = try Self.receiptRow(invocationID: proof.invocationID, in: db) {
            guard try Self.decode(AgentEffectProof.self, row["proof_json"]) == proof else {
                throw MiraError(.conflict, "The invocation already has a different business receipt.")
            }
            return try Self.receipt(row, in: db)
        }
        let authorization = try SQLiteLibraryAuthority.availableAuthorization(in: db, libraryID: self.libraryID)
        guard proof.authorization == authorization else { throw MiraError(.unauthorized, "Business authorization is stale.") }
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM business_fences WHERE session_id = ? AND execution_id = ?",
            arguments: [proof.sessionID.rawValue.uuidString, proof.executionID.rawValue.uuidString]) == nil else {
            throw MiraError(.cancelled, "The business execution has been fenced.")
        }
        let proposal = effect.proposal
        guard let namespace = proposal.businessNamespace, let handler = handlers[namespace] else {
            throw MiraError(.unsupported, "No business handler is registered for this tool.")
        }
        let key = try handler.businessKey(for: effect)
        guard !key.isEmpty, key.utf8.count <= 512 else { throw MiraError(.invalidInput, "The business operation key is invalid.") }
        let commandDigest = Self.digest(try SessionCodec.encode(proposal.plan.input))
        let operation = try Row.fetchOne(db, sql: "SELECT command_digest, result_digest FROM business_operations WHERE namespace = ? AND business_key = ?", arguments: [namespace, key])
        if let operation, (operation["command_digest"] as String) != commandDigest {
            throw MiraError(.conflict, "The business operation key refers to another command.")
        }
        try validator.validate(effect: effect, isReplay: operation != nil, in: db)
        let resultDigest: String
        if let operation { resultDigest = operation["result_digest"] }
        else {
            let result = try handler.apply(effect: effect, in: db)
            try ToolSchemaValidator.validate(result, schema: proposal.descriptor.outputSchema)
            let data = try SessionCodec.encode(result)
            guard data.count <= proposal.descriptor.maximumResultBytes else { throw MiraError(.outputLimit, "The business result exceeds its declared limit.") }
            resultDigest = Self.digest(data)
            try db.execute(sql: "INSERT INTO business_operations(namespace, business_key, command_digest, result_digest, result_blob, result_purged) VALUES (?, ?, ?, ?, ?, 0)",
                           arguments: [namespace, key, commandDigest, resultDigest, data])
        }
        let id = UUID()
        try db.execute(sql: """
            INSERT INTO business_receipts(id, invocation_id, library_id, epoch, intent_digest, result_digest,
              operation_namespace, operation_key, proof_json, acknowledged)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """, arguments: [id.uuidString, proof.invocationID.uuidString, authorization.libraryID.uuidString,
                String(authorization.epoch), proof.proposal.digest, resultDigest, namespace, key, try Self.encode(proof)])
        guard let row = try Self.receiptRow(invocationID: proof.invocationID, in: db) else { throw Self.corrupt }
        let receipt = try Self.receipt(row, in: db)
        if let bytes = receipt.result {
            guard bytes.count <= proposal.descriptor.maximumResultBytes else { throw MiraError(.outputLimit, "The business result exceeds its declared limit.") }
            try ToolSchemaValidator.validate(SessionCodec.decode(JSONValue.self, from: bytes), schema: proposal.descriptor.outputSchema)
        }
        return receipt
    }

    private func read<T: Sendable>(allowClosing: Bool = false, _ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await perform(allowClosing: allowClosing) { try self.database.read(body) }
    }
    private func write<T: Sendable>(allowClosing: Bool = false, _ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await perform(allowClosing: allowClosing) { try self.database.write(body) }
    }
    private func perform<T: Sendable>(allowClosing: Bool = false, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        guard allowClosing || beginOperation() else { throw MiraError(.storage, "The business effect store is closed.") }
        return try await withCheckedThrowingContinuation { continuation in
            io.async {
                do {
                    guard !self.isClosed() else { throw MiraError(.storage, "The business effect store is closed.") }
                    continuation.resume(returning: try body())
                } catch { continuation.resume(throwing: Self.safe(error)) }
                if !allowClosing { self.finishOperation() }
            }
        }
    }

    private func beginOperation() -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        guard accepting, !closed else { return false }
        activeOperations += 1
        return true
    }

    private func markClosing() -> Bool {
        lifecycleLock.lock(); accepting = false
        let drained = activeOperations == 0
        if drained { closed = true }
        lifecycleLock.unlock()
        return drained
    }

    private func isClosed() -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return closed
    }

    private func finishOperation() {
        lifecycleLock.lock(); activeOperations -= 1
        guard activeOperations == 0, !accepting else { lifecycleLock.unlock(); return }
        closed = true
        let waiters = closeWaiters; closeWaiters.removeAll(); lifecycleLock.unlock()
        waiters.forEach { $0.resume() }
    }

    private static func initialize(_ db: Database) throws {
        let owned = Self.archiveTableNames
        let present = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN (?, ?, ?, ?)", arguments: StatementArguments(owned))
        if !present.isEmpty {
            guard Set(present) == Set(owned), try Int.fetchOne(db, sql: "SELECT format_version FROM business_effects_metadata WHERE id = 1") == 1 else {
                throw MiraError(.storage, "The business library format is unsupported.")
            }
            return
        }
        for statement in Self.archiveSchemaStatements { try db.execute(sql: statement) }
        try db.execute(sql: "INSERT INTO business_effects_metadata(id, format_version) VALUES (1, 1)")
    }

    private static func requireUnfenced(_ context: AgentToolContext, in db: Database) throws {
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM business_fences WHERE session_id = ? AND execution_id = ?",
            arguments: [context.evidence.reference.sessionID.rawValue.uuidString, context.executionID.rawValue.uuidString]) == nil else {
            throw MiraError(.cancelled, "The business execution has been fenced.")
        }
    }
    static func receiptRow(invocationID: UUID, in db: Database) throws -> Row? {
        try Row.fetchOne(db, sql: "SELECT * FROM business_receipts WHERE invocation_id = ?", arguments: [invocationID.uuidString])
    }
    static func receipt(_ row: Row, in db: Database) throws -> AgentBusinessReceipt {
        guard let id = UUID(uuidString: row["id"]), let invocation = UUID(uuidString: row["invocation_id"]),
              let library = UUID(uuidString: row["library_id"]), let epoch = UInt64(row["epoch"] as String),
              let operation = try Row.fetchOne(db, sql: "SELECT result_digest, result_purged, length(result_blob) AS byte_count FROM business_operations WHERE namespace = ? AND business_key = ?",
                arguments: [row["operation_namespace"] as String, row["operation_key"] as String]),
              (operation["result_digest"] as String) == (row["result_digest"] as String) else { throw corrupt }
        let reference = AgentBusinessReceiptReference(id: id, invocationID: invocation, authorization: .init(libraryID: library, epoch: epoch),
            intentDigest: row["intent_digest"], resultDigest: row["result_digest"])
        try reference.validate()
        var body: Data?
        if (operation["result_purged"] as Int) == 0 {
            guard let count = operation["byte_count"] as Int?, (1...65_536).contains(count) else { throw corrupt }
            body = try Data.fetchOne(db, sql: "SELECT result_blob FROM business_operations WHERE namespace = ? AND business_key = ?",
                arguments: [row["operation_namespace"] as String, row["operation_key"] as String])
            guard let body, body.count == count, digest(body) == reference.resultDigest else { throw corrupt }
        }
        return .init(reference: reference, result: body)
    }
    static func validateProof(_ proof: AgentEffectProof) throws {
        try proof.proposal.validate()
        guard proof.intentSequence > 0, proof.proposal.sessionID == proof.sessionID,
              proof.proposal.batchID == proof.intentBatchID, proof.proposal.kind == .effectIntent else { throw corrupt }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try SessionCodec.encode(value), as: UTF8.self) }
    static func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T { try SessionCodec.decode(type, from: Data(value.utf8)) }
    private static func validNamespace(_ value: String) -> Bool {
        let bytes = value.utf8
        guard (1...128).contains(bytes.count), let first = bytes.first, (97...122).contains(first) else { return false }
        return bytes.allSatisfy { (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 95 || $0 == 45 }
    }
    private static var corrupt: MiraError { .init(.storage, "The business effect metadata or result is invalid.") }
    private static func safe(_ error: any Error) -> MiraError {
        if error is CancellationError { return .init(.cancelled, "The business operation was cancelled.") }
        return (error as? MiraError) ?? .init(.storage, "The business effect operation failed.")
    }
}

/// Owns the entire asynchronous commit, including journal resolution before entering SQLite.
/// Caller cancellation cannot release this ownership while a business outcome is still pending.
private actor BusinessCommitOwners {
    private struct Owner {
        let proof: AgentEffectProof
        let task: Task<AgentBusinessCommitOutcome, Never>
    }
    private var owners: [UUID: Owner] = [:]
    private var closing = false

    func perform(_ proof: AgentEffectProof,
                 operation: @escaping @Sendable () async -> AgentBusinessCommitOutcome) async -> AgentBusinessCommitOutcome {
        if let owner = owners[proof.invocationID] {
            guard owner.proof == proof else { return .notCommitted(.init(.conflict, "The invocation already has another pending business proof.")) }
            return await owner.task.value
        }
        guard !closing else { return .notCommitted(.init(.storage, "The business effect store is closed.")) }
        guard owners.count < 256 else { return .notCommitted(.init(.busy, "The business effect concurrency limit was reached.")) }
        let task = Task { await operation() }
        owners[proof.invocationID] = .init(proof: proof, task: task)
        let result = await task.value
        owners[proof.invocationID] = nil
        return result
    }

    func drain(invocationID: UUID) async {
        if let owner = owners[invocationID] { _ = await owner.task.value }
    }

    func close() async {
        closing = true
        let active = owners.values.map(\.task)
        for task in active { _ = await task.value }
    }
}
