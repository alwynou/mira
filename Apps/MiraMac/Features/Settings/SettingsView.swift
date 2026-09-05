import AppKit
import SwiftUI
import MiraCore
import MiraProviders

struct SettingsView: View {
    let container: AppContainer
    @State private var routes: [ModelRoute] = []
    @State private var selectedID: RouteID?
    @State private var editing: ModelRoute?
    @State private var showEditor = false
    @State private var status = ""
    @State private var diagnostics: StorageDiagnostics?
    @State private var isWorking = false
    @State private var probeTask: Task<Void, Never>?

    var body: some View {
        TabView {
            Tab("模型服务", systemImage: "network") { providerSettings }
            Tab("数据", systemImage: "externaldrive") { dataSettings }
        }.padding(20).frame(width: 720, height: 560)
            .task {
                guard let application = container.application else { return }
                for await _ in await application.events() {
                    if Task.isCancelled { return }
                    do { routes = try await application.library().routes; diagnostics = try await application.diagnostics() }
                    catch { status = MiraError.safe(error).message }
                }
            }
            .sheet(isPresented: $showEditor) { ProviderEditor(container: container, existing: editing) }
            .onDisappear { probeTask?.cancel() }
    }

    private var providerSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接你自己的模型").font(.title2.weight(.semibold))
            Text("首批支持 OpenAI Chat Completions 兼容接口和 Anthropic Messages。API Key 仅存入本机 Keychain，连接不会自动发送测试请求。")
                .font(.callout).foregroundStyle(.secondary)
            List(selection: $selectedID) {
                ForEach(routes) { route in
                    HStack {
                        Image(systemName: "network").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(route.name).font(.headline)
                            Text(route.modelID).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(route.contextWindow.map { "窗口 \($0)" } ?? "窗口待配置").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6).tag(route.id)
                }
            }.overlay {
                if routes.isEmpty { ContentUnavailableView("尚未连接模型", systemImage: "key", description: Text("添加连接后，在对话中选择它。")) }
            }
            HStack {
                Button("添加连接", systemImage: "plus") { editing = nil; showEditor = true }
                Button("编辑") { editing = routes.first { $0.id == selectedID }; showEditor = true }.disabled(selectedID == nil)
                Button("检测文本") { runProbe(.text) }.disabled(selectedID == nil || isWorking)
                Button("检测工具") { runProbe(.tools) }.disabled(selectedID == nil || isWorking)
                if probeTask != nil { Button("取消检测") { probeTask?.cancel() } }
                Spacer()
                Button("移除", role: .destructive) {
                    guard let route = routes.first(where: { $0.id == selectedID }) else { return }
                    Task { do { try await container.removeRoute(route); selectedID = nil } catch { status = MiraError.safe(error).message } }
                }.disabled(selectedID == nil || container.isDemo)
            }
            Text("当前路线用于对话；提取、压缩与 Embedding 用途会随对应里程碑开放。").font(.caption).foregroundStyle(.secondary)
            Text("检测仅发送固定合成提示，不包含个人历史；所选模型服务可能收取少量 API 费用。").font(.caption).foregroundStyle(.secondary)
            if let route = routes.first(where: { $0.id == selectedID }), let observation = route.probeObservation {
                let kindName = observation.type == .text ? "文本" : "工具"
                Text("最近\(kindName)检测：\(observation.state == .verified ? "通过" : "失败") · \(observation.checkedAt, format: .dateTime)")
                    .font(.caption).foregroundStyle(observation.state == .verified ? .green : .orange)
                if let error = observation.error { Text(error.message).font(.caption).foregroundStyle(.secondary) }
            }
            if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.secondary) }
        }.padding(.top, 16)
    }
    private func runProbe(_ kind: CapabilityProbeKind) {
        guard let route = routes.first(where: { $0.id == selectedID }) else { return }
        isWorking = true
        status = "正在检测（只发送固定合成内容，不包含历史对话）…"
        probeTask = Task {
            let observation = await container.probe(route, kind: kind)
            defer { isWorking = false; probeTask = nil }
            guard !Task.isCancelled else { status = "检测已取消，能力状态未改变。"; return }
            guard observation.state != .unknown else {
                status = observation.error?.message ?? "能力检测失败。"
                return
            }
            do { try await container.saveProbe(observation, for: route); status = observation.state == .verified ? "检测成功，已保存能力状态。" : (observation.error?.message ?? "能力检测失败，已记录状态。") }
            catch { status = MiraError.safe(error).message }
        }
    }

    private var dataSettings: some View {
        Form {
            Section("本地资料库") {
                LabeledContent("目录") { Text(container.directory.path).textSelection(.enabled).lineLimit(3) }
                if let diagnostics {
                    LabeledContent("SQLite", value: diagnostics.sqliteVersion)
                    LabeledContent("FTS5 / Trigram", value: "\(diagnostics.supportsFTS5 ? "可用" : "不可用") / \(diagnostics.supportsTrigram ? "可用" : "不可用")")
                }
                Text("此阶段建议使用可丢弃资料。完整记忆、资料文件和长期恢复验收尚在后续里程碑。").font(.caption).foregroundStyle(.secondary)
                if let message = container.maintenanceMessage {
                    Text(message).font(.callout).foregroundStyle(.orange)
                    Button("重试凭据清理") { Task { await container.retryCredentialCleanup() } }
                }
            }
            Section("备份与恢复") {
                Text("备份包含对话、配置和本地请求记录，不含 API Key。请妥善保存备份文件。恢复会创建新的隔离目录，保留当前资料库。")
                HStack {
                    Button("导出资料库备份…") { exportBackup() }
                    Button("恢复到新目录…") { restoreBackup() }
                }.disabled(isWorking)
                if !status.isEmpty { Text(status).font(.callout).textSelection(.enabled) }
            }
        }.formStyle(.grouped)
    }
    private func exportBackup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Mira-backup.sqlite"; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do { try await container.application?.exportBackup(to: url); status = "备份已保存。" }
            catch { status = MiraError.safe(error).message }
        }
    }
    private func restoreBackup() {
        let sourcePanel = NSOpenPanel(); sourcePanel.canChooseDirectories = false; sourcePanel.allowsMultipleSelection = false
        sourcePanel.message = "选择 Mira 资料库备份"
        guard sourcePanel.runModal() == .OK, let source = sourcePanel.url else { return }
        let folderPanel = NSOpenPanel(); folderPanel.canChooseDirectories = true; folderPanel.canChooseFiles = false
        folderPanel.canCreateDirectories = true; folderPanel.message = "选择恢复目录的父目录；Mira 会在其中新建独立目录"
        guard folderPanel.runModal() == .OK, let parent = folderPanel.url else { return }
        let destination = parent.appendingPathComponent("Mira-Restored-\(UUID().uuidString.prefix(8))", isDirectory: true)
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await container.application?.restoreBackup(from: source, to: destination)
                status = "验证并恢复完成：\(destination.path)。当前资料库保持打开；切换步骤见开发文档。"
            } catch { status = MiraError.safe(error).message }
        }
    }
}

private struct ProviderEditor: View {
    @Environment(\.dismiss) private var dismiss
    let container: AppContainer
    let existing: ModelRoute?
    @State private var name = ""
    @State private var kind = ProviderKind.openAICompatible
    @State private var baseURL = "https://api.openai.com/v1"
    @State private var modelID = ""
    @State private var apiKey = ""
    @State private var contextWindow = ""
    @State private var maxOutputTokens = "1024"
    @State private var allowsHTTP = false
    @State private var requestsUsage = true
    @State private var confirmsText = false
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "添加模型连接" : "编辑模型连接").font(.title2.weight(.semibold))
            Form {
                TextField("名称", text: $name)
                Picker("协议", selection: Binding(get: { kind }, set: { newKind in
                    guard kind != newKind else { return }
                    kind = newKind
                    baseURL = newKind == .anthropic ? "https://api.anthropic.com" : "https://api.openai.com/v1"
                })) {
                    Text("OpenAI Chat Completions 兼容").tag(ProviderKind.openAICompatible)
                    Text("Anthropic Messages").tag(ProviderKind.anthropic)
                }
                TextField("Base URL", text: $baseURL)
                TextField("Model ID", text: $modelID)
                SecureField(existing == nil ? "API Key" : "新 API Key（留空保留）", text: $apiKey)
                TextField("上下文窗口（Token）", text: $contextWindow)
                TextField("最大输出（Token）", text: $maxOutputTokens)
                Toggle("我已确认模型支持流式文本对话", isOn: $confirmsText)
                if kind == .openAICompatible { Toggle("请求流式 Token 用量（服务需支持 include_usage）", isOn: $requestsUsage) }
                Toggle("允许明确配置的本机 HTTP 服务", isOn: $allowsHTTP)
            }
            Text("Model ID 可手工填写；窗口未知时可以保存连接，发送前必须补齐。此阶段不自动推断工具能力。保存连接不会产生模型费用。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { apiKey = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { Task { await save() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || name.isEmpty || modelID.isEmpty || container.isDemo)
            }
        }.padding(28).frame(width: 590)
            .onAppear { load() }
    }
    private func load() {
        guard let existing else { return }
        name = existing.name; kind = existing.providerKind; baseURL = existing.baseURL
        modelID = existing.modelID; contextWindow = existing.contextWindow.map(String.init) ?? ""
        maxOutputTokens = String(existing.maxOutputTokens); allowsHTTP = existing.allowsLoopbackHTTP
        requestsUsage = existing.requestsUsage; confirmsText = existing.textCapability == .declared || existing.textCapability == .verified
    }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            let windowText = contextWindow.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let output = Int(maxOutputTokens), output > 0,
                  windowText.isEmpty || (Int(windowText).map { $0 > output && $0 <= 10_000_000 } ?? false) else { throw MiraError(.configuration, "请输入有效的 Token 数；最大输出须小于上下文窗口。") }
            var route = ModelRoute(id: existing?.id ?? .init(), revision: (existing?.revision ?? 0) + 1,
                                   name: name.trimmingCharacters(in: .whitespacesAndNewlines), providerKind: kind,
                                   baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines), modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines),
                                   credentialReference: existing?.credentialReference ?? UUID().uuidString,
                                   credentialVersion: existing?.credentialVersion ?? 1, contextWindow: Int(windowText), maxOutputTokens: output,
                                   textCapability: confirmsText ? .declared : .unknown, allowsLoopbackHTTP: allowsHTTP, requestsUsage: requestsUsage)
            if let existing, existing.providerKind == route.providerKind, existing.baseURL == route.baseURL,
               existing.modelID == route.modelID, existing.contextWindow == route.contextWindow,
               existing.maxOutputTokens == route.maxOutputTokens, existing.allowsLoopbackHTTP == route.allowsLoopbackHTTP,
               existing.requestsUsage == route.requestsUsage, apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                route.toolCapability = existing.toolCapability
                // Changing an explicit declaration invalidates an observation only for that dimension.
                if confirmsText == (existing.textCapability == .verified || existing.textCapability == .declared) {
                    route.textCapability = existing.textCapability; route.probeObservation = existing.probeObservation
                }
            }
            _ = try route.validatedEndpoint()
            try await container.saveRoute(route, previous: existing, secret: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            apiKey = ""; dismiss()
        } catch { self.error = MiraError.safe(error).message }
    }
}
