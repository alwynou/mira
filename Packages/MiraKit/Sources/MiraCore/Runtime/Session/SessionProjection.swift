import Foundation

/// Query values are disposable metadata, never execution eligibility or business authorization.
public struct SessionSummary: Sendable, Equatable, Identifiable {
    public let id: ConversationID
    public let workspaceID: WorkspaceID?
    public let title: SessionContent
    public let revision: Int
    public let isArchived: Bool
    public let createdAt: Date
    public let updatedAt: Date
    public let activeExecutionID: ExecutionID?
    public let latestExecutionID: ExecutionID?
    public let head: SessionJournalHead

    public init(id: ConversationID, workspaceID: WorkspaceID?, title: SessionContent,
                revision: Int, isArchived: Bool, createdAt: Date, updatedAt: Date,
                activeExecutionID: ExecutionID?, latestExecutionID: ExecutionID?, head: SessionJournalHead) {
        self.id = id; self.workspaceID = workspaceID; self.title = title
        self.revision = revision; self.isArchived = isArchived; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.activeExecutionID = activeExecutionID; self.latestExecutionID = latestExecutionID; self.head = head
    }
}

public struct SessionListCursor: Sendable, Equatable {
    public let updatedAt: Date
    public let sessionID: ConversationID
    public init(updatedAt: Date, sessionID: ConversationID) { self.updatedAt = updatedAt; self.sessionID = sessionID }
}

public enum SessionQueryScope: Sendable, Equatable {
    case all, inbox, workspace(WorkspaceID)
}

public enum SessionMessageRole: String, Codable, Sendable { case user, assistant }

/// Body references remain subject to the payload store's current retention checks.
public struct SessionMessageSummary: Sendable, Equatable, Identifiable {
    public let id: MessageID
    public let sessionID: ConversationID
    public let executionID: ExecutionID
    public let role: SessionMessageRole
    public let sequence: Int64
    public let occurredAt: Date
    public let body: SessionContent?
    public let thinking: SessionContent?

    public init(id: MessageID, sessionID: ConversationID, executionID: ExecutionID, role: SessionMessageRole,
                sequence: Int64, occurredAt: Date, body: SessionContent?, thinking: SessionContent?) {
        self.id = id; self.sessionID = sessionID; self.executionID = executionID; self.role = role
        self.sequence = sequence; self.occurredAt = occurredAt; self.body = body; self.thinking = thinking
    }
}

public struct SessionExecutionSummary: Sendable, Equatable, Identifiable {
    public var id: ExecutionID { admission.executionID }
    public let sessionID: ConversationID
    public let admission: SessionAdmission
    public let sequence: Int64
    public let admittedAt: Date
    public let phase: ExecutionPhase
    public let completion: SessionCompletion?

    public init(sessionID: ConversationID, admission: SessionAdmission, sequence: Int64, admittedAt: Date,
                phase: ExecutionPhase, completion: SessionCompletion?) {
        self.sessionID = sessionID; self.admission = admission; self.sequence = sequence; self.admittedAt = admittedAt
        self.phase = phase; self.completion = completion
    }
}

/// Metadata captured in one projection read transaction. Execution summaries include
/// every execution referenced by the page, the latest admitted execution, and the active execution, if any.
/// A retry replaces the prior assistant row for one user turn in the disposable
/// projection; executions retain distinct audit identities in the journal.
public struct SessionProjectionMessagePage: Sendable, Equatable {
    public let session: SessionSummary?
    public let messages: [SessionMessageSummary]
    public let executions: [SessionExecutionSummary]
    public let hasMore: Bool

    public init(session: SessionSummary?, messages: [SessionMessageSummary],
                executions: [SessionExecutionSummary], hasMore: Bool) {
        self.session = session; self.messages = messages; self.executions = executions; self.hasMore = hasMore
    }
}

/// No implementation may invoke a model, tool, domain handler, or completion consumer.
public protocol SessionProjectionStore: Sendable {
    func head(sessionID: ConversationID) async throws -> SessionJournalHead?
    /// Atomically advances rows and checkpoint. Identical batches are idempotent; gaps/conflicts fail.
    func apply(_ batch: SessionBatch) async throws
    /// Deletes only this session's derived rows and checkpoint, never canonical business data.
    func reset(sessionID: ConversationID) async throws
    func session(id: ConversationID) async throws -> SessionSummary?
    /// Descending updatedAt, then ascending session UUID. Cursor pagination is a live view.
    func sessions(scope: SessionQueryScope, includeArchived: Bool, after: SessionListCursor?, limit: Int) async throws -> [SessionSummary]
    /// Newest first; the next page uses the last row's sequence. A retry adds no second user message.
    func messages(sessionID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> [SessionMessageSummary]
    /// Captures header, page rows, linked/latest/active executions and pagination in one read snapshot.
    /// Every returned message's execution is linked in `executions`; latest and
    /// active executions are linked even when they have no message row yet.
    /// Newest first, at most 128 messages. A missing session returns an empty page.
    func messagePage(sessionID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> SessionProjectionMessagePage
    func executions(sessionID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> [SessionExecutionSummary]
    func close() async throws
}
