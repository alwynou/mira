import Foundation

public enum MemoryManagementScope: Equatable, Sendable {
    case all
    case global
    case workspace(WorkspaceID)
}

public enum MemoryManagementSection: String, Equatable, Sendable { case current, history }
public enum MemoryManagementOrder: String, Equatable, Sendable { case newestFirst, oldestFirst }

/// Keyset position bound to the filters and ordering that produced it.
public struct MemoryManagementCursor: Equatable, Sendable {
    public let timestamp: Date
    public let memoryID: MemoryID
    public let queryKey: String

    public init(timestamp: Date, memoryID: MemoryID, queryKey: String) {
        self.timestamp = timestamp
        self.memoryID = memoryID
        self.queryKey = queryKey
    }
}

public struct MemoryManagementQuery: Sendable {
    public var scope: MemoryManagementScope
    public var section: MemoryManagementSection
    public var query: String
    public var order: MemoryManagementOrder
    public var limit: Int
    public var cursor: MemoryManagementCursor?

    public init(scope: MemoryManagementScope = .all, section: MemoryManagementSection = .current,
                query: String = "", order: MemoryManagementOrder = .newestFirst,
                limit: Int = 100, cursor: MemoryManagementCursor? = nil) {
        self.scope = scope; self.section = section; self.query = query
        self.order = order; self.limit = limit; self.cursor = cursor
    }

    public var key: String {
        let scopeKey: String
        switch scope {
        case .all: scopeKey = "all"
        case .global: scopeKey = "global"
        case .workspace(let id): scopeKey = "workspace:\(id.rawValue.uuidString.lowercased())"
        }
        let bytes = Array([scopeKey, section.rawValue, query, order.rawValue].joined(separator: "\u{1f}").utf8)
        let hash = bytes.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}

public struct MemoryManagementPage: Sendable {
    public var memories: [Memory]
    public var nextCursor: MemoryManagementCursor?
    public var nextTransitionAt: Date?
    public init(memories: [Memory], nextCursor: MemoryManagementCursor?, nextTransitionAt: Date? = nil) {
        self.memories = memories; self.nextCursor = nextCursor; self.nextTransitionAt = nextTransitionAt
    }
}

public enum MemoryManagementStatus: String, Codable, CaseIterable, Sendable {
    case current, superseded, archived, candidate, rejected, removed, forgotten, expired, notYetValid
}

extension Memory {
    public func managementStatus(at date: Date) -> MemoryManagementStatus {
        switch lifecycleStatus(at: date) {
        case .active: return .current
        case .candidate: return .candidate
        case .archived: return .archived
        case .rejected: return .rejected
        case .removed: return .removed
        case .forgotten: return .forgotten
        case .superseded: return .superseded
        case .expired: return .expired
        case .notYetValid: return .notYetValid
        }
    }
}
