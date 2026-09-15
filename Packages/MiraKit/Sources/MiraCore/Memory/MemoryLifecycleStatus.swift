import Foundation

/// The effective lifecycle is distinct from the persisted review state.
public enum MemoryLifecycleStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case active, candidate, archived, rejected, removed, forgotten, superseded, expired, notYetValid
}

extension Memory {
    public func lifecycleStatus(at date: Date) -> MemoryLifecycleStatus {
        if forgottenAt != nil { return .forgotten }
        if deletedAt != nil || state == .removed { return .removed }
        if supersededBy != nil { return .superseded }
        switch state {
        case .candidate: return .candidate
        case .archived: return .archived
        case .rejected: return .rejected
        case .removed: return .removed
        case .active:
            if let until = draft?.validUntil, until <= date { return .expired }
            if let from = draft?.validFrom, from > date { return .notYetValid }
            return .active
        }
    }
}

/// Body-free provenance for a retained historical reply. It is derived from
/// current memory state, never used as a new source of facts or authorization.
public struct MemoryContextNotice: Equatable, Hashable, Sendable, Identifiable {
    public enum Reason: String, CaseIterable, Hashable, Sendable {
        case forgotten, superseded, expired, notYetValid, archived, rejected, removed, candidate, updated, unavailable
    }
    public var memoryID: MemoryID
    public var reason: Reason
    public var id: String { "\(memoryID.rawValue):\(reason.rawValue)" }
    public init(memoryID: MemoryID, reason: Reason) {
        self.memoryID = memoryID
        self.reason = reason
    }
}
