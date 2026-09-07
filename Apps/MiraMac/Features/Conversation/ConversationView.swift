import SwiftUI
import MiraCore
import AppKit

struct ConversationRoot: View {
    @Environment(\.locale) private var locale
    @State private var model: ConversationModel
    @State private var showsWorkspaceSheet = false
    @State private var editingWorkspace: Workspace?
    @State private var showsInspector = false
    @State private var showsMemories = false
    @State private var showsKnowledge = false
    @State private var showsTasks = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var initialMemoryID: MemoryID?
    let isDemo: Bool

    init(application: MiraApplication, isDemo: Bool) {
        _model = State(initialValue: ConversationModel(application: application))
        self.isDemo = isDemo
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: MiraTheme.Layout.sidebarMin, ideal: MiraTheme.Layout.sidebarIdeal, max: MiraTheme.Layout.sidebarMax)
        } detail: {
            if showsMemories {
                MemoryRootView(application: model.application, workspaceID: model.selectedWorkspaceID, workspaces: model.workspaces,
                               initialMemoryID: initialMemoryID) { id in
                    showsMemories = false
                    initialMemoryID = nil
                    if let conversation = model.conversations.first(where: { $0.id == id }) {
                        model.selectedWorkspaceID = conversation.workspaceID
                        model.showArchived = conversation.isArchived
                    }
                    Task { await model.selectConversation(id) }
                }.navigationTitle(L10n.string("Memories", locale: locale))
            } else {
            ConversationDetail(model: model, isDemo: isDemo,
                               onOpenMemory: { id in
                                   initialMemoryID = id
                                   showsMemories = true
                               })
                .navigationTitle(displayedConversationTitle)
                .toolbar {
                    ToolbarItem {
                        Button("Execution details", systemImage: "sidebar.right") { showsInspector.toggle() }
                            .disabled(model.executions.isEmpty)
                            .accessibilityIdentifier("conversation.inspector")
                    }
                    ToolbarItem {
                        Button("Knowledge", systemImage: "book.closed") { showsKnowledge = true }
                    }
                }
                .inspector(isPresented: $showsInspector) { ExecutionInspector(model: model).environment(\.locale, locale).inspectorColumnWidth(min: 280, ideal: 340, max: 480) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New conversation", systemImage: "square.and.pencil") {
                    showsMemories = false
                    Task { await model.newConversation() }
                }
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityIdentifier("conversation.new")
            }
        }
        .tint(MiraTheme.Colors.accent)
        .foregroundStyle(MiraTheme.Colors.text)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 850, minHeight: 580)
        .task {
            #if DEBUG
            if NativePerformanceBenchmark.isRequested {
                await NativePerformanceBenchmark.run(model: model)
                return
            }
            #endif
            await model.observe()
        }
        .task { await model.observeMemoryApprovals() }
        .onChange(of: showsMemories) { _, isShowing in
            if !isShowing { initialMemoryID = nil }
        }
        .safeAreaInset(edge: .bottom) {
            if let request = model.memoryApprovals.first {
                MemoryToolApprovalView(request: request, application: model.application, workspaces: model.workspaces)
                    .environment(\.locale, locale)
            }
        }
        .sheet(isPresented: $showsWorkspaceSheet) { WorkspaceEditor(application: model.application, workspace: editingWorkspace).environment(\.locale, locale) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.application.refreshReminderDelivery() } }
        }
        .sheet(isPresented: $showsTasks) {
            TaskRootView(application: model.application, workspaceID: model.selectedWorkspaceID)
                .environment(\.locale, locale)
        }
        .sheet(isPresented: $showsKnowledge) {
            KnowledgeRootView(application: model.application, workspaceID: model.selectedWorkspaceID, workspaces: model.workspaces)
                .environment(\.locale, locale)
        }
        .alert("Operation incomplete", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error.map { L10n.error($0, locale: locale) } ?? "") }
    }

    private var displayedConversationTitle: String {
        guard let conversation = model.currentConversation else { return "Mira" }
        return conversation.title.isEmpty ? L10n.string("New conversation", locale: locale) : conversation.title
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
                            showsMemories = false
                            Task { await model.newConversation() }
                        } label: {
                            MiraSidebarRow { Label("New conversation", systemImage: "square.and.pencil") }
                        }
                        .accessibilityIdentifier("sidebar.newConversation")
                        Button { showsMemories = true } label: {
                            MiraSidebarRow(isSelected: showsMemories) { Label("Memories", systemImage: "brain") }
                        }.accessibilityIdentifier("sidebar.memories")
                        Button { showsKnowledge = true } label: {
                            MiraSidebarRow { Label("Knowledge", systemImage: "book.closed") }
                        }.accessibilityIdentifier("sidebar.knowledge")
                        Button { showsTasks = true } label: {
                            MiraSidebarRow { Label("Tasks", systemImage: "checklist") }
                        }.accessibilityIdentifier("sidebar.tasks")
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
            SettingsLink {
                MiraSidebarRow { Label("Settings", systemImage: "gearshape") }
            }
            .buttonStyle(MiraRowButtonStyle())
            .padding(MiraTheme.Spacing.sm)
        }
        // NavigationSplitView owns the native sidebar material and accessibility fallback.
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Workspace")
                .font(MiraTheme.Typography.section)
                .foregroundStyle(MiraTheme.Colors.secondaryText)
                .padding(.horizontal, MiraTheme.Spacing.md)
                .padding(.bottom, MiraTheme.Spacing.sm)
            Button {
                showsMemories = false
                model.selectedWorkspaceID = nil
                Task { await model.selectConversation(nil) }
            } label: {
                MiraSidebarRow(isSelected: model.selectedWorkspaceID == nil && !showsMemories) {
                    Label("Inbox", systemImage: "tray")
                }
            }
            ForEach(model.workspaces) { workspace in
                Button {
                    showsMemories = false
                    model.selectedWorkspaceID = workspace.id
                    Task { await model.selectConversation(nil) }
                } label: {
                    MiraSidebarRow(isSelected: model.selectedWorkspaceID == workspace.id && !showsMemories) {
                        Label {
                            Text(verbatim: workspace.name).lineLimit(1)
                        } icon: {
                            Image(systemName: workspace.allowsRemoteSend ? "folder" : "lock.folder")
                        }
                    }
                }
                .contextMenu {
                    Button("Edit workspace") { editingWorkspace = workspace; showsWorkspaceSheet = true }
                }
            }
            Button { editingWorkspace = nil; showsWorkspaceSheet = true } label: {
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
                Button { model.showArchived.toggle(); Task { await model.selectConversation(nil) } } label: {
                    Label(LocalizedStringKey(model.showArchived ? "Show active conversations" : "Show archived conversations"),
                          systemImage: model.showArchived ? "bubble.left.and.bubble.right" : "archivebox")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(MiraIconButtonStyle())
                .help(L10n.string(model.showArchived ? "Show active conversations" : "Show archived conversations", locale: locale))
            }
            .foregroundStyle(MiraTheme.Colors.secondaryText)
            .padding(.leading, MiraTheme.Spacing.md)
            .padding(.trailing, MiraTheme.Spacing.xs)
            ForEach(model.filteredConversations) { conversation in
                Button { showsMemories = false; Task { await model.selectConversation(conversation.id) } } label: {
                    MiraSidebarRow(isSelected: model.selectedConversationID == conversation.id && !showsMemories) {
                        Text(verbatim: conversation.title.isEmpty ? L10n.string("New conversation", locale: locale) : conversation.title)
                            .lineLimit(1)
                    }
                }
                .help(conversation.title.isEmpty ? L10n.string("New conversation", locale: locale) : conversation.title)
                .accessibilityIdentifier("conversation.row.\(conversation.id.rawValue.uuidString)")
                .contextMenu {
                    if !conversation.isArchived {
                        Button("Archive conversation", systemImage: "archivebox") { Task { await model.archive(conversation.id) } }
                    }
                }
            }
            if model.filteredConversations.isEmpty {
                Text(L10n.string(model.showArchived ? "No archived conversations" : "No conversations yet", locale: locale))
                    .font(MiraTheme.Typography.caption)
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
                    .padding(.horizontal, MiraTheme.Spacing.md)
                    .padding(.vertical, MiraTheme.Spacing.sm)
            }
        }
    }

}

private struct ConversationDetail: View {
    @Bindable var model: ConversationModel
    let isDemo: Bool
    let onOpenMemory: (MemoryID) -> Void
    @Environment(\.locale) private var locale
    @State private var rememberedMessage: Message?
    @State private var showsExtractionStatus = false
    @State private var revealedMessageID: MessageID?

    var body: some View {
        VStack(spacing: 0) {
            if model.messages.isEmpty && model.activeExecution == nil { welcome.frame(maxHeight: .infinity) }
            else {
                ConversationTranscript(model: model, rememberedMessage: $rememberedMessage, revealedMessageID: $revealedMessageID)
                    .id(model.selectedConversationID)
            }
            if let execution = model.executions.last, execution.status.isTerminal, execution.status != .completed {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(execution.error.map { L10n.error($0, locale: locale) } ?? L10n.string("The reply was interrupted.", locale: locale)).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if model.retryableExecution != nil { Button("Retry last turn") { Task { await model.retry() } } }
                }.padding(.horizontal, 28).padding(.vertical, 12)
            }
            if model.currentConversation?.isArchived == true {
                Label("This conversation is archived", systemImage: "archivebox").foregroundStyle(.secondary).padding(20)
            }
            if let conversationID = model.selectedConversationID, !model.messages.isEmpty || !model.executions.isEmpty {
                DisclosureGroup(isExpanded: $showsExtractionStatus) {
                    MemoryExtractionStatusView(application: model.application, conversationID: conversationID,
                                               onOpenMemory: onOpenMemory, onOpenSource: revealMessage)
                        .frame(minHeight: 72, maxHeight: 220)
                        .environment(\.locale, locale)
                } label: {
                    Label("Memory extraction", systemImage: "sparkles")
                        .font(MiraTheme.Typography.caption)
                        .foregroundStyle(MiraTheme.Colors.secondaryText)
                }
                .frame(maxWidth: MiraTheme.Layout.composerMax)
                .padding(.horizontal, MiraTheme.Spacing.xl)
                .padding(.vertical, 8)
            }
            if model.currentConversation?.isArchived != true { ConversationComposer(model: model, isDemo: isDemo) }
        }
        .background(MiraTheme.Colors.canvas)
        .sheet(item: $rememberedMessage) { message in
            MemoryEditorView(application: model.application, workspaces: model.workspaces,
                             initialScope: model.currentConversation?.workspaceID.map(MemoryScope.workspace) ?? .global,
                             sourceMessage: message, onSaved: { await model.reload() })
                .environment(\.locale, locale)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .discarded }
            NSWorkspace.shared.open(url)
            return .handled
        })
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
                SettingsLink { Label("Connect model service", systemImage: "key") }
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
    private func revealMessage(_ messageID: MessageID) {
        guard model.messages.contains(where: { $0.id == messageID && $0.role == .user && $0.status == .committed }) else { return }
        revealedMessageID = messageID
    }

    private var welcomeMessage: String {
        if model.routes.isEmpty {
            return L10n.string("Connect your own model service first.\nConversations are stored on this Mac, and only the connection you choose is used when sending.", locale: locale)
        }
        return L10n.string("Organize your thoughts, discuss a project, or ask a question.\nChoose a model, then write your first message.", locale: locale)
    }
}

private struct ConversationComposer: View {
    @Bindable var model: ConversationModel
    let isDemo: Bool
    @Environment(\.locale) private var locale
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            contextShelf
                .padding(.horizontal, MiraTheme.Spacing.md)
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.lg) {
                TextField("Send a message…", text: $model.composer, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...8)
                    .font(MiraTheme.Typography.body)
                    .focused($composerFocused)
                    .accessibilityLabel("Message input")
                    .accessibilityIdentifier("conversation.composer")
                if model.selectedModelUnavailable {
                    Text("Choose an available model or use the default model before sending.")
                        .font(MiraTheme.Typography.caption).foregroundStyle(.orange)
                }
                HStack(spacing: MiraTheme.Spacing.sm) {
                    executionStatus
                    Spacer(minLength: MiraTheme.Spacing.sm)
                    modelPicker
                    primaryAction
                }
            }
            .padding(MiraTheme.Spacing.lg)
            .background(MiraTheme.Colors.surface, in: .rect(cornerRadius: MiraTheme.Radius.composer))
            .overlay {
                RoundedRectangle(cornerRadius: MiraTheme.Radius.composer)
                    .strokeBorder(composerFocused ? MiraTheme.Colors.secondaryText.opacity(contrast == .increased ? 1 : 0.5) : MiraTheme.Colors.border,
                                  lineWidth: contrast == .increased || composerFocused ? 1.5 : 1)
            }
            .shadow(color: .black.opacity(0.035), radius: 12, x: 0, y: 3)

            Text(L10n.string(isDemo ? "Local demo" : "Send to selected model service · ⌘ Return to send", locale: locale))
                .font(MiraTheme.Typography.caption)
                .foregroundStyle(MiraTheme.Colors.secondaryText)
                .padding(.top, MiraTheme.Spacing.sm)
        }
        .frame(maxWidth: MiraTheme.Layout.composerMax)
        .padding(.horizontal, MiraTheme.Spacing.xl)
        .padding(.bottom, MiraTheme.Spacing.lg)
        .padding(.top, MiraTheme.Spacing.md)
        .frame(maxWidth: .infinity)
    }

    private var contextShelf: some View {
        HStack(spacing: MiraTheme.Spacing.lg) {
            Label {
                Text(verbatim: model.workspaces.first(where: { $0.id == model.selectedWorkspaceID })?.name
                     ?? L10n.string("Inbox", locale: locale))
                    .lineLimit(1)
            } icon: { Image(systemName: "folder") }
            Label("Local Library", systemImage: "desktopcomputer")
                .foregroundStyle(MiraTheme.Colors.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(MiraTheme.Typography.caption)
        .padding(.horizontal, MiraTheme.Spacing.lg)
        .padding(.top, MiraTheme.Spacing.md)
        .padding(.bottom, MiraTheme.Spacing.md + MiraTheme.Spacing.xs)
        .background(MiraTheme.Colors.inset, in: .rect(topLeadingRadius: MiraTheme.Radius.panel, topTrailingRadius: MiraTheme.Radius.panel))
        .padding(.bottom, -MiraTheme.Spacing.xs)
    }

    private var modelPicker: some View {
        Picker("Conversation model", selection: $model.selectedRouteID) {
            Text("Use default model").tag(nil as RouteID?)
            if let selected = model.selectedRouteID, !model.routes.contains(where: { $0.id == selected }) {
                Text("Unavailable model").tag(Optional(selected))
            }
            ForEach(model.configuration.models(for: .conversation)) { entry in
                Text(verbatim: "\(entry.model.modelID) · \(entry.connection.name)").tag(Optional(entry.route.id))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .buttonStyle(.plain)
        .font(MiraTheme.Typography.caption)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 260)
        .disabled(model.activeExecution != nil)
        .accessibilityIdentifier("conversation.modelPicker")
    }

    @ViewBuilder private var executionStatus: some View {
        if model.needsPersistenceRetry {
            Label("Reply pending save", systemImage: "externaldrive.badge.exclamationmark")
                .font(MiraTheme.Typography.caption).foregroundStyle(.orange)
        } else if model.activeExecution != nil {
            ProgressView().controlSize(.small)
            Text("Generating").font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
        }
    }

    @ViewBuilder private var primaryAction: some View {
        if model.needsPersistenceRetry {
            Button("Retry save", systemImage: "externaldrive") { Task { await model.retrySaving() } }
                .buttonStyle(MiraPrimaryButtonStyle())
        } else if model.activeExecution != nil {
            Button("Stop", systemImage: "stop.fill") { Task { await model.cancel() } }
                .labelStyle(.iconOnly)
                .buttonStyle(MiraCircleButtonStyle())
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop")
                .accessibilityIdentifier("conversation.stop")
        } else {
            Button("Send", systemImage: "arrow.up") { Task { await model.send(); composerFocused = true } }
                .labelStyle(.iconOnly)
                .buttonStyle(MiraCircleButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isSending || model.selectedModelUnavailable || model.routes.isEmpty || model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send")
                .accessibilityIdentifier("conversation.send")
        }
    }
}
