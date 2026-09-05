import Foundation
import GRDB
import MiraCore

extension SQLiteMiraStore {
    static func knowledgeTableNames(in db: Database) throws -> Set<String> {
        var result: Set<String> = ["managed_blobs", "knowledge_sources", "source_versions", "source_chunks", "source_usages"]
        for prefix in ["knowledge_words", "knowledge_trigrams"] where try db.tableExists(prefix) {
            result.formUnion([prefix, prefix + "_data", prefix + "_idx", prefix + "_content", prefix + "_docsize", prefix + "_config"])
        }
        return result
    }

    static func validateKnowledgeContents(in db: Database) throws {
        func fail() -> MiraError { .init(.storage, "The knowledge backup contents are inconsistent.") }
        func digestValid(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        func optionalDate(_ value: Date?, _ stored: Double?) -> Bool {
            if let value { return memoryTimestampMatches(value, stored) }
            return stored == nil
        }
        var sources: [KnowledgeSourceID: KnowledgeSource] = [:]
        var versions: [SourceVersionID: KnowledgeSourceVersion] = [:]
        var chunks: [SourceChunkID: SourceChunkSummary] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM managed_blobs") {
            let digest: String = row["digest"], bytes: Int = row["byte_count"], created: Double = row["created_at"]
            let pending: Double? = row["pending_deletion_at"]
            guard digestValid(digest), (0...10_485_760).contains(bytes), created.isFinite, pending?.isFinite ?? true else { throw fail() }
            if pending != nil, try Int.fetchOne(db, sql: "SELECT 1 FROM source_versions WHERE content_hash = ? LIMIT 1", arguments: [digest]) != nil { throw fail() }
        }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM knowledge_sources") {
            let value: KnowledgeSource = try decode(row["source_json"])
            guard id(value.id) == row["id"] as String, value.workspaceID.map(id) == row["workspace_id"] as String?, value.title == row["title"] as String,
                  value.currentVersionID.map(id) == row["current_version_id"] as String?, value.allowsRemoteUse == (row["allows_remote_use"] as Int != 0),
                  value.revision == row["revision"] as Int, value.revision > 0, value.title.utf8.count <= 1_024,
                  memoryTimestampMatches(value.createdAt, row["created_at"]), memoryTimestampMatches(value.updatedAt, row["updated_at"]), optionalDate(value.deletedAt, row["deleted_at"]) else { throw fail() }
            if value.deletedAt != nil {
                guard value.title == "Deleted source", value.currentVersionID == nil, !value.allowsRemoteUse,
                      try Int.fetchOne(db, sql: "SELECT 1 FROM source_versions WHERE source_id = ? LIMIT 1", arguments: [id(value.id)]) == nil else { throw fail() }
            }
            sources[value.id] = value
        }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM source_versions") {
            let value: KnowledgeSourceVersion = try decode(row["version_json"])
            guard id(value.id) == row["id"] as String, id(value.sourceID) == row["source_id"] as String,
                  value.contentHash == row["content_hash"] as String, digestValid(value.contentHash), value.byteCount == row["byte_count"] as Int,
                  (0...10_485_760).contains(value.byteCount), value.parseState.rawValue == row["parse_state"] as String,
                  memoryTimestampMatches(value.createdAt, row["created_at"]), value.parserVersion == MarkdownChunker.parserVersion,
                  (value.parseState == .failed) == (value.parseError != nil), let source = sources[value.sourceID], source.deletedAt == nil,
                  try Int.fetchOne(db, sql: "SELECT byte_count FROM managed_blobs WHERE digest = ?", arguments: [value.contentHash]) == value.byteCount else { throw fail() }
            if value.parseState == .failed {
                guard try Int.fetchOne(db, sql: "SELECT 1 FROM source_chunks WHERE version_id = ? LIMIT 1", arguments: [id(value.id)]) == nil else { throw fail() }
            }
            versions[value.id] = value
        }
        for source in sources.values {
            if let current = source.currentVersionID {
                guard let version = versions[current], version.sourceID == source.id, version.parseState == .ready else { throw fail() }
            }
        }
        var expectedSequence: [SourceVersionID: Int] = [:], expectedOffset: [SourceVersionID: Int] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT rowid, * FROM source_chunks ORDER BY version_id, sequence") {
            let value: SourceChunkSummary = try decode(row["summary_json"]), text: String = row["text"]
            guard id(value.id) == row["id"] as String, id(value.sourceID) == row["source_id"] as String,
                  id(value.sourceVersionID) == row["version_id"] as String, value.sequence == row["sequence"] as Int,
                  value.sequence == expectedSequence[value.sourceVersionID, default: 0],
                  let version = versions[value.sourceVersionID], version.sourceID == value.sourceID, version.parseState == .ready,
                  let source = sources[value.sourceID], text.utf8.count <= 8_192, !text.isEmpty,
                  value.startUTF8Offset >= 0, value.endUTF8Offset <= version.byteCount,
                  value.endUTF8Offset - value.startUTF8Offset == text.utf8.count,
                  value.startLine > 0, value.endLine >= value.startLine, value.headingPath.count <= 6,
                  value.headingPath.allSatisfy({ $0.utf8.count <= 512 }), value.contentHash == knowledgeHash(Data(text.utf8)) else { throw fail() }
            if let offset = expectedOffset[value.sourceVersionID] { guard value.startUTF8Offset == offset else { throw fail() } }
            else { guard value.startUTF8Offset == 0 || value.startUTF8Offset == 3 else { throw fail() } }
            expectedSequence[value.sourceVersionID] = value.sequence + 1; expectedOffset[value.sourceVersionID] = value.endUTF8Offset
            let normalized = normalizeKnowledge(source.title + "\n" + value.headingPath.joined(separator: "\n") + "\n" + text)
            guard normalized == row["normalized_text"] as String else { throw fail() }
            for index in ["knowledge_words", "knowledge_trigrams"] where try db.tableExists(index) {
                guard try String.fetchOne(db, sql: "SELECT content FROM \(index) WHERE rowid = ?", arguments: [row["rowid"] as Int64]) == normalized else { throw fail() }
            }
            chunks[value.id] = value
        }
        for (versionID, offset) in expectedOffset { guard versions[versionID]?.byteCount == offset else { throw fail() } }
        for index in ["knowledge_words", "knowledge_trigrams"] where try db.tableExists(index) {
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(index)") == chunks.count else { throw fail() }
        }
        for row in try Row.fetchAll(db, sql: "SELECT u.*,e.body_purged_at,c.workspace_id FROM source_usages u JOIN executions e ON e.id = u.execution_id JOIN conversations c ON c.id = e.conversation_id") {
            guard let sourceUUID = UUID(uuidString: row["source_id"]), let source = sources[.init(sourceUUID)],
                  let versionUUID = UUID(uuidString: row["version_id"]), (row["created_at"] as Double).isFinite,
                  source.workspaceID == nil || source.workspaceID.map(id) == row["workspace_id"] as String? else { throw fail() }
            let purged = row["body_purged_at"] as Double? != nil, key: String = row["chunk_key"]
            guard key.isEmpty || UUID(uuidString: key) != nil else { throw fail() }
            if source.deletedAt != nil || !source.allowsRemoteUse { guard purged else { throw fail() } }
            if source.deletedAt == nil {
                guard let version = versions[.init(versionUUID)], version.sourceID == source.id else { throw fail() }
                if !key.isEmpty {
                    guard let uuid = UUID(uuidString: key), let chunk = chunks[.init(uuid)], chunk.sourceVersionID == version.id, chunk.sourceID == source.id else { throw fail() }
                }
            }
        }
    }
}
