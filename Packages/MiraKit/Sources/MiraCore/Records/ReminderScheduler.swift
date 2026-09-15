import Foundation

public enum NotificationPermission: Sendable { case allowed, notDetermined, denied }

public struct ReminderNotification: Sendable, Equatable {
    public var identifier: String
    public var title: String
    public var body: String
    public var fireAt: Date
    public var revision: Int
    public init(identifier: String, title: String, body: String, fireAt: Date, revision: Int) {
        self.identifier = identifier; self.title = title; self.body = body
        self.fireAt = fireAt; self.revision = revision
    }
}

public protocol LocalNotificationPort: Sendable {
    func permission() async -> NotificationPermission
    func requestPermission() async throws -> Bool
    func pending() async -> [ReminderNotification]
    func install(_ notification: ReminderNotification) async throws
    /// Removes both pending and delivered notifications owned by this identifier.
    func remove(_ identifier: String) async
}

/// System scheduling is recoverable, separate from the canonical task transaction.
/// One serial reconciliation loop prevents stale scheduling from racing a newer edit.
public actor ReminderScheduler {
    private let store: any TaskStore
    private let notifications: any LocalNotificationPort
    private let namespace: String
    private let access: AgentLibraryAccess
    private let scope: RuntimeScope
    private let now: @Sendable () -> Date

    private var reconcileTask: Task<Void, any Error>?
    private var permissionTask: Task<Bool, any Error>?
    private var reconcileAgain = false
    private var closed = false

    public init(store: any TaskStore, notifications: any LocalNotificationPort, namespace: String,
                access: AgentLibraryAccess, scope: RuntimeScope,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.notifications = notifications; self.namespace = namespace
        self.access = access; self.scope = scope; self.now = now
    }

    /// Permission is an explicit user operation. It is still owned by the scheduler
    /// so maintenance revocation and scheduler close drain the real request.
    public func requestPermission() async throws -> Bool {
        try Task.checkCancellation()
        guard !closed else { throw Self.closedError }
        if let permissionTask {
            return try await permissionTask.value
        }
        let task = Task {
            defer { self.permissionTask = nil }
            return try await self.runPermissionRequest()
        }
        permissionTask = task
        return try await task.value
    }

    public func reconcile() async throws {
        try Task.checkCancellation()
        guard !closed else { throw Self.closedError }
        if let reconcileTask {
            reconcileAgain = true
            return try await reconcileTask.value
        }
        let task = Task {
            defer { self.reconcileTask = nil }
            try await self.runReconcileLoop()
        }
        reconcileTask = task
        try await task.value
    }

    /// Stops accepting new work and drains accepted notification operations.
    /// Existing system notifications are left in place for maintenance reconciliation.
    public func close() async {
        closed = true
        let reconcileTask = self.reconcileTask
        let permissionTask = self.permissionTask
        reconcileTask?.cancel()
        permissionTask?.cancel()
        _ = await reconcileTask?.result
        _ = await permissionTask?.result
        self.reconcileTask = nil
        self.permissionTask = nil
    }

    private func runReconcileLoop() async throws {
        repeat {
            reconcileAgain = false
            try await runReconcilePass()
        } while reconcileAgain && !closed
    }

    private func runPermissionRequest() async throws -> Bool {
        let lease = try await access.acquire(in: scope)
        let resource: AgentLibraryResourceLease<Task<Bool, any Error>>
        do {
            resource = try await lease.start {
                let task = Task { try await self.checked(lease) { try await self.notifications.requestPermission() } }
                return AgentLibraryResource(value: task, cleanup: {
                    task.cancel()
                    _ = await task.result
                })
            }
        } catch {
            // If start failed, no resource was admitted and only the lease needs releasing.
            await lease.release()
            throw error
        }
        do {
            try lease.bindCancellation { resource.value.cancel() }
            let value = try await withTaskCancellationHandler(operation: {
                try await resource.value.value
            }, onCancel: {
                resource.value.cancel()
            })
            await resource.release()
            await lease.release()
            return value
        } catch {
            await resource.release()
            await lease.release()
            throw error
        }
    }

    private func runReconcilePass() async throws {
        let lease = try await access.acquire(in: scope)
        let resource: AgentLibraryResourceLease<Task<Void, any Error>>
        do {
            resource = try await lease.start {
                let task = Task { [weak self, lease] in
                    guard let self else { throw CancellationError() }
                    try await self.reconcilePass(using: lease)
                }
                return AgentLibraryResource(value: task, cleanup: {
                    task.cancel()
                    _ = await task.result
                })
            }
        } catch {
            await lease.release()
            throw error
        }
        do {
            try lease.bindCancellation { resource.value.cancel() }
            try await withTaskCancellationHandler(operation: {
                try await resource.value.value
            }, onCancel: {
                resource.value.cancel()
            })
            await resource.release()
            await lease.release()
        } catch {
            await resource.release()
            await lease.release()
            throw error
        }
    }

    private func reconcilePass(using lease: AgentLibraryAccessLease) async throws {
        let tasks = try await lease.read {
            try await self.store.reminderWork(limit: 1_000)
        }
        let permission = try await checked(lease) { await self.notifications.permission() }
        let installed = try await checked(lease) { await self.notifications.pending() }
        let identifierPrefix = "mira.\(namespace)."
        let currentIdentifiers = Set(tasks.map { identifier(for: $0) })

        // A reset can leave a request whose task row no longer exists. Remove only
        // requests owned by this library namespace; other libraries may share the center.
        for request in installed where request.identifier.hasPrefix(identifierPrefix) && !currentIdentifiers.contains(request.identifier) {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: String(request.identifier.dropFirst(identifierPrefix.count))),
                  try await lease.read({ try await self.store.reminderTaskExists(.init(id)) }) == false else { continue }
            try await checked(lease) {
                await self.notifications.remove(request.identifier)
            }
        }

        for task in tasks {
            try Task.checkCancellation()
            try await lease.check()
            let identifier = identifier(for: task)
            let current = try await lease.read {
                try await self.store.taskDetail(task.id, workspaceID: task.workspaceID)
            }
            guard current.revision == task.revision else {
                reconcileAgain = true
                continue
            }

            let state: ReminderDeliveryState
            var deliveryError: MiraError?
            if task.status.isTerminal || task.draft.reminderAt == nil || task.deliveryState == .paused {
                try await checked(lease) { await self.notifications.remove(identifier) }
                state = task.deliveryState == .paused ? .paused : (task.status.isTerminal ? .cancelled : .none)
            } else if permission != .allowed {
                try await checked(lease) { await self.notifications.remove(identifier) }
                state = .permissionRequired
            } else if let fireAt = task.draft.reminderAt, fireAt <= now() {
                // A missing past request does not prove that the user saw a notification.
                state = .elapsed
            } else if let fireAt = task.draft.reminderAt {
                let desired = ReminderNotification(identifier: identifier, title: task.draft.title,
                                                    body: task.draft.notes, fireAt: fireAt, revision: task.revision)
                if installed.first(where: { $0.identifier == identifier }) == desired {
                    state = .scheduled
                } else {
                    do {
                        try await checked(lease) { try await self.notifications.install(desired) }
                        let observed = try await checked(lease) { await self.notifications.pending() }
                        guard observed.contains(desired) else {
                            throw MiraError(.storage, "The system did not confirm the reminder schedule. Retry scheduling.")
                        }
                        state = .scheduled
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Preserve revocation/cancellation as control flow, not a failed schedule.
                        try await lease.check()
                        try await checked(lease) { await self.notifications.remove(identifier) }
                        state = .failed
                        deliveryError = .init(.storage, "The reminder could not be scheduled. Retry scheduling.")
                    }
                }
            } else {
                state = .none
            }

            try await lease.check()
            let committed = try await self.store.setReminderDelivery(
                task.id,
                expectedRevision: task.revision,
                state: state,
                error: deliveryError,
                authorization: lease.authorization,
                at: now()
            )
            try await lease.check()
            if !committed {
                try await checked(lease) { await self.notifications.remove(identifier) }
                reconcileAgain = true
            }
        }
    }

    private func checked<T: Sendable>(_ lease: AgentLibraryAccessLease,
                                      _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await lease.check()
        let value = try await operation()
        try await lease.check()
        return value
    }

    private func identifier(for task: MiraTask) -> String {
        "mira.\(namespace).\(task.id.rawValue.uuidString.lowercased())"
    }

    private static var closedError: MiraError {
        .init(.busy, "The reminder scheduler is closed.")
    }
}
