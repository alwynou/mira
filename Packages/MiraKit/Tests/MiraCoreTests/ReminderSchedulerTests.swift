import Foundation
import Testing
import MiraCore

@Suite("Reminder scheduler cleanup")
struct ReminderSchedulerTests {
    @Test(arguments: [true, false])
    func removesOnlyOrphanRequestsInThisLibraryNamespace(inWorkPage: Bool) async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let task = MiraTask(
            id: .init(), workspaceID: nil,
            draft: TaskDraft(title: "Current reminder", reminderAt: now.addingTimeInterval(3_600)),
            status: .open, createdAt: now, updatedAt: now
        )
        let namespace = "library-a"
        let currentIdentifier = "mira.\(namespace).\(task.id.rawValue.uuidString.lowercased())"
        let orphanIdentifier = "mira.\(namespace).\(UUID().uuidString.lowercased())"
        let foreignIdentifier = "mira.library-b.\(UUID().uuidString.lowercased())"
        let current = ReminderNotification(identifier: currentIdentifier, title: task.draft.title, body: task.draft.notes,
                                            fireAt: task.draft.reminderAt!, revision: task.revision)
        let orphan = ReminderNotification(identifier: orphanIdentifier, title: "Orphan", body: "", fireAt: now.addingTimeInterval(7_200), revision: 1)
        let foreign = ReminderNotification(identifier: foreignIdentifier, title: "Other library", body: "", fireAt: now.addingTimeInterval(7_200), revision: 1)
        let store = SchedulerStore(tasks: [task], includeInWorkPage: inWorkPage)
        let notifications = SchedulerNotificationPort(initial: [current, orphan, foreign])
        try await withScheduler(store: store, notifications: notifications, namespace: namespace, now: now) { scheduler in
            try await scheduler.reconcile()

            let pending = await notifications.pending()
            #expect(pending.contains(orphan) == false)
            #expect(pending.contains(foreign))
            #expect(pending.contains(current))
        }
    }
}

private actor SchedulerStore: TaskStore {
    var tasks: [MiraTask]
    let includeInWorkPage: Bool
    init(tasks: [MiraTask], includeInWorkPage: Bool) { self.tasks = tasks; self.includeInWorkPage = includeInWorkPage }

    func taskList(workspaceID: WorkspaceID?, includeCompleted: Bool, limit: Int) async throws -> [MiraTask] { tasks }
    func taskDetail(_ id: MiraTaskID, workspaceID: WorkspaceID?) async throws -> MiraTask {
        guard let task = tasks.first(where: { $0.id == id }) else { throw MiraError(.notFound, "Task is unavailable.") }
        return task
    }
    func taskRevision(_ id: MiraTaskID, revision: Int, workspaceID: WorkspaceID?) async throws -> TaskRevision {
        guard let task = tasks.first(where: { $0.id == id && $0.revision == revision }) else {
            throw MiraError(.notFound, "Task revision is unavailable.")
        }
        return .init(task: task, operation: "synthetic", actor: "test", changedAt: task.updatedAt)
    }
    func taskRevisions(_ id: MiraTaskID, workspaceID: WorkspaceID?) async throws -> [TaskRevision] { [] }
    func taskProposals(workspaceID: WorkspaceID?) async throws -> [TaskProposal] { [] }
    func saveTask(_ id: MiraTaskID, workspaceID: WorkspaceID?, draft: TaskDraft, status: MiraTaskStatus,
                  expectedRevision: Int?, operationID: UUID, authorization: AgentLibraryAuthorization, at: Date) async throws -> MiraTask {
        throw MiraError(.unsupported, "Synthetic store does not save tasks.")
    }
    func resolveTaskProposal(_ id: UUID, workspaceID: WorkspaceID?, accept: Bool, correctedDraft: TaskDraft?,
                             source: SessionUserEvidence?, authorization: AgentLibraryAuthorization, at: Date) async throws -> TaskWriteReceipt {
        throw MiraError(.unsupported, "Synthetic store does not resolve proposals.")
    }
    func reminderWork(limit: Int) async throws -> [MiraTask] { includeInWorkPage ? tasks : [] }
    func reminderTaskExists(_ id: MiraTaskID) async throws -> Bool { tasks.contains { $0.id == id } }
    func setReminderDelivery(_ id: MiraTaskID, expectedRevision: Int, state: ReminderDeliveryState, error: MiraError?,
                             authorization: AgentLibraryAuthorization, at: Date) async throws -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].revision == expectedRevision else { return false }
        tasks[index].deliveryState = state
        tasks[index].deliveryRevision = expectedRevision
        tasks[index].deliveryError = error
        return true
    }
    func resumeReminder(_ id: MiraTaskID, workspaceID: WorkspaceID?, expectedRevision: Int,
                        authorization: AgentLibraryAuthorization, at: Date) async throws {}
}

private actor SchedulerNotificationPort: LocalNotificationPort {
    private var values: [String: ReminderNotification]
    init(initial: [ReminderNotification]) { values = Dictionary(uniqueKeysWithValues: initial.map { ($0.identifier, $0) }) }
    func permission() async -> NotificationPermission { .allowed }
    func requestPermission() async throws -> Bool { true }
    func pending() async -> [ReminderNotification] { Array(values.values) }
    func install(_ notification: ReminderNotification) async throws { values[notification.identifier] = notification }
    func remove(_ identifier: String) async { values[identifier] = nil }
}

private actor SchedulerAccessStore: AgentLibraryMaintenanceStore {
    private let storedState: AgentLibraryMaintenanceState

    init() {
        storedState = .init(
            authorization: .init(libraryID: UUID(), epoch: 1),
            pending: nil
        )
    }

    func state() async throws -> AgentLibraryMaintenanceState { storedState }
    func operation(id: UUID) async throws -> AgentLibraryMaintenanceOperation? { nil }

    func begin(_ request: AgentLibraryMaintenanceRequest,
               expected: AgentLibraryAuthorization) async throws -> AgentLibraryMaintenanceOperation {
        throw MiraError(.unsupported, "Synthetic scheduler authority does not perform maintenance.")
    }

    func complete(_ operation: AgentLibraryMaintenanceOperation,
                  at date: Date) async throws -> AgentLibraryMaintenanceOperation {
        throw MiraError(.unsupported, "Synthetic scheduler authority does not perform maintenance.")
    }
}

private func withScheduler<T>(store: SchedulerStore, notifications: SchedulerNotificationPort,
                             namespace: String, now: Date,
                             _ body: (ReminderScheduler) async throws -> T) async throws -> T {
    let access = try await AgentLibraryAccess.open(store: SchedulerAccessStore())
    let scope = RuntimeScope(kind: .application)
    let scheduler = ReminderScheduler(store: store, notifications: notifications, namespace: namespace,
                                      access: access, scope: scope, now: { now })
    do {
        let result = try await body(scheduler)
        await scheduler.close()
        await access.close()
        await scope.dispose()
        return result
    } catch {
        await scheduler.close()
        await access.close()
        await scope.dispose()
        throw error
    }
}
