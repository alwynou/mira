import Foundation

/// A host-visible request for explicit confirmation of a memory write.
public struct MemoryApprovalRequest: Identifiable, Sendable {
    public let invocationID: UUID
    public let executionID: ExecutionID
    public let conversationID: ConversationID
    public let draft: MemoryDraft
    public let evidenceExcerpt: String
    public let createdAt: Date

    public var id: UUID { invocationID }

    public init(invocationID: UUID, executionID: ExecutionID, conversationID: ConversationID, draft: MemoryDraft, evidenceExcerpt: String, createdAt: Date) {
        self.invocationID = invocationID; self.executionID = executionID; self.conversationID = conversationID
        self.draft = draft; self.evidenceExcerpt = evidenceExcerpt; self.createdAt = createdAt
    }
}

/// Keeps approval state outside model-controlled tool arguments.
public actor MemoryApprovalCoordinator {
    private struct Pending {
        let request: MemoryApprovalRequest
        let proposal: CanonicalToolCall
        let continuation: CheckedContinuation<Bool, Error>
    }
    private struct Grant {
        let request: MemoryApprovalRequest
        let proposal: CanonicalToolCall
    }

    private var pendingRequests: [UUID: Pending] = [:]
    private var grants: [UUID: Grant] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var observers: [UUID: AsyncStream<[MemoryApprovalRequest]>.Continuation] = [:]
    private let clock: any RuntimeClock

    public init(clock: any RuntimeClock = RuntimeEnvironment().clock) {
        self.clock = clock
    }

    public func events() -> AsyncStream<[MemoryApprovalRequest]> {
        let observerID = UUID()
        let pair = AsyncStream<[MemoryApprovalRequest]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[observerID] = pair.continuation
        pair.continuation.yield(currentRequests())
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(observerID) }
        }
        return pair.stream
    }

    public func pending() -> [MemoryApprovalRequest] { currentRequests() }

    /// Host UI is the only public approval decision path.
    public func respond(_ id: UUID, approved: Bool) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        cancelTimeout(id)
        if approved { grants[id] = Grant(request: pending.request, proposal: pending.proposal) }
        pending.continuation.resume(returning: approved)
        publish()
    }

    /// Removes both pending requests and single-use grants for a terminal execution.
    public func cancel(executionID: ExecutionID) {
        let pendingIDs = pendingRequests.compactMap { $0.value.request.executionID == executionID ? $0.key : nil }
        for id in pendingIDs {
            guard let pending = pendingRequests.removeValue(forKey: id) else { continue }
            cancelTimeout(id)
            pending.continuation.resume(throwing: CancellationError())
        }
        grants = grants.filter { $0.value.request.executionID != executionID }
        if !pendingIDs.isEmpty { publish() }
    }

    // MARK: Internal tool coordination

    func awaitApproval(_ request: MemoryApprovalRequest, proposal: CanonicalToolCall) async throws -> Bool {
        try Task.checkCancellation()
        guard pendingRequests[request.id] == nil, grants[request.id] == nil else {
            throw MiraError(.conflict, "This memory proposal already has an approval decision.")
        }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard pendingRequests[request.id] == nil, grants[request.id] == nil else {
                    continuation.resume(throwing: MiraError(.conflict, "This memory proposal already has an approval decision."))
                    return
                }
                pendingRequests[request.id] = Pending(request: request, proposal: proposal, continuation: continuation)
                scheduleTimeout(for: request.id)
                publish()
            }
        }, onCancel: {
            Task { await self.cancelRequest(request.id) }
        })
    }

    func grantDirect(_ request: MemoryApprovalRequest, proposal: CanonicalToolCall) throws {
        try Task.checkCancellation()
        guard pendingRequests[request.id] == nil, grants[request.id] == nil else {
            throw MiraError(.conflict, "This memory proposal already has an approval decision.")
        }
        grants[request.id] = Grant(request: request, proposal: proposal)
    }

    func consumeGrant(invocationID: UUID, executionID: ExecutionID, proposal: CanonicalToolCall) throws {
        guard let grant = grants[invocationID], grant.request.executionID == executionID, grant.proposal == proposal else {
            throw MiraError(.unauthorized, "This memory proposal is not approved.")
        }
        grants[invocationID] = nil
    }

    private func cancelRequest(_ id: UUID) {
        guard let pending = pendingRequests.removeValue(forKey: id) else {
            grants[id] = nil
            return
        }
        cancelTimeout(id)
        pending.continuation.resume(throwing: CancellationError())
        publish()
    }

    private func scheduleTimeout(for id: UUID) {
        timeoutTasks[id]?.cancel()
        let clock = self.clock
        timeoutTasks[id] = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: .seconds(120))
                await self?.timeout(id)
            } catch { }
        }
    }

    private func timeout(_ id: UUID) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        timeoutTasks[id] = nil
        pending.continuation.resume(throwing: MiraError(.timeout, "Memory approval timed out."))
        publish()
    }

    private func cancelTimeout(_ id: UUID) {
        timeoutTasks[id]?.cancel()
        timeoutTasks[id] = nil
    }

    private func currentRequests() -> [MemoryApprovalRequest] {
        pendingRequests.values.map(\.request).sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func publish() {
        let requests = currentRequests()
        for observer in observers.values { observer.yield(requests) }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }
}
