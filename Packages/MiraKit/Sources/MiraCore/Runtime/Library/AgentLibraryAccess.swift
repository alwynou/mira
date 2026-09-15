import Foundation

public enum AgentLibraryAccessPhase: Sendable, Equatable {
    case ready, snapshotting, beginningMaintenance, maintenance, completingMaintenance, uncertain, closing, closed
}

public struct AgentLibraryAccessSnapshot: Sendable, Equatable {
    public let phase: AgentLibraryAccessPhase
    public let authorization: AgentLibraryAuthorization
    public let pending: AgentLibraryMaintenanceOperation?
    public let activeLeases: Int
    public let acquiringLeases: Int
    public let activeReads: Int
    public let activeResources: Int
}

/// A factory may synchronously create an owned operation, but must not perform blocking work.
/// Closing the resource must cancel and drain its actual producer, not merely stop observation.
public struct AgentLibraryResource<Value: Sendable>: Sendable {
    public let value: Value
    fileprivate let cleanup: @Sendable () async -> Void
    public init(value: Value, cleanup: @escaping @Sendable () async -> Void) {
        self.value = value; self.cleanup = cleanup
    }
}

/// The composition owner routes all live maintenance transitions through this gate.
/// The underlying store remains available to recovery before ordinary access is opened.
public actor AgentLibraryAccess {
    public nonisolated let libraryID: UUID
    private let store: any AgentLibraryMaintenanceStore
    private let maximumLeases: Int
    private var authorization: AgentLibraryAuthorization
    private var pending: AgentLibraryMaintenanceOperation?
    private var phase: AgentLibraryAccessPhase
    private var leases: [UUID: Entry] = [:]
    private var acquiring = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var cancellableWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var transition: Task<AgentLibraryMaintenanceOperation, any Error>?
    private var intent: Intent?
    private var shutdown: Task<Void, Never>?
    private var snapshotWork: SnapshotWork?

    private struct SnapshotWork {
        let cancel: @Sendable () -> Void
        let drain: @Sendable () async -> Void
    }

    var pendingQuiescenceWaiterCount: Int { cancellableWaiters.count }
    var pendingLeaseReleaseCount: Int { leases.values.filter(\.releasing).count }

    private enum Intent: Equatable {
        case begin(AgentLibraryMaintenanceRequest, AgentLibraryAuthorization)
        case complete(AgentLibraryMaintenanceOperation, Date)
    }
    private struct Entry {
        let scope: RuntimeScope
        let scopeLease: RuntimeScopeLease
        let closingRegistration: UUID
        let signal: AgentLibraryRevocation
        var reads = 0
        var releasing = false
        var resources: [UUID: RuntimeRelease] = [:]
        var drain: Task<Void, Never>?
    }

    private init(store: any AgentLibraryMaintenanceStore, state: AgentLibraryMaintenanceState, maximumLeases: Int) {
        self.store = store; authorization = state.authorization; pending = state.pending
        libraryID = state.authorization.libraryID; self.maximumLeases = maximumLeases
        phase = state.pending == nil ? .ready : .maintenance
    }

    public static func open(store: any AgentLibraryMaintenanceStore, maximumLeases: Int = 1_024) async throws -> AgentLibraryAccess {
        guard (1...16_384).contains(maximumLeases) else { throw MiraError(.configuration, "The library access limit is invalid.") }
        let state = try await store.state()
        if let pending = state.pending {
            try pending.validate()
            guard pending.completedAt == nil, pending.authorization == state.authorization else {
                throw MiraError(.storage, "The library maintenance state is inconsistent.")
            }
        }
        return .init(store: store, state: state, maximumLeases: maximumLeases)
    }

    public func checkReady() throws { try Task.checkCancellation(); try requireReady() }

    /// Maintenance metadata remains readable while access is uncertain. It grants no body access.
    public func operation(id: UUID) async throws -> AgentLibraryMaintenanceOperation? {
        try requireNotClosing()
        let operation = try await store.operation(id: id)
        try requireNotClosing()
        if let operation {
            try operation.validate()
            guard operation.request.id == id, operation.authorization.libraryID == libraryID else {
                throw Self.conflict
            }
        }
        return operation
    }

    /// A replacement coordinator may reconcile the gate's accepted completion without inventing
    /// a new date or repeating verified domain work. The gate remains the sole owner of this intent.
    func retryCompletion(for request: AgentLibraryMaintenanceRequest,
                         expected: AgentLibraryAuthorization) async throws -> AgentLibraryMaintenanceOperation? {
        try requireNotClosing()
        guard let intent, case .complete(let operation, _) = intent,
              operation.request == request, operation.previousAuthorization == expected else { return nil }
        if let transition { return try await transition.value }
        guard phase == .uncertain else { throw Self.conflict }
        return try await start(intent)
    }

    public func snapshot() -> AgentLibraryAccessSnapshot {
        .init(phase: phase, authorization: authorization, pending: pending,
              activeLeases: leases.count, acquiringLeases: acquiring,
              activeReads: leases.values.reduce(0) { $0 + $1.reads },
              activeResources: leases.values.reduce(0) { $0 + $1.resources.count })
    }

    /// A scope cannot finish disposal while its library lease still owns work or body reads.
    public func acquire(in scope: RuntimeScope) async throws -> AgentLibraryAccessLease {
        try Task.checkCancellation(); try requireReady()
        guard leases.count + acquiring < maximumLeases else { throw MiraError(.busy, "The library access limit was reached.") }
        acquiring += 1
        defer { acquiring -= 1; wakeWaiters() }
        let scopeLease = try await scope.acquireLease()
        let id = UUID(), signal = AgentLibraryRevocation()
        var registration: UUID?
        do {
            registration = try await scope.registerClosing { signal.revoke(); await self.revoke(id) }
            try Task.checkCancellation(); try requireReady()
            guard let registration, !signal.isRevoked else { throw Self.unavailable }
            leases[id] = .init(scope: scope, scopeLease: scopeLease, closingRegistration: registration, signal: signal)
            return AgentLibraryAccessLease(gate: self, id: id, authorization: authorization, signal: signal)
        } catch {
            if let registration { await scope.unregisterClosing(registration) }
            await scopeLease.release()
            throw error
        }
    }

    /// This returns after the durable intent, without pretending that revoked owners have drained.
    public func begin(_ request: AgentLibraryMaintenanceRequest,
                      expected: AgentLibraryAuthorization) async throws -> AgentLibraryMaintenanceOperation {
        try request.validate()
        let desired = Intent.begin(request, expected)
        try requireNotClosing()
        if let intent, intent == desired {
            if let transition { return try await transition.value }
            if phase == .uncertain { return try await start(desired) }
        }
        if let pending, pending.request == request, pending.previousAuthorization == expected { return pending }
        // Repeating a completed command cannot revoke leases belonging to a newer epoch.
        if let existing = try await store.operation(id: request.id) {
            try requireNotClosing()
            guard existing.request == request, existing.previousAuthorization == expected,
                  existing.authorization.libraryID == libraryID, existing.authorization.epoch <= authorization.epoch,
                  existing.completedAt != nil else { throw Self.conflict }
            return existing
        }
        try requireReady()
        guard authorization == expected else { throw Self.conflict }
        return try await start(desired)
    }

    /// Only the maintenance owner calls this after verifying domain, journal and body cleanup.
    /// A live read, producer, scope acquisition, or unreleased work lease prevents completion.
    public func complete(_ operation: AgentLibraryMaintenanceOperation, at date: Date) async throws -> AgentLibraryMaintenanceOperation {
        try operation.validate(); try requireNotClosing()
        guard date.timeIntervalSince1970.isFinite else { throw Self.conflict }
        let desired = Intent.complete(operation, date)
        if let intent, intent == desired {
            if let transition { return try await transition.value }
            if phase == .uncertain { return try await start(desired) }
        }
        if pending != operation {
            guard let existing = try await store.operation(id: operation.request.id),
                  existing.request == operation.request, existing.previousAuthorization == operation.previousAuthorization,
                  existing.authorization == operation.authorization, existing.authorization.libraryID == libraryID,
                  existing.authorization.epoch <= authorization.epoch, existing.completedAt != nil else { throw Self.conflict }
            try requireNotClosing()
            return existing
        }
        guard phase == .maintenance else { throw Self.conflict }
        guard leases.isEmpty, acquiring == 0 else { throw MiraError(.busy, "Library access has not drained.") }
        return try await start(desired)
    }

    /// Cancellation stops only this wait. It cannot reopen access or release another owner's lease.
    public func waitForQuiescence() async throws {
        guard phase != .ready else { throw Self.conflict }
        while !leases.isEmpty || acquiring != 0 {
            try Task.checkCancellation()
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { cancellableWaiters[id] = $0 }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        }
        try Task.checkCancellation()
    }

    /// The coordinator has drained every revoked owner. An acknowledged absence check can
    /// resolve a rejected start without manufacturing a completed maintenance operation.
    func reconcileUnstartedMaintenance(_ request: AgentLibraryMaintenanceRequest,
                                       expected: AgentLibraryAuthorization) async throws -> Bool {
        let desired = Intent.begin(request, expected)
        guard phase == .uncertain, intent == desired, transition == nil,
              leases.isEmpty, acquiring == 0, authorization == expected else { return false }
        let state = try await store.state()
        let operation = try await store.operation(id: request.id)
        guard phase == .uncertain, intent == desired, transition == nil,
              leases.isEmpty, acquiring == 0, authorization == expected,
              state.authorization == expected, state.pending == nil, operation == nil else { return false }
        pending = nil; intent = nil; phase = .ready
        wakeWaiters()
        return true
    }

    /// The coordinator supplies the complete producer drain. Export is a read-only operation
    /// against this library: it may publish a separate artifact, never mutate live authority.
    /// The gate owns the task so closing cannot outlive its actual I/O or revive old leases.
    func withQuiescentSnapshot<Value: Sendable>(
        expected: AgentLibraryAuthorization,
        quiesce: @escaping @Sendable () async throws -> Void,
        operation: @escaping @Sendable (AgentLibraryAuthorization) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation(); try requireReady()
        guard authorization == expected, snapshotWork == nil, pending == nil, intent == nil,
              transition == nil else { throw Self.conflict }
        phase = .snapshotting
        revokeAll()
        let task = Task {
            defer { self.snapshotWork = nil; self.wakeWaiters() }
            return try await self.executeSnapshot(expected: expected, quiesce: quiesce, operation: operation)
        }
        snapshotWork = .init(cancel: { task.cancel() }, drain: { _ = await task.result })
        return try await task.value
    }

    private func executeSnapshot<Value: Sendable>(
        expected: AgentLibraryAuthorization,
        quiesce: @Sendable () async throws -> Void,
        operation: @Sendable (AgentLibraryAuthorization) async throws -> Value
    ) async throws -> Value {
        var drained = false
        do {
            try await quiesce()
            try await waitForQuiescence()
            try await verifySnapshotAuthority(expected)
            try requireSnapshot(expected)
            drained = true
            let result = try await operation(expected)
            try await verifySnapshotAuthority(expected)
            try requireSnapshot(expected)
            phase = .ready
            return result
        } catch {
            let original = error
            // A failed artifact does not create durable maintenance intent. Reopen only after
            // producer drain and a fresh authority proof; failed quiescence requires recreation.
            if phase == .snapshotting {
                if drained {
                    do { try await verifySnapshotAuthority(expected); try requireSnapshot(expected); phase = .ready }
                    catch { if phase == .snapshotting { phase = .uncertain } }
                } else { phase = .uncertain }
            }
            throw original
        }
    }

    private func verifySnapshotAuthority(_ expected: AgentLibraryAuthorization) async throws {
        try requireSnapshot(expected)
        let state = try await store.state()
        try requireSnapshot(expected)
        guard state.authorization == expected, state.pending == nil else { throw Self.conflict }
    }

    private func requireSnapshot(_ expected: AgentLibraryAuthorization) throws {
        try Task.checkCancellation()
        guard phase == .snapshotting, authorization == expected, pending == nil,
              intent == nil, transition == nil, leases.isEmpty, acquiring == 0 else { throw Self.conflict }
    }

    public func close() async {
        if let shutdown { await shutdown.value; return }
        phase = .closing; revokeAll(); snapshotWork?.cancel()
        let task = Task { await self.finishClose() }
        shutdown = task
        await task.value
    }

    private func start(_ desired: Intent) async throws -> AgentLibraryMaintenanceOperation {
        intent = desired
        phase = switch desired { case .begin: .beginningMaintenance; case .complete: .completingMaintenance }
        revokeAll()
        let task = Task { try await self.persist(desired) }
        transition = task
        return try await task.value
    }

    private func persist(_ desired: Intent) async throws -> AgentLibraryMaintenanceOperation {
        do {
            let result: AgentLibraryMaintenanceOperation
            switch desired {
            case .begin(let request, let expected): result = try await store.begin(request, expected: expected)
            case .complete(let operation, let date): result = try await store.complete(operation, at: date)
            }
            try result.validate()
            guard result.authorization.libraryID == libraryID else { throw Self.conflict }
            switch desired {
            case .begin(let request, let expected):
                guard result.request == request, result.previousAuthorization == expected else { throw Self.conflict }
            case .complete(let operation, _):
                guard result.request == operation.request, result.previousAuthorization == operation.previousAuthorization,
                      result.authorization == operation.authorization, result.completedAt != nil else { throw Self.conflict }
            }
            authorization = result.authorization
            pending = result.completedAt == nil ? result : nil
            transition = nil; intent = nil
            if phase != .closing { phase = pending == nil ? .ready : .maintenance }
            wakeWaiters()
            return result
        } catch {
            transition = nil
            if phase != .closing { phase = .uncertain }
            wakeWaiters()
            throw error
        }
    }

    fileprivate func check(_ id: UUID, authorization expected: AgentLibraryAuthorization) throws {
        try Task.checkCancellation(); try requireReady()
        guard authorization == expected, let entry = leases[id], !entry.releasing, !entry.signal.isRevoked else {
            throw Self.unavailable
        }
    }

    fileprivate func read<T: Sendable>(id: UUID, authorization: AgentLibraryAuthorization,
                                       operation: @Sendable () async throws -> T) async throws -> T {
        try check(id, authorization: authorization)
        leases[id]?.reads += 1
        defer { leases[id]?.reads -= 1; wakeWaiters() }
        let value = try await operation()
        try check(id, authorization: authorization)
        return value
    }

    /// Admission and resource registration are synchronous within the same gate turn.
    fileprivate func startResource<T: Sendable>(_ factory: @Sendable () -> AgentLibraryResource<T>, id: UUID,
                                                authorization: AgentLibraryAuthorization) throws -> AgentLibraryResourceLease<T> {
        try check(id, authorization: authorization)
        guard (leases[id]?.resources.count ?? 0) < 256 else {
            throw MiraError(.busy, "The library lease resource limit was reached.")
        }
        let resource = factory(), resourceID = UUID()
        leases[id]?.resources[resourceID] = RuntimeRelease(resource.cleanup)
        return .init(value: resource.value, cleanup: { await self.releaseResource(resourceID, leaseID: id) })
    }

    private func releaseResource(_ resourceID: UUID, leaseID: UUID) async {
        guard let owner = leases[leaseID]?.resources[resourceID] else { return }
        await owner.release()
        leases[leaseID]?.resources.removeValue(forKey: resourceID)
        wakeWaiters()
    }

    fileprivate func release(_ id: UUID) async {
        guard let entry = leases[id] else { return }
        leases[id]?.releasing = true
        revoke(id, cancelOwner: false)
        while leases[id]?.reads ?? 0 > 0 {
            await withCheckedContinuation { waiters.append($0) }
        }
        await leases[id]?.drain?.value
        await entry.scope.unregisterClosing(entry.closingRegistration)
        await entry.scopeLease.release()
        leases.removeValue(forKey: id); wakeWaiters()
    }

    private func revoke(_ id: UUID, cancelOwner: Bool = true) {
        guard let entry = leases[id] else { return }
        entry.signal.revoke(cancelOwner: cancelOwner)
        guard entry.drain == nil else { return }
        let resources = Array(entry.resources.values)
        leases[id]?.drain = Task {
            await withTaskGroup(of: Void.self) { group in
                for resource in resources { group.addTask { await resource.release() } }
            }
        }
    }
    private func revokeAll() { for id in Array(leases.keys) { revoke(id) }; wakeWaiters() }
    private func finishClose() async {
        _ = await transition?.result
        await snapshotWork?.drain()
        while !leases.isEmpty || acquiring != 0 { await withCheckedContinuation { waiters.append($0) } }
        phase = .closed; wakeWaiters()
    }
    private func cancelWaiter(_ id: UUID) { cancellableWaiters.removeValue(forKey: id)?.resume() }
    private func wakeWaiters() {
        let pending = waiters + Array(cancellableWaiters.values)
        waiters.removeAll(); cancellableWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
    private func requireReady() throws { guard phase == .ready else { throw Self.unavailable } }
    private func requireNotClosing() throws { guard phase != .closing, phase != .closed else { throw Self.unavailable } }
    private static var unavailable: MiraError { .init(.unauthorized, "The library access lease is unavailable.") }
    private static var conflict: MiraError { .init(.conflict, "The library maintenance operation conflicts with current authority.") }
}

/// Explicit ownership: release only after the work using this lease has actually returned.
/// Body reads and registered resources remain pinned even if release is requested prematurely.
public final class AgentLibraryAccessLease: Sendable {
    public let authorization: AgentLibraryAuthorization
    private let gate: AgentLibraryAccess
    private let id: UUID
    private let signal: AgentLibraryRevocation
    private let owner: RuntimeRelease
    fileprivate init(gate: AgentLibraryAccess, id: UUID, authorization: AgentLibraryAuthorization, signal: AgentLibraryRevocation) {
        self.gate = gate; self.id = id; self.authorization = authorization; self.signal = signal
        owner = RuntimeRelease { await gate.release(id) }
    }
    public var isRevoked: Bool { signal.isRevoked }
    /// Bind the actual owner's synchronous cancellation request. Late binding observes revocation.
    public func bindCancellation(_ cancel: @escaping @Sendable () -> Void) throws { try signal.bind(cancel) }
    public func check() async throws { try await gate.check(id, authorization: authorization) }
    public func reader(from payloads: any SessionPayloadReader) -> any SessionPayloadReader {
        AgentLibraryPayloadReader(lease: self, payloads: payloads)
    }
    public func read(_ reference: SessionPayloadReference, from payloads: any SessionPayloadReader) async throws -> Data {
        try await read { try await payloads.read(reference) }
    }
    /// The query is owned until its actual return. Revocation discards a late result.
    /// This is a read boundary; mutations need their domain commit authorization as well.
    public func read<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await gate.read(id: id, authorization: authorization, operation: operation)
    }
    public func start<T: Sendable>(_ factory: @Sendable () -> AgentLibraryResource<T>) async throws -> AgentLibraryResourceLease<T> {
        try await gate.startResource(factory, id: id, authorization: authorization)
    }
    public func release() async { await owner.release() }
}

/// Releasing a completed operation removes its registration without releasing the enclosing work lease.
public final class AgentLibraryResourceLease<Value: Sendable>: Sendable {
    public let value: Value
    private let owner: RuntimeRelease
    fileprivate init(value: Value, cleanup: @escaping @Sendable () async -> Void) {
        self.value = value; owner = RuntimeRelease(cleanup)
    }
    public func release() async { await owner.release() }
}

private final class AgentLibraryRevocation: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    private var cancellationRequested = false
    private var cancellation: (@Sendable () -> Void)?
    var isRevoked: Bool { lock.withLock { revoked } }
    func bind(_ cancellation: @escaping @Sendable () -> Void) throws {
        lock.lock()
        guard self.cancellation == nil else {
            lock.unlock(); throw MiraError(.conflict, "The library lease already has a cancellation owner.")
        }
        self.cancellation = cancellation
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel { cancellation() }
    }
    func revoke(cancelOwner: Bool = true) {
        lock.lock()
        revoked = true
        let shouldCancel = cancelOwner && !cancellationRequested
        cancellationRequested = cancellationRequested || cancelOwner
        let cancel = shouldCancel ? cancellation : nil
        lock.unlock(); cancel?()
    }
}

private struct AgentLibraryPayloadReader: SessionPayloadReader {
    let lease: AgentLibraryAccessLease
    let payloads: any SessionPayloadReader
    func read(_ reference: SessionPayloadReference) async throws -> Data {
        try await lease.read(reference, from: payloads)
    }
}
