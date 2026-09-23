import AppKit
import Litext
import MarkdownView
import MiraCore
import SwiftUI

struct KnowledgeManagementDetail: View {
    let detail: KnowledgeSourceDetail
    let document: KnowledgeDocumentPage?
    let selectedMatch: SourceChunkSummary?
    let workspaces: [Workspace]
    let isWorking: Bool
    let isLoadingDocument: Bool
    let onSelectVersion: (SourceVersionID) -> Void
    let onNextPage: () -> Void
    let onPreviousPage: () -> Void
    let hasPreviousPage: Bool
    let chooseImport: () -> Void
    let requestPermission: (KnowledgeSource) -> Void
    let requestDelete: (KnowledgeSource) -> Void
    @Environment(\.locale) private var locale
    @State private var tab: KnowledgeDetailTab = .document
    @State private var showsRaw = false

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
                    header
                    if let selectedVersion = detail.selectedVersion {
                        statusBanner(for: selectedVersion)
                    }
                    if let latestFailedVersion, latestFailedVersion.id != detail.selectedVersion?.id {
                        latestFailureNotice(latestFailedVersion)
                    }
                    tabBar
                    tabContent
                }
                .padding(MiraTheme.Spacing.xl)
                .frame(maxWidth: MiraTheme.Layout.knowledgeReaderContentMax, alignment: .leading)
                .frame(maxWidth: .infinity)
                .id("knowledge.document.top")
            }
            .onChange(of: documentToken) { _, _ in
                reader.scrollTo("knowledge.document.top", anchor: .top)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("knowledge.management.detail")
        .onChange(of: detail.source.id) { _, _ in
            tab = .document
            showsRaw = false
        }
    }

    private var documentToken: SourceChunkID? { document?.chunks.first?.id }

    private var header: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
            HStack(alignment: .top, spacing: MiraTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                    Text(verbatim: detail.source.title)
                        .font(MiraTheme.Typography.title)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("knowledge.management.title")
                    HStack(spacing: MiraTheme.Spacing.xs) {
                        Image(systemName: detail.source.workspaceID == nil ? "tray" : "folder")
                        Text(scopeName)
                        Text(verbatim: "·").accessibilityHidden(true)
                        Text(L10n.string("Markdown snapshot", locale: locale))
                    }
                    .font(MiraTheme.Typography.caption)
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
                }
                Spacer(minLength: MiraTheme.Spacing.md)
                permissionButton
                Menu {
                    Button { chooseImport() } label: {
                        Label(L10n.string("Update source", locale: locale), systemImage: "arrow.up.doc")
                    }
                    Button { requestPermission(detail.source) } label: {
                        Label(permissionLabel, systemImage: detail.source.allowsRemoteUse ? "lock" : "checkmark")
                    }
                    Divider()
                    Button(role: .destructive) { requestDelete(detail.source) } label: {
                        Label(L10n.string("Delete source", locale: locale), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: MiraTheme.Layout.controlHeight, height: MiraTheme.Layout.controlHeight)
                }
                .menuStyle(.borderlessButton)
                .disabled(isWorking)
                .accessibilityLabel(L10n.string("More source actions", locale: locale))
                .accessibilityIdentifier("knowledge.management.more")
            }

            HStack(spacing: MiraTheme.Spacing.sm) {
                Label(L10n.string("Original filename", locale: locale), systemImage: "doc.text")
                Text(verbatim: detail.source.title)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                if let version = detail.selectedVersion {
                    Text(byteCount(version.byteCount))
                        .foregroundStyle(MiraTheme.Colors.tertiaryText)
                }
            }
            .font(MiraTheme.Typography.caption)
            .foregroundStyle(MiraTheme.Colors.secondaryText)
        }
    }

    private var permissionButton: some View {
        Button { requestPermission(detail.source) } label: {
            Label(permissionLabel, systemImage: detail.source.allowsRemoteUse ? "checkmark" : "lock")
        }
        .buttonStyle(MiraSecondaryButtonStyle())
        .disabled(isWorking)
        .accessibilityIdentifier("knowledge.management.permission")
    }

    private var permissionLabel: String {
        L10n.string(detail.source.allowsRemoteUse ? "Model use allowed" : "Local only", locale: locale)
    }

    private var scopeName: String {
        guard let id = detail.source.workspaceID else { return L10n.string("Inbox", locale: locale) }
        return workspaces.first { $0.id == id }?.name ?? L10n.string("Workspace", locale: locale)
    }

    private func statusBanner(for version: KnowledgeSourceVersion) -> some View {
        HStack(alignment: .top, spacing: MiraTheme.Spacing.sm) {
            Image(systemName: version.parseState == .failed ? "exclamationmark.circle" :
                    (version.id == detail.source.currentVersionID ? "checkmark.circle" : "clock"))
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
                Text(statusTitle(for: version)).font(MiraTheme.Typography.section.weight(.semibold))
                if version.parseState == .failed {
                    Text(L10n.string("This version could not be parsed. The previous successful version remains available.", locale: locale))
                } else if version.id != detail.source.currentVersionID {
                    Text(L10n.string("You are reading a historical version. Search and future requests use the current version.", locale: locale))
                }
            }
            .foregroundStyle(version.parseState == .failed ? MiraTheme.Colors.failure : MiraTheme.Colors.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(MiraTheme.Spacing.md)
        .background(MiraTheme.Colors.inset, in: RoundedRectangle(cornerRadius: MiraTheme.Radius.row))
    }

    private func statusTitle(for version: KnowledgeSourceVersion) -> String {
        if version.parseState == .failed {
            return version.id == detail.source.currentVersionID
                ? L10n.string("Current version failed", locale: locale)
                : L10n.string("Failed version", locale: locale)
        }
        return version.id == detail.source.currentVersionID
            ? L10n.string("Current version", locale: locale)
            : L10n.string("Historical version", locale: locale)
    }

    private var tabBar: some View {
        HStack(spacing: MiraTheme.Spacing.md) {
            Picker(L10n.string("Source view", locale: locale), selection: $tab) {
                Text(L10n.string("Document", locale: locale)).tag(KnowledgeDetailTab.document)
                Text(L10n.string("Versions", locale: locale)).tag(KnowledgeDetailTab.versions)
                Text(L10n.string("Source info", locale: locale)).tag(KnowledgeDetailTab.info)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("knowledge.management.tabs")
            Spacer(minLength: MiraTheme.Spacing.md)
            if tab == .document, let selectedVersion = detail.selectedVersion,
               selectedVersion.parseState == .ready {
                Button {
                    showsRaw.toggle()
                } label: {
                    Label(showsRaw ? L10n.string("Read preview", locale: locale) :
                            L10n.string("Read original", locale: locale),
                          systemImage: showsRaw ? "book.closed" : "text.alignleft")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("knowledge.management.document")
            }
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .document: documentContent
        case .versions: versionsContent
        case .info: infoContent
        }
    }

    @ViewBuilder private var documentContent: some View {
        if detail.selectedVersion == nil, let failed = detail.versions.first(where: { $0.parseState == .failed }) {
            failureContent(for: failed, initial: true)
        } else if let version = detail.selectedVersion, version.parseState == .failed {
            failureContent(for: version, initial: false)
        } else if isLoadingDocument {
            ProgressView(L10n.string("Loading document", locale: locale))
                .frame(maxWidth: .infinity, minHeight: 180)
        } else if let document {
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.lg) {
                if let selectedMatch {
                    Text(L10n.format("Search match · lines %lld–%lld", locale: locale,
                                     Int64(selectedMatch.startLine), Int64(selectedMatch.endLine)))
                        .font(MiraTheme.Typography.caption)
                        .foregroundStyle(MiraTheme.Colors.secondaryText)
                }
                if showsRaw {
                    ForEach(document.chunks) { chunk in
                        KnowledgeRawChunkView(chunk: chunk, isMatch: selectedMatch?.id == chunk.id)
                    }
                } else {
                    KnowledgeMarkdownChunkView(source: document.chunks.map(\.text).joined(separator: "\n"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, MiraTheme.Spacing.xs)
                }
                HStack {
                    if hasPreviousPage {
                        Button { onPreviousPage() } label: {
                            Label(L10n.string("Previous", locale: locale), systemImage: "chevron.left")
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    if document.nextSequence != nil {
                        Button { onNextPage() } label: {
                            Label(L10n.string("Load more", locale: locale), systemImage: "chevron.down")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(MiraTheme.Typography.caption)
                .foregroundStyle(MiraTheme.Colors.secondaryText)
            }
            .accessibilityIdentifier("knowledge.management.document")
        } else {
            ContentUnavailableView(L10n.string("Document unavailable", locale: locale),
                                   systemImage: "doc.text",
                                   description: Text(L10n.string("Select a readable version to open its content.", locale: locale)))
        }
    }

    private func failureContent(for version: KnowledgeSourceVersion, initial: Bool) -> some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
            Label(initial ? L10n.string("Import failed", locale: locale) : L10n.string("This version is unavailable", locale: locale),
                  systemImage: "exclamationmark.circle")
                .font(MiraTheme.Typography.section.weight(.semibold))
                .foregroundStyle(MiraTheme.Colors.failure)
            Text(initial
                 ? L10n.string("The source has no readable current version. Select Versions to inspect the retained failed attempt.", locale: locale)
                 : L10n.string("The previous successful version remains available.", locale: locale))
                .font(MiraTheme.Typography.body)
                .foregroundStyle(MiraTheme.Colors.secondaryText)
            if let error = version.parseError {
                Text(L10n.error(error, locale: locale))
                    .font(MiraTheme.Typography.caption)
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
            }
            if let current = detail.source.currentVersionID, !initial {
                Button(L10n.string("View current version", locale: locale)) { onSelectVersion(current) }
                    .buttonStyle(MiraSecondaryButtonStyle())
            }
        }
        .padding(MiraTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MiraTheme.Colors.inset, in: RoundedRectangle(cornerRadius: MiraTheme.Radius.row))
    }

    private func latestFailureNotice(_ version: KnowledgeSourceVersion) -> some View {
        HStack(alignment: .top, spacing: MiraTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.circle")
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
                Text(L10n.string("Latest update failed", locale: locale))
                    .font(MiraTheme.Typography.section.weight(.semibold))
                Text(L10n.string("The previous current version remains readable. Open Versions to inspect the failed update.", locale: locale))
            }
            Spacer(minLength: 0)
            Button(L10n.string("Versions", locale: locale)) { tab = .versions }
                .buttonStyle(.plain)
        }
        .font(MiraTheme.Typography.caption)
        .foregroundStyle(MiraTheme.Colors.failure)
        .padding(MiraTheme.Spacing.md)
        .background(MiraTheme.Colors.inset, in: RoundedRectangle(cornerRadius: MiraTheme.Radius.row))
    }

    private var latestFailedVersion: KnowledgeSourceVersion? {
        guard let latest = detail.versions.first, latest.parseState == .failed else { return nil }
        return latest
    }

    private var versionsContent: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
            Text(L10n.string("Every import is retained as a local snapshot. Selecting a version opens that exact revision.", locale: locale))
                .font(MiraTheme.Typography.caption)
                .foregroundStyle(MiraTheme.Colors.secondaryText)
            ForEach(detail.versions) { version in
                Button { onSelectVersion(version.id) } label: {
                    HStack(alignment: .top, spacing: MiraTheme.Spacing.md) {
                        Image(systemName: version.parseState == .failed ? "exclamationmark.circle" : "clock")
                            .foregroundStyle(version.parseState == .failed ? MiraTheme.Colors.failure : MiraTheme.Colors.secondaryText)
                        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
                            HStack {
                                Text(versionTitle(version))
                                    .font(MiraTheme.Typography.body.weight(.semibold))
                                if version.id == detail.source.currentVersionID {
                                    Text(L10n.string("Current", locale: locale))
                                        .font(MiraTheme.Typography.caption)
                                        .padding(.horizontal, MiraTheme.Spacing.xs)
                                        .padding(.vertical, 2)
                                        .background(MiraTheme.Colors.surface, in: Capsule())
                                }
                                Spacer(minLength: MiraTheme.Spacing.sm)
                            }
                            Text(version.createdAt.formatted(.dateTime.year().month().day().hour().minute().locale(locale)))
                            Text(version.parseState == .failed
                                 ? L10n.string("Parsing failed; local bytes are retained.", locale: locale)
                                 : byteCount(version.byteCount))
                        }
                        .foregroundStyle(MiraTheme.Colors.text)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(MiraTheme.Colors.tertiaryText)
                    }
                    .padding(MiraTheme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MiraTheme.Colors.inset, in: RoundedRectangle(cornerRadius: MiraTheme.Radius.row))
                }
                .buttonStyle(.plain)
            }
            if detail.versions.isEmpty {
                Text(L10n.string("No versions are available.", locale: locale))
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
            }
            if detail.hasMoreVersions {
                Text(L10n.string("Showing the latest 100 versions. Older versions remain available to existing citations.", locale: locale))
                    .font(MiraTheme.Typography.caption)
                    .foregroundStyle(MiraTheme.Colors.tertiaryText)
            }
        }
        .accessibilityIdentifier("knowledge.management.versions")
    }

    private var infoContent: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
            metadataRow(L10n.string("Title", locale: locale), value: detail.source.title)
            metadataRow(L10n.string("Original filename", locale: locale), value: detail.source.title)
            metadataRow(L10n.string("Scope", locale: locale), value: scopeName)
            metadataRow(L10n.string("Permission", locale: locale), value: permissionLabel)
            metadataRow(L10n.string("Versions", locale: locale), value: detail.hasMoreVersions ? "100+" : String(detail.versions.count))
            metadataRow(L10n.string("Created", locale: locale), value: detail.source.createdAt.formatted(.dateTime.year().month().day().hour().minute().locale(locale)))
            metadataRow(L10n.string("Updated", locale: locale), value: detail.source.updatedAt.formatted(.dateTime.year().month().day().hour().minute().locale(locale)))
            Text(L10n.string("Mira stores a local copy. The original file is never modified and is not linked for live updates.", locale: locale))
                .font(MiraTheme.Typography.caption)
                .foregroundStyle(MiraTheme.Colors.tertiaryText)
                .padding(.top, MiraTheme.Spacing.sm)
            Divider().padding(.vertical, MiraTheme.Spacing.md)
            HStack {
                Button { chooseImport() } label: {
                    Label(L10n.string("Update source", locale: locale), systemImage: "arrow.up.doc")
                }
                .buttonStyle(MiraSecondaryButtonStyle())
                .disabled(isWorking)
                Spacer()
                Button(role: .destructive) { requestDelete(detail.source) } label: {
                    Label(L10n.string("Delete source", locale: locale), systemImage: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(MiraTheme.Colors.failure)
                .disabled(isWorking)
                .accessibilityIdentifier("knowledge.management.delete")
            }
        }
        .accessibilityIdentifier("knowledge.management.info")
    }

    private func metadataRow(_ key: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: key)
                .foregroundStyle(MiraTheme.Colors.tertiaryText)
                .frame(width: MiraTheme.Layout.memoryMetadataLabelWidth, alignment: .leading)
            Text(verbatim: value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(MiraTheme.Typography.caption)
    }

    private func versionTitle(_ version: KnowledgeSourceVersion) -> String {
        let date = version.createdAt.formatted(.dateTime.year().month().day().hour().minute().locale(locale))
        return L10n.format("Version %@", locale: locale, date)
    }

    private func byteCount(_ count: Int) -> String {
        Int64(count).formatted(.byteCount(style: .file).locale(locale))
    }
}

private enum KnowledgeDetailTab: String, CaseIterable {
    case document
    case versions
    case info
}

private struct KnowledgeRawChunkView: View {
    let chunk: SourceChunk
    let isMatch: Bool

    var body: some View {
        let normalized = chunk.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(chunk.summary.endLine - chunk.summary.startLine + 1)
            .enumerated()
            .map { KnowledgeRawLine(id: "\(chunk.id.rawValue.uuidString)-\($0.offset)", number: chunk.summary.startLine + $0.offset, text: String($0.element)) }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                HStack(alignment: .top, spacing: MiraTheme.Spacing.md) {
                    Text(verbatim: String(line.number))
                        .frame(width: 42, alignment: .trailing)
                        .foregroundStyle(MiraTheme.Colors.tertiaryText)
                    Text(verbatim: line.text.isEmpty ? " " : line.text)
                        .foregroundStyle(MiraTheme.Colors.text)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
                .background(isMatch ? MiraTheme.Colors.selected.opacity(0.55) : .clear)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(MiraTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MiraTheme.Colors.inset, in: RoundedRectangle(cornerRadius: MiraTheme.Radius.row))
        .overlay {
            if isMatch {
                RoundedRectangle(cornerRadius: MiraTheme.Radius.row)
                    .strokeBorder(MiraTheme.Colors.secondaryText, lineWidth: 1)
            }
        }
    }
}

private struct KnowledgeRawLine: Identifiable {
    let id: String
    let number: Int
    let text: String
}

private struct KnowledgeMarkdownChunkView: NSViewRepresentable {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    func makeNSView(context: Context) -> MiraMarkdownView { MiraMarkdownView() }

    func updateNSView(_ view: MiraMarkdownView, context: Context) {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!
        view.appearance = appearance
        let theme = MiraMarkdownStyle.theme(for: appearance)
        view.apply(content: MarkdownContent(markdown: source, theme: theme, locale: locale),
                   source: source, theme: theme, locale: locale,
                   isStreaming: false, reduceMotion: true)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MiraMarkdownView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: view.fittingHeight(width: width))
    }
}
