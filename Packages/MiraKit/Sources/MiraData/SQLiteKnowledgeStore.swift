import Foundation
import CryptoKit
import GRDB
import MiraCore

enum KnowledgeStorageFaultStage: Sendable, Equatable {
    case afterBlobInstall, beforeImportCommit, beforeReferenceScan, beforeBlobRemoval, afterBlobRemoval
}

extension SQLiteMiraStore {
    public func knowledgeSources(workspaceID: WorkspaceID?, limit: Int) throws -> [KnowledgeSource] {
        try safely { try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT source_json FROM knowledge_sources WHERE deleted_at IS NULL AND (workspace_id IS NULL OR workspace_id = ?) ORDER BY updated_at DESC, id LIMIT ?", arguments: [workspaceID.map(Self.id), max(1, min(limit, 1_000))])
                .map { try Self.decode($0["source_json"]) }
        }}
    }

    public func knowledgeSource(_ sourceID: KnowledgeSourceID, versionID: SourceVersionID?, workspaceID: WorkspaceID?, connectionID: ConnectionID?) throws -> KnowledgeSourceDetail {
        try safely { try pool.read { db in
            let source = try requireKnowledgeSource(sourceID, workspaceID: workspaceID, connectionID: connectionID, in: db)
            let versions: [KnowledgeSourceVersion] = try Row.fetchAll(db, sql: "SELECT version_json FROM source_versions WHERE source_id = ? ORDER BY created_at DESC, id LIMIT 100", arguments: [Self.id(sourceID)]).map { try Self.decode($0["version_json"]) }
            let selected = try (versionID ?? source.currentVersionID).map { try requireSourceVersion($0, sourceID: sourceID, in: db) }
            let rows = try selected.map { try Row.fetchAll(db, sql: "SELECT summary_json FROM source_chunks WHERE version_id = ? ORDER BY sequence LIMIT 201", arguments: [Self.id($0.id)]) } ?? []
            return .init(source: source, versions: versions, selectedVersion: selected, chunks: try rows.prefix(200).map { try Self.decode($0["summary_json"]) }, hasMoreChunks: rows.count > 200)
        }}
    }

    public func sourceChunk(_ chunkID: SourceChunkID, workspaceID: WorkspaceID?, connectionID: ConnectionID?) throws -> SourceChunk {
        try safely { try pool.read { db in
            let chunk = try requireSourceChunk(chunkID, in: db)
            _ = try requireKnowledgeSource(chunk.summary.sourceID, workspaceID: workspaceID, connectionID: connectionID, in: db)
            let version = try requireSourceVersion(chunk.summary.sourceVersionID, sourceID: chunk.summary.sourceID, in: db)
            _ = try blobs.read(version.contentHash)
            return chunk
        }}
    }

    public func importMarkdownFile(_ url: URL, workspaceID: WorkspaceID?, updating: KnowledgeSourceID?, expectedRevision: Int?, at: Date) throws -> KnowledgeImportReceipt {
        let data = try ManagedBlobStore.readSelectedMarkdownFile(url)
        let title = url.lastPathComponent
        guard title.utf8.count <= 1_024, at.timeIntervalSince1970.isFinite else { throw MiraError(.invalidInput, "The Markdown import metadata is invalid.") }
        let parsed: Result<[MarkdownChunkSlice], MiraError>
        do { parsed = .success(try MarkdownChunker.chunk(data)) }
        catch { parsed = .failure(MiraError.safe(error)) }
        return try blobs.withMaintenanceLock {
            let digest = try blobs.install(data)
            try knowledgeFaultInjector(.afterBlobInstall)
            return try safely { try pool.write { db in
                if let workspaceID { try validateMemoryScope(.workspace(workspaceID), in: db) }
                var source: KnowledgeSource
                if let updating {
                    source = try requireKnowledgeSource(updating, workspaceID: workspaceID, connectionID: nil, in: db)
                    guard source.revision == expectedRevision, source.revision < Int.max else { throw MiraError(.conflict, "The source revision is out of date.") }
                } else {
                    guard expectedRevision == nil else { throw MiraError(.invalidInput, "A new source cannot have an expected revision.") }
                    if let row = try Row.fetchOne(db, sql: "SELECT s.source_json, v.version_json FROM knowledge_sources s JOIN source_versions v ON v.source_id = s.id WHERE s.deleted_at IS NULL AND s.workspace_id IS ? AND v.content_hash = ? ORDER BY v.created_at DESC, v.id LIMIT 1", arguments: [workspaceID.map(Self.id), digest]) {
                        let source: KnowledgeSource = try Self.decode(row["source_json"])
                        let version: KnowledgeSourceVersion = try Self.decode(row["version_json"])
                        return .init(source: source, version: version, reused: true)
                    }
                    source = .init(id: .init(), workspaceID: workspaceID, title: title, createdAt: at, updatedAt: at)
                    try db.execute(sql: "INSERT INTO knowledge_sources (id, workspace_id, title, current_version_id, allows_remote_use, revision, created_at, updated_at, deleted_at, source_json) VALUES (?, ?, ?, NULL, 0, 1, ?, ?, NULL, ?)", arguments: [Self.id(source.id), workspaceID.map(Self.id), title, at.timeIntervalSince1970, at.timeIntervalSince1970, try Self.encode(source)])
                }
                if let currentID = source.currentVersionID {
                    let current = try requireSourceVersion(currentID, sourceID: source.id, in: db)
                    if current.contentHash == digest { return .init(source: source, version: current, reused: true) }
                }
                let slices: [MarkdownChunkSlice], parseError: MiraError?
                switch parsed { case .success(let value): slices = value; parseError = nil
                case .failure(let error): slices = []; parseError = error }
                let version = KnowledgeSourceVersion(id: .init(), sourceID: source.id, contentHash: digest, byteCount: data.count, parserVersion: MarkdownChunker.parserVersion, parseState: parseError == nil ? .ready : .failed, parseError: parseError, createdAt: at)
                try db.execute(sql: "INSERT OR IGNORE INTO managed_blobs (digest, byte_count, created_at, pending_deletion_at) VALUES (?, ?, ?, NULL)", arguments: [digest, data.count, at.timeIntervalSince1970])
                try db.execute(sql: "UPDATE managed_blobs SET pending_deletion_at = NULL WHERE digest = ?", arguments: [digest])
                try db.execute(sql: "INSERT INTO source_versions (id, source_id, content_hash, byte_count, parse_state, created_at, version_json) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [Self.id(version.id), Self.id(source.id), digest, data.count, version.parseState.rawValue, at.timeIntervalSince1970, try Self.encode(version)])
                for slice in slices {
                    let summary = SourceChunkSummary(id: .init(), sourceID: source.id, sourceVersionID: version.id, sequence: slice.sequence, startLine: slice.startLine, endLine: slice.endLine, startUTF8Offset: slice.startUTF8Offset, endUTF8Offset: slice.endUTF8Offset, headingPath: slice.headingPath, contentHash: Self.knowledgeHash(Data(slice.text.utf8)))
                    let normalized = Self.normalizeKnowledge(source.title + "\n" + slice.headingPath.joined(separator: "\n") + "\n" + slice.text)
                    try db.execute(sql: "INSERT INTO source_chunks (id, source_id, version_id, sequence, text, normalized_text, summary_json) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [Self.id(summary.id), Self.id(source.id), Self.id(version.id), summary.sequence, slice.text, normalized, try Self.encode(summary)])
                    let rowID = db.lastInsertedRowID
                    try db.execute(sql: "INSERT INTO knowledge_words (rowid, content) VALUES (?, ?)", arguments: [rowID, normalized])
                    if try db.tableExists("knowledge_trigrams") { try db.execute(sql: "INSERT INTO knowledge_trigrams (rowid, content) VALUES (?, ?)", arguments: [rowID, normalized]) }
                }
                if parseError == nil { source.currentVersionID = version.id }
                source.updatedAt = at
                if updating != nil { source.revision += 1 }
                try writeKnowledgeSource(source, in: db)
                try knowledgeFaultInjector(.beforeImportCommit)
                return .init(source: source, version: version, reused: false)
            }}
        }
    }

    public func setSourceRemoteUse(_ sourceID: KnowledgeSourceID, workspaceID: WorkspaceID?, allowed: Bool, expectedRevision: Int, at: Date) throws -> KnowledgeSource {
        try safely { try pool.write { db in
            var source = try requireKnowledgeSource(sourceID, workspaceID: workspaceID, connectionID: nil, in: db)
            guard source.revision == expectedRevision, source.revision < Int.max else { throw MiraError(.conflict, "The source revision is out of date.") }
            source.allowsRemoteUse = allowed; source.revision += 1; source.updatedAt = at
            try writeKnowledgeSource(source, in: db)
            if !allowed { try purgeSourceConsumers(sourceID, at: at, in: db) }
            return source
        }}
    }

    public func deleteKnowledgeSource(_ sourceID: KnowledgeSourceID, workspaceID: WorkspaceID?, expectedRevision: Int, at: Date) throws {
        try blobs.withMaintenanceLock { try safely { try pool.write { db in
            var source = try requireKnowledgeSource(sourceID, workspaceID: workspaceID, connectionID: nil, in: db)
            guard source.revision == expectedRevision, source.revision < Int.max else { throw MiraError(.conflict, "The source revision is out of date.") }
            try purgeSourceConsumers(sourceID, at: at, in: db)
            try db.execute(sql: "DELETE FROM knowledge_words WHERE rowid IN (SELECT rowid FROM source_chunks WHERE source_id = ?)", arguments: [Self.id(sourceID)])
            if try db.tableExists("knowledge_trigrams") { try db.execute(sql: "DELETE FROM knowledge_trigrams WHERE rowid IN (SELECT rowid FROM source_chunks WHERE source_id = ?)", arguments: [Self.id(sourceID)]) }
            try db.execute(sql: "DELETE FROM source_chunks WHERE source_id = ?", arguments: [Self.id(sourceID)])
            try db.execute(sql: "DELETE FROM source_versions WHERE source_id = ?", arguments: [Self.id(sourceID)])
            try db.execute(sql: "UPDATE managed_blobs SET pending_deletion_at = ? WHERE pending_deletion_at IS NULL AND NOT EXISTS (SELECT 1 FROM source_versions WHERE content_hash = managed_blobs.digest)", arguments: [at.timeIntervalSince1970])
            source.title = "Deleted source"; source.currentVersionID = nil; source.deletedAt = at
            source.allowsRemoteUse = false; source.revision += 1; source.updatedAt = at
            try writeKnowledgeSource(source, in: db)
        }}}
    }

    func requireKnowledgeSource(_ sourceID: KnowledgeSourceID, workspaceID: WorkspaceID?, connectionID: ConnectionID?, in db: Database) throws -> KnowledgeSource {
        guard let row = try Row.fetchOne(db, sql: "SELECT source_json FROM knowledge_sources WHERE id = ? AND deleted_at IS NULL AND (workspace_id IS NULL OR workspace_id = ?)", arguments: [Self.id(sourceID), workspaceID.map(Self.id)]) else { throw MiraError(.notFound, "The source is unavailable in this workspace.") }
        let source: KnowledgeSource = try Self.decode(row["source_json"])
        if let connectionID {
            guard source.allowsRemoteUse else { throw MiraError(.unauthorized, "This source is not authorized for model use.") }
            try validateWorkspacePolicy(workspaceID, connectionID: connectionID, in: db)
            try validateWorkspacePolicy(source.workspaceID, connectionID: connectionID, in: db)
        }
        return source
    }
    func requireSourceVersion(_ versionID: SourceVersionID, sourceID: KnowledgeSourceID, in db: Database) throws -> KnowledgeSourceVersion {
        guard let json = try String.fetchOne(db, sql: "SELECT version_json FROM source_versions WHERE id = ? AND source_id = ?", arguments: [Self.id(versionID), Self.id(sourceID)]) else { throw MiraError(.notFound, "The source version is unavailable.") }
        return try Self.decode(json)
    }
    func requireSourceChunk(_ chunkID: SourceChunkID, in db: Database) throws -> SourceChunk {
        guard let row = try Row.fetchOne(db, sql: "SELECT summary_json, text FROM source_chunks WHERE id = ?", arguments: [Self.id(chunkID)]) else { throw MiraError(.notFound, "The source chunk is unavailable.") }
        return .init(summary: try Self.decode(row["summary_json"]), text: row["text"])
    }
    func writeKnowledgeSource(_ source: KnowledgeSource, in db: Database) throws {
        try db.execute(sql: "UPDATE knowledge_sources SET title = ?, current_version_id = ?, allows_remote_use = ?, revision = ?, updated_at = ?, deleted_at = ?, source_json = ? WHERE id = ?", arguments: [source.title, source.currentVersionID.map(Self.id), source.allowsRemoteUse, source.revision, source.updatedAt.timeIntervalSince1970, source.deletedAt?.timeIntervalSince1970, try Self.encode(source), Self.id(source.id)])
    }
    static func knowledgeHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func normalizeKnowledge(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func createKnowledgeSchema(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE managed_blobs (digest TEXT PRIMARY KEY NOT NULL CHECK(length(digest)=64), byte_count INTEGER NOT NULL CHECK(byte_count BETWEEN 0 AND 10485760), created_at REAL NOT NULL, pending_deletion_at REAL);
        CREATE TABLE knowledge_sources (id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT REFERENCES workspaces(id), title TEXT NOT NULL, current_version_id TEXT, allows_remote_use INTEGER NOT NULL CHECK(allows_remote_use IN (0,1)), revision INTEGER NOT NULL CHECK(revision>0), created_at REAL NOT NULL, updated_at REAL NOT NULL, deleted_at REAL, source_json TEXT NOT NULL);
        CREATE TABLE source_versions (id TEXT PRIMARY KEY NOT NULL, source_id TEXT NOT NULL REFERENCES knowledge_sources(id), content_hash TEXT NOT NULL REFERENCES managed_blobs(digest), byte_count INTEGER NOT NULL CHECK(byte_count BETWEEN 0 AND 10485760), parse_state TEXT NOT NULL CHECK(parse_state IN ('ready','failed')), created_at REAL NOT NULL, version_json TEXT NOT NULL);
        CREATE TABLE source_chunks (id TEXT UNIQUE NOT NULL, source_id TEXT NOT NULL REFERENCES knowledge_sources(id), version_id TEXT NOT NULL REFERENCES source_versions(id), sequence INTEGER NOT NULL CHECK(sequence>=0), text TEXT NOT NULL, normalized_text TEXT NOT NULL, summary_json TEXT NOT NULL, UNIQUE(version_id,sequence));
        CREATE TABLE source_usages (execution_id TEXT NOT NULL REFERENCES executions(id), source_id TEXT NOT NULL REFERENCES knowledge_sources(id), version_id TEXT NOT NULL, chunk_key TEXT NOT NULL, created_at REAL NOT NULL, PRIMARY KEY(execution_id,source_id,version_id,chunk_key));
        CREATE INDEX knowledge_sources_scope ON knowledge_sources(workspace_id,deleted_at,updated_at,id);
        CREATE INDEX source_versions_source ON source_versions(source_id,created_at,id);
        CREATE INDEX source_chunks_source ON source_chunks(source_id,version_id,sequence);
        CREATE INDEX source_usages_source ON source_usages(source_id,execution_id);
        CREATE VIRTUAL TABLE knowledge_words USING fts5(content, tokenize='unicode61');
        """)
        do { try db.execute(sql: "CREATE VIRTUAL TABLE knowledge_trigrams USING fts5(content, tokenize='trigram')") }
        catch { /* The bounded normalized-text fallback remains available. */ }
    }
}
