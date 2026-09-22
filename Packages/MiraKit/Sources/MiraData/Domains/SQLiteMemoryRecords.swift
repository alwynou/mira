import Foundation
import CryptoKit
import GRDB
import MiraCore

extension SQLiteMemoryStore {
    static var corrupt: MiraError { .init(.storage, "The memory record is inconsistent.") }
    static var invalid: MiraError { .init(.invalidInput, "The memory input is invalid.") }
    static var conflict: MiraError { .init(.conflict, "The memory revision or operation is out of date.") }
    static var unavailable: MiraError { .init(.notFound, "The memory does not exist or is unavailable.") }
    static var unauthorized: MiraError { .init(.unauthorized, "The memory source is unavailable for this destination.") }
    static var limit: MiraError { .init(.outputLimit, "The memory operation exceeds its supported bounds.") }
    static func key<Tag>(_ id: EntityID<Tag>) -> String { key(id.rawValue) }
    static func key(_ id: UUID) -> String { id.uuidString.lowercased() }
    static func uuid(_ text: String) throws -> UUID {
        guard let id = UUID(uuidString: text), key(id) == text else { throw corrupt }; return id
    }
    static func date(_ date: Date) throws { guard date.timeIntervalSince1970.isFinite else { throw invalid } }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let bytes = try SessionCodec.encode(value); guard bytes.count <= 131_072 else { throw limit }; return bytes
    }
    static func decode<T: Decodable>(_ bytes: Data) throws -> T {
        guard !bytes.isEmpty, bytes.count <= 131_072 else { throw corrupt }
        do { return try SessionCodec.decode(T.self, from: bytes) } catch { throw corrupt }
    }
    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func sourceKey(_ identity: MemoryEvidenceSource) throws -> String { digest(try encode(identity)) }
    static func normalized(_ content: String) -> String { content.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() }

    struct ResolvedSource {
        let input: MemorySourceInput
        let identity: MemoryEvidenceSource
        let workspaceID: WorkspaceID?
        let excerpt: String
        let bodyHash: String
    }
    static func resolve(_ source: MemoryWriteSource, draft: MemoryDraft, in db: Database) throws -> ResolvedSource {
        if let workspaceID = draft.scope.workspaceID { _ = try SQLiteWorkspaceStore.read(workspaceID, in: db) }
        switch source {
        case .userMessage(let evidence, let excerpt):
            try evidence.reference.validate(); try date(evidence.admittedAt)
            guard !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, excerpt.utf8.count <= 8_192,
                  evidence.text.contains(excerpt), evidence.observedHead.cursor.sessionID == evidence.reference.sessionID,
                  evidence.observedHead.cursor.sequence >= evidence.reference.admissionSequence,
                  TimeZone(identifier: evidence.timeZoneIdentifier) != nil,
                  draft.scope.workspaceID == nil || draft.scope.workspaceID == evidence.workspaceID else { throw invalid }
            if let workspaceID = evidence.workspaceID { _ = try SQLiteWorkspaceStore.read(workspaceID, in: db) }
            return .init(input: .userMessage(reference: evidence.reference, excerpt: excerpt), identity: .userMessage(evidence.reference),
                         workspaceID: evidence.workspaceID, excerpt: excerpt, bodyHash: digest(Data(evidence.text.utf8)))
        case .manualEntry(let id, let statement):
            guard !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, statement.utf8.count <= 8_192 else { throw invalid }
            return .init(input: .manualEntry(id: id, statement: statement), identity: .manualEntry(id), workspaceID: nil,
                         excerpt: statement, bodyHash: digest(Data(statement.utf8)))
        }
    }
    static func bindSource(_ source: ResolvedSource, in db: Database) throws {
        let sourceKey = try sourceKey(source.identity)
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM memory_sources WHERE source_key = ?", arguments: [sourceKey]) {
            guard try sourceIdentity(row) == source.identity,
                  row["workspace_id"] as String? == source.workspaceID.map(key) else { throw corrupt }
            let oldHash: String? = row["body_hash"]
            if case .manualEntry = source.identity { guard oldHash == source.bodyHash else { throw conflict } }
            else if let oldHash { guard oldHash == source.bodyHash else { throw conflict } }
            return
        }
        try db.execute(sql: "INSERT INTO memory_sources(source_key, workspace_id, identity_json, body_hash, suppression) VALUES (?, ?, ?, ?, 0)", arguments: [sourceKey, source.workspaceID.map(key), try encode(source.identity), source.bodyHash])
    }
    static func sourceIdentity(_ row: Row) throws -> MemoryEvidenceSource {
        let source: MemoryEvidenceSource = try decode(row["identity_json"])
        if case .userMessage(let reference) = source { do { try reference.validate() } catch { throw corrupt } }
        if case .manualEntry = source { guard row["workspace_id"] as String? == nil else { throw corrupt } }
        guard try sourceKey(source) == row["source_key"] as String,
              (0...3).contains(row["suppression"] as Int) else { throw corrupt }
        return source
    }
    static func suppress(_ source: MemoryEvidenceSource, strength: Int, in db: Database) throws {
        guard (1...3).contains(strength), let row = try Row.fetchOne(db, sql: "SELECT * FROM memory_sources WHERE source_key = ?", arguments: [try sourceKey(source)]),
              try sourceIdentity(row) == source else { throw corrupt }
        try db.execute(sql: "UPDATE memory_sources SET suppression = max(suppression, ?) WHERE source_key = ?", arguments: [strength, try sourceKey(source)])
    }
    static func assertionKey(draft: MemoryDraft, source: MemoryEvidenceSource) throws -> String {
        struct Identity: Encodable { let source: MemoryEvidenceSource; let scope: MemoryScope; let subject: MemorySubject; let assertion: String }
        return digest(try encode(Identity(source: source, scope: draft.scope, subject: draft.subject, assertion: normalized(draft.content))))
    }
    static func fingerprint(kind: String, id: MemoryID? = nil, workspaceID: WorkspaceID? = nil, draft: MemoryDraft? = nil,
                            source: MemorySourceInput? = nil, replacing: MemoryID? = nil, expectedRevision: Int? = nil,
                            otherRevision: Int? = nil, state: MemoryState? = nil) throws -> String {
        // JSON Set iteration order must never change operation identity after reopening the library.
        struct StableDraft: Encodable {
            let content: String; let scope: MemoryScope; let subject: MemorySubject; let kind: MemoryKind
            let sensitivity: MemorySensitivity; let allowsRemoteUse: Bool; let connections: [String]?
            let validFrom: Date?; let validUntil: Date?
            init(_ draft: MemoryDraft) {
                content = draft.content; scope = draft.scope; subject = draft.subject; kind = draft.kind
                sensitivity = draft.sensitivity; allowsRemoteUse = draft.allowsRemoteUse
                connections = draft.allowedConnectionIDs.map { $0.map { $0.rawValue.uuidString.lowercased() }.sorted() }
                validFrom = draft.validFrom; validUntil = draft.validUntil
            }
        }
        struct Identity: Encodable {
            let kind: String; let id: MemoryID?; let workspaceID: WorkspaceID?; let draft: StableDraft?
            let source: MemorySourceInput?; let replacing: MemoryID?; let expectedRevision: Int?; let otherRevision: Int?; let state: MemoryState?
        }
        return digest(try encode(Identity(kind: kind, id: id, workspaceID: workspaceID, draft: draft.map(StableDraft.init), source: source,
                                          replacing: replacing, expectedRevision: expectedRevision, otherRevision: otherRevision, state: state)))
    }
    static func operation(_ id: UUID, request: String, in db: Database) throws -> MemoryWriteReceipt? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM memory_operations WHERE operation_id = ?", arguments: [key(id)]) else { return nil }
        guard let hash: String = row["request_hash"], let bytes: Data = row["receipt_json"] else { throw conflict }
        guard hash == request else { throw conflict }
        let receipt: MemoryWriteReceipt = try decode(bytes)
        try validate(receipt.memory)
        guard receipt.memory.id == MemoryID(try uuid(row["memory_id"])) else { throw corrupt }
        let current = try read(receipt.memory.id, workspaceID: receipt.memory.scope.workspaceID, in: db)
        guard current.forgottenAt == nil else { throw conflict }
        return receipt
    }
    static func saveOperation(_ id: UUID, request: String, receipt: MemoryWriteReceipt, dependencies: [MemoryID], in db: Database) throws {
        guard dependencies.contains(receipt.memory.id), Set(dependencies).count == dependencies.count else { throw corrupt }
        try db.execute(sql: "INSERT INTO memory_operations(operation_id, request_hash, memory_id, receipt_json) VALUES (?, ?, ?, ?)", arguments: [key(id), request, key(receipt.memory.id), try encode(receipt)])
        for memoryID in dependencies {
            try db.execute(sql: "INSERT INTO memory_operation_dependencies(operation_id, memory_id) VALUES (?, ?)", arguments: [key(id), key(memoryID)])
        }
    }
    static func validate(_ memory: Memory) throws {
        guard memory.revision > 0, memory.createdAt.timeIntervalSince1970.isFinite, memory.updatedAt.timeIntervalSince1970.isFinite,
              memory.deletedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              memory.forgottenAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              memory.subject != .workspace || memory.scope.workspaceID != nil,
              memory.supersededBy != memory.id,
              (memory.draft == nil) == (memory.forgottenAt != nil),
              (memory.deletedAt != nil) == (memory.state == .removed) else { throw corrupt }
        if let marker = memory.retraction {
            guard marker.priorRevision > 0, marker.priorRevision < Int.max,
                  marker.revision == marker.priorRevision + 1, marker.revision <= memory.revision,
                  marker.revision < Int.max,
                  marker.createdAt.timeIntervalSince1970.isFinite else { throw corrupt }
        }
        if let draft = memory.draft {
            do { try draft.validate() } catch { throw corrupt }
            guard draft.scope == memory.scope, draft.subject == memory.subject else { throw corrupt }
        }
    }
    static func record(_ row: Row) throws -> Memory {
        let memory: Memory = try decode(row["json"]); try validate(memory)
        let draft: MemoryDraft? = try (row["draft_json"] as Data?).map { try decode($0) }
        guard key(memory.id) == row["id"] as String, memory.revision == row["revision"] as Int,
              memory.scope.key == row["scope"] as String, memory.scope.workspaceID.map(key) == row["workspace_id"] as String?,
              memory.state.rawValue == row["state"] as String, memory.supersededBy.map(key) == row["superseded_by"] as String?,
              memory.deletedAt?.timeIntervalSince1970 == row["deleted_at"] as Double?,
              memory.forgottenAt?.timeIntervalSince1970 == row["forgotten_at"] as Double?, draft == memory.draft else { throw corrupt }
        return memory
    }
    static func read(_ id: MemoryID, workspaceID: WorkspaceID?, in db: Database) throws -> Memory {
        if let workspaceID { _ = try SQLiteWorkspaceStore.read(workspaceID, in: db) }
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM memory_records WHERE id = ?", arguments: [key(id)]) else { throw unavailable }
        let memory = try record(row); guard memory.scope.isVisible(in: workspaceID) else { throw unavailable }; return memory
    }
    static func mutable(_ id: MemoryID, workspaceID: WorkspaceID?, expected: Int, in db: Database) throws -> Memory {
        let memory = try read(id, workspaceID: workspaceID, in: db)
        guard memory.revision == expected, expected > 0, expected < Int.max, memory.forgottenAt == nil else { throw conflict }; return memory
    }
    static func write(_ memory: Memory, insert: Bool, in db: Database) throws {
        try validate(memory)
        let draft = try memory.draft.map(encode)
        let arguments: StatementArguments = [memory.revision, memory.scope.key, memory.scope.workspaceID.map(key), memory.state.rawValue,
            memory.supersededBy.map(key), memory.deletedAt?.timeIntervalSince1970, memory.forgottenAt?.timeIntervalSince1970, draft, try encode(memory), key(memory.id)]
        if insert {
            try db.execute(sql: "INSERT INTO memory_records(revision, scope, workspace_id, state, superseded_by, deleted_at, forgotten_at, draft_json, json, id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: arguments)
        } else {
            try db.execute(sql: "UPDATE memory_records SET revision = ?, scope = ?, workspace_id = ?, state = ?, superseded_by = ?, deleted_at = ?, forgotten_at = ?, draft_json = ?, json = ? WHERE id = ?", arguments: arguments)
            guard db.changesCount == 1 else { throw corrupt }
        }
        let revision = MemoryRevision(memoryID: memory.id, revision: memory.revision, draft: memory.draft, changedAt: memory.updatedAt, bodyPurgedAt: memory.forgottenAt)
        try db.execute(sql: "INSERT INTO memory_revisions(memory_id, revision, json) VALUES (?, ?, ?)", arguments: [key(memory.id), memory.revision, try encode(revision)])
        try db.execute(sql: "DELETE FROM memory_search WHERE memory_id = ?", arguments: [key(memory.id)])
        if let draft = memory.draft { try db.execute(sql: "INSERT INTO memory_search(memory_id, content) VALUES (?, ?)", arguments: [key(memory.id), draft.content]) }
        try invalidateVector(memory, in: db)
    }
    static func revision(_ row: Row, memoryID: MemoryID) throws -> MemoryRevision {
        let revision: MemoryRevision = try decode(row["json"])
        guard revision.memoryID == memoryID, key(memoryID) == row["memory_id"] as String,
              revision.revision == row["revision"] as Int, revision.revision > 0,
              revision.changedAt.timeIntervalSince1970.isFinite,
              (revision.draft == nil) == (revision.bodyPurgedAt != nil) else { throw corrupt }
        if let draft = revision.draft { do { try draft.validate() } catch { throw corrupt } }
        return revision
    }
    static func evidence(_ id: MemoryID, in db: Database) throws -> [MemoryEvidence] {
        guard let memoryRow = try Row.fetchOne(db, sql: "SELECT * FROM memory_records WHERE id = ?", arguments: [key(id)]) else {
            throw unavailable
        }
        let memory = try record(memoryRow)
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM memory_evidence WHERE memory_id = ? ORDER BY id LIMIT 101", arguments: [key(id)])
        guard !rows.isEmpty, rows.count <= 100 else { throw corrupt }
        return try rows.map { row in
            let value: MemoryEvidence = try decode(row["json"])
            guard value.memoryID == id, key(value.id) == row["id"] as String, key(id) == row["memory_id"] as String,
                  value.sourceWorkspaceID.map(key) == row["source_workspace_id"] as String?,
                  try sourceKey(value.source) == row["source_key"] as String,
                  value.createdAt.timeIntervalSince1970.isFinite,
                  value.bodyPurgedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                  value.retractionRevision.map({ $0 > 0 }) ?? true,
                  (value.excerpt == nil) == (value.bodyPurgedAt != nil),
                  (value.sourceHash == nil) == (value.bodyPurgedAt != nil),
                  let source = try Row.fetchOne(db, sql: "SELECT * FROM memory_sources WHERE source_key = ?", arguments: [try sourceKey(value.source)]),
                  try sourceIdentity(source) == value.source,
                  source["workspace_id"] as String? == value.sourceWorkspaceID.map(key) else { throw corrupt }
            if let markerRevision = value.retractionRevision {
                guard let marker = memory.retraction, markerRevision <= marker.revision,
                      try Row.fetchOne(db, sql: "SELECT 1 FROM memory_revisions WHERE memory_id = ? AND revision = ?",
                                       arguments: [key(id), markerRevision]) != nil else { throw corrupt }
            }
            return value
        }
    }
    static func compatible(_ draft: MemoryDraft?, previous: Memory) throws {
        guard let draft, let old = previous.draft, previous.forgottenAt == nil, previous.deletedAt == nil,
              previous.state == .active, previous.scope == draft.scope, previous.subject == draft.subject,
              (old.validFrom == nil && draft.validFrom == nil) || (old.validFrom != nil && draft.validFrom != nil && draft.validFrom! >= old.validFrom!),
              old.validUntil == draft.validUntil else { throw conflict }
    }
    static func relation(_ row: Row) throws -> MemoryReplacement {
        let value: MemoryReplacement = try decode(row["json"])
        guard key(value.id) == row["id"] as String, key(value.replacementID) == row["replacement_id"] as String,
              key(value.previousID) == row["previous_id"] as String, value.state.rawValue == row["state"] as String,
              value.replacementID != value.previousID, value.createdAt.timeIntervalSince1970.isFinite else { throw corrupt }
        return value
    }
    static func writeRelation(_ value: MemoryReplacement, in db: Database) throws {
        try db.execute(sql: "INSERT INTO memory_replacements(id, replacement_id, previous_id, state, json) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET state = excluded.state, json = excluded.json", arguments: [key(value.id), key(value.replacementID), key(value.previousID), value.state.rawValue, try encode(value)])
    }
}
