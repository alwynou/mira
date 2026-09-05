import Foundation
import Testing
@testable import MiraCore

struct MemoryExtractionWorkerTests {
    @Test func disabledStoreIsNotPolledOrSent() async throws {
        let store = WorkerStore(claim: nil)
        let provider = WorkerProvider(events: [.textDelta("{}"), .finished(.stop)])
        let worker = MemoryExtractionWorker(store: store, provider: provider)
        await worker.wake()
        try await waitUntil { store.claimCount > 0 }
        #expect(store.claimCount == 1)
        #expect(provider.requestCount == 0)
        await worker.shutdown()
    }

    @Test func duplicateWakesDrainOneClaimSerially() async throws {
        let claim = makeClaim()
        let store = WorkerStore(claim: claim)
        let provider = WorkerProvider(events: [.textDelta("{\"version\":1,\"items\":[]}"), .usage(.init(inputTokens: 3, outputTokens: 4)), .finished(.stop)])
        let worker = MemoryExtractionWorker(store: store, provider: provider)
        for _ in 0..<5 { await worker.wake() }
        try await waitUntil { store.completedCount == 1 }
        #expect(store.claimCount >= 2)
        #expect(provider.requestCount == 1)
        #expect(store.prepareCount == 1)
        #expect(store.dispatchCount == 1)
        #expect(store.failureCount == 0)
        await worker.shutdown()
    }

    @Test func requestBuilderOwnsSourceAndAttemptIdentity() throws {
        let claim = makeClaim()
        let request = try MemoryExtractionRequestBuilder.request(for: claim)
        #expect(request.executionID == claim.source.executionID)
        #expect(request.requestID == claim.attemptID)
        #expect(request.tools == nil)
        #expect(request.messages.count == 1)
        #expect(request.messages[0].role == .user)
        #expect(request.system.contains(MemoryExtractionValidator.instructions))
        #expect(request.system.contains("untrusted evidence"))
        #expect(request.system.contains(try MemoryExtractionValidator.outputSchema.jsonString()))
        #expect(request.system.contains("\"required\""))
        #expect(request.messages[0].text.contains(claim.source.message.id.rawValue.uuidString.lowercased()))
        #expect(request.messages[0].text.contains(claim.source.sourceHash))
        #expect(request.messages[0].text.contains(claim.source.message.text))
        #expect(request.messages[0].text.contains("\"role\":\"user\""))
    }

    @Test func malformedStreamToolCallsUnfinishedAndOversizedOutputFailAndArePersisted() async throws {
        let cases: [[CanonicalStreamEvent]] = [
            [.textDelta("{"), .finished(.stop)],
            [.toolCalls([.init(id: "tool", name: "anything", arguments: "{}")]), .finished(.toolCalls)],
            [.textDelta("{")],
            [.textDelta(String(repeating: "x", count: 32_769)), .finished(.stop)],
            [.textDelta("ok"), .finished(.outputLimit)]
        ]
        for events in cases {
            let store = WorkerStore(claim: makeClaim(), completeError: .init(.invalidInput, "The extraction output is invalid."))
            let provider = WorkerProvider(events: events)
            let worker = MemoryExtractionWorker(store: store, provider: provider)
            await worker.wake()
            try await waitUntil { store.failureCount == 1 }
            #expect(provider.requestCount == 1)
            #expect(store.failureCount == 1)
            await worker.shutdown()
        }
    }

    @Test func usageReportsAccumulateMonotonicallyAndInvalidityIsSticky() async throws {
        let cases: [([CanonicalStreamEvent], TokenUsage)] = [
            ([.usage(.init(inputTokens: 11)), .usage(.init(outputTokens: 7))], .init(inputTokens: 11, outputTokens: 7)),
            ([.usage(.init(inputTokens: 11, outputTokens: 7)), .usage(.init(inputTokens: 13, outputTokens: 9))], .init(inputTokens: 13, outputTokens: 9)),
            ([.usage(.init(inputTokens: 13, outputTokens: 9)), .usage(.init(inputTokens: 12, outputTokens: 10))], .init()),
            ([.usage(.init(inputTokens: -1, outputTokens: 2)), .usage(.init(inputTokens: 13, outputTokens: 9))], .init()),
            ([], .init())
        ]
        for (usageEvents, expected) in cases {
            let store = WorkerStore(claim: makeClaim())
            let provider = WorkerProvider(events: [.textDelta("{}")] + usageEvents + [.finished(.stop)])
            let worker = MemoryExtractionWorker(store: store, provider: provider)
            await worker.wake()
            try await waitUntil { store.completedCount == 1 }
            #expect(store.completedUsage == expected)
            await worker.shutdown()
        }
    }

    @Test func timeoutUsesInjectedClockAndCancelsProvider() async throws {
        let clock = TestClock()
        let store = WorkerStore(claim: makeClaim())
        let provider = WorkerProvider(hanging: true)
        let worker = MemoryExtractionWorker(store: store, provider: provider, environment: RuntimeEnvironment(sleep: { try await clock.sleep(for: $0) }))
        await worker.wake()
        try await waitUntil { provider.requestCount == 1 }
        clock.release()
        try await waitUntil { store.failureCount == 1 }
        #expect(store.failure?.code == .timeout)
        #expect(provider.terminated)
        await worker.shutdown()
    }

    @Test func cancelCurrentFailsClaimAndTerminatesProvider() async throws {
        let store = WorkerStore(claim: makeClaim())
        let provider = WorkerProvider(hanging: true)
        let worker = MemoryExtractionWorker(store: store, provider: provider)
        await worker.wake()
        try await waitUntil { provider.requestCount == 1 }
        await worker.cancelCurrent()
        try await waitUntil { store.failureCount == 1 }
        #expect(store.failure?.code == .cancelled)
        #expect(provider.terminated)
        await worker.shutdown()
    }

    @Test func shutdownIsIdempotentAndEndsProviderAndObservers() async throws {
        let store = WorkerStore(claim: makeClaim())
        let provider = WorkerProvider(hanging: true)
        let worker = MemoryExtractionWorker(store: store, provider: provider)
        let events = await worker.events()
        await worker.wake()
        try await waitUntil { provider.requestCount == 1 }
        await worker.shutdown()
        await worker.shutdown()
        #expect(provider.terminated)
        var observedEvents = 0
        for await _ in events {
            observedEvents += 1
        }
        #expect(observedEvents > 0)
    }
}

private struct WorkerTestTimeout: Error {}

private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async throws {
    for _ in 0..<300 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw WorkerTestTimeout()
}

private func makeClaim() -> MemoryExtractionClaim {
    let executionID = ExecutionID()
    let text = "I prefer compact interfaces"
    let message = Message(id: MessageID(), conversationID: ConversationID(), executionID: executionID, sequence: 1, role: .user, status: .committed, text: text, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    let source = MemoryExtractionSource(message: message, executionID: executionID, workspaceID: nil, sourceHash: "fixture-hash")
    let job = MemoryExtractionJob(id: MemoryExtractionJobID(), sourceMessageID: message.id, conversationID: message.conversationID, policyRevision: 1, state: .running, createdAt: message.createdAt, updatedAt: message.createdAt)
    let policy = MemoryCapturePolicy(revision: 1, mode: .candidateOnly, dailyTokenLimit: 10_000, enabledAt: message.createdAt)
    let route = ResolvedModelRouteSnapshot(name: "Memory fixture", providerKind: .openAICompatible, baseURL: "https://example.com/v1", modelID: "fixture", credentialReference: "fixture", contextWindow: 65_536, purpose: .memoryExtraction)
    return MemoryExtractionClaim(job: job, source: source, policy: policy, route: route, leaseID: UUID(), leaseExpiresAt: message.createdAt.addingTimeInterval(120), attemptID: UUID())
}

private final class WorkerStore: MemoryExtractionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var nextClaim: MemoryExtractionClaim?
    private let completeError: MiraError?
    private var claims = 0
    private var prepares = 0
    private var dispatches = 0
    private var failures = 0
    private var completes = 0
    private var lastFailure: MiraError?
    private var lastUsage = TokenUsage()

    init(claim: MemoryExtractionClaim?, completeError: MiraError? = nil) {
        nextClaim = claim
        self.completeError = completeError
    }
    var claimCount: Int { lock.withLock { claims } }
    var prepareCount: Int { lock.withLock { prepares } }
    var dispatchCount: Int { lock.withLock { dispatches } }
    var failureCount: Int { lock.withLock { failures } }
    var completedCount: Int { lock.withLock { completes } }
    var failure: MiraError? { lock.withLock { lastFailure } }
    var completedUsage: TokenUsage { lock.withLock { lastUsage } }

    func memoryCapturePolicy() throws -> MemoryCapturePolicy { .init() }
    func saveMemoryCapturePolicy(_ policy: MemoryCapturePolicy, expectedRevision: Int, at: Date) throws {}
    func memoryExtractionJobs(conversationID: ConversationID?, limit: Int) throws -> [MemoryExtractionJob] { [] }
    func memoryExtractionBudget(at: Date) throws -> MemoryExtractionBudget { .init(dayStart: at, tokenLimit: 10_000, reservedTokens: 0, chargedTokens: 0) }
    func claimMemoryExtraction(at: Date) throws -> MemoryExtractionClaim? {
        lock.withLock {
            claims += 1
            defer { nextClaim = nil }
            return nextClaim
        }
    }
    func prepareMemoryExtraction(_ claim: MemoryExtractionClaim, request: CanonicalModelRequest, at: Date) throws -> Int {
        lock.withLock { prepares += 1 }
        return 1_024
    }
    func markMemoryExtractionDispatched(_ claim: MemoryExtractionClaim, at: Date) throws {
        lock.withLock { dispatches += 1 }
    }
    func completeMemoryExtraction(_ claim: MemoryExtractionClaim, output: ModelOutput, usage: TokenUsage, at: Date) throws -> MemoryExtractionJob {
        if let completeError { throw completeError }
        lock.withLock { completes += 1; lastUsage = usage }
        return claim.job
    }
    func failMemoryExtraction(_ claim: MemoryExtractionClaim, error: MiraError, at: Date) throws {
        lock.withLock { failures += 1; lastFailure = error }
    }
    func retryMemoryExtraction(_ id: MemoryExtractionJobID, at: Date) throws -> MemoryExtractionJobID { id }
    func recoverMemoryExtraction(at: Date) throws {}
}

private final class WorkerProvider: ModelProviderPort, @unchecked Sendable {
    private let lock = NSLock()
    private let events: [CanonicalStreamEvent]
    private let isHanging: Bool
    private var captured = 0
    private var didTerminate = false
    init(events: [CanonicalStreamEvent] = [], hanging: Bool = false) {
        self.events = events
        isHanging = hanging
    }
    var requestCount: Int { lock.withLock { captured } }
    var terminated: Bool { lock.withLock { didTerminate } }
    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        lock.withLock { captured += 1 }
        if isHanging {
            let pair = AsyncThrowingStream<CanonicalStreamEvent, any Error>.makeStream()
            pair.continuation.onTermination = { [weak self] _ in self?.lock.withLock { self?.didTerminate = true } }
            return pair.stream
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private final class TestClock: RuntimeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    private var pendingReleases = 0
    func sleep(for duration: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let releaseNow = lock.withLock {
                    if pendingReleases > 0 {
                        pendingReleases -= 1
                        return true
                    }
                    waiters.append(continuation)
                    return false
                }
                if releaseNow { continuation.resume() }
            }
        } onCancel: {
            self.cancelOne()
        }
    }
    func release() {
        let waiter: CheckedContinuation<Void, any Error>? = lock.withLock {
            if waiters.isEmpty {
                pendingReleases += 1
                return nil
            }
            return waiters.removeFirst()
        }
        waiter?.resume()
    }
    private func cancelOne() {
        let waiter = lock.withLock { waiters.isEmpty ? nil : waiters.removeFirst() }
        waiter?.resume(throwing: CancellationError())
    }
}
