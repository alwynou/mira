import Foundation

public struct RuntimeApprovalRequest: Identifiable, Sendable, Equatable {
    public let invocationID: UUID
    public let executionID: ExecutionID
    public let proposalHash: String
    public let authorizationEpoch: UInt64
    public let expiresAt: Date
    public let prompt: String

    public var id: UUID { invocationID }

    public init(invocationID: UUID = UUID(), executionID: ExecutionID, proposalHash: String, authorizationEpoch: UInt64, expiresAt: Date, prompt: String) {
        self.invocationID = invocationID
        self.executionID = executionID
        self.proposalHash = proposalHash
        self.authorizationEpoch = authorizationEpoch
        self.expiresAt = expiresAt
        self.prompt = prompt
    }
}

public enum RuntimeApprovalDecision: Sendable, Equatable {
    case approved
    case denied
}

/// One-shot approval coordination independent of any UI channel.
public actor RuntimeApprovalService {
    private struct Pending {
        let request: RuntimeApprovalRequest
        let generation: UUID
        let continuation: CheckedContinuation<RuntimeApprovalDecision, Error>
    }

    private var pending: [UUID: Pending] = [:]
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]
    private var observers: [UUID: AsyncStream<[RuntimeApprovalRequest]>.Continuation] = [:]
    private var consumed: Set<UUID> = []
    private var stopped = false
    private let environment: RuntimeEnvironment

    public init(environment: RuntimeEnvironment = .init()) {
        self.environment = environment
    }

    public func snapshots() -> AsyncStream<[RuntimeApprovalRequest]> {
        if stopped {
            let stream = AsyncStream<[RuntimeApprovalRequest]> { continuation in continuation.finish() }
            return stream
        }
        let observerID = environment.uuid()
        let pair = AsyncStream<[RuntimeApprovalRequest]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[observerID] = pair.continuation
        pair.continuation.yield(currentRequests())
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(observerID) }
        }
        return pair.stream
    }

    public func request(_ request: RuntimeApprovalRequest) async throws -> RuntimeApprovalDecision {
        try Task.checkCancellation()
        guard !stopped else { throw MiraError(.cancelled, "Approval service is shut down.") }
        guard !observers.isEmpty else { throw MiraError(.unauthorized, "Approval is unavailable.") }
        let now = environment.now()
        let remaining = request.expiresAt.timeIntervalSince(now)
        guard request.proposalHash.isEmpty == false && request.proposalHash.utf8.count <= 4096,
              request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              request.prompt.utf8.count <= 4096,
              now.timeIntervalSinceReferenceDate.isFinite,
              request.expiresAt.timeIntervalSinceReferenceDate.isFinite,
              remaining > 0 && remaining <= 86_400 else {
            throw MiraError(.invalidInput, "Approval request is invalid.")
        }
        guard !consumed.contains(request.id) else {
            throw MiraError(.conflict, "This approval request has already been consumed.")
        }
        guard pending[request.id] == nil else {
            throw MiraError(.conflict, "This approval request is already pending.")
        }
        let generation = environment.uuid()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard pending[request.id] == nil else {
                    continuation.resume(throwing: MiraError(.conflict, "This approval request is already pending."))
                    return
                }
                pending[request.id] = Pending(request: request, generation: generation, continuation: continuation)
                scheduleExpiry(request, generation: generation)
                publish()
            }
        }, onCancel: {
            Task { await self.cancelRequest(request.id, generation: generation) }
        })
    }

    public func resolve(id: UUID, proposalHash: String, authorizationEpoch: UInt64, decision: RuntimeApprovalDecision) throws {
        guard let item = pending[id] else { throw MiraError(.notFound, "Approval request is no longer pending.") }
        let now = environment.now()
        guard now.timeIntervalSinceReferenceDate.isFinite, now < item.request.expiresAt else {
            pending[id] = nil
            consumed.insert(id)
            cancelExpiry(id)
            item.continuation.resume(throwing: MiraError(.timeout, "Approval request expired."))
            publish()
            throw MiraError(.timeout, "Approval request expired.")
        }
        guard item.request.proposalHash == proposalHash else { throw MiraError(.unauthorized, "Approval proposal no longer matches.") }
        guard item.request.authorizationEpoch == authorizationEpoch else { throw MiraError(.unauthorized, "Approval authorization is stale.") }
        pending[id] = nil
        consumed.insert(id)
        cancelExpiry(id)
        item.continuation.resume(returning: decision)
        publish()
    }

    public func cancel(executionID: ExecutionID) {
        let entries = pending.compactMap { $0.value.request.executionID == executionID ? ($0.key, $0.value.generation) : nil }
        for (id, generation) in entries { cancelRequest(id, generation: generation) }
    }

    public func shutdown() {
        guard !stopped else { return }
        stopped = true
        let entries = pending.map { ($0.key, $0.value.generation) }
        for (id, generation) in entries { deny(id, generation: generation, error: MiraError(.cancelled, "Approval service is shutting down.")) }
        for observer in observers.values { observer.finish() }
        observers.removeAll()
    }

    private func scheduleExpiry(_ request: RuntimeApprovalRequest, generation: UUID) {
        guard !stopped, pending[request.id]?.generation == generation else { return }
        let environment = self.environment
        expiryTasks[request.id]?.cancel()
        expiryTasks[request.id] = Task { [weak self] in
            do {
                let now = environment.now()
                let remaining = request.expiresAt.timeIntervalSince(now)
                guard now.timeIntervalSinceReferenceDate.isFinite, remaining.isFinite, remaining > 0 else {
                    await self?.deny(request.id, generation: generation, error: MiraError(.timeout, "Approval request expired."))
                    return
                }
                try await environment.clock.sleep(for: remaining.asDuration)
                let afterSleep = environment.now()
                if afterSleep.timeIntervalSinceReferenceDate.isFinite, afterSleep < request.expiresAt {
                    await self?.scheduleExpiry(request, generation: generation)
                } else {
                    await self?.expire(request.id, generation: generation)
                }
            } catch is CancellationError { }
            catch { await self?.deny(request.id, generation: generation, error: MiraError(.timeout, "Approval request could not be timed.")) }
        }
    }

    private func expire(_ id: UUID, generation: UUID) {
        guard let current = pending[id], current.generation == generation,
              let item = pending.removeValue(forKey: id) else { return }
        consumed.insert(id)
        expiryTasks[id] = nil
        item.continuation.resume(throwing: MiraError(.timeout, "Approval request expired."))
        publish()
    }

    private func cancelRequest(_ id: UUID, generation: UUID?) {
        guard let item = pending[id], generation == nil || item.generation == generation else { return }
        pending[id] = nil
        consumed.insert(id)
        cancelExpiry(id)
        item.continuation.resume(throwing: CancellationError())
        publish()
    }

    private func deny(_ id: UUID, generation: UUID? = nil, error: Error) {
        guard let item = pending[id], generation == nil || item.generation == generation else { return }
        pending[id] = nil
        consumed.insert(id)
        cancelExpiry(id)
        item.continuation.resume(throwing: error)
        publish()
    }

    private func cancelExpiry(_ id: UUID) { expiryTasks.removeValue(forKey: id)?.cancel() }
    private func currentRequests() -> [RuntimeApprovalRequest] { pending.values.map(\.request).sorted { $0.id.uuidString < $1.id.uuidString } }
    private func publish() { let snapshot = currentRequests(); observers.values.forEach { $0.yield(snapshot) } }
    private func removeObserver(_ id: UUID) {
        observers[id] = nil
        guard observers.isEmpty else { return }
        let entries = pending.map { ($0.key, $0.value.generation) }
        for (requestID, generation) in entries { deny(requestID, generation: generation, error: MiraError(.cancelled, "Approval interface disconnected.")) }
    }
}

private extension TimeInterval {
    var asDuration: Duration {
        let milliseconds = min(max(0, self), 86_400) * 1_000
        return .milliseconds(Int64(milliseconds.rounded(.down)))
    }
}
