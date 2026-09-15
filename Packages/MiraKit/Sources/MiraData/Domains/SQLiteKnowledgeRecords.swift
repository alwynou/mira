import Foundation
import CryptoKit
import GRDB
import MiraCore

extension SQLiteKnowledgeStore {
    static var corrupt: MiraError { .init(.storage, "The knowledge record is inconsistent.") }
    static var invalid: MiraError { .init(.invalidInput, "The knowledge input is invalid.") }
    static var conflict: MiraError { .init(.conflict, "The source revision or operation is out of date.") }
    static var unavailable: MiraError { .init(.notFound, "The source does not exist or is unavailable.") }
    static var unauthorized: MiraError { .init(.unauthorized, "The knowledge source is unavailable for this destination.") }
    static func key<Tag>(_ id: EntityID<Tag>) -> String { key(id.rawValue) }
    static func key(_ id: UUID) -> String { id.uuidString.lowercased() }
    static func uuid(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value), key(id) == value else { throw corrupt }; return id
    }
    static func date(_ value: Date) throws { guard value.timeIntervalSince1970.isFinite else { throw invalid } }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let bytes = try SessionCodec.encode(value); guard bytes.count <= 131_072 else { throw invalid }; return bytes
    }
    static func decode<T: Decodable>(_ bytes: Data) throws -> T {
        guard !bytes.isEmpty, bytes.count <= 131_072 else { throw corrupt }
        do { return try SessionCodec.decode(T.self, from: bytes) } catch { throw corrupt }
    }
    static func validateScope(_ scope: KnowledgeReadScope, in db: Database) throws {
        if let route = scope.destination.modelRoute { try SQLiteAgentModelSettings.validateFrozenIdentity(route, in: db) }
        do { try SQLiteWorkspaceStore.validatePolicy(scope.workspaceID, connectionID: scope.destination.modelRoute?.connectionID, in: db) }
        catch let error as MiraError where error.code == .notFound || error.code == .unauthorized { throw unauthorized }
    }
    static func record(_ row: Row) throws -> KnowledgeSource {
        let value: KnowledgeSource = try decode(row["json"])
        guard value.revision > 0, !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.title.utf8.count <= 1_024, value.createdAt.timeIntervalSince1970.isFinite,
              value.updatedAt.timeIntervalSince1970.isFinite, value.deletedAt?.timeIntervalSince1970.isFinite ?? true,
              value.deletedAt == nil || (value.currentVersionID == nil && !value.allowsRemoteUse),
              key(value.id) == row["id"] as String, value.workspaceID.map(key) == row["workspace_id"] as String?,
              value.title == row["title"] as String, value.currentVersionID.map(key) == row["current_version_id"] as String?,
              value.allowsRemoteUse == row["allows_remote_use"] as Bool, value.revision == row["revision"] as Int,
              value.updatedAt.timeIntervalSince1970 == row["updated_at"] as Double,
              value.deletedAt?.timeIntervalSince1970 == row["deleted_at"] as Double? else { throw corrupt }
        return value
    }
    static func source(_ id: KnowledgeSourceID, scope: KnowledgeReadScope, in db: Database) throws -> KnowledgeSource {
        try validateScope(scope, in: db)
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM knowledge_sources WHERE id = ?", arguments: [key(id)]) else { throw unavailable }
        let value = try record(row)
        guard value.deletedAt == nil, value.workspaceID == nil || value.workspaceID == scope.workspaceID else { throw unavailable }
        if let connection = scope.destination.modelRoute?.connectionID {
            guard value.allowsRemoteUse else { throw unauthorized }
            try SQLiteWorkspaceStore.validatePolicy(value.workspaceID, connectionID: connection, in: db)
        }
        return value
    }
    static func version(_ row: Row) throws -> KnowledgeSourceVersion {
        let value: KnowledgeSourceVersion = try decode(row["json"])
        guard key(value.id) == row["id"] as String, key(value.sourceID) == row["source_id"] as String,
              value.contentHash == row["content_hash"] as String, isHash(value.contentHash),
              value.byteCount == row["byte_count"] as Int, (0...MarkdownChunker.maxFileBytes).contains(value.byteCount),
              value.parseState.rawValue == row["parse_state"] as String,
              (value.parseState == .failed) == (value.parseError != nil), value.parserVersion == MarkdownChunker.parserVersion,
              value.createdAt.timeIntervalSince1970.isFinite, value.createdAt.timeIntervalSince1970 == row["created_at"] as Double else { throw corrupt }
        return value
    }
    static func version(_ id: SourceVersionID, sourceID: KnowledgeSourceID, in db: Database) throws -> KnowledgeSourceVersion {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM knowledge_versions WHERE id = ? AND source_id = ?", arguments: [key(id), key(sourceID)]) else { throw unavailable }
        return try version(row)
    }
    static func chunk(_ row: Row) throws -> SourceChunk {
        let summary: SourceChunkSummary = try decode(row["json"]), text: String = row["text"]
        guard key(summary.id) == row["id"] as String, key(summary.sourceID) == row["source_id"] as String,
              key(summary.sourceVersionID) == row["version_id"] as String, summary.sequence == row["sequence"] as Int,
              summary.sequence >= 0, summary.startLine >= 1, summary.endLine >= summary.startLine,
              summary.startUTF8Offset >= 0, summary.endUTF8Offset > summary.startUTF8Offset,
              summary.endUTF8Offset - summary.startUTF8Offset == text.utf8.count, text.utf8.count <= 8_192,
              summary.headingPath.count <= 6, summary.headingPath.allSatisfy({ $0.utf8.count <= 512 }),
              hash(Data(text.utf8)) == summary.contentHash else { throw corrupt }
        return .init(summary: summary, text: text)
    }
    static func chunk(_ id: SourceChunkID, in db: Database) throws -> SourceChunk {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM knowledge_chunks WHERE id = ?", arguments: [key(id)]) else { throw unavailable }
        return try chunk(row)
    }
    func verifiedChunk(_ id: SourceChunkID, scope: KnowledgeReadScope, in db: Database) throws -> SourceCitationDetail {
        let value = try Self.chunk(id, in: db)
        let source = try Self.source(value.summary.sourceID, scope: scope, in: db)
        let version = try Self.version(value.summary.sourceVersionID, sourceID: source.id, in: db)
        guard version.parseState == .ready else { throw Self.corrupt }
        let data = try blobs.read(version.contentHash)
        guard data.count == version.byteCount, value.summary.endUTF8Offset <= data.count,
              Data(data[value.summary.startUTF8Offset..<value.summary.endUTF8Offset]) == Data(value.text.utf8) else { throw Self.corrupt }
        return .init(source: source, version: version, chunk: value)
    }
    static func write(_ value: KnowledgeSource, insert: Bool, in db: Database) throws {
        if insert {
            try db.execute(sql: "INSERT INTO knowledge_sources(id, workspace_id, title, current_version_id, allows_remote_use, revision, updated_at, deleted_at, json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [key(value.id), value.workspaceID.map(key), value.title, value.currentVersionID.map(key), value.allowsRemoteUse, value.revision, value.updatedAt.timeIntervalSince1970, value.deletedAt?.timeIntervalSince1970, try encode(value)])
        } else {
            try db.execute(sql: "UPDATE knowledge_sources SET title = ?, current_version_id = ?, allows_remote_use = ?, revision = ?, updated_at = ?, deleted_at = ?, json = ? WHERE id = ?", arguments: [value.title, value.currentVersionID.map(key), value.allowsRemoteUse, value.revision, value.updatedAt.timeIntervalSince1970, value.deletedAt?.timeIntervalSince1970, try encode(value), key(value.id)])
        }
    }
    static func mutable(_ id: KnowledgeSourceID, workspaceID: WorkspaceID?, expected: Int, in db: Database) throws -> KnowledgeSource {
        let value = try source(id, scope: .init(workspaceID: workspaceID, destination: .local), in: db)
        guard value.workspaceID == workspaceID, value.revision == expected, expected > 0, expected < Int.max else { throw conflict }
        return value
    }
    static func fingerprint(kind: String, sourceID: KnowledgeSourceID?, workspaceID: WorkspaceID?, expected: Int?, title: String? = nil, hash: String? = nil) throws -> String {
        struct Identity: Encodable {
            let kind: String; let sourceID: KnowledgeSourceID?; let workspaceID: WorkspaceID?; let expected: Int?; let title: String?; let hash: String?
        }
        return Self.hash(try encode(Identity(kind: kind, sourceID: sourceID, workspaceID: workspaceID, expected: expected, title: title, hash: hash)))
    }
    static func operation<T: Decodable>(_ id: UUID, kind: String, request: String, in db: Database) throws -> T? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM knowledge_operations WHERE operation_id = ?", arguments: [key(id)]) else { return nil }
        guard row["kind"] as String == kind, row["request_hash"] as String? == request,
              let bytes: Data = row["receipt_json"] else { throw conflict }
        let value: T = try decode(bytes)
        let source: KnowledgeSource
        if let receipt = value as? KnowledgeImportReceipt, kind == "import" {
            source = receipt.source
            guard receipt.version.sourceID == source.id, isHash(receipt.version.contentHash),
                  (0...MarkdownChunker.maxFileBytes).contains(receipt.version.byteCount),
                  receipt.version.parserVersion == MarkdownChunker.parserVersion,
                  (receipt.version.parseState == .failed) == (receipt.version.parseError != nil),
                  receipt.version.createdAt.timeIntervalSince1970.isFinite else { throw corrupt }
            guard try version(receipt.version.id, sourceID: source.id, in: db) == receipt.version else { throw corrupt }
        } else if let receipt = value as? KnowledgeSource, kind == "allow" { source = receipt }
        else { throw corrupt }
        guard source.revision > 0, source.deletedAt == nil, source.title.utf8.count <= 1_024,
              !source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.createdAt.timeIntervalSince1970.isFinite, source.updatedAt.timeIntervalSince1970.isFinite,
              key(source.id) == row["source_id"] as String else { throw corrupt }
        let current = try maintenanceSource(source.id, in: db)
        guard current.deletedAt == nil, current.workspaceID == source.workspaceID else { throw conflict }
        guard source.createdAt == current.createdAt, source.title == current.title,
              source.revision <= current.revision else { throw corrupt }
        return value
    }
    static func saveOperation<T: Encodable>(_ id: UUID, kind: String, request: String, sourceID: KnowledgeSourceID, receipt: T, in db: Database) throws {
        try db.execute(sql: "INSERT INTO knowledge_operations(operation_id, kind, request_hash, source_id, receipt_json) VALUES (?, ?, ?, ?, ?)", arguments: [key(id), kind, request, key(sourceID), try encode(receipt)])
    }
}
