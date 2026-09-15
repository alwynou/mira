import Foundation

public enum RuntimePriority: String, Sendable, Codable, Equatable {
    case foreground
    case background
}

/// A releasable reservation for one model execution attempt.
public final class RuntimeLease: Sendable {
    private let releaseAction: @Sendable () async -> Void

    fileprivate init(releaseAction: @escaping @Sendable () async -> Void) {
        self.releaseAction = releaseAction
    }

    public func release() async {
        await releaseAction()
    }
}

/// Bounded, fair scheduling of execution attempts.
public actor RuntimeScheduler {
    private struct Waiter {
        let token: UUID
        let executionID: ExecutionID
        let priority: RuntimePriority
        let continuation: CheckedContinuation<RuntimeLease, Error>
    }

    private let modelCapacity: Int
    private let backgroundCapacity: Int
    private let foregroundBurstLimit = 3
    private var foregroundBurst = 0
    private var active: [UUID: RuntimePriority] = [:]
    private var activeExecutions: Set<ExecutionID> = []
    private var foregroundQueue: [Waiter] = []
    private var backgroundQueue: [Waiter] = []
    private var stopped = false

    public init(modelCapacity: Int = 2, backgroundCapacity: Int = 1) {
        precondition(modelCapacity > 0, "modelCapacity must be greater than zero")
        precondition(backgroundCapacity >= 0 && backgroundCapacity <= modelCapacity, "backgroundCapacity must be within modelCapacity")
        self.modelCapacity = modelCapacity
        self.backgroundCapacity = backgroundCapacity
    }

    public func acquire(executionID: ExecutionID, priority: RuntimePriority) async throws -> RuntimeLease {
        try Task.checkCancellation()
        guard !stopped else { throw MiraError(.busy, "The runtime is shutting down.") }
        guard priority != .background || backgroundCapacity > 0 else {
            throw MiraError(.unsupported, "Background execution is disabled.")
        }
        guard !activeExecutions.contains(executionID),
              !foregroundQueue.contains(where: { $0.executionID == executionID }),
              !backgroundQueue.contains(where: { $0.executionID == executionID }) else {
            throw MiraError(.conflict, "This execution already has an active attempt.")
        }

        let token = UUID()
        let lease = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let waiter = Waiter(token: token, executionID: executionID, priority: priority, continuation: continuation)
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    if priority == .foreground { foregroundQueue.append(waiter) }
                    else { backgroundQueue.append(waiter) }
                    pump()
                }
            }
        }, onCancel: {
            Task { await self.cancelQueued(token: token) }
        })
        if Task.isCancelled {
            await lease.release()
            throw CancellationError()
        }
        return lease
    }

    /// Stops admission and rejects all queued requests. Existing leases remain valid.
    public func shutdown() {
        guard !stopped else { return }
        stopped = true
        let queued = foregroundQueue + backgroundQueue
        foregroundQueue.removeAll(); backgroundQueue.removeAll()
        for waiter in queued { waiter.continuation.resume(throwing: MiraError(.cancelled, "The runtime is shutting down.")) }
    }

    private func cancelQueued(token: UUID) {
        if let index = foregroundQueue.firstIndex(where: { $0.token == token }) {
            let waiter = foregroundQueue.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        if let index = backgroundQueue.firstIndex(where: { $0.token == token }) {
            let waiter = backgroundQueue.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    private func pump() {
        while active.count < modelCapacity {
            let chooseBackground = !backgroundQueue.isEmpty &&
                (foregroundQueue.isEmpty || foregroundBurst >= foregroundBurstLimit)
            let waiter: Waiter?
            if chooseBackground && backgroundCapacityAvailable {
                waiter = backgroundQueue.removeFirst()
            } else if !foregroundQueue.isEmpty {
                waiter = foregroundQueue.removeFirst()
            } else if !backgroundQueue.isEmpty && backgroundCapacityAvailable {
                waiter = backgroundQueue.removeFirst()
            } else {
                waiter = nil
            }
            guard let waiter else { break }
            active[waiter.token] = waiter.priority
            activeExecutions.insert(waiter.executionID)
            if waiter.priority == .foreground { foregroundBurst = min(foregroundBurst + 1, foregroundBurstLimit) } else { foregroundBurst = 0 }
            let lease = RuntimeLease { [weak self] in
                await self?.release(token: waiter.token, executionID: waiter.executionID)
            }
            waiter.continuation.resume(returning: lease)
        }
    }

    private var backgroundCapacityAvailable: Bool {
        active.values.filter { $0 == .background }.count < backgroundCapacity
    }

    private func release(token: UUID, executionID: ExecutionID) {
        guard active.removeValue(forKey: token) != nil else { return }
        activeExecutions.remove(executionID)
        pump()
    }
}
