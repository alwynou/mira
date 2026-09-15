import Foundation

public struct AgentSessionConsumerServiceLimits: Sendable {
    public var sessionsPerPage: Int
    public var batchesPerPass: Int
    public var reconciliationSeconds: Int
    public var pageDelayMilliseconds: Int
    public init(
        sessionsPerPage: Int = 32, batchesPerPass: Int = 8,
        reconciliationSeconds: Int = 30, pageDelayMilliseconds: Int = 100
    ) {
        self.sessionsPerPage = sessionsPerPage
        self.batchesPerPass = batchesPerPass
        self.reconciliationSeconds = reconciliationSeconds
        self.pageDelayMilliseconds = pageDelayMilliseconds
    }
    public func validate() throws {
        guard (1...128).contains(sessionsPerPage), (1...128).contains(batchesPerPass),
            (1...3_600).contains(reconciliationSeconds), (1...1_000).contains(pageDelayMilliseconds)
        else {
            throw MiraError(.configuration, "The session consumer service limits are invalid.")
        }
    }
}

/// All notifications are coalescible hints. Domain queues and business checkpoints remain authoritative.
public enum AgentSessionConsumerServiceEvent: Sendable, Equatable {
    case reconciled
    case advanced(AgentSessionConsumerCheckpoint)
    case failure(consumerID: String?, sessionID: ConversationID?, error: MiraError)
}

public enum AgentSessionConsumerServiceStatus: Sendable, Equatable {
    case running
    case failed(MiraError)
    case closed
}

/// A library-owned scheduler for registered durable consumers. It neither invokes a model
/// nor knows any domain job type. Composition opens it after maintenance/startup recovery,
/// and closes it before disposing consumer registrations or their underlying stores.
public actor AgentSessionConsumerService {
    private let journal: any SessionJournal
    private let registry: RuntimeRegistry<AgentCapability>
    private let coordinator: AgentSessionConsumerCoordinator
    private let lease: AgentLibraryAccessLease
    private let scope: RuntimeScope
    private let clock: any RuntimeClock
    private let limits: AgentSessionConsumerServiceLimits
    private var registration: UUID?
    private var runner: Task<Void, Never>?
    private var idleSleep: Task<Void, any Error>?
    private var closeTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<AgentSessionConsumerServiceEvent>.Continuation] = [:]
    private var closed = false
    private var terminalFailure: MiraError?
    private var wakeRequested = false
    private var cursor: ConversationID?
    private var sweepHadBacklog = false

    private init(
        journal: any SessionJournal, registry: RuntimeRegistry<AgentCapability>,
        coordinator: AgentSessionConsumerCoordinator, lease: AgentLibraryAccessLease,
        scope: RuntimeScope, clock: any RuntimeClock, limits: AgentSessionConsumerServiceLimits
    ) {
        self.journal = journal
        self.registry = registry
        self.coordinator = coordinator
        self.lease = lease
        self.scope = scope
        self.clock = clock
        self.limits = limits
    }

    public static func open(
        journal: any SessionJournal, registry: RuntimeRegistry<AgentCapability>,
        access: AgentLibraryAccess, scope: RuntimeScope,
        environment: RuntimeEnvironment = .init(),
        limits: AgentSessionConsumerServiceLimits = .init(),
        extensionSchemas: [String: Set<Int>] = [:]
    ) async throws -> AgentSessionConsumerService {
        try limits.validate()
        let coordinator = try AgentSessionConsumerCoordinator(
            journal: journal, registry: registry,
            extensionSchemas: extensionSchemas, maximumConcurrentPasses: 1)
        let lease = try await access.acquire(in: scope)
        let service = AgentSessionConsumerService(
            journal: journal, registry: registry, coordinator: coordinator,
            lease: lease, scope: scope, clock: environment.clock, limits: limits)
        do {
            // Revocation cancels the coordinator's real owner, not only a waiter on its result.
            try lease.bindCancellation { [weak service] in Task { await service?.close() } }
            let registration = try await scope.registerClosing { await service.close() }
            guard await service.install(registration) else {
                await scope.unregisterClosing(registration)
                throw Self.unavailable
            }
            try await lease.check()
            try await service.start()
            return service
        } catch {
            await service.close()
            throw error
        }
    }

    public func status() -> AgentSessionConsumerServiceStatus {
        if closed { return .closed }
        if let terminalFailure { return .failed(terminalFailure) }
        return .running
    }

    /// The initial hint also wakes a domain worker when no new journal batch is needed.
    public func events() throws -> AsyncStream<AgentSessionConsumerServiceEvent> {
        guard observers.count < 256 else {
            throw MiraError(.busy, "The session consumer observer limit was reached.")
        }
        let pair = AsyncStream<AgentSessionConsumerServiceEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
        guard !closed else {
            pair.continuation.finish()
            return pair.stream
        }
        let id = UUID()
        observers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        if let terminalFailure {
            pair.continuation.yield(.failure(consumerID: nil, sessionID: nil, error: terminalFailure))
        } else {
            pair.continuation.yield(.reconciled)
        }
        return pair.stream
    }

    /// A wake never resets the current page cursor: a hot session cannot starve later sessions.
    public func wake() {
        guard !closed else { return }
        wakeRequested = true
        idleSleep?.cancel()
    }

    public func close() async {
        if let closeTask {
            await closeTask.value
            return
        }
        closed = true
        runner?.cancel()
        idleSleep?.cancel()
        let runner = runner
        let coordinator = coordinator
        let lease = lease
        let scope = scope
        let registration = registration
        let task = Task {
            await coordinator.close()
            await runner?.value
            await lease.release()
            if let registration { await scope.unregisterClosing(registration) }
        }
        closeTask = task
        await task.value
        for continuation in observers.values { continuation.finish() }
        observers.removeAll()
    }

    private func install(_ registration: UUID) -> Bool {
        guard !closed else { return false }
        self.registration = registration
        return true
    }

    private func start() throws {
        try Task.checkCancellation()
        guard !closed, runner == nil else { throw Self.unavailable }
        runner = Task { await self.run() }
    }

    private func run() async {
        while !closed && !Task.isCancelled {
            var continuing = false
            do { continuing = try await page() } catch is CancellationError { return } catch {
                if closed || Task.isCancelled { return }
                emit(.failure(consumerID: nil, sessionID: nil, error: Self.safe(error)))
                // Preserve the failed enumeration position, but avoid spinning on storage failure.
            }
            emit(.reconciled)
            do {
                // Even a flood of wakes cannot remove the scheduling break between finite pages.
                try await clock.sleep(for: .milliseconds(limits.pageDelayMilliseconds))
                try Task.checkCancellation()
                if !continuing && !wakeRequested {
                    let clock = clock
                    let delay = limits.reconciliationSeconds
                    let task = Task { try await clock.sleep(for: .seconds(delay)) }
                    idleSleep = task
                    do { try await task.value } catch is CancellationError { if Task.isCancelled { return } }
                    idleSleep = nil
                }
                if cursor == nil { wakeRequested = false }
            } catch {
                if closed || Task.isCancelled { return }
                terminalFailure = Self.safe(error)
                emit(.failure(consumerID: nil, sessionID: nil, error: Self.safe(error)))
                // A broken clock is a service failure, not permission to run an unthrottled loop.
                return
            }
        }
    }

    /// One page of canonical session IDs, one captured prefix per session, and one finite pass
    /// per currently registered consumer. No unbounded backlog or session list is retained.
    private func page() async throws -> Bool {
        let registry = registry
        let identities = try await lease.read {
            let snapshot = try await registry.freeze()
            let catalog: AgentRuntimeCatalog
            do { catalog = try AgentRuntimeCatalog(snapshot: snapshot) } catch {
                await snapshot.release()
                throw error
            }
            let identities = catalog.consumerIdentities
            await catalog.release()
            return identities
        }
        guard !identities.isEmpty else {
            cursor = nil
            sweepHadBacklog = false
            return false
        }
        let journal = journal
        let previous = cursor
        let pageSize = limits.sessionsPerPage
        let sessions = try await lease.read { try await journal.sessions(after: previous, limit: pageSize) }
        guard sessions.count <= pageSize, Set(sessions).count == sessions.count,
            sessions == sessions.sorted(by: Self.precedes),
            previous.map({ prior in sessions.allSatisfy { Self.precedes(prior, $0) } }) ?? true
        else {
            throw MiraError(.storage, "The journal session page is invalid.")
        }
        for sessionID in sessions {
            try await lease.check()
            let target: SessionJournalHead
            do {
                target = try await lease.read { try await journal.head(sessionID: sessionID) }
                try target.validate()
                guard target.cursor.sessionID == sessionID else {
                    throw MiraError(.storage, "The journal session page is invalid.")
                }
            } catch {
                try await lease.check()
                emit(.failure(consumerID: nil, sessionID: sessionID, error: Self.safe(error)))
                continue
            }
            for identity in identities {
                try await lease.check()
                let coordinator = coordinator
                let batchLimit = limits.batchesPerPass
                do {
                    let progress = try await lease.read {
                        try await coordinator.advance(
                            consumerID: identity.id, through: target, maximumBatches: batchLimit)
                    }
                    sweepHadBacklog = sweepHadBacklog || progress.hasMore
                    if progress.processedBatches > 0 { emit(.advanced(progress.checkpoint)) }
                } catch {
                    try await lease.check()
                    emit(.failure(consumerID: identity.id, sessionID: sessionID, error: Self.safe(error)))
                }
            }
            await Task.yield()
        }
        if sessions.count == pageSize {
            cursor = sessions.last
            return true
        }
        cursor = nil
        let backlog = sweepHadBacklog
        sweepHadBacklog = false
        return backlog
    }

    private static func precedes(_ a: ConversationID, _ b: ConversationID) -> Bool {
        a.rawValue.uuidString < b.rawValue.uuidString
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func emit(_ event: AgentSessionConsumerServiceEvent) {
        for continuation in observers.values { continuation.yield(event) }
    }
    private static var unavailable: MiraError { .init(.cancelled, "The session consumer service is closed.") }
    private static func safe(_ error: any Error) -> MiraError {
        if let error = error as? MiraError { return error }
        return .init(.storage, "Session consumer reconciliation did not complete.")
    }
}
