import MiraCore
import SwiftUI

struct TaskManagementDetail: View {
    let task: MiraTask
    @Bindable var model: TaskManagementModel
    let openSource: (SessionEvidenceReference) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
                    Label(t(taskStatusKey(task.status)), systemImage: taskStatusSymbol(task.status))
                        .font(MiraTheme.Typography.caption)
                        .foregroundStyle(MiraTheme.Colors.secondaryText)
                    Text(verbatim: task.draft.title)
                        .font(MiraTheme.Typography.title)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("tasks.detail.title")
                    Label(scopeName, systemImage: task.workspaceID == nil ? "tray" : "folder")
                        .font(MiraTheme.Typography.caption)
                        .foregroundStyle(MiraTheme.Colors.secondaryText)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: MiraTheme.Spacing.sm) { actions }
                    VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) { actions }
                }
                .disabled(model.isWorking)
                if !task.draft.notes.isEmpty {
                    Text(verbatim: task.draft.notes)
                        .font(MiraTheme.Typography.body).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
                    if let due = task.draft.dueAt {
                        property("Due", value: taskDate(due, zone: task.draft.timeZoneID, locale: locale))
                    }
                    property("Time zone", value: task.draft.timeZoneID)
                    property("Last updated", value: taskDate(task.updatedAt, zone: task.draft.timeZoneID, locale: locale))
                }
                reminder
                TaskSourceEvidence(evidence: task.evidence, openSource: openSource)
                history
            }
            .padding(MiraTheme.Spacing.xl)
            .frame(maxWidth: MiraTheme.Layout.taskDetailContentMax, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tasks.detail")
    }

    @ViewBuilder private var actions: some View {
        Button(t("Edit task")) { model.beginEdit(task) }
            .buttonStyle(MiraSecondaryButtonStyle()).accessibilityIdentifier("tasks.edit")
        if task.status.isTerminal {
            Button(t("Reopen task")) { model.changeStatus(task, to: .open) }
                .buttonStyle(MiraSecondaryButtonStyle()).accessibilityIdentifier("tasks.reopen")
        } else {
            Button(t("Complete task")) { model.changeStatus(task, to: .completed) }
                .buttonStyle(MiraPrimaryButtonStyle()).accessibilityIdentifier("tasks.complete")
        }
        Menu {
            if task.status == .open {
                Button(t("Start task")) { model.changeStatus(task, to: .inProgress) }
            } else if task.status == .inProgress {
                Button(t("Mark as to do")) { model.changeStatus(task, to: .open) }
            }
            if !task.status.isTerminal {
                Button(t("Cancel task")) { model.changeStatus(task, to: .cancelled) }
            }
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel(t("More task actions"))
        .accessibilityIdentifier("tasks.more")
        .disabled(task.status.isTerminal)
    }

    private var reminder: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
            Label(t(taskDeliveryKey(task.deliveryState)), systemImage: "bell")
                .font(MiraTheme.Typography.section.weight(.semibold))
                .accessibilityIdentifier("tasks.delivery")
            if let fireAt = task.draft.reminderAt {
                Text(taskDate(fireAt, zone: task.draft.timeZoneID, locale: locale))
                    .font(MiraTheme.Typography.body)
            }
            Text(t(deliveryExplanation)).font(MiraTheme.Typography.caption)
                .foregroundStyle(MiraTheme.Colors.secondaryText)
            if let error = task.deliveryError {
                Text(L10n.error(error, locale: locale))
                    .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.failure)
            }
            if task.deliveryState == .permissionRequired {
                Button(t("Allow notifications")) { model.requestNotifications() }
                    .buttonStyle(MiraSecondaryButtonStyle())
                    .accessibilityIdentifier("tasks.allowNotifications")
                Text(t("If permission was denied, enable Mira in System Settings → Notifications, then check scheduling again."))
                    .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
            }
            if task.deliveryState == .paused {
                Button(t("Resume reminder")) { model.resumeReminder(task) }
                    .buttonStyle(MiraSecondaryButtonStyle()).accessibilityIdentifier("tasks.resumeReminder")
            }
            if [.pending, .failed, .permissionRequired, .scheduled].contains(task.deliveryState) {
                Button(t("Check scheduling")) { model.retryReminders() }
                    .buttonStyle(MiraSecondaryButtonStyle()).accessibilityIdentifier("tasks.retryReminder")
            }
            if task.deliveryState == .elapsed || (task.deliveryState == .paused && (task.draft.reminderAt ?? .distantFuture) <= .now) {
                Button(t("Choose a new reminder time")) { model.beginEdit(task) }
                    .buttonStyle(MiraSecondaryButtonStyle())
            }
        }
        .disabled(model.isWorking)
        .padding(MiraTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MiraTheme.Colors.inset, in: RoundedRectangle(cornerRadius: MiraTheme.Radius.row))
    }

    private var deliveryExplanation: String {
        switch task.deliveryState {
        case .none: "A due date does not send a notification. Edit the task to add a one-time reminder."
        case .pending: "The task is saved. System scheduling has not been confirmed yet."
        case .scheduled: "The system accepted this reminder. Delivery still depends on system notification settings."
        case .permissionRequired: "The task is saved, but Mira needs notification permission to schedule its reminder."
        case .failed: "The task is saved. Scheduling failed; check again to retry."
        case .elapsed: "The reminder time has passed. This does not confirm that you saw a notification."
        case .paused: "This reminder was restored from a backup. Resume it explicitly to schedule a notification."
        case .cancelled: "This task is completed or cancelled, so its reminder is no longer scheduled."
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
            Text(t("History")).font(MiraTheme.Typography.section.weight(.semibold))
            ForEach(model.revisions) { revision in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
                        Text(verbatim: revision.task.draft.title).textSelection(.enabled)
                        if !revision.task.draft.notes.isEmpty {
                            Text(verbatim: revision.task.draft.notes).textSelection(.enabled)
                        }
                        property("Status", value: t(taskStatusKey(revision.task.status)))
                        if let due = revision.task.draft.dueAt {
                            property("Due", value: taskDate(due, zone: revision.task.draft.timeZoneID, locale: locale))
                        }
                        if let date = revision.task.draft.reminderAt {
                            property("Reminder", value: taskDate(date, zone: revision.task.draft.timeZoneID, locale: locale))
                        }
                        property("Time zone", value: revision.task.draft.timeZoneID)
                        Text(t(revision.actor == "user" ? "Changed by you" : "Changed from a conversation"))
                            .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                        if let evidence = revision.task.evidence {
                            TaskSourceEvidence(evidence: evidence, openSource: openSource)
                        }
                    }
                    .padding(.vertical, MiraTheme.Spacing.md)
                } label: {
                    VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
                        Text(L10n.format("Revision %lld", locale: locale, Int64(revision.task.revision)))
                        Text(taskDate(revision.changedAt, zone: revision.task.draft.timeZoneID, locale: locale))
                            .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                    }
                }
                Divider()
            }
            if model.hasMoreRevisions {
                Button(t("Load earlier revisions")) { model.loadMoreRevisions() }
                    .disabled(model.isLoadingDetail)
            }
        }
        .accessibilityIdentifier("tasks.history")
    }

    private func property(_ key: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
            Text(t(key)).font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
            Text(verbatim: value).font(MiraTheme.Typography.body).textSelection(.enabled)
        }
    }
    private var scopeName: String {
        task.workspaceID.flatMap { id in model.workspaces.first { $0.id == id }?.name } ?? t("Inbox")
    }
    private func t(_ key: String) -> String { L10n.string(key, locale: locale) }
}

struct TaskSourceEvidence: View {
    let evidence: TaskEvidence?
    let openSource: (SessionEvidenceReference) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
            Text(L10n.string("Source", locale: locale)).font(MiraTheme.Typography.section.weight(.semibold))
            if let evidence {
                Text(verbatim: evidence.quote).textSelection(.enabled)
                    .font(MiraTheme.Typography.body)
                Text(taskDate(evidence.sentAt, zone: evidence.timeZoneID, locale: locale))
                    .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                Button(L10n.string("Open original message", locale: locale)) { openSource(evidence.source) }
                    .buttonStyle(MiraSecondaryButtonStyle()).accessibilityIdentifier("tasks.openSource")
            } else {
                Text(L10n.string("Created manually", locale: locale))
                    .font(MiraTheme.Typography.body).foregroundStyle(MiraTheme.Colors.secondaryText)
            }
        }
    }
}
