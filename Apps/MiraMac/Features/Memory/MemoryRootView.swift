import SwiftUI
import MiraCore

struct MemoryRootView: View {
    @Environment(\.locale) private var locale
    @State private var model: MemoryModel
    @State private var editorRequest: MemoryEditorRequest?
    let workspaceID: WorkspaceID?
    let workspaces: [Workspace]
    let initialMemoryID: MemoryID?
    let onOpenConversation: (ConversationID) -> Void

    init(application: MiraApplication, workspaceID: WorkspaceID?, workspaces: [Workspace], initialMemoryID: MemoryID? = nil, onOpenConversation: @escaping (ConversationID) -> Void) {
        _model = State(initialValue: MemoryModel(application: application, workspaceID: workspaceID))
        self.workspaceID = workspaceID
        self.workspaces = workspaces
        self.initialMemoryID = initialMemoryID
        self.onOpenConversation = onOpenConversation
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            VStack(spacing: 10) {
                Picker("Memory state", selection: $model.filter) {
                    ForEach(MemoryListFilter.allCases) { filter in Text(L10n.string(filter.titleKey, locale: locale)).tag(filter) }
                }
                .labelsHidden()
                .accessibilityLabel("Memory state")
                List(selection: $model.selectedID) {
                    ForEach(model.memories) { memory in
                        MemoryListRow(memory: memory, workspaces: workspaces)
                            .tag(memory.id)
                    }
                    if let selected = model.selectedDetail?.memory,
                       !model.memories.contains(where: { $0.id == selected.id }) {
                        MemoryListRow(memory: selected, workspaces: workspaces)
                            .tag(selected.id)
                    }
                }
                .overlay {
                    if model.memories.isEmpty && model.selectedDetail == nil && !model.isLoading {
                        ContentUnavailableView("No memories", systemImage: "brain", description: Text("Create a memory from a committed user message or add one manually."))
                    }
                }
                if model.listWasTruncated { Text("Showing the first 100 results. Refine your search to see more.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8) }
                Button("New memory", systemImage: "plus") {
                    editorRequest = MemoryEditorRequest(scope: model.workspaceID.map(MemoryScope.workspace) ?? .global)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .padding(.bottom, 6)
            }
            .padding(.top, 12)
            .navigationTitle("Memory")
            .searchable(text: $model.query, placement: .sidebar, prompt: "Search memories")
        } detail: {
            if let detail = model.selectedDetail {
                MemoryDetailPane(detail: detail, workspaces: workspaces, application: model.application, workspaceID: model.workspaceID,
                                 onEdit: { editorRequest = MemoryEditorRequest(scope: detail.memory.scope, existing: $0) },
                                 onReplace: { editorRequest = MemoryEditorRequest(scope: $0.scope, replacing: $0) },
                                 onOpenConversation: onOpenConversation,
                                 onChanged: { await model.refreshAfterMutation() })
                    .id(detail.memory.id)
            } else if model.selectedID != nil {
                ProgressView("Loading memory")
            } else {
                ContentUnavailableView("Select a memory", systemImage: "brain", description: Text("Review its content, evidence, and lifecycle here."))
            }
        }
        .frame(minWidth: 850, minHeight: 580)
        .task { await model.observe() }
        .task(id: model.searchIdentity) { await model.reload() }
        .task(id: model.selectedID) { await model.loadSelectedDetail() }
        .onAppear { model.selectInitialMemory(initialMemoryID) }
        .onChange(of: initialMemoryID) { _, newMemoryID in
            model.selectInitialMemory(newMemoryID)
        }
        .onChange(of: workspaceID) { _, newWorkspaceID in
            model.updateWorkspace(newWorkspaceID)
        }
        .sheet(item: $editorRequest) { request in
            MemoryEditorView(application: model.application, workspaces: workspaces, initialScope: request.scope,
                             existing: request.existing, sourceMessage: request.sourceMessage, replacing: request.replacing,
                             onSaved: { await model.refreshAfterMutation() })
                .environment(\.locale, locale)
        }
        .alert("Memory operation incomplete", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(verbatim: model.error.map { L10n.error($0, locale: locale) } ?? "")
        }
    }
}

private struct MemoryEditorRequest: Identifiable {
    let id = UUID()
    let scope: MemoryScope
    let existing: Memory?
    let sourceMessage: Message?
    let replacing: Memory?
    init(scope: MemoryScope, existing: Memory? = nil, sourceMessage: Message? = nil, replacing: Memory? = nil) {
        self.scope = scope; self.existing = existing; self.sourceMessage = sourceMessage; self.replacing = replacing
    }
}

private struct MemoryListRow: View {
    @Environment(\.locale) private var locale
    let memory: Memory
    let workspaces: [Workspace]

    private var lifecycleStatus: MemoryLifecycleStatus {
        memory.lifecycleStatus(at: .now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                memoryContentView(memory).font(.headline).lineLimit(3)
                Spacer(minLength: 8)
                Text(L10n.string(memoryLifecycleStatusKey(lifecycleStatus), locale: locale))
                    .font(.caption)
                    .foregroundStyle(lifecycleStatus == .active ? .green : .secondary)
            }
            HStack(spacing: 8) {
                Text(L10n.string(memoryKindKey(memory.draft?.kind ?? .context), locale: locale))
                scopeView(memory.scope)
                Text(memory.updatedAt, format: .dateTime.month(.abbreviated).day())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Memory")
        .accessibilityValue(Text(verbatim: accessibilitySummary))
    }

    private var accessibilitySummary: String {
        [memory.draft?.content ?? L10n.string("Memory body unavailable", locale: locale), L10n.string(memoryLifecycleStatusKey(lifecycleStatus), locale: locale), L10n.string(memoryKindKey(memory.draft?.kind ?? .context), locale: locale)].joined(separator: ", ")
    }
    @ViewBuilder private func memoryContentView(_ memory: Memory) -> some View {
        if let content = memory.draft?.content { Text(verbatim: content) }
        else { Text("Memory body unavailable") }
    }
    @ViewBuilder private func scopeView(_ scope: MemoryScope) -> some View {
        switch scope {
        case .global: Text("Global")
        case .workspace(let id):
            if let name = workspaces.first(where: { $0.id == id })?.name { Text(verbatim: name) }
            else { Text("Workspace") }
        }
    }
}

private func memoryLifecycleStatusKey(_ status: MemoryLifecycleStatus) -> String {
    switch status {
    case .active: "Active"
    case .candidate: "Needs review"
    case .archived: "Archived"
    case .rejected: "Rejected"
    case .removed: "Removed"
    case .forgotten: "Forgotten"
    case .superseded: "Superseded"
    case .expired: "Expired"
    case .notYetValid: "Not yet valid"
    }
}
private func memoryKindKey(_ kind: MemoryKind) -> String {
    switch kind { case .fact: "Fact"; case .preference: "Preference"; case .decision: "Decision"; case .goal: "Goal"; case .constraint: "Constraint"; case .procedure: "Procedure"; case .learning: "Learning"; case .context: "Context" }
}
