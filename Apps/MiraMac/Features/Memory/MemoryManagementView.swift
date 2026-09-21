import MiraCore
import SwiftUI

struct MemoryManagementView: View {
    @Bindable var model: MemoryManagementModel
    @Binding var editor: MemoryEditorDestination?
    let openSource: (SessionEvidenceReference) -> Void
    @Environment(\.locale) private var locale
    @State private var forgetting: Memory?
    @FocusState private var listFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < MiraTheme.Layout.memoryCompactBreakpoint
            HStack(spacing: 0) {
                if !compact || model.selectedID == nil {
                    listPane
                        .frame(width: compact ? nil : Self.listWidth(for: geometry.size.width))
                        .frame(maxWidth: compact ? .infinity : nil)
                }
                if !compact { Divider() }
                if !compact || model.selectedID != nil {
                    VStack(spacing: 0) {
                        if compact { compactBackBar }
                        selectedDetail
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private static func listWidth(for width: CGFloat) -> CGFloat {
        min(max(width * MiraTheme.Layout.memoryListProportion, MiraTheme.Layout.memoryListMin),
            MiraTheme.Layout.memoryListMax)
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            listTools
            captionRow
            memoryList
            listFooter
        }
    }

    private var listTools: some View {
        VStack(spacing: MiraTheme.Spacing.md) {
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
            HStack(spacing: MiraTheme.Spacing.md) {
                Menu {
                    Button("All scopes") { model.scope = .all }
                    Button("Global") { model.scope = .global }
                    Divider()
                    ForEach(model.workspaces) { workspace in
                        Button(workspace.name) { model.scope = .workspace(workspace.id) }
                    }
                } label: { Text(scopeLabel).lineLimit(1) }
                .frame(maxWidth: MiraTheme.Layout.selectMaxWidth)
                .accessibilityIdentifier("memory.scope")
                Spacer(minLength: 0)
                Picker("Memory list", selection: $model.section) {
                    Text("Current").tag(MemoryManagementSection.current)
                    Text("History").tag(MemoryManagementSection.history)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityIdentifier("memory.section")
            }
        }
        .padding(.horizontal, MiraTheme.Spacing.lg)
        .padding(.top, MiraTheme.Spacing.lg)
    }

    private var captionRow: some View {
        HStack {
            Text(L10n.format("Memories: %lld", locale: locale, Int64(model.memories.count)))
            Spacer(minLength: MiraTheme.Spacing.md)
            Menu {
                Button("Newest first") { model.order = .newestFirst }
                Button("Oldest first") { model.order = .oldestFirst }
            } label: {
                Label(model.order == .newestFirst ? "Newest first" : "Oldest first",
                      systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("memory.sort")
        }
        .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.tertiaryText)
        .padding(.horizontal, MiraTheme.Spacing.lg)
        .padding(.top, MiraTheme.Spacing.lg)
        .padding(.bottom, MiraTheme.Spacing.sm)
    }

    private var memoryList: some View {
        Group {
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
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.memories.enumerated()), id: \.element.id) { index, memory in
                            MemoryManagementRow(
                                memory: memory, workspaceName: workspaceName(memory.scope),
                                isSelected: model.selectedID == memory.id) {
                                    listFocused = true
                                    model.select(memory.id)
                                }
                            if index < model.memories.count - 1 {
                                let nextSelected = model.selectedID == model.memories[index + 1].id
                                let isSelected = model.selectedID == memory.id
                                Divider()
                                    .opacity(isSelected || nextSelected ? 0 : 0.6)
                                    .padding(.horizontal, MiraTheme.Spacing.lg)
                            }
                        }
                        if model.hasMore {
                            Button("Load more") { model.loadMore() }.disabled(model.isLoading)
                                .font(MiraTheme.Typography.caption)
                                .foregroundStyle(MiraTheme.Colors.secondaryText)
                                .buttonStyle(.plain)
                                .padding(MiraTheme.Spacing.md)
                        }
                    }
                    .padding(.horizontal, MiraTheme.Spacing.sm)
                    .padding(.bottom, MiraTheme.Spacing.sm)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .onMoveCommand(perform: moveSelection)
                .accessibilityIdentifier("memory.list")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listFooter: some View {
        HStack(spacing: MiraTheme.Spacing.xs) {
            Image(systemName: "internaldrive")
            Text("Stored on this device")
            Spacer()
            if model.isWorking { ProgressView().controlSize(.small) }
        }
        .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.tertiaryText)
        .padding(.horizontal, MiraTheme.Spacing.lg)
        .padding(.vertical, MiraTheme.Spacing.md)
    }

    private var compactBackBar: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.select(nil) } label: { Label("All memories", systemImage: "chevron.left") }
                    .buttonStyle(.plain).accessibilityIdentifier("memory.back")
                Spacer()
            }
            .padding(MiraTheme.Spacing.lg)
            Divider()
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

    private func moveSelection(_ direction: MoveCommandDirection) {
        let ids = model.memories.map(\.id)
        guard !ids.isEmpty else { return }
        let current = model.selectedID.flatMap { ids.firstIndex(of: $0) }
        let next: Int
        switch direction {
        case .up: next = max((current ?? ids.count) - 1, 0)
        case .down: next = min((current ?? -1) + 1, ids.count - 1)
        default: return
        }
        guard next != current else { return }
        model.select(ids[next])
    }

    private var scopeLabel: String {
        switch model.scope {
        case .all: L10n.string("All scopes", locale: locale)
        case .global: L10n.string("Global", locale: locale)
        case .workspace(let id): model.workspaces.first { $0.id == id }?.name ?? L10n.string("Workspace", locale: locale)
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
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                Text(memory.draft?.content ?? L10n.string("Forgotten memory", locale: locale))
                    .font(MiraTheme.Typography.body).lineLimit(2)
                    .foregroundStyle(MiraTheme.Colors.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(workspaceName).lineLimit(1)
                    Text(verbatim: "·").accessibilityHidden(true)
                    if let kind = memory.draft?.kind { Text(L10n.string(memoryManagementKindKey(kind), locale: locale)) }
                    else { Text("Forgotten") }
                    if memory.draft?.allowsRemoteUse == false {
                        Label("Local only", systemImage: "lock")
                            .labelStyle(MemoryPolicyLabelStyle())
                            .foregroundStyle(MiraTheme.Colors.secondaryText)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(MiraTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 4))
                    }
                    if memory.managementStatus(at: .now) != .current {
                        Text(verbatim: "·").accessibilityHidden(true)
                        Text(L10n.string(memoryManagementStatusKey(memory.managementStatus(at: .now)), locale: locale))
                    }
                    Spacer(minLength: 0)
                    Text(memory.updatedAt, format: .dateTime.month().day())
                }
                .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.tertiaryText)
            }
            .padding(.horizontal, MiraTheme.Spacing.md)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: MiraTheme.Radius.row, style: .continuous)
                    .fill(isSelected ? MiraTheme.Colors.inset : (isHovered ? MiraTheme.Colors.inset.opacity(0.7) : .clear))
            )
            .overlay {
                if isSelected && contrast == .increased {
                    RoundedRectangle(cornerRadius: MiraTheme.Radius.row, style: .continuous)
                        .strokeBorder(MiraTheme.Colors.secondaryText, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: MiraTheme.Radius.row, style: .continuous))
        }
        .buttonStyle(MemoryRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("memory.row.\(memory.id.rawValue.uuidString)")
        .onHover { isHovered = $0 }
    }
}

private struct MemoryPolicyLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

private struct MemoryRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
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
