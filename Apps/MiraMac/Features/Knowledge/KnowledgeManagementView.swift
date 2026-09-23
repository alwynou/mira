import AppKit
import Litext
import MarkdownView
import MiraCore
import SwiftUI

struct KnowledgeManagementView: View {
    @Bindable var model: KnowledgeManagementModel
    @Environment(\.locale) private var locale
    @FocusState private var listFocused: Bool
    @State private var permissionSource: KnowledgeSource?
    @State private var deletionSource: KnowledgeSource?

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < MiraTheme.Layout.knowledgeCompactBreakpoint
            HStack(spacing: 0) {
                if !compact || model.selectedID == nil {
                    listPane
                        .frame(width: compact ? nil : MiraTheme.Layout.knowledgeListWidth)
                        .frame(maxWidth: compact ? .infinity : nil)
                }
                if !compact { Divider() }
                if !compact || model.selectedID != nil {
                    VStack(spacing: 0) {
                        if compact { compactBackBar }
                        detailPane
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(MiraTheme.Colors.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("knowledge.management")
        .task { await model.observe() }
        .onChange(of: model.generation) { previous, current in
            guard previous != nil, previous != current else { return }
            permissionSource = nil
            deletionSource = nil
        }
        .sheet(isPresented: $model.showsImport) {
            KnowledgeImportSheet(model: model)
                .environment(\.locale, locale)
        }
        .confirmationDialog(
            t("Change model-use permission"),
            isPresented: Binding(
                get: { permissionSource != nil },
                set: { if !$0 { permissionSource = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let source = permissionSource {
                Button(source.allowsRemoteUse ? t("Revoke model use") : t("Allow model use")) {
                    if source.allowsRemoteUse { model.revoke(source) } else { model.allow(source) }
                    permissionSource = nil
                }
                .accessibilityIdentifier("knowledge.permission.confirm")
            }
            Button(t("Cancel"), role: .cancel) { permissionSource = nil }
        } message: {
            if let source = permissionSource {
                Text(source.allowsRemoteUse
                     ? t("Mira keeps this source, its versions, generated answers, and thinking, but related citations become unavailable and future model requests exclude dependent content.")
                     : t("Relevant excerpts and this source title may be sent to an authorized provider within the source scope."))
            }
        }
        .confirmationDialog(
            t("Delete this source?"),
            isPresented: Binding(
                get: { deletionSource != nil },
                set: { if !$0 { deletionSource = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(t("Delete source"), role: .destructive) {
                if let source = deletionSource { model.delete(source) }
                deletionSource = nil
            }
            .accessibilityIdentifier("knowledge.delete.confirm")
            Button(t("Cancel"), role: .cancel) { deletionSource = nil }
        } message: {
            if let source = deletionSource {
                Text(L10n.format(
                    "This permanently clears %@, all retained versions, affected generated answers and thinking. Original user messages and the original external file remain unchanged. This cannot be undone.",
                    locale: locale,
                    source.title
                ))
            }
        }
        .alert(t("Operation incomplete"), isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button(t("Refresh")) { model.clearError(); model.refresh() }
            Button(t("OK"), role: .cancel) { model.clearError() }
        } message: {
            Text(model.error.map { L10n.error($0, locale: locale) } ?? "")
        }
    }

    private func t(_ key: String) -> String { L10n.string(key, locale: locale) }

    private var listPane: some View {
        VStack(spacing: 0) {
            listTools
            listCaption
            sourceList
            listFooter
        }
    }

    private var listTools: some View {
        VStack(spacing: MiraTheme.Spacing.md) {
            HStack(spacing: MiraTheme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
                TextField(t("Search sources"), text: $model.searchText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("knowledge.management.search")
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t("Clear search"))
                }
            }
            .padding(MiraTheme.Spacing.sm)
            .background(MiraTheme.Colors.inset,
                        in: RoundedRectangle(cornerRadius: MiraTheme.Radius.small))

            HStack(spacing: MiraTheme.Spacing.md) {
                Menu {
                    Button(t("All scopes")) { model.scope = .all }
                    Button(t("Inbox")) { model.scope = .inbox }
                    if !model.workspaces.isEmpty { Divider() }
                    ForEach(model.workspaces) { workspace in
                        Button(workspace.name) { model.scope = .workspace(workspace.id) }
                    }
                } label: {
                    Text(scopeLabel).lineLimit(1)
                }
                .frame(maxWidth: MiraTheme.Layout.selectMaxWidth, alignment: .leading)
                .accessibilityIdentifier("knowledge.management.scope")

                Menu {
                    Button(t("All statuses")) { model.status = .all }
                    Button(t("Searchable")) { model.status = .searchable }
                    Button(t("Local only")) { model.status = .localOnly }
                    Button(t("Needs attention")) { model.status = .needsAttention }
                } label: {
                    Text(statusLabel).lineLimit(1)
                }
                .frame(maxWidth: MiraTheme.Layout.selectMaxWidth, alignment: .leading)
                .accessibilityIdentifier("knowledge.management.status")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, MiraTheme.Spacing.lg)
        .padding(.top, MiraTheme.Spacing.lg)
    }

    private var listCaption: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.format("Sources: %lld", locale: locale, Int64(model.items.count)))
            Spacer(minLength: MiraTheme.Spacing.md)
            Menu {
                Button(t("Newest first")) { model.order = .newestFirst }
                Button(t("Title")) { model.order = .title }
            } label: {
                Label(orderLabel, systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("knowledge.management.sort")
        }
        .font(MiraTheme.Typography.caption)
        .foregroundStyle(MiraTheme.Colors.tertiaryText)
        .padding(.horizontal, MiraTheme.Spacing.lg)
        .padding(.top, MiraTheme.Spacing.lg)
        .padding(.bottom, MiraTheme.Spacing.sm)
    }

    private var sourceList: some View {
        let hasFilters = !model.searchText.isEmpty || model.scope != .all || model.status != .all
        return Group {
            if model.items.isEmpty {
                if model.isLoading {
                    ProgressView(t("Loading sources"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label(hasFilters ? t("No matching sources") : t("No sources yet"),
                              systemImage: hasFilters ? "magnifyingglass" : "book.closed")
                    } description: {
                        Text(hasFilters
                             ? t("Try another search, scope, or status.")
                             : t("Import a Markdown file to make it available for local reading."))
                    } actions: {
                        if !hasFilters {
                            Button(t("Import Markdown")) { model.chooseImport() }
                        } else {
                            Button(t("Clear filters")) {
                                model.searchText = ""
                                model.scope = .all
                                model.status = .all
                            }
                        }
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            KnowledgeManagementRow(
                                item: item,
                                workspaceName: workspaceName(for: item.source),
                                isSelected: model.selectedID == item.id,
                                locale: locale
                            ) {
                                listFocused = true
                                model.select(item.id)
                            }
                            if index < model.items.count - 1 {
                                let nextSelected = model.selectedID == model.items[index + 1].id
                                Divider()
                                    .opacity(model.selectedID == item.id || nextSelected ? 0 : 0.6)
                                    .padding(.horizontal, MiraTheme.Spacing.lg)
                            }
                        }
                        if model.hasMore {
                            Button(t("Load more")) { model.loadMore() }
                                .disabled(model.isLoading)
                                .font(MiraTheme.Typography.caption)
                                .foregroundStyle(MiraTheme.Colors.secondaryText)
                                .buttonStyle(.plain)
                                .padding(MiraTheme.Spacing.md)
                        }
                        if model.isTruncated {
                            Text(t("Some results are unavailable until the search is narrowed."))
                                .font(MiraTheme.Typography.caption)
                                .foregroundStyle(MiraTheme.Colors.tertiaryText)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, MiraTheme.Spacing.lg)
                                .padding(.vertical, MiraTheme.Spacing.sm)
                        }
                    }
                    .padding(.horizontal, MiraTheme.Spacing.sm)
                    .padding(.bottom, MiraTheme.Spacing.sm)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .onMoveCommand(perform: moveSelection)
                .accessibilityIdentifier("knowledge.management.list")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listFooter: some View {
        HStack(spacing: MiraTheme.Spacing.xs) {
            Image(systemName: "internaldrive")
            Text(t("Stored on this device"))
            Spacer()
            if model.isWorking { ProgressView().controlSize(.small) }
        }
        .font(MiraTheme.Typography.caption)
        .foregroundStyle(MiraTheme.Colors.tertiaryText)
        .padding(.horizontal, MiraTheme.Spacing.lg)
        .padding(.vertical, MiraTheme.Spacing.md)
    }

    private var compactBackBar: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.select(nil) } label: {
                    Label(t("All sources"), systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("knowledge.management.back")
                Spacer()
            }
            .padding(MiraTheme.Spacing.lg)
            Divider()
        }
    }

    @ViewBuilder private var detailPane: some View {
        if let detail = model.detail {
            KnowledgeManagementDetail(
                detail: detail,
                document: model.document,
                selectedMatch: model.selectedMatch,
                workspaces: model.workspaces,
                isWorking: model.isWorking,
                isLoadingDocument: model.isLoadingDocument,
                onSelectVersion: model.selectVersion,
                onNextPage: model.nextDocumentPage,
                onPreviousPage: model.previousDocumentPage,
                hasPreviousPage: model.hasPreviousDocumentPage,
                chooseImport: { model.chooseImport(updating: detail.source) },
                requestPermission: { permissionSource = $0 },
                requestDelete: { deletionSource = $0 }
            )
            .id(detail.source.id)
        } else if model.isLoadingDetail {
            ProgressView(t("Loading source"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(t("Select a source"), systemImage: "doc.text",
                                   description: Text(t("Read a source, its versions, and local metadata here.")))
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let ids = model.items.map(\.id)
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
        case .all: t("All scopes")
        case .inbox: t("Inbox")
        case .workspace(let id): model.workspaces.first { $0.id == id }?.name ?? t("Workspace")
        }
    }

    private var statusLabel: String {
        switch model.status {
        case .all: t("All statuses")
        case .searchable: t("Searchable")
        case .localOnly: t("Local only")
        case .needsAttention: t("Needs attention")
        }
    }

    private var orderLabel: String {
        model.order == .newestFirst ? t("Newest first") : t("Title")
    }

    private func workspaceName(for source: KnowledgeSource) -> String {
        guard let id = source.workspaceID else { return t("Inbox") }
        return model.workspaces.first { $0.id == id }?.name ?? t("Workspace")
    }
}

private struct KnowledgeManagementRow: View {
    let item: KnowledgeManagementItem
    let workspaceName: String
    let isSelected: Bool
    let locale: Locale
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: MiraTheme.Spacing.xs) {
                    Image(systemName: "doc.text")
                    Text(verbatim: item.source.title)
                        .font(MiraTheme.Typography.body)
                        .lineLimit(2)
                }
                .foregroundStyle(MiraTheme.Colors.text)
                .frame(maxWidth: .infinity, alignment: .leading)

                if item.currentVersion == nil || item.latestVersion?.parseState == .failed {
                    Label(item.currentVersion == nil ? key("Import failed") : key("Update failed"),
                          systemImage: "exclamationmark.circle")
                        .foregroundStyle(MiraTheme.Colors.failure)
                        .lineLimit(2)
                } else {
                    Text(verbatim: item.excerpt.split(whereSeparator: \.isNewline).joined(separator: " "))
                        .lineLimit(2)
                        .foregroundStyle(MiraTheme.Colors.secondaryText)
                }

                HStack(spacing: MiraTheme.Spacing.xs) {
                    Text(verbatim: workspaceName).lineLimit(1)
                    Text(verbatim: "·").accessibilityHidden(true)
                    if !item.source.allowsRemoteUse {
                        Label(key("Local only"), systemImage: "lock")
                            .labelStyle(KnowledgeCompactLabelStyle())
                    } else {
                        Text(key("Searchable"))
                    }
                    Spacer(minLength: 0)
                    Text(item.source.updatedAt, format: .dateTime.month().day())
                }
                .font(MiraTheme.Typography.caption)
                .foregroundStyle(MiraTheme.Colors.tertiaryText)
            }
            .padding(.horizontal, MiraTheme.Spacing.md)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: MiraTheme.Radius.row, style: .continuous)
                    .fill(isSelected ? MiraTheme.Colors.inset
                          : (isHovered ? MiraTheme.Colors.inset.opacity(0.7) : .clear))
            )
            .overlay {
                if isSelected && contrast == .increased {
                    RoundedRectangle(cornerRadius: MiraTheme.Radius.row, style: .continuous)
                        .strokeBorder(MiraTheme.Colors.secondaryText, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: MiraTheme.Radius.row, style: .continuous))
        }
        .buttonStyle(KnowledgeRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("knowledge.management.row.\(item.id.rawValue.uuidString)")
        .onHover { isHovered = $0 }
    }

    private func key(_ value: String) -> String { L10n.string(value, locale: locale) }
}

private struct KnowledgeCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: MiraTheme.Spacing.xs) {
            configuration.icon
            configuration.title
        }
    }
}

private struct KnowledgeRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

struct KnowledgeImportSheet: View {
    @Bindable var model: KnowledgeManagementModel
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.lg) {
            HStack {
                Text(model.importTarget == nil ? t("Import Markdown") : t("Update source"))
                    .font(MiraTheme.Typography.title)
                Spacer()
                Button { closeImport() } label: { Image(systemName: "xmark") }
                    .buttonStyle(MiraIconButtonStyle())
                    .accessibilityLabel(t("Cancel"))
            }

            Text(model.importTarget == nil
                 ? t("Import saves a copy for local reading. It does not modify the original file or create a live link.")
                 : t("Choose a new Markdown snapshot. The source name and scope stay fixed; older versions remain available."))
                .font(MiraTheme.Typography.body)
                .foregroundStyle(MiraTheme.Colors.secondaryText)

            Text(t("UTF-8 Markdown · up to 10 MiB per file · 100 files per batch"))
                .font(MiraTheme.Typography.caption)
                .foregroundStyle(MiraTheme.Colors.tertiaryText)

            GroupBox {
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                    if model.importFiles.isEmpty {
                        Label(t("No files selected"), systemImage: "doc.badge.plus")
                            .foregroundStyle(MiraTheme.Colors.secondaryText)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                                ForEach(model.importFiles, id: \.self) { file in
                                    Label(file.lastPathComponent, systemImage: "doc.text")
                                        .lineLimit(1)
                                        .help(file.lastPathComponent)
                                }
                            }
                        }
                        .frame(height: min(CGFloat(model.importFiles.count) * 24, 120))
                    }
                    Button(t("Choose Markdown files")) { model.chooseImport(updating: model.importTarget) }
                        .buttonStyle(MiraSecondaryButtonStyle())
                        .disabled(model.isWorking)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if model.importTarget == nil {
                HStack {
                    Text(t("Save in"))
                    Spacer()
                    Menu {
                        Button(t("Inbox")) { model.importWorkspaceID = nil }
                        ForEach(model.workspaces) { workspace in
                            Button(workspace.name) { model.importWorkspaceID = workspace.id }
                        }
                    } label: {
                        Text(importScopeLabel).lineLimit(1)
                    }
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("knowledge.management.import.scope")
                }

                Toggle(t("Allow model use"), isOn: $model.importAllowsRemoteUse)
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("knowledge.management.import.permission")
                Text(t("When enabled, relevant excerpts and the source title may be sent to authorized providers within this scope."))
                    .font(MiraTheme.Typography.caption)
                    .foregroundStyle(MiraTheme.Colors.tertiaryText)
            } else {
                Label(L10n.format("Updates keep the %@ scope and existing model-use permission.", locale: locale, importScopeLabel),
                      systemImage: "lock")
                    .font(MiraTheme.Typography.caption)
                    .foregroundStyle(MiraTheme.Colors.tertiaryText)
            }

            if model.isWorking {
                HStack(spacing: MiraTheme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(L10n.format("Importing file %lld of %lld", locale: locale,
                                     Int64(min(model.importResults.count + 1, model.importFiles.count)),
                                     Int64(model.importFiles.count)))
                        .font(MiraTheme.Typography.caption)
                        .foregroundStyle(MiraTheme.Colors.secondaryText)
                }
            }

            if !model.importResults.isEmpty {
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                    Text(t("Import results"))
                        .font(MiraTheme.Typography.section.weight(.semibold))
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                            ForEach(model.importResults) { result in
                                KnowledgeImportResultRow(result: result, locale: locale)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(model.importResults.count) * 64, 150))
                    if !model.isWorking && model.importResults.count < model.importFiles.count {
                        Text(t("Stopped after the current file. The remaining files were not imported."))
                            .font(MiraTheme.Typography.caption)
                            .foregroundStyle(MiraTheme.Colors.secondaryText)
                    }
                }
            }

            HStack {
                Spacer()
                Button(model.isWorking ? t("Stop after current file") : t("Close")) {
                    closeImport()
                }
                    .buttonStyle(MiraSecondaryButtonStyle())
                Button(model.importTarget == nil ? t("Start import") : t("Save update")) {
                    model.startImport()
                }
                .buttonStyle(MiraPrimaryButtonStyle())
                .disabled(!model.canImport || model.isWorking)
                .accessibilityIdentifier("knowledge.management.import.start")
            }
            }
            .padding(MiraTheme.Spacing.xl)
        }
        .frame(minWidth: 480, idealWidth: 540, maxWidth: 640, minHeight: 420, idealHeight: 520, maxHeight: 560)
        .accessibilityIdentifier("knowledge.management.import")
    }

    private func t(_ key: String) -> String { L10n.string(key, locale: locale) }

    private var importScopeLabel: String {
        guard let id = model.importWorkspaceID else { return t("Inbox") }
        return model.workspaces.first { $0.id == id }?.name ?? t("Workspace")
    }

    private func closeImport() {
        if model.isWorking { model.cancelImport() } else { model.clearImport() }
    }
}

private struct KnowledgeImportResultRow: View {
    let result: KnowledgeImportOutcome
    let locale: Locale

    var body: some View {
        HStack(alignment: .top, spacing: MiraTheme.Spacing.sm) {
            Image(systemName: result.state == .failed ? "exclamationmark.circle" : "checkmark.circle")
                .foregroundStyle(result.state == .failed ? MiraTheme.Colors.failure : MiraTheme.Colors.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: result.filename).lineLimit(1)
                Text(stateLabel)
                    .font(MiraTheme.Typography.caption)
                    .foregroundStyle(MiraTheme.Colors.tertiaryText)
                if let error = result.error {
                    Text(L10n.error(error, locale: locale))
                        .font(MiraTheme.Typography.caption)
                        .foregroundStyle(MiraTheme.Colors.failure)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var stateLabel: String {
        switch result.state {
        case .imported:
            if result.versionFailed { return L10n.string("Imported; parsing failed, original bytes retained", locale: locale) }
            if result.error != nil { return L10n.string("Imported; model-use permission was not changed", locale: locale) }
            if result.permissionUnchanged { return L10n.string("Imported; existing permission retained", locale: locale) }
            return L10n.string("Imported", locale: locale)
        case .reused:
            return result.permissionUnchanged
                ? L10n.string("Already exists; existing permission retained", locale: locale)
                : L10n.string("Already exists", locale: locale)
        case .failed: return L10n.string("Failed", locale: locale)
        }
    }
}
