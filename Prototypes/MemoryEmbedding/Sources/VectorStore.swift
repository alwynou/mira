import Accelerate
import Foundation
import SQLite3

struct MemoryFixture: Codable, Sendable {
    let id: String
    let text: String
    let scope: String
    let allowed: Bool
    let active: Bool
    let revision: Int
}

struct VectorRow: Sendable {
    let id: String
    let vector: [Float]
}

struct RankedHit: Codable, Sendable {
    let id: String
    let score: Float
}

func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
    precondition(lhs.count == rhs.count)
    var result: Float = 0
    vDSP_dotpr(lhs, 1, rhs, 1, &result, vDSP_Length(lhs.count))
    return result
}

func rank(_ query: [Float], rows: [VectorRow], limit: Int = 12) -> [RankedHit] {
    var hits: [RankedHit] = rows.map { RankedHit(id: $0.id, score: dot(query, $0.vector)) }
    hits.sort(by: precedes)
    return Array(hits.prefix(limit))
}

private func precedes(_ lhs: RankedHit, _ rhs: RankedHit) -> Bool {
    if lhs.score == rhs.score { return lhs.id < rhs.id }
    return lhs.score > rhs.score
}

func fuse(_ lists: [[RankedHit]], limit: Int = 6) -> [RankedHit] {
    var scores: [String: Float] = [:]
    for list in lists {
        for (index, hit) in list.enumerated() { scores[hit.id, default: 0] += 1 / Float(60 + index + 1) }
    }
    var hits: [RankedHit] = scores.map { RankedHit(id: $0.key, score: $0.value) }
    hits.sort(by: precedes)
    return Array(hits.prefix(limit))
}

// A documented prototype baseline: Latin words and contiguous CJK bigrams in FTS5.
// This is not a reimplementation or benchmark of Mira's production lexical path.
func lexicalTerms(_ text: String) -> [String] {
    let scalars = Array(text.lowercased().unicodeScalars)
    func isCJK(_ scalar: Unicode.Scalar) -> Bool { (0x3400...0x9fff).contains(scalar.value) }
    var terms = Set<String>()
    var word = ""
    for (index, scalar) in scalars.enumerated() {
        if isCJK(scalar) {
            if !word.isEmpty { terms.insert(word); word = "" }
            if index + 1 < scalars.count, isCJK(scalars[index + 1]) {
                terms.insert(String(scalar) + String(scalars[index + 1]))
            }
        } else if CharacterSet.alphanumerics.contains(scalar) {
            word.unicodeScalars.append(scalar)
        } else if !word.isEmpty { terms.insert(word); word = "" }
    }
    if !word.isEmpty { terms.insert(word) }
    return terms.sorted()
}

final class VectorStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw PrototypeError.database("Open failed") }
        try execute("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL;")
        try execute("""
            CREATE TABLE IF NOT EXISTS facts(id TEXT PRIMARY KEY, content TEXT NOT NULL,
                scope TEXT NOT NULL, allowed INTEGER NOT NULL, active INTEGER NOT NULL, revision INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS vectors(id TEXT PRIMARY KEY REFERENCES facts(id) ON DELETE CASCADE,
                revision INTEGER NOT NULL, fingerprint TEXT NOT NULL, dimension INTEGER NOT NULL, payload BLOB NOT NULL);
            CREATE VIRTUAL TABLE IF NOT EXISTS lexical USING fts5(id UNINDEXED, terms, tokenize='unicode61');
            """)
    }

    deinit { sqlite3_close(db) }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw PrototypeError.database(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func statement<T>(_ sql: String, _ values: [String], body: (OpaquePointer) throws -> T) throws -> T {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
            throw PrototypeError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(prepared) }
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(prepared, Int32(index + 1), value, -1, transient) == SQLITE_OK else {
                throw PrototypeError.database("Text bind failed")
            }
        }
        return try body(prepared)
    }

    private func done(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PrototypeError.database(String(cString: sqlite3_errmsg(db)))
        }
    }

    func put(_ fact: MemoryFixture) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try statement("INSERT INTO facts VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET content=excluded.content, scope=excluded.scope, allowed=excluded.allowed, active=excluded.active, revision=excluded.revision",
                [fact.id, fact.text, fact.scope, fact.allowed ? "1" : "0", fact.active ? "1" : "0", String(fact.revision)], body: done)
            try statement("DELETE FROM lexical WHERE id=?", [fact.id], body: done)
            try statement("INSERT INTO lexical(id,terms) VALUES(?,?)", [fact.id, lexicalTerms(fact.text).joined(separator: " ")], body: done)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    @discardableResult
    func putVector(id: String, revision: Int, fingerprint: String, vector: [Float]) throws -> Bool {
        guard vector.count == 1024, vector.allSatisfy(\.isFinite) else {
            throw PrototypeError.invalidInput("Invalid stored vector")
        }
        return try statement("""
            INSERT INTO vectors(id,revision,fingerprint,dimension,payload)
            SELECT id,revision,?,1024,? FROM facts WHERE id=? AND revision=? AND active=1
            ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,fingerprint=excluded.fingerprint,
                dimension=excluded.dimension,payload=excluded.payload
            """, []) { stmt in
                sqlite3_bind_text(stmt, 1, fingerprint, -1, transient)
                let status = vector.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32($0.count), transient) }
                guard status == SQLITE_OK else { throw PrototypeError.database("Vector bind failed") }
                sqlite3_bind_text(stmt, 3, id, -1, transient)
                sqlite3_bind_int64(stmt, 4, Int64(revision))
                try done(stmt)
                return sqlite3_changes(db) == 1
            }
    }

    func rows(scope: String, fingerprint: String) throws -> [VectorRow] {
        try statement("""
            SELECT f.id,v.payload FROM facts f JOIN vectors v ON f.id=v.id AND f.revision=v.revision
            WHERE f.active=1 AND f.allowed=1 AND (f.scope='global' OR f.scope=?)
                AND v.fingerprint=? AND v.dimension=1024 ORDER BY f.id
            """, [scope, fingerprint]) { stmt in
                var result: [VectorRow] = []
                var code = sqlite3_step(stmt)
                while code == SQLITE_ROW {
                    guard sqlite3_column_bytes(stmt, 1) == 4096, let bytes = sqlite3_column_blob(stmt, 1) else {
                        throw PrototypeError.database("Malformed vector blob")
                    }
                    var vector = Array(repeating: Float(0), count: 1024)
                    vector.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: bytes, count: 4096)) }
                    result.append(VectorRow(id: String(cString: sqlite3_column_text(stmt, 0)), vector: vector))
                    code = sqlite3_step(stmt)
                }
                guard code == SQLITE_DONE else { throw PrototypeError.database("Read failed") }
                return result
            }
    }

    func lexical(_ query: String, scope: String) throws -> [RankedHit] {
        let terms = lexicalTerms(query).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        guard !terms.isEmpty else { return [] }
        return try statement("""
            SELECT f.id,bm25(lexical) FROM lexical JOIN facts f ON f.id=lexical.id
            WHERE lexical MATCH ? AND f.active=1 AND f.allowed=1 AND (f.scope='global' OR f.scope=?)
            ORDER BY bm25(lexical),f.id LIMIT 12
            """, [terms.joined(separator: " OR "), scope]) { stmt in
                var result: [RankedHit] = []
                var code = sqlite3_step(stmt)
                while code == SQLITE_ROW {
                    result.append(.init(id: String(cString: sqlite3_column_text(stmt, 0)), score: -Float(sqlite3_column_double(stmt, 1))))
                    code = sqlite3_step(stmt)
                }
                guard code == SQLITE_DONE else { throw PrototypeError.database("FTS read failed") }
                return result
            }
    }

    func delete(id: String) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try statement("DELETE FROM lexical WHERE id=?", [id], body: done)
            try statement("DELETE FROM facts WHERE id=?", [id], body: done)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
}
