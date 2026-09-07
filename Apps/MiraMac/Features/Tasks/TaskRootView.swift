import SwiftUI
import MiraCore

struct TaskRootView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var model: TaskModel
    @State private var editorRequest: TaskEditorRequest?
    @State private var proposalRequest: TaskProposal?

    init(application: MiraApplication, workspaceID: WorkspaceID?) {
        _model = State(initialValue: TaskModel(application: application, workspaceID: workspaceID))
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            VStack(spacing: 10) {
                Toggle("Include completed", isOn: $model.includeCompleted)
                    .accessibilityIdentifier("tasks.includeCompleted")
                    .padding(.horizontal, 12)
                List(selection: $model.selectedID) {
                    if !model.proposals.isEmpty {
                        Section {
                            ForEach(model.proposals) { proposal in
                                TaskProposalRow(proposal: proposal) {
                                    proposalRequest = proposal
                                }
                            }
                        } header: {
                            Text("Needs review")
                        }
                        .accessibilityIdentifier("tasks.proposals")
                    }
                    Section {
                        ForEach(model.tasks) { task in
                            TaskListRow(task: task)
                                .tag(task.id)
                                .accessibilityIdentifier("tasks.item.\(task.id.rawValue.uuidString)")
                        }
                    } header: {
                        Text("Tasks")
                    }
                }
                .scrollContentBackground(.hidden)
                .background(MiraTheme.Colors.canvas)
                .overlay {
                    if model.tasks.isEmpty && model.proposals.isEmpty && !model.isLoading {
                        ContentUnavailableView("No tasks", systemImage: "checklist", description: Text("Create a task or review a proposed task."))
                    }
                }
                .accessibilityIdentifier("tasks.list")
                Button("New task", systemImage: "plus") {
                    editorRequest = TaskEditorRequest(existing: nil)
                }
                .buttonStyle(MiraPrimaryButtonStyle())
                .accessibilityIdentifier("tasks.new")
                .padding(.bottom, 6)
            }
            .padding(.top, 12)
            .foregroundStyle(MiraTheme.Colors.text)
            .background(MiraTheme.Colors.canvas)
            .navigationTitle("Tasks")
        } detail: {
            if let task = model.selectedTask {
                TaskDetailView(
                    task: task, revisions: model.selectedRevisions,
                    isWorking: model.isSaving,
                    onEdit: { editorRequest = TaskEditorRequest(existing: task) },
                    onStatus: { status in await model.changeStatus(task, to: status) },
                    onResumeReminder: { await model.resumeReminder(task) },
                    onEnableNotifications: { await model.enableNotifications() },
                    notificationsWorking: model.notificationRequestInFlight)
                    .id(task.id)
            } else if model.selectedID != nil {
                ProgressView("Loading task")
            } else {
                ContentUnavailableView("Select a task", systemImage: "checklist", description: Text("Review task details, evidence, and reminder delivery."))
            }
        }
        .tint(MiraTheme.Colors.accent)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .frame(minWidth: 850, minHeight: 580)
        .task { await model.observe() }
        .task(id: model.listIdentity) { await model.reload() }
        .onChange(of: model.selectedID) { _, id in
            Task { await model.select(id) }
        }
        .sheet(item: $editorRequest) { request in
            TaskEditorView(existing: request.existing, isSaving: model.isSaving) { draft in
                let saved = await model.save(draft: draft, existing: request.existing)
                if saved { editorRequest = nil }
                return saved
            }
            .environment(\.locale, locale)
        }
        .sheet(item: $proposalRequest) { proposal in
            TaskProposalReviewView(proposal: proposal, isSaving: model.isSaving) { accept, draft in
                let saved = await model.resolve(proposal, accept: accept, correctedDraft: draft)
                if saved { proposalRequest = nil }
                return saved
            }
            .environment(\.locale, locale)
        }
        .alert("Task operation incomplete", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(verbatim: model.error.map { L10n.error($0, locale: locale) } ?? "")
        }
        .safeAreaInset(edge: .bottom) {
            if let messageKey = model.notificationMessageKey {
                Text(L10n.string(messageKey, locale: locale))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }
}

private struct TaskEditorRequest: Identifiable {
    let id = UUID()
    let existing: MiraTask?
}

private struct TaskListRow: View {
    @Environment(\.locale) private var locale
    let task: MiraTask

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: task.draft.title).font(.headline).lineLimit(2)
                Spacer(minLength: 8)
                Text(L10n.string(taskStatusKey(task.status), locale: locale))
                    .font(.caption)
                    .foregroundStyle(task.status == .open || task.status == .inProgress ? .primary : .secondary)
            }
            HStack(spacing: 8) {
                Text(verbatim: task.draft.timeZoneID)
                if let dueAt = task.draft.dueAt {
                    Text(dueAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                }
                Text(L10n.string(deliveryStateKey(task.deliveryState), locale: locale))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .environment(\.timeZone, TimeZone(identifier: task.draft.timeZoneID) ?? .current)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Task")
        .accessibilityValue(Text(verbatim: [task.draft.title, L10n.string(taskStatusKey(task.status), locale: locale), L10n.string(deliveryStateKey(task.deliveryState), locale: locale)].joined(separator: ", ")))
    }
}

private struct TaskProposalRow: View {
    @Environment(\.locale) private var locale
    let proposal: TaskProposal
    let onReview: () -> Void

    var body: some View {
        Button(action: onReview) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: proposal.draft.title).font(.headline).lineLimit(2)
                Text(L10n.string(proposal.requiresTimeClarification ? "Reminder time needs review" : "Proposed task", locale: locale))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tasks.proposal.\(proposal.id.uuidString)")
    }
}

private struct TaskDetailView: View {
    @Environment(\.locale) private var locale
    let task: MiraTask
    let revisions: [TaskRevision]
    let isWorking: Bool
    let onEdit: () -> Void
    let onStatus: (MiraTaskStatus) async -> Void
    let onResumeReminder: () async -> Void
    let onEnableNotifications: () async -> Void
    let notificationsWorking: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: task.draft.title).font(.title2).bold()
                    Spacer()
                    Text(L10n.string(taskStatusKey(task.status), locale: locale))
                        .foregroundStyle(.secondary)
                }
                if !task.draft.notes.isEmpty {
                    LabeledContent("Notes") { Text(verbatim: task.draft.notes).textSelection(.enabled) }
                }
                LabeledContent("Time zone") { Text(verbatim: task.draft.timeZoneID) }
                if let dueAt = task.draft.dueAt {
                    LabeledContent("Due") { Text(dueAt, format: .dateTime.year().month().day().hour().minute()) }
                }
                if let reminderAt = task.draft.reminderAt {
                    LabeledContent("Reminder") { Text(reminderAt, format: .dateTime.year().month().day().hour().minute()) }
                }
                deliveryView
                evidenceView
                revisionView
                actionView
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24)
        }
        .environment(\.timeZone, TimeZone(identifier: task.draft.timeZoneID) ?? .current)
        .navigationTitle("Task details")
        .toolbar {
            ToolbarItem {
                Button("Edit", systemImage: "pencil", action: onEdit)
                    .accessibilityIdentifier("tasks.edit")
                    .disabled(isWorking)
            }
        }
    }

    @ViewBuilder private var deliveryView: some View {
        GroupBox("Reminder delivery") {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string(deliveryStateKey(task.deliveryState), locale: locale))
                if let deliveryError = task.deliveryError {
                    Text(verbatim: L10n.error(deliveryError, locale: locale)).font(.caption).foregroundStyle(.red)
                }
                if task.deliveryState == .permissionRequired {
                    Text("Allow Mira notifications in System Settings, then return to retry scheduling.").font(.caption).foregroundStyle(.secondary)
                    Button("Enable notifications", action: {
                        Task { await onEnableNotifications() }
                    })
                    .buttonStyle(MiraPrimaryButtonStyle())
                    .disabled(notificationsWorking)
                    .accessibilityIdentifier("tasks.notifications.enable")
                }
                if task.deliveryState == .failed || task.deliveryState == .paused {
                    Button(task.deliveryState == .paused ? "Resume reminder" : "Retry scheduling", action: {
                        Task { await onResumeReminder() }
                    })
                    .buttonStyle(MiraPrimaryButtonStyle())
                    .disabled(isWorking)
                    .accessibilityIdentifier("tasks.reminder.recover")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("tasks.reminder.delivery")
    }

    @ViewBuilder private var evidenceView: some View {
        if let evidence = task.evidence {
            GroupBox("Original request") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: evidence.quote).textSelection(.enabled)
                    Text(evidence.sentAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: evidence.timeZoneID).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("tasks.evidence")
        }
    }

    @ViewBuilder private var revisionView: some View {
        GroupBox("Revision history") {
            if revisions.isEmpty {
                Text("No revision history available.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(revisions) { revision in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "v\(revision.task.revision) · \(L10n.string(taskRevisionKey(revision.operation), locale: locale))")
                            Text(verbatim: revision.task.draft.title).font(.caption)
                            if !revision.task.draft.notes.isEmpty { Text(verbatim: revision.task.draft.notes).font(.caption) }
                            LabeledContent("Changed by") {
                                Text(L10n.string(revision.actor == "user" ? "User" : "Assistant", locale: locale))
                            }
                            if let dueAt = revision.task.draft.dueAt {
                                LabeledContent("Due") { Text(dueAt, format: .dateTime.year().month().day().hour().minute()) }
                            }
                            if let reminderAt = revision.task.draft.reminderAt {
                                LabeledContent("Reminder") { Text(reminderAt, format: .dateTime.year().month().day().hour().minute()) }
                            }
                            Text(verbatim: revision.task.draft.timeZoneID).font(.caption).foregroundStyle(.secondary)
                            Text(revision.changedAt, format: .dateTime.year().month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .environment(\.timeZone, TimeZone(identifier: revision.task.draft.timeZoneID) ?? .current)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .accessibilityIdentifier("tasks.revisions")
    }

    private var actionView: some View {
        HStack {
            if task.status == .open || task.status == .inProgress {
                Button("Complete") { Task { await onStatus(.completed) } }
                    .buttonStyle(MiraPrimaryButtonStyle())
                    .accessibilityIdentifier("tasks.complete")
                Button("Cancel", role: .destructive) { Task { await onStatus(.cancelled) } }
                    .accessibilityIdentifier("tasks.cancel")
            } else {
                Button("Reopen") { Task { await onStatus(.open) } }
                    .buttonStyle(MiraPrimaryButtonStyle())
                    .accessibilityIdentifier("tasks.reopen")
            }
        }
        .disabled(isWorking)
    }
}

private struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let existing: MiraTask?
    let isSaving: Bool
    let onSave: (TaskDraft) async -> Bool
    @State private var title: String
    @State private var notes: String
    @State private var dueEnabled: Bool
    @State private var dueAt: Date
    @State private var reminderEnabled: Bool
    @State private var reminderAt: Date
    @State private var timeZoneID: String

    init(existing: MiraTask?, isSaving: Bool, onSave: @escaping (TaskDraft) async -> Bool) {
        self.existing = existing; self.isSaving = isSaving; self.onSave = onSave
        let draft = existing?.draft ?? TaskDraft(title: "")
        _title = State(initialValue: draft.title)
        _notes = State(initialValue: draft.notes)
        _dueEnabled = State(initialValue: draft.dueAt != nil)
        _dueAt = State(initialValue: draft.dueAt ?? .now)
        _reminderEnabled = State(initialValue: draft.reminderAt != nil)
        _reminderAt = State(initialValue: draft.reminderAt ?? .now.addingTimeInterval(3600))
        _timeZoneID = State(initialValue: draft.timeZoneID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("tasks.title")
                    TextEditor(text: $notes)
                        .frame(minHeight: 100)
                        .accessibilityIdentifier("tasks.notes")
                }
                Section("Schedule") {
                    Toggle("Add due date", isOn: $dueEnabled)
                    if dueEnabled {
                        DatePicker("Due", selection: $dueAt, displayedComponents: [.date, .hourAndMinute])
                            .accessibilityIdentifier("tasks.due")
                    }
                    Toggle("Add reminder", isOn: $reminderEnabled)
                    if reminderEnabled {
                        DatePicker("Reminder", selection: $reminderAt, displayedComponents: [.date, .hourAndMinute])
                            .accessibilityIdentifier("tasks.reminder")
                    }
                    LabeledContent("Time zone") { Text(verbatim: timeZoneID) }
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                    Button("Save") {
                        let draft = TaskDraft(title: title, notes: notes, dueAt: dueEnabled ? dueAt : nil,
                                              reminderAt: reminderEnabled ? reminderAt : nil, timeZoneID: timeZoneID)
                        Task { if await onSave(draft) { dismiss() } }
                    }
                    .buttonStyle(MiraPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("tasks.save")
                    Spacer()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "New task" : "Edit task")
        }
        .environment(\.timeZone, TimeZone(identifier: timeZoneID) ?? .current)
        .frame(minWidth: 520, minHeight: 480)
    }
}

private struct TaskProposalReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let proposal: TaskProposal
    let isSaving: Bool
    let onResolve: (Bool, TaskDraft?) async -> Bool
    @State private var title: String
    @State private var notes: String
    @State private var reminderEnabled: Bool
    @State private var reminderAt: Date
    @State private var dueEnabled: Bool
    @State private var dueAt: Date
    @State private var timeZoneID: String

    init(proposal: TaskProposal, isSaving: Bool, onResolve: @escaping (Bool, TaskDraft?) async -> Bool) {
        self.proposal = proposal; self.isSaving = isSaving; self.onResolve = onResolve
        _title = State(initialValue: proposal.draft.title); _notes = State(initialValue: proposal.draft.notes)
        _reminderEnabled = State(initialValue: proposal.draft.reminderAt != nil)
        _reminderAt = State(initialValue: proposal.draft.reminderAt ?? .now.addingTimeInterval(3600))
        _dueEnabled = State(initialValue: proposal.draft.dueAt != nil)
        _dueAt = State(initialValue: proposal.draft.dueAt ?? .now)
        _timeZoneID = State(initialValue: proposal.draft.timeZoneID)
    }

    private var draft: TaskDraft {
        TaskDraft(title: title, notes: notes, dueAt: dueEnabled ? dueAt : nil,
                  reminderAt: reminderEnabled ? reminderAt : nil, timeZoneID: timeZoneID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Review proposed task") {
                    LabeledContent("Action") { Text(taskOperationKey(proposal.operation)) }
                    TextField("Title", text: $title).accessibilityIdentifier("tasks.proposal.title")
                    TextEditor(text: $notes).frame(minHeight: 80).accessibilityIdentifier("tasks.proposal.notes")
                }
                Section("Schedule") {
                    Toggle("Add due date", isOn: $dueEnabled)
                    if dueEnabled { DatePicker("Due", selection: $dueAt, displayedComponents: [.date, .hourAndMinute]) }
                    Toggle("Add reminder", isOn: $reminderEnabled)
                    if reminderEnabled { DatePicker("Reminder", selection: $reminderAt, displayedComponents: [.date, .hourAndMinute]) }
                    LabeledContent("Time zone") { Text(verbatim: timeZoneID) }
                    if proposal.requiresTimeClarification {
                        Text("Choose an exact reminder date and time before accepting.")
                            .font(.callout).foregroundStyle(.orange)
                            .accessibilityIdentifier("tasks.proposal.timeRequired")
                    }
                }
                Section("Original request") { Text(verbatim: proposal.evidence.quote).textSelection(.enabled) }
                HStack {
                    Button("Reject", role: .destructive) { Task { if await onResolve(false, nil) { dismiss() } } }
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                    Button("Accept") { Task { if await onResolve(true, draft) { dismiss() } } }
                        .buttonStyle(MiraPrimaryButtonStyle())
                        .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (proposal.requiresTimeClarification && !reminderEnabled))
                        .accessibilityIdentifier("tasks.proposal.accept")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Review task proposal")
        }
        .environment(\.timeZone, TimeZone(identifier: timeZoneID) ?? .current)
        .frame(minWidth: 560, minHeight: 560)
    }
}

private func taskStatusKey(_ status: MiraTaskStatus) -> String {
    switch status { case .open: "Open"; case .inProgress: "In progress"; case .completed: "Completed"; case .cancelled: "Cancelled" }
}

private func deliveryStateKey(_ state: ReminderDeliveryState) -> String {
    switch state {
    case .none: "No reminder"
    case .pending: "Pending"
    case .scheduled: "Scheduled"
    case .permissionRequired: "Permission required"
    case .failed: "Failed"
    case .elapsed: "Elapsed"
    case .paused: "Paused"
    case .cancelled: "Cancelled"
    }
}


private func taskRevisionKey(_ operation: String) -> String {
    switch operation {
    case "created": "Created"
    case "updated": "Updated"
    case "completed": "Completed"
    case "cancelled": "Cancelled"
    case "inProgress": "In progress"
    default: "Open"
    }
}


private func taskOperationKey(_ operation: TaskOperation) -> LocalizedStringKey {
    switch operation {
    case .create: "Create task"
    case .update: "Update task"
    case .complete: "Complete task"
    case .cancel: "Cancel task"
    }
}
