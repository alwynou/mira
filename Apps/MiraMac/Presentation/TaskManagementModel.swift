import Foundation
import MiraCore
import Observation

/// An intentional, one-time editing snapshot. Feed updates never change its CAS target.
@MainActor @Observable
final class TaskManagementEditor: Identifiable {
    let id = UUID()
    let workspaceID: WorkspaceID?
    let taskID: MiraTaskID?
    let proposal: TaskProposal?
    let expectedRevision: Int?
    var title: String
    var notes: String
    var timeZoneID: String
    var includesDue: Bool
    var dueAt: Date
    var includesReminder: Bool
    var reminderAt: Date
    var status: MiraTaskStatus
    var error: MiraError?
    var reminderTimeConfirmed = false
    let saveTaskID: MiraTaskID
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var previousDraft: TaskDraft?
    @ObservationIgnored private var previousStatus: MiraTaskStatus?

    var isExisting: Bool { taskID != nil }
    var canSave: Bool {
        guard (try? draft().validate()) != nil else { return false }
        if proposal?.requiresTimeClarification == true && (!includesReminder || !reminderTimeConfirmed) { return false }
        return status.isTerminal || !includesReminder || reminderAt > .now
    }

    init(task: MiraTask) {
        workspaceID = task.workspaceID; taskID = task.id; saveTaskID = task.id; proposal = nil
        expectedRevision = task.revision
        title = task.draft.title; notes = task.draft.notes; timeZoneID = task.draft.timeZoneID
        includesDue = task.draft.dueAt != nil; dueAt = task.draft.dueAt ?? .now
        includesReminder = task.draft.reminderAt != nil; reminderAt = task.draft.reminderAt ?? .now.addingTimeInterval(3600)
        status = task.status
    }

    init(proposal: TaskProposal) {
        workspaceID = proposal.workspaceID; taskID = proposal.taskID; self.proposal = proposal
        saveTaskID = proposal.taskID ?? .init(); expectedRevision = proposal.expectedRevision
        title = proposal.draft.title; notes = proposal.draft.notes; timeZoneID = proposal.draft.timeZoneID
        includesDue = proposal.draft.dueAt != nil; dueAt = proposal.draft.dueAt ?? .now
        includesReminder = proposal.draft.reminderAt != nil || proposal.requiresTimeClarification
        reminderAt = proposal.draft.reminderAt ?? .now.addingTimeInterval(3600)
        status = proposal.operation == .complete ? .completed : proposal.operation == .cancel ? .cancelled : .open
    }

    init(workspaceID: WorkspaceID?) {
        self.workspaceID = workspaceID; taskID = nil; saveTaskID = .init(); proposal = nil; expectedRevision = nil
        title = ""; notes = ""; timeZoneID = TimeZone.current.identifier
        includesDue = false; dueAt = .now.addingTimeInterval(3600)
        includesReminder = false; reminderAt = .now.addingTimeInterval(3600); status = .open
    }

    func draft() -> TaskDraft {
        TaskDraft(title: title, notes: notes, dueAt: includesDue ? dueAt : nil,
                  reminderAt: includesReminder ? reminderAt : nil, timeZoneID: timeZoneID)
    }

    /// An identical retry reuses its operation identity; editing starts a new request.
    func saveOperationID() -> UUID {
        let value = draft()
        if previousDraft != value || previousStatus != status {
            operationID = UUID(); previousDraft = value; previousStatus = status
        }
        return operationID
    }
}

/// Read ownership follows the mounted screen and library generation. Accepted writes
/// remain owned here and in the library applications when the screen disappears.
@MainActor @Observable
final class TaskManagementModel {
    let library: MacLibrary
    var workspaceID: WorkspaceID? {
        didSet {
            guard oldValue != workspaceID else { return }
            items = []; proposals = []; select(nil); refresh()
        }
    }
    var searchText = "" { didSet { if oldValue != searchText { scheduleSearch() } } }
    var status: TaskManagementStatus = .active { didSet { if oldValue != status { refresh() } } }
    private(set) var items: [MiraTask] = []
    private(set) var proposals: [TaskProposal] = []
    private(set) var workspaces: [Workspace] = []
    private(set) var selectedID: MiraTaskID?
    private(set) var detail: MiraTask?
    private(set) var revisions: [TaskRevision] = []
    private(set) var hasMore = false
    private(set) var hasMoreProposals = false
    private(set) var hasMoreRevisions = false
    private(set) var isLoading = false
    private(set) var isLoadingDetail = false
    private(set) var isLoadingProposals = false
    private(set) var isWorking = false
    private(set) var error: MiraError?
    private(set) var generation: UInt64?
    var editor: TaskManagementEditor?

    @ObservationIgnored private var group: MacLibraryWorkloads?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var bindingID = UUID()
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var businessTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var proposalTask: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var retirementTask: Task<Void, Never>?
    @ObservationIgnored private var readToken = UUID()
    @ObservationIgnored private var detailToken = UUID()
    @ObservationIgnored private var proposalToken = UUID()
    @ObservationIgnored private var readDirty = false

    init(library: MacLibrary) { self.library = library }

    func observe() async {
        let run = UUID(); runID = run
        if let previous = observationTask { previous.cancel(); retire([previous]) }
        observationTask = nil
        invalidate(run: run)
        await retirementTask?.value
        guard !Task.isCancelled, runID == run else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            for await state in await library.observe() {
                guard !Task.isCancelled, self.runID == run else { break }
                switch state.phase {
                case .ready:
                    guard let binding = try? await library.binding(), !Task.isCancelled,
                          self.runID == run, binding.status.phase == .ready,
                          binding.status.generation == state.generation else { continue }
                    if self.generation != state.generation || self.group !== binding.workgroup {
                        await self.bind(binding.workgroup, generation: state.generation, run: run)
                    }
                case .failed:
                    self.invalidate(run: run); self.error = state.failure
                default: self.invalidate(run: run)
                }
            }
            if self.runID == run { self.invalidate(run: run) }
        }
        observationTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        if runID == run { observationTask = nil }
        await retirementTask?.value
    }

    func refresh() {
        guard let group, let generation else { return }
        readDirty = true; isLoading = true
        cancelProposalRead()
        if readTask == nil { startRead(group, generation: generation, append: false) }
    }

    func loadMore() {
        guard hasMore, !isLoading, let group, let generation else { return }
        isLoading = true
        startRead(group, generation: generation, append: true)
    }

    func loadMoreProposals() {
        guard hasMoreProposals, !isLoading, !isLoadingProposals, let group, let generation else { return }
        let run = runID, binding = bindingID, token = UUID(), workspace = workspaceID
        proposalToken = token; isLoadingProposals = true
        let offset = proposals.count
        proposalTask = Task { @MainActor [weak self] in
            do {
                let page = try await group.tasks.proposalPage(workspaceID: workspace, offset: offset, limit: 50)
                guard !Task.isCancelled, let self,
                      await self.isCurrent(run: run, binding: binding, generation: generation),
                      self.proposalToken == token else { return }
                let existing = Set(self.proposals.map(\.id))
                self.proposals += page.items.filter { !existing.contains($0.id) }
                self.hasMoreProposals = page.hasMore
                self.isLoadingProposals = false; self.proposalTask = nil
            } catch {
                guard !Task.isCancelled, let self,
                      await self.isCurrent(run: run, binding: binding, generation: generation),
                      self.proposalToken == token else { return }
                self.isLoadingProposals = false; self.proposalTask = nil
                self.reportReadError(error)
            }
        }
    }

    func loadMoreRevisions() {
        guard hasMoreRevisions, !isLoadingDetail, let id = selectedID, let group, let generation else { return }
        loadDetail(id, group: group, generation: generation, appendRevisions: true)
    }

    func select(_ id: MiraTaskID?) {
        selectedID = id; clearDetail()
        guard let id, let group, let generation else { return }
        loadDetail(id, group: group, generation: generation)
    }

    func beginCreate() {
        guard generation != nil, !isWorking else { return }
        editor = TaskManagementEditor(workspaceID: workspaceID)
    }
    func beginEdit(_ task: MiraTask) {
        guard generation != nil, !isWorking else { return }
        editor = TaskManagementEditor(task: task)
    }
    func beginReview(_ proposal: TaskProposal) {
        guard generation != nil, !isWorking else { return }
        editor = TaskManagementEditor(proposal: proposal)
    }

    func saveEditor() {
        guard let editor, editor.canSave, !isWorking else { return }
        let draft = editor.draft(), workspace = editor.workspaceID
        let taskID = editor.saveTaskID, revision = editor.expectedRevision, status = editor.status
        let proposal = editor.proposal, operationID = editor.saveOperationID()
        editor.error = nil
        mutate(editorID: editor.id) { group in
            if let proposal {
                return try await group.tasks.resolve(id: proposal.id, workspaceID: workspace,
                    accept: true, correctedDraft: draft).task
            }
            return try await group.tasks.save(id: taskID, workspaceID: workspace, draft: draft,
                status: status, expectedRevision: revision, operationID: operationID)
        }
    }

    func reloadEditor() {
        guard let target = editor, target.proposal == nil, let id = target.taskID,
              !isWorking, let group, let generation else { return }
        let run = runID, binding = bindingID, workspace = target.workspaceID
        isWorking = true
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isWorking = false; self.actionTask = nil }
            do {
                let value = try await group.tasks.detail(id: id, workspaceID: workspace)
                guard await self.isCurrent(run: run, binding: binding, generation: generation), self.editor?.id == target.id else { return }
                self.editor = TaskManagementEditor(task: value)
            } catch {
                guard await self.isCurrent(run: run, binding: binding, generation: generation), self.editor?.id == target.id else { return }
                target.error = MiraError.safe(error)
            }
        }
    }

    func changeStatus(_ task: MiraTask, to status: MiraTaskStatus) {
        guard !isWorking else { return }
        if !status.isTerminal, let reminder = task.draft.reminderAt, reminder <= .now {
            beginEdit(task); editor?.status = status
            editor?.error = .init(.invalidInput, "Choose a future reminder time before scheduling.")
            return
        }
        let operationID = UUID()
        mutate { group in
            try await group.tasks.save(id: task.id, workspaceID: task.workspaceID, draft: task.draft,
                status: status, expectedRevision: task.revision, operationID: operationID)
        }
    }

    func reject(_ proposal: TaskProposal) {
        mutate(editorID: editor?.proposal?.id == proposal.id ? editor?.id : nil, reconciles: false) { group in
            _ = try await group.tasks.resolve(id: proposal.id, workspaceID: proposal.workspaceID, accept: false)
            return nil
        }
    }
    func requestNotifications() {
        mutate { group in _ = try await group.reminders.requestPermission(); return nil }
    }
    func retryReminders() { mutate { _ in nil } }
    func resumeReminder(_ task: MiraTask) {
        mutate { group in
            try await group.tasks.resumeReminder(id: task.id, workspaceID: task.workspaceID, expectedRevision: task.revision)
            return nil
        }
    }
    func dismissError() { error = nil }
    func waitForAction() async { await actionTask?.value }

    private func mutate(editorID: UUID? = nil, reconciles: Bool = true,
                        operation: @escaping @Sendable (MacLibraryWorkloads) async throws -> MiraTask?) {
        guard !isWorking, actionTask == nil, let group, let generation else { return }
        let run = runID, binding = bindingID
        isWorking = true; error = nil
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isWorking = false; self.actionTask = nil }
            do {
                let saved = try await operation(group)
                if await self.isCurrent(run: run, binding: binding, generation: generation) {
                    if let editorID, self.editor?.id == editorID { self.editor = nil }
                    if let saved, saved.workspaceID == self.workspaceID { self.selectedID = saved.id }
                    self.refresh()
                }
            } catch {
                guard await self.isCurrent(run: run, binding: binding, generation: generation) else { return }
                let failure = MiraError.safe(error)
                if let editorID, self.editor?.id == editorID { self.editor?.error = failure }
                else { self.error = failure }
                return
            }
            // A committed write remains successful even if scheduling subsequently fails.
            if reconciles {
                do { try await group.reminders.reconcile() }
                catch {
                    if await self.isCurrent(run: run, binding: binding, generation: generation) {
                        self.error = MiraError.safe(error)
                    }
                }
            }
            if await self.isCurrent(run: run, binding: binding, generation: generation) { self.refresh() }
        }
    }

    private func bind(_ group: MacLibraryWorkloads, generation: UInt64, run: UUID) async {
        invalidate(run: run); await retirementTask?.value
        guard !Task.isCancelled, runID == run else { return }
        let binding = UUID(); bindingID = binding
        do {
            let changes = try await group.changes.observe()
            guard !Task.isCancelled, runID == run, bindingID == binding else { return }
            self.group = group; self.generation = generation
            businessTask = Task { @MainActor [weak self] in
                for await event in changes {
                    guard !Task.isCancelled, let self, self.runID == run, self.bindingID == binding else { return }
                    if event.isClosed { self.invalidate(run: run) } else { self.refresh() }
                }
            }
            refresh()
        } catch {
            guard !Task.isCancelled, runID == run, bindingID == binding else { return }
            invalidate(run: run); self.error = MiraError.safe(error)
        }
    }

    private func startRead(_ group: MacLibraryWorkloads, generation: UInt64, append: Bool) {
        readDirty = false
        let token = UUID(), run = runID, binding = bindingID
        readToken = token
        let query = TaskManagementQuery(workspaceID: workspaceID, search: searchText,
            status: status, offset: append ? items.count : 0, limit: 50)
        readTask = Task { @MainActor [weak self] in
            do {
                async let result = group.tasks.managementPage(query)
                async let spaces = group.workspaces.workspaces()
                async let pending = group.tasks.proposalPage(workspaceID: query.workspaceID, offset: 0, limit: 50)
                let (page, workspaceValues, proposalPage) = try await (result, spaces, pending)
                guard !Task.isCancelled, let self,
                      await self.isCurrent(run: run, binding: binding, generation: generation), self.readToken == token else { return }
                self.readTask = nil
                if self.readDirty {
                    self.startRead(group, generation: generation, append: false); return
                }
                let existing = Set(self.items.map(\.id))
                self.items = append ? self.items + page.items.filter { !existing.contains($0.id) } : page.items
                self.hasMore = page.hasMore; self.workspaces = workspaceValues
                if !append {
                    self.proposals = proposalPage.items; self.hasMoreProposals = proposalPage.hasMore
                }
                self.isLoading = false
                if let id = self.selectedID { self.select(id) }
            } catch {
                guard !Task.isCancelled, let self,
                      await self.isCurrent(run: run, binding: binding, generation: generation), self.readToken == token else { return }
                self.readTask = nil
                if self.readDirty {
                    self.startRead(group, generation: generation, append: false); return
                }
                self.isLoading = false
                self.reportReadError(error)
            }
        }
    }

    private func loadDetail(_ id: MiraTaskID, group: MacLibraryWorkloads, generation: UInt64, appendRevisions: Bool = false) {
        let run = runID, binding = bindingID, token = UUID(), workspace = workspaceID
        let offset = appendRevisions ? revisions.count : 0
        detailToken = token; isLoadingDetail = true
        detailTask = Task { @MainActor [weak self] in
            do {
                async let task = group.tasks.detail(id: id, workspaceID: workspace)
                async let page = group.tasks.revisionPage(id: id, workspaceID: workspace, offset: offset, limit: 50)
                let (value, history) = try await (task, page)
                guard !Task.isCancelled, let self,
                      await self.isCurrent(run: run, binding: binding, generation: generation),
                      self.detailToken == token, self.selectedID == id else { return }
                let sameRevision = self.detail?.revision == value.revision
                self.detail = value
                if appendRevisions && !sameRevision {
                    self.detailTask = nil
                    self.select(id); return
                }
                let existing = Set(self.revisions.map(\.id))
                self.revisions = appendRevisions ? self.revisions + history.items.filter { !existing.contains($0.id) } : history.items
                self.hasMoreRevisions = history.hasMore
                self.isLoadingDetail = false; self.detailTask = nil
            } catch {
                guard !Task.isCancelled, let self,
                      await self.isCurrent(run: run, binding: binding, generation: generation), self.detailToken == token else { return }
                self.isLoadingDetail = false; self.detailTask = nil
                self.detail = nil; self.revisions = []
                self.reportReadError(error)
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.searchTask = nil; self.refresh()
        }
    }
    private func isCurrent(run: UUID, binding: UUID, generation: UInt64) async -> Bool {
        guard runID == run, bindingID == binding, self.generation == generation else { return false }
        let state = await library.status()
        return state.phase == .ready && state.generation == generation && runID == run && bindingID == binding && self.generation == generation
    }
    private func reportReadError(_ failure: Error) {
        if error == nil { error = MiraError.safe(failure) }
    }
    private func clearDetail() {
        detailToken = UUID()
        if let task = detailTask { task.cancel(); retire([task]); detailTask = nil }
        detail = nil; revisions = []; hasMoreRevisions = false; isLoadingDetail = false
    }
    private func cancelProposalRead() {
        proposalToken = UUID(); isLoadingProposals = false
        if let task = proposalTask { task.cancel(); retire([task]); proposalTask = nil }
    }
    private func invalidate(run: UUID) {
        guard runID == run else { return }
        bindingID = UUID(); generation = nil; group = nil
        clearDetail(); cancelProposalRead()
        let tasks = [readTask, businessTask, searchTask].compactMap { $0 }
        tasks.forEach { $0.cancel() }; retire(tasks)
        readTask = nil; businessTask = nil; searchTask = nil
        readToken = UUID(); readDirty = false
        items = []; proposals = []; workspaces = []; selectedID = nil
        hasMore = false; hasMoreProposals = false; isLoading = false; editor = nil; error = nil
    }
    private func retire(_ tasks: [Task<Void, Never>]) {
        guard !tasks.isEmpty else { return }
        let previous = retirementTask
        retirementTask = Task {
            await previous?.value
            for task in tasks { await task.value }
        }
    }
}
