import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MiraCore

struct KnowledgeRootView: View {
    @Environment(\.locale) private var locale
    @State private var model: KnowledgeModel
    let workspaceID: WorkspaceID?
    let workspaces: [Workspace]
    @State private var showingDeleteConfirmation = false
    @State private var pendingDelete: KnowledgeSource?

    init(application: MiraApplication, workspaceID: WorkspaceID?, workspaces: [Workspace]) {
        _model = State(initialValue: KnowledgeModel(application: application, workspaceID: workspaceID))
        self.workspaceID = workspaceID
        self.workspaces = workspaces
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 10) {
                if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sourceList
                } else {
                    searchList
                }
                HStack {
                    Button("Import Markdown…", systemImage: "square.and.arrow.down") { chooseFiles(updating: nil) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("i", modifiers: [.command, .shift])
                    Spacer()
                    if model.isSearching { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 10)
                Text("Imports keep an immutable snapshot; Mira does not retain file access or update it automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                importResults
            }
            .padding(.top, 10)
            .navigationTitle("Knowledge")
            .searchable(text: $model.query, placement: .sidebar, prompt: "Search knowledge")
        } detail: {
            if let detail = model.selectedDetail {
                KnowledgeDetailView(model: model, detail: detail, workspaces: workspaces,
                                    onUpdate: { chooseFiles(updating: detail.source) },
                                    onDelete: {
                                        pendingDelete = detail.source
                                        showingDeleteConfirmation = true
                                    })
            } else if model.selectedID != nil {
                if let error = model.error {
                    VStack(spacing: 10) {
                        ContentUnavailableView("Source unavailable", systemImage: "exclamationmark.triangle", description: Text(L10n.error(error, locale: locale)))
                        Button("Reload source") { Task { await model.loadSelectedDetail() } }
                    }
                } else {
                    ProgressView("Loading source")
                }
            } else {
                ContentUnavailableView("Select a source", systemImage: "book.closed", description: Text("Import a Markdown file or select a source to inspect its versions and chunks."))
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task(id: workspaceID) {
            model.updateWorkspace(workspaceID)
            await model.observe()
        }
        .task(id: model.selectedID) { await model.loadSelectedDetailIfNeeded() }
        .task(id: model.searchIdentity) { await model.search() }
        .onChange(of: workspaceID) { _, _ in
            pendingDelete = nil
            showingDeleteConfirmation = false
        }
        .onChange(of: showingDeleteConfirmation) { _, showing in
            if !showing { pendingDelete = nil }
        }
        .confirmationDialog("Delete knowledge source?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            if let source = pendingDelete {
                Button(role: .destructive) {
                    Task { await model.delete(source) }
                } label: {
                    Text(L10n.format("Delete %@", locale: locale, source.title))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let source = pendingDelete {
                Text(L10n.format("This permanently removes %@, its versions and chunks, and derived source bodies. Historical body-free usage records remain. Unreferenced managed file copies may remain for at least 7 days before cleanup; existing backups are not rewritten, and the original external file is never modified.", locale: locale, source.title))
            }
        }
    }

    private var sourceList: some View {
        List(selection: Binding(get: { model.selectedID }, set: { model.selectSource($0) })) {
            ForEach(model.sources) { source in
                KnowledgeSourceRow(source: source, workspaces: workspaces)
                    .tag(source.id)
            }
            if let selected = model.selectedDetail?.source,
               !model.sources.contains(where: { $0.id == selected.id }) {
                KnowledgeSourceRow(source: selected, workspaces: workspaces)
                    .tag(selected.id)
            }
        }
        .overlay {
            if model.sources.isEmpty && !model.isLoading {
                ContentUnavailableView("No knowledge sources", systemImage: "book.closed", description: Text("Import Markdown files to make local source material available for review."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.hasMoreSources {
                Text("Showing the first 100 sources. Search can find older sources.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial)
            }
        }
    }

    private var searchList: some View {
        List {
            ForEach(model.searchHits) { hit in
                Button {
                    Task { await model.openSearchHit(hit) }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: hit.source.title).font(.headline)
                        if let heading = hit.chunk.headingPath.last { Text(verbatim: heading).font(.caption).foregroundStyle(.secondary) }
                        Text(verbatim: hit.snippet).lineLimit(3).font(.callout)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay {
            if model.searchHits.isEmpty && !model.isSearching {
                ContentUnavailableView("No matching knowledge", systemImage: "magnifyingglass", description: Text(model.searchIsTruncated ? "Search results may be incomplete. Refine your search phrase." : "Try a different search phrase."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.searchIsTruncated {
                Text(L10n.format("Search checked %lld candidates before its time limit. Refine your query.", locale: locale,
                                 Int64(model.searchScannedCandidates)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial)
            }
        }
    }

    @ViewBuilder
    private var importResults: some View {
        if model.isImporting {
            ProgressView("Importing Markdown")
                .font(.caption)
                .padding(.horizontal, 10)
        }
        if !model.importOutcomes.isEmpty {
            GroupBox("Import results") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(model.importOutcomes) { outcome in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                let failed = outcome.error != nil || outcome.receipt?.version.parseError != nil
                                Image(systemName: failed ? "xmark.circle" : "checkmark.circle")
                                    .foregroundStyle(failed ? .red : .green)
                                Text(verbatim: outcome.filename).lineLimit(1)
                                if let receipt = outcome.receipt {
                                    if let parseError = receipt.version.parseError {
                                        Text(L10n.error(parseError, locale: locale))
                                            .font(.caption).foregroundStyle(.red).lineLimit(2)
                                    } else {
                                        Text(L10n.string(receipt.reused ? "Reused existing version" : "Imported", locale: locale))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if let error = outcome.error {
                                    Text(L10n.error(error, locale: locale)).font(.caption).foregroundStyle(.red).lineLimit(2)
                                }
                            }
                        }
                    }
                    .font(.caption)
                }
                .frame(maxHeight: 120)
            }
            .padding(.horizontal, 10)
        }
        if let error = model.error {
            Text(L10n.error(error, locale: locale))
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
        }
    }

    private func chooseFiles(updating source: KnowledgeSource?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = source == nil
        panel.allowedContentTypes = [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }
        panel.message = source.map { L10n.format("Choose one Markdown file to update %@.", locale: locale, $0.title) } ?? L10n.string("Choose up to 100 Markdown files, each no larger than 10 MiB.", locale: locale)
        guard panel.runModal() == .OK else { return }
        let urls = source == nil ? panel.urls : Array(panel.urls.prefix(1))
        guard !urls.isEmpty else { return }
        Task { await model.importFiles(urls, updating: source) }
    }
}

private struct KnowledgeSourceRow: View {
    @Environment(\.locale) private var locale
    let source: KnowledgeSource
    let workspaces: [Workspace]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: source.title).font(.headline).lineLimit(2)
            HStack(spacing: 8) {
                scopeView
                Text(L10n.string(source.currentVersionID == nil ? "No current version" : "Current version available", locale: locale))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if source.allowsRemoteUse {
                Label("Model use allowed", systemImage: "arrow.up.right.circle").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var scopeView: some View {
        if let workspaceID = source.workspaceID, let workspace = workspaces.first(where: { $0.id == workspaceID }) {
            Text(verbatim: workspace.name)
        } else if source.workspaceID == nil {
            Text("Global")
        } else {
            Text("Workspace unavailable")
        }
    }
}
