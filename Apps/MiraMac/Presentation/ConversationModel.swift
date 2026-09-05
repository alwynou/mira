import Foundation
import Observation
import MiraCore

extension ExecutionStatus {
    var displayTitle: String {
        switch self {
        case .queued: "等待发送"
        case .waitingForModel: "正在生成"
        case .completed: "已完成"
        case .failed: "失败"
        case .cancelled: "已停止"
        case .interrupted: "已中断"
        }
    }
}

@MainActor @Observable
final class ConversationModel {
    var workspaces: [Workspace] = []
    var conversations: [Conversation] = []
    var routes: [ModelRoute] = []
    var messages: [Message] = []
    var executions: [Execution] = []
    var drafts: [ExecutionID: String] = [:]
    var pendingSaveIDs: Set<ExecutionID> = []
    var selectedWorkspaceID: WorkspaceID?
    var selectedConversationID: ConversationID?
    var selectedRouteID: RouteID?
    var composer = ""
    var error: MiraError?
    var isSending = false
    var showArchived = false
    @ObservationIgnored let application: MiraApplication
    @ObservationIgnored private var selectionGeneration = 0

    init(application: MiraApplication) { self.application = application }
    var currentConversation: Conversation? { conversations.first { $0.id == selectedConversationID } }
    var activeExecution: Execution? { executions.last { !$0.status.isTerminal } }
    var needsPersistenceRetry: Bool { activeExecution.map { pendingSaveIDs.contains($0.id) } ?? false }
    var retryableExecution: Execution? {
        guard let last = executions.last, last.status.isTerminal, last.status != .completed,
              messages.last(where: { $0.role == .user })?.id == last.triggerMessageID else { return nil }
        return last
    }
    var filteredConversations: [Conversation] { conversations.filter { $0.workspaceID == selectedWorkspaceID && $0.isArchived == showArchived } }

    func observe() async {
        let stream = await application.events()
        for await event in stream {
            if Task.isCancelled { return }
            switch event {
            case .changed: await reload()
            case .draft(let id, let value): if executions.contains(where: { $0.id == id }) { drafts[id] = value }
            case .failure(let failure): error = failure
            }
        }
    }
    func reload() async {
        do {
            let library = try await application.library(includeArchived: true)
            workspaces = library.workspaces; conversations = library.conversations; routes = library.routes
            if !routes.contains(where: { $0.id == selectedRouteID }) { selectedRouteID = routes.first?.id }
            if let id = selectedConversationID { try await loadConversation(id) }
        } catch { self.error = MiraError.safe(error) }
    }
    func selectConversation(_ id: ConversationID?) async {
        selectionGeneration += 1; selectedConversationID = id
        messages = []; executions = []; drafts = [:]; pendingSaveIDs = []; composer = ""
        guard let id else { return }
        do { try await loadConversation(id) } catch { self.error = MiraError.safe(error) }
    }
    private func loadConversation(_ id: ConversationID) async throws {
        let generation = selectionGeneration
        let state = try await application.conversation(id)
        guard generation == selectionGeneration, selectedConversationID == id else { return }
        messages = state.messages; executions = state.executions
        drafts = Dictionary(uniqueKeysWithValues: state.drafts.map { ($0.executionID, $0.text) })
        pendingSaveIDs = state.pendingSaveIDs
    }
    func newConversation() async {
        do {
            let id = try await application.createConversation(workspaceID: selectedWorkspaceID)
            showArchived = false; await reload(); await selectConversation(id)
        } catch { self.error = MiraError.safe(error) }
    }
    func send() async {
        guard !isSending, let routeID = selectedRouteID else { error = MiraError(.configuration, "请先在设置中配置模型服务。"); return }
        let input = composer
        let originalSelection = selectedConversationID
        let originalWorkspace = selectedWorkspaceID
        let generation = selectionGeneration
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            let id: ConversationID
            if let originalSelection { id = originalSelection }
            else { id = try await application.createConversation(workspaceID: originalWorkspace) }
            _ = try await application.send(conversationID: id, text: input, routeID: routeID)
            if generation == selectionGeneration {
                if composer == input { composer = "" }
                if originalSelection == nil { selectedConversationID = id }
            }
            await reload()
        } catch { self.error = MiraError.safe(error) }
    }
    func cancel() async { if let activeExecution { await application.cancel(activeExecution.id) } }
    func retrySaving() async {
        guard let activeExecution else { return }
        do { try await application.retryPendingSave(activeExecution.id); await reload() }
        catch { self.error = MiraError(.storage, "回复仍未能保存，请检查磁盘空间和资料库权限。") }
    }
    func retry() async {
        guard let execution = retryableExecution, let routeID = selectedRouteID else { return }
        do { _ = try await application.retry(execution.id, routeID: routeID); await reload() }
        catch { self.error = MiraError.safe(error) }
    }
    func archive(_ id: ConversationID) async {
        do { try await application.archiveConversation(id); await selectConversation(nil); await reload() }
        catch { self.error = MiraError.safe(error) }
    }
}
