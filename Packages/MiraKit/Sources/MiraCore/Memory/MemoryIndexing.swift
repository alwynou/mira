import Foundation

/// Immutable snapshot of one outbox entry. It is not authority to commit a later result.
public struct MemoryIndexJob: Sendable, Equatable {
    public let memoryID: MemoryID
    public let revision: Int
    public let content: String
    public let contentHash: String
    public let generation: UUID
    public let identity: MemoryEmbeddingIdentity

    public init(memoryID: MemoryID, revision: Int, content: String, contentHash: String,
                generation: UUID, identity: MemoryEmbeddingIdentity) {
        self.memoryID = memoryID; self.revision = revision; self.content = content
        self.contentHash = contentHash; self.generation = generation; self.identity = identity
    }
}

public protocol MemoryIndexStore: Sendable {
    func hasMemoryVectors() async throws -> Bool
    func pendingMemoryIndexJobs(limit: Int) async throws -> [MemoryIndexJob]
    /// Returns false if a mutation, deletion, or index generation invalidated this job.
    func completeMemoryIndexJob(_ job: MemoryIndexJob, vector: [Float],
                                authorization: AgentLibraryAuthorization) async throws -> Bool
    func failMemoryIndexJob(_ job: MemoryIndexJob, authorization: AgentLibraryAuthorization) async throws
}

/// One library-owned producer. Each inference result is checked against the canonical revision in SQL.
public actor MemoryIndexWorker {
    private let store: any MemoryIndexStore
    private let embeddings: any MemoryEmbeddingService
    private let access: AgentLibraryAccess
    private let scope: RuntimeScope
    private var task: Task<Void, Never>?
    private var closed = false
    private var wakeRequested = false
    private var idle = false
    private var failure: MiraError?
    private var preparationRequested = false
    private var retryAfter: Date?

    public init(store: any MemoryIndexStore, embeddings: any MemoryEmbeddingService,
                access: AgentLibraryAccess, scope: RuntimeScope) {
        self.store = store; self.embeddings = embeddings; self.access = access; self.scope = scope
    }

    public func lastFailure() -> MiraError? { failure }
    public func embeddingStatus() async -> MemoryEmbeddingStatus { await embeddings.status() }
    public func prepareModel() {
        preparationRequested = true
        retryAfter = nil
        wake(isIdle: idle)
    }

    /// Index only while foreground executions are idle; a submitted GPU call still drains on cancellation.
    public func wake(isIdle: Bool) {
        idle = isIdle
        guard !closed, isIdle, retryAfter.map({ Date() >= $0 }) ?? true else { return }
        wakeRequested = true
        guard task == nil else { return }
        task = Task { await self.run() }
    }

    public func close() async {
        closed = true
        task?.cancel()
        if let task { await task.value }
    }

    private func run() async {
        defer { task = nil }
        do {
            while !closed && idle && !Task.isCancelled {
                wakeRequested = false
                let progressed = try await pass()
                if !progressed && !wakeRequested { break }
                await Task.yield()
            }
            failure = nil
            retryAfter = nil
        } catch is CancellationError {} catch {
            failure = MiraError.safe(error)
            retryAfter = Date().addingTimeInterval(300)
        }
    }

    private func pass() async throws -> Bool {
        let lease = try await access.acquire(in: scope)
        do {
            let resource = try await lease.start {
                let operation = Task { try await self.index(lease: lease) }
                return AgentLibraryResource(value: operation, cleanup: {
                    operation.cancel()
                    _ = await operation.result
                })
            }
            do {
                try lease.bindCancellation { resource.value.cancel() }
                let result = try await withTaskCancellationHandler {
                    try await resource.value.value
                } onCancel: { resource.value.cancel() }
                await resource.release()
                await lease.release()
                return result
            } catch {
                await resource.release()
                throw error
            }
        } catch {
            await lease.release()
            throw error
        }
    }

    private func index(lease: AgentLibraryAccessLease) async throws -> Bool {
        let jobs = try await lease.read { try await self.store.pendingMemoryIndexJobs(limit: 4) }
        let hasVectors = try await store.hasMemoryVectors()
        let shouldLoad = await embeddings.status() != .ready && hasVectors
        guard !jobs.isEmpty || preparationRequested || shouldLoad else { return false }
        preparationRequested = false
        try await embeddings.prepare()
        for job in jobs {
            guard idle && !closed else { return false }
            try Task.checkCancellation()
            try await lease.check()
            guard job.identity == embeddings.identity else {
                throw MiraError(.configuration, "The local memory embedding space does not match the index.")
            }
            do {
                let vectors = try await embeddings.embed(.documents([job.content]))
                try Task.checkCancellation()
                try await lease.check()
                guard vectors.count == 1 else { throw MiraError(.invalidInput, "The local embedding result is invalid.") }
                _ = try await store.completeMemoryIndexJob(job, vector: vectors[0], authorization: lease.authorization)
            } catch let error as MiraError where error.code == .invalidInput || error.code == .outputLimit {
                // A bounded-out assertion retains lexical recall; do not retry it on every wake.
                try await store.failMemoryIndexJob(job, authorization: lease.authorization)
            }
        }
        return !jobs.isEmpty
    }
}
