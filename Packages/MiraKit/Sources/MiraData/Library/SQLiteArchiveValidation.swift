import Foundation
import GRDB
import MiraCore

enum SQLiteArchiveValidation {
    /// Inspect lengths before materializing any TEXT/BLOB, including mirrored identifiers.
    /// Callers supply compiled table names; a visitor may update only its current row.
    static func rows(
        in db: Database, table: String, maximumRows: Int = 100_000,
        maximumBytes: [String: Int] = [:], visit: (Row) throws -> Void
    ) throws {
        func identifier(_ name: String) throws -> String {
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 })
            else {
                throw LibraryArchiveIO.invalid
            }
            return "\"\(name)\""
        }
        let tableName = try identifier(table)
        guard maximumRows > 0, maximumRows <= 1_000_000 else { throw LibraryArchiveIO.invalid }
        let columns = try db.columns(in: table).filter { ["TEXT", "BLOB"].contains($0.type.uppercased()) }
        guard columns.count <= 128, Set(maximumBytes.keys).isSubset(of: Set(columns.map(\.name))) else {
            throw LibraryArchiveIO.invalid
        }
        let lengths = try columns.enumerated().map { index, column in
            "length(CAST(\(try identifier(column.name)) AS BLOB)) AS archive_length_\(index)"
        }
        let select = (["rowid AS archive_rowid"] + lengths).joined(separator: ",")
        let cursor = try Row.fetchCursor(db, sql: "SELECT \(select) FROM \(tableName) ORDER BY rowid")
        var count = 0
        while let metadata = try cursor.next() {
            count += 1
            guard count <= maximumRows else { throw LibraryArchiveIO.invalid }
            for (index, column) in columns.enumerated() {
                if let length = metadata["archive_length_\(index)"] as Int? {
                    let bound = maximumBytes[column.name] ?? 131_072
                    guard bound > 0, bound <= SessionPrivacyPlan.maximumBytes, (0...bound).contains(length) else {
                        throw LibraryArchiveIO.invalid
                    }
                }
            }
            let rowID: Int64 = metadata["archive_rowid"]
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM \(tableName) WHERE rowid = ?", arguments: [rowID])
            else {
                throw LibraryArchiveIO.invalid
            }
            try visit(row)
        }
    }

    static func metadata(_ table: String, in db: Database, versionColumn: String = "version", expectedVersion: Int = 1) throws {
        guard table.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 }),
            ["version", "format_version"].contains(versionColumn),
            try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") == 1,
            try Int.fetchOne(db, sql: "SELECT \(versionColumn) FROM \(table) WHERE id = 1") == expectedVersion
        else { throw LibraryArchiveIO.invalid }
    }

    static func digest(_ value: String?) throws {
        guard let value, value.utf8.count == 64,
            value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw LibraryArchiveIO.invalid }
    }
}
