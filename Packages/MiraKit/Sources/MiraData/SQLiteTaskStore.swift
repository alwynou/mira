import Foundation
import GRDB
import MiraCore

public final class SQLiteTaskStore: TaskStore, @unchecked Sendable {
    let owner: SQLiteDomainDatabase
    public init(database: DatabaseQueue, libraryID: UUID) throws {
        owner = try SQLiteDomainDatabase(database: database, libraryID: libraryID, label: "mira.tasks")
        try database.write { db in
            guard try db.tableExists("business_workspaces") else { throw SQLiteDomainDatabase.invalidSchema }
            try Self.createTaskSchema(in: db)
        }
    }
    public func close() async { await owner.close() }

    static let archiveSchemaDefinitions: [(String, String)] = [
            ("task_schema", "CREATE TABLE task_schema(id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL CHECK(version=1))"),
            ("mira_tasks", "CREATE TABLE mira_tasks ( id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT REFERENCES business_workspaces(id), status TEXT NOT NULL CHECK(status IN ('open','inProgress','completed','cancelled')), revision INTEGER NOT NULL CHECK(revision > 0), reminder_at REAL, delivery_state TEXT NOT NULL CHECK(delivery_state IN ('none','pending','scheduled','permissionRequired','failed','elapsed','paused','cancelled')), delivery_revision INTEGER CHECK(delivery_revision > 0), updated_at REAL NOT NULL, task_json TEXT NOT NULL CHECK(length(task_json)<=131072) )"),
            ("mira_tasks_scope", "CREATE INDEX mira_tasks_scope ON mira_tasks(workspace_id, status, updated_at)"),
            ("mira_tasks_delivery", "CREATE INDEX mira_tasks_delivery ON mira_tasks(delivery_state, reminder_at)"),
            ("task_revisions", "CREATE TABLE task_revisions ( id TEXT PRIMARY KEY NOT NULL, task_id TEXT NOT NULL REFERENCES mira_tasks(id), revision INTEGER NOT NULL CHECK(revision > 0), revision_json TEXT NOT NULL CHECK(length(revision_json)<=131072), UNIQUE(task_id, revision) )"),
            ("task_proposals", "CREATE TABLE task_proposals ( id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT REFERENCES business_workspaces(id), state TEXT NOT NULL CHECK(state IN ('pending','accepted','rejected')), proposal_json TEXT NOT NULL CHECK(length(proposal_json)<=131072) )"),
            ("task_proposals_scope", "CREATE INDEX task_proposals_scope ON task_proposals(workspace_id, state)"),
            ("task_operations", "CREATE TABLE task_operations ( id TEXT PRIMARY KEY NOT NULL, business_key TEXT NOT NULL UNIQUE, request_json TEXT NOT NULL CHECK(length(request_json)<=131072), receipt_json TEXT NOT NULL CHECK(length(receipt_json)<=131072) )"),
    ]

    static var archiveSchemaStatements: [String] { archiveSchemaDefinitions.map(\.1) }

    static func createTaskSchema(in db: Database) throws {
        try SQLiteDomainDatabase.initialize(archiveSchemaDefinitions, metadata: "task_schema", in: db)
    }

    public func taskList(workspaceID: WorkspaceID?, includeCompleted: Bool, limit: Int) async throws -> [MiraTask] {
        try await owner.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM mira_tasks WHERE workspace_id IS ? AND (? OR status IN ('open','inProgress')) ORDER BY (reminder_at IS NULL), reminder_at, updated_at DESC, id LIMIT ?", arguments: [workspaceID.map(Self.id), includeCompleted, max(1, min(limit, 200))]).map(Self.taskRecord)
        }
    }

    public func taskDetail(_ id: MiraTaskID, workspaceID: WorkspaceID?) async throws -> MiraTask {
        try await owner.read { try Self.readTask(id, workspaceID: workspaceID, in: $0) }
    }

    public func taskRevisions(_ id: MiraTaskID, workspaceID: WorkspaceID?) async throws -> [TaskRevision] {
        try await owner.read { db in
            _ = try Self.readTask(id, workspaceID: workspaceID, in: db)
            return try Row.fetchAll(db, sql: "SELECT * FROM task_revisions WHERE task_id = ? ORDER BY revision DESC LIMIT 100", arguments: [Self.id(id)]).map { row in
                let revision = try Self.revisionRecord(row)
                guard revision.task.id == id, revision.task.workspaceID == workspaceID else { throw Self.taskConflict }
                return revision
            }
        }
    }

    public func saveTask(_ id: MiraTaskID, workspaceID: WorkspaceID?, draft: TaskDraft, status: MiraTaskStatus, expectedRevision: Int?, operationID: UUID, authorization: AgentLibraryAuthorization, at: Date) async throws -> MiraTask {
        try await owner.write(authorization: authorization) { db in
            let request = try Self.encode(TaskSaveRequest(id: id, workspaceID: workspaceID, draft: draft, status: status, expectedRevision: expectedRevision))
            if let receipt = try Self.taskOperation(operationID, request: request, in: db), let task = receipt.task { return task }
            let task = try Self.writeTask(id, workspaceID: workspaceID, draft: draft, status: status, expectedRevision: expectedRevision, evidence: nil, actor: "user", at: at, in: db)
            try Self.insertTaskOperation(operationID, request: request, receipt: .init(task: task), in: db)
            return task
        }
    }

    public func taskProposals(workspaceID: WorkspaceID?) async throws -> [TaskProposal] {
        try await owner.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM task_proposals WHERE workspace_id IS ? AND state = 'pending' ORDER BY rowid DESC LIMIT 100", arguments: [workspaceID.map(Self.id)]).map(Self.proposalRecord)
        }
    }

    public func resolveTaskProposal(_ id: UUID, workspaceID: WorkspaceID?, accept: Bool, correctedDraft: TaskDraft?, source: SessionUserEvidence?, authorization: AgentLibraryAuthorization, at: Date) async throws -> TaskWriteReceipt {
        try await owner.write(authorization: authorization) { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM task_proposals WHERE id = ? AND workspace_id IS ?", arguments: [id.uuidString.lowercased(), workspaceID.map(Self.id)]) else { throw Self.taskUnavailable }
            var proposal = try Self.proposalRecord(row)
            guard proposal.state == .pending else { throw MiraError(.conflict, "This task proposal has already been reviewed.") }
            if !accept {
                proposal.state = .rejected
                try Self.writeTaskProposal(proposal, in: db)
                return .init(proposal: proposal)
            }
            guard let source, source.workspaceID == workspaceID, TaskEvidence(source) == proposal.evidence else { throw Self.taskUnauthorized }
            try proposal.evidence.validate()
            let draft = correctedDraft ?? proposal.draft
            if proposal.requiresTimeClarification {
                guard correctedDraft != nil, draft.reminderAt != nil else { throw MiraError(.invalidInput, "Choose an exact reminder time before accepting this proposal.") }
            }
            let task = try Self.applyTaskProposal(proposal, draft: draft, actor: "user", at: at, in: db)
            proposal.state = .accepted
            try Self.writeTaskProposal(proposal, in: db)
            return .init(task: task, proposal: proposal)
        }
    }

    public func reminderWork(limit: Int) async throws -> [MiraTask] {
        try await owner.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM mira_tasks WHERE delivery_revision IS NOT revision OR delivery_state IN ('pending','scheduled','permissionRequired','failed') ORDER BY (reminder_at IS NULL), reminder_at, id LIMIT ?", arguments: [max(1, min(limit, 1_000))]).map(Self.taskRecord)
        }
    }

    public func reminderTaskExists(_ id: MiraTaskID) async throws -> Bool {
        try await owner.read { db in
            try Int.fetchOne(db, sql: "SELECT 1 FROM mira_tasks WHERE id = ?", arguments: [Self.id(id)]) != nil
        }
    }

    public func setReminderDelivery(_ id: MiraTaskID, expectedRevision: Int, state: ReminderDeliveryState, error: MiraError?, authorization: AgentLibraryAuthorization, at: Date) async throws -> Bool {
        try await owner.write(authorization: authorization) { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM mira_tasks WHERE id = ?", arguments: [Self.id(id)]) else { return false }
            var task = try Self.taskRecord(row)
            guard task.revision == expectedRevision else { return false }
            if state == .scheduled { guard !task.status.isTerminal, task.draft.reminderAt != nil, task.deliveryState != .paused else { return false } }
            task.deliveryState = state; task.deliveryRevision = expectedRevision; task.deliveryError = error
            try Self.updateTaskRow(task, in: db)
            return true
        }
    }

    public func resumeReminder(_ id: MiraTaskID, workspaceID: WorkspaceID?, expectedRevision: Int, authorization: AgentLibraryAuthorization, at: Date) async throws {
        try await owner.write(authorization: authorization) { db in
            var task = try Self.readTask(id, workspaceID: workspaceID, in: db)
            guard task.revision == expectedRevision else { throw Self.taskConflict }
            guard !task.status.isTerminal, let fireAt = task.draft.reminderAt, fireAt > at else { throw MiraError(.invalidInput, "Choose a future reminder time before scheduling.") }
            task.deliveryState = .pending; task.deliveryRevision = nil; task.deliveryError = nil
            try Self.updateTaskRow(task, in: db)
        }
    }

    static func pauseRestoredReminders(in db: Database) throws {
        try SQLiteArchiveValidation.rows(in: db, table: "mira_tasks") { row in
            var task = try taskRecord(row)
            guard task.draft.reminderAt != nil, !task.status.isTerminal else { return }
            task.deliveryState = .paused; task.deliveryRevision = nil; task.deliveryError = nil
            try updateTaskRow(task, in: db)
        }
    }

    private struct TaskSaveRequest: Codable {
        var id: MiraTaskID; var workspaceID: WorkspaceID?; var draft: TaskDraft; var status: MiraTaskStatus; var expectedRevision: Int?
    }

    static func writeTask(_ id: MiraTaskID, workspaceID: WorkspaceID?, draft: TaskDraft, status: MiraTaskStatus, expectedRevision: Int?, evidence: TaskEvidence?, actor: String, at: Date, in db: Database) throws -> MiraTask {
        try draft.validate()
        try evidence?.validate()
        guard at.timeIntervalSince1970.isFinite else { throw taskConflict }
        try SQLiteWorkspaceStore.validatePolicy(workspaceID, connectionID: nil, in: db)
        let existing = try Row.fetchOne(db, sql: "SELECT * FROM mira_tasks WHERE id = ?", arguments: [Self.id(id)]).map(taskRecord)
        if let existing { guard existing.workspaceID == workspaceID, existing.revision == expectedRevision, existing.revision < 1_000_000, at >= existing.updatedAt else { throw taskConflict } }
        else { guard expectedRevision == nil, status == .open else { throw taskConflict } }
        if let reminderAt = draft.reminderAt, !status.isTerminal {
            guard reminderAt > at else { throw MiraError(.invalidInput, "Choose a future reminder time before scheduling.") }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mira_tasks WHERE id != ? AND reminder_at > ? AND status IN ('open','inProgress')", arguments: [Self.id(id), at.timeIntervalSince1970]) ?? 0
            guard count < 60 else { throw MiraError(.outputLimit, "At most 60 future reminders can be active. Complete or cancel a reminder first.") }
        }
        var task = MiraTask(id: id, workspaceID: workspaceID, draft: draft, status: status, revision: (existing?.revision ?? 0) + 1, createdAt: existing?.createdAt ?? at, updatedAt: at, evidence: evidence ?? existing?.evidence)
        if let existing, existing.draft == draft, existing.status == status { return existing }
        if existing == nil {
            try db.execute(sql: "INSERT INTO mira_tasks (id, workspace_id, status, revision, reminder_at, delivery_state, delivery_revision, updated_at, task_json) VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?)", arguments: [Self.id(id), workspaceID.map(Self.id), task.status.rawValue, task.revision, task.draft.reminderAt?.timeIntervalSince1970, task.deliveryState.rawValue, at.timeIntervalSince1970, try encode(task)])
        } else {
            // A revision invalidates the system observation even when the trigger is unchanged.
            task.deliveryRevision = nil
            try updateTaskRow(task, in: db)
        }
        let operation = existing == nil ? "created" : (status != existing?.status ? status.rawValue : "updated")
        let revision = TaskRevision(task: task, operation: operation, actor: actor, changedAt: at)
        try db.execute(sql: "INSERT INTO task_revisions (id, task_id, revision, revision_json) VALUES (?, ?, ?, ?)", arguments: [revision.id.uuidString.lowercased(), Self.id(task.id), task.revision, try encode(revision)])
        return task
    }

    static func applyTaskProposal(_ proposal: TaskProposal, draft: TaskDraft, actor: String, at: Date, in db: Database) throws -> MiraTask {
        let id = proposal.taskID ?? MiraTaskID(proposal.id)
        let current = try proposal.taskID.map { try readTask($0, workspaceID: proposal.workspaceID, in: db) }
        let status: MiraTaskStatus
        switch proposal.operation {
        case .create: status = .open
        case .update: status = current?.status ?? .open
        case .complete: status = .completed
        case .cancel: status = .cancelled
        }
        return try writeTask(id, workspaceID: proposal.workspaceID, draft: draft, status: status, expectedRevision: proposal.expectedRevision, evidence: proposal.evidence, actor: actor, at: at, in: db)
    }

    static func updateTaskRow(_ task: MiraTask, in db: Database) throws {
        try db.execute(sql: "UPDATE mira_tasks SET status = ?, revision = ?, reminder_at = ?, delivery_state = ?, delivery_revision = ?, updated_at = ?, task_json = ? WHERE id = ?", arguments: [task.status.rawValue, task.revision, task.draft.reminderAt?.timeIntervalSince1970, task.deliveryState.rawValue, task.deliveryRevision, task.updatedAt.timeIntervalSince1970, try encode(task), Self.id(task.id)])
    }

    static func readTask(_ id: MiraTaskID, workspaceID: WorkspaceID?, in db: Database) throws -> MiraTask {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM mira_tasks WHERE id = ? AND workspace_id IS ?", arguments: [Self.id(id), workspaceID.map(Self.id)]) else { throw taskUnavailable }
        return try taskRecord(row)
    }

    static func taskRecord(_ row: Row) throws -> MiraTask {
        let task: MiraTask = try decode(row["task_json"] as String)
        try task.draft.validate()
        try task.evidence?.validate()
        guard Self.id(task.id) == row["id"] as String, task.workspaceID.map(Self.id) == row["workspace_id"] as String?,
              task.status.rawValue == row["status"] as String, task.revision == row["revision"] as Int,
              taskTimestampMatches(task.draft.reminderAt, row["reminder_at"] as Double?),
              taskTimestampMatches(task.updatedAt, row["updated_at"] as Double?),
              task.deliveryState.rawValue == row["delivery_state"] as String, task.deliveryRevision == row["delivery_revision"] as Int?,
              task.revision > 0, task.revision <= 1_000_000, task.createdAt.timeIntervalSince1970.isFinite,
              task.createdAt <= task.updatedAt,
              (task.status == .completed) == (task.completedAt != nil),
              task.deliveryRevision == nil || task.deliveryRevision == task.revision,
              task.deliveryState != .scheduled || (!task.status.isTerminal && task.draft.reminderAt != nil && task.deliveryRevision == task.revision) else {
            throw MiraError(.storage, "The task record is inconsistent.")
        }
        return task
    }

    /// Millisecond JSON and SQLite seconds can differ by a floating-point ULP.
    /// Allow only that representation rounding, not a changed reminder time.
    static func taskTimestampMatches(_ date: Date?, _ stored: Double?) -> Bool {
        guard let date, let stored else { return date == nil && stored == nil }
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, stored.isFinite else { return false }
        return abs(seconds - stored) <= max(seconds.ulp, stored.ulp) * 4
    }

    static func writeTaskProposal(_ proposal: TaskProposal, in db: Database) throws {
        try db.execute(sql: "INSERT INTO task_proposals (id, workspace_id, state, proposal_json) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET state = excluded.state, proposal_json = excluded.proposal_json", arguments: [proposal.id.uuidString.lowercased(), proposal.workspaceID.map(Self.id), proposal.state.rawValue, try encode(proposal)])
    }

    static func taskOperation(_ id: UUID, request: String, in db: Database) throws -> TaskWriteReceipt? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM task_operations WHERE id = ?", arguments: [id.uuidString.lowercased()]) else { return nil }
        guard row["request_json"] as String == request else { throw MiraError(.conflict, "This task operation identifier was already used for another change.") }
        return try validateTaskOperation(row, in: db)
    }

    static func insertTaskOperation(_ id: UUID, request: String, receipt: TaskWriteReceipt, in db: Database) throws {
        try db.execute(sql: "INSERT INTO task_operations (id, business_key, request_json, receipt_json) VALUES (?, ?, ?, ?)", arguments: [id.uuidString.lowercased(), "ui:" + id.uuidString.lowercased(), request, try encode(receipt)])
    }

    static func proposalRecord(_ row: Row) throws -> TaskProposal {
        let proposal: TaskProposal = try decode(row["proposal_json"])
        try proposal.draft.validate(); try proposal.evidence.validate()
        guard proposal.id.uuidString.lowercased() == row["id"] as String,
              proposal.state.rawValue == row["state"] as String,
              proposal.workspaceID.map(Self.id) == row["workspace_id"] as String?,
              proposal.createdAt.timeIntervalSince1970.isFinite,
              proposal.operation == .create ? (proposal.taskID == nil && proposal.expectedRevision == nil)
                  : (proposal.taskID != nil && (1...1_000_000).contains(proposal.expectedRevision ?? 0)) else { throw taskConflict }
        return proposal
    }

    static func revisionRecord(_ row: Row) throws -> TaskRevision {
        let revision: TaskRevision = try decode(row["revision_json"])
        try revision.task.draft.validate(); try revision.task.evidence?.validate()
        guard revision.id.uuidString.lowercased() == row["id"] as String,
              Self.id(revision.task.id) == row["task_id"] as String,
              revision.task.revision == row["revision"] as Int,
              (1...1_000_000).contains(revision.task.revision),
              revision.changedAt == revision.task.updatedAt,
              revision.changedAt.timeIntervalSince1970.isFinite,
              revision.task.createdAt.timeIntervalSince1970.isFinite,
              revision.task.createdAt <= revision.changedAt else { throw taskConflict }
        return revision
    }

    static func validateTaskContents(in db: Database) throws {
        for row in try Row.fetchAll(db, sql: "SELECT * FROM mira_tasks") {
            let task = try taskRecord(row)
            try task.evidence?.validate()
            guard let latest = try String.fetchOne(db, sql: "SELECT revision_json FROM task_revisions WHERE task_id = ? AND revision = ?", arguments: [Self.id(task.id), task.revision]) else { throw taskUnavailable }
            let revision: TaskRevision = try decode(latest)
            guard revision.task.id == task.id, revision.task.draft == task.draft, revision.task.status == task.status else { throw taskConflict }
        }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM task_revisions") { _ = try revisionRecord(row) }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM task_proposals") { _ = try proposalRecord(row) }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM task_operations") { _ = try validateTaskOperation(row, in: db) }
    }


    static func validateTaskOperation(_ row: Row, in db: Database) throws -> TaskWriteReceipt {
        guard let operationID = UUID(uuidString: row["id"] as String), operationID.uuidString.lowercased() == row["id"] as String else { throw taskConflict }
        let request = row["request_json"] as String
        let receipt: TaskWriteReceipt = try decode(row["receipt_json"])
        guard (receipt.task == nil) != (receipt.proposal == nil) else { throw taskConflict }
        if let task = receipt.task {
            let current = try readTask(task.id, workspaceID: task.workspaceID, in: db)
            guard task.revision <= current.revision,
                  let revisionJSON = try String.fetchOne(db, sql: "SELECT revision_json FROM task_revisions WHERE task_id = ? AND revision = ?", arguments: [Self.id(task.id), task.revision]) else { throw taskConflict }
            let revision: TaskRevision = try decode(revisionJSON)
            var businessSnapshot = task
            businessSnapshot.deliveryState = revision.task.deliveryState
            businessSnapshot.deliveryRevision = revision.task.deliveryRevision
            businessSnapshot.deliveryError = revision.task.deliveryError
            guard businessSnapshot == revision.task else { throw taskConflict }
            let save: TaskSaveRequest = try decode(request)
            try save.draft.validate()
            guard row["business_key"] as String == "ui:" + operationID.uuidString.lowercased(),
                  save.id == task.id, save.workspaceID == task.workspaceID,
                  save.draft == task.draft, save.status == task.status else { throw taskConflict }
        } else { throw taskConflict }
        return receipt
    }

    static func id<Tag>(_ value: EntityID<Tag>) -> String { value.rawValue.uuidString.lowercased() }
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let bytes = try SessionCodec.encode(value)
        guard bytes.count <= 131_072, let text = String(data: bytes, encoding: .utf8) else { throw taskConflict }
        return text
    }
    static func decode<T: Decodable>(_ text: String) throws -> T {
        guard text.utf8.count <= 131_072 else { throw taskConflict }
        return try SessionCodec.decode(T.self, from: Data(text.utf8))
    }

    static var taskUnavailable: MiraError { .init(.notFound, "The task or proposal is unavailable in this workspace.") }
    static var taskConflict: MiraError { .init(.conflict, "The task changed in another window. Refresh before saving.") }
    static var taskUnauthorized: MiraError { .init(.unauthorized, "The task source or tool request is no longer authorized.") }
}
