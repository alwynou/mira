import MiraCore
import SwiftUI

struct TaskManagementView: View {
    @Bindable var model: TaskManagementModel
    let openSource: (SessionEvidenceReference) -> Void
    @Environment(\.locale) private var locale
    @State private var showsProposals = false
    @FocusState private var listFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < MiraTheme.Layout.taskCompactBreakpoint
            HStack(spacing: 0) {
                if !compact || model.selectedID == nil || showsProposals {
                    listPane
                        .frame(width: compact ? nil : MiraTheme.Layout.taskListWidth)
                        .frame(maxWidth: compact ? .infinity : nil)
                }
                if !compact { Divider() }
                if !compact || (model.selectedID != nil && !showsProposals) {
                    VStack(spacing: 0) {
                        if compact {
                            HStack {
                                Button { model.select(nil) } label: {
                                    Label(t("All tasks"), systemImage: "chevron.left")
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("tasks.back")
                                Spacer()
                            }
                            .padding(MiraTheme.Spacing.lg)
                            Divider()
                        }
                        detailPane
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(MiraTheme.Colors.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tasks.management")
        .task { await model.observe() }
        .sheet(item: $model.editor) { editor in
            TaskEditorView(editor: editor, model: model, openSource: openSource)
                .environment(\.locale, locale)
        }
        .alert(t("Operation incomplete"), isPresented: Binding(
            get: { model.error != nil && model.editor == nil },
            set: { if !$0 { model.dismissError() } }
        )) {
            Button(t("Refresh")) { model.dismissError(); model.refresh() }
            Button(t("OK"), role: .cancel) { model.dismissError() }
        } message: {
            Text(model.error.map { L10n.error($0, locale: locale) } ?? "")
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            VStack(spacing: MiraTheme.Spacing.md) {
                Picker(t("Task section"), selection: $showsProposals) {
                    Text(t("Tasks")).tag(false)
                    Text(t("Needs review")).tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("tasks.section")
                .onChange(of: showsProposals) { _, _ in model.select(nil) }

                HStack {
                    Menu {
                        Button(t("Inbox")) { model.workspaceID = nil }
                        ForEach(model.workspaces) { workspace in
                            Button { model.workspaceID = workspace.id } label: { Text(verbatim: workspace.name) }
                        }
                    } label: {
                        Label(scopeName, systemImage: model.workspaceID == nil ? "tray" : "folder")
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel(t("Task scope"))
                    .accessibilityIdentifier("tasks.scope")
                    Spacer(minLength: MiraTheme.Spacing.sm)
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .help(t("Refresh"))
                        .accessibilityLabel(t("Refresh"))
                        .accessibilityIdentifier("tasks.refresh")
                }
                if !showsProposals {
                    HStack(spacing: MiraTheme.Spacing.sm) {
                        Image(systemName: "magnifyingglass").foregroundStyle(MiraTheme.Colors.secondaryText)
                        TextField(t("Search tasks"), text: $model.searchText)
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("tasks.search")
                        if !model.searchText.isEmpty {
                            Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .accessibilityLabel(t("Clear search"))
                        }
                    }
                    .padding(MiraTheme.Spacing.sm)
                    .background(MiraTheme.Colors.inset, in: RoundedRectangle(cornerRadius: MiraTheme.Radius.small))
                    Picker(t("Status"), selection: $model.status) {
                        ForEach(TaskManagementStatus.allCases, id: \.self) { status in
                            Text(t(taskFilterKey(status))).tag(status)
                        }
                    }
                    .accessibilityIdentifier("tasks.statusFilter")
                }
            }
            .padding(MiraTheme.Spacing.lg)
            Divider()
            if showsProposals { proposalList } else { taskList }
            Divider()
            HStack(spacing: MiraTheme.Spacing.xs) {
                Image(systemName: "internaldrive")
                Text(t("Stored on this device"))
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
            }
            .font(MiraTheme.Typography.caption)
            .foregroundStyle(MiraTheme.Colors.tertiaryText)
            .padding(MiraTheme.Spacing.lg)
        }
    }

    @ViewBuilder private var taskList: some View {
        if model.isLoading && model.items.isEmpty {
            ProgressView(t("Loading tasks")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty {
            ContentUnavailableView(t("No tasks here"), systemImage: "checklist", description:
                Text(t("Add a task or change the scope, search, or status filter.")))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.items) { task in
                            Button { model.select(task.id) } label: {
                                TaskManagementRow(task: task, isSelected: model.selectedID == task.id)
                            }
                            .buttonStyle(MiraRowButtonStyle())
                            .id(task.id)
                            .accessibilityIdentifier("tasks.row.\(task.id.rawValue.uuidString)")
                            .accessibilityAddTraits(model.selectedID == task.id ? .isSelected : [])
                        }
                        if model.hasMore {
                            Button(t("Load more")) { model.loadMore() }
                                .disabled(model.isLoading).padding(MiraTheme.Spacing.md)
                        }
                    }
                    .padding(MiraTheme.Spacing.sm)
                }
                .focusable().focusEffectDisabled().focused($listFocused)
                .onMoveCommand { direction in
                    moveSelection(direction)
                    if let id = model.selectedID { proxy.scrollTo(id) }
                }
            }
            .accessibilityIdentifier("tasks.list")
        }
    }

    @ViewBuilder private var proposalList: some View {
        if model.isLoading && model.proposals.isEmpty {
            ProgressView(t("Loading tasks")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.proposals.isEmpty {
            ContentUnavailableView(t("Nothing to review"), systemImage: "checkmark.circle",
                description: Text(t("Task requests that need your confirmation appear here.")))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                    Text(t("These requests have not changed your tasks. Review the original message before accepting."))
                        .font(MiraTheme.Typography.caption)
                        .foregroundStyle(MiraTheme.Colors.secondaryText)
                        .padding(MiraTheme.Spacing.sm)
                    ForEach(model.proposals) { proposal in
                        Button { model.beginReview(proposal) } label: {
                            MiraSidebarRow {
                                VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                                    Text(verbatim: proposal.draft.title).lineLimit(3)
                                    Label(t(taskOperationKey(proposal.operation)), systemImage: "text.bubble")
                                        .font(MiraTheme.Typography.caption)
                                        .foregroundStyle(MiraTheme.Colors.secondaryText)
                                    if proposal.requiresTimeClarification {
                                        Text(t("Choose a reminder time"))
                                            .font(MiraTheme.Typography.caption)
                                            .foregroundStyle(MiraTheme.Colors.secondaryText)
                                    }
                                }
                                .padding(.vertical, MiraTheme.Spacing.sm)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(MiraRowButtonStyle()).disabled(model.isWorking)
                        .accessibilityIdentifier("tasks.proposal.\(proposal.id.uuidString)")
                    }
                    if model.hasMoreProposals {
                        Button(t("Load more")) { model.loadMoreProposals() }
                            .disabled(model.isLoading).padding(MiraTheme.Spacing.md)
                    }
                }
                .padding(MiraTheme.Spacing.sm)
            }
            .accessibilityIdentifier("tasks.proposals")
        }
    }

    @ViewBuilder private var detailPane: some View {
        if let task = model.detail, !showsProposals {
            TaskManagementDetail(task: task, model: model, openSource: openSource)
        } else if model.isLoadingDetail {
            ProgressView(t("Loading task")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(t(showsProposals ? "Review a task request" : "Select a task"),
                systemImage: showsProposals ? "text.bubble" : "checklist",
                description: Text(t(showsProposals
                    ? "Check the proposed change, its source, and the exact reminder time."
                    : "View its details, reminder status, and history here.")))
        }
    }

    private var scopeName: String {
        model.workspaceID.flatMap { id in model.workspaces.first { $0.id == id }?.name } ?? t("Inbox")
    }
    private func t(_ key: String) -> String { L10n.string(key, locale: locale) }
    private func moveSelection(_ direction: MoveCommandDirection) {
        let ids = model.items.map(\.id)
        guard !ids.isEmpty else { return }
        let current = model.selectedID.flatMap { ids.firstIndex(of: $0) }
        switch direction {
        case .up: model.select(ids[max((current ?? ids.count) - 1, 0)])
        case .down: model.select(ids[min((current ?? -1) + 1, ids.count - 1)])
        default: break
        }
    }
}

struct TaskManagementRow: View {
    let task: MiraTask
    let isSelected: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        MiraSidebarRow(isSelected: isSelected) {
            HStack(alignment: .top, spacing: MiraTheme.Spacing.md) {
                Image(systemName: taskStatusSymbol(task.status))
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                    Text(verbatim: task.draft.title).lineLimit(2)
                        .foregroundStyle(MiraTheme.Colors.text)
                    Text(L10n.string(taskStatusKey(task.status), locale: locale))
                        .font(MiraTheme.Typography.caption)
                        .foregroundStyle(MiraTheme.Colors.secondaryText)
                    if let due = task.draft.dueAt {
                        Label(taskDate(due, zone: task.draft.timeZoneID, locale: locale), systemImage: "calendar")
                            .font(MiraTheme.Typography.caption)
                            .foregroundStyle(MiraTheme.Colors.secondaryText)
                    }
                    if task.draft.reminderAt != nil {
                        Label(L10n.string(taskDeliveryKey(task.deliveryState), locale: locale), systemImage: "bell")
                            .font(MiraTheme.Typography.caption)
                            .foregroundStyle(MiraTheme.Colors.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, MiraTheme.Spacing.sm)
        }
        .accessibilityElement(children: .combine)
    }
}

func taskStatusKey(_ status: MiraTaskStatus) -> String {
    switch status {
    case .open: "To do"
    case .inProgress: "In progress"
    case .completed: "Completed"
    case .cancelled: "Cancelled"
    }
}
func taskStatusSymbol(_ status: MiraTaskStatus) -> String {
    switch status {
    case .open: "circle"
    case .inProgress: "circle.lefthalf.filled"
    case .completed: "checkmark.circle"
    case .cancelled: "xmark.circle"
    }
}
func taskFilterKey(_ status: TaskManagementStatus) -> String {
    switch status {
    case .all: "All statuses"
    case .active: "Active tasks"
    case .open: "To do"
    case .inProgress: "In progress"
    case .completed: "Completed"
    case .cancelled: "Cancelled"
    }
}
func taskOperationKey(_ operation: TaskOperation) -> String {
    switch operation {
    case .create: "Create task"
    case .update: "Update task"
    case .complete: "Complete task"
    case .cancel: "Cancel task"
    }
}
func taskDeliveryKey(_ state: ReminderDeliveryState) -> String {
    switch state {
    case .none: "No reminder"
    case .pending: "Awaiting scheduling"
    case .scheduled: "Scheduled by system"
    case .permissionRequired: "Notification permission needed"
    case .failed: "Scheduling failed"
    case .elapsed: "Reminder time passed"
    case .paused: "Paused after restore"
    case .cancelled: "Reminder cancelled"
    }
}
func taskDate(_ date: Date, zone: String, locale: Locale) -> String {
    date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale,
                                   timeZone: TimeZone(identifier: zone) ?? .current))
}
