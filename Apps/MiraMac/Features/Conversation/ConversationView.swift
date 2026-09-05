import SwiftUI
import MiraCore

struct ConversationRoot: View {
    @State private var model: ConversationModel
    @State private var showsWorkspaceSheet = false
    @State private var editingWorkspace: Workspace?
    @State private var showsInspector = false
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
            ConversationDetail(model: model, isDemo: isDemo)
                .navigationTitle(model.currentConversation?.title ?? "Mira")
                .toolbar {
                    ToolbarItem {
                        Button("新对话", systemImage: "square.and.pencil") { Task { await model.newConversation() } }
                            .keyboardShortcut("n", modifiers: .command)
                    }
                    ToolbarItem {
                        Button("执行详情", systemImage: "sidebar.right") { showsInspector.toggle() }
                            .disabled(model.executions.isEmpty)
                    }
                }
                .inspector(isPresented: $showsInspector) { ExecutionInspector(model: model).inspectorColumnWidth(min: 280, ideal: 340, max: 480) }
        }
        .frame(minWidth: 850, minHeight: 580)
        .task { await model.observe() }
        .sheet(isPresented: $showsWorkspaceSheet) { WorkspaceEditor(application: model.application, workspace: editingWorkspace) }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好", role: .cancel) { model.error = nil }
        } message: { Text(model.error?.message ?? "") }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle").font(.title).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mira").font(.title2.weight(.semibold))
                    Text(isDemo ? "本机演示 · 不发送网络请求" : "你的个人工作空间").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(20)
            List {
                Section("工作空间") {
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
                            .contextMenu { Button("编辑工作空间") { editingWorkspace = workspace; showsWorkspaceSheet = true } }
                    }
                    Button { editingWorkspace = nil; showsWorkspaceSheet = true } label: {
                        Label("创建工作空间", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                    }.buttonStyle(.plain)
                }
                Section {
                    ForEach(model.filteredConversations) { conversation in
                        Button { Task { await model.selectConversation(conversation.id) } } label: {
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
                                if !conversation.isArchived { Button("归档对话", systemImage: "archivebox") { Task { await model.archive(conversation.id) } } }
                            }
                    }
                    if model.filteredConversations.isEmpty { Text(model.showArchived ? "没有归档对话" : "还没有对话").font(.caption).foregroundStyle(.secondary) }
                } header: {
                    HStack {
                        Text(model.showArchived ? "已归档" : "对话")
                        Spacer()
                        Button { model.showArchived.toggle(); Task { await model.selectConversation(nil) } } label: { Image(systemName: model.showArchived ? "bubble.left.and.bubble.right" : "archivebox") }
                            .buttonStyle(.plain).help(model.showArchived ? "显示活动对话" : "显示归档对话")
                    }
                }
            }.listStyle(.sidebar)
            Divider()
            SettingsLink { Label("设置", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.plain).padding(18)
        }
    }
}

private struct ConversationDetail: View {
    @Bindable var model: ConversationModel
    let isDemo: Bool
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.messages.isEmpty && model.activeExecution == nil { welcome.frame(maxHeight: .infinity) }
            else { transcript }
            if let execution = model.executions.last, execution.status.isTerminal, execution.status != .completed {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(execution.error?.message ?? "回复已中断。").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if model.retryableExecution != nil { Button("重试最后回合") { Task { await model.retry() } } }
                }.padding(.horizontal, 28).padding(.vertical, 12)
            }
            if model.currentConversation?.isArchived == true {
                Label("此对话已归档", systemImage: "archivebox").foregroundStyle(.secondary).padding(20)
            } else { composer }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
    private var welcome: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkle").font(.system(size: 44, weight: .light)).foregroundStyle(.tint)
            Text("从一个想法开始").font(.largeTitle.weight(.semibold))
            Text(model.routes.isEmpty ? "先连接你自己的模型服务。\n对话保存在本机，发送时只使用你选择的连接。" : "整理思路、讨论项目，或提出一个问题。\n选择模型后，写下第一条消息。")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            if model.routes.isEmpty { SettingsLink { Label("连接模型服务", systemImage: "key").padding(.horizontal, 12) }.buttonStyle(.borderedProminent).controlSize(.large) }
            if isDemo { Label("演示回复由本机生成", systemImage: "desktopcomputer").font(.caption).foregroundStyle(.secondary) }
        }.padding(40).frame(maxWidth: .infinity)
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(model.messages) { message in
                        MessageRow(role: message.role, text: message.text, status: message.status).id(message.id)
                    }
                    if let execution = model.activeExecution {
                        MessageRow(role: .assistant, text: model.drafts[execution.id] ?? "", status: nil)
                    }
                    Color.clear.frame(height: 1).id("transcript-end")
                }.padding(28).frame(maxWidth: 860).frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.messages.count) { _, _ in proxy.scrollTo("transcript-end", anchor: .bottom) }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("对话模型", selection: $model.selectedRouteID) {
                    if model.routes.isEmpty { Text("尚未配置模型").tag(nil as RouteID?) }
                    ForEach(model.routes) { route in Text("\(route.name) · \(route.modelID)").tag(Optional(route.id)) }
                }.labelsHidden().frame(maxWidth: 320).disabled(model.activeExecution != nil)
                Spacer()
                if model.needsPersistenceRetry { Label("回复待保存", systemImage: "externaldrive.badge.exclamationmark").font(.caption).foregroundStyle(.orange) }
                else if model.activeExecution != nil { ProgressView().controlSize(.small); Text("正在生成").font(.caption).foregroundStyle(.secondary) }
            }
            TextField("发送消息…", text: $model.composer, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(3...8).font(.body).focused($composerFocused)
                .accessibilityLabel("消息输入框")
            HStack {
                Text(isDemo ? "本机演示" : "发送到所选模型服务 · ⌘ Return 发送")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if model.needsPersistenceRetry {
                    Button("重试保存", systemImage: "externaldrive") { Task { await model.retrySaving() } }.buttonStyle(.borderedProminent)
                } else if model.activeExecution != nil {
                    Button("停止", systemImage: "stop.fill") { Task { await model.cancel() } }.keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("发送", systemImage: "arrow.up") { Task { await model.send(); composerFocused = true } }
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
}

private struct MessageRow: View {
    let role: MessageRole
    let text: String
    let status: MessageStatus?
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: role == .user ? "person.crop.circle" : "sparkle")
                .font(.title3).foregroundStyle(role == .user ? Color.secondary : Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text(role == .user ? "你" : "Mira").font(.callout.weight(.semibold))
                    if let status, status != .committed { Text("未完成").font(.caption).foregroundStyle(.orange) }
                }
                if text.isEmpty && status == nil { Text("正在思考…").foregroundStyle(.secondary) }
                else { Text(text).textSelection(.enabled).lineSpacing(5).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .contain)
    }
}

private struct ExecutionInspector: View {
    @Bindable var model: ConversationModel
    @State private var requestText = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("执行详情").font(.headline)
                if let execution = model.executions.last {
                    LabeledContent("状态", value: execution.status.displayTitle)
                    LabeledContent("模型", value: execution.route.modelID)
                    LabeledContent("输入 Token", value: execution.usage.inputTokens.map(String.init) ?? "服务未提供")
                    LabeledContent("输出 Token", value: execution.usage.outputTokens.map(String.init) ?? "服务未提供")
                    Text("费用未估算；以服务商账单为准。").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("实际发送内容").font(.subheadline.weight(.semibold))
                    Text("仅在本机查看；不包含 API Key。").font(.caption).foregroundStyle(.secondary)
                    Text(requestText.isEmpty ? "尚未发送请求" : requestText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }.padding(20)
        }
        .task(id: model.executions.last?.updatedAt) {
            requestText = ""
            guard let execution = model.executions.last else { return }
            do {
                if let request = try await model.application.request(for: execution.id) {
                    requestText = "SYSTEM\n\(request.system)\n\n" + request.messages.map { "\($0.role.rawValue.uppercased())\n\($0.text)" }.joined(separator: "\n\n")
                }
            } catch { model.error = MiraError.safe(error) }
        }
    }
}
