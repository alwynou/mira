import AppKit
import MiraCore
import MiraData
import Observation
import UniformTypeIdentifiers

struct KnowledgeImportOutcome: Identifiable {
    enum State { case imported, reused, failed }
    let id = UUID()
    let filename: String
    let state: State
    var error: MiraError?
    var versionFailed = false
    var permissionUnchanged = false
}

/// Local management reads belong to the current library generation. Admitted
/// mutations remain owned here when the view is removed or its task is cancelled.
@MainActor @Observable
final class KnowledgeManagementModel {
    let library: MacLibrary
    var searchText = "" { didSet { if searchText != oldValue { scheduleSearchRefresh() } } }
    var scope: KnowledgeManagementScope = .all { didSet { if scope != oldValue { refresh() } } }
    var status: KnowledgeManagementStatus = .all { didSet { if status != oldValue { refresh() } } }
    var order: KnowledgeManagementOrder = .newestFirst { didSet { if order != oldValue { refresh() } } }
    private(set) var items: [KnowledgeManagementItem] = []
    private(set) var workspaces: [Workspace] = []
    private(set) var selectedID: KnowledgeSourceID?
    private(set) var detail: KnowledgeSourceDetail?
    private(set) var document: KnowledgeDocumentPage?
    private(set) var selectedMatch: SourceChunkSummary?
    private(set) var isLoading = false
    private(set) var isLoadingDetail = false
    private(set) var isLoadingDocument = false
    private(set) var isWorking = false
    private(set) var error: MiraError?
    private(set) var hasMore = false
    private(set) var isTruncated = false
    private(set) var generation: UInt64?

    var showsImport = false
    var importWorkspaceID: WorkspaceID?
    var importAllowsRemoteUse = false
    private(set) var importFiles: [URL] = []
    private(set) var importResults: [KnowledgeImportOutcome] = []
    private(set) var importTarget: KnowledgeSource?
    var canImport: Bool { !isWorking && generation != nil && !importFiles.isEmpty && importResults.isEmpty }
    var hasPreviousDocumentPage: Bool { documentStarts.count > 1 }

    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var bindingID = UUID()
    @ObservationIgnored private var group: MacLibraryWorkloads?
    @ObservationIgnored private var cursor: KnowledgeManagementCursor?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var businessTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var documentTask: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var retirementTask: Task<Void, Never>?
    @ObservationIgnored private var readID = UUID()
    @ObservationIgnored private var detailID = UUID()
    @ObservationIgnored private var documentID = UUID()
    @ObservationIgnored private var readDirty = false
    @ObservationIgnored private var documentStarts: [Int?] = [nil]
    @ObservationIgnored private var stopImportRequested = false
    @ObservationIgnored private var importGeneration: UInt64?

    init(library: MacLibrary) { self.library = library }

    func observe() async {
        let run = UUID()
        runID = run
        bindingID = UUID()
        generation = nil
        group = nil
        clearRevocableData(preserveSelection: true)
        stopReadTasks()
        let previous = [observationTask, businessTask].compactMap { $0 }
        observationTask = nil; businessTask = nil
        previous.forEach { $0.cancel() }
        for task in previous { await task.value }
        guard !Task.isCancelled, runID == run else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            for await state in await self.library.observe() {
                guard !Task.isCancelled, self.runID == run else { break }
                switch state.phase {
                case .ready:
                    guard let binding = try? await self.library.binding(),
                          binding.status.phase == .ready, binding.status.generation == state.generation,
                          self.runID == run, !Task.isCancelled else { continue }
                    if self.generation != state.generation || self.group !== binding.workgroup {
                        await self.bind(binding.workgroup, generation: state.generation, run: run)
                    }
                case .failed:
                    self.invalidate(run: run)
                    self.error = state.failure
                case .starting, .maintaining, .closing, .closed:
                    self.invalidate(run: run)
                }
            }
            if self.runID == run { self.invalidate(run: run) }
        }
        observationTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        if runID == run { observationTask = nil }
        await retirementTask?.value
    }

    private func scheduleSearchRefresh() {
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.searchTask = nil
            self.refresh()
        }
    }

    func refresh() {
        guard let group, let generation else { return }
        cursor = nil; hasMore = false; isTruncated = false; items = []
        clearDetail()
        isLoading = true
        // A feed refresh must not erase a concurrently reported action failure.
        readDirty = true
        guard readTask == nil else { return }
        startRead(group: group, run: runID, binding: bindingID, generation: generation, appending: false)
    }

    func loadMore() {
        guard hasMore, !isLoading, let cursor, let group, let generation else { return }
        isLoading = true
        startRead(group: group, run: runID, binding: bindingID, generation: generation,
                  appending: true, cursor: cursor)
    }

    func select(_ id: KnowledgeSourceID?) {
        if selectedID == id, detail != nil || isLoadingDetail { return }
        selectedID = id
        clearDetail()
        guard let item = items.first(where: { $0.id == id }), let group, let generation else { return }
        selectedMatch = item.match
        let version = item.match?.sourceVersionID ?? item.source.currentVersionID ?? item.latestVersion?.id
        loadDetail(item.source, versionID: version, group: group, generation: generation)
    }

    func selectVersion(_ id: SourceVersionID) {
        guard let source = detail?.source, let group, let generation else { return }
        let match = selectedMatch
        clearDetail()
        if match?.sourceVersionID == id { selectedMatch = match }
        loadDetail(source, versionID: id, group: group, generation: generation)
    }

    func nextDocumentPage() {
        guard !isLoadingDocument, let next = document?.nextSequence else { return }
        documentStarts.append(next)
        loadDocument()
    }

    func previousDocumentPage() {
        guard !isLoadingDocument, hasPreviousDocumentPage else { return }
        documentStarts.removeLast()
        loadDocument()
    }

    private func loadDetail(_ source: KnowledgeSource, versionID: SourceVersionID?,
                            group: MacLibraryWorkloads, generation: UInt64) {
        isLoadingDetail = true
        let run = runID, binding = bindingID, token = detailID
        detailTask = Task { @MainActor [weak self] in
            do {
                let result = try await group.knowledge.detail(source.id, versionID: versionID,
                    scope: .init(workspaceID: source.workspaceID, destination: .local))
                guard !Task.isCancelled, let self,
                      await self.isCurrent(run: run, binding: binding, generation: generation),
                      self.detailID == token, self.selectedID == source.id else { return }
                self.detail = result
                self.isLoadingDetail = false
                self.detailTask = nil
                self.documentStarts = [nil]
                if let match = self.selectedMatch, match.sourceVersionID == result.selectedVersion?.id,
                   match.sequence > 0 { self.documentStarts.append(match.sequence - 1) }
                self.loadDocument()
            } catch {
                guard !Task.isCancelled, let self,
                      await self.isCurrent(run: run, binding: binding, generation: generation),
                      self.detailID == token else { return }
                self.isLoadingDetail = false; self.detailTask = nil
                self.error = MiraError.safe(error)
            }
        }
    }

    private func loadDocument() {
        cancelDocumentRead()
        document = nil
        guard let detail, let version = detail.selectedVersion, version.parseState == .ready,
              let group, let generation else { return }
        isLoadingDocument = true
        let run = runID, binding = bindingID, token = documentID
        let after = documentStarts.last ?? nil
        documentTask = Task { @MainActor [weak self] in
            do {
                let result = try await group.knowledge.documentPage(detail.source.id, versionID: version.id,
                    scope: .init(workspaceID: detail.source.workspaceID, destination: .local), afterSequence: after)
                guard !Task.isCancelled, let self,
                      await self.isCurrent(run: run, binding: binding, generation: generation),
                      self.documentID == token else { return }
                self.document = result
                self.isLoadingDocument = false; self.documentTask = nil
            } catch {
                guard !Task.isCancelled, let self,
                      await self.isCurrent(run: run, binding: binding, generation: generation),
                      self.documentID == token else { return }
                self.isLoadingDocument = false; self.documentTask = nil
                self.error = MiraError.safe(error)
            }
        }
    }

    func chooseImport(updating source: KnowledgeSource? = nil) {
        guard !isWorking, let generation else { return }
        let panel = NSOpenPanel()
        let locale = AppLanguage.resolve(stored: UserDefaults.standard.string(forKey: AppLanguage.preferenceKey) ?? "").locale
        panel.title = L10n.string(source == nil ? "Import Markdown" : "Update source", locale: locale)
        panel.allowedContentTypes = [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }
        panel.allowsMultipleSelection = source == nil
        panel.canChooseDirectories = false
        panel.resolvesAliases = false
        panel.begin { [weak self] response in
            guard response == .OK, let self, self.generation == generation else { return }
            self.prepareImport(urls: panel.urls, updating: source)
        }
    }

    /// Selection is a value snapshot; file access starts only after the review sheet.
    func prepareImport(urls: [URL], updating source: KnowledgeSource? = nil) {
        guard !isWorking, let generation else { return }
        guard !urls.isEmpty, urls.count <= 100, source == nil || urls.count == 1 else {
            error = .init(.invalidInput, "Choose up to 100 Markdown files, or one file when updating a source.")
            return
        }
        importFiles = urls
        importResults = []
        importTarget = source
        importGeneration = generation
        if let source { importWorkspaceID = source.workspaceID }
        else if case .workspace(let id) = scope { importWorkspaceID = id }
        else { importWorkspaceID = nil }
        importAllowsRemoteUse = false
        showsImport = true
    }

    func startImport() {
        guard canImport, let group, let generation, importGeneration == generation else { return }
        let files = importFiles, target = importTarget
        let workspace = target.map(\.workspaceID) ?? importWorkspaceID
        let allowNew = importAllowsRemoteUse && target == nil
        stopImportRequested = false
        startAction { [weak self] in
            guard let self else { return }
            let reader = MarkdownFileSnapshotReader()
            for url in files {
                if self.stopImportRequested { break }
                // Each next file is a new admission. Navigation is harmless; a
                // privacy boundary or library replacement stops the remaining batch.
                guard await self.libraryReady(generation) else { break }
                var outcome = KnowledgeImportOutcome(filename: url.lastPathComponent, state: .failed)
                do {
                    let input = try await reader.read(url)
                    guard await self.libraryReady(generation) else { break }
                    let receipt = try await group.knowledge.importMarkdown(input, workspaceID: workspace,
                        updating: target?.id, expectedRevision: target?.revision, operationID: UUID())
                    outcome = .init(filename: url.lastPathComponent, state: receipt.reused ? .reused : .imported,
                                    error: receipt.version.parseError,
                                    versionFailed: receipt.version.parseState == .failed,
                                    permissionUnchanged: receipt.reused || target != nil)
                    // A duplicate reuses its existing permission. The checkbox
                    // grants permission only to a newly created source.
                    if allowNew && !receipt.reused && receipt.version.parseState == .ready {
                        do {
                            _ = try await group.knowledge.allowRemoteUse(receipt.source.id, workspaceID: workspace,
                                expectedRevision: receipt.source.revision, operationID: UUID())
                        } catch { outcome.error = MiraError.safe(error) }
                    }
                } catch { outcome.error = MiraError.safe(error) }
                if await self.libraryReady(generation) { self.importResults.append(outcome) }
            }
            await reader.close()
            if self.generation == generation { self.refresh() }
        }
    }

    /// Stops before the next file; the current admitted write settles normally.
    func cancelImport() { stopImportRequested = true }
    func clearImport() {
        guard !isWorking else { return }
        showsImport = false; importFiles = []; importResults = []; importTarget = nil; importGeneration = nil
    }

    func allow(_ source: KnowledgeSource) {
        guard !isWorking, let group, let generation else { return }
        startAction { [weak self] in
            guard let self, await self.libraryReady(generation) else { return }
            _ = try await group.knowledge.allowRemoteUse(source.id, workspaceID: source.workspaceID,
                expectedRevision: source.revision, operationID: UUID())
            if self.generation == generation { self.refresh() }
        }
    }

    func revoke(_ source: KnowledgeSource) { maintain(source, action: .revokeRemoteUse) }
    func delete(_ source: KnowledgeSource) { maintain(source, action: .deleteSource) }

    private func maintain(_ source: KnowledgeSource, action: KnowledgePrivacyAction) {
        guard !isWorking, let generation else { return }
        let request = AgentLibraryMaintenanceRequest(id: UUID(), namespace: action.namespace, revision: 1,
            scope: .sources([.domain(namespace: KnowledgeSources.metadataNamespace,
                                     id: source.id.rawValue, revision: source.revision)]), requestedAt: .now)
        startAction(allowBindingChangeOnFailure: true) { [weak self] in
            guard let self, await self.libraryReady(generation) else { return }
            self.clearRevocableData(preserveSelection: action == .revokeRemoteUse)
            self.resetImportPresentation()
            _ = try await self.library.maintain(request)
        }
    }

    func clearError() { error = nil }
    func waitForAction() async { await actionTask?.value }

    private func startAction(allowBindingChangeOnFailure: Bool = false,
                             _ operation: @escaping @MainActor () async throws -> Void) {
        guard actionTask == nil else { return }
        let run = runID, binding = bindingID, generation = generation
        isWorking = true; error = nil
        actionTask = Task { @MainActor [weak self] in
            do { try await operation() }
            catch {
                if let self, self.runID == run {
                    let canPublish: Bool
                    if allowBindingChangeOnFailure {
                        // Maintenance deliberately replaces the binding. Its own
                        // failure must remain actionable within this observation run.
                        canPublish = (await self.library.status()).phase != .closed
                    } else if let generation {
                        canPublish = await self.isCurrent(run: run, binding: binding, generation: generation)
                    } else { canPublish = false }
                    if canPublish { self.error = MiraError.safe(error) }
                }
            }
            // Only one action can be admitted at a time; it owns this flag even
            // when observation has ended, so a new view is never left disabled.
            self?.isWorking = false
            self?.actionTask = nil
        }
    }

    private func bind(_ group: MacLibraryWorkloads, generation: UInt64, run: UUID) async {
        invalidate(run: run)
        await retirementTask?.value
        guard !Task.isCancelled, runID == run else { return }
        let binding = UUID(); bindingID = binding
        do {
            let changes = try await group.changes.observe()
            guard !Task.isCancelled, runID == run, bindingID == binding else { return }
            self.group = group; self.generation = generation
            businessTask = Task { @MainActor [weak self] in
                for await event in changes {
                    guard !Task.isCancelled, let self, self.runID == run, self.bindingID == binding else { return }
                    if event.isClosed { self.invalidate(run: run) } else { self.refresh() }
                }
            }
            refresh()
        } catch {
            guard !Task.isCancelled, runID == run, bindingID == binding else { return }
            invalidate(run: run)
            self.error = MiraError.safe(error)
        }
    }

    private func startRead(group: MacLibraryWorkloads, run: UUID, binding: UUID, generation: UInt64,
                           appending: Bool, cursor: KnowledgeManagementCursor? = nil) {
        readDirty = false
        let token = UUID(); readID = token
        let query = KnowledgeManagementQuery(scope: scope, status: status, query: searchText,
                                              order: order, limit: 100, cursor: cursor)
        readTask = Task { @MainActor [weak self] in
            do {
                async let page = group.knowledge.managementPage(query)
                async let spaces = group.workspaces.workspaces()
                let (result, workspaceValues) = try await (page, spaces)
                guard !Task.isCancelled, let self,
                      await self.isCurrent(run: run, binding: binding, generation: generation), self.readID == token else { return }
                self.readTask = nil
                if self.readDirty {
                    self.startRead(group: group, run: run, binding: binding, generation: generation, appending: false)
                    return
                }
                let existing = Set(self.items.map(\.id))
                self.items = appending ? self.items + result.items.filter { !existing.contains($0.id) } : result.items
                self.workspaces = workspaceValues
                self.cursor = result.nextCursor; self.hasMore = result.nextCursor != nil
                self.isTruncated = result.isTruncated
                self.isLoading = false
                if let selected = self.selectedID, self.items.contains(where: { $0.id == selected }) { self.select(selected) }
                else { self.select(nil) }
            } catch {
                guard !Task.isCancelled, let self,
                      await self.isCurrent(run: run, binding: binding, generation: generation), self.readID == token else { return }
                self.readTask = nil
                if self.readDirty {
                    self.startRead(group: group, run: run, binding: binding, generation: generation, appending: false)
                    return
                }
                self.items = []; self.cursor = nil; self.hasMore = false; self.isLoading = false
                self.clearDetail()
                self.error = MiraError.safe(error)
            }
        }
    }

    private func libraryReady(_ generation: UInt64) async -> Bool {
        let state = await library.status()
        return state.phase == .ready && state.generation == generation
    }

    private func isCurrent(run: UUID, binding: UUID, generation: UInt64) async -> Bool {
        guard runID == run, bindingID == binding, self.generation == generation else { return false }
        let ready = await libraryReady(generation)
        return ready && runID == run && bindingID == binding && self.generation == generation
    }

    private func invalidate(run: UUID) {
        guard runID == run else { return }
        bindingID = UUID(); generation = nil; group = nil
        stopReadTasks()
        clearRevocableData(preserveSelection: true)
        resetImportPresentation()
        if let task = businessTask { businessTask = nil; task.cancel(); retire([task]) }
    }

    private func resetImportPresentation() {
        showsImport = false; importFiles = []; importResults = []; importTarget = nil; importGeneration = nil
    }

    private func clearRevocableData(preserveSelection: Bool = false) {
        items = []; workspaces = []
        if !preserveSelection { selectedID = nil }
        clearDetail()
        cursor = nil; hasMore = false; isTruncated = false; isLoading = false
    }

    private func clearDetail() {
        detailID = UUID()
        if let task = detailTask { detailTask = nil; task.cancel(); retire([task]) }
        cancelDocumentRead()
        detail = nil; document = nil; selectedMatch = nil
        documentStarts = [nil]; isLoadingDetail = false
    }

    private func cancelDocumentRead() {
        documentID = UUID(); isLoadingDocument = false
        if let task = documentTask { documentTask = nil; task.cancel(); retire([task]) }
    }

    private func stopReadTasks() {
        let tasks = [readTask, detailTask, documentTask, searchTask].compactMap { $0 }
        readTask = nil; detailTask = nil; documentTask = nil; searchTask = nil
        readID = UUID(); detailID = UUID(); documentID = UUID(); readDirty = false
        tasks.forEach { $0.cancel() }; retire(tasks)
    }

    private func retire(_ tasks: [Task<Void, Never>]) {
        guard !tasks.isEmpty else { return }
        let previous = retirementTask
        retirementTask = Task {
            await previous?.value
            for task in tasks { await task.value }
        }
    }
}
