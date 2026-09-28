import MiraCore
import SwiftUI

struct TaskEditorView: View {
    @Bindable var editor: TaskManagementEditor
    @Bindable var model: TaskManagementModel
    let openSource: (SessionEvidenceReference) -> Void
    @Environment(\.locale) private var locale
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(t(editor.proposal == nil ? (editor.isExisting ? "Edit task" : "Add task") : "Review task request"))
                    .font(MiraTheme.Typography.title)
                Spacer()
            }
            .padding(MiraTheme.Spacing.xl)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.lg) {
                    Label(scopeName, systemImage: editor.workspaceID == nil ? "tray" : "folder")
                        .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                    if let proposal = editor.proposal {
                        Label(t(taskOperationKey(proposal.operation)), systemImage: "text.bubble")
                            .font(MiraTheme.Typography.section.weight(.semibold))
                        Text(t("Accepting applies this change to the task. Rejecting leaves the task unchanged."))
                            .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                    }
                    VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                        Text(t("Title")).font(MiraTheme.Typography.section)
                        TextField(t("Task title"), text: $editor.title)
                            .textFieldStyle(.roundedBorder).focused($titleFocused)
                            .accessibilityIdentifier("tasks.editor.title")
                    }
                    VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                        Text(t("Notes")).font(MiraTheme.Typography.section)
                        TextEditor(text: $editor.notes).font(MiraTheme.Typography.body)
                            .frame(minHeight: 90, maxHeight: 140)
                            .padding(MiraTheme.Spacing.xs)
                            .background(MiraTheme.Colors.inset, in: RoundedRectangle(cornerRadius: MiraTheme.Radius.small))
                            .accessibilityLabel(t("Task notes"))
                            .accessibilityIdentifier("tasks.editor.notes")
                    }
                    Toggle(t("Set a due date"), isOn: $editor.includesDue)
                        .accessibilityIdentifier("tasks.editor.hasDue")
                    if editor.includesDue {
                        DatePicker(t("Due"), selection: $editor.dueAt, displayedComponents: [.date, .hourAndMinute])
                            .environment(\.timeZone, editorZone)
                            .accessibilityIdentifier("tasks.editor.due")
                    }
                    Toggle(t("One-time reminder"), isOn: $editor.includesReminder)
                        .disabled(editor.proposal?.requiresTimeClarification == true)
                        .accessibilityIdentifier("tasks.editor.hasReminder")
                    if editor.includesReminder {
                        DatePicker(t("Remind me"), selection: $editor.reminderAt, displayedComponents: [.date, .hourAndMinute])
                            .environment(\.timeZone, editorZone)
                            .accessibilityIdentifier("tasks.editor.reminder")
                        Text(t("Choose a future time. Saving a reminder does not confirm system scheduling."))
                            .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                    }
                    LabeledContent(t("Time zone")) {
                        Text(verbatim: editor.timeZoneID).textSelection(.enabled)
                    }
                    .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                    if let proposal = editor.proposal {
                        if proposal.requiresTimeClarification {
                            Toggle(t("Confirm the exact reminder time before accepting."), isOn: $editor.reminderTimeConfirmed)
                                .font(MiraTheme.Typography.caption)
                                .accessibilityIdentifier("tasks.editor.confirmTime")
                        }
                        Divider()
                        TaskSourceEvidence(evidence: proposal.evidence) { source in
                            model.editor = nil
                            openSource(source)
                        }
                    }
                    if let error = editor.error {
                        Text(L10n.error(error, locale: locale))
                            .foregroundStyle(MiraTheme.Colors.failure)
                            .font(MiraTheme.Typography.caption)
                            .accessibilityIdentifier("tasks.editor.error")
                        if error.code == .conflict && editor.proposal == nil && editor.isExisting {
                            Text(t("Your edits are still here. Reloading replaces them with the latest task."))
                                .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                            Button(t("Reload latest task")) { model.reloadEditor() }
                                .buttonStyle(MiraSecondaryButtonStyle())
                        }
                    }
                }
                .padding(MiraTheme.Spacing.xl)
                .disabled(model.isWorking)
            }
            Divider()
            HStack(spacing: MiraTheme.Spacing.md) {
                if let proposal = editor.proposal {
                    Button(t("Reject request")) { model.reject(proposal) }
                        .accessibilityIdentifier("tasks.editor.reject")
                }
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
                Button(t("Cancel")) { model.editor = nil }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(MiraSecondaryButtonStyle())
                Button(t(editor.proposal == nil ? "Save task" : "Accept request")) { model.saveEditor() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(MiraPrimaryButtonStyle())
                    .disabled(!editor.canSave)
                    .accessibilityIdentifier("tasks.editor.save")
            }
            .disabled(model.isWorking)
            .padding(MiraTheme.Spacing.lg)
        }
        .frame(width: 500, height: 530)
        .background(MiraTheme.Colors.canvas)
        .interactiveDismissDisabled(model.isWorking)
        .accessibilityIdentifier("tasks.editor")
        .onAppear { if editor.proposal == nil { titleFocused = true } }
    }

    private var editorZone: TimeZone { TimeZone(identifier: editor.timeZoneID) ?? .current }
    private var scopeName: String {
        editor.workspaceID.flatMap { id in model.workspaces.first { $0.id == id }?.name } ?? t("Inbox")
    }
    private func t(_ key: String) -> String { L10n.string(key, locale: locale) }
}
