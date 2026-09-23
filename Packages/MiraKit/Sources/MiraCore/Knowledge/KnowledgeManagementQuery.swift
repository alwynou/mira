import Foundation

public enum KnowledgeManagementScope: Equatable, Sendable {
    case all
    case inbox
    case workspace(WorkspaceID)
}

public enum KnowledgeManagementStatus: String, CaseIterable, Sendable {
    case all
    case searchable
    case localOnly
    case needsAttention
}

public enum KnowledgeManagementOrder: String, CaseIterable, Sendable {
    case newestFirst
    case title
}

/// A keyset position bound to the filters and ordering that produced it.
public struct KnowledgeManagementCursor: Equatable, Sendable {
    public let updatedAt: Date?
    public let title: String?
    public let sourceID: KnowledgeSourceID
    public let queryKey: String

    public init(updatedAt: Date? = nil, title: String? = nil,
                sourceID: KnowledgeSourceID, queryKey: String) {
        self.updatedAt = updatedAt
        self.title = title
        self.sourceID = sourceID
        self.queryKey = queryKey
    }
}

public struct KnowledgeManagementQuery: Sendable {
    public var scope: KnowledgeManagementScope
    public var status: KnowledgeManagementStatus
    public var query: String
    public var order: KnowledgeManagementOrder
    public var limit: Int
    public var cursor: KnowledgeManagementCursor?

    public init(scope: KnowledgeManagementScope = .all,
                status: KnowledgeManagementStatus = .all,
                query: String = "",
                order: KnowledgeManagementOrder = .newestFirst,
                limit: Int = 100,
                cursor: KnowledgeManagementCursor? = nil) {
        self.scope = scope
        self.status = status
        self.query = query
        self.order = order
        self.limit = limit
        self.cursor = cursor
    }

    /// A stable opaque binding for a cursor. It deliberately excludes the page size.
    public var key: String {
        let scopeKey: String
        switch scope {
        case .all: scopeKey = "all"
        case .inbox: scopeKey = "inbox"
        case .workspace(let id): scopeKey = "workspace:\(id.rawValue.uuidString.lowercased())"
        }
        let value = [scopeKey, status.rawValue, query, order.rawValue].joined(separator: "\u{1f}")
        let hash = value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

public struct KnowledgeManagementItem: Identifiable, Sendable {
    public let source: KnowledgeSource
    public let currentVersion: KnowledgeSourceVersion?
    public let latestVersion: KnowledgeSourceVersion?
    public let versionCount: Int
    public let excerpt: String
    public let match: SourceChunkSummary?
    public var id: KnowledgeSourceID { source.id }

    public init(source: KnowledgeSource,
                currentVersion: KnowledgeSourceVersion?,
                latestVersion: KnowledgeSourceVersion?,
                versionCount: Int,
                excerpt: String,
                match: SourceChunkSummary?) {
        self.source = source
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.versionCount = versionCount
        self.excerpt = excerpt
        self.match = match
    }
}

public struct KnowledgeManagementPage: Sendable {
    public let items: [KnowledgeManagementItem]
    public let nextCursor: KnowledgeManagementCursor?
    public let isTruncated: Bool

    public init(items: [KnowledgeManagementItem],
                nextCursor: KnowledgeManagementCursor?,
                isTruncated: Bool = false) {
        self.items = items
        self.nextCursor = nextCursor
        self.isTruncated = isTruncated
    }
}

public struct KnowledgeDocumentPage: Sendable {
    public let source: KnowledgeSource
    public let version: KnowledgeSourceVersion
    public let chunks: [SourceChunk]
    public let nextSequence: Int?

    public init(source: KnowledgeSource, version: KnowledgeSourceVersion,
                chunks: [SourceChunk], nextSequence: Int?) {
        self.source = source
        self.version = version
        self.chunks = chunks
        self.nextSequence = nextSequence
    }
}
