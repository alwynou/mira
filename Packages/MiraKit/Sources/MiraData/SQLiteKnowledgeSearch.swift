import Foundation
import GRDB
import MiraCore
import SQLite3

private final class KnowledgeSearchDeadline: @unchecked Sendable {
    let end = ContinuousClock.now.advanced(by: .milliseconds(200))
    var expired: Bool { ContinuousClock.now >= end }
}

extension SQLiteKnowledgeStore {
    /// Searches only the current, ready version of sources eligible for the
    /// requested destination. Candidate rows are bounded before scoring so a
    /// broad local library cannot turn search into an unbounded operation.
    static func search(query: String, scope: KnowledgeReadScope, limit: Int, in db: Database) throws -> KnowledgeSearchResult {
        try scope.destination.modelRoute?.validate()
        try validateScope(scope, in: db)

        let normalized = normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, query.unicodeScalars.count <= 500 else {
            throw invalid
        }
        let words = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { throw invalid }

        guard (1...100).contains(limit) else { throw invalid }
        let maximum = limit
        let indexed = words.allSatisfy { $0.unicodeScalars.count >= 3 }
        let candidate = candidateQuery(words: words, scope: scope, indexed: indexed)
        let deadline = KnowledgeSearchDeadline()
        let pointer = Unmanaged.passUnretained(deadline).toOpaque()
        sqlite3_progress_handler(db.sqliteConnection, 1_000, { context in
            guard let context else { return 0 }
            return Unmanaged<KnowledgeSearchDeadline>.fromOpaque(context).takeUnretainedValue().expired ? 1 : 0
        }, pointer)
        defer { sqlite3_progress_handler(db.sqliteConnection, 0, nil, nil) }

        var scored: [(score: Int, id: String, hit: KnowledgeSearchHit)] = []
        var scanned = 0
        var truncated = false
        do {
            let cursor = try Row.fetchCursor(db, sql: candidate.sql, arguments: candidate.arguments)
            let chunkStatement = try db.cachedStatement(sql: "SELECT * FROM knowledge_chunks WHERE rowid = ?")
            while let candidateRow = try cursor.next() {
                if deadline.expired || scanned >= 20_000 {
                    truncated = true
                    break
                }
                scanned += 1
                let rowID: Int64 = candidateRow["candidate_rowid"]
                guard let row = try Row.fetchOne(chunkStatement, arguments: [rowID]) else { throw corrupt }
                let rawText: String = row["text"]
                let normalizedText: String = row["normalized_text"]
                guard words.allSatisfy({ normalizedText.contains($0) }) else { continue }

                let sourceID = try uuid(row["source_id"] as String)
                let source = try source(.init(sourceID), scope: scope, in: db)
                let chunk = try chunk(row)
                guard chunk.summary.sourceID == source.id,
                      chunk.summary.sourceVersionID == source.currentVersionID,
                      normalizedText == normalize(source.title + "\n" + chunk.summary.headingPath.joined(separator: "\n") + "\n" + chunk.text) else {
                    throw corrupt
                }
                let score = rank(normalizedQuery: normalized, normalizedText: normalizedText, source: source)
                let hit = KnowledgeSearchHit(source: source, chunk: chunk.summary,
                                             snippet: snippet(rawText, query: words.first ?? normalized))
                scored.append((score, key(chunk.summary.id), hit))
                scored.sort {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.id < $1.id
                }
                if scored.count > maximum {
                    scored.removeLast()
                    truncated = true
                }
            }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_INTERRUPT {
            guard deadline.expired else { throw error }
            truncated = true
        }
        return .init(hits: scored.map(\.hit), isTruncated: truncated, scannedCandidates: scanned)
    }

    private static func candidateQuery(words: [String], scope: KnowledgeReadScope,
                                      indexed: Bool) -> (sql: String, arguments: StatementArguments) {
        var arguments: StatementArguments = [scope.workspaceID.map { key($0) }]
        let remotePredicate: String
        if scope.destination.modelRoute != nil {
            remotePredicate = " AND s.allows_remote_use = 1"
        } else {
            remotePredicate = ""
        }
        let join = indexed ? "JOIN" : "CROSS JOIN"
        var sql = """
        SELECT c.rowid AS candidate_rowid
        FROM knowledge_chunks c
        \(join) knowledge_sources s ON s.id = c.source_id
        JOIN knowledge_versions v ON v.id = c.version_id AND v.source_id = s.id
        WHERE s.deleted_at IS NULL AND s.current_version_id = c.version_id
          AND v.parse_state = 'ready'
          AND (s.workspace_id IS NULL OR s.workspace_id = ?)
          \(remotePredicate)
        """
        if indexed {
            let expression = words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
            sql += " AND (c.rowid IN (SELECT rowid FROM knowledge_words WHERE knowledge_words MATCH ?) OR c.rowid IN (SELECT rowid FROM knowledge_trigrams WHERE knowledge_trigrams MATCH ?))"
            arguments += [expression, expression]
        }
        // Sort and cap only identities. Sorting c.* can materialize hundreds of
        // megabytes of body/JSON data before the first candidate is returned.
        // Bodies are read on demand in this same database operation and remain
        // subject to source, chunk and immutable blob validation.
        sql += " ORDER BY c.rowid LIMIT 20001"
        return (sql, arguments)
    }

    private static func rank(normalizedQuery: String, normalizedText: String,
                             source: KnowledgeSource) -> Int {
        let title = normalize(source.title)
        return (normalizedText.contains(normalizedQuery) ? 1_000 : 0) +
            (title.contains(normalizedQuery) ? 100 : 0)
    }

    private static func snippet(_ text: String, query: String) -> String {
        let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])?.lowerBound ?? text.startIndex
        let start = text.index(match, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
        var result = ""
        var bytes = 0
        for scalar in text[start...].unicodeScalars {
            let value = String(scalar)
            let size = value.utf8.count
            guard bytes + size <= 1_200 else { break }
            result.append(contentsOf: value)
            bytes += size
        }
        return result
    }

}
