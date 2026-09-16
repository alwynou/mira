import Foundation

/// Business jobs and accounting, never a second authority for messages or executions.
/// Every mutation checks the library authorization and current policy in its SQL transaction.
/// Fresh source evidence is resolved under the caller-owned library lease before each transition.
public protocol MemoryExtractionStore: Sendable {
    /// Converts eligible durable dirty turns into bounded jobs.
    func flushDirtyMemoryExtraction(at: Date, authorization: AgentLibraryAuthorization) async throws
    func memoryExtractionJobs(sessionID: ConversationID?, state: MemoryExtractionJobState?, limit: Int) async throws
        -> [MemoryExtractionJob]
    /// Select the oldest queued job in the next session in UUID order, wrapping at the end.
    /// This is only a scheduling hint; claim still arbitrates the sole live library attempt.
    func nextQueuedMemoryExtraction(after sessionID: ConversationID?) async throws -> MemoryExtractionJob?
    /// One live claim per library. The source and frozen conversation route must match the selected job.
    func claimMemoryExtraction(
        _ id: MemoryExtractionJobID, expectedAttemptCount: Int,
        source: SessionUserEvidence, selection: AgentModelRouteResolution,
        authorization: AgentLibraryAuthorization, at: Date
    ) async throws -> MemoryExtractionClaim?
    /// Persist the exact prepared request and reserve its conservative input/output ceiling before network work.
    func prepareMemoryExtraction(
        _ claim: MemoryExtractionClaim, request: AgentPreparedModelRequest,
        source: SessionUserEvidence, authorization: AgentLibraryAuthorization, at: Date
    ) async throws -> Int
    /// Recheck current settings, workspace sending permission, suppression, policy, lease and reservation atomically.
    func markMemoryExtractionDispatched(
        _ claim: MemoryExtractionClaim, source: SessionUserEvidence,
        authorization: AgentLibraryAuthorization, at: Date) async throws
    /// Validate structured output again and commit decisions, memories, attempt settlement and job result atomically.
    func completeMemoryExtraction(
        _ claim: MemoryExtractionClaim, source: SessionUserEvidence,
        output: AgentModelOutput, authorization: AgentLibraryAuthorization, at: Date
    ) async throws -> MemoryExtractionJob
    /// Idempotent settlement. Unsent work releases its reservation; dispatched uncertainty charges the ceiling and pauses.
    func failMemoryExtraction(
        _ claim: MemoryExtractionClaim, error: MiraError,
        authorization: AgentLibraryAuthorization, at: Date) async throws
    /// Preparation can reject an unavailable source before a claim exists; this never dispatches or advances attempts.
    func pauseMemoryExtraction(
        _ id: MemoryExtractionJobID, expectedAttemptCount: Int, error: MiraError,
        authorization: AgentLibraryAuthorization, at: Date) async throws
    /// Explicit retry still requires fresh evidence and cannot resurrect suppressed sources.
    func retryMemoryExtraction(
        _ id: MemoryExtractionJobID, source: SessionUserEvidence,
        authorization: AgentLibraryAuthorization, at: Date
    ) async throws -> MemoryExtractionJobID
    /// Composition calls recovery only after the previous worker and actual producers have drained.
    /// Unsent attempts can be requeued; dispatched/uncertain attempts pause without an implicit resend.
    func recoverMemoryExtraction(authorization: AgentLibraryAuthorization, at: Date) async throws
}
