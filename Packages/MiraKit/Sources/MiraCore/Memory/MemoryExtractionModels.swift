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
    public init(
        revision: Int = 1, mode: MemoryCaptureMode = .manualOnly, dailyTokenLimit: Int = 10_000, enabledAt: Date? = nil
    ) {
        self.revision = revision
        self.mode = mode
        self.dailyTokenLimit = dailyTokenLimit
        self.enabledAt = enabledAt
    }
    public func validate() throws {
        guard revision > 0, dailyTokenLimit > 0, dailyTokenLimit <= 10_000_000,
            enabledAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
            mode == .manualOnly || enabledAt != nil
        else {
            throw MiraError(.configuration, "Choose a positive daily token budget before enabling automatic memory.")
        }
    }
}

/// Durable provenance for the completion that admitted this business job.
/// The journal remains the authority for the source and completion facts.
public struct MemoryExtractionOrigin: Codable, Equatable, Sendable {
    public let source: SessionEvidenceReference
    public let completedExecutionID: ExecutionID
    public let completionEventID: UUID
    public let completionHead: SessionJournalHead
    public init(
        source: SessionEvidenceReference, completedExecutionID: ExecutionID,
        completionEventID: UUID, completionHead: SessionJournalHead
    ) {
        self.source = source
        self.completedExecutionID = completedExecutionID
        self.completionEventID = completionEventID
        self.completionHead = completionHead
    }
    public func validate() throws {
        try source.validate()
        try completionHead.validate()
        guard completionHead.cursor.sessionID == source.sessionID,
            completionHead.cursor.sequence > source.admissionSequence
        else {
            throw MiraError(.invalidInput, "The memory extraction completion provenance is invalid.")
        }
    }
}

public enum MemoryExtractionJobState: String, Codable, Sendable {
    case queued, running, paused, completed, failed, cancelled, suppressed
}

public struct MemoryExtractionJob: Identifiable, Codable, Equatable, Sendable {
    public let id: MemoryExtractionJobID
    public let origin: MemoryExtractionOrigin
    public let workspaceID: WorkspaceID?
    public let policyRevision: Int
    public let extractorRevision: Int
    public var state: MemoryExtractionJobState
    public var attemptCount: Int
    public let createdAt: Date
    public var updatedAt: Date
    public var error: MiraError?
    public var memoryIDs: [MemoryID]
    public var candidateMemoryIDs: [MemoryID]
    public init(
        id: MemoryExtractionJobID, origin: MemoryExtractionOrigin, workspaceID: WorkspaceID?,
        policyRevision: Int, extractorRevision: Int = 1, state: MemoryExtractionJobState = .queued,
        attemptCount: Int = 0, createdAt: Date, updatedAt: Date, error: MiraError? = nil,
        memoryIDs: [MemoryID] = [], candidateMemoryIDs: [MemoryID] = []
    ) {
        self.id = id
        self.origin = origin
        self.workspaceID = workspaceID
        self.policyRevision = policyRevision
        self.extractorRevision = extractorRevision
        self.state = state
        self.attemptCount = attemptCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.error = error
        self.memoryIDs = memoryIDs
        self.candidateMemoryIDs = candidateMemoryIDs
    }
    public func validate() throws {
        try origin.validate()
        guard policyRevision > 0, extractorRevision == MemoryExtractionRequestBuilder.revision,
            (0...100).contains(attemptCount), createdAt.timeIntervalSince1970.isFinite,
            updatedAt.timeIntervalSince1970.isFinite, updatedAt >= createdAt,
            memoryIDs.count <= 6, Set(memoryIDs).count == memoryIDs.count,
            candidateMemoryIDs.count <= 6, Set(candidateMemoryIDs).count == candidateMemoryIDs.count,
            Set(candidateMemoryIDs).isSubset(of: Set(memoryIDs))
        else {
            throw MiraError(.invalidInput, "The memory extraction job is invalid.")
        }
        guard state == .completed || state == .suppressed || memoryIDs.isEmpty else {
            throw MiraError(.invalidInput, "An unfinished extraction job cannot contain memory results.")
        }
        switch state {
        case .queued: guard error == nil else { throw Self.invalidState }
        case .running, .completed: guard attemptCount > 0, error == nil else { throw Self.invalidState }
        case .paused, .failed: guard error != nil else { throw Self.invalidState }
        case .suppressed: guard error == nil else { throw Self.invalidState }
        case .cancelled: break
        }
    }
    private static var invalidState: MiraError { .init(.invalidInput, "The extraction job state is inconsistent.") }
}

/// A business attempt has its own identity; it never impersonates the foreground execution.
public struct MemoryExtractionClaim: Sendable {
    public let job: MemoryExtractionJob
    public let source: SessionUserEvidence
    public let policy: MemoryCapturePolicy
    public let selection: AgentModelRouteResolution
    public let leaseID: UUID
    public let leaseExpiresAt: Date
    public let attemptID: UUID
    public var route: AgentModelRoute { selection.route }
    public var executionID: ExecutionID { .init(attemptID) }
    public init(
        job: MemoryExtractionJob, source: SessionUserEvidence, policy: MemoryCapturePolicy,
        selection: AgentModelRouteResolution, leaseID: UUID, leaseExpiresAt: Date, attemptID: UUID
    ) {
        self.job = job
        self.source = source
        self.policy = policy
        self.selection = selection
        self.leaseID = leaseID
        self.leaseExpiresAt = leaseExpiresAt
        self.attemptID = attemptID
    }
    public func validate() throws {
        try job.validate()
        try policy.validate()
        try route.validate()
        try MemoryExtractionRequestBuilder.validate(source: source)
        guard job.state == .running, job.attemptCount > 0, job.origin.source == source.reference,
            job.workspaceID == source.workspaceID, policy.revision == job.policyRevision,
            policy.mode != .manualOnly, let enabledAt = policy.enabledAt, source.admittedAt >= enabledAt,
            let binding = selection.binding, binding.purpose == AgentModelPurposeID.memoryExtraction,
            binding.routeID == route.id, leaseExpiresAt.timeIntervalSince1970.isFinite,
            leaseExpiresAt > job.updatedAt, executionID != job.origin.completedExecutionID,
            executionID != source.reference.originalExecutionID
        else {
            throw MiraError(.conflict, "The memory extraction claim does not match its admitted source and route.")
        }
        try binding.validate()
        switch binding.scope {
        case .global: break
        case .workspace(let id): guard id == job.workspaceID else { throw Self.invalidBinding }
        }
    }
    private static var invalidBinding: MiraError {
        .init(.configuration, "The extraction route binding has a different scope.")
    }
}

public enum MemoryExtractionTriage: String, Sendable { case active, candidate }

/// Model-supplied semantic metadata is only used to group assertions for
/// review/evolution. It never grants authorization or changes source scope.
public enum MemoryAssertionMode: String, Codable, CaseIterable, Sendable {
    case directStable, inferred, reported, quoted, hypothetical, question, temporary, correction, uncertain
}

public enum MemoryChangeIntent: String, Codable, CaseIterable, Sendable {
    case independent, explicitReplacement, uncertain
}

public struct MemoryAssertionMetadata: Codable, Equatable, Sendable {
    public let mode: MemoryAssertionMode
    public let aspectKey: String?
    public let changeIntent: MemoryChangeIntent
    public init(mode: MemoryAssertionMode, aspectKey: String?, changeIntent: MemoryChangeIntent) {
        self.mode = mode
        self.aspectKey = aspectKey
        self.changeIntent = changeIntent
    }
}

/// Produced by deterministic validation, never decoded as authorization from model output.
public struct MemoryExtractionProposal: Sendable {
    public let draft: MemoryDraft
    public let quote: String
    public let origin: MemoryOrigin
    public let authority: MemoryAuthority
    public let triage: MemoryExtractionTriage
    public let reviewReason: String?
    public let assertion: MemoryAssertionMetadata
    public init(
        draft: MemoryDraft, quote: String, origin: MemoryOrigin, authority: MemoryAuthority,
        triage: MemoryExtractionTriage, reviewReason: String? = nil,
        assertion: MemoryAssertionMetadata = .init(mode: .uncertain, aspectKey: nil, changeIntent: .uncertain)
    ) {
        self.draft = draft
        self.quote = quote
        self.origin = origin
        self.authority = authority
        self.triage = triage
        self.reviewReason = reviewReason
        self.assertion = assertion
    }
}

public struct MemoryExtractionBudget: Equatable, Sendable {
    public let dayStart: Date
    public let tokenLimit: Int
    public let reservedTokens: Int
    public let chargedTokens: Int
    public var remainingTokens: Int {
        guard tokenLimit > 0, reservedTokens >= 0, chargedTokens >= 0, reservedTokens < tokenLimit else { return 0 }
        let afterReservation = tokenLimit - reservedTokens
        return chargedTokens < afterReservation ? afterReservation - chargedTokens : 0
    }
    public init(dayStart: Date, tokenLimit: Int, reservedTokens: Int, chargedTokens: Int) {
        self.dayStart = dayStart
        self.tokenLimit = tokenLimit
        self.reservedTokens = reservedTokens
        self.chargedTokens = chargedTokens
    }
}
