import Foundation
import GRDB
import MiraCore

public final class SQLiteWorkspaceStore: WorkspaceStore, @unchecked Sendable {
    private let owner: SQLiteDomainDatabase
    public init(database: DatabaseQueue, libraryID: UUID) throws {
        owner = try SQLiteDomainDatabase(database: database, libraryID: libraryID, label: "mira.workspaces")
        try database.write { try Self.initialize(in: $0) }
    }
    public func close() async { await owner.close() }
    public func workspaces() async throws -> [Workspace] {
        try await owner.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM business_workspaces ORDER BY id LIMIT 1025")
            guard rows.count <= 1_024 else { throw SQLiteDomainDatabase.invalidSchema }
            return try rows.map(Self.decode)
        }
    }
    public func workspace(_ id: WorkspaceID) async throws -> Workspace {
        try await owner.read { try Self.read(id, in: $0) }
    }
    public func saveWorkspace(_ workspace: Workspace, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws {
        try Self.validate(workspace)
        let bytes = try SessionCodec.encode(workspace)
        guard bytes.count <= 131_072 else { throw SQLiteDomainDatabase.invalidSchema }
        try await owner.write(authorization: authorization) { db in
            let old = try Row.fetchOne(db, sql: "SELECT * FROM business_workspaces WHERE id = ?", arguments: [workspace.id.rawValue.uuidString.lowercased()]).map(Self.decode)
            guard old?.revision == expectedRevision, workspace.revision == (old?.revision ?? 0) + 1 else {
                throw MiraError(.conflict, "The workspace revision is out of date.")
            }
            if old == nil {
                guard try Int.fetchOne(db, sql: "SELECT count(*) FROM business_workspaces") ?? 0 < 1024 else {
                    throw MiraError(.outputLimit, "The workspace information is invalid.")
                }
            }
            try db.execute(sql: "INSERT INTO business_workspaces(id, revision, json) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET revision = excluded.revision, json = excluded.json",
                           arguments: [workspace.id.rawValue.uuidString.lowercased(), workspace.revision, bytes])
        }
    }

    public static func archiveModule() throws -> SQLiteArchiveModule {
        try SQLiteArchiveModule(
            identity: .init(name: "workspace.store", revision: 1),
            schemaStatements: schemaStatements, restoration: .preserve
        ) { db, snapshot in
            try SQLiteArchiveValidation.metadata("workspace_schema", in: db)
            var workspaceIDs = Set<String>()
            try SQLiteArchiveValidation.rows(in: db, table: "business_workspaces", maximumRows: 1_024,
                maximumBytes: ["json": 131_072, "id": 128]) { row in
                    let value = try decode(row); workspaceIDs.insert(value.id.rawValue.uuidString.lowercased())
                }
            for session in snapshot.sessions {
                for batch in try snapshot.readBatches(sessionID: session.id) {
                    for event in batch.events {
                        if case .opened(let header) = event.fact, let workspaceID = header.workspaceID {
                            guard workspaceIDs.contains(workspaceID.rawValue.uuidString.lowercased()) else { throw LibraryArchiveIO.invalid }
                        }
                    }
                }
            }
            return []
        }
    }
    static let schemaStatements = [
        "CREATE TABLE workspace_schema(id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL CHECK(version=1))",
        "CREATE TABLE business_workspaces(id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL CHECK(revision>0), json BLOB NOT NULL CHECK(length(json)<=131072))"
    ]
    static func initialize(in db: Database) throws {
        try SQLiteDomainDatabase.initialize([
            ("workspace_schema", schemaStatements[0]), ("business_workspaces", schemaStatements[1])
        ], metadata: "workspace_schema", in: db)
    }
    static func read(_ id: WorkspaceID, in db: Database) throws -> Workspace {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM business_workspaces WHERE id = ?", arguments: [id.rawValue.uuidString.lowercased()]) else {
            throw MiraError(.notFound, "The workspace does not exist.")
        }
        return try decode(row)
    }
    static func validatePolicy(_ id: WorkspaceID?, connectionID: ConnectionID?, in db: Database) throws {
        guard let id else { return }
        let workspace = try read(id, in: db)
        if let connectionID {
            guard workspace.allowsRemoteSend, workspace.allowedConnectionIDs?.contains(connectionID) ?? true else {
                throw MiraError(.unauthorized, "The task source or tool request is no longer authorized.")
            }
        }
    }
    private static func decode(_ row: Row) throws -> Workspace {
        let bytes: Data = row["json"]
        guard bytes.count <= 131_072 else { throw SQLiteDomainDatabase.invalidSchema }
        let value = try SessionCodec.decode(Workspace.self, from: bytes)
        do { try validate(value) }
        catch let error as MiraError where error.code == .invalidInput {
            throw MiraError(.storage, "The workspace record is inconsistent.")
        }
        guard value.id.rawValue.uuidString.lowercased() == row["id"] as String, value.revision == row["revision"] as Int else {
            throw SQLiteDomainDatabase.invalidSchema
        }
        return value
    }
    private static func validate(_ value: Workspace) throws {
        guard value.revision > 0, value.revision < Int.max,
              !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.name.utf8.count <= 1_024, value.background.utf8.count <= 65_536,
              value.allowedConnectionIDs?.count ?? 0 <= 128 else {
            throw MiraError(.invalidInput, "The workspace information is invalid.")
        }
    }
}
