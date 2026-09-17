import Accelerate
import CryptoKit
import Foundation
import GRDB
import MiraCore

extension SQLiteMemoryStore: MemoryIndexStore {
    static let vectorSchemaDefinitions: [(String, String)] = [
        ("memory_embedding_state", "CREATE TABLE memory_embedding_state(id INTEGER PRIMARY KEY CHECK(id=1), fingerprint TEXT NOT NULL, dimensions INTEGER NOT NULL, generation TEXT NOT NULL)"),
        ("memory_embedding_jobs", "CREATE TABLE memory_embedding_jobs(memory_id TEXT PRIMARY KEY NOT NULL REFERENCES memory_records(id), revision INTEGER NOT NULL, content_hash TEXT NOT NULL, generation TEXT NOT NULL, failed INTEGER NOT NULL DEFAULT 0 CHECK(failed IN (0,1)))"),
        ("memory_embeddings", "CREATE TABLE memory_embeddings(memory_id TEXT PRIMARY KEY NOT NULL REFERENCES memory_records(id), revision INTEGER NOT NULL, content_hash TEXT NOT NULL, generation TEXT NOT NULL, vector BLOB NOT NULL)")
    ]

    static func initializeVectors(identity: MemoryEmbeddingIdentity, in db: Database) throws {
        guard identity.dimensions > 0, identity.dimensions <= 4096, !identity.fingerprint.isEmpty else { throw invalid }
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM memory_embedding_state WHERE id = 1"),
           row["fingerprint"] as String == identity.fingerprint, row["dimensions"] as Int == identity.dimensions {
            _ = try uuid(row["generation"])
        } else {
            try db.execute(sql: "DELETE FROM memory_embeddings")
            try db.execute(sql: "DELETE FROM memory_embedding_jobs")
            try db.execute(sql: "DELETE FROM memory_embedding_state")
            try db.execute(sql: "INSERT INTO memory_embedding_state VALUES (1, ?, ?, ?)",
                           arguments: [identity.fingerprint, identity.dimensions, key(UUID())])
        }
        // Restored archives omit the derived index. Queue current facts without copying their text.
        let rows = try Row.fetchCursor(db, sql: "SELECT m.* FROM memory_records m LEFT JOIN memory_embeddings v ON v.memory_id=m.id LEFT JOIN memory_embedding_jobs j ON j.memory_id=m.id WHERE v.memory_id IS NULL AND j.memory_id IS NULL AND m.state='active' AND m.superseded_by IS NULL AND m.forgotten_at IS NULL AND m.deleted_at IS NULL")
        var missing: [Memory] = []
        while let row = try rows.next() { missing.append(try record(row)) }
        for memory in missing { try invalidateVector(memory, in: db) }
    }

    /// Runs inside every canonical memory write, including extraction, supersession and privacy purge.
    static func invalidateVector(_ memory: Memory, in db: Database) throws {
        try db.execute(sql: "DELETE FROM memory_embeddings WHERE memory_id=?", arguments: [key(memory.id)])
        try db.execute(sql: "DELETE FROM memory_embedding_jobs WHERE memory_id=?", arguments: [key(memory.id)])
        guard memory.isCurrent, memory.deletedAt == nil, let draft = memory.draft, draft.allowsRemoteUse,
              let generation = try String.fetchOne(db, sql: "SELECT generation FROM memory_embedding_state WHERE id=1") else { return }
        try db.execute(sql: "INSERT INTO memory_embedding_jobs(memory_id, revision, content_hash, generation) VALUES (?, ?, ?, ?)",
                       arguments: [key(memory.id), memory.revision, embeddingHash(draft.content), generation])
    }

    public func hasMemoryVectors() async throws -> Bool {
        try await owner.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM memory_embeddings)") == true
        }
    }

    public func pendingMemoryIndexJobs(limit: Int) async throws -> [MemoryIndexJob] {
        guard (1...4).contains(limit) else { throw Self.invalid }
        return try await owner.read { db in
            guard let state = try Row.fetchOne(db, sql: "SELECT * FROM memory_embedding_state WHERE id=1") else { throw Self.corrupt }
            let identity = MemoryEmbeddingIdentity(fingerprint: state["fingerprint"], dimensions: state["dimensions"])
            let generation = try Self.uuid(state["generation"])
            return try Row.fetchAll(db, sql: "SELECT m.*, j.content_hash FROM memory_embedding_jobs j JOIN memory_records m ON m.id=j.memory_id AND m.revision=j.revision WHERE j.failed=0 AND j.generation=? ORDER BY m.id LIMIT ?", arguments: [Self.key(generation), limit]).map { row in
                let memory = try Self.record(row)
                guard memory.isCurrent, memory.deletedAt == nil, let draft = memory.draft, draft.allowsRemoteUse,
                      Self.embeddingHash(draft.content) == row["content_hash"] as String else { throw Self.corrupt }
                return .init(memoryID: memory.id, revision: memory.revision, content: draft.content,
                             contentHash: row["content_hash"], generation: generation, identity: identity)
            }
        }
    }

    public func completeMemoryIndexJob(_ job: MemoryIndexJob, vector: [Float], authorization: AgentLibraryAuthorization) async throws -> Bool {
        let bytes = try Self.vectorBytes(vector, dimensions: job.identity.dimensions)
        return try await owner.write(authorization: authorization) { db in
            guard try Self.indexJobIsCurrent(job, in: db) else { return false }
            try db.execute(sql: "INSERT OR REPLACE INTO memory_embeddings VALUES (?, ?, ?, ?, ?)",
                           arguments: [Self.key(job.memoryID), job.revision, job.contentHash, Self.key(job.generation), bytes])
            try db.execute(sql: "DELETE FROM memory_embedding_jobs WHERE memory_id=?", arguments: [Self.key(job.memoryID)])
            return true
        }
    }

    public func failMemoryIndexJob(_ job: MemoryIndexJob, authorization: AgentLibraryAuthorization) async throws {
        try await owner.write(authorization: authorization) { db in
            guard try Self.indexJobIsCurrent(job, in: db) else { return }
            try db.execute(sql: "UPDATE memory_embedding_jobs SET failed=1 WHERE memory_id=?", arguments: [Self.key(job.memoryID)])
        }
    }

    private static func indexJobIsCurrent(_ job: MemoryIndexJob, in db: Database) throws -> Bool {
        guard let row = try Row.fetchOne(db, sql: "SELECT m.*, j.content_hash, j.generation FROM memory_embedding_jobs j JOIN memory_records m ON m.id=j.memory_id AND m.revision=j.revision JOIN memory_embedding_state s ON s.generation=j.generation WHERE j.memory_id=? AND j.revision=? AND j.content_hash=? AND j.generation=? AND s.fingerprint=? AND s.dimensions=?",
                                        arguments: [key(job.memoryID), job.revision, job.contentHash, key(job.generation), job.identity.fingerprint, job.identity.dimensions]) else { return false }
        let memory = try record(row)
        return memory.isCurrent && memory.deletedAt == nil && memory.draft?.allowsRemoteUse == true &&
            memory.draft?.content == job.content && embeddingHash(job.content) == job.contentHash
    }

    // Admission floor for the pinned Qwen 4-bit memory-query space. A nearest
    // neighbor is not necessarily relevant, even when the library is very small.
    // Reevaluate this floor when the model or query instruction changes.
    static let minimumSemanticRecallSimilarity: Float = 0.5

    static func semanticSearch(vector: [Float], identity: MemoryEmbeddingIdentity, request: AgentContextRequest,
                               limit: Int, at: Date, in db: Database) throws -> MemorySearchResult {
        _ = try vectorBytes(vector, dimensions: identity.dimensions)
        let (conditions, arguments) = try eligibility(workspaceID: request.workspaceID, states: [.active], request: request, at: at, in: db)
        let rows = try Row.fetchCursor(db, sql: "SELECT m.*, v.vector, v.content_hash FROM memory_records m JOIN memory_embeddings v ON v.memory_id=m.id AND v.revision=m.revision JOIN memory_embedding_state s ON s.generation=v.generation WHERE \(conditions.joined(separator: " AND ")) AND s.fingerprint=? AND s.dimensions=?", arguments: arguments + [identity.fingerprint, identity.dimensions])
        var ranked: [(Memory, Float)] = []
        let candidateLimit = limit + 1
        while let row = try rows.next() {
            let memory = try record(row)
            guard let draft = memory.draft, row["content_hash"] as String == embeddingHash(draft.content) else { throw corrupt }
            let stored = try decodeVector(row["vector"], dimensions: identity.dimensions)
            var score: Float = 0
            vDSP_dotpr(vector, 1, stored, 1, &score, vDSP_Length(identity.dimensions))
            guard score.isFinite else { throw corrupt }
            guard score >= minimumSemanticRecallSimilarity else { continue }
            ranked.append((memory, score))
            if ranked.count > candidateLimit * 2 {
                ranked.sort { $0.1 == $1.1 ? key($0.0.id) < key($1.0.id) : $0.1 > $1.1 }
                ranked.removeLast(ranked.count - candidateLimit)
            }
        }
        ranked.sort { $0.1 == $1.1 ? key($0.0.id) < key($1.0.id) : $0.1 > $1.1 }
        return .init(memories: try ranked.prefix(limit).map { try recall($0.0.id, request: request, at: at, in: db) },
                     isTruncated: ranked.count > limit, retrieval: .hybrid)
    }

    static func embeddingHash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func vectorBytes(_ vector: [Float], dimensions: Int) throws -> Data {
        guard vector.count == dimensions, vector.allSatisfy(\.isFinite) else { throw invalid }
        let norm = vector.reduce(Float.zero) { $0 + $1 * $1 }
        guard abs(norm - 1) < 0.002 else { throw invalid }
        return vector.map { $0.bitPattern.littleEndian }.withUnsafeBytes { Data($0) }
    }

    private static func decodeVector(_ data: Data, dimensions: Int) throws -> [Float] {
        guard data.count == dimensions * 4 else { throw corrupt }
        let result = data.withUnsafeBytes { bytes in
            (0..<dimensions).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        guard result.allSatisfy(\.isFinite) else { throw corrupt }
        return result
    }
}
