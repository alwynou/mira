import MiraCore
import SwiftUI

struct MemoryManagementView: View {
    @Bindable var model: MemoryManagementModel
    @Binding var editor: MemoryEditorDestination?
    let openSource: (SessionEvidenceReference) -> Void
    @Environment(\.locale) private var locale
    @State private var forgetting: Memory?

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 790
            VStack(spacing: 0) {
                if !compact || model.selectedID == nil { filters }
                HStack(spacing: 0) {
                    if !compact || model.selectedID == nil {
                        memoryList.frame(maxWidth: compact ? .infinity : 360)
                    }
                    if !compact { Divider() }
                    if !compact || model.selectedID != nil {
                        VStack(spacing: 0) {
                            if compact {
                                HStack {
                                    Button { model.select(nil) } label: { Label("All memories", systemImage: "chevron.left") }
                                        .buttonStyle(.plain).accessibilityIdentifier("memory.back")
                                    Spacer()
                                }
                                .padding(MiraTheme.Spacing.lg)
                                Divider()
                            }
                            selectedDetail
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(MiraTheme.Colors.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.management")
        .task { await model.observe() }
        .onChange(of: model.generation) { previous, current in
            if previous != nil && previous != current {
                editor = nil
                forgetting = nil
            }
        }
        .sheet(item: $editor) { destination in
            MemoryEditorView(
                library: model.library, workspaces: model.workspaces,
                existing: destination.existing, replacing: destination.replacing,
                initialScope: destination.scope,
                onSaved: { await model.reloadAfterEditing() })
            .environment(\.locale, locale)
        }
        .confirmationDialog("Forget this memory?", isPresented: Binding(
            get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible
        ) {
            Button("Forget memory", role: .destructive) {
                if let memory = forgetting { model.forget(memory) }
                forgetting = nil
            }
            .accessibilityIdentifier("memory.forget.confirm")
            Button("Cancel", role: .cancel) { forgetting = nil }
        } message: {
            Text("This permanently clears the memory, its source excerpts, and derived data. A record remains to prevent it from being learned again. The original conversation stays on this device. This cannot be undone.")
        }
        .alert("Operation incomplete", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.clearError() } })
        ) {
            Button("Refresh") { model.refresh() }
            Button("OK", role: .cancel) { model.clearError() }
        } message: { Text(model.error.map { L10n.error($0, locale: locale) } ?? "") }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.lg) {
            HStack {
                Text("Keep what matters.").font(MiraTheme.Typography.title)
                Spacer()
                Button { editor = .init(scope: model.creationScope) } label: { Label("Add memory", systemImage: "plus") }
                    .buttonStyle(MiraPrimaryButtonStyle()).accessibilityIdentifier("memory.add")
            }
            Text("Review what Mira remembers, where it applies, and how it may be used.")
                .font(MiraTheme.Typography.body).foregroundStyle(MiraTheme.Colors.secondaryText)
            HStack(spacing: MiraTheme.Spacing.md) {
                HStack(spacing: MiraTheme.Spacing.sm) {
                    Image(systemName: "magnifyingglass").foregroundStyle(MiraTheme.Colors.secondaryText)
                    TextField("Search memories", text: $model.searchText).textFieldStyle(.plain)
                        .accessibilityIdentifier("memory.search")
                    if !model.searchText.isEmpty {
                        Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(MiraTheme.Spacing.sm)
                .background(MiraTheme.Colors.inset, in: RoundedRectangle(cornerRadius: MiraTheme.Radius.small))
                Menu {
                    Button("All scopes") { model.scope = .all }
                    Button("Global") { model.scope = .global }
                    Divider()
                    ForEach(model.workspaces) { workspace in
                        Button(workspace.name) { model.scope = .workspace(workspace.id) }
                    }
                } label: { Text(scopeLabel).lineLimit(1) }
                .frame(maxWidth: 180).accessibilityIdentifier("memory.scope")
            }
            HStack {
                Picker("Memory list", selection: $model.section) {
                    Text("Current").tag(MemoryManagementSection.current)
                    Text("History").tag(MemoryManagementSection.history)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 220)
                .accessibilityIdentifier("memory.section")
                Spacer()
                Menu {
                    Button("Newest first") { model.order = .newestFirst }
                    Button("Oldest first") { model.order = .oldestFirst }
                } label: {
                    Label(model.order == .newestFirst ? "Newest first" : "Oldest first", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("memory.sort")
            }
        }
        .padding(MiraTheme.Spacing.xl)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var scopeLabel: String {
        switch model.scope {
        case .all: L10n.string("All scopes", locale: locale)
        case .global: L10n.string("Global", locale: locale)
        case .workspace(let id): model.workspaces.first { $0.id == id }?.name ?? L10n.string("Workspace", locale: locale)
        }
    }

    private var memoryList: some View {
        VStack(spacing: 0) {
            if model.memories.isEmpty {
                if model.isLoading {
                    ProgressView("Loading memories").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label(model.searchText.isEmpty ? "No memories yet" : "No matching memories", systemImage: "brain")
                    } description: {
                        Text(model.searchText.isEmpty
                             ? "Save a useful preference or fact, or remember something from a conversation."
                             : "Try another search or scope.")
                    } actions: {
                        if model.searchText.isEmpty && model.section == .current {
                            Button("Add memory") { editor = .init(scope: model.creationScope) }
                        }
                    }
                }
            } else {
                List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                    ForEach(model.memories) { memory in
                        MemoryManagementRow(memory: memory, workspaceName: workspaceName(memory.scope))
                            .contentShape(Rectangle())
                            .tag(memory.id)
                            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                            .accessibilityIdentifier("memory.row.\(memory.id.rawValue.uuidString)")
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .accessibilityIdentifier("memory.list")
                if model.hasMore {
                    Button("Load more") { model.loadMore() }.disabled(model.isLoading)
                        .padding(MiraTheme.Spacing.md)
                }
            }
            HStack(spacing: MiraTheme.Spacing.xs) {
                Image(systemName: "internaldrive")
                Text("Stored on this device")
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
            }
            .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
            .padding(MiraTheme.Spacing.lg)
        }
    }

    @ViewBuilder private var selectedDetail: some View {
        if let detail = model.detail {
            MemoryManagementDetail(
                detail: detail, library: model.library, workspaceName: workspaceName(detail.memory.scope),
                isWorking: model.isWorking, relatedMemories: model.relatedMemories,
                selectRelated: { model.selectRelated($0) },
                confirmReplacement: { model.confirmReplacement(candidate: $0, current: $1) }, edit: { editor = .init(existing: detail.memory) },
                replace: { editor = .init(replacing: detail.memory) },
                changeState: { model.changeState(detail.memory, to: $0) },
                forget: { forgetting = detail.memory }, openSource: openSource)
            .id(detail.memory.id)
        } else if model.isLoadingDetail {
            ProgressView("Loading memory").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Select a memory", systemImage: "text.alignleft",
                                   description: Text("Read its source and history, or update what Mira remembers."))
        }
    }

    private func workspaceName(_ scope: MemoryScope) -> String {
        guard let id = scope.workspaceID else { return L10n.string("Global", locale: locale) }
        return model.workspaces.first { $0.id == id }?.name ?? L10n.string("Workspace", locale: locale)
    }
}

struct MemoryEditorDestination: Identifiable {
    let id = UUID()
    var existing: Memory?
    var replacing: Memory?
    var scope: MemoryScope?
}

private struct MemoryManagementRow: View {
    let memory: Memory
    let workspaceName: String
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
            Text(memory.draft?.content ?? L10n.string("Forgotten memory", locale: locale))
                .font(MiraTheme.Typography.body).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(workspaceName).lineLimit(1)
                Text(verbatim: "·").accessibilityHidden(true)
                if let kind = memory.draft?.kind { Text(L10n.string(memoryManagementKindKey(kind), locale: locale)) }
                else { Text("Forgotten") }
                Spacer(minLength: 0)
                if memory.draft?.allowsRemoteUse == false {
                    Image(systemName: "lock").help("Local only")
                }
            }
            .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
            HStack {
                if memory.managementStatus(at: .now) != .current {
                    Text(L10n.string(memoryManagementStatusKey(memory.managementStatus(at: .now)), locale: locale))
                }
                Spacer(minLength: 0)
                Text(memory.updatedAt, format: .dateTime.month().day())
            }
            .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.tertiaryText)
        }
        .padding(.vertical, MiraTheme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

func memoryManagementStatusKey(_ status: MemoryManagementStatus) -> String {
    switch status {
    case .current: "Current"
    case .superseded: "Replaced"
    case .archived: "Archived"
    case .candidate: "Pending replacement"
    case .rejected: "Rejected"
    case .removed: "Removed"
    case .forgotten: "Forgotten"
    case .expired: "Expired"
    case .notYetValid: "Not yet valid"
    }
}

func memoryManagementKindKey(_ kind: MemoryKind) -> String {
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
