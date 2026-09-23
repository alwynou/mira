import Foundation
import GRDB
import MiraCore

/// Host-owned knowledge management reads. These methods intentionally do not
/// accept a model route and never participate in model source authorization.
extension SQLiteKnowledgeStore {
    public func knowledgeManagementPage(_ query: KnowledgeManagementQuery) async throws -> KnowledgeManagementPage {
        guard (1...100).contains(query.limit), query.query.unicodeScalars.count <= 500 else { throw Self.invalid }
        return try await owner.read { db in
            db.add(function: Self.managementNormalizeFunction)
            return try Self.managementPage(query, in: db)
        }
    }

    public func knowledgeDocumentPage(_ id: KnowledgeSourceID, versionID: SourceVersionID,
                                      scope: KnowledgeReadScope, afterSequence: Int?,
                                      limit: Int) async throws -> KnowledgeDocumentPage {
        guard (1...16).contains(limit), afterSequence.map({ $0 >= 0 }) ?? true else { throw Self.invalid }
        return try await owner.read { db in
            try self.documentPage(id, versionID: versionID, scope: scope,
                                  afterSequence: afterSequence, limit: limit, in: db)
        }
    }

    private static func managementPage(_ query: KnowledgeManagementQuery, in db: Database) throws -> KnowledgeManagementPage {
        if case .workspace(let workspaceID) = query.scope {
            _ = try SQLiteWorkspaceStore.read(workspaceID, in: db)
        }

        let trimmed = query.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = normalize(trimmed).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let key = query.key
        var conditions = ["s.deleted_at IS NULL"]
        var arguments = StatementArguments()
        switch query.scope {
        case .all: break
        case .inbox:
            conditions.append("s.workspace_id IS NULL")
        case .workspace(let workspaceID):
            conditions.append("s.workspace_id = ?")
            arguments += [Self.key(workspaceID)]
        }
        switch query.status {
        case .all: break
        case .searchable:
            conditions.append("EXISTS (SELECT 1 FROM knowledge_versions cv WHERE cv.id = s.current_version_id AND cv.source_id = s.id AND cv.parse_state = 'ready')")
        case .localOnly:
            conditions.append("s.allows_remote_use = 0")
        case .needsAttention:
            conditions.append("EXISTS (SELECT 1 FROM knowledge_versions lv WHERE lv.id = (SELECT latest.id FROM knowledge_versions latest WHERE latest.source_id = s.id ORDER BY latest.created_at DESC, latest.id DESC LIMIT 1) AND lv.parse_state = 'failed')")
        }
        if !terms.isEmpty {
            // The SQL predicate narrows the bounded scan. Swift verifies the
            // normalized body match before returning a navigation summary.
            let patterns = terms.map(managementLikePattern)
            let titleTerms = terms.map { _ in "mira_knowledge_normalize(s.title) LIKE mira_knowledge_normalize(?) ESCAPE '\\'" }.joined(separator: " AND ")
            let bodyTerms = terms.map { _ in "c.normalized_text LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
            conditions.append("((\(titleTerms)) OR EXISTS (SELECT 1 FROM knowledge_chunks c JOIN knowledge_versions v ON v.id = c.version_id AND v.source_id = c.source_id WHERE c.source_id = s.id AND c.version_id = s.current_version_id AND v.parse_state = 'ready' AND \(bodyTerms)))")
            arguments += StatementArguments(patterns)
            arguments += StatementArguments(patterns)
        }
        if let cursor = query.cursor {
            guard cursor.queryKey == key else { throw Self.invalidCursor }
            switch query.order {
            case .newestFirst:
                guard let updatedAt = cursor.updatedAt, updatedAt.timeIntervalSince1970.isFinite else { throw Self.invalidCursor }
                let value = updatedAt.timeIntervalSince1970
                conditions.append("(s.updated_at < ? OR (s.updated_at = ? AND s.id > ?))")
                arguments += [value, value, Self.key(cursor.sourceID)]
            case .title:
                guard let title = cursor.title, !title.isEmpty else { throw Self.invalidCursor }
                conditions.append("(s.title > ? OR (s.title = ? AND s.id > ?))")
                arguments += [title, title, Self.key(cursor.sourceID)]
            }
        }

        let order: String
        switch query.order {
        case .newestFirst: order = "s.updated_at DESC, s.id ASC"
        case .title: order = "s.title ASC, s.id ASC"
        }
        let scanLimit = query.limit + 1
        let rows = try Row.fetchAll(db,
            sql: "SELECT s.* FROM knowledge_sources s WHERE \(conditions.joined(separator: " AND ")) ORDER BY \(order) LIMIT ?",
            arguments: arguments + [scanLimit])
        let pageRows = Array(rows.prefix(query.limit + 1))
        let hasMorePage = pageRows.count > query.limit
        let visibleRows = Array(pageRows.prefix(query.limit))
        let items = try visibleRows.map {
            try managementItem(source: Self.record($0), queryTerms: terms, in: db)
        }
        guard hasMorePage, let last = items.last else {
            return .init(items: items, nextCursor: nil, isTruncated: false)
        }
        let next: KnowledgeManagementCursor
        switch query.order {
        case .newestFirst:
            next = .init(updatedAt: last.source.updatedAt, sourceID: last.source.id, queryKey: key)
        case .title:
            next = .init(title: last.source.title, sourceID: last.source.id, queryKey: key)
        }
        return .init(items: items, nextCursor: next, isTruncated: false)
    }

    private static func managementItem(source: KnowledgeSource, queryTerms: [String], in db: Database) throws -> KnowledgeManagementItem {
        let current = try source.currentVersionID.map { try version($0, sourceID: source.id, in: db) }
        let latestRow = try Row.fetchOne(db,
            sql: "SELECT * FROM knowledge_versions WHERE source_id = ? ORDER BY created_at DESC, id DESC LIMIT 1",
            arguments: [key(source.id)])
        let latest = try latestRow.map(version)
        let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM knowledge_versions WHERE source_id = ?",
                                     arguments: [key(source.id)]) ?? 0
        guard count >= 0, (latestRow == nil) == (count == 0) else { throw corrupt }

        guard !queryTerms.isEmpty else {
            let excerpt: String
            if let current, current.parseState == .ready,
               let row = try Row.fetchOne(db, sql: "SELECT text FROM knowledge_chunks WHERE source_id = ? AND version_id = ? ORDER BY sequence ASC LIMIT 1", arguments: [key(source.id), key(current.id)]) {
                excerpt = bounded(row["text"] as String)
            } else {
                excerpt = bounded(source.title)
            }
            return .init(source: source, currentVersion: current, latestVersion: latest,
                         versionCount: count, excerpt: excerpt, match: nil)
        }
        let title = normalize(source.title)
        if queryTerms.allSatisfy({ title.contains($0) }) {
            return .init(source: source, currentVersion: current, latestVersion: latest,
                         versionCount: count, excerpt: bounded(source.title), match: nil)
        }
        guard let current, current.parseState == .ready else {
            return .init(source: source, currentVersion: current, latestVersion: latest,
                         versionCount: count, excerpt: "", match: nil)
        }
        let chunkTerms = queryTerms.map { _ in "normalized_text LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM knowledge_chunks
            WHERE source_id = ? AND version_id = ?
              AND \(chunkTerms)
            ORDER BY sequence ASC LIMIT 1
            """, arguments: StatementArguments([key(source.id), key(current.id)] + queryTerms.map(managementLikePattern)))
        for row in rows {
            let chunk = try Self.chunk(row)
            let normalizedText: String = row["normalized_text"]
            guard chunk.summary.sourceID == source.id, chunk.summary.sourceVersionID == current.id,
                  normalizedText == normalize(source.title + "\n" + chunk.summary.headingPath.joined(separator: "\n") + "\n" + chunk.text),
                  queryTerms.allSatisfy({ normalizedText.contains($0) }) else { continue }
            return .init(source: source, currentVersion: current, latestVersion: latest,
                         versionCount: count, excerpt: boundedSnippet(chunk.text, query: queryTerms[0]),
                         match: chunk.summary)
        }
        return .init(source: source, currentVersion: current, latestVersion: latest,
                     versionCount: count, excerpt: "", match: nil)
    }

    private func documentPage(_ id: KnowledgeSourceID, versionID: SourceVersionID,
                              scope: KnowledgeReadScope, afterSequence: Int?, limit: Int,
                              in db: Database) throws -> KnowledgeDocumentPage {
        try Self.validateScope(scope, in: db)
        let source = try Self.source(id, scope: scope, in: db)
        let version = try Self.version(versionID, sourceID: source.id, in: db)
        guard version.parseState == .ready else { throw Self.corrupt }
        let blob = try blobs.read(version.contentHash)
        guard blob.count == version.byteCount else { throw Self.corrupt }
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM knowledge_chunks
            WHERE source_id = ? AND version_id = ? AND sequence > ?
            ORDER BY sequence ASC LIMIT ?
            """, arguments: [Self.key(source.id), Self.key(version.id), afterSequence ?? -1, limit + 1])
        let hasMore = rows.count > limit
        let chunks = try rows.prefix(limit).map { row -> SourceChunk in
            let chunk = try Self.chunk(row)
            guard chunk.summary.sourceID == source.id, chunk.summary.sourceVersionID == version.id,
                  chunk.summary.endUTF8Offset <= blob.count,
                  Data(blob[chunk.summary.startUTF8Offset..<chunk.summary.endUTF8Offset]) == Data(chunk.text.utf8) else {
                throw Self.corrupt
            }
            return chunk
        }
        return .init(source: source, version: version, chunks: chunks,
                     nextSequence: hasMore ? chunks.last?.summary.sequence : nil)
    }

    private static func managementLikePattern(_ value: String) -> String {
        "%" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    private static func bounded(_ value: String) -> String {
        boundedBytes(value, limit: 1_200)
    }

    private static func boundedSnippet(_ text: String, query: String) -> String {
        let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])?.lowerBound ?? text.startIndex
        let start = text.index(match, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
        return boundedBytes(String(text[start...]), limit: 1_200)
    }

    private static func boundedBytes(_ value: String, limit: Int) -> String {
        var result = ""
        var count = 0
        for scalar in value.unicodeScalars {
            let fragment = String(scalar)
            guard count + fragment.utf8.count <= limit else { break }
            result.append(contentsOf: fragment)
            count += fragment.utf8.count
        }
        return result
    }

    private static var invalidCursor: MiraError {
        .init(.invalidInput, "The knowledge management cursor is invalid.")
    }

    private static let managementNormalizeFunction = DatabaseFunction(
        "mira_knowledge_normalize", argumentCount: 1, pure: true
    ) { values in
        guard let first = values.first, case .string(let value) = first.storage else { return nil }
        return normalize(value)
    }
}
