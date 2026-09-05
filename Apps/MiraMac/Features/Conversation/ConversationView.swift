import SwiftUI
import MiraCore
import SwiftStreamingMarkdown
import AppKit

struct ConversationRoot: View {
    @Environment(\.locale) private var locale
    @State private var model: ConversationModel
    @State private var showsWorkspaceSheet = false
    @State private var editingWorkspace: Workspace?
    @State private var showsInspector = false
    @State private var showsMemories = false
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
                    }
                    ToolbarItem {
                        Button("Execution details", systemImage: "sidebar.right") { showsInspector.toggle() }
                            .disabled(model.executions.isEmpty)
                    }
                }
                .inspector(isPresented: $showsInspector) { ExecutionInspector(model: model).environment(\.locale, locale).inspectorColumnWidth(min: 280, ideal: 340, max: 480) }
            }
        }
        .frame(minWidth: 850, minHeight: 580)
        .task { await model.observe() }
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
            HStack(spacing: 10) {
                Image(systemName: "sparkle").font(.title).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mira").font(.title2.weight(.semibold))
                    Text(L10n.string(isDemo ? "Local demo · no network requests" : "Your personal workspace", locale: locale)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(20)
            List {
                Section {
                    Button { showsMemories = true } label: {
                        Label("Memories", systemImage: "brain")
                            .foregroundStyle(showsMemories ? Color.accentColor : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }.buttonStyle(.plain)
                }
                Section("Workspace") {
                    Button {
                        model.selectedWorkspaceID = nil; Task { await model.selectConversation(nil) }
                    } label: {
                        Label("Inbox", systemImage: "tray").foregroundStyle(model.selectedWorkspaceID == nil ? Color.accentColor : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    ForEach(model.workspaces) { workspace in
                        Button {
                            model.selectedWorkspaceID = workspace.id; Task { await model.selectConversation(nil) }
                        } label: {
                            Label(workspace.name, systemImage: workspace.allowsRemoteSend ? "folder" : "lock.folder")
                                .foregroundStyle(model.selectedWorkspaceID == workspace.id ? Color.accentColor : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                        }.buttonStyle(.plain)
                            .contextMenu { Button("Edit workspace") { editingWorkspace = workspace; showsWorkspaceSheet = true } }
                    }
                    Button { editingWorkspace = nil; showsWorkspaceSheet = true } label: {
                        Label("Create workspace", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                    }.buttonStyle(.plain)
                }
                Section {
                    ForEach(model.filteredConversations) { conversation in
                        Button { showsMemories = false; Task { await model.selectConversation(conversation.id) } } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "bubble.left").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conversation.title).lineLimit(2)
                                    Text(conversation.updatedAt, format: .dateTime.month(.abbreviated).day()).font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 5)
                            .foregroundStyle(model.selectedConversationID == conversation.id ? Color.accentColor : Color.primary)
                            .contentShape(.rect)
                        }.buttonStyle(.plain)
                            .contextMenu {
                                if !conversation.isArchived { Button("Archive conversation", systemImage: "archivebox") { Task { await model.archive(conversation.id) } } }
                            }
                    }
                    if model.filteredConversations.isEmpty { Text(L10n.string(model.showArchived ? "No archived conversations" : "No conversations yet", locale: locale)).font(.caption).foregroundStyle(.secondary) }
                } header: {
                    HStack {
                        Text(L10n.string(model.showArchived ? "Archived" : "Conversations", locale: locale))
                        Spacer()
                        Button { model.showArchived.toggle(); Task { await model.selectConversation(nil) } } label: { Image(systemName: model.showArchived ? "bubble.left.and.bubble.right" : "archivebox") }
                            .buttonStyle(.plain).help(L10n.string(model.showArchived ? "Show active conversations" : "Show archived conversations", locale: locale))
                    }
                }
            }.listStyle(.sidebar)
            Divider()
            SettingsLink { Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.plain).padding(18)
        }
    }
}

private struct ConversationDetail: View {
    @Bindable var model: ConversationModel
    let isDemo: Bool
    let onOpenMemory: (MemoryID) -> Void
    @Environment(\.locale) private var locale
    @FocusState private var composerFocused: Bool
    @State private var rememberedMessage: Message?
    @State private var showsExtractionStatus = false
    @State private var revealedMessageID: MessageID?

    var body: some View {
        VStack(spacing: 0) {
            if model.messages.isEmpty && model.activeExecution == nil { welcome.frame(maxHeight: .infinity) }
            else { transcript }
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
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
            if model.currentConversation?.isArchived != true { composer }
        }
        .background(Color(nsColor: .textBackgroundColor))
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
            Image(systemName: "sparkle").font(.system(size: 44, weight: .light)).foregroundStyle(.tint)
            Text("Start with an idea").font(.largeTitle.weight(.semibold))
            Text(welcomeMessage)
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            if model.routes.isEmpty { SettingsLink { Label("Connect model service", systemImage: "key").padding(.horizontal, 12) }.buttonStyle(.borderedProminent).controlSize(.large) }
            if isDemo { Label("Demo replies generated locally", systemImage: "desktopcomputer").font(.caption).foregroundStyle(.secondary) }
        }.padding(40).frame(maxWidth: .infinity)
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(transcriptItems) { item in
                        if item.bodyPurgedAt != nil {
                            Label("Reply content cleared after forgetting a memory", systemImage: "eye.slash")
                                .font(.callout).foregroundStyle(.secondary)
                        } else if item.role == .assistant {
                            VStack(alignment: .leading, spacing: 10) {
                                AssistantMarkdownRow(text: item.text, status: item.status, isStreaming: item.isStreaming)
                                if let executionID = item.executionID, let conversationID = model.selectedConversationID {
                                    MemoryCitationList(references: MemoryCitationReference.references(in: item.text), executionID: executionID,
                                                       conversationID: conversationID, application: model.application) { sourceID in
                                        Task { await model.selectConversation(sourceID) }
                                    }.padding(.leading, 40)
                                }
                            }
                        } else {
                            MessageRow(role: item.role, text: item.text, status: item.status)
                                .contextMenu {
                                    if let message = item.message, message.role == .user, message.status == .committed {
                                        Button("Remember this message…", systemImage: "brain") { rememberedMessage = message }
                                    }
                                }
                        }
                    }
                    Color.clear.frame(height: 1).id("transcript-end")
                }.padding(28).frame(maxWidth: 860).frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: revealedMessageID) { _, messageID in
                guard let messageID,
                      model.messages.contains(where: { $0.id == messageID && $0.role == .user && $0.status == .committed }) else { return }
                proxy.scrollTo("message:\(messageID.rawValue.uuidString)", anchor: .center)
                revealedMessageID = nil
            }
            .onChange(of: model.messages.count) { _, _ in proxy.scrollTo("transcript-end", anchor: .bottom) }
        }
    }

    private func revealMessage(_ messageID: MessageID) {
        guard model.messages.contains(where: { $0.id == messageID && $0.role == .user && $0.status == .committed }) else { return }
        revealedMessageID = messageID
    }

    private var transcriptItems: [TranscriptItem] {
        var items = model.messages.map { message in
            TranscriptItem(
                id: message.role == .assistant ? (message.executionID.map { "execution:\($0.rawValue.uuidString)" } ?? "message:\(message.id.rawValue.uuidString)") : "message:\(message.id.rawValue.uuidString)",
                role: message.role,
                text: message.text,
                status: message.status,
                isStreaming: false,
                message: message,
                bodyPurgedAt: message.bodyPurgedAt,
                executionID: message.executionID
            )
        }
        if let execution = model.executions.last,
           !items.contains(where: { $0.id == "execution:\(execution.id.rawValue.uuidString)" }),
           let draft = model.drafts[execution.id] {
            items.append(.init(
                id: "execution:\(execution.id.rawValue.uuidString)", role: .assistant, text: draft,
                status: execution.status.isTerminal ? .interrupted : nil,
                isStreaming: !execution.status.isTerminal,
                executionID: execution.id
            ))
        }
        return items
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Conversation model", selection: $model.selectedRouteID) {
                    Text("Use purpose route").tag(nil as RouteID?)
                    if let selected = model.selectedRouteID, !model.routes.contains(where: { $0.id == selected }) { Text("Unavailable route").tag(Optional(selected)) }
                    ForEach(model.routes) { route in Text(verbatim: route.name).tag(Optional(route.id)) }
                }.labelsHidden().frame(maxWidth: 320).disabled(model.activeExecution != nil)
                Spacer()
                if model.needsPersistenceRetry { Label("Reply pending save", systemImage: "externaldrive.badge.exclamationmark").font(.caption).foregroundStyle(.orange) }
                else if model.activeExecution != nil { ProgressView().controlSize(.small); Text("Generating").font(.caption).foregroundStyle(.secondary) }
            }
            TextField("Send a message…", text: $model.composer, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(3...8).font(.body).focused($composerFocused)
                .accessibilityLabel("Message input")
            HStack {
                Text(L10n.string(isDemo ? "Local demo" : "Send to selected model service · ⌘ Return to send", locale: locale))
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if model.needsPersistenceRetry {
                    Button("Retry save", systemImage: "externaldrive") { Task { await model.retrySaving() } }.buttonStyle(.borderedProminent)
                } else if model.activeExecution != nil {
                    Button("Stop", systemImage: "stop.fill") { Task { await model.cancel() } }.keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("Send", systemImage: "arrow.up") { Task { await model.send(); composerFocused = true } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.isSending || model.routes.isEmpty || model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(16).background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary) }
        .padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 12)
        .frame(maxWidth: 910).frame(maxWidth: .infinity)
    }

    private var welcomeMessage: String {
        if model.routes.isEmpty {
            return L10n.string("Connect your own model service first.\nConversations are stored on this Mac, and only the connection you choose is used when sending.", locale: locale)
        }
        return L10n.string("Organize your thoughts, discuss a project, or ask a question.\nChoose a model, then write your first message.", locale: locale)
    }
}
