import Foundation

/// One leased background job at a time; every transition rechecks source, policy, and budget inside the transaction.
public protocol MemoryExtractionStore: Sendable {
    func memoryCapturePolicy() throws -> MemoryCapturePolicy
    func saveMemoryCapturePolicy(_ policy: MemoryCapturePolicy, expectedRevision: Int, at: Date) throws
    func memoryExtractionJobs(conversationID: ConversationID?, limit: Int) throws -> [MemoryExtractionJob]
    func memoryExtractionBudget(at: Date) throws -> MemoryExtractionBudget
    /// Queued jobs originate atomically with a successful foreground reply. This method never processes older history implicitly.
    func claimMemoryExtraction(at: Date) throws -> MemoryExtractionClaim?
    /// Persists the exact request and reserves input plus maximum output before dispatch. Returns the reserved token ceiling.
    func prepareMemoryExtraction(_ claim: MemoryExtractionClaim, request: CanonicalModelRequest, at: Date) throws -> Int
    /// Validates the lease, original source, dedicated purpose binding, and current permissions immediately before a remote call.
    func markMemoryExtractionDispatched(_ claim: MemoryExtractionClaim, at: Date) throws
    /// Parses/validates output again under the transaction, settles usage, and commits decisions, memories, and job completion atomically.
    func completeMemoryExtraction(_ claim: MemoryExtractionClaim, output: ModelOutput, usage: TokenUsage, at: Date) throws -> MemoryExtractionJob
    /// Releases an unsent reservation, or charges its ceiling after dispatch. Late/duplicate settlement is a no-op.
    func failMemoryExtraction(_ claim: MemoryExtractionClaim, error: MiraError, at: Date) throws
    /// Explicit user retry revalidates the source and suppression; it cannot silently recreate a forgotten assertion.
    func retryMemoryExtraction(_ id: MemoryExtractionJobID, at: Date) throws -> MemoryExtractionJobID
    /// Unsent expired claims may return to the queue. Dispatched/uncertain attempts pause and require an explicit retry.
    func recoverMemoryExtraction(at: Date) throws
}
