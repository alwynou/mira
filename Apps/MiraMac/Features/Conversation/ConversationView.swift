import AppKit
import MiraCore
import SwiftUI

struct ConversationRoot: View {
    @Environment(\.locale) private var locale
    @Environment(\.openWindow) private var openWindow
    @State private var model: ConversationModel
    @State private var showsWorkspaceSheet = false
    @State private var editingWorkspace: Workspace?
    @State private var showsInspector = false
    @Environment(\.scenePhase) private var scenePhase
    let isDemo: Bool

    init(library: MacLibrary, isDemo: Bool) {
        _model = State(initialValue: ConversationModel(library: library))
        self.isDemo = isDemo
    }

    var body: some View {
        windowShell
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .modifier(ConversationTitleVisibility())
            .navigationTitle(displayedConversationTitle)
            .tint(MiraTheme.Colors.accent)
            .foregroundStyle(MiraTheme.Colors.text)
            .frame(minWidth: 850, minHeight: 620)
            .task { await model.observe() }
            .task {
                #if DEBUG
                    await NativePerformanceBenchmark.run(model: model)
                #endif
            }
            .safeAreaInset(edge: .bottom) {
                if let request = model.approvals.first {
                    RuntimeApprovalView(request: request) { decision in
                        await model.resolveApproval(request, decision: decision)
                    }
                    .id(request.id)
                    .environment(\.locale, locale)
                }
            }
            .sheet(isPresented: $showsWorkspaceSheet) {
                if let group = model.workgroup {
                    WorkspaceEditor(
                        workspaces: group.workspaces, settings: group.modelSettings, workspace: editingWorkspace
                    )
                    .environment(\.locale, locale)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, let group = model.workgroup { Task { await group.wake() } }
            }
            .alert(
                "Operation incomplete",
                isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
            ) {
                Button("OK", role: .cancel) { model.error = nil }
            } message: {
                Text(model.error.map { L10n.error($0, locale: locale) } ?? "")
            }
    }

    private var windowShell: some View {
        MiraWindowShell(
            sidebar: AnyView(
                sidebar
                    .environment(\.locale, locale)
                    .environment(\.miraOpenSettingsWindow, openWindow)
                    .foregroundStyle(MiraTheme.Colors.text).tint(MiraTheme.Colors.accent)),
            detail: AnyView(
                ZStack {
                    ForEach(model.retainedPages) { page in
                        ConversationDetail(
                            model: model, page: page, isDemo: isDemo,
                            inspect: { executionID in
                                page.inspectedExecutionID = executionID
                                showsInspector = true
                            }
                        )
                        .opacity(page.isActive ? 1 : 0)
                        .allowsHitTesting(page.isActive)
                        .disabled(!page.isActive)
                        .accessibilityHidden(!page.isActive)
                    }
                }
                .environment(\.locale, locale)
                .environment(\.miraOpenSettingsWindow, openWindow)
                .foregroundStyle(MiraTheme.Colors.text).tint(MiraTheme.Colors.accent)),
            inspector: AnyView(
                ExecutionInspector(model: model, page: model.activePage)
                    .environment(\.locale, locale)),
            title: displayedConversationTitle, locale: locale,
            canInspect: !model.activePage.executions.isEmpty, showsInspector: $showsInspector,
            newConversation: { Task { await model.newConversation() } }
        )
        .ignoresSafeArea()
    }

    private var displayedConversationTitle: String { title(for: model.activePage) }

    private func title(for page: ConversationPageState) -> String {
        guard let conversation = page.session ?? model.conversations.first(where: { $0.id == page.conversationID })
        else { return "Mira" }
        return displayTitle(conversation)
    }

    private func displayTitle(_ conversation: SessionQueryItem) -> String {
        guard let text = conversation.title.text, !text.isEmpty else {
            return L10n.string("Untitled conversation", locale: locale)
        }
        return text
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: MiraTheme.Spacing.sm) {
                Text("Mira").font(MiraTheme.Typography.title)
                Spacer()
                if isDemo {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(MiraTheme.Colors.secondaryText)
                        .help("Local demo · no network requests")
                }
            }
            .padding(.horizontal, MiraTheme.Spacing.xl)
            .padding(.top, MiraTheme.Spacing.lg)
            .padding(.bottom, MiraTheme.Spacing.xl)

            ScrollView {
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
                    VStack(spacing: 2) {
                        Button {
                            Task { await model.newConversation() }
                        } label: {
                            MiraSidebarRow { Label("New conversation", systemImage: "square.and.pencil") }
                        }
                        .accessibilityIdentifier("sidebar.newConversation")
                        // Keep these destinations inert until their replacement interfaces are designed.
                        Button {
                        } label: {
                            MiraSidebarRow { Label("Memories", systemImage: "brain") }
                        }
                        .help("Not implemented yet")
                        .accessibilityIdentifier("sidebar.memories")
                        Button {
                        } label: {
                            MiraSidebarRow { Label("Knowledge", systemImage: "book.closed") }
                        }
                        .help("Not implemented yet")
                        .accessibilityIdentifier("sidebar.knowledge")
                        Button {
                        } label: {
                            MiraSidebarRow { Label("Tasks", systemImage: "checklist") }
                        }
                        .help("Not implemented yet")
                        .accessibilityIdentifier("sidebar.tasks")
                    }
                    workspaceSection
                    conversationSection
                }
                .buttonStyle(MiraRowButtonStyle())
                .padding(.horizontal, MiraTheme.Spacing.sm)
                .padding(.bottom, MiraTheme.Spacing.lg)
            }
            .scrollIndicators(.hidden)

            Rectangle().fill(MiraTheme.Colors.border).frame(height: 1)
            MiraSettingsLink {
                MiraSidebarRow { Label("Settings", systemImage: "gearshape") }
            }
            .buttonStyle(MiraRowButtonStyle())
            .accessibilityIdentifier("sidebar.settings")
            .padding(MiraTheme.Spacing.sm)
        }
        // The native sidebar split item owns its material and accessibility fallback.
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Workspace")
                .font(MiraTheme.Typography.section)
                .foregroundStyle(MiraTheme.Colors.secondaryText)
                .padding(.horizontal, MiraTheme.Spacing.md)
                .padding(.bottom, MiraTheme.Spacing.sm)
            Button {
                Task { await model.selectWorkspace(nil) }
            } label: {
                MiraSidebarRow(isSelected: model.selectedWorkspaceID == nil) {
                    Label("Inbox", systemImage: "tray")
                }
            }
            ForEach(model.workspaces) { workspace in
                Button {
                    Task { await model.selectWorkspace(workspace.id) }
                } label: {
                    MiraSidebarRow(isSelected: model.selectedWorkspaceID == workspace.id) {
                        Label {
                            Text(verbatim: workspace.name).lineLimit(1)
                        } icon: {
                            Image(systemName: workspace.allowsRemoteSend ? "folder" : "lock.folder")
                        }
                    }
                }
                .contextMenu {
                    Button("Edit workspace") {
                        editingWorkspace = workspace
                        showsWorkspaceSheet = true
                    }
                }
            }
            Button {
                editingWorkspace = nil
                showsWorkspaceSheet = true
            } label: {
                MiraSidebarRow { Label("Create workspace", systemImage: "plus") }
            }
            .foregroundStyle(MiraTheme.Colors.secondaryText)
        }
    }

    private var conversationSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(L10n.string(model.showArchived ? "Archived" : "Conversations", locale: locale))
                    .font(MiraTheme.Typography.section)
                Spacer()
                Button {
                    model.showArchived.toggle()
                    Task { await model.selectConversation(nil) }
                } label: {
                    Label(
                        LocalizedStringKey(
                            model.showArchived ? "Show active conversations" : "Show archived conversations"),
                        systemImage: model.showArchived ? "bubble.left.and.bubble.right" : "archivebox")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(MiraIconButtonStyle())
                .help(
                    L10n.string(
                        model.showArchived ? "Show active conversations" : "Show archived conversations", locale: locale
                    ))
            }
            .foregroundStyle(MiraTheme.Colors.secondaryText)
            .padding(.leading, MiraTheme.Spacing.md)
            .padding(.trailing, MiraTheme.Spacing.xs)
            ForEach(model.filteredConversations) { conversation in
                Button {
                    Task { await model.selectConversation(conversation.id) }
                } label: {
                    MiraSidebarRow(isSelected: model.selectedConversationID == conversation.id) {
                        Text(verbatim: displayTitle(conversation))
                            .lineLimit(1)
                    }
                }
                .help(displayTitle(conversation))
                .accessibilityIdentifier("conversation.row.\(conversation.id.rawValue.uuidString)")
                .contextMenu {
                    if !conversation.summary.isArchived {
                        Button("Archive conversation", systemImage: "archivebox") {
                            Task { await model.archive(conversation.id) }
                        }
                    }
                }
            }
            if model.hasMoreConversations {
                Button("Earlier conversations") { Task { await model.loadMoreConversations() } }
                    .padding(.horizontal, MiraTheme.Spacing.md)
            }
            if model.filteredConversations.isEmpty {
                Text(
                    L10n.string(
                        model.showArchived ? "No archived conversations" : "No conversations yet", locale: locale)
                )
                .font(MiraTheme.Typography.caption)
                .foregroundStyle(MiraTheme.Colors.secondaryText)
                .padding(.horizontal, MiraTheme.Spacing.md)
                .padding(.vertical, MiraTheme.Spacing.sm)
            }
        }
    }

}

private struct ConversationTitleVisibility: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.1, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

private struct ConversationDetail: View {
    @Bindable var model: ConversationModel
    @Bindable var page: ConversationPageState
    let isDemo: Bool
    let inspect: (ExecutionID) -> Void
    @Environment(\.locale) private var locale
    @State private var rememberedMessage: SessionQueryMessage?
    @State private var revealedMessageID: MessageID?
    @State private var bottomOverlayHeight: CGFloat = 0

    private var currentConversation: SessionQueryItem? { page.session }

    var body: some View {
        GeometryReader { geometry in
            conversation(topOverlayHeight: geometry.safeAreaInsets.top)
                .overlay(alignment: .top) {
                    if #unavailable(macOS 26.1) {
                        MiraTheme.Colors.canvas.frame(height: geometry.safeAreaInsets.top)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottom) {
                    bottomOverlay
                        .onGeometryChange(for: CGFloat.self) { geometry in
                            ceil(geometry.size.height)
                        } action: { height in
                            bottomOverlayHeight = height
                        }
                }
                .ignoresSafeArea(.container, edges: .top)
        }
        .background(MiraTheme.Colors.canvas)
        .sheet(item: $rememberedMessage) { message in
            MemoryEditorView(
                library: model.library, workspaces: model.workspaces,
                sourceMessage: message, onSaved: { await model.reload() }
            )
            .environment(\.locale, locale)
        }
        .environment(
            \.openURL,
            OpenURLAction { url in
                guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                    return .discarded
                }
                NSWorkspace.shared.open(url)
                return .handled
            })
    }

    private func conversation(topOverlayHeight: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            if page.conversationID != nil {
                ConversationTranscript(
                    model: model, page: page, topOverlayHeight: topOverlayHeight,
                    bottomOverlayHeight: bottomOverlayHeight, rememberedMessage: $rememberedMessage,
                    revealedMessageID: $revealedMessageID)
            }
            if page.messages.isEmpty && page.activeExecution == nil {
                if !page.isLoading {
                    welcome.padding(.top, topOverlayHeight).padding(.bottom, bottomOverlayHeight).frame(
                        maxHeight: .infinity)
                }
            }
        }
    }
    private var bottomOverlay: some View {
        VStack(spacing: MiraTheme.Spacing.sm) {
            if let execution = page.executions.last, let completion = execution.completion,
                completion.status != .completed
            {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(L10n.string(execution.displayTitle, locale: locale)).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Execution details") { inspect(execution.id) }
                    if page.retryableExecution != nil { Button("Retry last turn") { Task { await model.retry(page) } } }
                }
                .padding(MiraTheme.Spacing.md)
                .modifier(MiraComposerGlass())
                .frame(maxWidth: MiraTheme.Layout.composerMax)
                .padding(.horizontal, MiraTheme.Spacing.xl)
            }
            if currentConversation?.summary.isArchived == true {
                Label("This conversation is archived", systemImage: "archivebox")
                    .foregroundStyle(.secondary).padding(MiraTheme.Spacing.lg)
                    .modifier(MiraComposerGlass())
                    .padding(.bottom, MiraTheme.Spacing.lg)
            }
            if currentConversation?.summary.isArchived != true {
                ConversationComposer(model: model, page: page, isDemo: isDemo)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var welcome: some View {
        VStack(spacing: MiraTheme.Spacing.xl) {
            MiraBrandMark()
                .frame(width: 72, height: 52)
                .opacity(0.45)
            Text("Start with an idea")
                .font(MiraTheme.Typography.welcome)
                .foregroundStyle(MiraTheme.Colors.text)
                .multilineTextAlignment(.center)
            if model.routes.isEmpty {
                Text(welcomeMessage)
                    .font(MiraTheme.Typography.body)
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 480)
                MiraSettingsLink { Label("Connect model service", systemImage: "key") }
                    .buttonStyle(MiraPrimaryButtonStyle())
            }
            if isDemo {
                Label("Demo replies generated locally", systemImage: "desktopcomputer")
                    .font(MiraTheme.Typography.caption)
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
            }
        }
        .padding(MiraTheme.Spacing.xxl)
        .frame(maxWidth: .infinity)
    }
    private var welcomeMessage: String {
        if model.routes.isEmpty {
            return L10n.string(
                "Connect your own model service first.\nConversations are stored on this Mac, and only the connection you choose is used when sending.",
                locale: locale)
        }
        return L10n.string(
            "Organize your thoughts, discuss a project, or ask a question.\nChoose a model, then write your first message.",
            locale: locale)
    }
}

private struct ConversationComposer: View {
    let model: ConversationModel
    @Bindable var page: ConversationPageState
    let isDemo: Bool
    @Environment(\.locale) private var locale
    @FocusState private var composerFocused: Bool

    private var selectedModelUnavailable: Bool {
        page.selectedRouteID.map { selected in !model.routes.contains { $0.id == selected } } ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            contextShelf
            Rectangle().fill(MiraTheme.Colors.border).frame(height: 1)
                .padding(.horizontal, MiraTheme.Spacing.lg)
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
                TextField("Send a message…", text: $page.composer, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...8)
                    .font(MiraTheme.Typography.body)
                    .focused($composerFocused)
                    .accessibilityLabel("Message input")
                    .accessibilityIdentifier("conversation.composer")
                if selectedModelUnavailable {
                    Text("Choose an available model or use the default model before sending.")
                        .font(MiraTheme.Typography.caption).foregroundStyle(.orange)
                }
                MiraComposerBarLayout {
                    HStack(spacing: MiraTheme.Spacing.sm) { executionStatus }
                    Text(
                        L10n.string(
                            isDemo ? "Local demo" : "Send to selected model service · ⌘ Return to send", locale: locale)
                    )
                    .font(MiraTheme.Typography.composerFootnote)
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
                    .multilineTextAlignment(.center)
                    HStack(spacing: MiraTheme.Spacing.sm) {
                        modelPicker
                        primaryAction
                    }
                }
            }
            .padding(.horizontal, MiraTheme.Spacing.lg)
            .padding(.top, MiraTheme.Spacing.md)
            .padding(.bottom, MiraTheme.Spacing.sm)

        }
        .frame(maxWidth: MiraTheme.Layout.composerMax)
        .modifier(MiraComposerGlass())
        .padding(.horizontal, MiraTheme.Spacing.xl)
        .padding(.bottom, MiraTheme.Layout.composerBottomInset)
        .padding(.top, MiraTheme.Spacing.sm)
        .frame(maxWidth: .infinity)
        .onChange(of: page.isActive) { _, active in
            if !active { composerFocused = false }
        }
    }

    private var contextShelf: some View {
        HStack(spacing: MiraTheme.Spacing.lg) {
            Label {
                Text(
                    verbatim: model.workspaces.first(where: { $0.id == page.workspaceID })?.name
                        ?? L10n.string("Inbox", locale: locale)
                )
                .lineLimit(1)
            } icon: {
                Image(systemName: "folder")
            }
            Label("Local Library", systemImage: "desktopcomputer")
                .foregroundStyle(MiraTheme.Colors.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(MiraTheme.Typography.caption)
        .padding(.horizontal, MiraTheme.Spacing.lg)
        .padding(.top, MiraTheme.Spacing.md)
        .padding(.bottom, MiraTheme.Spacing.md + MiraTheme.Spacing.xs)
    }

    private var modelPicker: some View {
        Menu {
            MiraModelPickerItems(groups: modelGroups, selectedID: page.selectedRouteID?.rawValue.uuidString) { value in
                guard let id = UUID(uuidString: value) else { return }
                Task { await model.selectModel(page, routeID: RouteID(id)) }
            }
        } label: {
            Text(verbatim: selectedModelLabel)
                .font(MiraTheme.Typography.composerModel)
                .foregroundStyle(MiraTheme.Colors.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: MiraTheme.Layout.composerModelMax, alignment: .trailing)
        .disabled(page.activeExecution != nil || page.isSelectingModel || page.isSending || !model.isReady)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(selectedModelLabel)
        .accessibilityLabel("Conversation model")
        .accessibilityValue(selectedModelLabel)
        .accessibilityIdentifier("conversation.modelPicker")

    }

    private var modelGroups: [MiraModelPickerGroup] {
        let grouped = Dictionary(grouping: model.routes, by: { $0.candidate.connection.id })
        return grouped.map { id, choices in
            MiraModelPickerGroup(id: id.rawValue.uuidString, title: choices[0].candidate.connection.name,
                options: choices.map { .init(id: $0.id.rawValue.uuidString, title: $0.name) })
        }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }

    private var selectedModelLabel: String {
        guard let selected = page.selectedRouteID else {
            return L10n.string("Select a model", locale: locale)
        }
        guard let entry = model.routes.first(where: { $0.id == selected }) else {
            return L10n.string("Unavailable model", locale: locale)
        }
        return entry.name
    }

    @ViewBuilder private var executionStatus: some View {
        if page.needsPersistenceRetry {
            Label("Reply pending save", systemImage: "externaldrive.badge.exclamationmark")
                .font(MiraTheme.Typography.caption).foregroundStyle(.orange)
        } else if let execution = page.activeExecution {
            ProgressView().controlSize(.small)
            Text(L10n.string(execution.displayTitle, locale: locale)).font(MiraTheme.Typography.caption)
                .foregroundStyle(MiraTheme.Colors.secondaryText)
        }
    }

    @ViewBuilder private var primaryAction: some View {
        if page.needsPersistenceRetry {
            Button("Retry save", systemImage: "externaldrive") { Task { await model.retrySaving(page) } }
                .buttonStyle(MiraPrimaryButtonStyle())
        } else if page.activeExecution != nil || page.isSending {
            Button("Stop", systemImage: "stop.fill") { Task { await model.cancel(page) } }
                .labelStyle(.iconOnly)
                .buttonStyle(MiraCircleButtonStyle())
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop")
                .accessibilityIdentifier("conversation.stop")
        } else {
            Button("Send", systemImage: "arrow.up") {
                Task {
                    await model.send(page)
                    if page.isActive { composerFocused = true }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(MiraCircleButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(
                !model.isReady || page.isSending || selectedModelUnavailable || model.routes.isEmpty
                    || page.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .help("Send")
            .accessibilityIdentifier("conversation.send")
        }
    }
}
