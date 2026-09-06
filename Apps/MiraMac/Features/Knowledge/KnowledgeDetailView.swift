import SwiftUI
import MiraCore

struct KnowledgeDetailView: View {
    @Environment(\.locale) private var locale
    @Bindable var model: KnowledgeModel
    let detail: KnowledgeSourceDetail
    let workspaces: [Workspace]
    let onUpdate: () -> Void
    let onDelete: () -> Void
    @State private var allowsRemoteUse = false
    @State private var remoteUseDirty = false
    @State private var isSavingRemoteUse = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: detail.source.title).font(.title2.weight(.semibold))
                    Spacer()
                    Button("Update selected source", systemImage: "arrow.triangle.2.circlepath") { onUpdate() }
                        .disabled(detail.source.deletedAt != nil || model.isImporting)
                    Button("Delete", systemImage: "trash", role: .destructive) { onDelete() }
                        .disabled(detail.source.deletedAt != nil || model.isImporting)
                }
                scopeRow
                Text(L10n.format("Source revision %@", locale: locale, String(detail.source.revision)))
                    .font(.caption).foregroundStyle(.secondary)

                remoteUseSection
                versionSection
                chunksSection
                if let error = model.error {
                    Text(L10n.error(error, locale: locale)).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(28)
            .frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear {
            allowsRemoteUse = detail.source.allowsRemoteUse
            remoteUseDirty = false
        }
        .onChange(of: detail.source.id) { _, _ in
            allowsRemoteUse = detail.source.allowsRemoteUse
            remoteUseDirty = false
        }
        .onChange(of: detail.source.revision) { _, _ in
            if !remoteUseDirty && !isSavingRemoteUse {
                allowsRemoteUse = detail.source.allowsRemoteUse
            }
        }
    }

    private var scopeRow: some View {
        HStack(spacing: 8) {
            Text("Scope").font(.caption.weight(.semibold))
            if let workspaceID = detail.source.workspaceID, let workspace = workspaces.first(where: { $0.id == workspaceID }) {
                Text(verbatim: workspace.name)
            } else if detail.source.workspaceID == nil {
                Text("Global")
            } else {
                Text("Workspace unavailable")
            }
        }
        .foregroundStyle(.secondary)
    }

    private var remoteUseSection: some View {
        GroupBox("Model use") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Allow model use for this source", isOn: Binding(get: { allowsRemoteUse }, set: { allowsRemoteUse = $0; remoteUseDirty = true }))
                    .disabled(isSavingRemoteUse)
                Text("Sources are local-only by default. Allowing model use permits this source to be sent through an explicitly configured route when policy and workspace restrictions allow it.")
                    .font(.caption).foregroundStyle(.secondary)
                if remoteUseDirty {
                    Button("Save model-use setting") {
                        isSavingRemoteUse = true
                        Task { @MainActor in
                            let saved = await model.saveRemoteUse(allowsRemoteUse)
                            isSavingRemoteUse = false
                            if saved { remoteUseDirty = false }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSavingRemoteUse || model.isImporting)
                }
            }
        }
    }

    private var versionSection: some View {
        GroupBox("Versions") {
            if detail.versions.isEmpty {
                Text("No versions are available.").foregroundStyle(.secondary)
            } else {
                Picker("Version", selection: Binding(get: { detail.selectedVersion?.id }, set: { versionID in
                    Task { await model.selectVersion(versionID) }
                })) {
                    ForEach(detail.versions) { version in
                        Text(versionLabel(version)).tag(Optional(version.id))
                    }
                }
                .labelsHidden()
                if let version = detail.selectedVersion {
                    HStack(spacing: 12) {
                        Text(L10n.string(versionStateKey(version.parseState), locale: locale))
                        Text(L10n.format("%@ bytes", locale: locale, String(version.byteCount)))
                        Text(version.createdAt, format: .dateTime)
                    }
                    .font(.caption)
                    .foregroundStyle(version.parseState == .ready ? Color.secondary : Color.orange)
                    if let parseError = version.parseError {
                        Text(L10n.error(parseError, locale: locale)).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                if detail.versions.count == 100 {
                    Text("Showing the first 100 versions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var chunksSection: some View {
        GroupBox("Chunks") {
            if detail.chunks.isEmpty {
                Text("This version has no parsed chunks.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(detail.chunks) { chunk in
                        Button {
                            Task {
                                await model.loadChunk(chunk)
                            }
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(L10n.format("Chunk %lld", locale: locale, Int64(chunk.sequence + 1)))
                                if let heading = chunk.headingPath.last { Text(verbatim: heading).lineLimit(1) }
                                Spacer()
                                Text(L10n.format("Lines %lld–%lld", locale: locale, Int64(chunk.startLine), Int64(chunk.endLine)))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.link)
                    }
                    if detail.hasMoreChunks {
                        Text("Showing the first 200 chunks.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func versionLabel(_ version: KnowledgeSourceVersion) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return L10n.format("Version %@ · %@", locale: locale, formatter.string(from: version.createdAt),
                          version.parseState == .ready ? L10n.string("Ready", locale: locale) : L10n.string("Parse failed", locale: locale))
    }

    private func versionStateKey(_ state: KnowledgeSourceVersion.ParseState) -> String {
        state == .ready ? "Ready" : "Parse failed"
    }
}

struct SourceChunkView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let chunk: SourceChunk

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Source chunk").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let heading = chunk.summary.headingPath.last { Text(verbatim: heading).font(.headline) }
            Text(L10n.format("Lines %lld–%lld", locale: locale, Int64(chunk.summary.startLine), Int64(chunk.summary.endLine)))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(verbatim: chunk.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(width: 680, height: 540)
    }
}
