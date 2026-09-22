import Foundation
import GRDB
import MiraCore

/// Durable, body-free handoff between the application-scoped delete command and
/// the library maintenance coordinator.
extension SQLiteMemoryStore: MemoryDeletionStore {
    private static let deletionLimit = 128

    public func pendingMemoryDeletions(limit: Int) async throws -> [MemoryDeletionRequest] {
        guard (1...Self.deletionLimit).contains(limit) else { throw Self.invalid }
        return try await owner.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM memory_deletion_requests WHERE state = 'pending' ORDER BY requested_at, id LIMIT ?",
                arguments: [limit])
            return try rows.map { try Self.deletionRequest($0, in: db) }
        }
    }

    public func memoryDeletions(sessionID: ConversationID, executionIDs: Set<ExecutionID>,
                                workspaceID: WorkspaceID?) async throws -> [MemoryDeletionRequest] {
        guard executionIDs.count <= Self.deletionLimit else { throw Self.limit }
        guard !executionIDs.isEmpty else { return [] }
        return try await owner.read { db in
            let ids = executionIDs.map { $0.rawValue.uuidString.lowercased() }.sorted()
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            var argumentValues: [(any DatabaseValueConvertible)?] = [sessionID.rawValue.uuidString.lowercased()]
            for id in ids { argumentValues.append(id) }
            argumentValues.append(workspaceID.map(Self.key))
            argumentValues.append(Self.deletionLimit + 1)
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM memory_deletion_requests WHERE session_id = ? AND execution_id IN (\(placeholders)) AND workspace_id IS ? ORDER BY requested_at, id LIMIT ?",
                arguments: StatementArguments(argumentValues))
            guard rows.count <= Self.deletionLimit else { throw Self.limit }
            return try rows.map { try Self.deletionRequest($0, in: db) }
        }
    }

    public func settleMemoryDeletion(_ request: MemoryDeletionRequest, state: MemoryDeletionRequest.State,
                                     authorization: AgentLibraryAuthorization) async throws {
        try request.validate()
        guard request.state == .pending, state != .pending else { throw Self.invalid }
        try await owner.write(authorization: authorization) { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM memory_deletion_requests WHERE id = ?",
                                             arguments: [Self.key(request.id)]) else { throw Self.unavailable }
            let stored = try Self.deletionRequest(row, in: db)
            guard Self.sameDeletionIdentity(stored, request) else { throw Self.conflict }
            switch state {
            case .completed:
                guard let operation = try SQLiteLibraryAuthority.readOperation(
                    id: request.id, in: db, libraryID: self.owner.libraryID),
                    operation.completedAt != nil,
                    operation.request == request.maintenanceRequest else { throw Self.conflict }
            case .failed:
                guard try SQLiteLibraryAuthority.readOperation(id: request.id, in: db, libraryID: self.owner.libraryID) == nil,
                      try SQLiteLibraryAuthority.readState(in: db, libraryID: self.owner.libraryID).pending == nil,
                      let memoryRow = try Row.fetchOne(db, sql: "SELECT * FROM memory_records WHERE id = ?",
                                                       arguments: [Self.key(request.target.memoryID)]) else { throw Self.conflict }
                let memory = try Self.record(memoryRow)
                let stillValid = memory.revision == request.target.revision && memory.state == .active &&
                    memory.supersededBy == nil && memory.deletedAt == nil && memory.forgottenAt == nil && memory.draft != nil
                guard !stillValid else { throw Self.conflict }
            case .pending:
                throw Self.invalid
            }
            if stored.state == state { return }
            guard stored.state == .pending else { throw Self.conflict }
            var updated = request
            updated.state = state
            try db.execute(sql: "UPDATE memory_deletion_requests SET state = ?, json = ? WHERE id = ?",
                           arguments: [state.rawValue, try Self.encode(updated), Self.key(request.id)])
        }
    }

    /// Called by the business effect transaction. The quote is validated by the
    /// handler but is deliberately absent from this durable request.
    static func enqueueDeletionInTransaction(_ request: MemoryDeletionRequest, in db: Database) throws -> MemoryDeletionRequest {
        try request.validate()
        guard request.state == .pending else { throw invalid }
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM memory_deletion_requests WHERE id = ?",
                                      arguments: [key(request.id)]) {
            let prior = try deletionRequest(row, in: db)
            guard sameDeletionIdentity(prior, request) else { throw conflict }
            return prior
        }
        guard try Row.fetchOne(db, sql: "SELECT 1 FROM memory_records WHERE id = ?", arguments: [key(request.target.memoryID)]) != nil else {
            throw unavailable
        }
        let sourceJSON = try encode(request.source)
        let sourceKey = try Self.sourceKey(.userMessage(request.source))
        let json = try encode(request)
        try db.execute(sql: """
            INSERT INTO memory_deletion_requests
              (id, memory_id, expected_revision, source_key, source_json, session_id, execution_id, workspace_id, requested_at, state, json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)
            """, arguments: [key(request.id), key(request.target.memoryID), request.target.revision,
                              sourceKey, sourceJSON, key(request.source.sessionID), key(request.executionID),
                              request.workspaceID.map(key), request.requestedAt.timeIntervalSince1970, json])
        return request
    }

    static func deletionRequest(_ row: Row, in db: Database) throws -> MemoryDeletionRequest {
        guard let idText: String = row["id"], key(try uuid(idText)) == idText,
              let memoryText: String = row["memory_id"], key(try uuid(memoryText)) == memoryText,
              let revision: Int = row["expected_revision"], revision > 0,
              let sourceKey: String = row["source_key"], sourceKey.utf8.count == 64,
              let sourceJSON: Data = row["source_json"],
              let sessionText: String = row["session_id"], key(try uuid(sessionText)) == sessionText,
              let executionText: String = row["execution_id"], key(try uuid(executionText)) == executionText,
              let requestedAt: Double = row["requested_at"], requestedAt.isFinite,
              let stateText: String = row["state"], let state = MemoryDeletionRequest.State(rawValue: stateText),
              let json: Data = row["json"] else { throw corrupt }
        let value: MemoryDeletionRequest = try decode(json)
        try value.validate()
        let source: SessionEvidenceReference = try decode(sourceJSON)
        let id = try uuid(idText)
        let memoryID = try uuid(memoryText)
        let sessionID = try uuid(sessionText)
        let executionID = try uuid(executionText)
        guard value.id == id, value.target.memoryID == MemoryID(memoryID),
              value.target.revision == revision, value.source == source,
              value.source.sessionID == ConversationID(sessionID),
              value.executionID == ExecutionID(executionID),
              value.workspaceID.map(key) == (row["workspace_id"] as String?),
              value.requestedAt.timeIntervalSince1970 == requestedAt, value.state == state,
              try encode(source) == sourceJSON, try Self.sourceKey(.userMessage(source)) == sourceKey,
              try Row.fetchOne(db, sql: "SELECT 1 FROM memory_records WHERE id = ?", arguments: [key(value.target.memoryID)]) != nil
        else { throw corrupt }
        let operation = try SQLiteLibraryAuthority.readOperation(
            id: value.id, in: db,
            libraryID: try SQLiteLibraryAuthority.readState(in: db).authorization.libraryID)
        switch value.state {
        case .pending:
            if let operation {
                guard operation.request == value.maintenanceRequest else { throw corrupt }
            }
        case .completed:
            guard let operation, operation.completedAt != nil,
                  operation.request == value.maintenanceRequest else { throw corrupt }
        case .failed:
            guard operation == nil,
                  try SQLiteLibraryAuthority.readState(in: db).pending == nil,
                  let memoryRow = try Row.fetchOne(db, sql: "SELECT * FROM memory_records WHERE id = ?",
                                                   arguments: [key(value.target.memoryID)]) else { throw corrupt }
            let memory = try record(memoryRow)
            let stillValid = memory.revision == value.target.revision && memory.state == .active &&
                memory.supersededBy == nil && memory.deletedAt == nil && memory.forgottenAt == nil && memory.draft != nil
            guard !stillValid else { throw corrupt }
        }
        return value
    }

    /// A deletion request suppresses automatic recapture from its original
    /// source immediately after the tool commit, independent of queue state.
    static func deletionCaptureSuppressed(_ source: MemoryEvidenceSource, in db: Database) throws -> Bool {
        let sourceKey = try Self.sourceKey(source)
        return try Int.fetchOne(db, sql: "SELECT 1 FROM memory_deletion_requests WHERE source_key = ? LIMIT 1",
                                arguments: [sourceKey]) != nil
    }

    static func sameDeletionIdentity(_ lhs: MemoryDeletionRequest, _ rhs: MemoryDeletionRequest) -> Bool {
        lhs.id == rhs.id && lhs.target == rhs.target && lhs.source == rhs.source &&
            lhs.executionID == rhs.executionID && lhs.workspaceID == rhs.workspaceID &&
            lhs.requestedAt == rhs.requestedAt
    }

    static func sameDeletionTarget(_ lhs: MemoryDeletionRequest, _ rhs: MemoryDeletionRequest) -> Bool {
        lhs.id == rhs.id && lhs.target == rhs.target && lhs.source == rhs.source &&
            lhs.executionID == rhs.executionID && lhs.workspaceID == rhs.workspaceID
    }
}
