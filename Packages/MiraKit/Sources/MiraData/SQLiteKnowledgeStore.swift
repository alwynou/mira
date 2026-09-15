import Foundation
import GRDB
import MiraCore

enum KnowledgeStorageFaultStage: Sendable, Equatable {
    case afterBlobInstall, beforeImportCommit, beforeReferenceScan, beforeBlobRemoval, afterBlobRemoval
    case afterPrivacyScopeCommit, afterDomainPrivacyCommit
}

/// Knowledge owns business records and immutable blobs; the session journal owns usage and execution history.
public final class SQLiteKnowledgeStore: KnowledgeStore, @unchecked Sendable {
    let owner: SQLiteDomainDatabase
    let blobs: ManagedBlobStore
    let fault: @Sendable (KnowledgeStorageFaultStage) throws -> Void

    public convenience init(database: DatabaseQueue, libraryID: UUID, directory: URL) throws {
        try self.init(database: database, libraryID: libraryID, directory: directory, faultInjector: { _ in })
    }
    init(database: DatabaseQueue, libraryID: UUID, directory: URL,
         faultInjector: @escaping @Sendable (KnowledgeStorageFaultStage) throws -> Void) throws {
        owner = try SQLiteDomainDatabase(database: database, libraryID: libraryID, label: "mira.knowledge")
        blobs = try ManagedBlobStore(directory: directory); fault = faultInjector
        try database.write { db in
            guard try db.tableExists("business_workspaces") else { throw Self.corrupt }
            try Self.initialize(in: db)
        }
    }
    public func close() async { await owner.close() }

    public func knowledgeSources(scope: KnowledgeReadScope, limit: Int) async throws -> [KnowledgeSource] {
        guard (1...1_000).contains(limit) else { throw Self.invalid }
        return try await owner.read { db in
            try Self.validateScope(scope, in: db)
            let remote = scope.destination.modelRoute == nil ? "" : " AND allows_remote_use = 1"
            return try Row.fetchAll(db, sql: "SELECT * FROM knowledge_sources WHERE deleted_at IS NULL AND (workspace_id IS NULL OR workspace_id = ?)\(remote) ORDER BY updated_at DESC, id LIMIT ?", arguments: [scope.workspaceID.map(Self.key), limit]).map { row in
                let value = try Self.record(row)
                return try Self.source(value.id, scope: scope, in: db)
            }
        }
    }
    public func knowledgeSource(_ id: KnowledgeSourceID, versionID: SourceVersionID?, scope: KnowledgeReadScope) async throws -> KnowledgeSourceDetail {
        try await owner.read { db in
            let source = try Self.source(id, scope: scope, in: db)
            let versions = try Row.fetchAll(db, sql: "SELECT * FROM knowledge_versions WHERE source_id = ? ORDER BY created_at DESC, id LIMIT 100", arguments: [Self.key(id)]).map(Self.version)
            let selected = try (versionID ?? source.currentVersionID).map { try Self.version($0, sourceID: id, in: db) }
            if versionID == nil, let selected { guard selected.parseState == .ready else { throw Self.corrupt } }
            let rows = try selected.map { try Row.fetchAll(db, sql: "SELECT * FROM knowledge_chunks WHERE version_id = ? ORDER BY sequence LIMIT 201", arguments: [Self.key($0.id)]) } ?? []
            guard selected?.parseState != .failed || rows.isEmpty else { throw Self.corrupt }
            let chunks = try rows.prefix(200).map { try Self.chunk($0).summary }
            return .init(source: source, versions: versions, selectedVersion: selected, chunks: chunks, hasMoreChunks: rows.count > 200)
        }
    }
    public func sourceChunk(_ id: SourceChunkID, scope: KnowledgeReadScope) async throws -> SourceChunk {
        try await owner.read { try self.verifiedChunk(id, scope: scope, in: $0).chunk }
    }
    public func searchKnowledge(query: String, scope: KnowledgeReadScope, limit: Int) async throws -> KnowledgeSearchResult {
        try await owner.read { db in
            let result = try Self.search(query: query, scope: scope, limit: limit, in: db)
            for hit in result.hits {
                let verified = try self.verifiedChunk(hit.chunk.id, scope: scope, in: db)
                guard verified.source == hit.source, verified.chunk.summary == hit.chunk else { throw Self.corrupt }
            }
            return result
        }
    }
    public func sourceCitation(_ reference: SourceCitationReference, scope: KnowledgeReadScope) async throws -> SourceCitationDetail {
        try await owner.read { db in
            let detail = try self.verifiedChunk(reference.chunkID, scope: scope, in: db)
            guard detail.version.id == reference.versionID else { throw Self.unavailable }
            return detail
        }
    }
    public func validateKnowledgeSources(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {
        guard sources.count <= 8_192, Set(sources).count == sources.count else { throw Self.unauthorized }
        try await owner.read { try self.validateKnowledgeSources(sources, for: request, in: $0) }
    }
    func validateKnowledgeSources(_ sources: [AgentSourceReference], for request: AgentContextRequest,
                                 in db: Database) throws {
        let scope = KnowledgeReadScope(request)
        try Self.validateScope(scope, in: db)
        do {
            for source in sources {
                guard case .domain(let namespace, let id, let revision) = source else { throw Self.unauthorized }
                switch namespace {
                case KnowledgeSources.metadataNamespace:
                    let value = try Self.source(.init(id), scope: scope, in: db)
                    guard revision == value.revision else { throw Self.unauthorized }
                case KnowledgeSources.chunkNamespace:
                    guard revision == 1 else { throw Self.unauthorized }
                    _ = try self.verifiedChunk(.init(id), scope: scope, in: db)
                default: throw Self.unauthorized
                }
            }
        } catch let error as MiraError where error.code == .notFound { throw Self.unauthorized }
    }
    public func importMarkdown(_ input: KnowledgeImport, workspaceID: WorkspaceID?, updating: KnowledgeSourceID?, expectedRevision: Int?, operationID: UUID, authorization: AgentLibraryAuthorization, at: Date) async throws -> KnowledgeImportReceipt {
        try input.validate(); try Self.date(at)
        guard (updating == nil) == (expectedRevision == nil), expectedRevision.map({ $0 > 0 && $0 < Int.max }) ?? true else { throw Self.invalid }
        return try await owner.write(authorization: authorization) { db in
            try Self.validateScope(.init(workspaceID: workspaceID, destination: .local), in: db)
            let digest = Self.hash(input.bytes)
            let request = try Self.fingerprint(kind: "import", sourceID: updating, workspaceID: workspaceID, expected: expectedRevision, title: input.title, hash: digest)
            if let prior: KnowledgeImportReceipt = try Self.operation(operationID, kind: "import", request: request, in: db) { return prior }
            var source: KnowledgeSource
            if let updating, let expectedRevision {
                source = try Self.mutable(updating, workspaceID: workspaceID, expected: expectedRevision, in: db)
            } else {
                // Deduplication does not move a source back to an older version or overwrite by filename.
                if let row = try Row.fetchOne(db, sql: "SELECT s.* FROM knowledge_sources s JOIN knowledge_versions v ON v.id = s.current_version_id WHERE s.deleted_at IS NULL AND s.workspace_id IS ? AND v.content_hash = ? ORDER BY s.id LIMIT 1", arguments: [workspaceID.map(Self.key), digest]) {
                    let value = try Self.record(row)
                    guard let currentID = value.currentVersionID else { throw Self.corrupt }
                    let version = try Self.version(currentID, sourceID: value.id, in: db)
                    guard version.parseState == .ready, try self.blobs.read(version.contentHash) == input.bytes else { throw Self.corrupt }
                    let receipt = KnowledgeImportReceipt(source: value, version: version, reused: true)
                    try Self.saveOperation(operationID, kind: "import", request: request, sourceID: value.id, receipt: receipt, in: db)
                    return receipt
                }
                source = .init(id: .init(), workspaceID: workspaceID, title: input.title, createdAt: at, updatedAt: at)
            }
            if let currentID = source.currentVersionID {
                let current = try Self.version(currentID, sourceID: source.id, in: db)
                if current.contentHash == digest {
                    guard current.parseState == .ready, try self.blobs.read(current.contentHash) == input.bytes else { throw Self.corrupt }
                    let receipt = KnowledgeImportReceipt(source: source, version: current, reused: true)
                    try Self.saveOperation(operationID, kind: "import", request: request, sourceID: source.id, receipt: receipt, in: db)
                    return receipt
                }
            }
            return try self.blobs.withMaintenanceLock {
                guard try self.blobs.install(input.bytes) == digest else { throw Self.corrupt }
                try self.fault(.afterBlobInstall)
                let slices: [MarkdownChunkSlice], parseError: MiraError?
                do { slices = try MarkdownChunker.chunk(input.bytes); parseError = nil }
                catch let error as MiraError where error.code == .invalidInput { slices = []; parseError = error }
                let version = KnowledgeSourceVersion(id: .init(), sourceID: source.id, contentHash: digest, byteCount: input.bytes.count, parserVersion: MarkdownChunker.parserVersion, parseState: parseError == nil ? .ready : .failed, parseError: parseError, createdAt: at)
                if updating == nil { try Self.write(source, insert: true, in: db) }
                if let bytes = try Int.fetchOne(db, sql: "SELECT byte_count FROM knowledge_blobs WHERE digest = ?", arguments: [digest]) {
                    guard bytes == input.bytes.count else { throw Self.corrupt }
                    try db.execute(sql: "UPDATE knowledge_blobs SET pending_deletion_at = NULL WHERE digest = ?", arguments: [digest])
                } else {
                    try db.execute(sql: "INSERT INTO knowledge_blobs(digest, byte_count, created_at) VALUES (?, ?, ?)", arguments: [digest, input.bytes.count, at.timeIntervalSince1970])
                }
                try db.execute(sql: "INSERT INTO knowledge_versions(id, source_id, content_hash, byte_count, parse_state, created_at, json) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [Self.key(version.id), Self.key(source.id), digest, input.bytes.count, version.parseState.rawValue, at.timeIntervalSince1970, try Self.encode(version)])
                for slice in slices {
                    let summary = SourceChunkSummary(id: .init(), sourceID: source.id, sourceVersionID: version.id, sequence: slice.sequence, startLine: slice.startLine, endLine: slice.endLine, startUTF8Offset: slice.startUTF8Offset, endUTF8Offset: slice.endUTF8Offset, headingPath: slice.headingPath, contentHash: Self.hash(Data(slice.text.utf8)))
                    let normalized = Self.normalize(source.title + "\n" + slice.headingPath.joined(separator: "\n") + "\n" + slice.text)
                    try db.execute(sql: "INSERT INTO knowledge_chunks(id, source_id, version_id, sequence, text, normalized_text, json) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [Self.key(summary.id), Self.key(source.id), Self.key(version.id), summary.sequence, slice.text, normalized, try Self.encode(summary)])
                    let rowID = db.lastInsertedRowID
                    try db.execute(sql: "INSERT INTO knowledge_words(rowid, content) VALUES (?, ?)", arguments: [rowID, normalized])
                    try db.execute(sql: "INSERT INTO knowledge_trigrams(rowid, content) VALUES (?, ?)", arguments: [rowID, normalized])
                }
                if parseError == nil { source.currentVersionID = version.id }
                if updating != nil { source.revision += 1 }
                source.updatedAt = at
                try Self.write(source, insert: false, in: db)
                let receipt = KnowledgeImportReceipt(source: source, version: version, reused: false)
                try Self.saveOperation(operationID, kind: "import", request: request, sourceID: source.id, receipt: receipt, in: db)
                try self.fault(.beforeImportCommit)
                return receipt
            }
        }
    }
    public func allowSourceRemoteUse(_ id: KnowledgeSourceID, workspaceID: WorkspaceID?, expectedRevision: Int, operationID: UUID, authorization: AgentLibraryAuthorization, at: Date) async throws -> KnowledgeSource {
        try Self.date(at)
        return try await owner.write(authorization: authorization) { db in
            let request = try Self.fingerprint(kind: "allow", sourceID: id, workspaceID: workspaceID, expected: expectedRevision)
            if let prior: KnowledgeSource = try Self.operation(operationID, kind: "allow", request: request, in: db) { return prior }
            var source = try Self.mutable(id, workspaceID: workspaceID, expected: expectedRevision, in: db)
            source.allowsRemoteUse = true; source.revision += 1; source.updatedAt = at
            try Self.write(source, insert: false, in: db)
            try Self.saveOperation(operationID, kind: "allow", request: request, sourceID: id, receipt: source, in: db)
            return source
        }
    }
    public func revokeSourceRemoteUse(_ id: KnowledgeSourceID, workspaceID: WorkspaceID?, expectedRevision: Int, maintenance: AgentLibraryMaintenanceOperation, at: Date) async throws -> KnowledgeSource {
        try Self.date(at); try Self.requireMaintenance(maintenance, namespace: "knowledge.revoke", id: id, expected: expectedRevision)
        return try await owner.maintain(maintenance, afterCommit: { _ in try self.fault(.afterDomainPrivacyCommit) }) { db in
            if try Self.hasMaintenance(maintenance, id: id, workspaceID: workspaceID, expected: expectedRevision, in: db) {
                return try Self.maintenanceSource(id, in: db)
            }
            var source = try Self.mutable(id, workspaceID: workspaceID, expected: expectedRevision, in: db)
            source.allowsRemoteUse = false; source.revision += 1; source.updatedAt = at
            try Self.write(source, insert: false, in: db)
            try Self.saveMaintenance(maintenance, id: id, workspaceID: workspaceID, expected: expectedRevision, in: db)
            return source
        }
    }
    public func purgeKnowledgeSource(_ id: KnowledgeSourceID, workspaceID: WorkspaceID?, expectedRevision: Int, maintenance: AgentLibraryMaintenanceOperation, at: Date) async throws {
        try Self.date(at); try Self.requireMaintenance(maintenance, namespace: "knowledge.delete", id: id, expected: expectedRevision)
        try await owner.maintain(maintenance, afterCommit: { _ in try self.fault(.afterDomainPrivacyCommit) }) { db in
            if try Self.hasMaintenance(maintenance, id: id, workspaceID: workspaceID, expected: expectedRevision, in: db) { return }
            var source = try Self.mutable(id, workspaceID: workspaceID, expected: expectedRevision, in: db)
            try self.blobs.withMaintenanceLock {
                source.title = "Deleted source"; source.currentVersionID = nil; source.allowsRemoteUse = false
                source.deletedAt = at; source.updatedAt = at; source.revision += 1
                try Self.write(source, insert: false, in: db)
                for table in ["knowledge_words", "knowledge_trigrams"] {
                    try db.execute(sql: "DELETE FROM \(table) WHERE rowid IN (SELECT rowid FROM knowledge_chunks WHERE source_id = ?)", arguments: [Self.key(id)])
                }
                try db.execute(sql: "DELETE FROM knowledge_chunks WHERE source_id = ?", arguments: [Self.key(id)])
                try db.execute(sql: "DELETE FROM knowledge_versions WHERE source_id = ?", arguments: [Self.key(id)])
                try db.execute(sql: "UPDATE knowledge_blobs SET pending_deletion_at = ? WHERE pending_deletion_at IS NULL AND NOT EXISTS (SELECT 1 FROM knowledge_versions WHERE content_hash = knowledge_blobs.digest)", arguments: [at.timeIntervalSince1970])
                try db.execute(sql: "UPDATE knowledge_operations SET request_hash = NULL, receipt_json = NULL WHERE source_id = ?", arguments: [Self.key(id)])
                try Self.saveMaintenance(maintenance, id: id, workspaceID: workspaceID, expected: expectedRevision, in: db)
            }
        }
    }
    static func requireMaintenance(_ operation: AgentLibraryMaintenanceOperation, namespace: String, id: KnowledgeSourceID, expected: Int) throws {
        guard operation.request.namespace == namespace, operation.request.revision == 1,
              operation.request.scope == .sources([.domain(namespace: KnowledgeSources.metadataNamespace, id: id.rawValue, revision: expected)]) else { throw unauthorized }
    }
    static func maintenanceSource(_ id: KnowledgeSourceID, in db: Database) throws -> KnowledgeSource {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM knowledge_sources WHERE id = ?", arguments: [key(id)]) else { throw corrupt }
        return try record(row)
    }
    static func hasMaintenance(_ operation: AgentLibraryMaintenanceOperation, id: KnowledgeSourceID, workspaceID: WorkspaceID?, expected: Int, in db: Database) throws -> Bool {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM knowledge_maintenance WHERE operation_id = ?", arguments: [key(operation.request.id)]) else { return false }
        guard row["namespace"] as String == operation.request.namespace, row["source_id"] as String == key(id),
              row["workspace_id"] as String? == workspaceID.map(key), row["expected_revision"] as Int == expected else { throw conflict }
        return true
    }
    static func saveMaintenance(_ operation: AgentLibraryMaintenanceOperation, id: KnowledgeSourceID, workspaceID: WorkspaceID?, expected: Int, in db: Database) throws {
        try db.execute(sql: "INSERT INTO knowledge_maintenance(operation_id, namespace, source_id, workspace_id, expected_revision) VALUES (?, ?, ?, ?, ?)", arguments: [key(operation.request.id), operation.request.namespace, key(id), workspaceID.map(key), expected])
    }
}
