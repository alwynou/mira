import Foundation

public enum MemoryExtractionDisposition: String, Codable, Sendable { case created, reused }
public enum MemoryExtractionConflictReason: String, Codable, Sendable {
    case currentMemoryRequiresReview, multipleCurrentMemories
}

/// A decision is a historical business fact, not authorization to use a memory now.
/// Every validated model item retains its original zero-based position, including duplicates.
public struct MemoryExtractionDecision: Codable, Equatable, Sendable {
    public let proposalIndex: Int
    public let memoryID: MemoryID
    public let memoryRevision: Int
    public let memoryState: MemoryState
    public let disposition: MemoryExtractionDisposition
    public let validationReviewReason: String?
    public let conflictReason: MemoryExtractionConflictReason?
    public let conflictingMemoryIDs: [MemoryID]
    public let replacedMemoryID: MemoryID?

    public init(
        proposalIndex: Int, memoryID: MemoryID, memoryRevision: Int, memoryState: MemoryState,
        disposition: MemoryExtractionDisposition, validationReviewReason: String?,
        conflictReason: MemoryExtractionConflictReason? = nil, conflictingMemoryIDs: [MemoryID] = [],
        replacedMemoryID: MemoryID? = nil
    ) {
        self.proposalIndex = proposalIndex
        self.memoryID = memoryID
        self.memoryRevision = memoryRevision
        self.memoryState = memoryState
        self.disposition = disposition
        self.validationReviewReason = validationReviewReason
        self.conflictReason = conflictReason
        self.conflictingMemoryIDs = conflictingMemoryIDs
        self.replacedMemoryID = replacedMemoryID
    }

    public func validate() throws {
        guard (0..<6).contains(proposalIndex), memoryRevision > 0,
            ![.removed, .rejected].contains(memoryState),
            validationReviewReason.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true,
            conflictingMemoryIDs.count <= 100,
            Set(conflictingMemoryIDs).count == conflictingMemoryIDs.count,
            !conflictingMemoryIDs.contains(memoryID)
        else { throw Self.invalid }
        if disposition == .reused {
            guard conflictReason == nil, conflictingMemoryIDs.isEmpty, replacedMemoryID == nil else {
                throw Self.invalid
            }
            return
        }
        guard memoryState == .active || memoryState == .candidate else { throw Self.invalid }
        if memoryState == .active {
            guard validationReviewReason == nil, conflictReason == nil,
                conflictingMemoryIDs == (replacedMemoryID.map({ [$0] }) ?? [])
            else { throw Self.invalid }
        } else {
            guard replacedMemoryID == nil, validationReviewReason != nil || conflictReason != nil else {
                throw Self.invalid
            }
            switch conflictReason {
            case nil: guard conflictingMemoryIDs.isEmpty else { throw Self.invalid }
            case .currentMemoryRequiresReview: guard conflictingMemoryIDs.count == 1 else { throw Self.invalid }
            case .multipleCurrentMemories: guard conflictingMemoryIDs.count > 1 else { throw Self.invalid }
            }
        }
    }

    private static var invalid: MiraError {
        .init(.invalidInput, "The memory extraction decision is inconsistent.")
    }
}

/// Nil decisions mean the completed attempt's body has been purged; an empty array
/// means the model completed successfully without proposing a memory.
public struct MemoryExtractionDecisionReport: Sendable {
    public let jobID: MemoryExtractionJobID
    public let attemptID: UUID
    public let ordinal: Int
    public let decisions: [MemoryExtractionDecision]?
    public let bodyPurgedAt: Date?
    public init(
        jobID: MemoryExtractionJobID, attemptID: UUID, ordinal: Int,
        decisions: [MemoryExtractionDecision]?, bodyPurgedAt: Date?
    ) {
        self.jobID = jobID
        self.attemptID = attemptID
        self.ordinal = ordinal
        self.decisions = decisions
        self.bodyPurgedAt = bodyPurgedAt
    }
}

/// Inspection is separate from worker execution and never exposes prepared requests or model thinking.
public protocol MemoryExtractionInspectionStore: Sendable {
    /// Returns nil for an attempt that has not completed. A missing attempt or a different scope fails.
    func memoryExtractionDecisionReport(
        _ id: MemoryExtractionJobID, ordinal: Int, workspaceID: WorkspaceID?
    ) async throws -> MemoryExtractionDecisionReport?
}
