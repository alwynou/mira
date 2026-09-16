import Foundation
import GRDB
import MiraCore

extension SQLiteMemoryStore {
    public static func archiveModule() throws -> SQLiteArchiveModule {
        return try SQLiteArchiveModule(
            identity: .init(name: "memory.store", revision: 1),
            schemaStatements: archiveSchemaDefinitions.map(\.1),
            restoration: .preserve,
            prepareExport: { db in
                try db.execute(sql: "DELETE FROM memory_embeddings")
                try db.execute(sql: "DELETE FROM memory_embedding_jobs")
                try db.execute(sql: "DELETE FROM memory_embedding_state")
            }
        ) { db, snapshot in
            try validateArchive(db: db, snapshot: snapshot)
            return []
        }
    }

    private static func validateArchive(db: Database, snapshot: FileSessionSnapshot) throws {
        try SQLiteArchiveValidation.metadata("memory_schema", in: db)
        guard try Row.fetchOne(db, sql: "PRAGMA foreign_key_check") == nil else { throw LibraryArchiveIO.invalid }
        let sessions = try SQLiteArchiveSessions(snapshot)

        var memories: [String: Memory] = [:]
        try SQLiteArchiveValidation.rows(in: db, table: "memory_records") { row in
            let value = try record(row)
            let id = key(value.id)
            guard memories[id] == nil else { throw LibraryArchiveIO.invalid }
            memories[id] = value
        }
        for memory in memories.values {
            if let successor = memory.supersededBy {
                guard memories[key(successor)] != nil else { throw LibraryArchiveIO.invalid }
            }
        }

        var sources: [String: MemoryEvidenceSource] = [:]
        var sourceWorkspaces: [String: WorkspaceID?] = [:]
        try SQLiteArchiveValidation.rows(in: db, table: "memory_sources") { row in
            guard let sourceKey: String = row["source_key"] else { throw LibraryArchiveIO.invalid }
            let source = try sourceIdentity(row)
            guard sourceKey == (try self.sourceKey(source)) else { throw LibraryArchiveIO.invalid }
            let workspaceRaw: String? = row["workspace_id"]
            let workspace = try workspaceRaw.map { WorkspaceID(try uuid($0)) }
            switch source {
            case .userMessage(let reference):
                _ = try sessions.validate(reference, workspaceID: workspace)
            case .manualEntry:
                guard workspace == nil else { throw LibraryArchiveIO.invalid }
            }
            guard let suppression: Int = row["suppression"], (0...3).contains(suppression) else {
                throw LibraryArchiveIO.invalid
            }
            if let bodyHash: String = row["body_hash"] {
                guard bodyHash.utf8.count == 64,
                    bodyHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
                else {
                    throw LibraryArchiveIO.invalid
                }
            }
            sources[sourceKey] = source
            sourceWorkspaces[sourceKey] = .some(workspace)
        }

        try validateRecords(
            memories: memories, sources: sources, sourceWorkspaces: sourceWorkspaces, sessions: sessions,
            snapshot: snapshot, db: db)
        try validateRevisions(memories: memories, db: db)
        try validateRelations(memories: memories, sources: sources, db: db)
        try validateAspects(memories: memories, sources: sources, db: db)
        try validateOperations(memories: memories, db: db)
        try validatePurges(memories: memories, sources: sources, db: db)
        try validateSearch(memories: memories, db: db)
    }

    private static func validateRecords(
        memories: [String: Memory], sources: [String: MemoryEvidenceSource], sourceWorkspaces: [String: WorkspaceID?],
        sessions: SQLiteArchiveSessions, snapshot: FileSessionSnapshot, db: Database
    ) throws {
        var seen: Set<UUID> = []
        try SQLiteArchiveValidation.rows(in: db, table: "memory_evidence") { row in
            let value: MemoryEvidence = try decode(row["json"])
            let sourceKey = try self.sourceKey(value.source)
            guard seen.insert(value.id).inserted,
                key(value.id) == row["id"] as String,
                memories[key(value.memoryID)] != nil,
                key(value.memoryID) == row["memory_id"] as String,
                sources[sourceKey] == value.source,
                sourceKey == row["source_key"] as String,
                value.sourceWorkspaceID.map(key) == row["source_workspace_id"] as String?,
                value.createdAt.timeIntervalSince1970.isFinite,
                (value.excerpt == nil) == (value.bodyPurgedAt != nil),
                (value.sourceHash == nil) == (value.bodyPurgedAt != nil)
            else { throw LibraryArchiveIO.invalid }
            guard let sourceWorkspace = sourceWorkspaces[sourceKey], sourceWorkspace == value.sourceWorkspaceID,
                value.bodyPurgedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                value.excerpt.map({ !$0.isEmpty && $0.utf8.count <= 8192 }) ?? true
            else { throw LibraryArchiveIO.invalid }
            if let forgotten = memories[key(value.memoryID)]?.forgottenAt {
                guard value.bodyPurgedAt == forgotten, value.excerpt == nil, value.sourceHash == nil else {
                    throw LibraryArchiveIO.invalid
                }
            }
            if value.bodyPurgedAt != nil {
                guard
                    try Int.fetchOne(
                        db, sql: "SELECT suppression FROM memory_sources WHERE source_key = ?", arguments: [sourceKey])
                        == 3,
                    try String.fetchOne(
                        db, sql: "SELECT body_hash FROM memory_sources WHERE source_key = ?", arguments: [sourceKey])
                        == nil
                else { throw LibraryArchiveIO.invalid }
            }
            try validateEvidenceSource(
                value.source, sourceHash: value.sourceHash, sourceWorkspaceID: value.sourceWorkspaceID,
                sessions: sessions)
            if case .manualEntry = value.source, let hash = value.sourceHash, let excerpt = value.excerpt {
                guard digest(Data(excerpt.utf8)) == hash else { throw LibraryArchiveIO.invalid }
            }
            if let hash = value.sourceHash,
                let sourceRow = try Row.fetchOne(
                    db, sql: "SELECT body_hash FROM memory_sources WHERE source_key = ?", arguments: [sourceKey])
            {
                let stored: String? = sourceRow["body_hash"]
                let suppression = try Int.fetchOne(
                    db, sql: "SELECT suppression FROM memory_sources WHERE source_key = ?", arguments: [sourceKey])
                guard stored == hash || (stored == nil && suppression == 3) else { throw LibraryArchiveIO.invalid }
            }
        }
    }

    private static func validateEvidenceSource(
        _ source: MemoryEvidenceSource, sourceHash: String?, sourceWorkspaceID: WorkspaceID?,
        sessions: SQLiteArchiveSessions
    ) throws {
        guard case .userMessage(let reference) = source else { return }
        let user = try sessions.validate(reference, workspaceID: sourceWorkspaceID)
        guard user.reference == reference else { throw LibraryArchiveIO.invalid }
        guard let sourceHash else { return }
        guard sourceHash.utf8.count == 64,
            sourceHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            reference.body.digest == sourceHash
        else { throw LibraryArchiveIO.invalid }
    }

    private static func validateRevisions(memories: [String: Memory], db: Database) throws {
        var revisions: [String: Set<Int>] = [:]
        try SQLiteArchiveValidation.rows(in: db, table: "memory_revisions") { row in
            let value: MemoryRevision = try revision(row, memoryID: .init(try uuid(row["memory_id"] as String)))
            let id = key(value.memoryID)
            guard memories[id] != nil, revisions[id, default: []].insert(value.revision).inserted,
                value.revision <= memories[id]!.revision
            else { throw LibraryArchiveIO.invalid }
            if value.revision == memories[id]?.revision {
                guard value.draft == memories[id]?.draft, value.changedAt == memories[id]?.updatedAt else {
                    throw LibraryArchiveIO.invalid
                }
            }
            if let memory = memories[id], memory.forgottenAt != nil {
                guard value.draft == nil, value.bodyPurgedAt == memory.forgottenAt else {
                    throw LibraryArchiveIO.invalid
                }
            }
        }
        for (id, memory) in memories {
            guard revisions[id]?.count == memory.revision else { throw LibraryArchiveIO.invalid }
        }
    }

    private static func validateRelations(
        memories: [String: Memory], sources: [String: MemoryEvidenceSource], db: Database
    ) throws {
        try SQLiteArchiveValidation.rows(in: db, table: "memory_replacements") { row in
            let relation = try self.relation(row)
            guard memories[key(relation.replacementID)] != nil, memories[key(relation.previousID)] != nil else {
                throw LibraryArchiveIO.invalid
            }
        }
        try SQLiteArchiveValidation.rows(in: db, table: "memory_assertions") { row in
            let storedAssertionKey: String = row["assertion_key"]
            let memoryID: String = row["memory_id"]
            let sourceKey: String = row["source_key"]
            guard let memory = memories[memoryID], let source = sources[sourceKey] else {
                throw LibraryArchiveIO.invalid
            }
            var matches = false
            if let draft = memory.draft {
                matches = try SQLiteMemoryStore.assertionKey(draft: draft, source: source) == storedAssertionKey
            }
            if !matches {
                let revisions = try Row.fetchCursor(
                    db, sql: "SELECT * FROM memory_revisions WHERE memory_id = ?", arguments: [memoryID])
                while let revisionRow = try revisions.next() {
                    let revision = try SQLiteMemoryStore.revision(revisionRow, memoryID: memory.id)
                    if let draft = revision.draft,
                        try SQLiteMemoryStore.assertionKey(draft: draft, source: source) == storedAssertionKey
                    {
                        matches = true
                        break
                    }
                }
            }
            guard matches else { throw LibraryArchiveIO.invalid }
        }
    }

    private static func validateAspects(
        memories: [String: Memory], sources: [String: MemoryEvidenceSource], db: Database
    ) throws {
        try SQLiteArchiveValidation.rows(in: db, table: "memory_extraction_aspects") { row in
            let memoryID: String = row["memory_id"]
            let sourceKey: String = row["source_key"]
            guard let memory = memories[memoryID], let source = sources[sourceKey],
                let memoryRevision: Int = row["memory_revision"], (1...memory.revision).contains(memoryRevision),
                let sourceJSON: Data = row["source_json"],
                (try SQLiteMemoryStore.decode(sourceJSON) as MemoryEvidenceSource) == source,
                let hash: String = row["source_hash"], hash.utf8.count == 64,
                hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                let mode: String = row["assertion_mode"], MemoryAssertionMode(rawValue: mode) != nil,
                let change: String = row["change_intent"], MemoryChangeIntent(rawValue: change) != nil,
                let metadata: Data = row["metadata_json"],
                let assertion = try? SQLiteMemoryStore.decode(metadata) as MemoryAssertionMetadata,
                assertion.mode.rawValue == mode, assertion.changeIntent.rawValue == change,
                assertion.aspectKey == row["semantic_key"] as String?,
                let created: Double = row["created_at"], created.isFinite
            else { throw LibraryArchiveIO.invalid }
            guard try SQLiteMemoryStore.sourceKey(source) == sourceKey, row["body_purged_at"] as Double? == nil,
                case .userMessage(_) = source,
                let evidenceHash = try String.fetchOne(
                    db,
                    sql:
                        "SELECT json_extract(CAST(json AS TEXT), '$.sourceHash') FROM memory_evidence WHERE memory_id = ? AND source_key = ?",
                    arguments: [memoryID, sourceKey]), evidenceHash == hash
            else { throw LibraryArchiveIO.invalid }
            if let aspectKey = row["semantic_key"] as String? {
                let bytes = Array(aspectKey.utf8)
                guard (3...96).contains(bytes.count), !aspectKey.hasPrefix("."), !aspectKey.hasSuffix("."),
                    !aspectKey.contains(".."),
                    aspectKey.utf8.allSatisfy({
                        ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46
                    }),
                    (2...4).contains(aspectKey.split(separator: ".").count),
                    aspectKey.split(separator: ".").allSatisfy({
                        $0.first?.isASCII == true && $0.first?.isLetter == true
                    })
                else { throw LibraryArchiveIO.invalid }
            }
        }
    }

    private static func validateOperations(memories: [String: Memory], db: Database) throws {
        var operations: Set<String> = []
        try SQLiteArchiveValidation.rows(in: db, table: "memory_operations") { row in
            let operationID: String = row["operation_id"]
            guard let id = UUID(uuidString: operationID), key(id) == operationID,
                operations.insert(operationID).inserted,
                let memoryID: String = row["memory_id"], memories[memoryID] != nil
            else { throw LibraryArchiveIO.invalid }
            let request: String? = row["request_hash"]
            let receipt: Data? = row["receipt_json"]
            guard (request == nil) == (receipt == nil) else { throw LibraryArchiveIO.invalid }
            if let request {
                guard request.utf8.count == 64,
                    request.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
                else { throw LibraryArchiveIO.invalid }
            }
            if let receipt {
                let value: MemoryWriteReceipt = try decode(receipt)
                try validate(value.memory)
                guard key(value.memory.id) == memoryID, let current = memories[memoryID], current.forgottenAt == nil,
                    value.memory.revision <= current.revision, value.memory.scope == current.scope,
                    let revisionRow = try Row.fetchOne(
                        db, sql: "SELECT * FROM memory_revisions WHERE memory_id = ? AND revision = ?",
                        arguments: [memoryID, value.memory.revision]),
                    try revision(revisionRow, memoryID: current.id).draft == value.memory.draft
                else { throw LibraryArchiveIO.invalid }
            }
        }
        try SQLiteArchiveValidation.rows(in: db, table: "memory_operation_dependencies") { row in
            let operationID: String = row["operation_id"]
            let memoryID: String = row["memory_id"]
            guard operations.contains(operationID), memories[memoryID] != nil else { throw LibraryArchiveIO.invalid }
            if memories[memoryID]?.forgottenAt != nil {
                guard
                    try Int.fetchOne(
                        db,
                        sql:
                            "SELECT count(*) FROM memory_operations WHERE operation_id = ? AND request_hash IS NULL AND receipt_json IS NULL",
                        arguments: [operationID]) == 1
                else { throw LibraryArchiveIO.invalid }
            }
        }
    }

    private static func validatePurges(
        memories: [String: Memory], sources: [String: MemoryEvidenceSource], db: Database
    ) throws {
        let libraryID = try SQLiteLibraryAuthority.readState(in: db).authorization.libraryID
        var purged = Set<String>()
        try SQLiteArchiveValidation.rows(in: db, table: "memory_purges") { row in
            let operationID: String = row["operation_id"]
            let memoryID: String = row["memory_id"]
            guard let id = UUID(uuidString: operationID), key(id) == operationID,
                let memory = memories[memoryID], let expected: Int = row["expected_revision"],
                expected > 0, expected < Int.max, memory.revision == expected + 1,
                let forgotten = memory.forgottenAt, purged.insert(memoryID).inserted,
                row["workspace_id"] as String? == memory.scope.workspaceID.map(key),
                let operation = try SQLiteLibraryAuthority.readOperation(id: id, in: db, libraryID: libraryID),
                operation.completedAt != nil, operation.request.namespace == "memory.forget",
                operation.request.scope
                    == .sources([.domain(namespace: "memories", id: memory.id.rawValue, revision: expected)]),
                operation.request.requestedAt == forgotten
            else { throw LibraryArchiveIO.invalid }
            let receipt: MemoryForgetReceipt = try decode(row["json"])
            let keys = try receipt.suppressedSources.map(sourceKey)
            let actual = try String.fetchAll(
                db, sql: "SELECT source_key FROM memory_evidence WHERE memory_id = ?", arguments: [memoryID])
            guard key(receipt.memoryID) == memoryID, Set(keys).count == keys.count, Set(keys) == Set(actual),
                keys.allSatisfy({ sources[$0] != nil })
            else { throw LibraryArchiveIO.invalid }
        }
        guard purged == Set(memories.filter { $0.value.forgottenAt != nil }.keys) else {
            throw LibraryArchiveIO.invalid
        }
    }

    private static func validateSearch(memories: [String: Memory], db: Database) throws {
        var indexed: Set<String> = []
        let metadata = try Row.fetchCursor(
            db,
            sql:
                "SELECT rowid AS archive_rowid, length(CAST(memory_id AS BLOB)) AS id_bytes, length(CAST(content AS BLOB)) AS content_bytes FROM memory_search ORDER BY rowid"
        )
        var count = 0
        while let meta = try metadata.next() {
            count += 1
            guard count <= LibraryArchiveLimits.maximumDomainRows,
                let idBytes: Int = meta["id_bytes"], (1...128).contains(idBytes),
                let contentBytes: Int = meta["content_bytes"], (1...8_192).contains(contentBytes),
                let rowID: Int64 = meta["archive_rowid"],
                let row = try Row.fetchOne(
                    db, sql: "SELECT memory_id, content FROM memory_search WHERE rowid = ?", arguments: [rowID])
            else {
                throw LibraryArchiveIO.invalid
            }
            let id: String = row["memory_id"]
            let content: String = row["content"]
            guard indexed.insert(id).inserted, let memory = memories[id], let draft = memory.draft,
                draft.content == content
            else { throw LibraryArchiveIO.invalid }
        }
        let expected = Set(memories.compactMap { $0.value.draft == nil ? nil : $0.key })
        guard indexed == expected else { throw LibraryArchiveIO.invalid }
    }
}
