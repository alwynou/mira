import Foundation

public enum NotificationPermission: Sendable { case allowed, notDetermined, denied }

public struct ReminderNotification: Sendable, Equatable {
    public var identifier: String
    public var title: String
    public var body: String
    public var fireAt: Date
    public var revision: Int
    public init(identifier: String, title: String, body: String, fireAt: Date, revision: Int) {
        self.identifier = identifier; self.title = title; self.body = body; self.fireAt = fireAt; self.revision = revision
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
    private let now: @Sendable () -> Date
    private var running = false
    private var needsAnotherPass = false
    public init(store: any TaskStore, notifications: any LocalNotificationPort, namespace: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.notifications = notifications; self.namespace = namespace; self.now = now
    }

    public func requestPermission() async throws -> Bool { try await notifications.requestPermission() }

    public func reconcile() async throws {
        if running { needsAnotherPass = true; return }
        running = true
        defer { running = false }
        repeat {
            needsAnotherPass = false
            try await reconcilePass()
        } while needsAnotherPass
    }

    private func reconcilePass() async throws {
        let tasks = try store.reminderWork(limit: 1_000)
        let permission = await notifications.permission()
        let installed = await notifications.pending()
        let identifierPrefix = "mira.\(namespace)."
        let currentIdentifiers = Set(tasks.map { identifier(for: $0) })
        // A reset can leave a request whose task row no longer exists. Remove only
        // requests owned by this library namespace; other Mira libraries may share
        // the same notification center.
        for request in installed where request.identifier.hasPrefix(identifierPrefix) && !currentIdentifiers.contains(request.identifier) {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: String(request.identifier.dropFirst(identifierPrefix.count))),
                  try !store.reminderTaskExists(.init(id)) else { continue }
            await notifications.remove(request.identifier)
        }
        for task in tasks {
            try Task.checkCancellation()
            let identifier = identifier(for: task)
            // An edit may occur at every await. Revision checks are authoritative.
            let current = try store.taskDetail(task.id, workspaceID: task.workspaceID)
            guard current.revision == task.revision else { needsAnotherPass = true; continue }
            let state: ReminderDeliveryState
            var deliveryError: MiraError?
            if task.status.isTerminal || task.draft.reminderAt == nil || task.deliveryState == .paused {
                await notifications.remove(identifier)
                state = task.deliveryState == .paused ? .paused : (task.status.isTerminal ? .cancelled : .none)
            } else if permission != .allowed {
                await notifications.remove(identifier)
                state = .permissionRequired
            } else if let fireAt = task.draft.reminderAt, fireAt <= now() {
                // A missing past request does not prove that the user saw a notification.
                state = .elapsed
            } else if let fireAt = task.draft.reminderAt {
                let desired = ReminderNotification(identifier: identifier, title: task.draft.title, body: task.draft.notes, fireAt: fireAt, revision: task.revision)
                if installed.first(where: { $0.identifier == identifier }) == desired {
                    state = .scheduled
                } else {
                    do {
                        try await notifications.install(desired)
                        let observed = await notifications.pending()
                        guard observed.contains(desired) else { throw MiraError(.storage, "The system did not confirm the reminder schedule. Retry scheduling.") }
                        state = .scheduled
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // A failed replacement must not leave the previous time armed.
                        await notifications.remove(identifier)
                        state = .failed
                        deliveryError = .init(.storage, "The reminder could not be scheduled. Retry scheduling.")
                    }
                }
            } else { state = .none }
            if try !store.setReminderDelivery(task.id, expectedRevision: task.revision, state: state, error: deliveryError, at: now()) {
                await notifications.remove(identifier)
                needsAnotherPass = true
            }
        }
    }

    private func identifier(for task: MiraTask) -> String {
        "mira.\(namespace).\(task.id.rawValue.uuidString.lowercased())"
    }
}
