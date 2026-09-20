import Foundation
import MiraCore
import Observation

struct ConversationRouteChoice: Identifiable, Sendable, Equatable {
    let candidate: AgentModelRouteCandidate
    var id: RouteID { candidate.preset.id }
    var name: String { candidate.model.displayName ?? candidate.model.modelID }
    var title: String { "\(name) · \(candidate.connection.name)" }
}

/// Window navigation owns presentation work; the library owns every accepted execution.
@MainActor @Observable
final class ConversationModel {
    private(set) var workspaces: [Workspace] = []
    private(set) var conversations: [SessionQueryItem] = []
    private(set) var routes: [ConversationRouteChoice] = []
    private(set) var approvals: [RuntimeApprovalRequest] = []
    private(set) var workgroup: MacLibraryWorkloads?
    private(set) var activePage: ConversationPageState
    private(set) var retainedPages: [ConversationPageState]
    private(set) var hasMoreConversations = false
    var selectedWorkspaceID: WorkspaceID? {
        didSet { if selectedWorkspaceID != oldValue { requestReload() } }
    }
    var showArchived = false {
        didSet { if showArchived != oldValue { requestReload() } }
    }
    @ObservationIgnored let library: MacLibrary
    let modelPreferences: ConversationModelPreferences
    @ObservationIgnored private let instructions: String
    @ObservationIgnored private let pageLimit: Int
    @ObservationIgnored private var pages: [ConversationID: ConversationPageState] = [:]
    @ObservationIgnored private var draftPage: ConversationPageState?
    @ObservationIgnored private var recentIDs: [UUID] = []
    @ObservationIgnored private var bindingID = UUID()
    @ObservationIgnored private var sourceRevealID = UUID()
    @ObservationIgnored private var libraryGeneration: UInt64?
    @ObservationIgnored private var observationID: UUID?
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var retiring: [Task<Void, Never>] = []
    @ObservationIgnored private var retirementTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadVersion = 0
    @ObservationIgnored private var listCursor: SessionListCursor?
    @ObservationIgnored private var pendingArchives: [ConversationID: (commandID: UUID, runtimeID: UUID)] = [:]
    @ObservationIgnored private var archiving: Set<ConversationID> = []
    @ObservationIgnored private(set) var snapshotLoadCount = 0

    init(
        library: MacLibrary, pageLimit: Int = 3,
        modelPreferences: ConversationModelPreferences = .shared,
        instructions: String =
            "You are Mira, a personal assistant. Reply in the user's requested language, otherwise the language of their message. Use tools when needed and preserve source citations."
    ) {
        self.library = library
        self.modelPreferences = modelPreferences
        self.pageLimit = max(1, pageLimit)
        self.instructions = instructions
        let draft = ConversationPageState()
        draft.isActive = true
        activePage = draft
        retainedPages = [draft]
        draftPage = draft
    }

    var isReady: Bool { workgroup != nil }
    var selectedConversationID: ConversationID? { activePage.conversationID }
    var currentConversation: SessionQueryItem? { activePage.session }
    var filteredConversations: [SessionQueryItem] {
        conversations.filter { $0.summary.workspaceID == selectedWorkspaceID && $0.summary.isArchived == showArchived }
    }
    var error: MiraError? {
        get { activePage.error }
        set { activePage.error = newValue }
    }

    /// One task per window. Ending it drains presentation subscriptions without cancelling executions.
    func observe() async {
        guard observationID == nil else { return }
        let run = UUID()
        observationID = run
        for await status in await library.observe() {
            guard !Task.isCancelled, observationID == run else { break }
            if status.phase == .ready {
                guard libraryGeneration != status.generation || workgroup == nil else { continue }
                do {
                    let binding = try await library.binding()
                    _ = try await binding.workgroup.modelSettings.ensureConversationDefault()
                    guard !Task.isCancelled, observationID == run else { break }
                    unbind()
                    libraryGeneration = binding.status.generation
                    workgroup = binding.workgroup
                    startObservers(binding.workgroup, token: bindingID)
                    requestReload()
                    for page in retainedPages where page.conversationID != nil { mount(page) }
                } catch {
                    if observationID == run, !Task.isCancelled { self.error = MiraError.safe(error) }
                }
            } else {
                unbind()
                if let failure = status.failure { error = failure }
            }
        }
        guard observationID == run else { return }
        observationID = nil
        unbind()
        await retirementTask?.value
    }

    private func startObservers(_ group: MacLibraryWorkloads, token: UUID) {
        observers.append(
            Task { @MainActor [weak self] in
                do {
                    for await snapshot in try await group.application.observe() {
                        guard !Task.isCancelled, let self, bindingID == token else { return }
                        for page in retainedPages {
                            page.pendingSaveIDs = Set(
                                snapshot.settlementFailures.keys
                                    .filter { $0.sessionID == page.conversationID }.map(\.executionID))
                        }
                        requestReload()
                    }
                } catch {
                    guard !Task.isCancelled, let self, bindingID == token else { return }
                    self.error = MiraError.safe(error)
                }
            })
        observers.append(
            Task { @MainActor [weak self] in
                do {
                    for await change in try await group.changes.observe() {
                        guard !Task.isCancelled, let self, bindingID == token else { return }
                        if change.isClosed {
                            unbind()
                            return
                        }
                        requestReload()
                        for page in retainedPages where page.isLoaded { refreshNotices(page) }
                    }
                } catch {
                    guard !Task.isCancelled, let self, bindingID == token else { return }
                    self.error = MiraError.safe(error)
                }
            })
        observers.append(
            Task { @MainActor [weak self] in
                for await requests in await group.approvals.snapshots() {
                    guard !Task.isCancelled, let self, bindingID == token else { return }
                    approvals = requests
                }
            })
    }

    private func unbind() {
        bindingID = UUID()
        workgroup = nil
        libraryGeneration = nil
        observers.forEach { $0.cancel() }
        retiring += observers
        observers = []
        reloadVersion &+= 1
        if let reloadTask {
            reloadTask.cancel()
            retiring.append(reloadTask)
        }
        reloadTask = nil
        for page in allPages { retiring += page.releaseContent() }
        workspaces = []
        conversations = []
        routes = []
        approvals = []
        listCursor = nil
        hasMoreConversations = false
        scheduleRetirement()
    }

    private var allPages: [ConversationPageState] {
        var result = Array(pages.values)
        if let draftPage, !result.contains(where: { $0 === draftPage }) { result.append(draftPage) }
        return result
    }

    private func scheduleRetirement() {
        guard retirementTask == nil, !retiring.isEmpty else { return }
        retirementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !retiring.isEmpty {
                let tasks = retiring
                retiring = []
                for task in tasks { await task.value }
            }
            retirementTask = nil
        }
    }

    func reload() async {
        requestReload()
        await reloadTask?.value
        if activePage.conversationID != nil {
            mount(activePage)
            refresh(activePage)
            await activePage.loadTask?.value
        }
    }

    private func requestReload() {
        reloadVersion &+= 1
        guard let group = workgroup, reloadTask == nil else { return }
        let token = bindingID
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if bindingID == token { reloadTask = nil } }
            repeat {
                let version = reloadVersion
                let workspace = selectedWorkspaceID
                let archived = showArchived
                do {
                    // The application stream is a coalesced hint. The query service owns bounded catch-up.
                    try await group.queries.synchronizeLibrary()
                    let workspaceValues = try await group.workspaces.workspaces()
                    let presets = try await group.modelSettings.presets(modelID: nil, after: nil, limit: 128)
                    var routeChoices: [ConversationRouteChoice] = []
                    for preset in presets {
                        try Task.checkCancellation()
                        do {
                            let candidate = try await group.modelSettings.candidate(routeID: preset.id)
                            guard candidate.preset.id.rawValue == candidate.model.id.rawValue else { continue }
                            try candidate.validate()
                            routeChoices.append(.init(candidate: candidate))
                        } catch let error as MiraError
                            where [.notFound, .configuration, .conflict].contains(error.code)
                        {
                            // Deleted or stale presets are unavailable; resolving again at send remains authoritative.
                            continue
                        }
                    }
                    let rows = try await group.queries.sessions(
                        scope: workspace.map(SessionQueryScope.workspace) ?? .inbox, includeArchived: archived)
                    guard !Task.isCancelled, bindingID == token else { return }
                    guard version == reloadVersion else { continue }
                    workspaces = workspaceValues
                    routes = routeChoices.sorted {
                        ($0.candidate.connection.name, $0.name, $0.id.rawValue.uuidString)
                            < ($1.candidate.connection.name, $1.name, $1.id.rawValue.uuidString)
                    }
                    if activePage.conversationID == nil, activePage.selectedRouteID == nil {
                        await initializeModel(activePage)
                    }
                    conversations = rows
                    listCursor = rows.last.map { .init(updatedAt: $0.summary.updatedAt, sessionID: $0.id) }
                    hasMoreConversations = rows.count == 128
                } catch {
                    guard !Task.isCancelled, bindingID == token else { return }
                    if version == reloadVersion { self.error = MiraError.safe(error) }
                }
                if version == reloadVersion { break }
            } while !Task.isCancelled
        }
    }

    func loadMoreConversations() async {
        guard hasMoreConversations, let after = listCursor, let group = workgroup else { return }
        let token = bindingID
        let version = reloadVersion
        do {
            let rows = try await group.queries.sessions(
                scope: selectedWorkspaceID.map(SessionQueryScope.workspace) ?? .inbox,
                includeArchived: showArchived, after: after)
            guard !Task.isCancelled, bindingID == token, version == reloadVersion, listCursor == after else { return }
            let existing = Set(conversations.map(\.id))
            conversations += rows.filter { !existing.contains($0.id) }
            listCursor = rows.last.map { .init(updatedAt: $0.summary.updatedAt, sessionID: $0.id) }
            hasMoreConversations = rows.count == 128
        } catch { if bindingID == token, !Task.isCancelled { self.error = MiraError.safe(error) } }
    }

    func selectConversation(_ id: ConversationID?) async {
        sourceRevealID = UUID()
        guard let id else {
            activateDraft()
            await initializeModel(activePage)
            return
        }
        if id == selectedConversationID { return }
        let session = conversations.first { $0.id == id }
        let page = pages[id] ?? ConversationPageState(conversationID: id, workspaceID: session?.summary.workspaceID)
        pages[id] = page
        selectedWorkspaceID = page.workspaceID
        showArchived = session?.summary.isArchived ?? false
        activate(page)
        mount(page)
        if page.isLoaded { refreshNotices(page) }
        if !page.isLoaded {
            refresh(page)
            await page.loadTask?.value
        }
    }

    /// Opens the authorized original user turn for a memory source.
    ///
    /// The source reference is checked against the journal-backed application
    /// snapshot before any page is selected. Both reads are bounded; a second
    /// read around the admission sequence makes older turns reachable without
    /// walking the conversation history.
    @discardableResult
    func revealMemorySource(_ reference: SessionEvidenceReference) async -> Bool {
        guard let group = workgroup, let generation = libraryGeneration else {
            activePage.error = MiraError(.busy, "The conversation library is not ready.")
            return false
        }
        let token = bindingID
        let reveal = UUID()
        let originPage = activePage
        sourceRevealID = reveal
        guard await isCurrentSourceReveal(reveal, binding: token, generation: generation, origin: originPage) else {
            return false
        }

        do {
            try reference.validate()
            guard reference.admissionSequence < Int64.max else {
                throw MiraError(.unauthorized, "The original user message is unavailable.")
            }
            let state = try await group.application.sessionSnapshot(id: reference.sessionID)
            guard await isCurrentSourceReveal(reveal, binding: token, generation: generation, origin: originPage) else { return false }
            guard state.id == reference.sessionID,
                let execution = state.executions[reference.originalExecutionID],
                execution.admission.executionID == reference.originalExecutionID,
                execution.admission.userMessageID == reference.userMessageID,
                execution.admissionEventID == reference.admissionEventID,
                execution.admissionSequence == reference.admissionSequence,
                execution.admission.retryOfExecutionID == nil,
                execution.admission.userBody?.kind == .userText
            else {
                throw MiraError(.unauthorized, "The original user message is unavailable.")
            }

            let authorizedWorkspaces = try await group.workspaces.workspaces()
            guard await isCurrentSourceReveal(reveal, binding: token, generation: generation, origin: originPage) else { return false }
            if let workspaceID = state.header?.workspaceID,
                !authorizedWorkspaces.contains(where: { $0.id == workspaceID })
            {
                throw MiraError(.unauthorized, "The source workspace is no longer available.")
            }

            var contiguousPages: [SessionQueryMessagePage]?
            for _ in 0..<2 {
                let headPage = try await group.queries.messagePage(sessionID: reference.sessionID, limit: 128)
                guard await isCurrentSourceReveal(reveal, binding: token, generation: generation, origin: originPage) else { return false }
                guard let headSession = headPage.session,
                    headSession.summary.id == reference.sessionID,
                    headSession.summary.workspaceID == state.header?.workspaceID
                else {
                    throw MiraError(.unauthorized, "The original user message is unavailable.")
                }

                var pages = [headPage]
                var oldestSequence = headPage.messages.map { $0.summary.sequence }.min()
                var reachedSource = false
                var changedHead = false
                while !reachedSource {
                    if pages.contains(where: { page in page.messages.contains { $0.id == reference.userMessageID } }) {
                        reachedSource = true
                        break
                    }
                    guard let before = oldestSequence, pages.last?.hasMore == true else { break }
                    guard pages.count < Self.memorySourceMaximumPages else {
                        throw MiraError(
                            .outputLimit,
                            "This source is too far back to open in the conversation. Open the original conversation and load earlier messages.")
                    }
                    let olderPage = try await group.queries.messagePage(
                        sessionID: reference.sessionID, beforeSequence: before, limit: 128)
                    guard await isCurrentSourceReveal(reveal, binding: token, generation: generation, origin: originPage) else { return false }
                    guard let olderSession = olderPage.session,
                        olderSession.summary.id == reference.sessionID,
                        olderSession.summary.workspaceID == state.header?.workspaceID
                    else {
                        throw MiraError(.unauthorized, "The original user message is unavailable.")
                    }
                    guard olderSession.summary.head == headSession.summary.head else {
                        changedHead = true
                        break
                    }
                    guard let nextOldest = olderPage.messages.map({ $0.summary.sequence }).min(),
                        olderPage.messages.allSatisfy({ $0.summary.sequence < before }),
                        nextOldest < before
                    else {
                        throw MiraError(.storage, "The conversation source history could not be paged safely.")
                    }
                    pages.append(olderPage)
                    oldestSequence = nextOldest
                }
                if changedHead { continue }
                if reachedSource { contiguousPages = pages; break }
                throw MiraError(.unauthorized, "The original user message is unavailable.")
            }
            guard let contiguousPages, let newestPage = contiguousPages.first else {
                throw MiraError(.conflict, "The conversation changed while opening its memory source.")
            }

            guard let source = contiguousPages.lazy.flatMap(\.messages).first(where: { $0.id == reference.userMessageID }),
                source.summary.sessionID == reference.sessionID,
                source.summary.executionID == reference.originalExecutionID,
                source.summary.sequence == reference.admissionSequence,
                source.summary.role == .user,
                source.body.text != nil
            else {
                throw MiraError(.unauthorized, "The original user message is unavailable.")
            }

            guard await isCurrentSourceReveal(reveal, binding: token, generation: generation, origin: originPage) else { return false }
            guard let session = newestPage.session else {
                throw MiraError(.unauthorized, "The original user message is unavailable.")
            }
            let page = pages[reference.sessionID]
                ?? ConversationPageState(conversationID: reference.sessionID, workspaceID: session.summary.workspaceID)
            pages[reference.sessionID] = page
            page.apply(newestPage)
            for olderPage in contiguousPages.dropFirst() {
                page.apply(olderPage, appendingOlder: true)
            }
            page.revealedMessageID = reference.userMessageID
            selectedWorkspaceID = session.summary.workspaceID
            showArchived = session.summary.isArchived
            activate(page)
            mount(page)
            refresh(page)
            refreshNotices(page)
            return true
        } catch {
            guard await isCurrentSourceReveal(reveal, binding: token, generation: generation, origin: originPage) else { return false }
            originPage.error = MiraError.safe(error)
            return false
        }
    }

    private func isCurrentSourceReveal(
        _ reveal: UUID, binding: UUID, generation: UInt64, origin: ConversationPageState
    ) async -> Bool {
        guard !Task.isCancelled, sourceRevealID == reveal, bindingID == binding,
            libraryGeneration == generation, activePage === origin
        else { return false }
        let status = await library.status()
        guard !Task.isCancelled, sourceRevealID == reveal, bindingID == binding,
            libraryGeneration == generation, activePage === origin
        else { return false }
        guard status.phase == .ready, status.generation == generation else {
            origin.error = MiraError(.busy, "The conversation library changed while opening its source.")
            return false
        }
        return true
    }

    private static let memorySourceMaximumPages = 32

    func selectWorkspace(_ id: WorkspaceID?) async {
        sourceRevealID = UUID()
        selectedWorkspaceID = id
        await newConversation()
        requestReload()
        await reloadTask?.value
    }

    func newConversation() async {
        sourceRevealID = UUID()
        showArchived = false
        activateDraft()
        if activePage.composer.isEmpty, activePage.pendingAdmission == nil {
            activePage.selectedRouteID = nil
        }
        await initializeModel(activePage)
    }

    private func activateDraft() {
        let draft = draftPage ?? ConversationPageState(workspaceID: selectedWorkspaceID)
        draftPage = draft
        // An uncertain first submission already owns its original workspace and command identity.
        if draft.pendingAdmission == nil { draft.workspaceID = selectedWorkspaceID }
        activate(draft)
    }

    private func activate(_ page: ConversationPageState) {
        guard activePage !== page else { return }
        activePage.isActive = false
        activePage = page
        page.isActive = true
        if !retainedPages.contains(where: { $0 === page }) { retainedPages.append(page) }
        recentIDs.removeAll { $0 == page.id }
        recentIDs.append(page.id)
        trimPages()
    }

    private func trimPages() {
        while retainedPages.filter({ $0.conversationID != nil }).count > pageLimit {
            guard
                let candidate = recentIDs.compactMap({ id in retainedPages.first { $0.id == id } })
                    .first(where: {
                        $0 !== activePage && !$0.isSending && !$0.needsPersistenceRetry && $0.conversationID != nil
                    })
            else { break }
            retiring += candidate.releaseContent()
            retainedPages.removeAll { $0 === candidate }
            recentIDs.removeAll { $0 == candidate.id }
        }
        scheduleRetirement()
    }

    private func mount(_ page: ConversationPageState) {
        guard page.observationID == nil, let id = page.conversationID, let group = workgroup else { return }
        let token = bindingID
        let pageToken = UUID()
        let choiceGeneration = page.modelChoiceGeneration
        page.observationID = pageToken
        page.observers.append(
            Task { @MainActor [weak self, weak page] in
                guard let self, let page else { return }
                do {
                    let snapshot = try await group.application.sessionSnapshot(id: id)
                    guard !Task.isCancelled, bindingID == token, page.observationID == pageToken,
                          page.modelChoiceGeneration == choiceGeneration else { return }
                    page.modelSelection = snapshot.modelSelection
                    page.modelSelectionRevision = snapshot.modelSelectionRevision
                    if case .selected(let reference) = snapshot.modelSelection {
                        page.selectedRouteID = reference.routeID
                    } else {
                        page.selectedRouteID = nil
                        await initializeModel(page)
                    }
                } catch { /* session observation reports the authoritative failure */ }
            })
        page.observers.append(
            Task { @MainActor [weak self, weak page] in
                do {
                    let status = await group.application.snapshot()
                    if !Task.isCancelled, let self, let page, bindingID == token, page.observationID == pageToken {
                        page.pendingSaveIDs = Set(
                            status.settlementFailures.keys.filter { $0.sessionID == id }.map(\.executionID))
                    }
                    for await observation in try await group.application.observeSession(id: id) {
                        guard !Task.isCancelled, let self, let page,
                            bindingID == token, page.observationID == pageToken
                        else { return }
                        page.cancellationRequested = observation.cancellationRequested
                        if observation.requiresReconciliation, let active = observation.activeExecutionID {
                            page.pendingSaveIDs.insert(active)
                        }
                        if observation.isClosing {
                            retiring += page.releaseContent()
                            scheduleRetirement()
                            return
                        }
                        if page.lastObservedSequence != observation.cursor.sequence {
                            page.lastObservedSequence = observation.cursor.sequence
                            refresh(page)
                        }
                    }
                } catch {
                    guard !Task.isCancelled, let self, let page,
                        bindingID == token, page.observationID == pageToken
                    else { return }
                    page.error = MiraError.safe(error)
                }
            })
        page.observers.append(
            Task { @MainActor [weak self, weak page] in
                do {
                    for await output in try await group.application.observeSessionOutput(id: id) {
                        guard !Task.isCancelled, let self, let page,
                            bindingID == token, page.observationID == pageToken
                        else { return }
                        page.streamBuffer.receive(output)
                        if output.value == nil {
                            if output.handoffExecutionID == nil { page.settledOutput = nil }
                            if !output.isClosing { refresh(page) }
                        }
                    }
                } catch {
                    guard !Task.isCancelled, let self, let page,
                        bindingID == token, page.observationID == pageToken
                    else { return }
                    page.error = MiraError.safe(error)
                }
            })
    }

    private func refresh(_ page: ConversationPageState) {
        guard let id = page.conversationID, let group = workgroup else { return }
        page.loadGeneration &+= 1
        page.isLoading = !page.isLoaded
        guard page.loadTask == nil else { return }
        let token = bindingID
        let taskIdentity = page.observationID
        page.loadTask = Task { @MainActor [weak self, weak page] in
            guard let self, let page else { return }
            defer {
                if bindingID == token, page.observationID == taskIdentity { page.loadTask = nil }
            }
            repeat {
                let version = page.loadGeneration
                do {
                    snapshotLoadCount &+= 1
                    let snapshot = try await group.queries.messagePage(sessionID: id)
                    let settledOutput = try await group.queries.settledOutput(sessionID: id)
                    let activities: [ExecutionID: [SessionActivityStep]]
                    var activityError: MiraError?
                    do {
                        activities = try await group.queries.executionActivities(
                            sessionID: id, executionIDs: Array(snapshot.executions.map(\.id).prefix(128)))
                    } catch let error as MiraError where error.code == .storage || error.code == .outputLimit {
                        activities = [:]
                        activityError = error
                    }
                    guard !Task.isCancelled, bindingID == token, page.observationID == taskIdentity else { return }
                    guard version == page.loadGeneration else { continue }
                    page.apply(snapshot)
                    page.activities = activities
                    if let activityError { page.error = activityError }
                    refreshNotices(page)
                    if activePage === page, let session = snapshot.session {
                        selectedWorkspaceID = session.summary.workspaceID
                        showArchived = session.summary.isArchived
                    }
                    if let settledOutput, let activeExecution = page.activeExecution,
                        !page.cancellationRequested.contains(activeExecution.id)
                    {
                        page.settledOutput = settledOutput
                    } else {
                        page.settledOutput = nil
                    }
                    if let handoff = page.streamBuffer.observation?.handoffExecutionID,
                       let head = snapshot.session?.summary.head,
                       (page.activeExecution?.id == handoff && page.settledOutput != nil)
                        || snapshot.executions.contains(where: { $0.id == handoff && $0.completion != nil }) {
                        page.streamBuffer.completeHandoff(executionID: handoff, through: head.cursor.sequence)
                    }
                } catch {
                    guard !Task.isCancelled, bindingID == token, page.observationID == taskIdentity else { return }
                    if version == page.loadGeneration {
                        page.isLoading = false
                        page.error = MiraError.safe(error)
                    }
                }
                if version == page.loadGeneration { break }
            } while !Task.isCancelled
        }
    }

    func loadOlderMessages(_ page: ConversationPageState) async {
        guard page.hasMoreMessages, let id = page.conversationID,
            let sequence = page.messages.first?.summary.sequence, let group = workgroup
        else { return }
        let token = bindingID
        let version = page.loadGeneration
        do {
            let snapshot = try await group.queries.messagePage(sessionID: id, beforeSequence: sequence)
            let activities = try await group.queries.executionActivities(
                sessionID: id, executionIDs: Array(snapshot.executions.map(\.id).prefix(128)))
            guard !Task.isCancelled, bindingID == token, page.loadGeneration == version,
                page.messages.first?.summary.sequence == sequence
            else { return }
            guard snapshot.session?.summary.head == page.session?.summary.head else {
                refresh(page)
                return
            }
            page.apply(snapshot, appendingOlder: true)
            page.activities.merge(activities) { _, new in new }
            refreshNotices(page)
        } catch { if !Task.isCancelled, bindingID == token { page.error = MiraError.safe(error) } }
    }

    func send() async { await send(activePage) }

    /// Only an explicit picker action remembers a model; loading a session never changes this preference.
    func selectModel(_ page: ConversationPageState, routeID: RouteID?) async {
        guard let group = workgroup, page.activeExecution == nil, !page.isSelectingModel,
              !page.isSending, page.pendingAdmission == nil else { return }
        let token = bindingID
        page.isSelectingModel = true
        page.modelChoiceGeneration &+= 1
        defer { page.isSelectingModel = false }
        do {
            let selection: AgentSessionModelSelection
            if let routeID {
                let candidate = try await group.modelSettings.candidate(routeID: routeID)
                try candidate.validate()
                selection = .selected(.init(routeID: routeID, model: candidate.model.reference,
                    modelConfigurationID: candidate.model.id))
            } else { selection = .inherit }
            guard bindingID == token else { return }
            if let sessionID = page.conversationID {
                let snapshot = try await group.application.sessionSnapshot(id: sessionID)
                if snapshot.modelSelection != selection {
                    let result = await group.application.selectModel(
                        sessionID: sessionID, commandID: UUID(), expectedRevision: snapshot.modelSelectionRevision,
                        selection: selection)
                    switch result {
                    case .committed: page.modelSelectionRevision = snapshot.modelSelectionRevision + 1
                    case .notCommitted(let failure), .indeterminate(_, let failure):
                        page.error = failure
                        return
                    }
                } else { page.modelSelectionRevision = snapshot.modelSelectionRevision }
                page.modelSelection = selection
            }
            guard bindingID == token else { return }
            page.selectedRouteID = routeID
            if let routeID { modelPreferences.remember(routeID, libraryID: library.id) }
            page.error = nil
        } catch { if bindingID == token { page.error = MiraError.safe(error) } }
    }

    private func initializeModel(_ page: ConversationPageState) async {
        guard page.selectedRouteID == nil, !page.isSelectingModel, let group = workgroup else { return }
        let token = bindingID
        let workspaceID = page.workspaceID
        do {
            let global = try await group.modelSettings.bindings(scope: .global)
                .first { $0.purpose == AgentModelPurposeID.conversation }
            let scoped: AgentRouteBinding?
            if let workspaceID {
                scoped = try await group.modelSettings.bindings(scope: .workspace(workspaceID))
                    .first { $0.purpose == AgentModelPurposeID.conversation }
            } else { scoped = nil }
            let localMode = workspaceID.flatMap {
                modelPreferences.followsLastSelection(libraryID: library.id, scope: .workspace($0))
            }
            let following = localMode ?? (scoped != nil ? false :
                modelPreferences.followsLastSelection(libraryID: library.id, scope: .global) ?? false)
            let selected = following ? modelPreferences.lastRoute(libraryID: library.id) ?? scoped?.routeID ?? global?.routeID
                : scoped?.routeID ?? global?.routeID
            guard bindingID == token, page.workspaceID == workspaceID,
                  page.selectedRouteID == nil, !page.isSelectingModel else { return }
            page.selectedRouteID = selected
        } catch { if bindingID == token { page.error = MiraError.safe(error) } }
    }

    private func refreshNotices(_ page: ConversationPageState) {
        guard let id = page.conversationID, let group = workgroup else { return }
        page.noticeGeneration &+= 1
        guard page.noticeTask == nil else { return }
        let token = bindingID
        let identity = page.observationID
        page.noticeTask = Task { @MainActor [weak self, weak page] in
            guard let self, let page else { return }
            defer {
                if bindingID == token, page.observationID == identity { page.noticeTask = nil }
            }
            repeat {
                let version = page.noticeGeneration
                let ids = Array(Set(page.messages.filter { $0.summary.role == .assistant }.map(\.summary.executionID)))
                    .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
                let workspaceID = page.workspaceID
                do {
                    var notices: [ExecutionID: [MemoryContextNotice]] = [:]
                    for start in stride(from: 0, to: ids.count, by: 128) {
                        let batch = Set(ids[start..<min(start + 128, ids.count)])
                        let values = try await group.memories.contextNotices(
                            sessionID: id, executionIDs: batch, workspaceID: workspaceID)
                        guard !Task.isCancelled, bindingID == token, page.observationID == identity else { return }
                        notices.merge(values) { _, new in new }
                    }
                    guard !Task.isCancelled, bindingID == token, page.observationID == identity else { return }
                    if version == page.noticeGeneration { page.memoryNotices = notices }
                } catch {
                    guard !Task.isCancelled, bindingID == token, page.observationID == identity else { return }
                    if version == page.noticeGeneration {
                        page.memoryNotices = [:]
                        page.error = MiraError.safe(error)
                    }
                }
                if version == page.noticeGeneration { break }
            } while !Task.isCancelled
        }
    }

    func send(_ page: ConversationPageState) async {
        guard let group = workgroup, !page.isSending, !page.isSelectingModel, page.pendingAdmission == nil, page.activeExecution == nil else {
            return
        }
        let input = page.composer
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        page.isSending = true
        page.submissionCancelled = false
        defer {
            page.isSending = false
            trimPages()
        }
        let token = bindingID
        do {
            let selection = try await selection(for: page, group: group)
            let route = try await group.modelSettings.resolve(
                purpose: AgentModelPurposeID.conversation, explicitRouteID: nil,
                sessionSelection: selection, workspaceID: page.workspaceID
            ).route
            guard !Task.isCancelled, bindingID == token, !page.submissionCancelled else { return }
            let command = AgentSubmitCommand(
                id: UUID(), sessionID: page.conversationID ?? .init(), executionID: .init(),
                input: .message(id: .init(), text: input, timeZoneIdentifier: TimeZone.current.identifier),
                options: .init(instructions: instructions, route: route),
                opening: page.conversationID == nil
                    ? .init(title: String(input.prefix(80)), workspaceID: page.workspaceID) : nil,
                expectedSelectionRevision: page.modelSelectionRevision,
                selectionChange: selection == page.modelSelection ? nil
                    : .init(selection: selection, expectedRevision: page.modelSelectionRevision))
            page.pendingAdmission = command
            page.pendingAdmissionRuntimeID = group.application.id
            let result = await group.application.submit(command)
            if page.submissionCancelled { await group.application.cancel(sessionID: command.sessionID) }
            consume(result, command: command, page: page, token: token)
        } catch { if bindingID == token, !Task.isCancelled { page.error = MiraError.safe(error) } }
    }

    private func selection(for page: ConversationPageState, group: MacLibraryWorkloads) async throws
        -> AgentSessionModelSelection
    {
        await initializeModel(page)
        guard let routeID = page.selectedRouteID else { return .inherit }
        let candidate = try await group.modelSettings.candidate(routeID: routeID)
        return .selected(.init(routeID: routeID, model: candidate.model.reference,
            modelConfigurationID: candidate.model.id))
    }

    /// A committed identity is retained even when the caller was cancelled or the workgroup changed.
    private func consume(
        _ result: SessionCommitResult, command: AgentSubmitCommand,
        page: ConversationPageState, token: UUID
    ) {
        guard page.pendingAdmission?.id == command.id else { return }
        switch result {
        case .committed:
            if let change = command.selectionChange {
                page.modelSelection = change.selection
                page.modelSelectionRevision = change.expectedRevision + 1
            }
            page.pendingAdmission = nil
            page.pendingAdmissionRuntimeID = nil
            page.conversationID = command.sessionID
            pages[command.sessionID] = page
            if draftPage === page { draftPage = nil }
            if case .message(_, let input, _) = command.input, page.composer == input { page.composer = "" }
            recentIDs.removeAll { $0 == page.id }
            recentIDs.append(page.id)
            if bindingID == token { page.error = nil }
            if workgroup != nil {
                mount(page)
                refresh(page)
                requestReload()
            }
        case .notCommitted(let failure):
            page.pendingAdmission = nil
            page.pendingAdmissionRuntimeID = nil
            if bindingID == token { page.error = failure }
        case .indeterminate(_, let failure):
            if bindingID == token { page.error = failure }
        }
    }

    func cancel(_ page: ConversationPageState) async {
        if page.isSending { page.submissionCancelled = true }
        guard let group = workgroup, let id = page.pendingAdmission?.sessionID ?? page.conversationID else { return }
        await group.application.cancel(sessionID: id)
    }

    func retrySaving(_ page: ConversationPageState) async {
        guard let group = workgroup, !page.isSending else { return }
        let token = bindingID
        if let command = page.pendingAdmission {
            page.isSending = true
            defer { page.isSending = false }
            let result: SessionCommitResult
            if page.pendingAdmissionRuntimeID == group.application.id {
                result = await group.application.reconcileAdmission(commandID: command.id)
            } else {
                do {
                    // A replacement runtime is ready only after recovery has settled the journal.
                    let state = try await group.application.sessionSnapshot(id: command.sessionID)
                    guard bindingID == token else { return }
                    if let admitted = state.executions[command.executionID] {
                        guard admitted.admissionBatchID == command.id else {
                            throw MiraError(.conflict, "The recovered execution does not match the pending command.")
                        }
                        result = .committed(.init(sessionID: state.id, sequence: state.sequence))
                    } else {
                        result = .notCommitted(
                            .init(.interrupted, "The pending message was not committed. Your draft is retained."))
                    }
                } catch {
                    if bindingID == token { page.error = MiraError.safe(error) }
                    return
                }
            }
            consume(result, command: command, page: page, token: token)
        } else if let id = page.conversationID {
            for executionID in page.pendingSaveIDs {
                guard !Task.isCancelled, bindingID == token else { return }
                let result = await group.application.retrySettlement(executionID: executionID, sessionID: id)
                guard !Task.isCancelled, bindingID == token else { return }
                switch result {
                case .committed: page.pendingSaveIDs.remove(executionID)
                case .notCommitted(let failure), .indeterminate(_, let failure): page.error = failure
                }
            }
            refresh(page)
        }
    }

    func retry(_ page: ConversationPageState) async {
        guard let group = workgroup, let execution = page.retryableExecution,
            !page.isSending, page.pendingAdmission == nil
        else { return }
        page.isSending = true
        page.submissionCancelled = false
        defer { page.isSending = false }
        let token = bindingID
        do {
            let selection = try await selection(for: page, group: group)
            let route = try await group.modelSettings.resolve(
                purpose: AgentModelPurposeID.conversation, explicitRouteID: nil,
                sessionSelection: selection, workspaceID: page.workspaceID
            ).route
            guard !Task.isCancelled, bindingID == token, !page.submissionCancelled else { return }
            let command = AgentSubmitCommand(
                id: UUID(), sessionID: execution.sessionID, executionID: .init(),
                input: .retry(executionID: execution.id),
                options: .init(instructions: instructions, route: route),
                expectedSelectionRevision: page.modelSelectionRevision,
                selectionChange: selection == page.modelSelection
                    ? nil : .init(selection: selection, expectedRevision: page.modelSelectionRevision))
            page.pendingAdmission = command
            page.pendingAdmissionRuntimeID = group.application.id
            let result = await group.application.submit(command)
            if page.submissionCancelled { await group.application.cancel(sessionID: command.sessionID) }
            consume(result, command: command, page: page, token: token)
        } catch { if bindingID == token, !Task.isCancelled { page.error = MiraError.safe(error) } }
    }

    func archive(_ id: ConversationID) async {
        guard let group = workgroup, archiving.insert(id).inserted else { return }
        defer { archiving.remove(id) }
        let token = bindingID
        let result: SessionCommitResult
        if let pending = pendingArchives[id], pending.runtimeID == group.application.id {
            result = await group.application.reconcileSessionCommand(commandID: pending.commandID)
        } else {
            do {
                let state = try await group.application.sessionSnapshot(id: id)
                guard !Task.isCancelled, bindingID == token else { return }
                if state.isArchived {
                    pendingArchives[id] = nil
                    if selectedConversationID == id { await newConversation() }
                    requestReload()
                    return
                }
                let commandID = UUID()
                pendingArchives[id] = (commandID, group.application.id)
                result = await group.application.changeSession(
                    id: id, commandID: commandID, change: .archive(expectedRevision: state.revision))
            } catch {
                if bindingID == token, !Task.isCancelled { self.error = MiraError.safe(error) }
                return
            }
        }
        guard bindingID == token else { return }
        switch result {
        case .committed:
            pendingArchives[id] = nil
            if selectedConversationID == id { await newConversation() }
            requestReload()
        case .notCommitted(let failure):
            pendingArchives[id] = nil
            error = failure
        case .indeterminate(_, let failure): error = failure
        }
    }

    func resolveApproval(_ request: RuntimeApprovalRequest, decision: RuntimeApprovalDecision) async {
        guard let group = workgroup, approvals.contains(request) else { return }
        let token = bindingID
        do {
            try await group.approvals.resolve(
                id: request.id, proposalHash: request.proposalHash,
                authorizationEpoch: request.authorizationEpoch, decision: decision)
        } catch { if bindingID == token, !Task.isCancelled { self.error = MiraError.safe(error) } }
    }
}
