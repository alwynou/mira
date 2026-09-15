import Foundation
import GRDB
import MiraCore

extension SQLiteKnowledgeStore {
    private static let archiveMaximumRecords = 100_000

    /// Knowledge keeps immutable source blobs outside SQLite. The archive module
    /// validates the database graph and returns only blobs referenced by retained
    /// versions; the exporter validates and copies those files under this relative
    /// path.
    public static func archiveModule(blobDirectory: String) throws -> SQLiteArchiveModule {
        try LibraryArchiveIO.validatePath(blobDirectory)
        guard
            !["Business.sqlite", "manifest.json", "Sessions", "Projections"].contains(String(blobDirectory.split(separator: "/")[0]))
        else {
            throw LibraryArchiveIO.invalid
        }
        return try SQLiteArchiveModule(
            identity: .init(name: "knowledge.store", revision: 1),
            schemaStatements: archiveSchemaDefinitions.map(\.1),
            restoration: .preserve
        ) { db, _ in
            try inspectArchive(db: db, blobDirectory: blobDirectory)
        }
    }

    private static func inspectArchive(
        db: Database, blobDirectory: String
    ) throws -> [LibraryArchiveAttachment] {
        let state = try SQLiteLibraryAuthority.readState(in: db)
        guard state.pending == nil,
            try SQLiteLibraryAuthority.availableAuthorization(in: db, libraryID: state.authorization.libraryID)
                == state.authorization,
            try Int.fetchOne(db, sql: "SELECT version FROM knowledge_schema WHERE id = 1") == 1,
            try Int.fetchOne(db, sql: "SELECT count(*) FROM knowledge_schema") == 1
        else { throw LibraryArchiveIO.invalid }

        var sources: [String: KnowledgeSource] = [:]
        try SQLiteArchiveValidation.rows(in: db, table: "knowledge_sources", maximumRows: archiveMaximumRecords) {
            row in
            let value = try record(row)
            let id = key(value.id)
            guard sources[id] == nil else { throw LibraryArchiveIO.invalid }
            sources[id] = value
        }

        var blobs: [String: Int] = [:]
        try SQLiteArchiveValidation.rows(
            in: db, table: "knowledge_blobs", maximumRows: archiveMaximumRecords,
            maximumBytes: ["digest": 64]
        ) { row in
            guard blobs.count < archiveMaximumRecords,
                let digest: String = row["digest"], isHash(digest),
                let byteCount: Int = row["byte_count"], (0...MarkdownChunker.maxFileBytes).contains(byteCount),
                let createdAt: Double = row["created_at"], createdAt.isFinite,
                (row["pending_deletion_at"] as Double?).map({ $0.isFinite }) ?? true,
                blobs[digest] == nil
            else { throw LibraryArchiveIO.invalid }
            blobs[digest] = byteCount
        }

        var versions: [String: KnowledgeSourceVersion] = [:]
        var versionsBySource: [String: Set<String>] = [:]
        var referencedDigests: [String: Int] = [:]
        try SQLiteArchiveValidation.rows(in: db, table: "knowledge_versions", maximumRows: archiveMaximumRecords) {
            row in
            let value = try version(row)
            let id = key(value.id)
            let sourceID = key(value.sourceID)
            guard versions[id] == nil, sources[sourceID] != nil,
                blobs[value.contentHash] == value.byteCount,
                referencedDigests[value.contentHash] == nil || referencedDigests[value.contentHash] == value.byteCount
            else { throw LibraryArchiveIO.invalid }
            versions[id] = value
            versionsBySource[sourceID, default: []].insert(id)
            referencedDigests[value.contentHash] = value.byteCount
        }

        var chunkIDs = Set<String>()
        var chunksByVersion: [String: Int] = [:]
        try SQLiteArchiveValidation.rows(
            in: db, table: "knowledge_chunks", maximumRows: archiveMaximumRecords,
            maximumBytes: ["text": 8_192, "normalized_text": 131_072, "json": 131_072]
        ) { row in
            let value = try chunk(row)
            let id = key(value.id)
            let versionID = key(value.summary.sourceVersionID)
            guard chunkIDs.insert(id).inserted,
                versions[versionID]?.sourceID == value.summary.sourceID,
                key(value.summary.sourceID) == (row["source_id"] as String)
            else { throw LibraryArchiveIO.invalid }
            chunksByVersion[versionID, default: 0] += 1
        }

        for (sourceID, source) in sources {
            let sourceVersions = versionsBySource[sourceID] ?? []
            if source.deletedAt != nil {
                guard source.currentVersionID == nil, !source.allowsRemoteUse, sourceVersions.isEmpty else {
                    throw LibraryArchiveIO.invalid
                }
            } else if let current = source.currentVersionID {
                guard let version = versions[key(current)], version.sourceID == source.id,
                    version.parseState == .ready
                else { throw LibraryArchiveIO.invalid }
            }
            for versionID in sourceVersions {
                guard versions[versionID]?.parseState == .ready || chunksByVersion[versionID] == nil else {
                    throw LibraryArchiveIO.invalid
                }
            }
        }
        try validateSearchIndexes(db: db, chunkCount: chunkIDs.count)

        var operationIDs = Set<String>()
        try SQLiteArchiveValidation.rows(in: db, table: "knowledge_operations", maximumRows: archiveMaximumRecords) {
            row in
            guard let operationID: String = row["operation_id"],
                key(try uuid(operationID)) == operationID,
                operationIDs.insert(operationID).inserted,
                let kind: String = row["kind"], kind == "import" || kind == "allow",
                let sourceID: String = row["source_id"], sources[sourceID] != nil
            else { throw LibraryArchiveIO.invalid }
            let requestHash: String? = row["request_hash"]
            let receiptBytes: Data? = row["receipt_json"]
            guard (requestHash == nil) == (receiptBytes == nil),
                requestHash.map(isHash) ?? true
            else { throw LibraryArchiveIO.invalid }
            if let receiptBytes {
                guard (1...131_072).contains(receiptBytes.count), kind == "import" || kind == "allow"
                else { throw LibraryArchiveIO.invalid }
                if kind == "import" {
                    let receipt: KnowledgeImportReceipt? = try operation(
                        try uuid(operationID), kind: kind, request: requestHash!, in: db)
                    guard receipt != nil else { throw LibraryArchiveIO.invalid }
                } else {
                    let source: KnowledgeSource? = try operation(
                        try uuid(operationID), kind: kind, request: requestHash!, in: db)
                    guard source != nil else { throw LibraryArchiveIO.invalid }
                }
            } else {
                guard sources[sourceID]?.deletedAt != nil else { throw LibraryArchiveIO.invalid }
            }
        }

        try validateMaintenance(db: db, sources: sources, versionsBySource: versionsBySource)

        var attachments: [LibraryArchiveAttachment] = []
        attachments.reserveCapacity(referencedDigests.count)
        for digest in referencedDigests.keys.sorted() {
            guard let byteCount = referencedDigests[digest], blobs[digest] == byteCount else {
                throw LibraryArchiveIO.invalid
            }
            let path = "\(blobDirectory)/\(digest.prefix(2))/\(digest.dropFirst(2).prefix(2))/\(digest)"
            try LibraryArchiveIO.validatePath(path)
            attachments.append(.init(path: path, byteCount: byteCount, digest: digest))
        }
        return attachments
    }

    private static func validateSearchIndexes(db: Database, chunkCount: Int) throws {
        guard try Int.fetchOne(db, sql: "SELECT count(*) FROM knowledge_words") == chunkCount,
            try Int.fetchOne(db, sql: "SELECT count(*) FROM knowledge_trigrams") == chunkCount,
            try Int.fetchOne(
                db, sql: "SELECT count(*) FROM knowledge_words WHERE rowid NOT IN (SELECT rowid FROM knowledge_chunks)")
                == 0,
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM knowledge_trigrams WHERE rowid NOT IN (SELECT rowid FROM knowledge_chunks)")
                == 0
        else { throw LibraryArchiveIO.invalid }
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT c.rowid AS row_id,
                       length(CAST(c.normalized_text AS BLOB)) AS expected_bytes,
                       length(CAST(w.content AS BLOB)) AS word_bytes,
                       length(CAST(t.content AS BLOB)) AS trigram_bytes
                FROM knowledge_chunks c
                LEFT JOIN knowledge_words w ON w.rowid = c.rowid
                LEFT JOIN knowledge_trigrams t ON t.rowid = c.rowid
                """)
        while let row = try cursor.next() {
            guard let rowID: Int64 = row["row_id"],
                let expected: Int = row["expected_bytes"], (0...131_072).contains(expected),
                row["word_bytes"] as Int? == expected, row["trigram_bytes"] as Int? == expected,
                let normalized: String = try String.fetchOne(
                    db, sql: "SELECT normalized_text FROM knowledge_chunks WHERE rowid = ?", arguments: [rowID]),
                let words: String = try String.fetchOne(
                    db, sql: "SELECT content FROM knowledge_words WHERE rowid = ?", arguments: [rowID]),
                let trigrams: String = try String.fetchOne(
                    db, sql: "SELECT content FROM knowledge_trigrams WHERE rowid = ?", arguments: [rowID]),
                normalized == words, normalized == trigrams
            else { throw LibraryArchiveIO.invalid }
        }
    }

    private static func validateMaintenance(
        db: Database, sources: [String: KnowledgeSource], versionsBySource: [String: Set<String>]
    ) throws {
        var count = 0
        var maintenanceIDs = Set<String>()
        let libraryID = try SQLiteLibraryAuthority.readState(in: db).authorization.libraryID
        try SQLiteArchiveValidation.rows(
            in: db, table: "knowledge_privacy_scopes", maximumRows: archiveMaximumRecords,
            maximumBytes: [
                "scope_json": KnowledgePrivacyScope.maximumBytes, "digest": 64, "library_id": 36, "operation_id": 36,
            ]
        ) { _ in }
        try SQLiteArchiveValidation.rows(in: db, table: "knowledge_maintenance", maximumRows: archiveMaximumRecords) {
            row in
            count += 1
            guard count <= archiveMaximumRecords,
                let operationID: String = row["operation_id"], let operationUUID = UUID(uuidString: operationID),
                key(operationUUID) == operationID,
                let namespace: String = row["namespace"],
                namespace == "knowledge.revoke" || namespace == "knowledge.delete",
                let sourceID: String = row["source_id"], let source = sources[sourceID],
                let expected: Int = row["expected_revision"], (1...8_192).contains(expected),
                let operation = try SQLiteLibraryAuthority.readOperation(
                    id: operationUUID, in: db, libraryID: libraryID),
                operation.completedAt != nil,
                operation.request.namespace == namespace,
                operation.request.scope
                    == .sources([
                        .domain(
                            namespace: KnowledgeSources.metadataNamespace, id: source.id.rawValue, revision: expected)
                    ]),
                operation.request.requestedAt.timeIntervalSince1970.isFinite,
                row["workspace_id"] as String? == source.workspaceID.map(key)
            else { throw LibraryArchiveIO.invalid }
            guard maintenanceIDs.insert(operationUUID.uuidString).inserted else { throw LibraryArchiveIO.invalid }
            let scopeRows = try Row.fetchCursor(
                db,
                sql:
                    "SELECT library_id, byte_count, digest, length(scope_json) AS stored_length FROM knowledge_privacy_scopes WHERE operation_id = ?",
                arguments: [operationUUID.uuidString])
            guard let scopeRow = try scopeRows.next(),
                scopeRow["library_id"] as String? == operation.authorization.libraryID.uuidString,
                let byteCount: Int = scopeRow["byte_count"],
                (1...KnowledgePrivacyScope.maximumBytes).contains(byteCount),
                scopeRow["stored_length"] as Int? == byteCount,
                let digest: String = scopeRow["digest"], isHash(digest),
                let bytes = try Data.fetchOne(
                    db, sql: "SELECT scope_json FROM knowledge_privacy_scopes WHERE operation_id = ?",
                    arguments: [operationUUID.uuidString]),
                bytes.count == byteCount, hash(bytes) == digest,
                let scope: KnowledgePrivacyScope = try? SessionCodec.decode(KnowledgePrivacyScope.self, from: bytes),
                (try? scope.validate(for: operation.request)) != nil,
                scope.action.namespace == namespace, scope.sourceID.rawValue.uuidString.lowercased() == sourceID,
                scope.workspaceID.map(key) == source.workspaceID.map(key), scope.expectedRevision == expected,
                try scopeRows.next() == nil
            else { throw LibraryArchiveIO.invalid }
            if namespace == "knowledge.delete" {
                guard source.deletedAt != nil, versionsBySource[sourceID] == nil else { throw LibraryArchiveIO.invalid }
            }
        }
        try SQLiteArchiveValidation.rows(
            in: db, table: "knowledge_privacy_scopes", maximumRows: archiveMaximumRecords,
            maximumBytes: ["scope_json": KnowledgePrivacyScope.maximumBytes]
        ) { row in
            guard let operationID: String = row["operation_id"], maintenanceIDs.contains(operationID) else {
                throw LibraryArchiveIO.invalid
            }
        }
    }
}
