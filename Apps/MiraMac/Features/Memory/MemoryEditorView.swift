import MiraCore
import SwiftUI

struct MemoryEditorView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var model: MemoryEditorModel
    @State private var isPresented = false
    let onSaved: () async -> Void

    init(
        library: MacLibrary, workspaces: [Workspace], existing: Memory? = nil,
        replacing: Memory? = nil, sourceMessage: SessionQueryMessage? = nil,
        onSaved: @escaping () async -> Void
    ) {
        _model = State(
            initialValue: MemoryEditorModel(
                library: library, workspaces: workspaces, existing: existing,
                replacing: replacing, sourceMessage: sourceMessage))
        self.onSaved = onSaved
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            Text(titleKey).font(.title2.weight(.semibold))
            if model.hasSourceMessage { sourceNotice() }
            if model.isReplacing { replacementNotice() }
            Form {
                if model.hasSourceMessage {
                    TextField("Evidence excerpt", text: $model.evidenceExcerpt, axis: .vertical)
                        .lineLimit(2...5)
                    Text("Keep an exact excerpt from the original message, up to 8 KiB.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.sourceLoading {
                        ProgressView("Checking source").controlSize(.small)
                    } else if model.sourceText == nil {
                        Text("The original message is unavailable until the library is ready.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextField("Memory", text: $model.content, axis: .vertical)
                    .lineLimit(4...12).textFieldStyle(.roundedBorder)
                Picker("Kind", selection: $model.kind) {
                    ForEach(MemoryKind.allCases, id: \.self) { kind in
                        Text(L10n.string(memoryKindKey(kind), locale: locale)).tag(kind)
                    }
                }
                Picker("Scope", selection: $model.scopeChoice) {
                    Text("Global").tag(MemoryScopeChoice.global)
                    ForEach(model.workspaces) { workspace in
                        Text(verbatim: workspace.name).tag(MemoryScopeChoice.workspace(workspace.id))
                    }
                }
                .disabled(model.isEditingExisting || model.isReplacing)
                Picker("Subject", selection: $model.subject) {
                    Text("User").tag(MemorySubject.user)
                    Text("Workspace").tag(MemorySubject.workspace)
                }
                .disabled(model.isEditingExisting || model.isReplacing || model.scopeChoice == .global)
                Toggle("Sensitive memory", isOn: $model.sensitive)
                Toggle("Allow use in remote model requests", isOn: $model.allowsRemoteUse)
                Section("Validity") {
                    Toggle("Set valid from", isOn: $model.hasValidFrom)
                    if model.hasValidFrom { DatePicker("Valid from", selection: $model.validFrom) }
                    Toggle("Set valid until", isOn: $model.hasValidUntil)
                    if model.hasValidUntil { DatePicker("Valid until", selection: $model.validUntil) }
                }
            }
            Text(
                "Memory content is stored locally. Scope controls where it may be recalled; remote use is a separate disclosure choice."
            )
            .font(.caption).foregroundStyle(.secondary)
            if let error = model.error {
                Text(L10n.error(error, locale: locale)).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if model.receipt?.disposition == .replacementProposed {
                Text("Competing replacement created and needs review before it becomes active.")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if model.receipt?.disposition == .replacementProposed {
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button(LocalizedStringKey(model.isEditingExisting ? "Save revision" : "Save memory")) {
                        Task { await save() }
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(
                        model.saving || model.saved
                            || model.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(28).frame(width: 620)
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
        if model.isReplacing { return "Replace memory" }
        return model.isEditingExisting ? "Edit memory" : "New memory"
    }

    private func sourceNotice() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Source: committed user message").font(.caption.weight(.semibold))
            if let sourceText = model.sourceText {
                Text(verbatim: sourceText).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(4).textSelection(.enabled)
            } else {
                Text("Message body unavailable").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10).background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
    }

    private func replacementNotice() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(
                "Creates a new current memory and keeps the previous version in history. A competing replacement needs review."
            )
            .font(.caption.weight(.semibold))
            Text("The previous version remains in history.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10).background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
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
