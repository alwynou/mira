import Foundation
import Observation
import MiraCore

@MainActor @Observable
final class TaskModel {
    let application: MiraApplication
    private(set) var workspaceID: WorkspaceID?
    private(set) var tasks: [MiraTask] = []
    private(set) var proposals: [TaskProposal] = []
    private(set) var selectedTask: MiraTask?
    private(set) var selectedRevisions: [TaskRevision] = []
    var selectedID: MiraTaskID?
    var includeCompleted = false
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var notificationRequestInFlight = false
    var error: MiraError?
    var notificationMessageKey: String?

    private var reloadGeneration = 0
    private var detailGeneration = 0

    init(application: MiraApplication, workspaceID: WorkspaceID?) {
        self.application = application
        self.workspaceID = workspaceID
    }

    var listIdentity: String {
        "\(workspaceID?.rawValue.uuidString ?? "global")|\(includeCompleted)"
    }

    func observe() async {
        await reload()
        let events = await application.events()
        for await event in events {
            guard !Task.isCancelled else { return }
            if case .changed = event { await reload() }
        }
    }

    func reload() async {
        let generation = reloadGeneration + 1
        reloadGeneration = generation
        isLoading = true
        defer {
            if generation == reloadGeneration { isLoading = false }
        }
        do {
            error = nil
            async let loadedTasks = application.taskList(workspaceID: workspaceID, includeCompleted: includeCompleted, limit: 100)
            async let loadedProposals = application.taskProposals(workspaceID: workspaceID)
            let (newTasks, newProposals) = try await (loadedTasks, loadedProposals)
            guard generation == reloadGeneration, !Task.isCancelled else { return }
            tasks = newTasks
            proposals = newProposals.filter { $0.state == .pending }
            if let selectedID {
                if tasks.contains(where: { $0.id == selectedID }) {
                    await loadDetail(selectedID)
                } else {
                    self.selectedID = nil
                    selectedTask = nil
                    selectedRevisions = []
                }
            }
        } catch {
            guard generation == reloadGeneration, !Task.isCancelled else { return }
            self.error = MiraError.safe(error)
        }
    }

    func select(_ id: MiraTaskID?) async {
        selectedID = id
        selectedTask = nil
        selectedRevisions = []
        guard let id else { return }
        await loadDetail(id)
    }

    private func loadDetail(_ id: MiraTaskID) async {
        let generation = detailGeneration + 1
        detailGeneration = generation
        do {
            async let detail = application.taskDetail(id, workspaceID: workspaceID)
            async let history = application.taskRevisions(id, workspaceID: workspaceID)
            let (task, revisions) = try await (detail, history)
            guard generation == detailGeneration, selectedID == id, !Task.isCancelled else { return }
            selectedTask = task
            selectedRevisions = revisions
        } catch {
            guard generation == detailGeneration, !Task.isCancelled else { return }
            selectedID = nil
            selectedTask = nil
            selectedRevisions = []
            self.error = MiraError.safe(error)
        }
    }

    @discardableResult
    func save(draft: TaskDraft, existing: MiraTask? = nil) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let saved = try await application.saveTask(
                id: existing?.id ?? MiraTaskID(), workspaceID: workspaceID, draft: draft,
                status: existing?.status ?? .open, expectedRevision: existing?.revision,
                operationID: UUID())
            selectedID = saved.id
            await reload()
            await loadDetail(saved.id)
            return true
        } catch {
            self.error = MiraError.safe(error)
            return false
        }
    }

    func changeStatus(_ task: MiraTask, to status: MiraTaskStatus) async {
        guard !isSaving else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let saved = try await application.saveTask(
                id: task.id, workspaceID: workspaceID, draft: task.draft, status: status,
                expectedRevision: task.revision, operationID: UUID())
            selectedID = saved.id
            await reload()
            await loadDetail(saved.id)
        } catch {
            self.error = MiraError.safe(error)
        }
    }

    @discardableResult
    func resolve(_ proposal: TaskProposal, accept: Bool, correctedDraft: TaskDraft? = nil) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let receipt = try await application.resolveTaskProposal(
                id: proposal.id, workspaceID: workspaceID, accept: accept, correctedDraft: correctedDraft)
            if let task = receipt.task { selectedID = task.id }
            await reload()
            if let task = receipt.task { await loadDetail(task.id) }
            return true
        } catch {
            self.error = MiraError.safe(error)
            return false
        }
    }

    func resumeReminder(_ task: MiraTask) async {
        guard !isSaving else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            try await application.resumeReminder(task.id, workspaceID: workspaceID, expectedRevision: task.revision)
            await reload()
            await loadDetail(task.id)
        } catch {
            self.error = MiraError.safe(error)
        }
    }

    func enableNotifications() async {
        guard !notificationRequestInFlight else { return }
        notificationRequestInFlight = true
        notificationMessageKey = nil
        defer { notificationRequestInFlight = false }
        do {
            let granted = try await application.requestNotificationAuthorization()
            notificationMessageKey = granted ? "Notifications enabled." : "Notifications remain disabled."
            await reload()
        } catch {
            self.error = MiraError.safe(error)
        }
    }
}
