import Foundation
import GRDB
import MiraCore

/// Knowledge privacy owns the immutable scope and domain rows. Session payload
/// invalidation and blob collection remain owned by the library coordinator.
extension SQLiteKnowledgeStore: KnowledgePrivacyStore {
    private static var privacyLimit: MiraError {
        .init(.outputLimit, "The knowledge privacy scope is invalid or exceeds its limits.")
    }

    static func captureKnowledgePrivacy(
        _ request: AgentLibraryMaintenanceRequest,
        in db: Database
    ) throws -> KnowledgePrivacyScope {
        try request.validate()
        let action = try privacyAction(for: request)
        let (sourceID, expectedRevision) = try privacyTarget(from: request)
        guard
            let row = try Row.fetchOne(
                db, sql: "SELECT * FROM knowledge_sources WHERE id = ?", arguments: [key(sourceID)])
        else {
            throw unavailable
        }
        let source = try record(row)
        guard (1...8_192).contains(expectedRevision) else { throw invalid }
        guard source.revision == expectedRevision, source.deletedAt == nil else { throw conflict }

        let versionCursor = try Row.fetchCursor(
            db,
            sql: "SELECT * FROM knowledge_versions WHERE source_id = ? ORDER BY created_at, id LIMIT ?",
            arguments: [key(sourceID), 8_193])
        var versions: [KnowledgePrivacyVersion] = []
        while let row = try versionCursor.next() {
            guard versions.count < 8_192 else { throw privacyLimit }
            let value = try version(row)
            versions.append(.init(id: value.id, digest: value.contentHash, byteCount: value.byteCount))
        }
        guard !versions.isEmpty else { throw corrupt }
        let versionIDs = Set(versions.map(\.id))

        let chunkLimit = 8_192 - expectedRevision
        let chunkCursor = try Row.fetchCursor(
            db,
            sql: "SELECT * FROM knowledge_chunks WHERE source_id = ? ORDER BY version_id, sequence, id LIMIT ?",
            arguments: [key(sourceID), chunkLimit + 1])
        var chunks: [KnowledgePrivacyChunk] = []
        while let row = try chunkCursor.next() {
            guard chunks.count < chunkLimit else { throw privacyLimit }
            let value = try chunk(row).summary
            guard value.sourceID == sourceID, versionIDs.contains(value.sourceVersionID) else { throw corrupt }
            chunks.append(.init(id: value.id, versionID: value.sourceVersionID))
        }
        guard Set(chunks.map(\.id)).count == chunks.count else { throw corrupt }

        let operationCursor = try Row.fetchCursor(
            db,
            sql: "SELECT operation_id FROM knowledge_operations WHERE source_id = ? ORDER BY operation_id LIMIT ?",
            arguments: [key(sourceID), 8_193])
        var operationIDs: [UUID] = []
        while let row = try operationCursor.next() {
            guard operationIDs.count < 8_192 else { throw privacyLimit }
            guard let value: String = row["operation_id"] else { throw corrupt }
            operationIDs.append(try uuid(value))
        }
        let scope = KnowledgePrivacyScope(
            action: action, sourceID: sourceID, workspaceID: source.workspaceID,
            expectedRevision: expectedRevision, currentVersionID: source.currentVersionID,
            versions: versions, chunks: chunks, operationIDs: operationIDs)
        try scope.validate(for: request)
        return scope
    }

    public func prepareKnowledgePrivacy(operation: AgentLibraryMaintenanceOperation) async throws
        -> KnowledgePrivacyScope
    {
        try operation.validate()
        let result: (KnowledgePrivacyScope, Bool) = try await owner.maintain(
            operation,
            afterCommit: { result in
                if result.1 { try self.fault(.afterPrivacyScopeCommit) }
            }
        ) { db -> (KnowledgePrivacyScope, Bool) in
            if let existing = try self.readPrivacyScope(operation: operation, in: db) {
                try existing.validate(for: operation)
                return (existing, false)
            }
            let scope = try Self.captureKnowledgePrivacy(operation.request, in: db)
            try scope.validate(for: operation)
            try self.writePrivacyScope(scope, operation: operation, in: db)
            return (scope, true)
        }
        return result.0
    }

    public func applyKnowledgePrivacy(
        _ scope: KnowledgePrivacyScope,
        operation: AgentLibraryMaintenanceOperation
    ) async throws {
        try scope.validate(for: operation)
        let saved = try await readPrivacyScope(operation: operation)
        guard saved == scope else { throw Self.conflict }
        switch scope.action {
        case .revokeRemoteUse:
            _ = try await revokeSourceRemoteUse(
                scope.sourceID, workspaceID: scope.workspaceID,
                expectedRevision: scope.expectedRevision, maintenance: operation,
                at: operation.request.requestedAt)
        case .deleteSource:
            try await purgeKnowledgeSource(
                scope.sourceID, workspaceID: scope.workspaceID,
                expectedRevision: scope.expectedRevision, maintenance: operation,
                at: operation.request.requestedAt)
        }
    }

    public func verifyKnowledgePrivacy(
        _ scope: KnowledgePrivacyScope,
        operation: AgentLibraryMaintenanceOperation
    ) async throws {
        try scope.validate(for: operation)
        let saved = try await readPrivacyScope(operation: operation)
        guard saved == scope else { throw Self.conflict }
        try await owner.maintain(operation) { db in
            guard
                try Self.hasMaintenance(
                    operation, id: scope.sourceID, workspaceID: scope.workspaceID,
                    expected: scope.expectedRevision, in: db)
            else { throw Self.conflict }
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM knowledge_sources WHERE id = ?",
                    arguments: [Self.key(scope.sourceID)])
            else { throw Self.corrupt }
            let source = try Self.record(row)
            guard source.workspaceID == scope.workspaceID,
                source.revision == scope.expectedRevision + 1,
                source.updatedAt.timeIntervalSince1970 == operation.request.requestedAt.timeIntervalSince1970
            else { throw Self.conflict }

            switch scope.action {
            case .revokeRemoteUse:
                try Self.verifyRevoked(scope, source: source, in: db)
            case .deleteSource:
                try Self.verifyDeleted(scope, source: source, operation: operation, in: db)
            }
        }
    }

    private func readPrivacyScope(operation: AgentLibraryMaintenanceOperation) async throws -> KnowledgePrivacyScope {
        try operation.validate()
        return try await owner.maintain(operation) { db in
            guard let scope = try self.readPrivacyScope(operation: operation, in: db) else { throw Self.conflict }
            try scope.validate(for: operation)
            return scope
        }
    }

    private func readPrivacyScope(
        operation: AgentLibraryMaintenanceOperation,
        in db: Database
    ) throws -> KnowledgePrivacyScope? {
        let operationID = operation.request.id.uuidString
        guard
            let row = try Row.fetchOne(
                db,
                sql:
                    "SELECT library_id, byte_count, length(scope_json) AS stored_length, digest FROM knowledge_privacy_scopes WHERE operation_id = ?",
                arguments: [operationID])
        else { return nil }
        guard row["library_id"] as String? == owner.libraryID.uuidString,
            let count: Int = row["byte_count"],
            row["stored_length"] as Int? == count,
            (1...KnowledgePrivacyScope.maximumBytes).contains(count),
            let digest: String = row["digest"]
        else { throw Self.corrupt }
        guard
            let bytes = try Data.fetchOne(
                db, sql: "SELECT scope_json FROM knowledge_privacy_scopes WHERE operation_id = ?",
                arguments: [operationID]), bytes.count == count,
            Self.hash(bytes) == digest
        else { throw Self.corrupt }
        do {
            let scope: KnowledgePrivacyScope = try SessionCodec.decode(KnowledgePrivacyScope.self, from: bytes)
            try scope.validate(for: operation)
            return scope
        } catch { throw Self.corrupt }
    }

    private func writePrivacyScope(
        _ scope: KnowledgePrivacyScope,
        operation: AgentLibraryMaintenanceOperation,
        in db: Database
    ) throws {
        let bytes = try SessionCodec.encode(scope)
        guard !bytes.isEmpty, bytes.count <= KnowledgePrivacyScope.maximumBytes else { throw Self.privacyLimit }
        try db.execute(
            sql:
                "INSERT INTO knowledge_privacy_scopes(operation_id, library_id, byte_count, digest, scope_json) VALUES (?, ?, ?, ?, ?)",
            arguments: [
                operation.request.id.uuidString, owner.libraryID.uuidString, bytes.count, Self.hash(bytes), bytes,
            ])
    }

    private static func privacyAction(for request: AgentLibraryMaintenanceRequest) throws -> KnowledgePrivacyAction {
        switch request.namespace {
        case KnowledgePrivacyAction.revokeRemoteUse.namespace: return .revokeRemoteUse
        case KnowledgePrivacyAction.deleteSource.namespace: return .deleteSource
        default: throw unauthorized
        }
    }

    private static func privacyTarget(from request: AgentLibraryMaintenanceRequest) throws -> (KnowledgeSourceID, Int) {
        guard case .sources(let sources) = request.scope, sources.count == 1,
            case .domain(let namespace, let id, let revision) = sources[0],
            namespace == KnowledgeSources.metadataNamespace
        else { throw unauthorized }
        return (KnowledgeSourceID(id), revision)
    }

    private static func verifyRevoked(
        _ scope: KnowledgePrivacyScope, source: KnowledgeSource, in db: Database
    ) throws {
        guard !source.allowsRemoteUse, source.deletedAt == nil,
            source.currentVersionID == scope.currentVersionID
        else { throw conflict }
        try verifyVersionInventory(scope, in: db, shouldBePresent: true)
        try verifyChunkInventory(scope, in: db, shouldBePresent: true)
        try verifyOperationInventory(scope, in: db, clearBodies: false)
    }

    private static func verifyDeleted(
        _ scope: KnowledgePrivacyScope, source: KnowledgeSource,
        operation: AgentLibraryMaintenanceOperation, in db: Database
    ) throws {
        guard source.currentVersionID == nil, !source.allowsRemoteUse,
            source.title == "Deleted source"
        else { throw conflict }
        guard source.deletedAt?.timeIntervalSince1970 == operation.request.requestedAt.timeIntervalSince1970 else {
            throw conflict
        }
        try verifyVersionInventory(scope, in: db, shouldBePresent: false)
        try verifyChunkInventory(scope, in: db, shouldBePresent: false)
        guard
            try Int.fetchOne(
                db, sql: "SELECT count(*) FROM knowledge_chunks WHERE source_id = ?",
                arguments: [key(scope.sourceID)]) == 0
        else { throw conflict }
        for table in ["knowledge_words", "knowledge_trigrams"] {
            guard
                try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM \(table) WHERE rowid NOT IN (SELECT rowid FROM knowledge_chunks)"
                ) == 0
            else { throw conflict }
        }
        try verifyOperationInventory(scope, in: db, clearBodies: true)
    }

    private static func verifyOperationInventory(
        _ scope: KnowledgePrivacyScope, in db: Database, clearBodies: Bool
    ) throws {
        let cursor = try Row.fetchCursor(
            db,
            sql:
                "SELECT operation_id, source_id, request_hash IS NULL AS request_hash_missing, receipt_json IS NULL AS receipt_missing FROM knowledge_operations WHERE source_id = ? ORDER BY operation_id LIMIT ?",
            arguments: [key(scope.sourceID), scope.operationIDs.count + 1])
        var actual: [UUID] = []
        while let row = try cursor.next() {
            guard actual.count < scope.operationIDs.count + 1 else { throw conflict }
            guard let value: String = row["operation_id"] else { throw corrupt }
            let id = try uuid(value)
            guard row["source_id"] as String? == key(scope.sourceID) else { throw conflict }
            let requestHashMissing: Int = row["request_hash_missing"]
            let receiptMissing: Int = row["receipt_missing"]
            guard requestHashMissing == (clearBodies ? 1 : 0),
                receiptMissing == (clearBodies ? 1 : 0)
            else { throw conflict }
            actual.append(id)
        }
        guard actual.count == scope.operationIDs.count else { throw conflict }
        guard Set(actual) == Set(scope.operationIDs) else { throw conflict }
    }

    private static func verifyVersionInventory(
        _ scope: KnowledgePrivacyScope, in db: Database,
        shouldBePresent: Bool
    ) throws {
        let cursor = try Row.fetchCursor(
            db, sql: "SELECT * FROM knowledge_versions WHERE source_id = ? ORDER BY created_at, id LIMIT ?",
            arguments: [key(scope.sourceID), scope.versions.count + 1])
        var actual: [KnowledgePrivacyVersion] = []
        while let row = try cursor.next() {
            guard actual.count < scope.versions.count + 1 else { throw conflict }
            let value = try version(row)
            actual.append(.init(id: value.id, digest: value.contentHash, byteCount: value.byteCount))
        }
        guard actual.count == (shouldBePresent ? scope.versions.count : 0) else { throw conflict }
        if shouldBePresent { guard actual == scope.versions else { throw conflict } }
    }

    private static func verifyChunkInventory(
        _ scope: KnowledgePrivacyScope, in db: Database,
        shouldBePresent: Bool
    ) throws {
        let cursor = try Row.fetchCursor(
            db,
            sql:
                "SELECT id, source_id, version_id FROM knowledge_chunks WHERE source_id = ? ORDER BY version_id, sequence, id LIMIT ?",
            arguments: [key(scope.sourceID), scope.chunks.count + 1])
        var actual: [KnowledgePrivacyChunk] = []
        while let row = try cursor.next() {
            guard actual.count < scope.chunks.count + 1 else { throw conflict }
            guard let idValue: String = row["id"],
                let sourceValue: String = row["source_id"],
                let versionValue: String = row["version_id"],
                sourceValue == key(scope.sourceID)
            else { throw corrupt }
            actual.append(.init(id: .init(try uuid(idValue)), versionID: .init(try uuid(versionValue))))
        }
        guard actual.count == (shouldBePresent ? scope.chunks.count : 0) else { throw conflict }
        if shouldBePresent { guard actual == scope.chunks else { throw conflict } }
    }
}
