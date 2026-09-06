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
        let scheduler = ReminderScheduler(store: store, notifications: notifications, namespace: namespace, now: { now })

        try await scheduler.reconcile()

        let pending = await notifications.pending()
        #expect(pending.contains(orphan) == false)
        #expect(pending.contains(foreign))
        #expect(pending.contains(current))
    }
}

private final class SchedulerStore: TaskStore, @unchecked Sendable {
    var tasks: [MiraTask]
    let includeInWorkPage: Bool
    init(tasks: [MiraTask], includeInWorkPage: Bool) { self.tasks = tasks; self.includeInWorkPage = includeInWorkPage }

    func taskList(workspaceID: WorkspaceID?, includeCompleted: Bool, limit: Int) throws -> [MiraTask] { tasks }
    func taskDetail(_ id: MiraTaskID, workspaceID: WorkspaceID?) throws -> MiraTask {
        guard let task = tasks.first(where: { $0.id == id }) else { throw MiraError(.notFound, "Task is unavailable.") }
        return task
    }
    func taskRevisions(_ id: MiraTaskID, workspaceID: WorkspaceID?) throws -> [TaskRevision] { [] }
    func saveTask(_ id: MiraTaskID, workspaceID: WorkspaceID?, draft: TaskDraft, status: MiraTaskStatus, expectedRevision: Int?, operationID: UUID, at: Date) throws -> MiraTask { throw MiraError(.unsupported, "Synthetic store does not save tasks.") }
    func taskProposals(workspaceID: WorkspaceID?) throws -> [TaskProposal] { [] }
    func resolveTaskProposal(_ id: UUID, workspaceID: WorkspaceID?, accept: Bool, correctedDraft: TaskDraft?, at: Date) throws -> TaskWriteReceipt { throw MiraError(.unsupported, "Synthetic store does not resolve proposals.") }
    func performTaskTool(arguments: JSONValue, context: ToolContext, at: Date) throws -> TaskWriteReceipt { throw MiraError(.unsupported, "Synthetic store does not perform tools.") }
    func taskToolReference(context: ToolContext) throws -> TaskEvidence { throw MiraError(.unsupported, "Synthetic store does not provide evidence.") }
    func reminderWork(limit: Int) throws -> [MiraTask] { includeInWorkPage ? tasks : [] }
    func reminderTaskExists(_ id: MiraTaskID) throws -> Bool { tasks.contains { $0.id == id } }
    func setReminderDelivery(_ id: MiraTaskID, expectedRevision: Int, state: ReminderDeliveryState, error: MiraError?, at: Date) throws -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].revision == expectedRevision else { return false }
        tasks[index].deliveryState = state
        tasks[index].deliveryRevision = expectedRevision
        tasks[index].deliveryError = error
        return true
    }
    func resumeReminder(_ id: MiraTaskID, workspaceID: WorkspaceID?, expectedRevision: Int, at: Date) throws {}
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
