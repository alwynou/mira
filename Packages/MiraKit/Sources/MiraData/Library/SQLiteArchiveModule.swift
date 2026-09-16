import Foundation
import GRDB
import MiraCore

/// Explicit policy for local records in a newly restored, unopened library.
public enum SQLiteArchiveRestoration: Sendable {
    case preserve
    case prepare(
        apply: @Sendable (Database, Date) throws -> Void,
        verify: @Sendable (Database) throws -> Void
    )
}

/// A compiled adapter declares its exact schema and validates its own canonical records.
/// Validators run synchronously on a read-only database connection; they never perform effects.
public struct SQLiteArchiveModule: Sendable {
    public struct Identity: Codable, Equatable, Sendable {
        public let name: String
        public let revision: Int
        public init(name: String, revision: Int) {
            self.name = name
            self.revision = revision
        }
    }

    public let identity: Identity
    let restoration: SQLiteArchiveRestoration
    let sessionExtensions: [String: Set<Int>]
    let schema: [SQLiteArchiveSchemaObject]
    let prepareExport: @Sendable (Database) throws -> Void
    let inspect: @Sendable (Database, FileSessionSnapshot) throws -> [LibraryArchiveAttachment]

    public init(
        identity: Identity, schemaStatements: [String], sessionExtensions: [String: Set<Int>] = [:],
        restoration: SQLiteArchiveRestoration,
        prepareExport: @escaping @Sendable (Database) throws -> Void = { _ in },
        inspect: @escaping @Sendable (Database, FileSessionSnapshot) throws -> [LibraryArchiveAttachment]
    ) throws {
        guard Self.validName(identity.name), identity.revision > 0,
            !schemaStatements.isEmpty || !sessionExtensions.isEmpty, schemaStatements.count <= 256,
            sessionExtensions.count <= 128,
            sessionExtensions.allSatisfy({
                Self.validName($0.key) && !$0.value.isEmpty
                    && $0.value.count <= 128 && $0.value.allSatisfy({ $0 > 0 })
            }),
            schemaStatements.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 65_536 })
        else {
            throw LibraryArchiveIO.invalid
        }
        let reference = try DatabaseQueue()
        defer { try? reference.close() }
        schema = try reference.write { db in
            for statement in schemaStatements { try db.execute(sql: statement) }
            return try SQLiteArchiveSchemaObject.read(in: db)
        }
        self.identity = identity
        self.restoration = restoration
        self.prepareExport = prepareExport
        self.sessionExtensions = sessionExtensions
        self.inspect = inspect
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128
            && name.utf8.allSatisfy {
                (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 || $0 == 95
            }
    }
}

/// Relative to the library root. Only committed, retained files belong in an archive.
public struct LibraryArchiveAttachment: Equatable, Sendable {
    public let path: String
    public let byteCount: Int
    public let digest: String
    public init(path: String, byteCount: Int, digest: String) {
        self.path = path
        self.byteCount = byteCount
        self.digest = digest
    }
}

struct SQLiteArchiveSchemaObject: Equatable, Sendable {
    let type: String
    let name: String
    let table: String
    let sql: String

    static func read(in db: Database) throws -> [Self] {
        let rows = try Row.fetchCursor(
            db,
            sql:
                "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE substr(name, 1, 7) != 'sqlite_' ORDER BY name"
        )
        var result: [Self] = []
        while let row = try rows.next() {
            guard result.count < 4096, let sql = row["sql"] as String?, sql.utf8.count <= 65_536 else {
                throw LibraryArchiveIO.invalid
            }
            result.append(.init(type: row["type"], name: row["name"], table: row["tbl_name"], sql: sql))
        }
        return result
    }
}
