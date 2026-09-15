import Foundation

/// Absence and deliberate retention cleanup are distinct from an unreadable or corrupt payload.
/// Storage failures throw; they never become an empty message.
public enum SessionTextContent: Sendable, Equatable {
    case available(String)
    case absent
    case purged

    public var text: String? {
        if case .available(let text) = self { text } else { nil }
    }
}

public struct SessionQueryItem: Sendable, Equatable, Identifiable {
    public var id: ConversationID { summary.id }
    public let summary: SessionSummary
    public let title: SessionTextContent
    public init(summary: SessionSummary, title: SessionTextContent) {
        self.summary = summary
        self.title = title
    }
}

public struct SessionQueryMessage: Sendable, Equatable, Identifiable {
    public var id: MessageID { summary.id }
    public let summary: SessionMessageSummary
    public let body: SessionTextContent
    public let thinking: SessionTextContent
    public init(summary: SessionMessageSummary, body: SessionTextContent, thinking: SessionTextContent) {
        self.summary = summary
        self.body = body
        self.thinking = thinking
    }
}

/// Metadata comes from one projection transaction. Content was read under the same
/// library access lease and remains subject to invalidation after delivery to a host.
public struct SessionQueryMessagePage: Sendable, Equatable {
    public let session: SessionQueryItem?
    public let messages: [SessionQueryMessage]
    public let executions: [SessionExecutionSummary]
    public let hasMore: Bool
    public init(
        session: SessionQueryItem?, messages: [SessionQueryMessage],
        executions: [SessionExecutionSummary], hasMore: Bool
    ) {
        self.session = session
        self.messages = messages
        self.executions = executions
        self.hasMore = hasMore
    }
}

/// A persisted draft at a captured journal prefix. It excludes private provider
/// continuation/transcript data and is not a live token notification channel.
public struct SessionQueryDraft: Sendable, Equatable {
    public let head: SessionJournalHead
    public let executionID: ExecutionID
    public let answer: String
    public let thinking: String
    public init(head: SessionJournalHead, executionID: ExecutionID, answer: String, thinking: String) {
        self.head = head
        self.executionID = executionID
        self.answer = answer
        self.thinking = thinking
    }
}
