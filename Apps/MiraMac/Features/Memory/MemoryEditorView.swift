import SwiftUI
import MiraCore

struct MemoryEditorView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    let application: MiraApplication
    let workspaces: [Workspace]
    let initialScope: MemoryScope
    let existing: Memory?
    let sourceMessage: Message?
    let replacing: Memory?
    let onSaved: () async -> Void

    @State private var scopeChoice: MemoryScopeChoice
    @State private var subject: MemorySubject
    @State private var kind: MemoryKind
    @State private var content: String
    @State private var evidenceExcerpt: String
    @State private var sensitive: Bool
    @State private var allowsRemoteUse: Bool
    @State private var hasValidFrom: Bool
    @State private var hasValidUntil: Bool
    @State private var validFrom: Date
    @State private var validUntil: Date
    @State private var error: MiraError?
    @State private var saving = false
    @State private var receipt: MemoryWriteDisposition?
    @State private var operationID = UUID()
    @State private var manualSourceStatement: String?

    init(application: MiraApplication, workspaces: [Workspace], initialScope: MemoryScope, existing: Memory? = nil, sourceMessage: Message? = nil, replacing: Memory? = nil, onSaved: @escaping () async -> Void) {
        self.application = application; self.workspaces = workspaces; self.initialScope = initialScope
        self.existing = existing; self.sourceMessage = sourceMessage; self.replacing = replacing; self.onSaved = onSaved
        let sourceContent = sourceMessage?.text ?? replacing?.draft?.content ?? existing?.draft?.content ?? ""
        let sourceDraft = existing?.draft ?? replacing?.draft
        _scopeChoice = State(initialValue: MemoryScopeChoice(scope: existing?.scope ?? replacing?.scope ?? initialScope))
        _subject = State(initialValue: sourceDraft?.subject ?? existing?.subject ?? replacing?.subject ?? .user)
        _kind = State(initialValue: sourceDraft?.kind ?? .fact)
        _content = State(initialValue: sourceContent)
        _evidenceExcerpt = State(initialValue: Self.boundedExcerpt(sourceMessage?.text ?? ""))
        _sensitive = State(initialValue: sourceDraft?.sensitivity == .sensitive)
        _allowsRemoteUse = State(initialValue: sourceDraft?.allowsRemoteUse ?? true)
        _hasValidFrom = State(initialValue: sourceDraft?.validFrom != nil)
        _hasValidUntil = State(initialValue: sourceDraft?.validUntil != nil)
        _validFrom = State(initialValue: sourceDraft?.validFrom ?? .now)
        _validUntil = State(initialValue: sourceDraft?.validUntil ?? .now.addingTimeInterval(86_400))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(titleKey).font(.title2.weight(.semibold))
            if let sourceMessage { sourceNotice(sourceMessage) }
            if let replacing { replacementNotice(replacing) }
            Form {
                if sourceMessage != nil {
                    TextField("Evidence excerpt", text: $evidenceExcerpt, axis: .vertical).lineLimit(2...5)
                    Text("Keep an exact excerpt from the original message, up to 8 KiB.").font(.caption).foregroundStyle(.secondary)
                }
                TextField("Memory", text: $content, axis: .vertical)
                    .lineLimit(4...12)
                    .textFieldStyle(.roundedBorder)
                Picker("Kind", selection: $kind) {
                    ForEach(MemoryKind.allCases, id: \.self) { kind in Text(L10n.string(memoryKindKey(kind), locale: locale)).tag(kind) }
                }
                Picker("Scope", selection: $scopeChoice) {
                    Text("Global").tag(MemoryScopeChoice.global)
                    ForEach(workspaces) { workspace in Text(verbatim: workspace.name).tag(MemoryScopeChoice.workspace(workspace.id)) }
                }
                .disabled(existing != nil || replacing != nil)
        Picker("Subject", selection: $subject) {
                    Text("User").tag(MemorySubject.user)
                    Text("Workspace").tag(MemorySubject.workspace)
                }
                .disabled(existing != nil || replacing != nil || scopeChoice == .global)
                Toggle("Sensitive memory", isOn: $sensitive)
                Toggle("Allow use in remote model requests", isOn: $allowsRemoteUse)
                Section("Validity") {
                    Toggle("Set valid from", isOn: $hasValidFrom)
                    if hasValidFrom { DatePicker("Valid from", selection: $validFrom) }
                    Toggle("Set valid until", isOn: $hasValidUntil)
                    if hasValidUntil { DatePicker("Valid until", selection: $validUntil) }
                }
            }
            Text("Memory content is stored locally. Scope controls where it may be recalled; remote use is a separate disclosure choice.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(L10n.error(error, locale: locale)).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if receipt == .replacementProposed {
                Text("Competing replacement created and needs review before it becomes active.").font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if receipt == .replacementProposed {
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button(LocalizedStringKey(existing == nil ? "Save memory" : "Save revision")) { Task { await save() } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(28)
        .frame(width: 620)
        .onChange(of: sensitive) { _, isSensitive in if isSensitive { allowsRemoteUse = false } }
        .onChange(of: scopeChoice) { _, newScope in if newScope == .global { subject = .user } }
    }

    private var titleKey: LocalizedStringKey {
        if replacing != nil { return "Replace memory" }
        return existing == nil ? "New memory" : "Edit memory"
    }
    private func sourceNotice(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Source: committed user message").font(.caption.weight(.semibold))
            Text(verbatim: message.text).font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
        }
        .padding(10).background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
    }
    private func replacementNotice(_ memory: Memory) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Creates a new current memory and keeps the previous version in history. A competing replacement needs review.").font(.caption.weight(.semibold))
            if let content = memory.draft?.content {
                Text(verbatim: content).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            } else {
                Text("Memory body unavailable").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10).background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
    }

    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        do {
            let draft = MemoryDraft(content: content, scope: scopeChoice.scope, subject: subject, kind: kind,
                                    sensitivity: sensitive ? .sensitive : .standard, allowsRemoteUse: allowsRemoteUse,
                                    allowedConnectionIDs: existing?.draft?.allowedConnectionIDs ?? replacing?.draft?.allowedConnectionIDs,
                                    validFrom: hasValidFrom ? validFrom : nil, validUntil: hasValidUntil ? validUntil : nil)
            try draft.validate()
            if let existing {
                _ = try await application.reviseMemory(existing.id, workspaceID: existing.scope.workspaceID, draft: draft, expectedRevision: existing.revision)
                await onSaved(); dismiss()
            } else {
                if let sourceMessage {
                    guard sourceMessage.role == .user, sourceMessage.status == .committed else {
                        throw MiraError(.invalidInput, "Only a committed user message can be used as memory evidence.")
                    }
                }
                let source: MemorySourceInput
                if let sourceMessage {
                    guard !evidenceExcerpt.isEmpty, sourceMessage.text.contains(evidenceExcerpt), evidenceExcerpt.utf8.count <= 8_192 else {
                        throw MiraError(.invalidInput, "Memory evidence must be an exact excerpt of at most 8 KiB from the original message.")
                    }
                    source = .message(id: sourceMessage.id, excerpt: evidenceExcerpt)
                }
                else {
                    let statement = manualSourceStatement ?? content
                    manualSourceStatement = statement
                    source = .manualEntry(id: operationID, statement: statement)
                }
                let receipt = try await application.createMemory(draft: draft, source: source, operationID: operationID,
                                                                  replacing: replacing?.id, expectedRevision: replacing?.revision)
                await onSaved()
                if receipt.disposition == .replacementProposed { self.receipt = receipt.disposition }
                else { dismiss() }
            }
        } catch { self.error = MiraError.safe(error) }
    }
    private static func boundedExcerpt(_ text: String) -> String {
        var value = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            guard bytes + size <= 8_192 else { break }
            value.append(character); bytes += size
        }
        return value
    }
}

private enum MemoryScopeChoice: Hashable {
    case global
    case workspace(WorkspaceID)
    init(scope: MemoryScope) { if let id = scope.workspaceID { self = .workspace(id) } else { self = .global } }
    var scope: MemoryScope { switch self { case .global: .global; case .workspace(let id): .workspace(id) } }
}

private func memoryKindKey(_ kind: MemoryKind) -> String {
    switch kind { case .fact: "Fact"; case .preference: "Preference"; case .decision: "Decision"; case .goal: "Goal"; case .constraint: "Constraint"; case .procedure: "Procedure"; case .learning: "Learning"; case .context: "Context" }
}
