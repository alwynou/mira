import Foundation
import GRDB
import MiraCore
import SQLite3

private final class KnowledgeSearchDeadline {
    let end = ContinuousClock.now.advanced(by: .milliseconds(200))
    var expired: Bool { ContinuousClock.now >= end }
}

extension SQLiteMiraStore {
    public func searchKnowledge(query: String, workspaceID: WorkspaceID?, connectionID: ConnectionID?, limit: Int) throws -> KnowledgeSearchResult {
        let normalized = Self.normalizeKnowledge(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, query.unicodeScalars.count <= 500 else { throw MiraError(.invalidInput, "Enter a source search query of at most 500 characters.") }
        return try safely { try pool.read { db in
            if let connectionID { try validateWorkspacePolicy(workspaceID, connectionID: connectionID, in: db) }
            let words = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let hasTrigram = try db.tableExists("knowledge_trigrams")
            let indexed = hasTrigram && words.allSatisfy { $0.unicodeScalars.count >= 3 }
            let expression = words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
            var sql = "SELECT s.source_json, c.summary_json, c.text, c.normalized_text FROM source_chunks c JOIN knowledge_sources s ON s.id = c.source_id AND s.current_version_id = c.version_id WHERE s.deleted_at IS NULL AND (s.workspace_id IS NULL OR s.workspace_id = ?)"
            var arguments: StatementArguments = [workspaceID.map(Self.id)]
            if connectionID != nil { sql += " AND s.allows_remote_use = 1" }
            if indexed {
                sql += " AND c.rowid IN (SELECT rowid FROM knowledge_words WHERE knowledge_words MATCH ? UNION SELECT rowid FROM knowledge_trigrams WHERE knowledge_trigrams MATCH ?)"
                arguments += [expression, expression]
            }
            sql += " ORDER BY c.rowid LIMIT 20001"
            let deadline = KnowledgeSearchDeadline()
            let pointer = Unmanaged.passUnretained(deadline).toOpaque()
            sqlite3_progress_handler(db.sqliteConnection, 1_000, { context in
                guard let context else { return 0 }
                return Unmanaged<KnowledgeSearchDeadline>.fromOpaque(context).takeUnretainedValue().expired ? 1 : 0
            }, pointer)
            defer { sqlite3_progress_handler(db.sqliteConnection, 0, nil, nil) }
            var scored: [(Int, KnowledgeSearchHit)] = []
            var scanned = 0, truncated = false
            let maximum = max(1, min(limit, 100))
            do {
                let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
                while let row = try cursor.next() {
                    if deadline.expired || scanned == 20_000 { truncated = true; break }
                    scanned += 1
                    let text: String = row["normalized_text"]
                    guard words.allSatisfy({ text.contains($0) }) else { continue }
                    let source: KnowledgeSource = try Self.decode(row["source_json"])
                    let summary: SourceChunkSummary = try Self.decode(row["summary_json"])
                    let raw: String = row["text"]
                    let score = (text.contains(normalized) ? 1_000 : 0) + (Self.normalizeKnowledge(source.title).contains(normalized) ? 100 : 0)
                    let hit = KnowledgeSearchHit(source: source, chunk: summary, snippet: Self.knowledgeSnippet(raw, query: words.first ?? normalized))
                    scored.append((score, hit))
                    scored.sort { $0.0 == $1.0 ? Self.id($0.1.id) < Self.id($1.1.id) : $0.0 > $1.0 }
                    if scored.count > maximum { scored.removeLast(); truncated = true }
                }
            } catch let error as DatabaseError where error.resultCode == .SQLITE_INTERRUPT {
                guard deadline.expired else { throw error }
                truncated = true
            }
            return .init(hits: scored.map(\.1), isTruncated: truncated, scannedCandidates: scanned)
        }}
    }

    static func knowledgeSnippet(_ text: String, query: String) -> String {
        let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])?.lowerBound ?? text.startIndex
        let start = text.index(match, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
        var result = "", count = 0
        for scalar in text[start...].unicodeScalars {
            let value = String(scalar), size = value.utf8.count
            guard count + size <= 1_200 else { break }
            result += value; count += size
        }
        return result
    }
}
