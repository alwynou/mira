import Foundation

public enum SessionSearchPart: String, Codable, Sendable { case title, user, assistant, thinking }

/// A local search location, not permission to replay content or send it to a model.
public struct SessionSearchLocation: Codable, Sendable, Equatable {
    public let sessionID: ConversationID
    public let messageID: MessageID?
    public let executionID: ExecutionID?
    public let part: SessionSearchPart
    public let sequence: Int64
    public let occurredAt: Date
    public let reference: SessionPayloadReference

    public init(
        sessionID: ConversationID, messageID: MessageID?, executionID: ExecutionID?,
        part: SessionSearchPart, sequence: Int64, occurredAt: Date, reference: SessionPayloadReference
    ) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.executionID = executionID
        self.part = part
        self.sequence = sequence
        self.occurredAt = occurredAt
        self.reference = reference
    }

    public func validate() throws {
        try reference.validate()
        let kind: SessionPayloadKind
        switch part {
        case .title: kind = .title
        case .user: kind = .userText
        case .assistant: kind = .visibleAnswer
        case .thinking: kind = .visibleThinking
        }
        guard sequence > 0, occurredAt.timeIntervalSince1970.isFinite,
            reference.sessionID == sessionID, reference.kind == kind,
            (part == .title) == (messageID == nil), (part == .title) == (executionID == nil)
        else {
            throw MiraError(.storage, "The session search location is invalid.")
        }
    }
}

public struct SessionSearchDocument: Codable, Sendable, Equatable {
    public let location: SessionSearchLocation
    public let text: String
    public init(location: SessionSearchLocation, text: String) {
        self.location = location
        self.text = text
    }
}

/// One complete source batch and its still-retained, explicitly visible text.
/// Missing documents are allowed only for content already purged at the indexer's fixed source head.
public struct SessionSearchUpdate: Codable, Sendable, Equatable {
    public let batch: SessionBatch
    public let documents: [SessionSearchDocument]
    public init(batch: SessionBatch, documents: [SessionSearchDocument]) {
        self.batch = batch
        self.documents = documents
    }
}

public struct SessionSearchCursor: Codable, Sendable, Equatable {
    public let indexID: UUID
    public let beforeRowID: Int64
    public let queryDigest: String
    public init(indexID: UUID, beforeRowID: Int64, queryDigest: String) {
        self.indexID = indexID
        self.beforeRowID = beforeRowID
        self.queryDigest = queryDigest
    }
}

public struct SessionSearchSelection: Sendable, Equatable {
    public let text: String
    public let scope: SessionQueryScope
    public let includeArchived: Bool
    public let since: Date?
    public let until: Date?
    public init(
        text: String, scope: SessionQueryScope = .all, includeArchived: Bool = false,
        since: Date? = nil, until: Date? = nil
    ) {
        self.text = text
        self.scope = scope
        self.includeArchived = includeArchived
        self.since = since
        self.until = until
    }
    public func validate() throws {
        guard !SessionSearchText.terms(text).isEmpty, text.unicodeScalars.count <= 500,
            since?.timeIntervalSince1970.isFinite != false, until?.timeIntervalSince1970.isFinite != false,
            since.map({ start in until.map { start <= $0 } ?? true }) ?? true
        else {
            throw MiraError(.invalidInput, "The session search query is invalid.")
        }
    }
}

public struct SessionSearchCapabilities: Sendable, Equatable {
    public let wordIndex: Bool
    public let substringIndex: Bool
    public init(wordIndex: Bool, substringIndex: Bool) {
        self.wordIndex = wordIndex
        self.substringIndex = substringIndex
    }
}

/// Cache matches contain only locations; snippets must be read again from current retained payloads.
public struct SessionSearchIndexPage: Sendable, Equatable {
    public let matches: [SessionSearchLocation]
    public let nextCursor: SessionSearchCursor?
    public let isTruncated: Bool
    public let scannedCandidates: Int
    public let capabilities: SessionSearchCapabilities
    public init(
        matches: [SessionSearchLocation], nextCursor: SessionSearchCursor?, isTruncated: Bool,
        scannedCandidates: Int, capabilities: SessionSearchCapabilities
    ) {
        self.matches = matches
        self.nextCursor = nextCursor
        self.isTruncated = isTruncated
        self.scannedCandidates = scannedCandidates
        self.capabilities = capabilities
    }
}

public struct SessionSearchHit: Sendable, Equatable {
    public let location: SessionSearchLocation
    public let snippet: String
    public let observedHead: SessionJournalHead
    public init(location: SessionSearchLocation, snippet: String, observedHead: SessionJournalHead) {
        self.location = location
        self.snippet = snippet
        self.observedHead = observedHead
    }
}

public struct SessionSearchPage: Sendable, Equatable {
    public let hits: [SessionSearchHit]
    public let nextCursor: SessionSearchCursor?
    public let isTruncated: Bool
    public let scannedCandidates: Int
    public let capabilities: SessionSearchCapabilities
    public init(
        hits: [SessionSearchHit], nextCursor: SessionSearchCursor?, isTruncated: Bool,
        scannedCandidates: Int, capabilities: SessionSearchCapabilities
    ) {
        self.hits = hits
        self.nextCursor = nextCursor
        self.isTruncated = isTruncated
        self.scannedCandidates = scannedCandidates
        self.capabilities = capabilities
    }
}

/// A disposable local index. Implementations never call models, tools or business consumers.
public protocol SessionSearchIndex: Sendable {
    func head(sessionID: ConversationID) async throws -> SessionJournalHead?
    /// Atomically applies visible documents, metadata, invalidations and the complete-batch cursor.
    func apply(_ update: SessionSearchUpdate) async throws
    /// Newest indexed documents first. Cursor binds query filters and this index's current identity.
    /// Scope/time/archive predicates precede a 20,000 candidate cap; deadline/cap exhaustion is explicit.
    func search(_ selection: SessionSearchSelection, after: SessionSearchCursor?, limit: Int) async throws
        -> SessionSearchIndexPage
    /// Maintenance calls only after all users drain. Removes the entire text cache including SQLite sidecars,
    /// then recreates an empty current-format index with a fresh identity. Failure remains retryable.
    func clear() async throws
    func verifyEmpty() async throws
    func close() async throws
}

public enum SessionSearchText {
    public static func normalize(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func terms(_ value: String) -> [String] {
        normalize(value).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
    public static func matches(_ value: String, query: String) -> Bool {
        let normalized = normalize(value)
        return terms(query).allSatisfy { normalized.contains($0) }
    }
    public static func snippet(_ value: String, query: String) -> String {
        let term = terms(query).first ?? ""
        let match =
            value.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])?.lowerBound
            ?? value.startIndex
        let start = value.index(match, offsetBy: -80, limitedBy: value.startIndex) ?? value.startIndex
        var result = ""
        var bytes = 0
        for scalar in value[start...].unicodeScalars {
            let text = String(scalar)
            guard bytes + text.utf8.count <= 1_200 else { break }
            result.append(text)
            bytes += text.utf8.count
        }
        return result
    }
}
