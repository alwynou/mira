import Foundation
import GRDB
import MiraCore

struct MacLibraryDiagnostics: Sendable, Equatable {
    let sqliteVersion: String
    let supportsFTS5: Bool
    let supportsTrigram: Bool

    /// Reads the linked SQLite version from the library and probes tokenizer
    /// support on an isolated in-memory database using the same GRDB engine.
    static func probe(database: DatabaseQueue) throws -> Self {
        let version = try database.read { db in
            try String.fetchOne(db, sql: "SELECT sqlite_version()")
        }
        guard let version, !version.isEmpty else {
            throw MiraError(.storage, "SQLite did not report its engine version.")
        }

        let probe = try DatabaseQueue()
        defer { try? probe.close() }
        let support = try probe.write { db in
            (supportsFTS5(in: db), supportsTrigram(in: db))
        }
        return .init(sqliteVersion: version, supportsFTS5: support.0, supportsTrigram: support.1)
    }

    private static func supportsFTS5(in database: Database) -> Bool {
        supportsVirtualTable(in: database, tokenizer: nil)
    }

    private static func supportsTrigram(in database: Database) -> Bool {
        supportsVirtualTable(in: database, tokenizer: "trigram")
    }

    private static func supportsVirtualTable(in database: Database, tokenizer: String?) -> Bool {
        let table = "mira_diagnostics_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let tokenizerClause = tokenizer.map { ", tokenize='\($0)'" } ?? ""
        do {
            try database.execute(
                sql: "CREATE VIRTUAL TABLE \(table) USING fts5(content\(tokenizerClause))")
            try database.execute(sql: "DROP TABLE \(table)")
            return true
        } catch {
            try? database.execute(sql: "DROP TABLE \(table)")
            return false
        }
    }
}
