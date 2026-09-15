import CryptoKit
import Foundation
import GRDB
import MiraCore

/// Durable content-free maintenance facts; the composition root owns the shared database.
public final class SQLiteSessionPrivacyPlanStore: SessionPrivacyPlanStore, SessionPrivacyHistoryReader, @unchecked Sendable {
    private let owner: SQLiteDomainDatabase
    private let afterCommitHook: (@Sendable () throws -> Void)?

    public init(
        database: DatabaseQueue, libraryID: UUID,
        afterCommitHook: (@Sendable () throws -> Void)? = nil
    ) throws {
        owner = try SQLiteDomainDatabase(database: database, libraryID: libraryID, label: "mira.session-privacy-plan")
        self.afterCommitHook = afterCommitHook
        do {
            try database.write {
                try SQLiteDomainDatabase.initialize(Self.definitions, metadata: "session_privacy_plan_metadata", in: $0)
            }
        } catch { throw error as? MiraError ?? Self.invalid }
    }

    public func close() async { await owner.close() }

    public static func archiveModule() throws -> SQLiteArchiveModule {
        try SQLiteArchiveModule(identity: .init(name: "session.privacy", revision: 1),
            schemaStatements: definitions.map(\.1), restoration: .preserve
        ) { db, snapshot in
            try SQLiteArchiveValidation.metadata("session_privacy_plan_metadata", in: db)
            let authority = try SQLiteLibraryAuthority.readState(in: db)
            guard authority.pending == nil else { throw invalid }
            let journal = try SQLiteArchiveSessions(snapshot)
            var published: [ConversationID: Set<UUID>] = [:]
            try SQLiteArchiveValidation.rows(in: db, table: "session_privacy_plans",
                maximumBytes: ["plan_json": SessionPrivacyPlan.maximumBytes]) { row in
                guard let text: String = row["operation_id"], let id = UUID(uuidString: text), id.uuidString == text,
                    let plan = try read(id: id, in: db, libraryID: authority.authorization.libraryID),
                    let operation = try SQLiteLibraryAuthority.readOperation(id: id, in: db,
                        libraryID: authority.authorization.libraryID), operation.completedAt != nil,
                    operation.authorization.epoch <= authority.authorization.epoch else { throw invalid }
                for head in plan.heads { try journal.validate(head) }
                let capturedHeads = Dictionary(uniqueKeysWithValues: plan.heads.map { ($0.cursor.sessionID, $0.cursor.sequence) })
                func requireCapturedExecution(_ executionID: ExecutionID, sessionID: ConversationID) throws {
                    guard let sequence = journal.sessions[sessionID]?.executionSequences[executionID],
                        let capturedSequence = capturedHeads[sessionID], sequence <= capturedSequence else { throw invalid }
                }
                for change in plan.changes {
                    guard journal.sessions[change.batch.sessionID]?.invalidations[id] == change.batch else {
                        throw invalid
                    }
                    published[change.batch.sessionID, default: []].insert(id)
                    for dependency in change.dependencies {
                        try requireCapturedExecution(dependency.executionID, sessionID: change.batch.sessionID)
                    }
                }
                for source in plan.roots + plan.changes.flatMap({ $0.dependencies.flatMap(\.sources) }) {
                    if case .sessionExecution(let sessionID, let executionID) = source {
                        try requireCapturedExecution(executionID, sessionID: sessionID)
                    }
                }
            }
            for (id, session) in journal.sessions {
                guard published[id, default: []] == Set(session.invalidations.keys) else { throw invalid }
            }
            return []
        }
    }

    public func load(operation: AgentLibraryMaintenanceOperation) async throws -> SessionPrivacyPlan? {
        try await owner.maintain(operation) { db in
            let plan = try Self.read(id: operation.request.id, in: db, libraryID: self.owner.libraryID)
            guard plan == nil || plan?.operation == operation else { throw Self.conflict }
            return plan
        }
    }

    public func save(_ plan: SessionPrivacyPlan) async throws {
        try plan.validate()
        let bytes = try SessionCodec.encode(plan)
        guard !bytes.isEmpty, bytes.count <= SessionPrivacyPlan.maximumBytes else { throw Self.invalid }
        _ = try await owner.maintain(
            plan.operation,
            afterCommit: { (wrote: Bool) in
                if wrote {
                    do { try self.afterCommitHook?() } catch {
                        throw MiraError(.storage, "The session privacy plan commit acknowledgement failed.")
                    }
                }
            }
        ) { db -> Bool in
            if let existing = try Self.read(id: plan.operation.request.id, in: db, libraryID: self.owner.libraryID) {
                // Codable sets can have different byte ordering after reopening; semantic identity is immutable.
                guard existing == plan else { throw Self.conflict }
                return false
            }
            try db.execute(
                sql:
                    "INSERT INTO session_privacy_plans(operation_id, library_id, byte_count, digest, plan_json) VALUES (?, ?, ?, ?, ?)",
                arguments: [
                    plan.operation.request.id.uuidString, self.owner.libraryID.uuidString,
                    bytes.count, Self.digest(bytes), bytes,
                ])
            return true
        }
    }

    public func retainedDependencies(
        sessionID: ConversationID, invalidationIDs: Set<UUID>,
        operation: AgentLibraryMaintenanceOperation
    ) async throws -> [SessionPrivacyDependencies] {
        guard invalidationIDs.count <= 8_192 else { throw Self.invalid }
        return try await owner.maintain(operation) { db in
            var merged: [ExecutionID: Set<AgentSourceReference>] = [:]
            // The journal supplies every required operation ID. A missing index entry cannot hide provenance.
            for id in invalidationIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let plan = try Self.read(id: id, in: db, libraryID: self.owner.libraryID),
                    plan.operation.authorization.epoch <= operation.authorization.epoch,
                    let change = plan.changes.first(where: { $0.batch.sessionID == sessionID })
                else { throw Self.invalid }
                for dependency in change.dependencies {
                    merged[dependency.executionID, default: []].formUnion(dependency.sources)
                    guard merged[dependency.executionID, default: []].count <= 8_192,
                        merged.count <= 65_536
                    else { throw Self.invalid }
                }
            }
            return merged.keys.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }.map {
                SessionPrivacyDependencies(
                    executionID: $0, sources: merged[$0, default: []].sorted(by: Self.sourceOrder))
            }
        }
    }

    public func retainedHistory(sessionID: ConversationID, operationIDs: Set<UUID>,
                                executionIDs: Set<ExecutionID>) async throws -> [SessionPrivacyHistoryRecord] {
        guard operationIDs.count <= 8_192, executionIDs.count <= 128 else { throw Self.invalid }
        return try await owner.read { db in
            var records: [SessionPrivacyHistoryRecord] = []
            var returnedSources = 0
            var returnedBatchBytes = 0
            for id in operationIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let plan = try Self.read(id: id, in: db, libraryID: self.owner.libraryID),
                      let operation = try SQLiteLibraryAuthority.readOperation(
                        id: id, in: db, libraryID: self.owner.libraryID), operation.completedAt != nil,
                      let selected = plan.changes.first(where: { $0.batch.sessionID == sessionID }) else {
                    throw Self.invalid
                }
                // Expand only actual dependency edges. Unrelated roots in the same plan must
                // not turn into notices, and cycles cannot cause an unbounded traversal.
                var edges: [AgentSourceReference: [AgentSourceReference]] = [:]
                for change in plan.changes {
                    for dependency in change.dependencies {
                        edges[.sessionExecution(sessionID: change.batch.sessionID,
                                                 executionID: dependency.executionID)] = dependency.sources
                    }
                }
                var dependencies: [SessionPrivacyDependencies] = []
                for dependency in selected.dependencies where executionIDs.contains(dependency.executionID) {
                    var pending = dependency.sources
                    var visited = Set<AgentSourceReference>()
                    var domains = Set<AgentSourceReference>()
                    while let source = pending.popLast() {
                        guard visited.insert(source).inserted else { continue }
                        guard visited.count <= 65_536 else { throw Self.invalid }
                        if case .domain = source { domains.insert(source) }
                        else { pending.append(contentsOf: edges[source, default: []]) }
                    }
                    guard domains.count <= 8_192 else { throw Self.invalid }
                    returnedSources += domains.count
                    guard returnedSources <= 65_536 else { throw Self.invalid }
                    dependencies.append(.init(executionID: dependency.executionID,
                                              sources: domains.sorted(by: Self.sourceOrder)))
                }
                returnedBatchBytes += try SessionCodec.encode(selected.batch).count
                guard returnedBatchBytes <= SessionPrivacyPlan.maximumBytes else { throw Self.invalid }
                records.append(.init(batch: selected.batch, request: operation.request, dependencies: dependencies))
            }
            return records
        }
    }

    private static func read(id: UUID, in db: Database, libraryID: UUID) throws -> SessionPrivacyPlan? {
        guard
            let row = try Row.fetchOne(
                db,
                sql:
                    "SELECT library_id, byte_count, length(plan_json) AS stored_length, digest FROM session_privacy_plans WHERE operation_id = ?",
                arguments: [id.uuidString])
        else { return nil }
        guard row["library_id"] as String? == libraryID.uuidString,
            let count: Int = row["byte_count"], row["stored_length"] as Int? == count,
            (1...SessionPrivacyPlan.maximumBytes).contains(count), let hash: String = row["digest"],
            let bytes = try Data.fetchOne(
                db, sql: "SELECT plan_json FROM session_privacy_plans WHERE operation_id = ?",
                arguments: [id.uuidString]), bytes.count == count, digest(bytes) == hash
        else { throw invalid }
        let plan: SessionPrivacyPlan
        do {
            plan = try SessionCodec.decode(SessionPrivacyPlan.self, from: bytes)
            try plan.validate()
        } catch { throw invalid }
        guard plan.operation.request.id == id, plan.operation.authorization.libraryID == libraryID,
            let recorded = try SQLiteLibraryAuthority.readOperation(id: id, in: db, libraryID: libraryID),
            recorded.request == plan.operation.request,
            recorded.previousAuthorization == plan.operation.previousAuthorization,
            recorded.authorization == plan.operation.authorization
        else { throw invalid }
        return plan
    }

    private static func sourceOrder(_ lhs: AgentSourceReference, _ rhs: AgentSourceReference) -> Bool {
        switch (lhs, rhs) {
        case (.domain(let ln, let li, let lr), .domain(let rn, let ri, let rr)):
            if ln != rn { return ln < rn }
            if li != ri { return li.uuidString < ri.uuidString }
            return lr < rr
        case (.domain, .sessionExecution): return true
        case (.sessionExecution, .domain): return false
        case (.sessionExecution(let ls, let le), .sessionExecution(let rs, let re)):
            if ls != rs { return ls.rawValue.uuidString < rs.rawValue.uuidString }
            return le.rawValue.uuidString < re.rawValue.uuidString
        }
    }
    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static var invalid: MiraError { .init(.storage, "The session privacy plan store is inconsistent.") }
    private static var conflict: MiraError {
        .init(.conflict, "The session privacy plan conflicts with current maintenance state.")
    }
    private static let definitions: [(String, String)] = [
        (
            "session_privacy_plan_metadata",
            """
            CREATE TABLE session_privacy_plan_metadata (
              id INTEGER PRIMARY KEY NOT NULL CHECK (id = 1), version INTEGER NOT NULL CHECK (version = 1))
            """
        ),
        (
            "session_privacy_plans",
            """
            CREATE TABLE session_privacy_plans (
              operation_id TEXT PRIMARY KEY NOT NULL REFERENCES agent_library_maintenance(id), library_id TEXT NOT NULL,
              byte_count INTEGER NOT NULL CHECK(byte_count BETWEEN 1 AND 33554432), digest TEXT NOT NULL,
              plan_json BLOB NOT NULL CHECK(length(plan_json) = byte_count))
            """
        ),
    ]
}
