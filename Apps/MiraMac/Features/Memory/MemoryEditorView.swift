import MiraCore
import SwiftUI

struct MemoryEditorView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var model: MemoryEditorModel
    @State private var isPresented = false
    @State private var validityExpanded = false
    let onSaved: () async -> Void

    init(
        library: MacLibrary, workspaces: [Workspace], existing: Memory? = nil,
        replacing: Memory? = nil, sourceMessage: SessionQueryMessage? = nil,
        initialScope: MemoryScope? = nil, onSaved: @escaping () async -> Void
    ) {
        _model = State(initialValue: MemoryEditorModel(
            library: library, workspaces: workspaces, existing: existing,
            replacing: replacing, sourceMessage: sourceMessage, initialScope: initialScope))
        self.onSaved = onSaved
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
                Text(titleKey).font(MiraTheme.Typography.title)
                Text(introKey)
                    .font(MiraTheme.Typography.body)
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MiraTheme.Spacing.xl)
            .padding(.top, MiraTheme.Spacing.xl)
            .padding(.bottom, MiraTheme.Spacing.md)

            ScrollView {
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
                    if model.isReplacing, let previous = model.replacingMemoryContent {
                        GroupBox {
                            VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
                                Text("Previous memory")
                                    .font(MiraTheme.Typography.section)
                                Text(verbatim: previous)
                                    .font(MiraTheme.Typography.body)
                                    .foregroundStyle(MiraTheme.Colors.secondaryText)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    if model.hasSourceMessage { sourceEvidence(model: model) }

                    GroupBox {
                        VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                            fieldLabel("Memory content")
                            TextEditor(text: $model.content)
                                .font(MiraTheme.Typography.body)
                                .frame(minHeight: 104)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(MiraTheme.Colors.inset, in: RoundedRectangle(cornerRadius: MiraTheme.Radius.small))
                                .accessibilityLabel("Memory content")
                                .accessibilityIdentifier("memory.editor.content")
                            if model.hasSourceMessage {
                                fieldLabel("Evidence excerpt")
                                TextEditor(text: $model.evidenceExcerpt)
                                    .font(MiraTheme.Typography.body)
                                    .frame(minHeight: 62)
                                    .scrollContentBackground(.hidden)
                                    .padding(6)
                                    .background(MiraTheme.Colors.inset, in: RoundedRectangle(cornerRadius: MiraTheme.Radius.small))
                                    .accessibilityLabel("Evidence excerpt")
                                Text("Keep an exact excerpt from the original message, up to 8 KiB.")
                                    .font(MiraTheme.Typography.caption)
                                    .foregroundStyle(MiraTheme.Colors.secondaryText)
                            }
                        }
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
                            labeledPicker("Kind", selection: $model.kind) {
                                ForEach(MemoryKind.allCases, id: \.self) { kind in
                                    Text(L10n.string(memoryKindKey(kind), locale: locale)).tag(kind)
                                }
                            }
                            labeledPicker("Scope", selection: $model.scopeChoice) {
                                Text("Global").tag(MemoryScopeChoice.global)
                                ForEach(model.workspaces) { workspace in
                                    Text(verbatim: workspace.name).tag(MemoryScopeChoice.workspace(workspace.id))
                                }
                            }
                            .disabled(model.isEditingExisting || model.isReplacing)
                            if model.isEditingExisting || model.isReplacing {
                                Text("The scope and subject of an existing memory stay unchanged.")
                                    .font(MiraTheme.Typography.caption)
                                    .foregroundStyle(MiraTheme.Colors.secondaryText)
                            } else {
                                labeledPicker("Subject", selection: $model.subject) {
                                    Text("User").tag(MemorySubject.user)
                                    Text("Workspace").tag(MemorySubject.workspace)
                                }
                                .disabled(model.scopeChoice == .global)
                            }
                        }
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
                            Toggle(isOn: $model.sensitive) { Text("Sensitive information") }
                            Text("Sensitive memories are local-only by default.")
                                .font(MiraTheme.Typography.caption)
                                .foregroundStyle(MiraTheme.Colors.secondaryText)
                            Toggle(isOn: $model.allowsRemoteUse) { Text("Allow use in remote model requests") }
                                .accessibilityIdentifier("memory.editor.remoteUse")
                            Text("This permission is separate from scope and source access.")
                                .font(MiraTheme.Typography.caption)
                                .foregroundStyle(MiraTheme.Colors.secondaryText)
                        }
                    }

                    GroupBox {
                        DisclosureGroup(isExpanded: $validityExpanded) {
                            VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                                Toggle("Set valid from", isOn: $model.hasValidFrom)
                                if model.hasValidFrom { DatePicker("Valid from", selection: $model.validFrom) }
                                Toggle("Set valid until", isOn: $model.hasValidUntil)
                                if model.hasValidUntil { DatePicker("Valid until", selection: $model.validUntil) }
                            }
                            .padding(.top, MiraTheme.Spacing.sm)
                        } label: {
                            Text("Validity")
                                .font(MiraTheme.Typography.section)
                        }
                    }
                }
                .padding(.horizontal, MiraTheme.Spacing.xl)
                .padding(.bottom, MiraTheme.Spacing.lg)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .frame(minHeight: 0, maxHeight: .infinity)

            Divider()
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                Text("Memory content is stored locally. Scope controls where it may be recalled; remote use is a separate permission.")
                    .font(MiraTheme.Typography.caption)
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
                if let error = model.error {
                    Text(L10n.error(error, locale: locale))
                        .font(.callout).foregroundStyle(MiraTheme.Colors.failure)
                        .textSelection(.enabled)
                }
                if model.receipt?.disposition == .replacementProposed {
                    Text("A competing replacement was saved for review. The active memory has not changed.")
                        .font(.callout).foregroundStyle(MiraTheme.Colors.secondaryText)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .accessibilityIdentifier("memory.editor.cancel")
                        .keyboardShortcut(.cancelAction)
                    if model.receipt?.disposition == .replacementProposed {
                        Button("Return to memory") { dismiss() }
                            .buttonStyle(MiraPrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(saveTitleKey) { Task { await save() } }
                            .accessibilityIdentifier("memory.editor.save")
                            .buttonStyle(MiraPrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.saving || model.saved || model.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(.horizontal, MiraTheme.Spacing.xl)
            .padding(.vertical, MiraTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, idealWidth: 760, maxWidth: 850)
        .frame(minHeight: 520, idealHeight: 620, maxHeight: 720)
        .background(MiraTheme.Colors.canvas)
        .onChange(of: model.sensitive) { _, isSensitive in
            if isSensitive { model.allowsRemoteUse = false }
        }
        .onChange(of: model.scopeChoice) { _, newScope in
            if newScope == .global { model.subject = .user }
        }
        .task {
            isPresented = true
            await model.observeLibrary()
        }
        .onDisappear {
            isPresented = false
            Task { await model.close() }
        }
    }

    private var titleKey: LocalizedStringKey {
        if model.isReplacing { return "Replace with new memory" }
        return model.isEditingExisting ? "Edit wording" : "Add memory"
    }

    private var introKey: LocalizedStringKey {
        if model.isReplacing { return "The new memory becomes current. The previous memory stays in history." }
        if model.isEditingExisting { return "Correct the wording while keeping this memory and its source." }
        return "Save something useful for the long term, such as a preference, constraint, or decision."
    }

    private var saveTitleKey: LocalizedStringKey {
        if model.isReplacing { return "Confirm replacement" }
        return model.isEditingExisting ? "Save changes" : "Add memory"
    }

    private func fieldLabel(_ key: LocalizedStringKey) -> some View {
        Text(key).font(MiraTheme.Typography.section)
    }

    private func labeledPicker<Selection, Content>(
        _ title: LocalizedStringKey, selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View where Selection: Hashable, Content: View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(MiraTheme.Typography.body).frame(width: 110, alignment: .leading)
            Picker(title, selection: selection, content: content)
                .labelsHidden()
                .frame(maxWidth: 320, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    private func sourceEvidence(model: MemoryEditorModel) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
                Text("Source: committed user message")
                    .font(MiraTheme.Typography.section)
                if let sourceText = model.sourceText {
                    Text(verbatim: sourceText)
                        .font(MiraTheme.Typography.caption)
                        .foregroundStyle(MiraTheme.Colors.secondaryText)
                        .lineLimit(4).textSelection(.enabled)
                } else if model.sourceLoading {
                    ProgressView("Checking source").controlSize(.small)
                } else {
                    Text("The original message is unavailable until the library is ready.")
                        .font(MiraTheme.Typography.caption)
                        .foregroundStyle(MiraTheme.Colors.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func save() async {
        await model.save()
        guard isPresented, model.saved, model.receipt?.disposition != .replacementProposed else { return }
        await onSaved()
        guard isPresented, model.saved else { return }
        dismiss()
    }
}

private func memoryKindKey(_ kind: MemoryKind) -> String {
    switch kind {
    case .fact: "Fact"
    case .preference: "Preference"
    case .decision: "Decision"
    case .goal: "Goal"
    case .constraint: "Constraint"
    case .procedure: "Procedure"
    case .learning: "Learning"
    case .context: "Context"
    }
}
