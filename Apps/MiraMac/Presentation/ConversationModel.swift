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

/// A window owns navigation and a bounded set of mounted pages. Executions belong to the application.
@MainActor @Observable
final class ConversationModel {
    var workspaces: [Workspace] = []
    var conversations: [Conversation] = []
    var routes: [ModelRoute] = []
    var configuration = ModelConfiguration(connections: [], models: [], routes: [], bindings: [])
    var selectedWorkspaceID: WorkspaceID?
    var showArchived = false
    var memoryApprovals: [MemoryApprovalRequest] = []
    private(set) var activePage: ConversationPageState
    private(set) var retainedPages: [ConversationPageState]
    @ObservationIgnored let application: MiraApplication
    @ObservationIgnored private let pageLimit: Int
    @ObservationIgnored private var pages: [ConversationID: ConversationPageState] = [:]
    @ObservationIgnored private var draftPage: ConversationPageState?
    @ObservationIgnored private var recentIDs: [UUID] = []
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadVersion = 0
    @ObservationIgnored private(set) var snapshotLoadCount = 0

    init(application: MiraApplication, pageLimit: Int = 3) {
        self.application = application
        self.pageLimit = max(1, pageLimit)
        let draft = ConversationPageState()
        draft.isActive = true
        activePage = draft; retainedPages = [draft]; draftPage = draft
    }

    var selectedConversationID: ConversationID? { activePage.conversationID }
    var currentConversation: Conversation? { conversations.first { $0.id == selectedConversationID } }
    var filteredConversations: [Conversation] { conversations.filter { $0.workspaceID == selectedWorkspaceID && $0.isArchived == showArchived } }
    var error: MiraError? {
        get { activePage.error }
        set { activePage.error = newValue }
    }

    func observe() async {
        for await event in await application.events() {
            if Task.isCancelled { return }
            receive(event)
        }
    }

    func receive(_ event: ApplicationEvent) {
        switch event {
            case .changed:
                requestReload()
                for page in retainedPages where page.conversationID != nil { refresh(page) }
            case .conversationChanged(let id):
                requestReload()
                if let page = pages[id], retainedPages.contains(where: { $0 === page }) { refresh(page) }
            case .conversationContentInvalidated:
                invalidateContent()
            case .conversationFailure(let id, let failure):
                pages[id]?.error = failure
            case .draft(let id, let value):
                if let page = page(for: id) { page.streamBuffer.receiveDraft(value, for: id) }
            case .thinking(let id, let trace):
                if let page = page(for: id) { page.streamBuffer.receiveThinking(trace, for: id) }
            case .failure(let failure): error = failure
        }
    }

    func observeMemoryApprovals() async {
        for await requests in await application.memoryApprovalEvents() {
            if Task.isCancelled { return }
            memoryApprovals = requests
        }
    }

    /// An explicit refresh remains authoritative; activation itself never refreshes a loaded page.
    func reload() async {
        requestReload()
        await reloadTask?.value
        if activePage.conversationID != nil {
            refresh(activePage)
            await activePage.loadTask?.value
        }
    }

    func selectConversation(_ id: ConversationID?) async {
        guard let id else { activateDraft(); return }
        if id == selectedConversationID { return }
        let conversation = conversations.first { $0.id == id }
        let page = pages[id] ?? ConversationPageState(conversationID: id, workspaceID: conversation?.workspaceID)
        pages[id] = page
        selectedWorkspaceID = page.workspaceID
        showArchived = conversation?.isArchived ?? false
        activate(page)
        guard !page.isLoaded else { return }
        refresh(page)
        await page.loadTask?.value
    }

    func selectWorkspace(_ id: WorkspaceID?) async {
        selectedWorkspaceID = id
        await newConversation()
    }

    func newConversation() async {
        showArchived = false
        activateDraft()
    }

    private func activateDraft() {
        let draft = draftPage ?? ConversationPageState(workspaceID: selectedWorkspaceID)
        draftPage = draft
        draft.workspaceID = selectedWorkspaceID
        activate(draft)
    }

    private func activate(_ page: ConversationPageState) {
        guard activePage !== page else { return }
        activePage.isActive = false
        activePage = page
        page.isActive = true
        if !retainedPages.contains(where: { $0 === page }) { retainedPages.append(page) }
        recentIDs.removeAll { $0 == page.id }; recentIDs.append(page.id)
        trimPages()
    }

    private func trimPages() {
        while retainedPages.filter({ $0.conversationID != nil }).count > pageLimit {
            guard let candidate = recentIDs.compactMap({ id in retainedPages.first { $0.id == id } })
                .first(where: { $0 !== activePage && !$0.isSending && $0.conversationID != nil }) else { break }
            candidate.releaseContent()
            retainedPages.removeAll { $0 === candidate }
            recentIDs.removeAll { $0 == candidate.id }
        }
    }

    private func page(for executionID: ExecutionID) -> ConversationPageState? {
        retainedPages.first { $0.executions.contains { $0.id == executionID && !$0.status.isTerminal } }
    }

    private func requestReload() {
        reloadVersion &+= 1
        guard reloadTask == nil else { return }
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { reloadTask = nil }
            repeat {
                let version = reloadVersion
                let origin = activePage
                do {
                    let library = try await application.library(includeArchived: true)
                    guard version == reloadVersion else { continue }
                    workspaces = library.workspaces; conversations = library.conversations
                    configuration = library.configuration
                    routes = library.configuration.models(for: .conversation).map(\.route)
                    let available = Set(conversations.map(\.id))
                    for (id, page) in pages where !available.contains(id) && !page.isSending {
                        page.releaseContent()
                        retainedPages.removeAll { $0 === page }
                        pages[id] = nil
                        if activePage === page { await newConversation() }
                    }
                } catch {
                    if version == reloadVersion, activePage === origin { origin.error = MiraError.safe(error) }
                }
                if version == reloadVersion { break }
            } while !Task.isCancelled
        }
    }

    private func refresh(_ page: ConversationPageState) {
        guard page.conversationID != nil else { return }
        page.loadGeneration &+= 1
        page.needsReload = true
        page.isLoading = !page.isLoaded
        guard page.loadTask == nil else { return }
        page.loadTask = Task { @MainActor [weak self, weak page] in
            guard let self, let page else { return }
            while page.needsReload, !Task.isCancelled, let id = page.conversationID {
                page.needsReload = false
                let generation = page.loadGeneration
                do {
                    snapshotLoadCount &+= 1
                    let snapshot = try await application.conversation(id)
                    guard !Task.isCancelled, generation == page.loadGeneration else { continue }
                    page.apply(snapshot)
                } catch {
                    guard !Task.isCancelled, generation == page.loadGeneration else { continue }
                    page.isLoading = false; page.error = MiraError.safe(error)
                }
            }
            if !Task.isCancelled { page.loadTask = nil }
        }
    }

    private func invalidateContent() {
        for page in pages.values { page.releaseContent() }
        for page in retainedPages where page.conversationID != nil { refresh(page) }
    }

    func send() async { await send(activePage) }

    func send(_ page: ConversationPageState) async {
        guard !page.isSending else { return }
        guard page.selectedRouteID.map({ selected in routes.contains { $0.id == selected } }) ?? true else {
            page.error = MiraError(.configuration, "Choose an available model or use the default model before sending.")
            return
        }
        let routeID = page.selectedRouteID, input = page.composer
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        page.isSending = true
        defer { page.isSending = false; trimPages() }
        do {
            if let id = page.conversationID {
                _ = try await application.send(conversationID: id, text: input, routeID: routeID)
            } else {
                let execution = try await application.startConversation(workspaceID: page.workspaceID, text: input, routeID: routeID)
                page.conversationID = execution.conversationID
                pages[execution.conversationID] = page
                if draftPage === page { draftPage = nil }
                recentIDs.removeAll { $0 == page.id }; recentIDs.append(page.id)
            }
            if page.composer == input { page.composer = "" }
            requestReload()
            refresh(page)
            await page.loadTask?.value
        } catch { page.error = MiraError.safe(error) }
    }

    func cancel(_ page: ConversationPageState) async {
        if let execution = page.activeExecution { await application.cancel(execution.id) }
    }
    func retrySaving(_ page: ConversationPageState) async {
        guard let execution = page.activeExecution else { return }
        do { try await application.retryPendingSave(execution.id); refresh(page); await page.loadTask?.value }
        catch { page.error = MiraError(.storage, "The reply could not be saved. Check disk space and library permissions.") }
    }
    func retry(_ page: ConversationPageState) async {
        guard let execution = page.retryableExecution else { return }
        do { _ = try await application.retry(execution.id, routeID: page.selectedRouteID); refresh(page); await page.loadTask?.value }
        catch { page.error = MiraError.safe(error) }
    }
    func archive(_ id: ConversationID) async {
        do {
            try await application.archiveConversation(id)
            if id == selectedConversationID { await newConversation() }
            requestReload(); await reloadTask?.value
        } catch { self.error = MiraError.safe(error) }
    }
}
