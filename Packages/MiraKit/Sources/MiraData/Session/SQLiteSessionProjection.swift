import Foundation
import GRDB
import MiraCore

/// A disposable metadata cache. Its serial queue owns all database access and closure.
public final class SQLiteSessionProjection: SessionProjectionStore, @unchecked Sendable {
    private let database: DatabaseQueue
    private let io = DispatchQueue(label: "mira.session-projection", qos: .utility)
    private var closed = false

    public init(path: String) throws {
        do {
            database = try DatabaseQueue(path: path)
            try database.write(Self.initialize)
        } catch { throw Self.safe(error) }
    }

    public func head(sessionID: ConversationID) async throws -> SessionJournalHead? {
        try await read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT head_sequence, head_batch_id FROM projection_sessions WHERE session_id = ?",
                                            arguments: [Self.id(sessionID)]) else { return nil }
            return try Self.head(row, sessionID: sessionID)
        }
    }

    public func apply(_ batch: SessionBatch) async throws {
        try batch.validate()
        let bytes = try SessionCodec.encode(batch)
        guard bytes.count <= SessionFormatLimits.maximumBatchBytes else { throw Self.invalidData }
        let digest = FileSessionIO.digest(bytes)
        try await write { db in
            let session = Self.id(batch.sessionID)
            if let old = try Row.fetchOne(db, sql: "SELECT digest FROM projection_batches WHERE session_id = ? AND batch_id = ?",
                                         arguments: [session, batch.id.uuidString]) {
                guard old["digest"] as String == digest else {
                    throw MiraError(.conflict, "The projection batch identity conflicts.")
                }
                return
            }
            let current = try Int64.fetchOne(db, sql: "SELECT head_sequence FROM projection_sessions WHERE session_id = ?",
                                            arguments: [session]) ?? 0
            guard batch.expectedSequence == current else { throw MiraError(.conflict, "The projection batch sequence is stale.") }
            if current == 0 {
                guard case .opened = batch.events.first?.fact else { throw Self.invalidData }
            }
            // DatabaseQueue.write owns this entire transaction, including the precondition reads.
            try db.execute(sql: "INSERT INTO projection_batches(session_id, batch_id, sequence, digest) VALUES (?, ?, ?, ?)",
                           arguments: [session, batch.id.uuidString, batch.cursor.sequence, digest])
            for event in batch.events {
                try Self.reduce(event, sessionID: batch.sessionID, batchID: batch.id, in: db)
            }
            try db.execute(sql: "UPDATE projection_sessions SET head_sequence = ?, head_batch_id = ? WHERE session_id = ?",
                           arguments: [batch.cursor.sequence, batch.id.uuidString, session])
            try Self.requireChangedRow(db)
        }
    }

    public func reset(sessionID: ConversationID) async throws {
        try await write { db in
            for table in Self.tables {
                try db.execute(sql: "DELETE FROM \(table) WHERE session_id = ?", arguments: [Self.id(sessionID)])
            }
        }
    }

    public func session(id: ConversationID) async throws -> SessionSummary? {
        try await read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM projection_sessions WHERE session_id = ?", arguments: [Self.id(id)])
                .map { try Self.summary($0, in: db) }
        }
    }

    public func sessions(scope: SessionQueryScope, includeArchived: Bool, after: SessionListCursor?, limit: Int) async throws -> [SessionSummary] {
        try Self.validatePage(limit, beforeSequence: nil)
        guard after?.updatedAt.timeIntervalSince1970.isFinite != false else { throw Self.invalidCursor }
        return try await read { db in
            var sql = "SELECT * FROM projection_sessions WHERE 1 = 1"
            var arguments: StatementArguments = []
            if !includeArchived { sql += " AND archived = 0" }
            switch scope {
            case .all: break
            case .inbox: sql += " AND workspace_id IS NULL"
            case .workspace(let workspace): sql += " AND workspace_id = ?"; arguments += [Self.id(workspace)]
            }
            if let after {
                sql += " AND (updated_at < ? OR (updated_at = ? AND session_id > ?))"
                arguments += [after.updatedAt.timeIntervalSince1970, after.updatedAt.timeIntervalSince1970, Self.id(after.sessionID)]
            }
            sql += " ORDER BY updated_at DESC, session_id ASC LIMIT ?"; arguments += [limit]
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { try Self.summary($0, in: db) }
        }
    }

    public func messages(sessionID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> [SessionMessageSummary] {
        try Self.validatePage(limit, beforeSequence: beforeSequence)
        return try await read { db in
            let (sql, arguments) = Self.page(table: "projection_messages", sessionID: sessionID, before: beforeSequence, limit: limit)
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { try Self.message($0, sessionID: sessionID) }
        }
    }

    public func messagePage(sessionID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> SessionProjectionMessagePage {
        try Self.validatePage(limit, beforeSequence: beforeSequence)
        return try await read { db in
            guard let sessionRow = try Row.fetchOne(db, sql: "SELECT * FROM projection_sessions WHERE session_id = ?",
                                                    arguments: [Self.id(sessionID)]) else {
                return .init(session: nil, messages: [], executions: [], hasMore: false)
            }

            let (sql, arguments) = Self.page(table: "projection_messages", sessionID: sessionID,
                                             before: beforeSequence, limit: limit + 1)
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            let hasMore = rows.count > limit
            let messages = try rows.prefix(limit).map { try Self.message($0, sessionID: sessionID) }
            let session = try Self.summary(sessionRow, in: db)

            var executionIDs = Set(messages.map { Self.id($0.executionID) })
            if let activeExecutionID = session.activeExecutionID {
                executionIDs.insert(Self.id(activeExecutionID))
            }
            if let latestExecutionID = session.latestExecutionID {
                executionIDs.insert(Self.id(latestExecutionID))
            }
            guard !executionIDs.isEmpty else {
                return .init(session: session, messages: messages, executions: [], hasMore: hasMore)
            }
            let placeholders = Array(repeating: "?", count: executionIDs.count).joined(separator: ", ")
            var executionArguments: StatementArguments = [Self.id(sessionID)]
            for executionID in executionIDs { executionArguments += [executionID] }
            let executionRows = try Row.fetchAll(db,
                sql: "SELECT * FROM projection_executions WHERE session_id = ? AND execution_id IN (\(placeholders)) ORDER BY sequence DESC, execution_id ASC",
                arguments: executionArguments)
            guard executionRows.count == executionIDs.count else { throw Self.invalidData }
            let executions = try executionRows.map { try Self.execution($0, sessionID: sessionID) }
            return .init(session: session, messages: messages, executions: executions, hasMore: hasMore)
        }
    }

    public func executions(sessionID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> [SessionExecutionSummary] {
        try Self.validatePage(limit, beforeSequence: beforeSequence)
        return try await read { db in
            let (sql, arguments) = Self.page(table: "projection_executions", sessionID: sessionID, before: beforeSequence, limit: limit)
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { try Self.execution($0, sessionID: sessionID) }
        }
    }

    public func close() async throws {
        try await perform {
            guard !self.closed else { return }
            try self.database.close()
            self.closed = true
        }
    }

    private func read<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await perform { try self.requireOpen(); return try self.database.read(body) }
    }
    private func write<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await perform { try self.requireOpen(); return try self.database.write(body) }
    }
    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            io.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: Self.safe(error)) }
            }
        }
    }
    private func requireOpen() throws {
        guard !closed else { throw MiraError(.cancelled, "The session projection is closed.") }
    }

    private static let tables = ["projection_sessions", "projection_batches", "projection_executions", "projection_messages"]
    private static func initialize(_ db: Database) throws {
        let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        if version == 1 {
            guard try tables.allSatisfy({ try db.tableExists($0) }) else { throw invalidData }
            return
        }
        guard version == 0, try tables.allSatisfy({ try !db.tableExists($0) }) else {
            throw MiraError(.unsupported, "The session projection schema is unsupported.")
        }
        try db.execute(sql: """
            CREATE TABLE projection_sessions (
                session_id TEXT PRIMARY KEY, workspace_id TEXT, title_json BLOB NOT NULL,
                revision INTEGER NOT NULL CHECK(revision > 0), archived INTEGER NOT NULL CHECK(archived IN (0, 1)),
                created_at REAL NOT NULL, updated_at REAL NOT NULL, active_execution_id TEXT,
                head_sequence INTEGER NOT NULL CHECK(head_sequence > 0), head_batch_id TEXT NOT NULL
            );
            CREATE TABLE projection_batches (
                session_id TEXT NOT NULL, batch_id TEXT NOT NULL, sequence INTEGER NOT NULL, digest TEXT NOT NULL,
                PRIMARY KEY(session_id, batch_id), UNIQUE(session_id, sequence)
            );
            CREATE TABLE projection_executions (
                session_id TEXT NOT NULL, execution_id TEXT NOT NULL, admission_json BLOB NOT NULL,
                sequence INTEGER NOT NULL, admitted_at REAL NOT NULL, phase TEXT NOT NULL, completion_json BLOB,
                PRIMARY KEY(session_id, execution_id)
            );
            CREATE TABLE projection_messages (
                session_id TEXT NOT NULL, message_id TEXT NOT NULL, execution_id TEXT NOT NULL, role TEXT NOT NULL,
                sequence INTEGER NOT NULL, occurred_at REAL NOT NULL, body_json BLOB, thinking_json BLOB,
                PRIMARY KEY(session_id, message_id), UNIQUE(session_id, sequence)
            );
            CREATE INDEX projection_sessions_order ON projection_sessions(updated_at DESC, session_id ASC);
            CREATE INDEX projection_sessions_workspace ON projection_sessions(workspace_id, updated_at DESC, session_id ASC);
            CREATE INDEX projection_messages_order ON projection_messages(session_id, sequence DESC);
            CREATE INDEX projection_executions_order ON projection_executions(session_id, sequence DESC);
            PRAGMA user_version = 1;
            """)
    }

    private static func reduce(_ event: SessionEvent, sessionID: ConversationID, batchID: UUID, in db: Database) throws {
        let session = id(sessionID), time = event.occurredAt.timeIntervalSince1970
        switch event.fact {
        case .opened(let value):
            try db.execute(sql: """
                INSERT INTO projection_sessions(session_id, workspace_id, title_json, revision, archived,
                    created_at, updated_at, head_sequence, head_batch_id) VALUES (?, ?, ?, 1, 0, ?, ?, ?, ?)
                """, arguments: [session, value.workspaceID.map(id), try SessionCodec.encode(value.title), time, time, event.sequence, batchID.uuidString])
        case .modelSelectionChanged:
            // Selection intent is journal authority. The projection intentionally
            // does not write or resolve a second selection binding.
            break
        case .renamed(let title, let revision):
            guard revision > 1 else { throw invalidData }
            try db.execute(sql: "UPDATE projection_sessions SET title_json = ?, revision = ? WHERE session_id = ? AND revision = ? AND archived = 0",
                           arguments: [try SessionCodec.encode(title), revision, session, revision - 1])
            try requireChangedRow(db)
        case .archived(let revision):
            guard revision > 1 else { throw invalidData }
            try db.execute(sql: "UPDATE projection_sessions SET archived = 1, revision = ? WHERE session_id = ? AND revision = ? AND archived = 0 AND active_execution_id IS NULL",
                           arguments: [revision, session, revision - 1])
            try requireChangedRow(db)
        case .admitted(let value):
            try db.execute(sql: "UPDATE projection_sessions SET active_execution_id = ? WHERE session_id = ? AND active_execution_id IS NULL AND archived = 0",
                           arguments: [id(value.executionID), session])
            try requireChangedRow(db)
            try db.execute(sql: """
                INSERT INTO projection_executions(session_id, execution_id, admission_json, sequence, admitted_at, phase)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [session, id(value.executionID), try SessionCodec.encode(value), event.sequence, time, ExecutionPhase.queued.rawValue])
            if let body = value.userBody {
                try insertMessage(id: value.userMessageID, executionID: value.executionID, role: .user,
                                  body: body, thinking: nil, event: event, sessionID: sessionID, in: db)
            }
        case .phaseChanged(let executionID, let phase):
            try setPhase(phase, executionID: executionID, sessionID: sessionID, in: db)
        case .attemptStarted(let attempt):
            try setPhase(.waitingForModel, executionID: attempt.executionID, sessionID: sessionID, in: db)
        case .finished(let completion):
            try db.execute(sql: "UPDATE projection_executions SET completion_json = ? WHERE session_id = ? AND execution_id = ? AND completion_json IS NULL",
                           arguments: [try SessionCodec.encode(completion), session, id(completion.executionID)])
            try requireChangedRow(db)
            if let message = completion.assistantMessageID {
                try insertMessage(id: message, executionID: completion.executionID, role: .assistant,
                                  body: completion.answer, thinking: completion.visibleThinking, event: event, sessionID: sessionID, in: db)
            }
            try db.execute(sql: "UPDATE projection_sessions SET active_execution_id = NULL WHERE session_id = ? AND active_execution_id = ?",
                           arguments: [session, id(completion.executionID)])
            try requireChangedRow(db)
        case .retrySuperseded(let value):
            // A retry replaces the prior assistant presentation for the same user turn.
            // The canonical journal retains both executions for audit and recovery; the
            // disposable projection keeps the user row and removes only the superseded
            // assistant row. A source execution without visible output is a valid no-op.
            try db.execute(
                sql: "DELETE FROM projection_messages WHERE session_id = ? AND execution_id = ? AND role = ?",
                arguments: [session, id(value.sourceExecutionID), SessionMessageRole.assistant.rawValue])
        case .attemptResolved, .toolProposed, .toolPrepared, .toolApprovalRequested, .toolApprovalResolved,
             .toolDispatched, .toolResolved, .extensionRecorded: break
        }
        try db.execute(sql: "UPDATE projection_sessions SET updated_at = MAX(updated_at, ?) WHERE session_id = ?", arguments: [time, session])
        try requireChangedRow(db)
    }

    private static func setPhase(_ phase: ExecutionPhase, executionID: ExecutionID, sessionID: ConversationID, in db: Database) throws {
        try db.execute(sql: "UPDATE projection_executions SET phase = ? WHERE session_id = ? AND execution_id = ? AND completion_json IS NULL",
                       arguments: [phase.rawValue, id(sessionID), id(executionID)])
        try requireChangedRow(db)
    }
    private static func insertMessage(id messageID: MessageID, executionID: ExecutionID, role: SessionMessageRole,
        body: SessionContent?, thinking: SessionContent?, event: SessionEvent, sessionID: ConversationID, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO projection_messages(session_id, message_id, execution_id, role, sequence, occurred_at, body_json, thinking_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id(sessionID), id(messageID), id(executionID), role.rawValue, event.sequence,
                              event.occurredAt.timeIntervalSince1970, try body.map(SessionCodec.encode), try thinking.map(SessionCodec.encode)])
    }
    private static func requireChangedRow(_ db: Database) throws { guard db.changesCount == 1 else { throw invalidData } }
    private static func page(table: String, sessionID: ConversationID, before: Int64?, limit: Int) -> (String, StatementArguments) {
        var sql = "SELECT * FROM \(table) WHERE session_id = ?", arguments: StatementArguments = [id(sessionID)]
        if let before { sql += " AND sequence < ?"; arguments += [before] }
        sql += " ORDER BY sequence DESC LIMIT ?"; arguments += [limit]
        return (sql, arguments)
    }
    private static func validatePage(_ limit: Int, beforeSequence: Int64?) throws {
        guard (1...128).contains(limit) else { throw MiraError(.invalidInput, "The projection page size is invalid.") }
        guard beforeSequence.map({ $0 >= 0 }) ?? true else { throw invalidCursor }
    }

    private static func summary(_ row: Row, in db: Database) throws -> SessionSummary {
        let sessionID = ConversationID(try uuid(row["session_id"]))
        let title: SessionContent = try decode(row["title_json"])
        try validate(title, sessionID: sessionID)
        let latestExecutionID = try Row.fetchOne(
            db,
            sql: "SELECT execution_id FROM projection_executions WHERE session_id = ? ORDER BY sequence DESC, execution_id ASC LIMIT 1",
            arguments: [id(sessionID)]
        ).map { try ExecutionID(uuid($0["execution_id"])) }
        return .init(id: sessionID, workspaceID: try (row["workspace_id"] as String?).map { WorkspaceID(try uuid($0)) },
            title: title, revision: row["revision"], isArchived: row["archived"] as Int == 1,
            createdAt: try date(row["created_at"]), updatedAt: try date(row["updated_at"]),
            activeExecutionID: try (row["active_execution_id"] as String?).map { ExecutionID(try uuid($0)) },
            latestExecutionID: latestExecutionID, head: try head(row, sessionID: sessionID))
    }
    private static func head(_ row: Row, sessionID: ConversationID) throws -> SessionJournalHead {
        let head = SessionJournalHead(cursor: .init(sessionID: sessionID, sequence: row["head_sequence"]), batchID: try uuid(row["head_batch_id"]))
        try head.validate()
        return head
    }
    private static func message(_ row: Row, sessionID: ConversationID) throws -> SessionMessageSummary {
        let body: SessionContent? = try decodeOptional(row["body_json"])
        let thinking: SessionContent? = try decodeOptional(row["thinking_json"])
        if let body { try validate(body, sessionID: sessionID) }
        if let thinking { try validate(thinking, sessionID: sessionID) }
        guard let role = SessionMessageRole(rawValue: row["role"]) else { throw invalidData }
        let executionID = ExecutionID(try uuid(row["execution_id"]))
        return .init(id: MessageID(try uuid(row["message_id"])), sessionID: sessionID, executionID: executionID, role: role,
            sequence: row["sequence"], occurredAt: try date(row["occurred_at"]), body: body, thinking: thinking)
    }
    private static func execution(_ row: Row, sessionID: ConversationID) throws -> SessionExecutionSummary {
        guard let phase = ExecutionPhase(rawValue: row["phase"]) else { throw invalidData }
        let admission: SessionAdmission = try decode(row["admission_json"])
        guard admission.executionID.rawValue == (try uuid(row["execution_id"])) else { throw invalidData }
        let completion: SessionCompletion? = try decodeOptional(row["completion_json"])
        guard completion.map({ $0.executionID == admission.executionID }) ?? true else { throw invalidData }
        try validate(admission.plan, sessionID: sessionID)
        return .init(sessionID: sessionID, admission: admission, sequence: row["sequence"], admittedAt: try date(row["admitted_at"]),
                     phase: phase, completion: completion)
    }
    private static func validate(_ reference: SessionContent, sessionID: ConversationID) throws {
        try reference.validate()
    }
    private static func uuid(_ value: String) throws -> UUID { guard let result = UUID(uuidString: value) else { throw invalidData }; return result }
    private static func date(_ value: Double) throws -> Date { guard value.isFinite else { throw invalidData }; return Date(timeIntervalSince1970: value) }
    private static func id<Tag>(_ value: EntityID<Tag>) -> String { value.rawValue.uuidString }
    private static func decode<T: Decodable>(_ data: Data) throws -> T { try SessionCodec.decode(T.self, from: data) }
    private static func decodeOptional<T: Decodable>(_ data: Data?) throws -> T? {
        guard let data else { return nil }
        return try decode(data)
    }
    private static func safe(_ error: any Error) -> MiraError { (error as? MiraError) ?? invalidData }
    private static var invalidData: MiraError { .init(.storage, "The session projection data is invalid or unavailable.") }
    private static var invalidCursor: MiraError { .init(.invalidInput, "The session projection cursor is invalid.") }
}
