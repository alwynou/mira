import Foundation

public enum MemoryExtractionJobTag: Sendable {}
public typealias MemoryExtractionJobID = EntityID<MemoryExtractionJobTag>

public enum MemoryCaptureMode: String, Codable, CaseIterable, Sendable {
    case manualOnly, candidateOnly, automaticWithUndo
}

public struct MemoryCapturePolicy: Codable, Equatable, Sendable {
    public var revision: Int
    public var mode: MemoryCaptureMode
    public var dailyTokenLimit: Int
    public var enabledAt: Date?
    public init(revision: Int = 1, mode: MemoryCaptureMode = .manualOnly, dailyTokenLimit: Int = 10_000, enabledAt: Date? = nil) {
        self.revision = revision; self.mode = mode; self.dailyTokenLimit = dailyTokenLimit; self.enabledAt = enabledAt
    }
    public func validate() throws {
        guard revision > 0, dailyTokenLimit > 0, dailyTokenLimit <= 10_000_000,
              enabledAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              mode == .manualOnly || enabledAt != nil else {
            throw MiraError(.configuration, "Choose a positive daily token budget before enabling automatic memory.")
        }
    }
}

/// Ephemeral source resolved from committed storage when claiming a job. The model cannot provide these fields.
public struct MemoryExtractionSource: Sendable {
    public let message: Message
    public let executionID: ExecutionID
    public let workspaceID: WorkspaceID?
    public let sourceRevision: Int
    public let sourceHash: String
    public init(message: Message, executionID: ExecutionID, workspaceID: WorkspaceID?, sourceRevision: Int = 1, sourceHash: String) {
        self.message = message; self.executionID = executionID; self.workspaceID = workspaceID
        self.sourceRevision = sourceRevision; self.sourceHash = sourceHash
    }
}

public enum MemoryExtractionJobState: String, Codable, Sendable {
    case queued, running, paused, completed, failed, cancelled, suppressed
}

public struct MemoryExtractionJob: Identifiable, Sendable {
    public let id: MemoryExtractionJobID
    public var sourceMessageID: MessageID
    public var conversationID: ConversationID
    public var policyRevision: Int
    public var extractorVersion: Int
    public var state: MemoryExtractionJobState
    public var attemptCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var error: MiraError?
    public var memoryIDs: [MemoryID]
    public var candidateMemoryIDs: [MemoryID]
    public var callUsages: [ModelCallUsage] = []
    public init(id: MemoryExtractionJobID, sourceMessageID: MessageID, conversationID: ConversationID, policyRevision: Int, extractorVersion: Int = 1, state: MemoryExtractionJobState, attemptCount: Int = 0, createdAt: Date, updatedAt: Date, error: MiraError? = nil, memoryIDs: [MemoryID] = [], candidateMemoryIDs: [MemoryID] = []) {
        self.id = id; self.sourceMessageID = sourceMessageID; self.conversationID = conversationID
        self.policyRevision = policyRevision; self.extractorVersion = extractorVersion; self.state = state
        self.attemptCount = attemptCount; self.createdAt = createdAt; self.updatedAt = updatedAt; self.error = error; self.memoryIDs = memoryIDs
        self.candidateMemoryIDs = candidateMemoryIDs
    }
}

public struct MemoryExtractionClaim: Sendable {
    public let job: MemoryExtractionJob
    public let source: MemoryExtractionSource
    public let policy: MemoryCapturePolicy
    public let route: ResolvedModelRouteSnapshot
    public let leaseID: UUID
    public let leaseExpiresAt: Date
    public let attemptID: UUID
    public init(job: MemoryExtractionJob, source: MemoryExtractionSource, policy: MemoryCapturePolicy, route: ResolvedModelRouteSnapshot, leaseID: UUID, leaseExpiresAt: Date, attemptID: UUID) {
        self.job = job; self.source = source; self.policy = policy; self.route = route
        self.leaseID = leaseID; self.leaseExpiresAt = leaseExpiresAt; self.attemptID = attemptID
    }
}

public enum MemoryExtractionTriage: String, Sendable { case active, candidate }

/// Produced by deterministic validation, never decoded as authorization from model output.
public struct MemoryExtractionProposal: Sendable {
    public let draft: MemoryDraft
    public let quote: String
    public let origin: MemoryOrigin
    public let authority: MemoryAuthority
    public let triage: MemoryExtractionTriage
    public let reviewReason: String?
    public init(draft: MemoryDraft, quote: String, origin: MemoryOrigin, authority: MemoryAuthority, triage: MemoryExtractionTriage, reviewReason: String? = nil) {
        self.draft = draft; self.quote = quote; self.origin = origin; self.authority = authority; self.triage = triage; self.reviewReason = reviewReason
    }
}

public struct MemoryExtractionBudget: Sendable {
    public let dayStart: Date
    public let tokenLimit: Int
    public let reservedTokens: Int
    public let chargedTokens: Int
    public var remainingTokens: Int {
        guard tokenLimit > 0, reservedTokens >= 0, chargedTokens >= 0, reservedTokens < tokenLimit else { return 0 }
        return max(0, tokenLimit - reservedTokens - chargedTokens)
    }
    public init(dayStart: Date, tokenLimit: Int, reservedTokens: Int, chargedTokens: Int) {
        self.dayStart = dayStart; self.tokenLimit = tokenLimit; self.reservedTokens = reservedTokens; self.chargedTokens = chargedTokens
    }
}
