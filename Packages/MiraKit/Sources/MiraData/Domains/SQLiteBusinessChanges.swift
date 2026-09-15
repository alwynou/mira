import Foundation
import GRDB
import MiraCore

/// Publishes process-local, content-free wakeups after committed SQLite transactions.
public final class SQLiteBusinessChanges: AgentBusinessChangeSource, TransactionObserver, @unchecked Sendable {
    private let database: DatabaseQueue
    private let stateQueue = DispatchQueue(label: "mira.business-changes.state")
    private var subscribers: [UUID: AsyncStream<AgentBusinessChangeObservation>.Continuation] = [:]
    private var revision: UInt64 = 0
    private var changedInTransaction = false
    private var closed = false
    private var closeStarted = false
    private var closeFinished = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(database: DatabaseQueue) {
        self.database = database
        database.add(transactionObserver: self)
    }

    public func observe() async throws -> AsyncStream<AgentBusinessChangeObservation> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.removeSubscriber(id)
            }
            self.stateQueue.sync {
                guard !self.closed else {
                    continuation.yield(.init(revision: self.revision, isClosed: true))
                    continuation.finish()
                    return
                }
                self.subscribers[id] = continuation
                continuation.yield(.init(revision: self.revision))
            }
        }
    }

    public func close() async {
        await withCheckedContinuation { continuation in
            var owner = false
            var pending: (UInt64, [AsyncStream<AgentBusinessChangeObservation>.Continuation])?
            stateQueue.sync {
                if closeFinished {
                    continuation.resume()
                    return
                }
                closeWaiters.append(continuation)
                guard !closeStarted else { return }
                closeStarted = true
                closed = true
                pending = (revision, Array(subscribers.values))
                subscribers.removeAll()
                owner = true
            }
            if owner, let pending {
                Task { await self.finishClose(revision: pending.0, subscribers: pending.1) }
            }
        }
    }

    private func finishClose(
        revision: UInt64,
        subscribers: [AsyncStream<AgentBusinessChangeObservation>.Continuation]
    ) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                self.database.remove(transactionObserver: self)
                continuation.resume()
            }
        }
        let observation = AgentBusinessChangeObservation(revision: revision, isClosed: true)
        subscribers.forEach {
            _ = $0.yield(observation)
            $0.finish()
        }
        let waiters = stateQueue.sync { () -> [CheckedContinuation<Void, Never>] in
            closeFinished = true
            let waiters = closeWaiters
            closeWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    public var databaseEventObservationStrategy: DatabaseEventObservationStrategy { .default }

    public func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
    public func databaseDidChange() { markChanged() }
    public func databaseDidChange(with event: DatabaseEvent) { markChanged() }

    public func databaseDidCommit(_ db: Database) {
        stateQueue.sync {
            guard changedInTransaction else { return }
            changedInTransaction = false
            guard !closed else { return }
            revision += 1
            let observation = AgentBusinessChangeObservation(revision: revision)
            subscribers.values.forEach { _ = $0.yield(observation) }
        }
    }

    public func databaseDidRollback(_ db: Database) {
        stateQueue.sync { changedInTransaction = false }
    }

    private func markChanged() {
        stateQueue.sync { changedInTransaction = true }
    }

    private func removeSubscriber(_ id: UUID) {
        stateQueue.async { self.subscribers[id] = nil }
    }
}
