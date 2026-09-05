import Foundation
import GRDB
import MiraCore

/// The first on-disk implementation of `MiraStore`.
///
/// The store deliberately exposes synchronous operations.  Its owning application
/// actor is responsible for keeping these bounded operations off view tasks.
public final class SQLiteMiraStore: MiraStore, @unchecked Sendable {
    private static let currentSchemaVersion = 2
    private static let legacyMigrationName = "m0_core"
    private static let auditMigrationName = "m2_execution_audit"
    private let pool: DatabasePool

    public init(directory: URL) throws {
        do {
            try Self.createDirectoryIfNeeded(directory)
            let path = directory.appendingPathComponent("Mira.sqlite", isDirectory: false).path
            var configuration = Configuration()
            configuration.label = "Mira.SQLiteMiraStore"
            configuration.foreignKeysEnabled = true
            configuration.busyMode = .timeout(5)
            let pool = try DatabasePool(path: path, configuration: configuration)
            self.pool = pool
            let version = try pool.read { db in
                try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            }
            guard version <= Self.currentSchemaVersion else {
                throw MiraError(.unsupported, "资料库版本较新，无法在此版本打开。")
            }
            let migrator = Self.makeMigrator()
            try migrator.migrate(pool)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch let error as MiraError {
            throw error
        } catch {
            throw MiraError.safe(error)
        }
    }

    // MARK: - Workspace / conversation

    public func workspaces() throws -> [Workspace] {
        try safely { try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name, background, allows_remote_send, revision FROM workspaces ORDER BY name COLLATE NOCASE, id")
                .map { try Self.workspace($0) }
        }}
    }

    public func saveWorkspace(_ workspace: Workspace, expectedRevision: Int?) throws {
        try safely {
            guard workspace.revision > 0, !workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MiraError(.invalidInput, "工作区信息无效。")
            }
            try pool.write { db in
                if let current = try Int.fetchOne(db, sql: "SELECT revision FROM workspaces WHERE id = ?", arguments: [id(workspace.id)]) {
                    if let expectedRevision, current != expectedRevision {
                        throw MiraError(.conflict, "工作区已被其他窗口修改。")
                    }
                    guard expectedRevision == current, workspace.revision == current + 1 else { throw MiraError(.conflict, "工作区修订号已过期。") }
                    let next = current + 1
                    try db.execute(sql: "UPDATE workspaces SET name = ?, background = ?, allows_remote_send = ?, revision = ? WHERE id = ?", arguments: [workspace.name, workspace.background, workspace.allowsRemoteSend ? 1 : 0, next, id(workspace.id)])
                } else {
                    if expectedRevision != nil || workspace.revision != 1 {
                        throw MiraError(.conflict, "工作区已不存在。")
                    }
                    try db.execute(sql: "INSERT INTO workspaces (id, name, background, allows_remote_send, revision) VALUES (?, ?, ?, ?, ?)", arguments: [id(workspace.id), workspace.name, workspace.background, workspace.allowsRemoteSend ? 1 : 0, workspace.revision])
                }
            }
        }
    }

    public func conversations(includeArchived: Bool) throws -> [Conversation] {
        try safely { try pool.read { db in
            let sql = includeArchived
                ? "SELECT id, workspace_id, title, is_archived, created_at, updated_at, revision FROM conversations ORDER BY updated_at, id"
                : "SELECT id, workspace_id, title, is_archived, created_at, updated_at, revision FROM conversations WHERE is_archived = 0 ORDER BY updated_at, id"
            return try Row.fetchAll(db, sql: sql).map { try Self.conversation($0) }
        }}
    }

    public func createConversation(_ conversation: Conversation) throws {
        try safely {
            guard conversation.revision > 0, !conversation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MiraError(.invalidInput, "对话信息无效。")
            }
            try pool.write { db in
                if let workspaceID = conversation.workspaceID,
                   try Int.fetchOne(db, sql: "SELECT 1 FROM workspaces WHERE id = ?", arguments: [id(workspaceID)]) == nil {
                    throw MiraError(.notFound, "工作区不存在。")
                }
                try db.execute(sql: "INSERT INTO conversations (id, workspace_id, title, is_archived, created_at, updated_at, revision) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [id(conversation.id), conversation.workspaceID.map(id), conversation.title, conversation.isArchived ? 1 : 0, conversation.createdAt.timeIntervalSince1970, conversation.updatedAt.timeIntervalSince1970, conversation.revision])
            }
        }
    }

    public func archiveConversation(_ conversationID: ConversationID, at: Date) throws {
        try safely {
            try pool.write { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT revision, is_archived FROM conversations WHERE id = ?", arguments: [id(conversationID)]) else {
                    throw MiraError(.notFound, "对话不存在。")
                }
                if try Int.fetchOne(db, sql: "SELECT 1 FROM executions WHERE conversation_id = ? AND status IN ('queued', 'waitingForModel') LIMIT 1", arguments: [id(conversationID)]) != nil {
                    throw MiraError(.busy, "对话仍有执行正在进行。")
                }
                if row["is_archived"] as Int == 0 {
                    try db.execute(sql: "UPDATE conversations SET is_archived = 1, updated_at = ?, revision = ? WHERE id = ?", arguments: [at.timeIntervalSince1970, (row["revision"] as Int) + 1, id(conversationID)])
                }
            }
        }
    }

    public func messages(in conversationID: ConversationID) throws -> [Message] {
        try safely { try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, conversation_id, execution_id, sequence, role, status, text, created_at FROM messages WHERE conversation_id = ? ORDER BY sequence", arguments: [id(conversationID)]).map { try Self.message($0) }
        }}
    }

    public func executions(in conversationID: ConversationID) throws -> [Execution] {
        try safely { try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, conversation_id, trigger_message_id, retry_of_execution_id, status, route_json, usage_input, usage_output, error_json, created_at, updated_at FROM executions WHERE conversation_id = ? ORDER BY rowid", arguments: [id(conversationID)]).map { try Self.execution($0) }
        }}
    }

    public func draft(for executionID: ExecutionID) throws -> Draft? {
        try safely { try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT execution_id, text, updated_at FROM assistant_drafts WHERE execution_id = ?", arguments: [id(executionID)]) else { return nil }
            return Draft(executionID: try executionIDValue(row["execution_id"] as String), text: row["text"] as String, updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double))
        }}
    }

    // MARK: - Routes

    public func routes() throws -> [ModelRoute] {
        try safely { try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT route_json FROM routes ORDER BY name COLLATE NOCASE, id").map { try Self.decodeRoute($0["route_json"] as String) }
        }}
    }

    public func saveRoute(_ route: ModelRoute, expectedRevision: Int?) throws {
        try safely {
            guard route.revision > 0, !route.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !route.credentialReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MiraError(.invalidInput, "模型路线信息无效。")
            }
            let encoded = try encode(route)
            try pool.write { db in
                if let current = try Int.fetchOne(db, sql: "SELECT revision FROM routes WHERE id = ?", arguments: [id(route.id)]) {
                    guard expectedRevision == current, route.revision == current + 1 else { throw MiraError(.conflict, "模型路线修订号已过期。") }
                    let next = current + 1
                    try db.execute(sql: "UPDATE routes SET revision = ?, name = ?, route_json = ? WHERE id = ?", arguments: [next, route.name, encoded, id(route.id)])
                } else {
                    if expectedRevision != nil || route.revision != 1 { throw MiraError(.conflict, "模型路线已不存在。") }
                    try db.execute(sql: "INSERT INTO routes (id, revision, name, route_json) VALUES (?, ?, ?, ?)", arguments: [id(route.id), route.revision, route.name, encoded])
                }
            }
        }
    }

    public func removeRoute(_ routeID: RouteID) throws {
        try safely { try pool.write { db in
            try db.execute(sql: "DELETE FROM routes WHERE id = ?", arguments: [id(routeID)])
        }}
    }

    // MARK: - Runtime persistence

    public func enqueue(conversationID: ConversationID, text: String, route: ModelRoute, executionID: ExecutionID, messageID: MessageID, at: Date) throws -> Execution {
        try safely {
            guard !text.isEmpty else { throw MiraError(.invalidInput, "消息不能为空。") }
            return try pool.write { db in
                guard let conversation = try Row.fetchOne(db, sql: "SELECT is_archived FROM conversations WHERE id = ?", arguments: [id(conversationID)]) else { throw MiraError(.notFound, "对话不存在。") }
                guard conversation["is_archived"] as Int == 0 else { throw MiraError(.invalidInput, "归档对话不能发送消息。") }
                if try Int.fetchOne(db, sql: "SELECT 1 FROM executions WHERE conversation_id = ? AND status IN ('queued', 'waitingForModel') LIMIT 1", arguments: [id(conversationID)]) != nil {
                    throw MiraError(.busy, "此对话已有执行正在进行。")
                }
                let sequence = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence), 0) + 1 FROM messages WHERE conversation_id = ?", arguments: [id(conversationID)]) ?? 1)
                let execution = Execution(id: executionID, conversationID: conversationID, triggerMessageID: messageID, route: route, createdAt: at, updatedAt: at)
                try db.execute(sql: "INSERT INTO executions (id, conversation_id, trigger_message_id, retry_of_execution_id, status, route_json, usage_input, usage_output, error_json, created_at, updated_at) VALUES (?, ?, ?, NULL, 'queued', ?, NULL, NULL, NULL, ?, ?)", arguments: [id(executionID), id(conversationID), id(messageID), try encode(route), at.timeIntervalSince1970, at.timeIntervalSince1970])
                try db.execute(sql: "INSERT INTO messages (id, conversation_id, execution_id, sequence, role, status, text, created_at) VALUES (?, ?, ?, ?, 'user', 'committed', ?, ?)", arguments: [id(messageID), id(conversationID), id(executionID), sequence, text, at.timeIntervalSince1970])
                try db.execute(sql: "UPDATE conversations SET updated_at = ?, revision = revision + 1 WHERE id = ?", arguments: [at.timeIntervalSince1970, id(conversationID)])
                if let title = try String.fetchOne(db, sql: "SELECT title FROM conversations WHERE id = ?", arguments: [id(conversationID)]), ["New Conversation", "新对话"].contains(title) {
                    let preview = String(text.prefix(80))
                    try db.execute(sql: "UPDATE conversations SET title = ? WHERE id = ?", arguments: [preview, id(conversationID)])
                }
                return execution
            }
        }
    }

    public func retry(executionID: ExecutionID, newExecutionID: ExecutionID, route: ModelRoute, at: Date) throws -> Execution {
        try safely {
            return try pool.write { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT rowid, id, conversation_id, trigger_message_id, status, route_json FROM executions WHERE id = ?", arguments: [id(executionID)]) else { throw MiraError(.notFound, "执行不存在。") }
                let status = row["status"] as String
                guard ["failed", "cancelled", "interrupted"].contains(status) else { throw MiraError(.conflict, "只有已结束且失败的执行可以重试。") }
                let conversationID = try conversationIDValue(row["conversation_id"] as String)
                let triggerID = try messageIDValue(row["trigger_message_id"] as String)
                guard try Int.fetchOne(db, sql: "SELECT 1 FROM executions WHERE conversation_id = ? AND rowid > ? LIMIT 1", arguments: [id(conversationID), row["rowid"] as Int64]) == nil else { throw MiraError(.conflict, "该执行已经不是最后一回合。") }
                let laterUser = try Int.fetchOne(db, sql: "SELECT 1 FROM messages WHERE conversation_id = ? AND role = 'user' AND sequence > (SELECT sequence FROM messages WHERE id = ?) LIMIT 1", arguments: [id(conversationID), id(triggerID)])
                guard laterUser == nil else { throw MiraError(.conflict, "该执行之后已经有新的用户消息。") }
                if try Int.fetchOne(db, sql: "SELECT 1 FROM executions WHERE conversation_id = ? AND status IN ('queued', 'waitingForModel') LIMIT 1", arguments: [id(conversationID)]) != nil { throw MiraError(.busy, "此对话已有执行正在进行。") }
                guard try Row.fetchOne(db, sql: "SELECT 1 FROM conversations WHERE id = ? AND is_archived = 0", arguments: [id(conversationID)]) != nil else { throw MiraError(.invalidInput, "归档对话不能重试。") }
                let execution = Execution(id: newExecutionID, conversationID: conversationID, triggerMessageID: triggerID, retryOfExecutionID: executionID, route: route, createdAt: at, updatedAt: at)
                try db.execute(sql: "INSERT INTO executions (id, conversation_id, trigger_message_id, retry_of_execution_id, status, route_json, usage_input, usage_output, error_json, created_at, updated_at) VALUES (?, ?, ?, ?, 'queued', ?, NULL, NULL, NULL, ?, ?)", arguments: [id(newExecutionID), id(conversationID), id(triggerID), id(executionID), try encode(route), at.timeIntervalSince1970, at.timeIntervalSince1970])
                try db.execute(sql: "UPDATE conversations SET updated_at = ?, revision = revision + 1 WHERE id = ?", arguments: [at.timeIntervalSince1970, id(conversationID)])
                return execution
            }
        }
    }

    public func prepare(executionID: ExecutionID, request: CanonicalModelRequest, at: Date) throws {
        try safely {
            guard request.executionID == executionID else { throw MiraError(.invalidInput, "请求与执行不匹配。") }
            try pool.write { db in
                try db.execute(sql: "UPDATE executions SET status = 'waitingForModel', request_json = ?, updated_at = ? WHERE id = ? AND status = 'queued'", arguments: [try encode(request), at.timeIntervalSince1970, id(executionID)])
                guard db.changesCount > 0 else { throw MiraError(.conflict, "执行已离开等待状态。") }
            }
        }
    }

    public func request(for executionID: ExecutionID) throws -> CanonicalModelRequest? {
        try safely { try pool.read { db in
            // The legacy column remains the compatibility fallback. M2 callers get
            // the most recently prepared attempt, which is the request that would
            // have been sent for the current audit boundary.
            let value = try String.fetchOne(db, sql: "SELECT request_json FROM model_attempts WHERE execution_id = ? ORDER BY step_index DESC, attempt_index DESC, rowid DESC LIMIT 1", arguments: [id(executionID)])
                ?? String.fetchOne(db, sql: "SELECT request_json FROM executions WHERE id = ?", arguments: [id(executionID)])
            guard let value else { return nil }
            return try decodeRequest(value)
        }}
    }

    public func prepareAttempt(_ attempt: ModelAttempt) throws {
        try safely {
            guard attempt.stepIndex >= 0, attempt.attemptIndex > 0 else { throw MiraError(.invalidInput, "执行步骤序号无效。") }
            guard attempt.request.executionID == attempt.executionID,
                  attempt.request.requestID == attempt.id else { throw MiraError(.invalidInput, "请求与模型尝试不匹配。") }
            try pool.write { db in
                guard let execution = try Row.fetchOne(db, sql: "SELECT status FROM executions WHERE id = ?", arguments: [id(attempt.executionID)]) else {
                    throw MiraError(.notFound, "执行不存在。")
                }
                guard let status = ExecutionStatus(rawValue: execution["status"] as String), !status.isTerminal else {
                    throw MiraError(.conflict, "执行已经结束。")
                }

                let lastStep = try Int.fetchOne(db, sql: "SELECT MAX(sequence) FROM execution_steps WHERE execution_id = ?", arguments: [id(attempt.executionID)])
                let stepID: String
                if lastStep == nil {
                    guard attempt.attemptIndex == 1, attempt.stepIndex == 1 else { throw MiraError(.conflict, "首个步骤的序号无效。") }
                    stepID = attempt.stepID.uuidString.lowercased()
                    try db.execute(sql: "INSERT INTO execution_steps (id, execution_id, sequence, state, output_json, error_json, started_at, completed_at) VALUES (?, ?, ?, 'running', NULL, NULL, ?, NULL)", arguments: [stepID, id(attempt.executionID), attempt.stepIndex, attempt.createdAt.timeIntervalSince1970])
                } else if attempt.stepIndex == lastStep! {
                    guard attempt.attemptIndex > 1 else { throw MiraError(.conflict, "同一步骤的尝试序号重复。") }
                    guard let existingStep = try Row.fetchOne(db, sql: "SELECT id FROM execution_steps WHERE execution_id = ? AND sequence = ?", arguments: [id(attempt.executionID), lastStep!]),
                          existingStep["id"] as String == attempt.stepID.uuidString.lowercased(),
                          let previousAttempt = try Row.fetchOne(db, sql: "SELECT id, status, output_json FROM model_attempts WHERE execution_id = ? AND step_index = ? ORDER BY attempt_index DESC, rowid DESC LIMIT 1", arguments: [id(attempt.executionID), lastStep!]),
                          (previousAttempt["status"] as String) == AttemptStatus.failed.rawValue,
                          (previousAttempt["output_json"] as String?) == nil else { throw MiraError(.conflict, "只有无输出且无工具调用的失败尝试可以重试。") }
                    let priorInvocations = try Int.fetchOne(db, sql: "SELECT 1 FROM tool_invocations WHERE execution_id = ? AND attempt_id = ? LIMIT 1", arguments: [id(attempt.executionID), previousAttempt["id"] as String])
                    guard priorInvocations == nil else { throw MiraError(.conflict, "已有工具调用的尝试不能重试。") }
                    let expected = (try Int.fetchOne(db, sql: "SELECT attempt_index FROM model_attempts WHERE execution_id = ? AND step_index = ? ORDER BY attempt_index DESC, rowid DESC LIMIT 1", arguments: [id(attempt.executionID), lastStep!]) ?? 0) + 1
                    guard attempt.attemptIndex == expected else { throw MiraError(.conflict, "模型尝试必须按顺序创建。") }
                    let pending = try Int.fetchOne(db, sql: "SELECT 1 FROM tool_invocations WHERE execution_id = ? AND attempt_id = ? AND result_json IS NULL LIMIT 1", arguments: [id(attempt.executionID), previousAttempt["id"] as String])
                    guard pending == nil else { throw MiraError(.conflict, "上一次工具结果尚未提交。") }
                    stepID = attempt.stepID.uuidString.lowercased()
                    try db.execute(sql: "UPDATE execution_steps SET state = 'running', output_json = NULL, error_json = NULL, completed_at = NULL WHERE execution_id = ? AND sequence = ?", arguments: [id(attempt.executionID), lastStep!])
                } else if attempt.stepIndex == lastStep! + 1 {
                    guard attempt.attemptIndex == 1 else { throw MiraError(.conflict, "新步骤的尝试序号无效。") }
                    let previous = lastStep!
                    guard let previousAttempt = try Row.fetchOne(db, sql: "SELECT id, status, output_json FROM model_attempts WHERE execution_id = ? AND step_index = ? ORDER BY attempt_index DESC, rowid DESC LIMIT 1", arguments: [id(attempt.executionID), previous]),
                          (previousAttempt["status"] as String) == AttemptStatus.completed.rawValue,
                          (previousAttempt["output_json"] as String?) != nil else {
                        throw MiraError(.conflict, "上一步模型输出尚未提交。")
                    }
                    let previousOutput: ModelOutput = try Self.decode(previousAttempt["output_json"] as String)
                    guard previousOutput.finishReason == .toolCalls else { throw MiraError(.conflict, "只有工具调用输出可以继续下一步骤。") }
                    let pending = try Int.fetchOne(db, sql: "SELECT 1 FROM tool_invocations WHERE execution_id = ? AND attempt_id = ? AND result_json IS NULL LIMIT 1", arguments: [id(attempt.executionID), previousAttempt["id"] as String])
                    guard pending == nil else { throw MiraError(.conflict, "上一步工具结果尚未提交。") }
                    try db.execute(sql: "UPDATE execution_steps SET state = 'completed', completed_at = COALESCE(completed_at, ?) WHERE execution_id = ? AND sequence = ? AND state = 'waitingForTool'", arguments: [attempt.createdAt.timeIntervalSince1970, id(attempt.executionID), previous])
                    stepID = attempt.stepID.uuidString.lowercased()
                    try db.execute(sql: "INSERT INTO execution_steps (id, execution_id, sequence, state, output_json, error_json, started_at, completed_at) VALUES (?, ?, ?, 'running', NULL, NULL, ?, NULL)", arguments: [stepID, id(attempt.executionID), attempt.stepIndex, attempt.createdAt.timeIntervalSince1970])
                } else {
                    throw MiraError(.conflict, "执行步骤必须按顺序创建。")
                }
                try db.execute(sql: "INSERT INTO model_attempts (id, execution_id, step_id, step_index, attempt_index, request_json, status, output_json, usage_input, usage_output, error_json, created_at, completed_at) VALUES (?, ?, ?, ?, ?, ?, 'prepared', NULL, NULL, NULL, NULL, ?, NULL)", arguments: [attempt.id.uuidString.lowercased(), id(attempt.executionID), stepID, attempt.stepIndex, attempt.attemptIndex, try encode(attempt.request), attempt.createdAt.timeIntervalSince1970])
                try db.execute(sql: "UPDATE executions SET status = 'waitingForModel', request_json = ?, updated_at = ? WHERE id = ? AND status IN ('queued', 'waitingForModel')", arguments: [try encode(attempt.request), attempt.createdAt.timeIntervalSince1970, id(attempt.executionID)])
                guard db.changesCount > 0 else { throw MiraError(.conflict, "执行已离开等待状态。") }
            }
        }
    }

    public func attempts(for executionID: ExecutionID) throws -> [ModelAttempt] {
        try safely { try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, execution_id, step_id, step_index, attempt_index, request_json, status, output_json, usage_input, usage_output, error_json, created_at, completed_at FROM model_attempts WHERE execution_id = ? ORDER BY step_index, attempt_index, rowid", arguments: [id(executionID)]).map { try Self.modelAttempt($0) }
        }}
    }

    public func finishAttempt(_ id: UUID, output: ModelOutput?, invocations: [ToolInvocation], usage: TokenUsage, error: MiraError?, at: Date) throws {
        try safely {
            try pool.write { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT execution_id, step_id, step_index, status FROM model_attempts WHERE id = ?", arguments: [id.uuidString.lowercased()]) else { throw MiraError(.notFound, "模型尝试不存在。") }
                guard (row["status"] as String) == AttemptStatus.prepared.rawValue else { throw MiraError(.conflict, "模型尝试已经结束。") }
                let executionID = row["execution_id"] as String
                let toolCalls = output?.toolCalls ?? []
                guard output != nil || error != nil else { throw MiraError(.invalidInput, "模型尝试缺少输出或错误。") }
                guard output == nil || error == nil else { throw MiraError(.invalidInput, "模型输出与错误不能同时提交。") }
                guard invocations.count == toolCalls.count else { throw MiraError(.invalidInput, "工具调用数量与模型输出不匹配。") }
                for (index, invocation) in invocations.enumerated() {
                    let call = toolCalls[index]
                    guard invocation.attemptID.uuidString.lowercased() == id.uuidString.lowercased(),
                          invocation.modelOrder == index,
                          invocation.call == call,
                          invocation.result == nil,
                          invocation.dispatchedAt == nil,
                          invocation.completedAt == nil else { throw MiraError(.invalidInput, "工具调用审计内容不匹配。") }
                    // The provider call ID is also a schema-level unique key; the
                    // explicit preflight makes the error stable before insertion.
                    guard !call.id.isEmpty, !call.name.isEmpty else { throw MiraError(.invalidInput, "工具调用身份无效。") }
                }
                let finalStatus: AttemptStatus = output == nil ? .failed : .completed
                let outputJSON = try output.map(encode)
                let errorJSON = try error.map(encode)
                try db.execute(sql: "UPDATE model_attempts SET status = ?, output_json = ?, usage_input = ?, usage_output = ?, error_json = ?, completed_at = ? WHERE id = ? AND status = 'prepared'", arguments: [finalStatus.rawValue, outputJSON, usage.inputTokens, usage.outputTokens, errorJSON, at.timeIntervalSince1970, id.uuidString.lowercased()])
                guard db.changesCount == 1 else { throw MiraError(.conflict, "模型尝试已经结束。") }
                for invocation in invocations {
                    try db.execute(sql: "INSERT INTO tool_invocations (id, execution_id, attempt_id, model_order, provider_call_id, tool_name, arguments_json, status, result_json, dispatched_at, completed_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', NULL, NULL, NULL)", arguments: [invocation.id.uuidString.lowercased(), executionID, invocation.attemptID.uuidString.lowercased(), invocation.modelOrder, invocation.call.id, invocation.call.name, invocation.call.arguments])
                }
                let stepState = output?.toolCalls.isEmpty == false ? "waitingForTool" : (output == nil ? "failed" : "completed")
                let stepCompletedAt: Double? = output?.toolCalls.isEmpty == false ? nil : at.timeIntervalSince1970
                try db.execute(sql: "UPDATE execution_steps SET state = ?, output_json = ?, error_json = ?, completed_at = ? WHERE id = ? AND execution_id = ?", arguments: [stepState, outputJSON, errorJSON, stepCompletedAt, row["step_id"] as String, executionID])
                try db.execute(sql: "UPDATE executions SET updated_at = ? WHERE id = ?", arguments: [at.timeIntervalSince1970, executionID])
            }
        }
    }

    public func toolInvocations(for executionID: ExecutionID) throws -> [ToolInvocation] {
        try safely { try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, attempt_id, model_order, provider_call_id, tool_name, arguments_json, status, result_json, dispatched_at, completed_at FROM tool_invocations WHERE execution_id = ? ORDER BY (SELECT step_index FROM model_attempts WHERE id = tool_invocations.attempt_id), (SELECT attempt_index FROM model_attempts WHERE id = tool_invocations.attempt_id), model_order, rowid", arguments: [id(executionID)]).map { try Self.toolInvocation($0) }
        }}
    }

    public func markToolDispatched(_ id: UUID, at: Date) throws {
        try safely {
            try pool.write { db in
                try db.execute(sql: "UPDATE tool_invocations SET status = 'dispatched', dispatched_at = ? WHERE id = ? AND status = 'pending' AND result_json IS NULL", arguments: [at.timeIntervalSince1970, id.uuidString.lowercased()])
                guard db.changesCount == 1 else { throw MiraError(.conflict, "工具调用已调度或已经结束。") }
                try db.execute(sql: "UPDATE executions SET updated_at = ? WHERE id = (SELECT execution_id FROM tool_invocations WHERE id = ?)", arguments: [at.timeIntervalSince1970, id.uuidString.lowercased()])
            }
        }
    }

    @discardableResult
    public func finishToolInvocation(_ id: UUID, result: ToolResult, at: Date) throws -> Bool {
        try safely {
            try pool.write { db in
                guard let status = try String.fetchOne(db, sql: "SELECT status FROM tool_invocations WHERE id = ?", arguments: [id.uuidString.lowercased()]) else { throw MiraError(.notFound, "工具调用不存在。") }
                if ToolResultStatus(rawValue: status) != nil { return false }
                let dispatchFree: Set<ToolResultStatus> = [.invalidArguments, .notFound, .denied, .timedOut, .cancelledBeforeDispatch, .failed, .outputLimit]
                if status == "pending" && !dispatchFree.contains(result.status) { throw MiraError(.conflict, "未调度的工具调用结果状态无效。") }
                if status == "dispatched" && result.status == .cancelledBeforeDispatch { throw MiraError(.conflict, "已调度的工具调用不能标记为未调度取消。") }
                guard status == "pending" || status == "dispatched" else { throw MiraError(.conflict, "工具调用状态无效。") }
                try db.execute(sql: "UPDATE tool_invocations SET status = ?, result_json = ?, completed_at = ? WHERE id = ? AND status IN ('pending', 'dispatched') AND result_json IS NULL", arguments: [result.status.rawValue, try encode(result), at.timeIntervalSince1970, id.uuidString.lowercased()])
                guard db.changesCount == 1 else { return false }
                try db.execute(sql: "UPDATE executions SET updated_at = ? WHERE id = (SELECT execution_id FROM tool_invocations WHERE id = ?)", arguments: [at.timeIntervalSince1970, id.uuidString.lowercased()])
                return true
            }
        }
    }

    public func checkpoint(executionID: ExecutionID, text: String, at: Date) throws {
        try safely {
            try pool.write { db in
                guard try Int.fetchOne(db, sql: "SELECT 1 FROM executions WHERE id = ? AND status IN ('queued', 'waitingForModel')", arguments: [id(executionID)]) != nil else { throw MiraError(.conflict, "执行已结束，无法保存草稿。") }
                try db.execute(sql: "INSERT INTO assistant_drafts (execution_id, text, updated_at) VALUES (?, ?, ?) ON CONFLICT(execution_id) DO UPDATE SET text = excluded.text, updated_at = excluded.updated_at", arguments: [id(executionID), text, at.timeIntervalSince1970])
            }
        }
    }

    @discardableResult
    public func finish(executionID: ExecutionID, status: ExecutionStatus, text: String, usage: TokenUsage, error: MiraError?, assistantMessageID: MessageID, at: Date) throws -> Bool {
        try safely {
            guard status.isTerminal else { throw MiraError(.invalidInput, "执行终态无效。") }
            return try pool.write { db in
                guard let execution = try Row.fetchOne(db, sql: "SELECT conversation_id, status FROM executions WHERE id = ?", arguments: [id(executionID)]) else { throw MiraError(.notFound, "执行不存在。") }
                let unfinishedAttempts = try Int.fetchOne(db, sql: "SELECT 1 FROM model_attempts WHERE execution_id = ? AND status = 'prepared' LIMIT 1", arguments: [id(executionID)]) != nil
                let unfinishedTools = try Int.fetchOne(db, sql: "SELECT 1 FROM tool_invocations WHERE execution_id = ? AND result_json IS NULL LIMIT 1", arguments: [id(executionID)]) != nil
                if status == .completed && (unfinishedAttempts || unfinishedTools) {
                    throw MiraError(.conflict, "执行仍有未完成的模型尝试或工具调用。")
                }
                if status == .completed {
                    try db.execute(sql: "UPDATE execution_steps SET state = 'completed', completed_at = COALESCE(completed_at, ?) WHERE execution_id = ? AND state = 'waitingForTool' AND NOT EXISTS (SELECT 1 FROM tool_invocations WHERE tool_invocations.attempt_id IN (SELECT id FROM model_attempts WHERE model_attempts.step_id = execution_steps.id) AND tool_invocations.result_json IS NULL)", arguments: [at.timeIntervalSince1970, id(executionID)])
                }
                try db.execute(sql: "UPDATE executions SET status = ?, usage_input = ?, usage_output = ?, error_json = ?, updated_at = ? WHERE id = ? AND status IN ('queued', 'waitingForModel')", arguments: [status.rawValue, usage.inputTokens, usage.outputTokens, error.map(Self.encodeStoredError), at.timeIntervalSince1970, id(executionID)])
                guard db.changesCount > 0 else { return false }
                if status != .completed {
                    try closeOpenAudit(in: db, executionID: executionID, at: at)
                }
                if !text.isEmpty {
                    let conversationID = try conversationIDValue(execution["conversation_id"] as String)
                    let sequence = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence), 0) + 1 FROM messages WHERE conversation_id = ?", arguments: [id(conversationID)]) ?? 1)
                    let messageStatus: MessageStatus = status == .completed ? .committed : .interrupted
                    try db.execute(sql: "INSERT INTO messages (id, conversation_id, execution_id, sequence, role, status, text, created_at) VALUES (?, ?, ?, ?, 'assistant', ?, ?, ?)", arguments: [id(assistantMessageID), id(conversationID), id(executionID), sequence, messageStatus.rawValue, text, at.timeIntervalSince1970])
                }
                try db.execute(sql: "DELETE FROM assistant_drafts WHERE execution_id = ?", arguments: [id(executionID)])
                try db.execute(sql: "UPDATE conversations SET updated_at = ?, revision = revision + 1 WHERE id = ?", arguments: [at.timeIntervalSince1970, execution["conversation_id"] as String])
                return true
            }
        }
    }

    public func recoverInterrupted(at: Date) throws {
        try safely {
            try pool.write { db in
                let rows = try Row.fetchAll(db, sql: "SELECT id, conversation_id FROM executions WHERE status IN ('queued', 'waitingForModel')")
                for row in rows {
                    let executionID = try executionIDValue(row["id"] as String)
                    let conversationID = try conversationIDValue(row["conversation_id"] as String)
                    let draft = try Row.fetchOne(db, sql: "SELECT text FROM assistant_drafts WHERE execution_id = ?", arguments: [id(executionID)])
                    try db.execute(sql: "UPDATE executions SET status = 'interrupted', updated_at = ? WHERE id = ? AND status IN ('queued', 'waitingForModel')", arguments: [at.timeIntervalSince1970, id(executionID)])
                    let interrupted = db.changesCount > 0
                    if interrupted, let draft {
                        let already = try Int.fetchOne(db, sql: "SELECT 1 FROM messages WHERE execution_id = ? AND role = 'assistant' LIMIT 1", arguments: [id(executionID)])
                        if already == nil {
                            let sequence = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence), 0) + 1 FROM messages WHERE conversation_id = ?", arguments: [id(conversationID)]) ?? 1)
                            try db.execute(sql: "INSERT INTO messages (id, conversation_id, execution_id, sequence, role, status, text, created_at) VALUES (?, ?, ?, ?, 'assistant', 'interrupted', ?, ?)", arguments: [id(EntityID<MessageTag>()), id(conversationID), id(executionID), sequence, draft["text"] as String, at.timeIntervalSince1970])
                        }
                        try db.execute(sql: "DELETE FROM assistant_drafts WHERE execution_id = ?", arguments: [id(executionID)])
                    }
                    if interrupted {
                        try closeOpenAudit(in: db, executionID: executionID, at: at)
                    }
                }
            }
        }
    }

    // MARK: - Diagnostics and backup

    public func diagnostics() throws -> StorageDiagnostics {
        try safely {
            let probe = try DatabaseQueue(path: ":memory:")
            return try probe.write { db in
                try db.execute(sql: "ATTACH DATABASE ':memory:' AS linked")
                var fts5 = false
                var trigram = false
                do {
                    try db.execute(sql: "CREATE VIRTUAL TABLE linked.fts_probe USING fts5(content, tokenize='unicode61')")
                    fts5 = true
                } catch { }
                do {
                    try db.execute(sql: "CREATE VIRTUAL TABLE linked.trigram_probe USING fts5(content, tokenize='trigram')")
                    trigram = true
                } catch { }
                let version = try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "unknown"
                return StorageDiagnostics(sqliteVersion: version, supportsFTS5: fts5, supportsTrigram: trigram)
            }
        }
    }

    /// Close every audit record which may still represent work at a terminal
    /// execution boundary. A dispatched call is conservatively marked
    /// interrupted because its side effect may already have happened; a call
    /// which was never dispatched is explicitly cancelled before dispatch.
    private func closeOpenAudit(in db: Database, executionID: ExecutionID, at: Date) throws {
        try db.execute(sql: "UPDATE tool_invocations SET status = 'interrupted', result_json = ?, completed_at = ? WHERE execution_id = ? AND status = 'dispatched' AND result_json IS NULL", arguments: [try encode(ToolResult(status: .interrupted, text: "执行已中断。")), at.timeIntervalSince1970, id(executionID)])
        try db.execute(sql: "UPDATE tool_invocations SET status = 'cancelledBeforeDispatch', result_json = ?, completed_at = ? WHERE execution_id = ? AND status = 'pending' AND result_json IS NULL", arguments: [try encode(ToolResult(status: .cancelledBeforeDispatch, text: "工具未调度，执行已结束。")), at.timeIntervalSince1970, id(executionID)])
        try db.execute(sql: "UPDATE model_attempts SET status = 'interrupted', error_json = ?, completed_at = ? WHERE execution_id = ? AND status = 'prepared'", arguments: [Self.encodeStoredError(MiraError(.interrupted, "执行已中断。")), at.timeIntervalSince1970, id(executionID)])
        try db.execute(sql: "UPDATE execution_steps SET state = 'interrupted', error_json = ?, completed_at = ? WHERE execution_id = ? AND state IN ('running', 'waitingForTool')", arguments: [Self.encodeStoredError(MiraError(.interrupted, "执行已中断。")), at.timeIntervalSince1970, id(executionID)])
    }

    public func exportBackup(to destination: URL) throws {
        try safely {
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw MiraError(.conflict, "备份目标已存在。") }
            try Self.createDirectoryIfNeeded(destination.deletingLastPathComponent())
            var created = false
            do {
                do {
                    let dest = try DatabaseQueue(path: destination.path)
                    created = true
                    try pool.backup(to: dest)
                    try dest.writeWithoutTransaction { db in
                        try db.execute(sql: "PRAGMA journal_mode = DELETE")
                        try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                    }
                }
                // The destination handle is closed before the file is handed to callers.
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            } catch {
                if created { try? FileManager.default.removeItem(at: destination) }
                throw error
            }
        }
    }

    public func restoreBackup(from source: URL, to directory: URL) throws {
        try safely {
            guard FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: directory.path) else {
                throw MiraError(.conflict, "恢复源无效或目标资料库已存在。")
            }
            let parent = directory.deletingLastPathComponent()
            try Self.createDirectoryIfNeeded(parent)
            let temporary = parent.appendingPathComponent(".mira-restore-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Self.createDirectoryIfNeeded(temporary)
            let sourceStaging = parent.appendingPathComponent(".mira-source-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: sourceStaging) }
            try Self.createDirectoryIfNeeded(sourceStaging)
            let stagedSource = sourceStaging.appendingPathComponent("Mira.sqlite")
            try FileManager.default.copyItem(at: source, to: stagedSource)
            let destinationPath = temporary.appendingPathComponent("Mira.sqlite").path
            do {
                let reference = try DatabaseQueue()
                try Self.makeMigrator().migrate(reference)
                let expectedSchema = try reference.read { try Self.schemaSignature(in: $0) }
                // Never open the caller's backup writable. The staged copy is owned by this operation.
                let sourcePool = try DatabaseQueue(path: stagedSource.path)
                try sourcePool.read { db in
                    let sourceVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
                    if sourceVersion == 1 {
                        // Validate a v1 backup against a v1-only reference before allowing
                        // GRDB to migrate the private staging copy. The caller's source is
                        // never opened writable, so no journal/WAL/permission sidecars can
                        // be created beside it.
                        let legacyReference = try DatabaseQueue()
                        try Self.makeLegacyMigrator().migrate(legacyReference)
                        let legacySchema = try legacyReference.read { try Self.schemaSignature(in: $0) }
                        guard try Self.schemaSignature(in: db) == legacySchema else { throw MiraError(.unsupported, "备份结构或约束与旧版本不符。") }
                        try Self.validateBackupMetadata(in: db, version: 1)
                    } else {
                        guard sourceVersion == Self.currentSchemaVersion else { throw MiraError(.unsupported, "备份版本不受当前恢复器支持。") }
                        // Check constraints and indexes as well as names before typed row decoding.
                        // A forged or damaged same-version schema must not bypass runtime invariants.
                        guard try Self.schemaSignature(in: db) == expectedSchema else { throw MiraError(.unsupported, "备份结构或约束与当前版本不符。") }
                        try Self.validateBackupMetadata(in: db, version: 2)
                    }
                    guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok" else { throw MiraError(.storage, "备份校验失败。") }
                    let foreign = try String.fetchOne(db, sql: "PRAGMA foreign_key_check") ?? ""
                    guard foreign.isEmpty else { throw MiraError(.storage, "备份关系校验失败。") }
                    if sourceVersion == 1 { try Self.validateContents(in: db) }
                }
                if try sourcePool.read({ (try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0) == 1 }) {
                    try Self.makeMigrator().migrate(sourcePool)
                    try sourcePool.read { db in
                        guard try Self.schemaSignature(in: db) == expectedSchema else { throw MiraError(.unsupported, "备份迁移后的结构无效。") }
                        try Self.validateBackupMetadata(in: db, version: 2)
                        try Self.validateContents(in: db)
                    }
                } else {
                    try sourcePool.read { db in try Self.validateContents(in: db) }
                }
                let destination = try DatabaseQueue(path: destinationPath)
                try sourcePool.backup(to: destination)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationPath)
            _ = try SQLiteMiraStore(directory: temporary)
            try FileManager.default.moveItem(at: temporary, to: directory)
        }
    }
}

// MARK: - Schema

private extension SQLiteMiraStore {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = makeLegacyMigrator()
        migrator.registerMigration(auditMigrationName) { db in
            try createAuditSchema(in: db)
            try db.execute(sql: "PRAGMA user_version = 2")
        }
        return migrator
    }

    static func makeLegacyMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(legacyMigrationName) { db in
            try createSchema(in: db)
            try db.execute(sql: "PRAGMA user_version = 1")
        }
        return migrator
    }

    static func schemaSignature(in db: Database) throws -> Set<String> {
        Set(try Row.fetchAll(db, sql: "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'").map { row in
            let type: String = row["type"], name: String = row["name"]
            let sql: String? = row["sql"]
            return "\(type)|\(name)|\(sql ?? "<nil>")"
        })
    }

    static func createSchema(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE workspaces (
          id TEXT PRIMARY KEY NOT NULL,
          name TEXT NOT NULL CHECK(length(trim(name)) > 0),
          background TEXT NOT NULL,
          allows_remote_send INTEGER NOT NULL CHECK(allows_remote_send IN (0, 1)),
          revision INTEGER NOT NULL CHECK(revision > 0)
        );
        CREATE TABLE conversations (
          id TEXT PRIMARY KEY NOT NULL,
          workspace_id TEXT REFERENCES workspaces(id) ON DELETE RESTRICT,
          title TEXT NOT NULL CHECK(length(trim(title)) > 0),
          is_archived INTEGER NOT NULL CHECK(is_archived IN (0, 1)),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          revision INTEGER NOT NULL CHECK(revision > 0)
        );
        CREATE TABLE routes (
          id TEXT PRIMARY KEY NOT NULL,
          revision INTEGER NOT NULL CHECK(revision > 0),
          name TEXT NOT NULL CHECK(length(trim(name)) > 0),
          route_json TEXT NOT NULL
        );
        CREATE TABLE executions (
          id TEXT PRIMARY KEY NOT NULL,
          conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
          trigger_message_id TEXT NOT NULL,
          retry_of_execution_id TEXT REFERENCES executions(id) ON DELETE RESTRICT,
          status TEXT NOT NULL CHECK(status IN ('queued', 'waitingForModel', 'completed', 'failed', 'cancelled', 'interrupted')),
          route_json TEXT NOT NULL,
          request_json TEXT,
          usage_input INTEGER,
          usage_output INTEGER,
          error_json TEXT,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          UNIQUE(id, conversation_id),
          FOREIGN KEY(trigger_message_id, conversation_id) REFERENCES messages(id, conversation_id) DEFERRABLE INITIALLY DEFERRED
        );
        CREATE TABLE messages (
          id TEXT PRIMARY KEY NOT NULL,
          conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
          execution_id TEXT,
          sequence INTEGER NOT NULL CHECK(sequence > 0),
          role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
          status TEXT NOT NULL CHECK(status IN ('committed', 'interrupted', 'failed')),
          text TEXT NOT NULL,
          created_at REAL NOT NULL,
          UNIQUE(conversation_id, sequence),
          UNIQUE(id, conversation_id),
          FOREIGN KEY(execution_id, conversation_id) REFERENCES executions(id, conversation_id) DEFERRABLE INITIALLY DEFERRED
        );
        CREATE TABLE assistant_drafts (
          execution_id TEXT PRIMARY KEY NOT NULL REFERENCES executions(id) ON DELETE CASCADE,
          text TEXT NOT NULL,
          updated_at REAL NOT NULL
        );
        CREATE UNIQUE INDEX executions_one_active_per_conversation ON executions(conversation_id) WHERE status IN ('queued', 'waitingForModel');
        CREATE UNIQUE INDEX messages_one_assistant_per_execution ON messages(execution_id) WHERE role = 'assistant';
        CREATE INDEX conversations_workspace_updated ON conversations(workspace_id, updated_at, id);
        CREATE INDEX messages_conversation_sequence ON messages(conversation_id, sequence);
        CREATE INDEX executions_conversation_created ON executions(conversation_id, created_at, id);
        """)
    }

    static func createAuditSchema(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE execution_steps (
          id TEXT PRIMARY KEY NOT NULL,
          execution_id TEXT NOT NULL REFERENCES executions(id) ON DELETE CASCADE,
          sequence INTEGER NOT NULL CHECK(sequence > 0),
          state TEXT NOT NULL CHECK(state IN ('running', 'waitingForTool', 'completed', 'failed', 'interrupted')),
          output_json TEXT,
          error_json TEXT,
          started_at REAL NOT NULL,
          completed_at REAL,
          UNIQUE(id, execution_id, sequence),
          UNIQUE(execution_id, sequence),
          CHECK((state IN ('running', 'waitingForTool') AND completed_at IS NULL) OR (state IN ('completed', 'failed', 'interrupted') AND completed_at IS NOT NULL))
        );
        CREATE TABLE model_attempts (
          id TEXT PRIMARY KEY NOT NULL,
          execution_id TEXT NOT NULL REFERENCES executions(id) ON DELETE CASCADE,
          step_id TEXT NOT NULL,
          step_index INTEGER NOT NULL CHECK(step_index > 0),
          attempt_index INTEGER NOT NULL CHECK(attempt_index > 0),
          request_json TEXT NOT NULL,
          status TEXT NOT NULL CHECK(status IN ('prepared', 'completed', 'failed', 'interrupted')),
          output_json TEXT,
          usage_input INTEGER,
          usage_output INTEGER,
          error_json TEXT,
          created_at REAL NOT NULL,
          completed_at REAL,
          UNIQUE(id, execution_id),
          UNIQUE(execution_id, step_id, step_index, attempt_index),
          FOREIGN KEY(step_id, execution_id, step_index) REFERENCES execution_steps(id, execution_id, sequence) ON DELETE CASCADE,
          CHECK((status = 'prepared' AND completed_at IS NULL) OR (status IN ('completed', 'failed', 'interrupted') AND completed_at IS NOT NULL)),
          CHECK(status != 'completed' OR output_json IS NOT NULL)
        );
        CREATE TABLE tool_invocations (
          id TEXT PRIMARY KEY NOT NULL,
          execution_id TEXT NOT NULL REFERENCES executions(id) ON DELETE CASCADE,
          attempt_id TEXT NOT NULL,
          model_order INTEGER NOT NULL CHECK(model_order >= 0),
          provider_call_id TEXT NOT NULL CHECK(length(provider_call_id) > 0),
          tool_name TEXT NOT NULL CHECK(length(tool_name) > 0),
          arguments_json TEXT NOT NULL,
          status TEXT NOT NULL CHECK(status IN ('pending', 'dispatched', 'succeeded', 'invalidArguments', 'notFound', 'denied', 'timedOut', 'cancelledBeforeDispatch', 'cancelled', 'failed', 'outputLimit', 'interrupted')),
          result_json TEXT,
          dispatched_at REAL,
          completed_at REAL,
          UNIQUE(attempt_id, model_order),
          UNIQUE(attempt_id, provider_call_id),
          UNIQUE(id, execution_id),
          FOREIGN KEY(attempt_id, execution_id) REFERENCES model_attempts(id, execution_id) ON DELETE CASCADE,
          CHECK((status IN ('pending', 'dispatched') AND result_json IS NULL AND completed_at IS NULL) OR (status NOT IN ('pending', 'dispatched') AND result_json IS NOT NULL AND completed_at IS NOT NULL)),
          CHECK((status = 'pending' AND dispatched_at IS NULL) OR status != 'pending'),
          CHECK((status = 'dispatched' AND dispatched_at IS NOT NULL) OR status != 'dispatched'),
          CHECK((status IN ('pending', 'invalidArguments', 'notFound', 'cancelledBeforeDispatch') AND dispatched_at IS NULL) OR (status IN ('dispatched', 'succeeded', 'cancelled', 'interrupted') AND dispatched_at IS NOT NULL) OR status IN ('denied', 'timedOut', 'failed', 'outputLimit'))
        );
        CREATE INDEX execution_steps_execution_sequence ON execution_steps(execution_id, sequence);
        CREATE INDEX model_attempts_execution_order ON model_attempts(execution_id, step_index, attempt_index);
        CREATE INDEX tool_invocations_execution_order ON tool_invocations(execution_id, attempt_id, model_order);
        """)
    }

    static func createDirectoryIfNeeded(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path), (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw MiraError(.storage, "资料库目录无效。")
        }
        if fm.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw MiraError(.storage, "资料库目录无效。") }
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return
        }
    }

    static func encodeStoredError(_ error: MiraError) -> String {
        (try? encode(error)) ?? ""
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decodeRoute(_ value: String) throws -> ModelRoute {
        try decode(value)
    }

    static func decodeRequest(_ value: String) throws -> CanonicalModelRequest {
        try decode(value)
    }

    static func decode<T: Decodable>(_ value: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(T.self, from: Data(value.utf8))
    }

    func safely<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch let error as MiraError { throw error }
        catch { throw MiraError.safe(error) }
    }

    func id<Tag>(_ value: EntityID<Tag>) -> String { Self.id(value) }
    func encode<T: Encodable>(_ value: T) throws -> String { try Self.encode(value) }
    func decodeRoute(_ value: String) throws -> ModelRoute { try Self.decodeRoute(value) }
    func decodeRequest(_ value: String) throws -> CanonicalModelRequest { try Self.decodeRequest(value) }
    func executionIDValue(_ value: String) throws -> ExecutionID { try Self.executionIDValue(value) }
    func conversationIDValue(_ value: String) throws -> ConversationID { try Self.conversationIDValue(value) }
    func messageIDValue(_ value: String) throws -> MessageID { try Self.messageIDValue(value) }

    static func id<Tag>(_ value: EntityID<Tag>) -> String { value.rawValue.uuidString.lowercased() }
    static func workspace(_ row: Row) throws -> Workspace {
        guard let uuid = UUID(uuidString: row["id"] as String) else { throw MiraError(.storage, "资料库内容无效。") }
        return Workspace(id: WorkspaceID(uuid), name: row["name"] as String, background: row["background"] as String, allowsRemoteSend: (row["allows_remote_send"] as Int) != 0, revision: row["revision"] as Int)
    }
    static func conversation(_ row: Row) throws -> Conversation {
        guard let uuid = UUID(uuidString: row["id"] as String) else { throw MiraError(.storage, "资料库内容无效。") }
        let workspaceID = try (row["workspace_id"] as String?).map { value -> WorkspaceID in guard let value = UUID(uuidString: value) else { throw MiraError(.storage, "资料库内容无效。") }; return WorkspaceID(value) }
        return Conversation(id: ConversationID(uuid), workspaceID: workspaceID, title: row["title"] as String, isArchived: (row["is_archived"] as Int) != 0, createdAt: Date(timeIntervalSince1970: row["created_at"] as Double), updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double), revision: row["revision"] as Int)
    }
    static func message(_ row: Row) throws -> Message {
        guard let uuid = UUID(uuidString: row["id"] as String), let conversationUUID = UUID(uuidString: row["conversation_id"] as String), let role = MessageRole(rawValue: row["role"] as String), let status = MessageStatus(rawValue: row["status"] as String) else { throw MiraError(.storage, "资料库内容无效。") }
        let executionID = try (row["execution_id"] as String?).map { value -> ExecutionID in guard let value = UUID(uuidString: value) else { throw MiraError(.storage, "资料库内容无效。") }; return ExecutionID(value) }
        return Message(id: MessageID(uuid), conversationID: ConversationID(conversationUUID), executionID: executionID, sequence: row["sequence"] as Int, role: role, status: status, text: row["text"] as String, createdAt: Date(timeIntervalSince1970: row["created_at"] as Double))
    }
    static func execution(_ row: Row) throws -> Execution {
        guard let status = ExecutionStatus(rawValue: row["status"] as String) else { throw MiraError(.storage, "资料库内容无效。") }
        let retryID = try (row["retry_of_execution_id"] as String?).map { value -> ExecutionID in guard let value = UUID(uuidString: value) else { throw MiraError(.storage, "资料库内容无效。") }; return ExecutionID(value) }
        return Execution(id: ExecutionID(try uuid(row["id"] as String)), conversationID: ConversationID(try uuid(row["conversation_id"] as String)), triggerMessageID: MessageID(try uuid(row["trigger_message_id"] as String)), retryOfExecutionID: retryID, status: status, route: try decodeRoute(row["route_json"] as String), usage: TokenUsage(inputTokens: row["usage_input"] as Int?, outputTokens: row["usage_output"] as Int?), error: (row["error_json"] as String?).flatMap { try? decode($0) }, createdAt: Date(timeIntervalSince1970: row["created_at"] as Double), updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double))
    }
    static func uuid(_ value: String) throws -> UUID { guard let value = UUID(uuidString: value) else { throw MiraError(.storage, "资料库内容无效。") }; return value }
    static func executionIDValue(_ value: String) throws -> ExecutionID { ExecutionID(try uuid(value)) }
    static func conversationIDValue(_ value: String) throws -> ConversationID { ConversationID(try uuid(value)) }
    static func messageIDValue(_ value: String) throws -> MessageID { MessageID(try uuid(value)) }

    static func modelAttempt(_ row: Row) throws -> ModelAttempt {
        let attemptID = try uuid(row["id"] as String)
        let executionID = try executionIDValue(row["execution_id"] as String)
        let stepID = try uuid(row["step_id"] as String)
        guard let status = AttemptStatus(rawValue: row["status"] as String) else { throw MiraError(.storage, "资料库模型尝试状态无效。") }
        var attempt = ModelAttempt(id: attemptID, executionID: executionID, stepID: stepID, stepIndex: row["step_index"] as Int, attemptIndex: row["attempt_index"] as Int, request: try decodeRequest(row["request_json"] as String), createdAt: Date(timeIntervalSince1970: row["created_at"] as Double))
        attempt.status = status
        attempt.output = try (row["output_json"] as String?).map { try decode($0) }
        attempt.usage = TokenUsage(inputTokens: row["usage_input"] as Int?, outputTokens: row["usage_output"] as Int?)
        attempt.error = try (row["error_json"] as String?).map { try decode($0) }
        attempt.completedAt = (row["completed_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        return attempt
    }

    static func toolInvocation(_ row: Row) throws -> ToolInvocation {
        let id = try uuid(row["id"] as String)
        let attemptID = try uuid(row["attempt_id"] as String)
        let call = CanonicalToolCall(id: row["provider_call_id"] as String, name: row["tool_name"] as String, arguments: row["arguments_json"] as String)
        let status = row["status"] as String
        guard ToolResultStatus(rawValue: status) != nil else {
            guard status == "pending" || status == "dispatched" else { throw MiraError(.storage, "资料库工具调用状态无效。") }
            return ToolInvocation(id: id, attemptID: attemptID, modelOrder: row["model_order"] as Int, call: call, result: nil, dispatchedAt: (row["dispatched_at"] as Double?).map(Date.init(timeIntervalSince1970:)), completedAt: nil)
        }
        guard let resultJSON = row["result_json"] as String?,
              let result: ToolResult = try? decode(resultJSON),
              result.status.rawValue == status else { throw MiraError(.storage, "资料库工具结果无效。") }
        return ToolInvocation(id: id, attemptID: attemptID, modelOrder: row["model_order"] as Int, call: call, result: result, dispatchedAt: (row["dispatched_at"] as Double?).map(Date.init(timeIntervalSince1970:)), completedAt: (row["completed_at"] as Double?).map(Date.init(timeIntervalSince1970:)))
    }

    static func validateBackupMetadata(in db: Database, version: Int) throws {
        let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        let expectedMigrations = version == 1 ? [legacyMigrationName] : [legacyMigrationName, auditMigrationName]
        guard migrations == expectedMigrations else { throw MiraError(.unsupported, "备份包含未知资料库迁移。") }
        let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        let expectedTables: Set<String> = version == 1
            ? ["grdb_migrations", "workspaces", "conversations", "routes", "executions", "messages", "assistant_drafts"]
            : ["grdb_migrations", "workspaces", "conversations", "routes", "executions", "messages", "assistant_drafts", "execution_steps", "model_attempts", "tool_invocations"]
        guard Set(tables) == expectedTables else { throw MiraError(.unsupported, "备份包含未知资料库结构。") }
        let unexpectedProgrammableObjects = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('trigger', 'view')")
        guard unexpectedProgrammableObjects.isEmpty else { throw MiraError(.unsupported, "备份包含未知资料库对象。") }
    }

    static func validateContents(in db: Database) throws {
        for row in try Row.fetchAll(db, sql: "SELECT id, name, background, allows_remote_send, revision FROM workspaces") { _ = try workspace(row) }
        for row in try Row.fetchAll(db, sql: "SELECT id, workspace_id, title, is_archived, created_at, updated_at, revision FROM conversations") { _ = try conversation(row) }
        for row in try Row.fetchAll(db, sql: "SELECT route_json FROM routes") { _ = try decodeRoute(row["route_json"] as String) }
        for row in try Row.fetchAll(db, sql: "SELECT id, conversation_id, trigger_message_id, retry_of_execution_id, status, route_json, usage_input, usage_output, error_json, created_at, updated_at FROM executions") { _ = try execution(row) }
        for row in try Row.fetchAll(db, sql: "SELECT id, conversation_id, execution_id, sequence, role, status, text, created_at FROM messages") { _ = try message(row) }
        for row in try Row.fetchAll(db, sql: "SELECT execution_id, text, updated_at FROM assistant_drafts") { _ = try executionIDValue(row["execution_id"] as String) }
        for row in try Row.fetchAll(db, sql: "SELECT id, request_json FROM executions WHERE request_json IS NOT NULL") {
            let executionID = try executionIDValue(row["id"] as String)
            let request = try decodeRequest(row["request_json"] as String)
            guard request.executionID == executionID else { throw MiraError(.storage, "资料库请求内容无效。") }
        }
        if try Int.fetchOne(db, sql: "PRAGMA user_version") == 2 {
            for row in try Row.fetchAll(db, sql: "SELECT id, execution_id, step_id, step_index, attempt_index, request_json, status, output_json, usage_input, usage_output, error_json, created_at, completed_at FROM model_attempts") {
                let attempt = try modelAttempt(row)
                guard attempt.request.executionID == attempt.executionID,
                      attempt.request.requestID == attempt.id,
                      !(attempt.status == .prepared && attempt.output != nil),
                      !(attempt.status == .prepared && attempt.completedAt != nil) else { throw MiraError(.storage, "资料库审计请求身份无效。") }
                let rows = try Row.fetchAll(db, sql: "SELECT id, attempt_id, model_order, provider_call_id, tool_name, arguments_json, status, result_json, dispatched_at, completed_at FROM tool_invocations WHERE attempt_id = ? ORDER BY model_order, rowid", arguments: [attempt.id.uuidString.lowercased()])
                let storedInvocations = try rows.map { try toolInvocation($0) }
                let expectedCalls = attempt.output?.toolCalls ?? []
                guard storedInvocations.count == expectedCalls.count,
                      storedInvocations.enumerated().allSatisfy({ index, invocation in
                          invocation.attemptID == attempt.id && invocation.modelOrder == index && invocation.call == expectedCalls[index]
                      }) else { throw MiraError(.storage, "资料库模型调用与工具审计不匹配。") }
            }
            for row in try Row.fetchAll(db, sql: "SELECT id, attempt_id, model_order, provider_call_id, tool_name, arguments_json, status, result_json, dispatched_at, completed_at FROM tool_invocations") {
                let invocation = try toolInvocation(row)
                let storedAttemptID = try uuid(row["attempt_id"] as String)
                let status = row["status"] as String
                let dispatched = row["dispatched_at"] as Double?
                let validDispatchState = (status == "pending" || status == "invalidArguments" || status == "notFound" || status == "cancelledBeforeDispatch") ? dispatched == nil :
                    (status == "dispatched" || status == "succeeded" || status == "cancelled" || status == "interrupted") ? dispatched != nil :
                    (status == "denied" || status == "timedOut" || status == "failed" || status == "outputLimit")
                guard invocation.attemptID == storedAttemptID, validDispatchState else { throw MiraError(.storage, "资料库工具调用关联无效。") }
            }
            // Ensure the structural constraints that are not represented by a
            // Codable payload also hold for hand-edited/older files.
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM execution_steps WHERE sequence < 0 OR state NOT IN ('running','waitingForTool','completed','failed','interrupted') LIMIT 1") == nil,
                  try Int.fetchOne(db, sql: "SELECT 1 FROM execution_steps WHERE sequence = 0 LIMIT 1") == nil,
                  try Int.fetchOne(db, sql: "SELECT 1 FROM execution_steps WHERE (state IN ('running','waitingForTool') AND completed_at IS NOT NULL) OR (state IN ('completed','failed','interrupted') AND completed_at IS NULL) LIMIT 1") == nil,
                  try Int.fetchOne(db, sql: "SELECT 1 FROM model_attempts WHERE request_json IS NULL OR step_index < 0 OR attempt_index <= 0 LIMIT 1") == nil,
                  try Int.fetchOne(db, sql: "SELECT 1 FROM tool_invocations WHERE provider_call_id = '' OR tool_name = '' OR model_order < 0 LIMIT 1") == nil else {
                throw MiraError(.storage, "资料库审计内容无效。")
            }
        }
    }
}
