import Foundation
import NaturalLanguage
import GRDB
import MiraCore

extension SQLiteMemoryStore {
    static func validateDestination(_ request: AgentContextRequest, in db: Database) throws {
        if let route = request.destination.modelRoute { try SQLiteAgentModelSettings.validateFrozenIdentity(route, in: db) }
        do { try SQLiteWorkspaceStore.validatePolicy(request.workspaceID, connectionID: request.destination.modelRoute?.connectionID, in: db) }
        catch let error as MiraError where error.code == .notFound || error.code == .unauthorized { throw unauthorized }
    }
    static func recall(_ id: MemoryID, request: AgentContextRequest, at: Date, in db: Database) throws -> Memory {
        try date(at); try validateDestination(request, in: db)
        let memory: Memory
        do { memory = try read(id, workspaceID: request.workspaceID, in: db) }
        catch let error as MiraError where error.code == .notFound { throw unauthorized }
        guard memory.isCurrent, memory.deletedAt == nil, let draft = memory.draft,
              draft.validFrom.map({ $0 <= at }) ?? true, draft.validUntil.map({ $0 > at }) ?? true else { throw unauthorized }
        let connectionID = request.destination.modelRoute?.connectionID
        if let connectionID { guard memory.canRecall(in: request.workspaceID, connectionID: connectionID, at: at) else { throw unauthorized } }
        for evidence in try evidence(id, in: db) {
            guard evidence.bodyPurgedAt == nil else { throw unauthorized }
            do { try SQLiteWorkspaceStore.validatePolicy(evidence.sourceWorkspaceID, connectionID: connectionID, in: db) }
            catch let error as MiraError where error.code == .notFound || error.code == .unauthorized { throw unauthorized }
        }
        return memory
    }
    static func search(query: String, workspaceID: WorkspaceID?, states: Set<MemoryState>, request: AgentContextRequest?, limit: Int, at: Date?, in db: Database) throws -> MemorySearchResult {
        guard (1...128).contains(limit), query.unicodeScalars.count <= 500 else { throw invalid }
        if let at { try date(at) }
        if let workspaceID { _ = try SQLiteWorkspaceStore.read(workspaceID, in: db) }
        guard !states.isEmpty else { return .init(memories: []) }
        var conditions = ["m.state IN (\(states.map { _ in "?" }.joined(separator: ",")))", "m.scope IN (?, ?)"]
        var arguments = StatementArguments(states.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue))
        arguments += ["global", workspaceID.map { MemoryScope.workspace($0).key } ?? "global"]
        if let request {
            conditions += ["m.forgotten_at IS NULL", "m.deleted_at IS NULL", "m.draft_json IS NOT NULL", "m.superseded_by IS NULL"]
            guard let at else { throw invalid }
            conditions += ["(json_extract(m.draft_json, '$.validFrom') IS NULL OR json_extract(m.draft_json, '$.validFrom') <= ?)", "(json_extract(m.draft_json, '$.validUntil') IS NULL OR json_extract(m.draft_json, '$.validUntil') > ?)"]
            arguments += [at.timeIntervalSinceReferenceDate, at.timeIntervalSinceReferenceDate]
            if let connectionID = request.destination.modelRoute?.connectionID {
                conditions += ["json_extract(m.draft_json, '$.allowsRemoteUse') = 1", "(json_extract(m.draft_json, '$.allowedConnectionIDs') IS NULL OR EXISTS (SELECT 1 FROM json_each(json_extract(m.draft_json, '$.allowedConnectionIDs')) WHERE lower(json_extract(value, '$.rawValue')) = ?))"]
                arguments += [key(connectionID)]
                // Validate current workspace rows before using their IDs in the SQL eligibility filter.
                let rows = try Row.fetchAll(db, sql: "SELECT id FROM business_workspaces ORDER BY id LIMIT 1025")
                guard rows.count <= 1024 else { throw corrupt }
                let permitted = try rows.compactMap { row -> String? in
                    let id = WorkspaceID(try uuid(row["id"])), workspace = try SQLiteWorkspaceStore.read(id, in: db)
                    return workspace.allowsRemoteSend && (workspace.allowedConnectionIDs?.contains(connectionID) ?? true) ? key(id) : nil
                }
                let blocked = permitted.isEmpty ? "e.source_workspace_id IS NOT NULL" : "e.source_workspace_id IS NOT NULL AND e.source_workspace_id NOT IN (\(permitted.map { _ in "?" }.joined(separator: ",")))"
                conditions.append("NOT EXISTS (SELECT 1 FROM memory_evidence e WHERE e.memory_id = m.id AND (\(blocked)))")
                arguments += StatementArguments(permitted)
            }
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var from = "memory_records m", rank = "0.0"
        if !trimmed.isEmpty, request != nil {
            let expansion = MemoryRecallPlanner.expand(query: trimmed)
            var shorts = memorySearchShortCJKTerms(trimmed, maximum: 12)
            for alias in expansion.aliasTerms where alias.unicodeScalars.count == 2 && alias.unicodeScalars.allSatisfy(isCJKScalar) {
                if !shorts.contains(alias) && shorts.count < 12 { shorts.append(alias) }
            }
            var seen = Set<String>()
            let terms = Array((memorySearchTerms(trimmed) + expansion.aliasTerms.flatMap(memorySearchTerms)).filter { seen.insert($0).inserted }.prefix(24 - shorts.count))
            if trimmed.count < 3 && expansion.aliasTerms.isEmpty {
                conditions.append("lower(json_extract(m.draft_json, '$.content')) LIKE lower(?) ESCAPE '\\'")
                arguments += [escapedMemoryLikePattern(trimmed)]
            } else if terms.isEmpty && shorts.isEmpty { conditions.append("0 = 1") }
            else if !shorts.isEmpty {
                var parts = shorts.map { _ in "lower(json_extract(m.draft_json, '$.content')) LIKE lower(?) ESCAPE '\\'" }
                arguments += StatementArguments(shorts.map(escapedMemoryLikePattern))
                if !terms.isEmpty {
                    parts.append("m.id IN (SELECT memory_id FROM memory_search WHERE memory_search MATCH ?)")
                    arguments += [terms.map { "\"\($0)\"" }.joined(separator: " OR ")]
                }
                conditions.append("(\(parts.joined(separator: " OR ")))")
                // Keep the broad short-CJK OR recall and rank an exact literal query first.
                // This placeholder follows every WHERE argument in SQLite's positional order.
                rank = "CASE WHEN lower(json_extract(m.draft_json, '$.content')) LIKE lower(?) ESCAPE '\\' THEN -1 ELSE 0 END"
                arguments += [escapedMemoryLikePattern(trimmed)]
            } else {
                from += " JOIN memory_search ON memory_search.memory_id = m.id"
                conditions.append("memory_search MATCH ?"); arguments += [terms.map { "\"\($0)\"" }.joined(separator: " OR ")]
                rank = "bm25(memory_search)"
            }
        } else if !trimmed.isEmpty {
            conditions.append("lower(json_extract(m.draft_json, '$.content')) LIKE lower(?) ESCAPE '\\'")
            arguments += [escapedMemoryLikePattern(trimmed)]
        }
        // All privacy and lifecycle filters precede this cap; a blocked prefix cannot hide later eligible records.
        let rows = try Row.fetchAll(db, sql: "SELECT m.* FROM \(from) WHERE \(conditions.joined(separator: " AND ")) ORDER BY \(rank), m.id LIMIT 2001", arguments: arguments)
        var result: [Memory] = []
        for row in rows {
            let memory = try record(row)
            if let request, let at { _ = try recall(memory.id, request: request, at: at, in: db) }
            result.append(memory); if result.count > limit { break }
        }
        return .init(memories: Array(result.prefix(limit)), isTruncated: result.count > limit || rows.count > 2000)
    }
    /// Produces terms compatible with the trigram index while treating
    /// punctuation as a separator. CJK runs are emitted as bounded overlapping
    /// three-scalar grams; short CJK words are handled by
    /// `memorySearchShortCJKTerms` because the trigram index cannot match them.
    static func memorySearchTerms(_ query: String) -> [String] {
        let stopWords: Set<String> = ["a", "an", "and", "are", "for", "in", "is", "it", "my", "of", "on", "or", "the", "to"]
        var terms: [String] = []
        var latin = ""
        var cjkRun: [Character] = []

        func flushLatin() {
            guard !latin.isEmpty else { return }
            let normalized = latin.lowercased()
            if !stopWords.contains(normalized) { terms.append(normalized) }
            latin.removeAll(keepingCapacity: true)
        }
        func flushCJK() {
            guard !cjkRun.isEmpty else { return }
            if cjkRun.count >= 3 {
                for index in 0...(cjkRun.count - 3) {
                    terms.append(String(cjkRun[index..<(index + 3)]))
                    if terms.count >= 24 { break }
                }
            }
            cjkRun.removeAll(keepingCapacity: true)
        }

        for character in query {
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
                flushLatin(); flushCJK(); continue
            }
            let value = scalar.value
            let isCJK = (0x3400...0x4DBF).contains(value) ||
                (0x4E00...0x9FFF).contains(value) ||
                (0xF900...0xFAFF).contains(value) ||
                (0x20000...0x2FA1F).contains(value)
            if isCJK {
                flushLatin()
                cjkRun.append(character)
            } else if CharacterSet.alphanumerics.contains(scalar) {
                flushCJK()
                latin.append(character)
            } else {
                flushLatin(); flushCJK()
            }
            if terms.count >= 24 { break }
        }
        flushLatin(); flushCJK()
        return Array(terms.prefix(24))
    }

    /// Returns only native Natural Language word tokens that are exactly two
    /// CJK scalars. Single-character terms are intentionally discarded, and
    /// arbitrary overlapping bigrams are never synthesized.
    static func memorySearchShortCJKTerms(_ query: String, maximum: Int = 24) -> [String] {
        guard maximum > 0, query.unicodeScalars.contains(where: isCJKScalar) else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.simplifiedChinese)
        tokenizer.string = query
        let range = query.startIndex..<query.endIndex
        var terms: [String] = []
        var seen = Set<String>()
        for tokenRange in tokenizer.tokens(for: range) {
            let token = String(query[tokenRange])
            guard token.unicodeScalars.count == 2,
                  token.unicodeScalars.allSatisfy(isCJKScalar), seen.insert(token).inserted else { continue }
            terms.append(token)
            if terms.count == maximum { break }
        }
        return terms
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value) ||
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0xF900...0xFAFF).contains(scalar.value) ||
            (0x20000...0x2FA1F).contains(scalar.value)
    }

    private static func escapedMemoryLikePattern(_ term: String) -> String {
        let escaped = term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

}
