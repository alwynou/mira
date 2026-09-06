import Foundation
import CryptoKit
import GRDB
import MiraCore

extension SQLiteMiraStore {
    static let taskTableNames: Set<String> = ["mira_tasks", "task_revisions", "task_proposals", "task_operations", "message_time_context"]

    static func createTaskSchema(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE message_time_context (
          message_id TEXT PRIMARY KEY NOT NULL REFERENCES messages(id), time_zone TEXT NOT NULL
        );
        CREATE TABLE mira_tasks (
          id TEXT PRIMARY KEY NOT NULL,
          workspace_id TEXT REFERENCES workspaces(id),
          status TEXT NOT NULL CHECK(status IN ('open','inProgress','completed','cancelled')),
          revision INTEGER NOT NULL CHECK(revision > 0),
          reminder_at REAL,
          delivery_state TEXT NOT NULL CHECK(delivery_state IN ('none','pending','scheduled','permissionRequired','failed','elapsed','paused','cancelled')),
          delivery_revision INTEGER CHECK(delivery_revision > 0),
          updated_at REAL NOT NULL,
          source_message_id TEXT REFERENCES messages(id),
          task_json TEXT NOT NULL
        );
        CREATE INDEX mira_tasks_scope ON mira_tasks(workspace_id, status, updated_at);
        CREATE INDEX mira_tasks_delivery ON mira_tasks(delivery_state, reminder_at);
        CREATE TABLE task_revisions (
          id TEXT PRIMARY KEY NOT NULL, task_id TEXT NOT NULL REFERENCES mira_tasks(id),
          revision INTEGER NOT NULL CHECK(revision > 0), revision_json TEXT NOT NULL,
          UNIQUE(task_id, revision)
        );
        CREATE TABLE task_proposals (
          id TEXT PRIMARY KEY NOT NULL, workspace_id TEXT REFERENCES workspaces(id),
          source_message_id TEXT NOT NULL REFERENCES messages(id),
          state TEXT NOT NULL CHECK(state IN ('pending','accepted','rejected')),
          proposal_json TEXT NOT NULL
        );
        CREATE INDEX task_proposals_scope ON task_proposals(workspace_id, state);
        CREATE TABLE task_operations (
          id TEXT PRIMARY KEY NOT NULL, business_key TEXT NOT NULL UNIQUE, request_json TEXT NOT NULL, receipt_json TEXT NOT NULL
        );
        """)
    }

    public func taskList(workspaceID: WorkspaceID?, includeCompleted: Bool, limit: Int) throws -> [MiraTask] {
        try safely { try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM mira_tasks WHERE workspace_id IS ? AND (? OR status IN ('open','inProgress')) ORDER BY (reminder_at IS NULL), reminder_at, updated_at DESC, id LIMIT ?", arguments: [workspaceID.map(Self.id), includeCompleted, max(1, min(limit, 200))]).map(Self.taskRecord)
        }}
    }

    public func taskDetail(_ id: MiraTaskID, workspaceID: WorkspaceID?) throws -> MiraTask {
        try safely { try pool.read { try Self.readTask(id, workspaceID: workspaceID, in: $0) } }
    }

    public func taskRevisions(_ id: MiraTaskID, workspaceID: WorkspaceID?) throws -> [TaskRevision] {
        try safely { try pool.read { db in
            _ = try Self.readTask(id, workspaceID: workspaceID, in: db)
            return try String.fetchAll(db, sql: "SELECT revision_json FROM task_revisions WHERE task_id = ? ORDER BY revision DESC LIMIT 100", arguments: [Self.id(id)]).map { try Self.decode($0) }
        }}
    }

    public func saveTask(_ id: MiraTaskID, workspaceID: WorkspaceID?, draft: TaskDraft, status: MiraTaskStatus, expectedRevision: Int?, operationID: UUID, at: Date) throws -> MiraTask {
        try safely { try pool.write { db in
            let request = try Self.encode(TaskSaveRequest(id: id, workspaceID: workspaceID, draft: draft, status: status, expectedRevision: expectedRevision))
            if let receipt = try Self.taskOperation(operationID, request: request, in: db), let task = receipt.task { return task }
            let task = try Self.writeTask(id, workspaceID: workspaceID, draft: draft, status: status, expectedRevision: expectedRevision, evidence: nil, actor: "user", at: at, in: db)
            try Self.insertTaskOperation(operationID, request: request, receipt: .init(task: task), in: db)
            return task
        }}
    }

    public func taskProposals(workspaceID: WorkspaceID?) throws -> [TaskProposal] {
        try safely { try pool.read { db in
            try String.fetchAll(db, sql: "SELECT proposal_json FROM task_proposals WHERE workspace_id IS ? AND state = 'pending' ORDER BY rowid DESC LIMIT 100", arguments: [workspaceID.map(Self.id)]).map { try Self.decode($0) }
        }}
    }

    public func resolveTaskProposal(_ id: UUID, workspaceID: WorkspaceID?, accept: Bool, correctedDraft: TaskDraft?, at: Date) throws -> TaskWriteReceipt {
        try safely { try pool.write { db in
            guard let raw = try String.fetchOne(db, sql: "SELECT proposal_json FROM task_proposals WHERE id = ? AND workspace_id IS ?", arguments: [id.uuidString.lowercased(), workspaceID.map(Self.id)]) else { throw Self.taskUnavailable }
            var proposal: TaskProposal = try Self.decode(raw)
            guard proposal.state == .pending else { throw MiraError(.conflict, "This task proposal has already been reviewed.") }
            if !accept {
                proposal.state = .rejected
                try Self.writeTaskProposal(proposal, in: db)
                return .init(proposal: proposal)
            }
            try Self.validateTaskEvidence(proposal.evidence, workspaceID: workspaceID, in: db)
            let draft = correctedDraft ?? proposal.draft
            if proposal.requiresTimeClarification {
                guard correctedDraft != nil, draft.reminderAt != nil else { throw MiraError(.invalidInput, "Choose an exact reminder time before accepting this proposal.") }
            }
            let task = try Self.applyTaskProposal(proposal, draft: draft, actor: "user", at: at, in: db)
            proposal.state = .accepted
            try Self.writeTaskProposal(proposal, in: db)
            return .init(task: task, proposal: proposal)
        }}
    }

    public func taskToolReference(context: ToolContext) throws -> TaskEvidence {
        try safely { try pool.read { try Self.taskToolEvidence(context: context, requireDispatched: false, in: $0) } }
    }

    public func performTaskTool(arguments: JSONValue, context: ToolContext, at: Date) throws -> TaskWriteReceipt {
        try safely { try pool.write { db in
            let normalized = try ToolSchemaValidator.decode(try arguments.jsonString(), schema: TaskTools.mutationDefinition.inputSchema)
            let request = try normalized.jsonString()
            let replay = try Self.taskOperation(context.invocationID, request: request, in: db)
            let businessKey = Self.taskBusinessKey(messageID: context.userMessageID, request: request)
            let prior = try String.fetchOne(db, sql: "SELECT receipt_json FROM task_operations WHERE business_key = ?", arguments: [businessKey])
            // A second durable invocation may share the source command's receipt. Revalidate
            // its authorization and exact arguments before returning that committed result.
            let evidence = try Self.taskToolEvidence(context: context, requireDispatched: true, allowCompletedInvocation: replay != nil || prior != nil, in: db)
            guard let row = try Row.fetchOne(db, sql: "SELECT tool_name, arguments_json FROM tool_invocations WHERE id = ?", arguments: [context.invocationID.uuidString.lowercased()]),
                  row["tool_name"] as String == "task.change",
                  try ToolSchemaValidator.decode(row["arguments_json"] as String, schema: TaskTools.mutationDefinition.inputSchema) == normalized,
                  arguments["quote"]?.stringValue == evidence.quote else { throw Self.taskUnauthorized }
            if let replay { return replay }
            if let prior { return try Self.decode(prior) }
            var proposal = try TaskCommandInterpreter.proposal(arguments: normalized, reference: evidence, workspaceID: context.workspaceID, operationID: context.invocationID, at: at)
            let current = try proposal.taskID.map { try Self.readTask($0, workspaceID: context.workspaceID, in: db) }
            if let current, current.revision != proposal.expectedRevision { throw Self.taskConflict }
            if let current, proposal.operation == .complete || proposal.operation == .cancel { proposal.draft = current.draft }
            let direct = TaskCommandInterpreter.canCommitDirectly(proposal, current: current, arguments: normalized) && !proposal.requiresTimeClarification && ([TaskOperation.complete, .cancel].contains(proposal.operation) || (proposal.draft.reminderAt.map { $0 > at } ?? true))
            let receipt: TaskWriteReceipt
            if direct {
                let task = try Self.applyTaskProposal(proposal, draft: proposal.draft, actor: "agent", at: at, in: db)
                receipt = .init(task: task)
            } else {
                let pendingCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_proposals WHERE state = 'pending'") ?? 0
                guard pendingCount < 100 else { throw MiraError(.outputLimit, "Review pending task proposals before creating more.") }
                try Self.writeTaskProposal(proposal, in: db)
                receipt = .init(proposal: proposal)
            }
            try Self.insertTaskOperation(context.invocationID, businessKey: businessKey, request: request, receipt: receipt, in: db)
            return receipt
        }}
    }

    public func reminderWork(limit: Int) throws -> [MiraTask] {
        try safely { try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM mira_tasks WHERE delivery_revision IS NOT revision OR delivery_state IN ('pending','scheduled','permissionRequired','failed') ORDER BY (reminder_at IS NULL), reminder_at, id LIMIT ?", arguments: [max(1, min(limit, 1_000))]).map(Self.taskRecord)
        }}
    }

    public func reminderTaskExists(_ id: MiraTaskID) throws -> Bool {
        try safely { try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT 1 FROM mira_tasks WHERE id = ?", arguments: [Self.id(id)]) != nil
        }}
    }

    public func setReminderDelivery(_ id: MiraTaskID, expectedRevision: Int, state: ReminderDeliveryState, error: MiraError?, at: Date) throws -> Bool {
        try safely { try pool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM mira_tasks WHERE id = ?", arguments: [Self.id(id)]) else { return false }
            var task = try Self.taskRecord(row)
            guard task.revision == expectedRevision else { return false }
            if state == .scheduled { guard !task.status.isTerminal, task.draft.reminderAt != nil, task.deliveryState != .paused else { return false } }
            task.deliveryState = state; task.deliveryRevision = expectedRevision; task.deliveryError = error
            try Self.updateTaskRow(task, in: db)
            return true
        }}
    }

    public func resumeReminder(_ id: MiraTaskID, workspaceID: WorkspaceID?, expectedRevision: Int, at: Date) throws {
        try safely { try pool.write { db in
            var task = try Self.readTask(id, workspaceID: workspaceID, in: db)
            guard task.revision == expectedRevision else { throw Self.taskConflict }
            guard !task.status.isTerminal, let fireAt = task.draft.reminderAt, fireAt > at else { throw MiraError(.invalidInput, "Choose a future reminder time before scheduling.") }
            task.deliveryState = .pending; task.deliveryRevision = nil; task.deliveryError = nil
            try Self.updateTaskRow(task, in: db)
        }}
    }

    static func pauseRestoredReminders(in db: Database) throws {
        for row in try Row.fetchAll(db, sql: "SELECT * FROM mira_tasks WHERE reminder_at IS NOT NULL AND status IN ('open','inProgress')") {
            var task = try taskRecord(row)
            task.deliveryState = .paused; task.deliveryRevision = nil; task.deliveryError = nil
            try updateTaskRow(task, in: db)
        }
    }

    private struct TaskSaveRequest: Codable {
        var id: MiraTaskID; var workspaceID: WorkspaceID?; var draft: TaskDraft; var status: MiraTaskStatus; var expectedRevision: Int?
    }

    private static func writeTask(_ id: MiraTaskID, workspaceID: WorkspaceID?, draft: TaskDraft, status: MiraTaskStatus, expectedRevision: Int?, evidence: TaskEvidence?, actor: String, at: Date, in db: Database) throws -> MiraTask {
        try draft.validate()
        if let workspaceID { guard try Int.fetchOne(db, sql: "SELECT 1 FROM workspaces WHERE id = ?", arguments: [Self.id(workspaceID)]) != nil else { throw taskUnavailable } }
        let existing = try Row.fetchOne(db, sql: "SELECT * FROM mira_tasks WHERE id = ?", arguments: [Self.id(id)]).map(taskRecord)
        if let existing { guard existing.workspaceID == workspaceID, existing.revision == expectedRevision, existing.revision < 1_000_000 else { throw taskConflict } }
        else { guard expectedRevision == nil, status == .open else { throw taskConflict } }
        if let reminderAt = draft.reminderAt, !status.isTerminal {
            guard reminderAt > at else { throw MiraError(.invalidInput, "Choose a future reminder time before scheduling.") }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mira_tasks WHERE id != ? AND reminder_at > ? AND status IN ('open','inProgress')", arguments: [Self.id(id), at.timeIntervalSince1970]) ?? 0
            guard count < 60 else { throw MiraError(.outputLimit, "At most 60 future reminders can be active. Complete or cancel a reminder first.") }
        }
        var task = MiraTask(id: id, workspaceID: workspaceID, draft: draft, status: status, revision: (existing?.revision ?? 0) + 1, createdAt: existing?.createdAt ?? at, updatedAt: at, evidence: evidence ?? existing?.evidence)
        if let existing, existing.draft == draft, existing.status == status { return existing }
        if existing == nil {
            try db.execute(sql: "INSERT INTO mira_tasks (id, workspace_id, status, revision, reminder_at, delivery_state, delivery_revision, updated_at, source_message_id, task_json) VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, ?)", arguments: [Self.id(id), workspaceID.map(Self.id), task.status.rawValue, task.revision, task.draft.reminderAt?.timeIntervalSince1970, task.deliveryState.rawValue, at.timeIntervalSince1970, task.evidence.map { Self.id($0.messageID) }, try encode(task)])
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

    private static func applyTaskProposal(_ proposal: TaskProposal, draft: TaskDraft, actor: String, at: Date, in db: Database) throws -> MiraTask {
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

    private static func updateTaskRow(_ task: MiraTask, in db: Database) throws {
        try db.execute(sql: "UPDATE mira_tasks SET status = ?, revision = ?, reminder_at = ?, delivery_state = ?, delivery_revision = ?, updated_at = ?, source_message_id = ?, task_json = ? WHERE id = ?", arguments: [task.status.rawValue, task.revision, task.draft.reminderAt?.timeIntervalSince1970, task.deliveryState.rawValue, task.deliveryRevision, task.updatedAt.timeIntervalSince1970, task.evidence.map { Self.id($0.messageID) }, try encode(task), Self.id(task.id)])
    }

    private static func readTask(_ id: MiraTaskID, workspaceID: WorkspaceID?, in db: Database) throws -> MiraTask {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM mira_tasks WHERE id = ? AND workspace_id IS ?", arguments: [Self.id(id), workspaceID.map(Self.id)]) else { throw taskUnavailable }
        return try taskRecord(row)
    }

    private static func taskRecord(_ row: Row) throws -> MiraTask {
        let task: MiraTask = try decode(row["task_json"] as String)
        try task.draft.validate()
        guard Self.id(task.id) == row["id"] as String, task.workspaceID.map(Self.id) == row["workspace_id"] as String?,
              task.status.rawValue == row["status"] as String, task.revision == row["revision"] as Int,
              taskTimestampMatches(task.draft.reminderAt, row["reminder_at"] as Double?),
              taskTimestampMatches(task.updatedAt, row["updated_at"] as Double?),
              task.deliveryState.rawValue == row["delivery_state"] as String, task.deliveryRevision == row["delivery_revision"] as Int?,
              task.evidence.map({ Self.id($0.messageID) }) == row["source_message_id"] as String?,
              task.revision > 0, task.createdAt <= task.updatedAt,
              (task.status == .completed) == (task.completedAt != nil),
              task.deliveryRevision == nil || task.deliveryRevision == task.revision,
              task.deliveryState != .scheduled || (!task.status.isTerminal && task.draft.reminderAt != nil && task.deliveryRevision == task.revision) else {
            throw MiraError(.storage, "The task record is inconsistent.")
        }
        return task
    }

    /// Millisecond JSON and SQLite seconds can differ by a floating-point ULP.
    /// Allow only that representation rounding, not a changed reminder time.
    private static func taskTimestampMatches(_ date: Date?, _ stored: Double?) -> Bool {
        guard let date, let stored else { return date == nil && stored == nil }
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, stored.isFinite else { return false }
        return abs(seconds - stored) <= max(seconds.ulp, stored.ulp) * 4
    }

    private static func writeTaskProposal(_ proposal: TaskProposal, in db: Database) throws {
        try db.execute(sql: "INSERT INTO task_proposals (id, workspace_id, source_message_id, state, proposal_json) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET state = excluded.state, proposal_json = excluded.proposal_json", arguments: [proposal.id.uuidString.lowercased(), proposal.workspaceID.map(Self.id), Self.id(proposal.evidence.messageID), proposal.state.rawValue, try encode(proposal)])
    }

    private static func taskOperation(_ id: UUID, request: String, in db: Database) throws -> TaskWriteReceipt? {
        guard let row = try Row.fetchOne(db, sql: "SELECT request_json, receipt_json FROM task_operations WHERE id = ?", arguments: [id.uuidString.lowercased()]) else { return nil }
        guard row["request_json"] as String == request else { throw MiraError(.conflict, "This task operation identifier was already used for another change.") }
        return try decode(row["receipt_json"] as String)
    }

    private static func insertTaskOperation(_ id: UUID, businessKey: String? = nil, request: String, receipt: TaskWriteReceipt, in db: Database) throws {
        try db.execute(sql: "INSERT INTO task_operations (id, business_key, request_json, receipt_json) VALUES (?, ?, ?, ?)", arguments: [id.uuidString.lowercased(), businessKey ?? "ui:" + id.uuidString.lowercased(), request, try encode(receipt)])
    }

    private static func taskToolEvidence(context: ToolContext, requireDispatched: Bool, allowCompletedInvocation: Bool = false, in db: Database) throws -> TaskEvidence {
        guard let row = try Row.fetchOne(db, sql: """
        SELECT e.trigger_message_id, e.conversation_id, e.status, e.route_json, e.body_purged_at,
               c.workspace_id, c.is_archived, m.text, m.created_at, m.body_purged_at AS message_purged,
               t.time_zone, i.dispatched_at, i.completed_at, i.body_purged_at AS invocation_purged, i.tool_name
        FROM executions e JOIN conversations c ON c.id = e.conversation_id
        JOIN messages m ON m.id = e.trigger_message_id AND m.role = 'user' AND m.status = 'committed'
        JOIN message_time_context t ON t.message_id = m.id
        JOIN model_attempts a ON a.execution_id = e.id
        JOIN tool_invocations i ON i.attempt_id = a.id AND i.id = ?
        WHERE e.id = ?
        """, arguments: [context.invocationID.uuidString.lowercased(), Self.id(context.executionID)]),
              (allowCompletedInvocation ? ["queued", "waitingForModel", "completed"] : ["queued", "waitingForModel"]).contains(row["status"] as String), row["body_purged_at"] as Double? == nil,
              row["message_purged"] as Double? == nil, row["invocation_purged"] as Double? == nil,
              (allowCompletedInvocation || row["completed_at"] as Double? == nil), row["is_archived"] as Int == 0,
              row["trigger_message_id"] as String == Self.id(context.userMessageID), row["text"] as String == context.userText,
              row["workspace_id"] as String? == context.workspaceID.map(Self.id),
              ["task.list", "task.change"].contains(row["tool_name"] as String),
              !requireDispatched || row["dispatched_at"] as Double? != nil else { throw taskUnauthorized }
        let route: ResolvedModelRouteSnapshot = try decode(row["route_json"] as String)
        if let workspaceID = context.workspaceID {
            guard let workspaceRow = try Row.fetchOne(db, sql: "SELECT id, name, background, allows_remote_send, allowed_connection_ids_json, revision FROM workspaces WHERE id = ?", arguments: [Self.id(workspaceID)]) else { throw taskUnauthorized }
            let workspace = try workspace(workspaceRow)
            guard workspace.allowsRemoteSend, workspace.allowedConnectionIDs?.contains(route.connectionID) != false else { throw taskUnauthorized }
        }
        guard let conversationUUID = UUID(uuidString: row["conversation_id"] as String), TimeZone(identifier: row["time_zone"] as String) != nil else { throw taskUnauthorized }
        return .init(messageID: context.userMessageID, conversationID: .init(conversationUUID), quote: row["text"], sentAt: Date(timeIntervalSince1970: row["created_at"]), timeZoneID: row["time_zone"])
    }

    private static func validateTaskEvidence(_ evidence: TaskEvidence, workspaceID: WorkspaceID?, in db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT m.text, m.created_at, c.workspace_id, t.time_zone FROM messages m JOIN conversations c ON c.id = m.conversation_id JOIN message_time_context t ON t.message_id = m.id WHERE m.id = ? AND m.conversation_id = ? AND m.role = 'user' AND m.body_purged_at IS NULL", arguments: [Self.id(evidence.messageID), Self.id(evidence.conversationID)]),
              row["text"] as String == evidence.quote, row["workspace_id"] as String? == workspaceID.map(Self.id),
              row["time_zone"] as String == evidence.timeZoneID, taskTimestampMatches(evidence.sentAt, row["created_at"] as Double?) else { throw taskUnauthorized }
    }

    private static func taskBusinessKey(messageID: MessageID, request: String) -> String {
        let hash = SHA256.hash(data: Data(request.utf8)).map { String(format: "%02x", $0) }.joined()
        return "tool:" + Self.id(messageID) + ":" + hash
    }

    static func validateTaskContents(in db: Database) throws {
        for row in try Row.fetchAll(db, sql: "SELECT t.message_id, t.time_zone, m.role FROM message_time_context t JOIN messages m ON m.id = t.message_id") {
            guard row["role"] as String == "user", TimeZone(identifier: row["time_zone"] as String) != nil else { throw taskConflict }
        }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM mira_tasks") {
            let task = try taskRecord(row)
            if let evidence = task.evidence { try validateTaskEvidence(evidence, workspaceID: task.workspaceID, in: db) }
            guard let latest = try String.fetchOne(db, sql: "SELECT revision_json FROM task_revisions WHERE task_id = ? AND revision = ?", arguments: [Self.id(task.id), task.revision]) else { throw taskUnavailable }
            let revision: TaskRevision = try decode(latest)
            guard revision.task.id == task.id, revision.task.draft == task.draft, revision.task.status == task.status else { throw taskConflict }
        }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM task_revisions") {
            let revision: TaskRevision = try decode(row["revision_json"])
            try revision.task.draft.validate()
            guard revision.id.uuidString.lowercased() == row["id"] as String, Self.id(revision.task.id) == row["task_id"] as String, revision.task.revision == row["revision"] as Int else { throw taskConflict }
        }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM task_proposals") {
            let proposal: TaskProposal = try decode(row["proposal_json"])
            try proposal.draft.validate()
            guard proposal.id.uuidString.lowercased() == row["id"] as String, proposal.state.rawValue == row["state"] as String, proposal.workspaceID.map(Self.id) == row["workspace_id"] as String?, Self.id(proposal.evidence.messageID) == row["source_message_id"] as String else { throw taskConflict }
            try validateTaskEvidence(proposal.evidence, workspaceID: proposal.workspaceID, in: db)
        }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM task_operations") {
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
                if let save: TaskSaveRequest = try? decode(request) {
                    try save.draft.validate()
                    guard row["business_key"] as String == "ui:" + operationID.uuidString.lowercased() else { throw taskConflict }
                    guard save.id == task.id, save.workspaceID == task.workspaceID, save.draft == task.draft, save.status == task.status else { throw taskConflict }
                } else {
                    let arguments = try ToolSchemaValidator.decode(request, schema: TaskTools.mutationDefinition.inputSchema)
                    guard let evidence = task.evidence, evidence.quote == arguments["quote"]?.stringValue,
                          row["business_key"] as String == taskBusinessKey(messageID: evidence.messageID, request: request) else { throw taskConflict }
                }
            } else if let proposal = receipt.proposal {
                let arguments = try ToolSchemaValidator.decode(request, schema: TaskTools.mutationDefinition.inputSchema)
                guard row["business_key"] as String == taskBusinessKey(messageID: proposal.evidence.messageID, request: request),
                      proposal.id == operationID, proposal.evidence.quote == arguments["quote"]?.stringValue,
                      let canonicalJSON = try String.fetchOne(db, sql: "SELECT proposal_json FROM task_proposals WHERE id = ?", arguments: [operationID.uuidString.lowercased()]) else { throw taskConflict }
                var canonical: TaskProposal = try decode(canonicalJSON)
                canonical.state = .pending
                guard canonical == proposal else { throw taskConflict }
            }
        }
    }

    private static var taskUnavailable: MiraError { .init(.notFound, "The task or proposal is unavailable in this workspace.") }
    private static var taskConflict: MiraError { .init(.conflict, "The task changed in another window. Refresh before saving.") }
    private static var taskUnauthorized: MiraError { .init(.unauthorized, "The task source or tool request is no longer authorized.") }
}
