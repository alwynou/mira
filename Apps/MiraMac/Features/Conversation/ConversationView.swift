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
    @State private var expandedWorkspaceIDs: Set<WorkspaceID> = []
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
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
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
                        Button("New conversation", systemImage: "square.and.pencil") { Task { await model.newConversation() } }
                            .keyboardShortcut("n", modifiers: .command)
                            .accessibilityIdentifier("conversation.new")
                    }
                    ToolbarItem {
                        Button("Execution details", systemImage: "sidebar.right") { showsInspector.toggle() }
                            .disabled(model.executions.isEmpty)
                            .accessibilityIdentifier("conversation.inspector")
                    }
                }
                .inspector(isPresented: $showsInspector) {
                    ExecutionInspector(model: model)
                        .environment(\.locale, locale)
                        .background(MiraSurface.content)
                        .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
                }
            }
        }
        .toolbarBackground(MiraSurface.content, for: .windowToolbar)
        .frame(minWidth: 850, minHeight: 580)
        .onChange(of: model.selectedWorkspaceID) { _, id in
            if let id { expandedWorkspaceIDs.insert(id) }
        }
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
            Text("Mira")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MiraLayout.medium)
                .padding(.top, MiraLayout.large)
                .padding(.bottom, MiraLayout.medium)
            VStack(spacing: 0) {
                sidebarDestination("Memories", systemImage: "brain", isSelected: showsMemories) {
                    showsMemories = true
                    showsKnowledge = false
                    showsTasks = false
                }
                .accessibilityIdentifier("sidebar.memories")
                sidebarDestination("Knowledge", systemImage: "book.closed", isSelected: showsKnowledge) {
                    showsMemories = false
                    showsKnowledge = true
                    showsTasks = false
                }
                .accessibilityIdentifier("sidebar.knowledge")
                sidebarDestination("Tasks & Reminders", systemImage: "checklist", isSelected: showsTasks) {
                    showsMemories = false
                    showsKnowledge = false
                    showsTasks = true
                }
                .accessibilityIdentifier("sidebar.tasks")
            }
            .padding(.horizontal, MiraLayout.small)
            Divider()
            List {
                Section {
                    ForEach(model.workspaces) { workspace in
                        DisclosureGroup(isExpanded: workspaceExpansionBinding(for: workspace.id)) {
                            let workspaceConversations = conversations(for: workspace.id)
                            if workspaceConversations.isEmpty {
                                Text(L10n.string(model.showArchived ? "No archived conversations" : "No conversations yet", locale: locale))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(workspaceConversations) { conversation in
                                    conversationRow(conversation)
                                }
                            }
                        } label: {
                            Button {
                                selectWorkspace(workspace.id)
                            } label: {
                                HStack(spacing: MiraLayout.small) {
                                    Image(systemName: workspace.allowsRemoteSend ? "folder" : "lock.folder")
                                    Text(workspace.name).font(.body)
                                }
                                    .foregroundStyle(.primary)
                                    .padding(.vertical, MiraLayout.small)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(.rect)
                                    .background(model.selectedWorkspaceID == workspace.id ? Color(nsColor: .quaternaryLabelColor) : Color.clear,
                                                in: .rect(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                        .contextMenu { Button("Edit workspace") { editingWorkspace = workspace; showsWorkspaceSheet = true } }
                    }
                } header: {
                    sidebarSectionHeader("Workspaces", systemImage: "plus") {
                        editingWorkspace = nil
                        showsWorkspaceSheet = true
                    }
                }
                Section {
                    let temporaryConversations = conversations(for: nil)
                    if temporaryConversations.isEmpty {
                        Text(L10n.string(model.showArchived ? "No archived conversations" : "No conversations yet", locale: locale))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(temporaryConversations) { conversation in
                            conversationRow(conversation)
                        }
                    }
                } header: {
                    HStack(spacing: MiraLayout.small) {
                        Text(L10n.string(model.showArchived ? "Archived" : "Conversations", locale: locale))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button {
                            model.showArchived.toggle()
                            Task { await model.selectConversation(nil) }
                        } label: {
                            Image(systemName: model.showArchived ? "bubble.left.and.bubble.right" : "archivebox")
                        }
                        .buttonStyle(.plain)
                        .help(L10n.string(model.showArchived ? "Show active conversations" : "Show archived conversations", locale: locale))
                        Button {
                            showsMemories = false
                            model.selectedWorkspaceID = nil
                            Task { await model.newConversation() }
                        } label: { Image(systemName: "plus") }
                            .buttonStyle(.plain)
                            .help(L10n.string("New conversation", locale: locale))
                    }
                }
            }.listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            Divider()
            SettingsLink { Label("Settings", systemImage: "gearshape").font(.body).frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(MiraSettingsButtonStyle())
                .padding(.horizontal, MiraLayout.medium)
                .padding(.vertical, MiraLayout.large)
        }
    }

    private func sidebarDestination(_ title: LocalizedStringKey, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: MiraLayout.medium) {
                Image(systemName: systemImage).font(.title3).frame(width: 24)
                Text(title).font(.body)
            }
                .foregroundStyle(.primary)
                .padding(.vertical, MiraLayout.small)
                .padding(.horizontal, MiraLayout.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .background(isSelected ? Color(nsColor: .quaternaryLabelColor) : Color.clear, in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func sidebarSectionHeader(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: MiraLayout.small) {
            Text(title)
            Spacer(minLength: 0)
            Button(action: action) { Image(systemName: systemImage) }
                .buttonStyle(.plain)
                .help(L10n.string("Create workspace", locale: locale))
        }
    }

    private func workspaceExpansionBinding(for id: WorkspaceID) -> Binding<Bool> {
        Binding(
            get: { expandedWorkspaceIDs.contains(id) },
            set: { isExpanded in
                if isExpanded { expandedWorkspaceIDs.insert(id) }
                else { expandedWorkspaceIDs.remove(id) }
            }
        )
    }

    private func conversations(for workspaceID: WorkspaceID?) -> [Conversation] {
        model.conversations.filter { $0.workspaceID == workspaceID && $0.isArchived == model.showArchived }
    }

    private func selectWorkspace(_ id: WorkspaceID) {
        expandedWorkspaceIDs.insert(id)
        model.selectedWorkspaceID = id
        Task { await model.selectConversation(nil) }
    }

    private func conversationRow(_ conversation: Conversation) -> some View {
        Button {
            showsMemories = false
            showsKnowledge = false
            showsTasks = false
            Task { await model.selectConversation(conversation.id) }
        } label: {
            HStack(alignment: .top, spacing: MiraLayout.small) {
                Image(systemName: "bubble.left").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: MiraLayout.micro) {
                    Text(conversation.title).lineLimit(2)
                    Text(conversation.updatedAt, format: .dateTime.month(.abbreviated).day())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, MiraLayout.micro)
            .foregroundStyle(.primary)
            .contentShape(.rect)
            .background(model.selectedConversationID == conversation.id ? Color(nsColor: .quaternaryLabelColor) : Color.clear,
                        in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("conversation.row.\(conversation.id.rawValue.uuidString)")
        .contextMenu {
            if !conversation.isArchived {
                Button("Archive conversation", systemImage: "archivebox") { Task { await model.archive(conversation.id) } }
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
                }.padding(.horizontal, MiraLayout.section).padding(.vertical, MiraLayout.medium)
            }
            if model.currentConversation?.isArchived == true {
                Label("This conversation is archived", systemImage: "archivebox")
                    .foregroundStyle(.secondary)
                    .padding(MiraLayout.large)
            }
        }
        .background(MiraSurface.content)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let conversationID = model.selectedConversationID {
                    DisclosureGroup(isExpanded: $showsExtractionStatus) {
                        MemoryExtractionStatusView(application: model.application, conversationID: conversationID,
                                                   onOpenMemory: onOpenMemory, onOpenSource: revealMessage)
                            .frame(minHeight: 72, maxHeight: 220)
                            .environment(\.locale, locale)
                    } label: {
                        Label("Memory extraction", systemImage: "sparkles")
                            .font(.callout.weight(.semibold))
                    }
                    .padding(.horizontal, MiraLayout.large)
                    .padding(.vertical, MiraLayout.small)
                    .frame(maxWidth: MiraLayout.readingWidth)
                    .frame(maxWidth: .infinity)
                }
                if model.currentConversation?.isArchived != true {
                    ConversationComposer(model: model, isDemo: isDemo)
                }
            }
        }
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
        VStack(spacing: 20) {
            Image(systemName: "sparkle").font(.system(size: 44, weight: .light)).foregroundStyle(.primary)
            Text("Start with an idea").font(.largeTitle.weight(.semibold))
            Text(welcomeMessage)
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            if model.routes.isEmpty { SettingsLink { Label("Connect model service", systemImage: "key").padding(.horizontal, 12) }.buttonStyle(.borderedProminent).tint(.primary).controlSize(.large) }
            if isDemo { Label("Demo replies generated locally", systemImage: "desktopcomputer").font(.caption).foregroundStyle(.secondary) }
        }.padding(40).frame(maxWidth: .infinity)
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
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MiraLayout.small) {
            TextField("Send a message…", text: $model.composer, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...8)
                .font(.body)
                .focused($composerFocused)
                .accessibilityLabel("Message input")
                .accessibilityIdentifier("conversation.composer")
            if model.selectedModelUnavailable {
                Text("Choose an available model or use the default model before sending.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: MiraLayout.small) {
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
                .frame(maxWidth: 320)
                .disabled(model.activeExecution != nil)
                ViewThatFits(in: .horizontal) {
                    Text(L10n.string(isDemo ? "Local demo" : "Send to selected model service · ⌘ Return to send", locale: locale))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    EmptyView()
                }
                Spacer()
                if model.needsPersistenceRetry {
                    Label("Reply pending save", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if model.activeExecution != nil {
                    ProgressView().controlSize(.small)
                    Text("Generating").font(.caption).foregroundStyle(.secondary)
                }
                if model.needsPersistenceRetry {
                    Button("Retry save", systemImage: "externaldrive") { Task { await model.retrySaving() } }
                        .buttonStyle(.borderedProminent).tint(.primary)
                } else if model.activeExecution != nil {
                    composerActionButton("Stop", systemImage: "stop.fill") {
                        Task { await model.cancel() }
                    }
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityIdentifier("conversation.stop")
                } else {
                    composerActionButton("Send", systemImage: "arrow.up") {
                        Task { await model.send(); composerFocused = true }
                    }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.isSending || model.selectedModelUnavailable || model.routes.isEmpty || model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("conversation.send")
                }
            }
        }
        .padding(.horizontal, MiraLayout.large)
        .padding(.top, MiraLayout.medium)
        .padding(.bottom, MiraLayout.medium)
        .frame(maxWidth: MiraLayout.readingWidth)
        .conversationGlassSurface()
        .frame(maxWidth: .infinity)
        .padding(.horizontal, MiraLayout.large)
        .padding(.bottom, MiraLayout.medium)
    }

    private func composerActionButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 32)
                .foregroundStyle(Color(nsColor: .textBackgroundColor))
                .background(Color(nsColor: .labelColor), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

}

private extension View {
    @ViewBuilder
    func conversationGlassSurface() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: 22))
        } else {
            background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
                .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.quaternary) }
        }
    }
}

private struct MiraSettingsButtonStyle: ButtonStyle {
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovered || configuration.isPressed ? Color.primary : Color.secondary)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : (isHovered ? 1.02 : 1)))
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .snappy, value: isHovered)
            .animation(reduceMotion ? nil : .snappy, value: configuration.isPressed)
    }
}
