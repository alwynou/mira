import Foundation

public enum MemoryExtractionAttemptState: String, Codable, Sendable {
    case claimed, prepared, dispatched, completed, failed, paused
    public var isLive: Bool { self == .claimed || self == .prepared || self == .dispatched }
}

/// Accounting has no request, response, thinking, evidence excerpt, or memory body.
/// Reserved and charged tokens are conservative per-attempt accounting facts, never a quota or a substitute for reported usage.
public struct MemoryExtractionAttemptUsage: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let jobID: MemoryExtractionJobID
    public let ordinal: Int
    public let state: MemoryExtractionAttemptState
    public let startedAt: Date
    public let dispatchedAt: Date?
    public let settledAt: Date?
    public let reservedTokens: Int
    public let chargedTokens: Int
    public let usage: TokenUsage?
    public let route: AgentModelRoute?
    public let bodyPurgedAt: Date?

    public init(
        id: UUID, jobID: MemoryExtractionJobID, ordinal: Int, state: MemoryExtractionAttemptState,
        startedAt: Date, dispatchedAt: Date?, settledAt: Date?,
        reservedTokens: Int, chargedTokens: Int, usage: TokenUsage?, route: AgentModelRoute?,
        bodyPurgedAt: Date?
    ) {
        self.id = id
        self.jobID = jobID
        self.ordinal = ordinal
        self.state = state
        self.startedAt = startedAt
        self.dispatchedAt = dispatchedAt
        self.settledAt = settledAt
        self.reservedTokens = reservedTokens
        self.chargedTokens = chargedTokens
        self.usage = usage
        self.route = route
        self.bodyPurgedAt = bodyPurgedAt
    }

    public func validate() throws {
        guard (1...100).contains(ordinal), startedAt.timeIntervalSince1970.isFinite,
            [dispatchedAt, settledAt, bodyPurgedAt].allSatisfy({
                $0.map { $0.timeIntervalSince1970.isFinite } ?? true
            }), (0...10_000_000).contains(reservedTokens),
            chargedTokens >= 0, chargedTokens <= TokenUsage.maximumAggregateTokens,
            state.isLive == (settledAt == nil),
            (state == .completed) == (usage != nil),
            (bodyPurgedAt == nil) == (route != nil),
            bodyPurgedAt == nil || !state.isLive,
            dispatchedAt.map({ $0 >= startedAt }) ?? true,
            settledAt.map({ $0 >= (dispatchedAt ?? startedAt) }) ?? true,
            bodyPurgedAt.map({ $0 >= (settledAt ?? startedAt) }) ?? true
        else { throw Self.invalid }
        try usage?.validate()
        try route?.validate()
        switch state {
        case .claimed:
            guard dispatchedAt == nil, reservedTokens == 0, chargedTokens == 0 else { throw Self.invalid }
        case .prepared:
            guard dispatchedAt == nil, reservedTokens > 0, chargedTokens == 0 else { throw Self.invalid }
        case .dispatched:
            guard dispatchedAt != nil, reservedTokens > 0, chargedTokens == 0 else { throw Self.invalid }
        case .failed:
            guard dispatchedAt == nil, chargedTokens == 0 else { throw Self.invalid }
        case .paused:
            guard dispatchedAt != nil, reservedTokens > 0, chargedTokens == reservedTokens else { throw Self.invalid }
        case .completed:
            guard dispatchedAt != nil, reservedTokens > 0 else { throw Self.invalid }
            let expected: Int
            if let input = usage?.totalInputTokens, let output = usage?.outputTokens {
                let (sum, overflow) = input.addingReportingOverflow(output)
                expected = overflow ? reservedTokens : sum
            } else {
                expected = reservedTokens
            }
            guard chargedTokens == expected else { throw Self.invalid }
        }
    }

    private static var invalid: MiraError { .init(.storage, "The extraction accounting record is inconsistent.") }
}

public struct MemoryExtractionJobSummary: Identifiable, Equatable, Sendable {
    public let id: MemoryExtractionJobID
    public let sessionID: ConversationID
    public let executionID: ExecutionID
    public let workspaceID: WorkspaceID?
    public let state: MemoryExtractionJobState
    /// Safe classification for a failed or paused job; never exposes error text.
    public let errorCode: MiraError.Code?
    public let attemptCount: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let memoryCount: Int
    public let candidateCount: Int

    public init(job: MemoryExtractionJob) {
        id = job.id
        sessionID = job.origin.source.sessionID
        executionID = job.origin.completedExecutionID
        workspaceID = job.workspaceID
        state = job.state
        errorCode = job.error?.code
        attemptCount = job.attemptCount
        createdAt = job.createdAt
        updatedAt = job.updatedAt
        memoryCount = job.memoryIDs.count
        candidateCount = job.candidateMemoryIDs.count
    }
}

/// A keyset cursor belongs to exactly one workspace, session, and originating completion.
public struct MemoryExtractionStatusCursor: Equatable, Hashable, Sendable {
    public let workspaceID: WorkspaceID?
    public let sessionID: ConversationID
    public let executionID: ExecutionID
    public let createdAt: Date
    public let jobID: MemoryExtractionJobID

    public init(
        workspaceID: WorkspaceID?, sessionID: ConversationID, executionID: ExecutionID,
        createdAt: Date, jobID: MemoryExtractionJobID
    ) {
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.executionID = executionID
        self.createdAt = createdAt
        self.jobID = jobID
    }
}

public struct MemoryExtractionStatusPage: Equatable, Sendable {
    public let jobs: [MemoryExtractionJobSummary]
    public let nextCursor: MemoryExtractionStatusCursor?
    public init(jobs: [MemoryExtractionJobSummary], nextCursor: MemoryExtractionStatusCursor?) {
        self.jobs = jobs
        self.nextCursor = nextCursor
    }
}

/// One transaction returns the job and all of its at most 100 attempts, regardless of job pagination.
public struct MemoryExtractionJobReport: Equatable, Sendable {
    public let job: MemoryExtractionJobSummary
    public let attempts: [MemoryExtractionAttemptUsage]
    public init(job: MemoryExtractionJobSummary, attempts: [MemoryExtractionAttemptUsage]) {
        self.job = job
        self.attempts = attempts
    }
}

public protocol MemoryExtractionStatusReader: Sendable {
    func memoryExtractionStatus(
        sessionID: ConversationID, executionID: ExecutionID, workspaceID: WorkspaceID?,
        before: MemoryExtractionStatusCursor?, limit: Int
    ) async throws -> MemoryExtractionStatusPage
    func memoryExtractionReport(
        _ id: MemoryExtractionJobID, sessionID: ConversationID,
        executionID: ExecutionID, workspaceID: WorkspaceID?
    ) async throws -> MemoryExtractionJobReport
}
