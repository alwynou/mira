import Foundation
import GRDB
import MiraCore

/// Metadata cache and resolved model updates publish in the same business transaction.
public final class SQLiteAgentModelMetadataStore: AgentModelMetadataStore, @unchecked Sendable {
    private let database: DatabaseQueue
    private let libraryID: UUID
    private static let definition = "CREATE TABLE model_metadata_snapshots(source_id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL CHECK(revision>0), json BLOB NOT NULL CHECK(length(json)<=8400000))"
    public init(database: DatabaseQueue, libraryID: UUID) throws {
        self.database = database; self.libraryID = libraryID
        try database.write { db in
            try SQLiteLibraryAuthority.validateInitialized(in: db, libraryID: libraryID)
            if try !db.tableExists("model_metadata_snapshots") { try db.execute(sql: Self.definition) }
            guard try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'model_metadata_snapshots'") == Self.definition else {
                throw MiraError(.unsupported, "The model metadata cache schema is unsupported.")
            }
        }
    }
    public func snapshot(sourceID: String, authorization: AgentLibraryAuthorization) async throws -> AgentModelMetadataSnapshot? {
        do {
            return try await database.read { db in
                try Self.authorize(authorization, libraryID: self.libraryID, in: db)
                return try Self.load(sourceID, in: db)
            }
        } catch { throw Self.safe(error) }
    }
    public func publish(_ snapshot: AgentModelMetadataSnapshot, expectedRevision: Int?, updates: [AgentModelMetadataUpdate],
                        authorization: AgentLibraryAuthorization) async throws {
        try snapshot.validate()
        guard updates.count <= 4_096, Set(updates.map { $0.previous.id }).count == updates.count else {
            throw MiraError(.configuration, "The model metadata update set is invalid.")
        }
        for update in updates { try update.validate() }
        do {
            try await database.write { db in
                try Self.authorize(authorization, libraryID: self.libraryID, in: db)
                let previous = try Self.load(snapshot.sourceID, in: db)
                guard previous?.revision == expectedRevision,
                    (expectedRevision ?? 0) < Int.max, snapshot.revision == (expectedRevision ?? 0) + 1 else {
                    throw MiraError(.conflict, "The model metadata snapshot changed during refresh.")
                }
                if previous == nil {
                    guard (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM model_metadata_snapshots") ?? 0) < 16 else {
                        throw MiraError(.outputLimit, "The model metadata source limit was exceeded.")
                    }
                }
                try SQLiteAgentModelSettings.applyMetadataUpdates(updates, in: db)
                let bytes = try SessionCodec.encode(snapshot)
                guard bytes.count <= 8_400_000 else { throw MiraError(.outputLimit, "The model metadata snapshot is too large.") }
                try db.execute(sql: "INSERT INTO model_metadata_snapshots(source_id,revision,json) VALUES(?,?,?) ON CONFLICT(source_id) DO UPDATE SET revision=excluded.revision,json=excluded.json",
                               arguments: [snapshot.sourceID, snapshot.revision, bytes])
            }
        } catch { throw Self.safe(error) }
    }
    public static func archiveModule() throws -> SQLiteArchiveModule {
        try SQLiteArchiveModule(identity: .init(name: "model.metadata", revision: 1), schemaStatements: [definition], restoration: .preserve) { db, _ in
            try SQLiteArchiveValidation.rows(in: db, table: "model_metadata_snapshots", maximumRows: 16,
                maximumBytes: ["source_id": 128, "json": 8_400_000]) { _ = try decode($0) }
            return []
        }
    }
    private static func load(_ id: String, in db: Database) throws -> AgentModelMetadataSnapshot? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM model_metadata_snapshots WHERE source_id = ?", arguments: [id]) else { return nil }
        return try decode(row)
    }
    private static func decode(_ row: Row) throws -> AgentModelMetadataSnapshot {
        guard let bytes: Data = row["json"], bytes.count <= 8_400_000 else { throw invalid }
        let value = try SessionCodec.decode(AgentModelMetadataSnapshot.self, from: bytes)
        try value.validate()
        guard (row["source_id"] as String?) == value.sourceID, (row["revision"] as Int?) == value.revision,
            try SessionCodec.encode(value) == bytes else { throw invalid }
        return value
    }
    private static func authorize(_ authorization: AgentLibraryAuthorization, libraryID: UUID, in db: Database) throws {
        guard authorization.libraryID == libraryID,
            try SQLiteLibraryAuthority.availableAuthorization(in: db, libraryID: libraryID) == authorization else {
            throw MiraError(.unauthorized, "The model metadata authorization is stale or belongs to another library.")
        }
    }
    private static var invalid: MiraError { .init(.storage, "The model metadata cache is invalid.") }
    private static func safe(_ error: any Error) -> MiraError {
        error as? MiraError ?? .init(.storage, "The model metadata cache could not access its database.")
    }
}
