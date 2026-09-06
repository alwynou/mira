import Foundation
import Observation
import MiraCore

extension ExecutionStatus {
    var displayTitle: String {
        switch self {
        case .queued: "Queued"
        case .waitingForModel: "Generating"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        case .interrupted: "Interrupted"
        }
    }
}

@MainActor @Observable
final class ConversationModel {
    var workspaces: [Workspace] = []
    var conversations: [Conversation] = []
    var routes: [ModelRoute] = []
    var configuration = ModelConfiguration(connections: [], models: [], routes: [], bindings: [])
    var messages: [Message] = []
    var executions: [Execution] = []
    var memoryNotices: [ExecutionID: [MemoryContextNotice]] = [:]
    let streamBuffer = ConversationStreamBuffer()
    var pendingSaveIDs: Set<ExecutionID> = []
    var selectedWorkspaceID: WorkspaceID?
    var selectedConversationID: ConversationID?
    var selectedRouteID: RouteID?
    var composer = ""
    var error: MiraError?
    var isSending = false
    var inspectionRevision = 0
    var showArchived = false
    var memoryApprovals: [MemoryApprovalRequest] = []
    @ObservationIgnored let application: MiraApplication
    @ObservationIgnored private var selectionGeneration = 0

    init(application: MiraApplication) { self.application = application }
    var selectedModelUnavailable: Bool { selectedRouteID.map { selected in !routes.contains { $0.id == selected } } ?? false }
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
            case .draft(let id, let value):
                if executions.contains(where: { $0.id == id && !$0.status.isTerminal }) { streamBuffer.receiveDraft(value, for: id) }
            case .thinking(let id, let trace):
                if executions.contains(where: { $0.id == id && !$0.status.isTerminal }) { streamBuffer.receiveThinking(trace, for: id) }
            case .failure(let failure): error = failure
            }
        }
    }
    func observeMemoryApprovals() async {
        for await requests in await application.memoryApprovalEvents() {
            if Task.isCancelled { return }
            memoryApprovals = requests
        }
    }
    func reload() async {
        do {
            let library = try await application.library(includeArchived: true)
            workspaces = library.workspaces; conversations = library.conversations; routes = library.configuration.models(for: .conversation).map(\.route); configuration = library.configuration
            if let id = selectedConversationID { try await loadConversation(id) }
        } catch { self.error = MiraError.safe(error) }
    }
    func selectConversation(_ id: ConversationID?) async {
        selectionGeneration += 1; selectedConversationID = id
        messages = []; executions = []; memoryNotices = [:]; streamBuffer.replace(drafts: [:], thinkingTraces: [:]); pendingSaveIDs = []; composer = ""; selectedRouteID = nil
        guard let id else { return }
        if let conversation = conversations.first(where: { $0.id == id }) {
            selectedWorkspaceID = conversation.workspaceID
            showArchived = conversation.isArchived
        }
        do { try await loadConversation(id) } catch { self.error = MiraError.safe(error) }
    }
    private func loadConversation(_ id: ConversationID) async throws {
        let generation = selectionGeneration
        let state = try await application.conversation(id)
        guard generation == selectionGeneration, selectedConversationID == id else { return }
        messages = state.messages; executions = state.executions; memoryNotices = state.memoryNotices
        streamBuffer.replace(
            drafts: Dictionary(uniqueKeysWithValues: state.drafts.map { ($0.executionID, $0.text) }),
            thinkingTraces: Dictionary(uniqueKeysWithValues: state.drafts.map { ($0.executionID, $0.trace) })
        )
        pendingSaveIDs = state.pendingSaveIDs
        inspectionRevision += 1
    }
    func newConversation() async {
        do {
            let id = try await application.createConversation(workspaceID: selectedWorkspaceID)
            showArchived = false; await reload(); await selectConversation(id)
        } catch { self.error = MiraError.safe(error) }
    }
    func send() async {
        guard !isSending else { return }
        guard !selectedModelUnavailable else {
            error = MiraError(.configuration, "Choose an available model or use the default model before sending.")
            return
        }
        let routeID = selectedRouteID
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
        catch { self.error = MiraError(.storage, "The reply could not be saved. Check disk space and library permissions.") }
    }
    func retry() async {
        guard let execution = retryableExecution else { return }
        let routeID = selectedRouteID
        do { _ = try await application.retry(execution.id, routeID: routeID); await reload() }
        catch { self.error = MiraError.safe(error) }
    }
    func archive(_ id: ConversationID) async {
        do { try await application.archiveConversation(id); await selectConversation(nil); await reload() }
        catch { self.error = MiraError.safe(error) }
    }
}
