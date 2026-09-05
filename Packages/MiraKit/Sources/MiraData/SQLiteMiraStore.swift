import Foundation
import GRDB
import MiraCore

/// The first on-disk implementation of `MiraStore`.
///
/// The store deliberately exposes synchronous operations.  Its owning application
/// actor is responsible for keeping these bounded operations off view tasks.
public final class SQLiteMiraStore: MiraStore, @unchecked Sendable {
    private static let currentSchemaVersion = 1
    private static let migrationName = "m0_core"
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
            guard let value = try String.fetchOne(db, sql: "SELECT request_json FROM executions WHERE id = ?", arguments: [id(executionID)]) else { return nil }
            return try decodeRequest(value)
        }}
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
                guard let execution = try Row.fetchOne(db, sql: "SELECT conversation_id FROM executions WHERE id = ?", arguments: [id(executionID)]) else { throw MiraError(.notFound, "执行不存在。") }
                try db.execute(sql: "UPDATE executions SET status = ?, usage_input = ?, usage_output = ?, error_json = ?, updated_at = ? WHERE id = ? AND status IN ('queued', 'waitingForModel')", arguments: [status.rawValue, usage.inputTokens, usage.outputTokens, error.map(Self.encodeStoredError), at.timeIntervalSince1970, id(executionID)])
                guard db.changesCount > 0 else { return false }
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
                    if db.changesCount > 0, let draft {
                        let already = try Int.fetchOne(db, sql: "SELECT 1 FROM messages WHERE execution_id = ? AND role = 'assistant' LIMIT 1", arguments: [id(executionID)])
                        if already == nil {
                            let sequence = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence), 0) + 1 FROM messages WHERE conversation_id = ?", arguments: [id(conversationID)]) ?? 1)
                            try db.execute(sql: "INSERT INTO messages (id, conversation_id, execution_id, sequence, role, status, text, created_at) VALUES (?, ?, ?, ?, 'assistant', 'interrupted', ?, ?)", arguments: [id(EntityID<MessageTag>()), id(conversationID), id(executionID), sequence, draft["text"] as String, at.timeIntervalSince1970])
                        }
                        try db.execute(sql: "DELETE FROM assistant_drafts WHERE execution_id = ?", arguments: [id(executionID)])
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
                    guard (try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0) == Self.currentSchemaVersion else { throw MiraError(.unsupported, "备份版本不受当前恢复器支持。") }
                    // Check constraints and indexes as well as names before typed row decoding.
                    // A forged or damaged same-version schema must not bypass runtime invariants.
                    guard try Self.schemaSignature(in: db) == expectedSchema else { throw MiraError(.unsupported, "备份结构或约束与当前版本不符。") }
                    guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok" else { throw MiraError(.storage, "备份校验失败。") }
                    let foreign = try String.fetchOne(db, sql: "PRAGMA foreign_key_check") ?? ""
                    guard foreign.isEmpty else { throw MiraError(.storage, "备份关系校验失败。") }
                    let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
                    let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
                    let expectedTables: Set<String> = ["grdb_migrations", "workspaces", "conversations", "routes", "executions", "messages", "assistant_drafts"]
                    guard !migrations.isEmpty, migrations.allSatisfy({ $0 == Self.migrationName }), Set(tables) == expectedTables else { throw MiraError(.unsupported, "备份包含未知资料库结构。") }
                    let unexpectedProgrammableObjects = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('trigger', 'view')")
                    guard unexpectedProgrammableObjects.isEmpty else { throw MiraError(.unsupported, "备份包含未知资料库对象。") }
                    try Self.validateContents(in: db)
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
        var migrator = DatabaseMigrator()
        migrator.registerMigration(migrationName) { db in
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
    }
}
