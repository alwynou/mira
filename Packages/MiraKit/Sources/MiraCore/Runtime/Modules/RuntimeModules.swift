import Foundation

public enum RuntimeScopeKind: Sendable, Equatable {
    case library(UUID)
    case application
    case session(ConversationID)
    case execution(ExecutionID)
}

public enum RuntimeScopeError: Error, Sendable, Equatable {
    case disposed
    case activationUnavailable
}

private enum RuntimeScopeDisposalContext {
    @TaskLocal static var activeScopeIDs: Set<UUID> = []
}

private enum RuntimeScopeTaskContext {
    @TaskLocal static var activeTaskIDs: Set<UUID> = []
}

private final class RuntimeTaskStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if started {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

}

actor RuntimeActivationGate {
    private enum State { case pending, open, failed }
    private var state: State = .pending
    private let parent: RuntimeActivationGate?

    init(parent: RuntimeActivationGate? = nil) { self.parent = parent }

    func requireOpen() async throws {
        try await parent?.requireOpen()
        guard state == .open else { throw RuntimeScopeError.activationUnavailable }
    }

    func open() throws {
        guard state != .failed else { throw RuntimeScopeError.activationUnavailable }
        state = .open
    }

    func fail() {
        state = .failed
    }
}

public actor RuntimeScope {
    public nonisolated let id: UUID
    public nonisolated let kind: RuntimeScopeKind
    private let parentID: UUID?
    private let activationGate: RuntimeActivationGate?

    private typealias CleanupOperation = @Sendable () async -> Void
    private struct CleanupRegistration: Sendable {
        let id: UUID
        let operation: CleanupOperation
    }

    private struct QuiescenceWaiter {
        let excludedTaskIDs: Set<UUID>
        let continuation: CheckedContinuation<Void, Never>
    }

    private var cleanupRegistrations: [CleanupRegistration] = []
    private var closingRegistrations: [CleanupRegistration] = []
    private var childScopes: [UUID: RuntimeScope] = [:]
    private var childRegistrationByScopeID: [UUID: UUID] = [:]
    private var childRegistrationIDs: Set<UUID> = []
    private var ownedTasks: [UUID: Task<Void, Never>] = [:]
    private var leases: Set<UUID> = []
    private var quiescenceWaiters: [QuiescenceWaiter] = []
    private var disposed = false
    private var disposing = false
    private var finishingCleanup = false
    private var cleanupComplete = false
    private var closingStarted = false
    private var closingMarked = false
    private var closingCallbacksRunning = false
    private var closingComplete = false
    private var closingMarkWaiters: [CheckedContinuation<Void, Never>] = []
    private var closingWaiters: [CheckedContinuation<Void, Never>] = []
    private var disposalWaiters: [CheckedContinuation<Void, Never>] = []
    private var onDisposed: CleanupOperation?

    public init(kind: RuntimeScopeKind, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.parentID = nil
        self.activationGate = nil
    }

    private init(kind: RuntimeScopeKind, id: UUID, parentID: UUID, activationGate: RuntimeActivationGate?, onDisposed: @escaping CleanupOperation) {
        self.id = id
        self.kind = kind
        self.parentID = parentID
        self.activationGate = activationGate
        self.onDisposed = onDisposed
    }

    public var isDisposed: Bool { disposed }

    /// Pins resources owned by this scope until the returned lease is released.
    public func acquireLease() async throws -> RuntimeScopeLease {
        guard !disposed, !disposing else { throw RuntimeScopeError.disposed }
        try await activationGate?.requireOpen()
        guard !disposed, !disposing else { throw RuntimeScopeError.disposed }
        let leaseID = UUID()
        leases.insert(leaseID)
        return RuntimeScopeLease(scope: self, id: leaseID)
    }

    /// Starts an operation only after the task has been entered into this scope's ownership set.
    public func ownTask(_ operation: @escaping @Sendable () async -> Void) throws -> Task<Void, Never> {
        guard !disposed, !disposing else { throw RuntimeScopeError.disposed }
        let taskID = UUID()
        let gate = RuntimeTaskStartGate()
        let task = Task { [weak self] in
            await gate.wait()
            let active = RuntimeScopeTaskContext.activeTaskIDs.union([taskID])
            await RuntimeScopeTaskContext.$activeTaskIDs.withValue(active) {
                if !Task.isCancelled { await operation() }
            }
            await self?.finishOwnedTask(taskID)
        }
        ownedTasks[taskID] = task
        gate.open()
        return task
    }

    public func registerCleanup(_ operation: @escaping @Sendable () async -> Void) async throws {
        try registerCleanup(operation, id: UUID())
    }

    internal func registerClosing(_ operation: @escaping @Sendable () async -> Void) throws -> UUID {
        guard !disposed, !disposing, !closingStarted else { throw RuntimeScopeError.disposed }
        let id = UUID()
        closingRegistrations.append(.init(id: id, operation: operation))
        return id
    }

    internal func unregisterClosing(_ id: UUID) {
        closingRegistrations.removeAll { $0.id == id }
    }

    internal var closingRegistrationCount: Int { closingRegistrations.count }

    public func dispose() async {
        if disposed, !disposing { return }
        if disposing {
            if RuntimeScopeDisposalContext.activeScopeIDs.contains(id)
                || parentID.map({ RuntimeScopeDisposalContext.activeScopeIDs.contains($0) }) == true
                || RuntimeScopeTaskContext.activeTaskIDs.contains(where: { ownedTasks[$0] != nil }) { return }
            await withCheckedContinuation { continuation in
                disposalWaiters.append(continuation)
            }
            return
        }

        await beginDisposal()
        await finishDisposalTree()
    }

    internal func beginDisposal() async {
        if !disposed {
            disposed = true
            disposing = true
        }
        await prepareForDisposalTree()
    }

    internal func finishDisposal() async {
        await finishDisposalTree()
    }

    internal func makeChild(kind: RuntimeScopeKind, activationGate: RuntimeActivationGate? = nil) throws -> RuntimeScope {
        let registrationID = UUID()
        let child = RuntimeScope(kind: kind, id: UUID(), parentID: id, activationGate: activationGate ?? self.activationGate, onDisposed: { [weak self] in
            await self?.removeCleanup(id: registrationID)
        })
        try registerCleanup({ await child.dispose() }, id: registrationID)
        childScopes[child.id] = child
        childRegistrationByScopeID[child.id] = registrationID
        childRegistrationIDs.insert(registrationID)
        return child
    }

    internal func makeActivationGate() -> RuntimeActivationGate { .init(parent: activationGate) }

    internal func ownsCurrentTask() async -> Bool {
        if RuntimeScopeTaskContext.activeTaskIDs.contains(where: { ownedTasks[$0] != nil }) { return true }
        for child in childScopes.values {
            if await child.ownsCurrentTask() { return true }
        }
        return false
    }

    private func registerCleanup(_ operation: @escaping CleanupOperation, id: UUID) throws {
        guard !disposed, !disposing else { throw RuntimeScopeError.disposed }
        cleanupRegistrations.append(.init(id: id, operation: operation))
    }

    private func removeCleanup(id: UUID) {
        cleanupRegistrations.removeAll { $0.id == id }
        childRegistrationIDs.remove(id)
        if let scopeID = childRegistrationByScopeID.first(where: { $0.value == id })?.key {
            childScopes.removeValue(forKey: scopeID)
            childRegistrationByScopeID.removeValue(forKey: scopeID)
        }
    }

    private func prepareForDisposalTree() async {
        await runClosingTree()
    }

    internal func markDisposalTree() async {
        if closingStarted {
            if closingMarked { return }
            await withCheckedContinuation { continuation in closingMarkWaiters.append(continuation) }
            return
        }
        closingStarted = true
        if !disposed {
            disposed = true
            disposing = true
            for task in ownedTasks.values { task.cancel() }
        } else if !disposing {
            return
        } else {
            for task in ownedTasks.values { task.cancel() }
        }
        await activationGate?.fail()

        let children = Array(childScopes.values)
        for child in children {
            await child.markDisposalTree()
        }
        closingMarked = true
        let waiters = closingMarkWaiters
        closingMarkWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    internal func runClosingTree() async {
        await markDisposalTree()
        if closingComplete { return }
        if closingCallbacksRunning {
            await withCheckedContinuation { continuation in closingWaiters.append(continuation) }
            return
        }
        closingCallbacksRunning = true
        let children = Array(childScopes.values)
        let callbacks = closingRegistrations.reversed().map(\.operation)
        closingRegistrations.removeAll(keepingCapacity: false)
        var activeIDs = RuntimeScopeDisposalContext.activeScopeIDs
        activeIDs.insert(id)
        await RuntimeScopeDisposalContext.$activeScopeIDs.withValue(activeIDs) {
            for child in children { await child.runClosingTree() }
            for callback in callbacks { await callback() }
        }
        closingComplete = true
        closingCallbacksRunning = false
        let waiters = closingWaiters
        closingWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    private func finishDisposalTree() async {
        if cleanupComplete { return }
        if finishingCleanup {
            if RuntimeScopeDisposalContext.activeScopeIDs.contains(id) { return }
            await withCheckedContinuation { continuation in disposalWaiters.append(continuation) }
            return
        }
        finishingCleanup = true

        let excluded = RuntimeScopeTaskContext.activeTaskIDs
        await waitForQuiescenceTree(excluding: excluded)

        let operations = cleanupRegistrations.reversed()
        let children = childScopes
        var childByRegistration: [UUID: RuntimeScope] = [:]
        for (scopeID, child) in children {
            if let registrationID = childRegistrationByScopeID[scopeID] {
                childByRegistration[registrationID] = child
            }
        }
        let childIDs = childRegistrationIDs
        var activeIDs = RuntimeScopeDisposalContext.activeScopeIDs
        activeIDs.insert(id)
        await RuntimeScopeDisposalContext.$activeScopeIDs.withValue(activeIDs) {
            for registration in operations {
                if childIDs.contains(registration.id), let child = childByRegistration[registration.id] {
                    await child.finishDisposalTree()
                } else {
                    await registration.operation()
                }
            }
        }

        cleanupRegistrations.removeAll(keepingCapacity: false)
        childScopes.removeAll(keepingCapacity: false)
        childRegistrationByScopeID.removeAll(keepingCapacity: false)
        childRegistrationIDs.removeAll(keepingCapacity: false)
        let callback = onDisposed
        onDisposed = nil
        cleanupComplete = true
        finishingCleanup = false
        disposing = false
        let waiters = disposalWaiters
        disposalWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        if let callback { await callback() }
    }

    private func waitForQuiescence(excluding excluded: Set<UUID>) async {
        while !leases.isEmpty || ownedTasks.keys.contains(where: { !excluded.contains($0) }) {
            await withCheckedContinuation { continuation in
                quiescenceWaiters.append(.init(excludedTaskIDs: excluded, continuation: continuation))
            }
        }
    }

    private func waitForQuiescenceTree(excluding excluded: Set<UUID>) async {
        await waitForQuiescence(excluding: excluded)
        let children = Array(childScopes.values)
        for child in children {
            await child.waitForQuiescenceTree(excluding: excluded)
        }
    }

    private func wakeQuiescenceWaiters() {
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.continuation.resume() }
    }

    private func finishOwnedTask(_ taskID: UUID) {
        ownedTasks.removeValue(forKey: taskID)
        wakeQuiescenceWaiters()
    }

    fileprivate func releaseLease(_ leaseID: UUID) {
        leases.remove(leaseID)
        wakeQuiescenceWaiters()
    }
}

/// Concurrent releasers all await the same resource drain, including cancelled callers.
actor RuntimeRelease {
    private let operation: @Sendable () async -> Void
    private var task: Task<Void, Never>?

    init(_ operation: @escaping @Sendable () async -> Void) { self.operation = operation }

    func release() async {
        if let task { await task.value; return }
        let task = Task { await operation() }
        self.task = task
        await task.value
    }
}

public final class RuntimeScopeLease: Sendable {
    private let owner: RuntimeRelease

    fileprivate init(scope: RuntimeScope, id: UUID) {
        owner = RuntimeRelease { await scope.releaseLease(id) }
    }

    public func release() async {
        await owner.release()
    }
}

public protocol RuntimeModule: Sendable {
    /// A stable lowercase ASCII namespace: `[a-z][a-z0-9._-]*`, at most 128 bytes.
    /// `core` and `core.*` are reserved for kernel-owned modules.
    var id: String { get }
    var dependencies: Set<String> { get }

    /// Activation must finish owning any tasks it starts before returning. A scope
    /// rejects registrations after disposal, so an unowned task cannot attach late.
    func activate(in scope: RuntimeScope) async throws
}

public enum RuntimeModuleHostError: Error, Sendable, Equatable {
    case invalidID(String)
    case reservedID(String)
    case duplicateID(String)
    case missingDependency(module: String, dependency: String)
    case dependencyCycle([String])
}

public enum RuntimeModuleActivationError: Error, Sendable, Equatable {
    case parentDisposed
}

private enum RuntimeModuleActivationDisposalContext {
    @TaskLocal static var activeIDs: Set<UUID> = []
}

public actor RuntimeModuleActivation {
    public nonisolated let activationOrder: [String]

    private let id = UUID()
    private var scopes: [RuntimeScope]
    private var disposed = false
    private var disposing = false
    private var disposalWaiters: [CheckedContinuation<Void, Never>] = []

    internal init(activationOrder: [String], scopes: [RuntimeScope]) {
        self.activationOrder = activationOrder
        self.scopes = scopes
    }

    public var isDisposed: Bool { disposed }

    public func dispose() async {
        if disposed, !disposing { return }
        if disposing {
            if RuntimeModuleActivationDisposalContext.activeIDs.contains(id) { return }
            for scope in scopes {
                if await scope.ownsCurrentTask() { return }
            }
            await withCheckedContinuation { continuation in
                disposalWaiters.append(continuation)
            }
            return
        }

        disposed = true
        disposing = true
        let scopesToDispose = scopes.reversed()

        var activeIDs = RuntimeModuleActivationDisposalContext.activeIDs
        activeIDs.insert(id)
        await RuntimeModuleActivationDisposalContext.$activeIDs.withValue(activeIDs) {
            for scope in scopesToDispose { await scope.markDisposalTree() }
            for scope in scopesToDispose { await scope.runClosingTree() }
            for scope in scopesToDispose { await scope.finishDisposal() }
        }

        scopes.removeAll(keepingCapacity: false)
        disposing = false
        let waiters = disposalWaiters
        disposalWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}

public struct RuntimeModuleHost: Sendable {
    private let modules: [any RuntimeModule]

    public init(modules: [any RuntimeModule]) throws {
        self.modules = try Self.deterministicOrder(modules)
    }

    public func activate(in parent: RuntimeScope) async throws -> RuntimeModuleActivation {
        var activatedModules: [String] = []
        var activatedScopes: [RuntimeScope] = []
        let activationGate = await parent.makeActivationGate()

        do {
            try Task.checkCancellation()
            for module in modules {
                try Task.checkCancellation()
                let childScope = try await parent.makeChild(kind: parent.kind, activationGate: activationGate)
                // Include the current scope in group rollback before activation can suspend or fail.
                activatedScopes.append(childScope)
                try await module.activate(in: childScope)
                try Task.checkCancellation()
                guard !(await parent.isDisposed), !(await childScope.isDisposed) else {
                    throw RuntimeModuleActivationError.parentDisposed
                }
                activatedModules.append(module.id)
            }

            try Task.checkCancellation()
            let activation = RuntimeModuleActivation(activationOrder: activatedModules, scopes: activatedScopes)
            if await parent.isDisposed {
                await activationGate.fail()
                await activation.dispose()
                throw RuntimeModuleActivationError.parentDisposed
            }
            try await activationGate.open()
            return activation
        } catch {
            await activationGate.fail()
            let partialActivation = RuntimeModuleActivation(activationOrder: activatedModules, scopes: activatedScopes)
            await partialActivation.dispose()
            throw error
        }
    }

    private static func deterministicOrder(_ modules: [any RuntimeModule]) throws -> [any RuntimeModule] {
        var byID: [String: any RuntimeModule] = [:]
        for module in modules.sorted(by: { $0.id < $1.id }) {
            guard validID(module.id) else {
                throw RuntimeModuleHostError.invalidID(module.id)
            }
            guard module.id != "core", !module.id.hasPrefix("core.") else {
                throw RuntimeModuleHostError.reservedID(module.id)
            }
            if byID.updateValue(module, forKey: module.id) != nil {
                throw RuntimeModuleHostError.duplicateID(module.id)
            }
        }

        for module in modules.sorted(by: { $0.id < $1.id }) {
            for dependency in module.dependencies.sorted() where byID[dependency] == nil {
                throw RuntimeModuleHostError.missingDependency(module: module.id, dependency: dependency)
            }
        }

        enum VisitState { case visiting, visited }
        var states: [String: VisitState] = [:]
        var order: [String] = []

        func visit(_ id: String, path: [String]) throws {
            if let state = states[id] {
                if case .visited = state { return }
                let start = path.firstIndex(of: id) ?? 0
                throw RuntimeModuleHostError.dependencyCycle(Array(path[start...]) + [id])
            }

            states[id] = .visiting
            let nextPath = path + [id]
            for dependency in byID[id]!.dependencies.sorted() {
                try visit(dependency, path: nextPath)
            }
            states[id] = .visited
            order.append(id)
        }

        for id in byID.keys.sorted() {
            try visit(id, path: [])
        }
        return order.map { byID[$0]! }
    }

    private static func validID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...128).contains(bytes.count), let first = bytes.first,
              (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(first) else {
            return false
        }
        return bytes.dropFirst().allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: ".")
                || byte == UInt8(ascii: "_")
                || byte == UInt8(ascii: "-")
        }
    }
}
