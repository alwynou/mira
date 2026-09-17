import Foundation

public enum MemoryExtractionJobTag: Sendable {}
public typealias MemoryExtractionJobID = EntityID<MemoryExtractionJobTag>

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

public struct MemoryExtractionTurn: Codable, Equatable, Sendable {
    public let source: SessionEvidenceReference
    public let completedExecutionID: ExecutionID
    public let completionEventID: UUID
    public let completionHead: SessionJournalHead
    public let admittedAt: Date
    public let completedAt: Date
    public let inputTokenEstimate: Int
    public init(source: SessionEvidenceReference, completedExecutionID: ExecutionID,
                completionEventID: UUID, completionHead: SessionJournalHead,
                admittedAt: Date, completedAt: Date, inputTokenEstimate: Int) {
        self.source = source; self.completedExecutionID = completedExecutionID
        self.completionEventID = completionEventID; self.completionHead = completionHead
        self.admittedAt = admittedAt; self.completedAt = completedAt; self.inputTokenEstimate = inputTokenEstimate
    }
    public func validate() throws {
        try source.validate(); try completionHead.validate()
        guard completionHead.cursor.sessionID == source.sessionID,
              completionHead.cursor.sequence > source.admissionSequence,
              inputTokenEstimate >= 0, inputTokenEstimate <= 32_768,
              admittedAt.timeIntervalSince1970.isFinite, completedAt.timeIntervalSince1970.isFinite else {
            throw MiraError(.invalidInput, "The automatic memory turn is invalid.")
        }
    }
}

public enum MemoryExtractionTrigger: String, Codable, Sendable { case turnCount, inputTokens, idle, oldestAge }

public enum MemoryExtractionBatching {
    public static let minimumTurns = 4
    public static let inputTokenThreshold = 2_000
    public static let idleInterval: TimeInterval = 120
    public static let oldestAge: TimeInterval = 600
    public static let maximumTurns = 16
    public static let maximumInputTokens = 8_192
    public static func trigger(turns: [MemoryExtractionTurn], now: Date) -> MemoryExtractionTrigger? {
        guard !turns.isEmpty, now.timeIntervalSince1970.isFinite else { return nil }
        let ordered = turns.sorted { $0.source.admissionSequence < $1.source.admissionSequence }
        let tokens = ordered.reduce(0) { $0 + $1.inputTokenEstimate }
        if ordered.count >= minimumTurns { return .turnCount }
        if tokens >= inputTokenThreshold { return .inputTokens }
        if let latest = ordered.map(\.completedAt).max(), now.timeIntervalSince(latest) >= idleInterval { return .idle }
        if let oldest = ordered.map(\.completedAt).min(), now.timeIntervalSince(oldest) >= oldestAge { return .oldestAge }
        return nil
    }
    public static func bounded(_ turns: [MemoryExtractionTurn]) -> [MemoryExtractionTurn] {
        var tokens = 0
        var result: [MemoryExtractionTurn] = []
        for turn in turns.sorted(by: { $0.source.admissionSequence < $1.source.admissionSequence }) {
            guard result.count < maximumTurns, tokens + turn.inputTokenEstimate <= maximumInputTokens else { break }
            result.append(turn); tokens += turn.inputTokenEstimate
        }
        return result
    }
}

public enum MemoryExtractionJobState: String, Codable, Sendable {
    case queued, running, paused, completed, failed, cancelled, suppressed
}

public struct MemoryExtractionJob: Identifiable, Codable, Equatable, Sendable {
    public let id: MemoryExtractionJobID
    public let origin: MemoryExtractionOrigin
    public let workspaceID: WorkspaceID?
    public let extractorRevision: Int
    public var state: MemoryExtractionJobState
    public var attemptCount: Int
    public let createdAt: Date
    public var updatedAt: Date
    public var error: MiraError?
    public var memoryIDs: [MemoryID]
    public var candidateMemoryIDs: [MemoryID]
    public var turns: [MemoryExtractionTurn]
    public init(
        id: MemoryExtractionJobID, origin: MemoryExtractionOrigin, workspaceID: WorkspaceID?,
        extractorRevision: Int = MemoryExtractionRequestBuilder.revision, state: MemoryExtractionJobState = .queued,
        attemptCount: Int = 0, createdAt: Date, updatedAt: Date, error: MiraError? = nil,
        memoryIDs: [MemoryID] = [], candidateMemoryIDs: [MemoryID] = [], turns: [MemoryExtractionTurn] = []
    ) {
        self.id = id
        self.origin = origin
        self.workspaceID = workspaceID
        self.extractorRevision = extractorRevision
        self.state = state
        self.attemptCount = attemptCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.error = error
        self.memoryIDs = memoryIDs
        self.candidateMemoryIDs = candidateMemoryIDs
        self.turns = turns
    }
    public func validate() throws {
        try origin.validate()
        guard extractorRevision == MemoryExtractionRequestBuilder.revision,
            (0...100).contains(attemptCount), createdAt.timeIntervalSince1970.isFinite,
            updatedAt.timeIntervalSince1970.isFinite, updatedAt >= createdAt,
            memoryIDs.count <= 6, Set(memoryIDs).count == memoryIDs.count,
            candidateMemoryIDs.count <= 6, Set(candidateMemoryIDs).count == candidateMemoryIDs.count,
            Set(candidateMemoryIDs).isSubset(of: Set(memoryIDs)),
            turns.count <= MemoryExtractionBatching.maximumTurns
        else {
            throw MiraError(.invalidInput, "The memory extraction job is invalid.")
        }
        for turn in turns { try turn.validate() }
        guard turns.allSatisfy({ $0.source.sessionID == origin.source.sessionID }),
              Set(turns.map { $0.source.userMessageID }).count == turns.count,
              turns.isEmpty || turns.first?.source == origin.source else {
            throw MiraError(.invalidInput, "The extraction batch lineage is inconsistent.")
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
    public let selection: AgentModelRouteResolution
    public let leaseID: UUID
    public let leaseExpiresAt: Date
    public let attemptID: UUID
    public var batchSources: [SessionUserEvidence]
    public var existingMemories: [Memory] = []
    public var assistantReplies: [String?] = []
    /// Optional provider prompt-cache prefix prepared by the worker from already-authorized context.
    public var prefix: MemoryExtractionPrefix? = nil
    /// Provider-legal output ceiling chosen by the adapter for the frozen route.
    public var outputTokenLimit: Int? = nil
    public var route: AgentModelRoute { selection.route }
    public var executionID: ExecutionID { .init(attemptID) }
    public init(
        job: MemoryExtractionJob, source: SessionUserEvidence,
        selection: AgentModelRouteResolution, leaseID: UUID, leaseExpiresAt: Date, attemptID: UUID
        , batchSources: [SessionUserEvidence]? = nil, prefix: MemoryExtractionPrefix? = nil,
        outputTokenLimit: Int? = nil
    ) {
        self.job = job
        self.source = source
        self.selection = selection
        self.leaseID = leaseID
        self.leaseExpiresAt = leaseExpiresAt
        self.attemptID = attemptID
        self.batchSources = batchSources ?? [source]
        self.prefix = prefix
        self.outputTokenLimit = outputTokenLimit
    }
    public func validate() throws {
        try job.validate()
        try route.validate()
        try MemoryExtractionRequestBuilder.validate(source: source)
        guard !batchSources.isEmpty, batchSources.count <= MemoryExtractionBatching.maximumTurns else {
            throw MiraError(.invalidInput, "The extraction claim exceeds its bounded source set.")
        }
        for evidence in batchSources { try MemoryExtractionRequestBuilder.validate(source: evidence) }
        guard prefix.map({ $0.route == route }) ?? true,
              outputTokenLimit.map({ $0 > 0 && $0 <= route.maximumOutputTokens }) ?? true else {
            throw MiraError(.configuration, "The extraction prefix or output budget does not match the conversation model.")
        }
        guard job.state == .running, job.attemptCount > 0,
            job.origin.source == source.reference,
            job.workspaceID == source.workspaceID,
            selection.binding == nil, leaseExpiresAt.timeIntervalSince1970.isFinite,
            leaseExpiresAt > job.updatedAt, executionID != job.origin.completedExecutionID,
            executionID != source.reference.originalExecutionID
        else {
            throw MiraError(.conflict, "The memory extraction claim does not match its admitted source and route.")
        }
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
    public let inputIndex: Int
    public let replacesIndex: Int?
    public init(
        draft: MemoryDraft, quote: String, origin: MemoryOrigin, authority: MemoryAuthority,
        triage: MemoryExtractionTriage, reviewReason: String? = nil,
        assertion: MemoryAssertionMetadata = .init(mode: .uncertain, aspectKey: nil, changeIntent: .uncertain), inputIndex: Int = 0, replacesIndex: Int? = nil
    ) {
        self.draft = draft
        self.quote = quote
        self.origin = origin
        self.authority = authority
        self.triage = triage
        self.reviewReason = reviewReason
        self.assertion = assertion
        self.inputIndex = inputIndex
        self.replacesIndex = replacesIndex
    }
}
