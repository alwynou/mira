import Foundation

public enum TaskManagementStatus: String, CaseIterable, Sendable {
    case all
    case active
    case open
    case inProgress
    case completed
    case cancelled
}

public struct TaskManagementQuery: Sendable {
    public var workspaceID: WorkspaceID?
    public var search: String
    public var status: TaskManagementStatus
    public var offset: Int
    public var limit: Int

    public init(workspaceID: WorkspaceID? = nil, search: String = "",
                status: TaskManagementStatus = .active, offset: Int = 0, limit: Int = 50) {
        self.workspaceID = workspaceID
        self.search = search
        self.status = status
        self.offset = offset
        self.limit = limit
    }
}

public struct TaskManagementPage: Sendable {
    public let items: [MiraTask]
    public let hasMore: Bool

    public init(items: [MiraTask], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }
}

public struct TaskProposalPage: Sendable {
    public let items: [TaskProposal]
    public let hasMore: Bool

    public init(items: [TaskProposal], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }
}

public struct TaskRevisionPage: Sendable {
    public let items: [TaskRevision]
    public let hasMore: Bool

    public init(items: [TaskRevision], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }
}
