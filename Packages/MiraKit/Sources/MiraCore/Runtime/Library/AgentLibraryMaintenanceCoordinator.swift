import Foundation

public struct AgentLibraryMaintenanceHandlerIdentity: Sendable, Equatable, Hashable {
    public let namespace: String
    public let revision: Int
    public init(namespace: String, revision: Int) { self.namespace = namespace; self.revision = revision }

    public func validate() throws {
        guard SessionState.validIdentifier(namespace, maximumBytes: 128), revision > 0 else {
            throw AgentLibraryMaintenanceError.invalidHandler
        }
    }
}

/// Register in a library scope, separately from capabilities owned by the application being stopped.
/// Both methods must support replay of the same durable operation after partial failure or restart.
/// Verification must inspect actual domain, journal and body state; returning from apply is not proof.
public protocol AgentLibraryMaintenanceHandler: Sendable {
    var identity: AgentLibraryMaintenanceHandlerIdentity { get }
    func apply(_ operation: AgentLibraryMaintenanceOperation) async throws
    func verify(_ operation: AgentLibraryMaintenanceOperation) async throws
}

/// A composition-owned producer group. Closing must stop admission and await all actual work,
/// including persistence and module cleanup. Throw if durable settlement remains unresolved.
public struct AgentLibraryWorkOwner: Sendable {
    public let id: String
    fileprivate let quiesce: @Sendable () async throws -> Void
    public init(id: String, quiesce: @escaping @Sendable () async throws -> Void) {
        self.id = id; self.quiesce = quiesce
    }

    public static func application(id: String, runtime: AgentApplicationRuntime) -> Self {
        .init(id: id) {
            guard await runtime.shutdown().isSettled else {
                throw AgentLibraryMaintenanceError.unsettledWork([id])
            }
        }
    }

    public static func consumers(id: String, coordinator: AgentSessionConsumerCoordinator) -> Self {
        .init(id: id) { await coordinator.close() }
    }
}

public enum AgentLibraryMaintenanceError: Error, Sendable, Equatable {
    case closed
    case busy
    case conflict
    case invalidWorkOwners
    case invalidHandler
    case invalidHandlerScope(String)
    case duplicateHandler(AgentLibraryMaintenanceHandlerIdentity)
    case missingHandler(AgentLibraryMaintenanceHandlerIdentity)
    case unsettledWork([String])
}

/// One coordinator owns a live library's maintenance commands. The host must include every producer
/// group and route maintenance here. Handler scopes and storage outlive the stopped application.
public actor AgentLibraryMaintenanceCoordinator {
    private let access: AgentLibraryAccess
    private let handlers: RuntimeRegistry<any AgentLibraryMaintenanceHandler>
    private let workOwners: [AgentLibraryWorkOwner]
    private let now: @Sendable () -> Date
    private var active: Active?
    private var snapshotDrain: (@Sendable () async -> Void)?
    private var closed = false
    private(set) var joiningWaiterCount = 0

    private struct Active {
        let request: AgentLibraryMaintenanceRequest
        let expected: AgentLibraryAuthorization
        let task: Task<AgentLibraryMaintenanceOperation, any Error>
    }

    public init(access: AgentLibraryAccess, handlers: RuntimeRegistry<any AgentLibraryMaintenanceHandler>,
                workOwners: [AgentLibraryWorkOwner], now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard workOwners.count <= 128, Set(workOwners.map(\.id)).count == workOwners.count,
              workOwners.allSatisfy({ SessionState.validIdentifier($0.id, maximumBytes: 128) }) else {
            throw AgentLibraryMaintenanceError.invalidWorkOwners
        }
        self.access = access; self.handlers = handlers; self.workOwners = workOwners; self.now = now
    }

    /// Caller cancellation before admission rejects the command. After admission the owned task
    /// finishes or preserves pending intent; cancelling a waiter cannot abandon cleanup.
    public func perform(_ request: AgentLibraryMaintenanceRequest,
                        expected: AgentLibraryAuthorization) async throws -> AgentLibraryMaintenanceOperation {
        try Task.checkCancellation(); try request.validate()
        guard !closed else { throw AgentLibraryMaintenanceError.closed }
        guard snapshotDrain == nil else { throw AgentLibraryMaintenanceError.busy }
        guard expected.libraryID == access.libraryID else { throw AgentLibraryMaintenanceError.conflict }
        if let active {
            guard active.request == request, active.expected == expected else { throw AgentLibraryMaintenanceError.busy }
            joiningWaiterCount += 1
            defer { joiningWaiterCount -= 1 }
            return try await active.task.value
        }
        let task = Task {
            defer { active = nil }
            return try await execute(request, expected: expected)
        }
        active = .init(request: request, expected: expected, task: task)
        return try await task.value
    }

    /// Serializes a read-only library snapshot with all durable maintenance. The callback must
    /// await its actual readers, copy workers and publication before returning or throwing.
    /// Cancelling a waiter never cancels accepted work. Old application scopes stay closed;
    /// the host composes fresh owners before resuming ordinary use, even after export failure.
    public func withQuiescentSnapshot<Value: Sendable>(
        expected: AgentLibraryAuthorization,
        operation: @escaping @Sendable (AgentLibraryAuthorization) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard !closed else { throw AgentLibraryMaintenanceError.closed }
        guard active == nil, snapshotDrain == nil else { throw AgentLibraryMaintenanceError.busy }
        guard expected.libraryID == access.libraryID else { throw AgentLibraryMaintenanceError.conflict }
        let task = Task {
            defer { self.snapshotDrain = nil }
            return try await access.withQuiescentSnapshot(expected: expected, quiesce: {
                let failures = await self.quiesce()
                guard failures.isEmpty else { throw AgentLibraryMaintenanceError.unsettledWork(failures) }
            }, operation: operation)
        }
        snapshotDrain = { _ = await task.result }
        return try await task.value
    }

    /// Stop accepting commands and drain the owned attempt. Failure leaves the durable pending
    /// operation for explicit recovery; closing never completes or cancels it implicitly.
    public func close() async {
        closed = true
        _ = await active?.task.result
        await snapshotDrain?()
    }

    private func execute(_ request: AgentLibraryMaintenanceRequest,
                         expected: AgentLibraryAuthorization) async throws -> AgentLibraryMaintenanceOperation {
        if let completed = try await access.retryCompletion(for: request, expected: expected) { return completed }
        if let existing = try await access.operation(id: request.id) {
            guard existing.request == request, existing.previousAuthorization == expected else {
                throw AgentLibraryMaintenanceError.conflict
            }
            if let date = existing.completedAt {
                let pending = AgentLibraryMaintenanceOperation(request: existing.request,
                    previousAuthorization: existing.previousAuthorization, authorization: existing.authorization, completedAt: nil)
                // This also reconciles a completion committed before a previous coordinator lost confirmation.
                return try await access.complete(pending, at: date)
            }
        }
        let state = await access.snapshot()
        if let pending = state.pending,
           pending.request != request || pending.previousAuthorization != expected {
            throw AgentLibraryMaintenanceError.conflict
        }
        // Validate the catalogue before revoking anything. Pin only independent library modules.
        let catalog = try await handlers.freeze()
        do {
            let handler = try select(request, in: catalog)
            let operation: AgentLibraryMaintenanceOperation
            do { operation = try await access.begin(request, expected: expected) }
            catch {
                // A lost begin acknowledgement still revoked producers. Stop and drain all groups,
                // but do not apply an operation whose persistent start has not been confirmed.
                let phase = await access.snapshot().phase
                if phase != .ready, phase != .closed {
                    let failures = await quiesce()
                    if failures.isEmpty {
                        do {
                            try await access.waitForQuiescence()
                            _ = try await access.reconcileUnstartedMaintenance(request, expected: expected)
                        } catch { /* Keep uncertain admission closed until its state can be proven. */ }
                    }
                }
                throw error
            }
            if operation.completedAt != nil { await catalog.release(); return operation }
            let failures = await quiesce()
            guard failures.isEmpty else { throw AgentLibraryMaintenanceError.unsettledWork(failures) }
            try await access.waitForQuiescence()
            try await handler.apply(operation)
            try await handler.verify(operation)
            let date = now()
            guard date.timeIntervalSince1970.isFinite else { throw AgentLibraryMaintenanceError.conflict }
            let result = try await access.complete(operation, at: date)
            await catalog.release()
            return result
        } catch { await catalog.release(); throw error }
    }

    private func select(_ request: AgentLibraryMaintenanceRequest,
                        in catalog: RuntimeRegistrySnapshot<any AgentLibraryMaintenanceHandler>) throws -> any AgentLibraryMaintenanceHandler {
        guard catalog.entries.count <= 128 else { throw AgentLibraryMaintenanceError.invalidHandler }
        var identities = Set<AgentLibraryMaintenanceHandlerIdentity>()
        let desired = AgentLibraryMaintenanceHandlerIdentity(namespace: request.namespace, revision: request.revision)
        var selected: (any AgentLibraryMaintenanceHandler)?
        for entry in catalog.entries {
            guard entry.scopeKind == .library(access.libraryID) else {
                throw AgentLibraryMaintenanceError.invalidHandlerScope(entry.id)
            }
            let identity = entry.value.identity
            try identity.validate()
            guard identities.insert(identity).inserted else { throw AgentLibraryMaintenanceError.duplicateHandler(identity) }
            if identity == desired { selected = entry.value }
        }
        guard let selected else { throw AgentLibraryMaintenanceError.missingHandler(desired) }
        return selected
    }

    private func quiesce() async -> [String] {
        // Every group receives shutdown even when another fails or waits for that group's work.
        await withTaskGroup(of: String?.self) { group in
            for owner in workOwners {
                group.addTask {
                    do { try await owner.quiesce(); return nil }
                    catch { return owner.id }
                }
            }
            var failures: [String] = []
            for await failure in group { if let failure { failures.append(failure) } }
            return failures.sorted()
        }
    }
}
