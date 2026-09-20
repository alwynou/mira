import Foundation
import MiraCore
import Observation

/// Owns the management query, selected detail and any admitted memory action.
/// Reads and presentation results are tied to both an observation run and a
/// replaceable library generation.
@MainActor @Observable
final class MemoryManagementModel {
    let library: MacLibrary

    var searchText = "" { didSet { if searchText != oldValue { refresh() } } }
    var scope: MemoryManagementScope = .all { didSet { if scope != oldValue { refresh() } } }
    var section: MemoryManagementSection = .current { didSet { if section != oldValue { refresh() } } }
    var order: MemoryManagementOrder = .newestFirst { didSet { if order != oldValue { refresh() } } }

    var creationScope: MemoryScope {
        if case .workspace(let id) = scope { .workspace(id) } else { .global }
    }

    private(set) var memories: [Memory] = []
    private(set) var workspaces: [Workspace] = []
    private(set) var selectedID: MemoryID?
    private(set) var detail: MemoryDetail?
    private(set) var relatedMemories: [MemoryID: Memory] = [:]
    private(set) var hasMoreRelatedHistory = false
    private(set) var isLoading = false
    private(set) var isLoadingDetail = false
    private(set) var isWorking = false
    private(set) var error: MiraError?
    private(set) var hasMore = false

    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var bindingID = UUID()
    private(set) var generation: UInt64?
    @ObservationIgnored private var group: MacLibraryWorkloads?
    @ObservationIgnored private var cursor: MemoryManagementCursor?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var businessTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var validityTask: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var retirementTask: Task<Void, Never>?
    @ObservationIgnored private var readID = UUID()
    @ObservationIgnored private var detailID = UUID()
    @ObservationIgnored private var readDirty = false

    init(library: MacLibrary) { self.library = library }

    /// Call from a view-owned task. Cancellation ends observation and drains this
    /// model's reads, but an already admitted action remains owned until settlement.
    func observe() async {
        let run = UUID()
        runID = run
        bindingID = UUID()
        generation = nil
        group = nil
        clearRevocableData()
        stopReadTasks()
        let oldObservation = observationTask
        let oldBusiness = businessTask
        observationTask = nil
        businessTask = nil
        oldObservation?.cancel()
        oldBusiness?.cancel()
        await drain([oldObservation, oldBusiness].compactMap { $0 })
        guard !Task.isCancelled, runID == run else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            for await status in await self.library.observe() {
                guard !Task.isCancelled, self.runID == run else { break }
                switch status.phase {
                case .ready:
                    guard let binding = try? await self.library.binding(),
                        binding.status.phase == .ready,
                        binding.status.generation == status.generation,
                        self.runID == run, !Task.isCancelled
                    else { continue }
                    if self.generation != status.generation || self.group !== binding.workgroup {
                        await self.bind(binding.workgroup, generation: status.generation, run: run)
                    }
                case .failed:
                    self.invalidate(run: run)
                    self.error = status.failure
                case .starting, .maintaining, .closing, .closed:
                    self.invalidate(run: run)
                }
            }
            guard self.runID == run else { return }
            self.invalidate(run: run)
        }
        observationTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        if runID == run { observationTask = nil }
        await retirementTask?.value
    }

    func refresh() {
        guard let group, generation != nil else { return }
        cursor = nil
        hasMore = false
        memories = []
        detailID = UUID()
        cancelDetailRead()
        detail = nil
        relatedMemories = [:]
        hasMoreRelatedHistory = false
        isLoadingDetail = false
        isLoading = true
        error = nil
        scheduleRead(group: group, run: runID, binding: bindingID, generation: generation!, appending: false)
    }

    func loadMore() {
        guard hasMore, !isLoading, let cursor, let group, let generation else { return }
        isLoading = true
        error = nil
        scheduleRead(group: group, run: runID, binding: bindingID, generation: generation,
                     appending: true, cursor: cursor)
    }

    func select(_ id: MemoryID?) {
        if selectedID == id, (detail != nil || isLoadingDetail) { return }
        selectedID = id
        detail = nil
        relatedMemories = [:]
        hasMoreRelatedHistory = false
        detailID = UUID()
        cancelDetailRead()
        isLoadingDetail = false
        guard let id, let memory = memories.first(where: { $0.id == id }),
            let group, let generation
        else { return }
        loadDetail(memory, group: group, generation: generation)
    }

    /// Selects a related record already resolved within the active owner's scope.
    /// A related record need not be present in the current filtered or paged list.
    func selectRelated(_ memory: Memory) {
        guard let authorized = relatedMemories[memory.id],
            authorized.revision == memory.revision,
            authorized.scope == memory.scope
        else { return }
        if selectedID == memory.id, (detail != nil || isLoadingDetail) { return }
        selectedID = authorized.id
        detail = nil
        relatedMemories = [:]
        hasMoreRelatedHistory = false
        detailID = UUID()
        cancelDetailRead()
        guard let group, let generation else { return }
        loadDetail(authorized, group: group, generation: generation)
    }

    private func loadDetail(_ memory: Memory, group: MacLibraryWorkloads, generation: UInt64) {
        let id = memory.id
        isLoadingDetail = true
        let run = runID, binding = bindingID, token = detailID
        let task = Task { @MainActor [weak self] in
            do {
                // Scope is derived from the selected memory itself. The filter is
                // only a list constraint and never grants detail access.
                var result = try await group.memories.detail(id, workspaceID: memory.scope.workspaceID)
                result.replacements.sort { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
                var related: [MemoryID: Memory] = [:]
                let relatedIDs = Set(result.replacements.prefix(32).flatMap { [$0.replacementID, $0.previousID] })
                    .subtracting([id])
                for relatedID in relatedIDs {
                    try Task.checkCancellation()
                    guard await self?.isCurrent(run: run, binding: binding, generation: generation) == true,
                        self?.detailID == token, self?.selectedID == id
                    else { return }
                    // Both ends are resolved with the selected memory's scope. A
                    // relationship never grants access to a broader workspace.
                    if let relatedDetail = try? await group.memories.detail(
                        relatedID, workspaceID: memory.scope.workspaceID)
                    {
                        related[relatedID] = relatedDetail.memory
                    }
                }
                if result.memory.state == .candidate {
                    var frontier = Array(related.values)
                    var visited = Set(related.keys)
                    while let ancestor = frontier.popLast(), visited.count <= 100 {
                        try Task.checkCancellation()
                        guard await self?.isCurrent(run: run, binding: binding, generation: generation) == true,
                              self?.detailID == token else { return }
                        guard ancestor.forgottenAt == nil, ancestor.deletedAt == nil,
                              ![.rejected, .removed].contains(ancestor.state),
                              let successor = ancestor.supersededBy, visited.insert(successor).inserted else { continue }
                        if let next = try? await group.memories.detail(successor, workspaceID: memory.scope.workspaceID) {
                            related[successor] = next.memory
                            frontier.append(next.memory)
                        }
                    }
                }
                guard !Task.isCancelled, let self,
                    await self.isCurrent(run: run, binding: binding, generation: generation),
                    self.detailID == token, self.selectedID == id
                else { return }
                self.detail = result
                self.relatedMemories = related
                self.hasMoreRelatedHistory = result.replacements.count > 32
                self.error = nil
                self.isLoadingDetail = false
                self.detailTask = nil
            } catch {
                guard !Task.isCancelled, let self,
                    await self.isCurrent(run: run, binding: binding, generation: generation),
                    self.detailID == token
                else { return }
                self.detail = nil
                self.relatedMemories = [:]
                self.hasMoreRelatedHistory = false
                self.error = MiraError.safe(error)
                self.isLoadingDetail = false
                self.detailTask = nil
            }
        }
        detailTask = task
    }

    func changeState(_ memory: Memory, to state: MemoryState) {
        guard !isWorking, let group, let generation, self.generation == generation else { return }
        let run = runID, binding = bindingID, scopeID = memory.scope.workspaceID
        let expectedRevision = memory.revision
        let operationID = UUID()
        startAction { [weak self] in
            guard let self, await self.isCurrent(run: run, binding: binding, generation: generation) else { return }
            _ = try await group.memories.changeMemoryState(memory.id, workspaceID: scopeID, state: state,
                                                           expectedRevision: expectedRevision, operationID: operationID)
            await self.reloadAfterEditing(preferredID: memory.id, run: run, binding: binding, generation: generation)
        }
    }

    func forget(_ memory: Memory) {
        guard !isWorking, let generation,
            self.generation == generation
        else { return }
        let run = runID, binding = bindingID
        let request = AgentLibraryMaintenanceRequest(
            id: UUID(), namespace: "memory.forget", revision: 1,
            scope: .sources([.domain(namespace: "memories", id: memory.id.rawValue, revision: memory.revision)]),
            requestedAt: .now)
        startAction(allowBindingChangeOnFailure: true) { [weak self] in
            guard let self, await self.isCurrent(run: run, binding: binding, generation: generation) else { return }
            // Maintenance owns the exact revision-bound privacy operation and
            // invalidates all body-bearing caches as it revokes the library.
            self.clearRevocableData()
            _ = try await self.library.maintain(request)
        }
    }

    func confirmReplacement(candidate: Memory, current: Memory) {
        guard !isWorking, let group, let generation,
            candidate.state == .candidate,
            self.generation == generation
        else { return }
        let run = runID, binding = bindingID
        let candidateRevision = candidate.revision, currentRevision = current.revision
        let workspaceID = candidate.scope.workspaceID
        let operationID = UUID()
        startAction { [weak self] in
            guard let self, await self.isCurrent(run: run, binding: binding, generation: generation) else { return }
            _ = try await group.memories.confirmMemoryReplacement(
                candidate.id, workspaceID: workspaceID, replacingCurrent: current.id,
                expectedCandidateRevision: candidateRevision, expectedCurrentRevision: currentRevision,
                operationID: operationID)
            await self.reloadAfterEditing(preferredID: current.id, run: run, binding: binding, generation: generation)
        }
    }

    func reloadAfterEditing(preferredID: MemoryID? = nil) async {
        guard group != nil, let generation else { return }
        await reloadAfterEditing(preferredID: preferredID, run: runID, binding: bindingID, generation: generation)
    }

    func clearError() { error = nil }
    func waitForAction() async { await actionTask?.value }

    private func bind(_ group: MacLibraryWorkloads, generation: UInt64, run: UUID) async {
        invalidate(run: run)
        await retirementTask?.value
        guard !Task.isCancelled, runID == run else { return }
        let binding = UUID()
        bindingID = binding
        do {
            let changes = try await group.changes.observe()
            guard !Task.isCancelled, runID == run, bindingID == binding else { return }
            self.group = group
            self.generation = generation
            let feed = Task { @MainActor [weak self] in
                for await event in changes {
                    guard !Task.isCancelled, let self, self.runID == run, self.bindingID == binding else { return }
                    if event.isClosed { self.invalidate(run: run) }
                    else { self.refresh() }
                }
            }
            businessTask = feed
            do {
                let values = try await group.workspaces.workspaces()
                guard !Task.isCancelled, await isCurrent(run: run, binding: binding, generation: generation) else { return }
                workspaces = values
            } catch {
                guard !Task.isCancelled, await isCurrent(run: run, binding: binding, generation: generation) else { return }
                workspaces = []
                self.error = MiraError.safe(error)
            }
            refresh()
        } catch {
            guard !Task.isCancelled, runID == run, bindingID == binding else { return }
            invalidate(run: run)
            self.error = MiraError.safe(error)
        }
    }

    private func scheduleRead(group: MacLibraryWorkloads, run: UUID, binding: UUID, generation: UInt64,
                              appending: Bool, cursor: MemoryManagementCursor? = nil) {
        readDirty = true
        guard readTask == nil else { return }
        startRead(group: group, run: run, binding: binding, generation: generation, appending: appending, cursor: cursor)
    }

    private func startRead(group: MacLibraryWorkloads, run: UUID, binding: UUID, generation: UInt64,
                           appending: Bool, cursor: MemoryManagementCursor?) {
        readDirty = false
        let token = UUID(); readID = token
        let query = MemoryManagementQuery(scope: scope, section: section, query: searchText,
                                          order: order, limit: 100, cursor: cursor)
        readTask = Task { @MainActor [weak self] in
            do {
                async let page = group.memories.managementPage(query)
                async let spaces = group.workspaces.workspaces()
                let (result, workspaceValues) = try await (page, spaces)
                guard !Task.isCancelled, let self,
                    await self.isCurrent(run: run, binding: binding, generation: generation), self.readID == token
                else { return }
                self.readTask = nil
                if self.readDirty {
                    self.startRead(group: group, run: run, binding: binding, generation: generation,
                                   appending: false, cursor: nil)
                    return
                }
                let oldSelection = self.selectedID
                let existingIDs = Set(self.memories.map(\.id))
                self.memories = appending ? self.memories + result.memories.filter { !existingIDs.contains($0.id) } : result.memories
                self.workspaces = workspaceValues
                self.cursor = result.nextCursor
                self.hasMore = result.nextCursor != nil
                self.scheduleValidityRefresh(at: result.nextTransitionAt, run: run, binding: binding, generation: generation)
                self.isLoading = false
                self.error = nil
                let wanted = oldSelection ?? self.selectedID
                if let wanted, self.memories.contains(where: { $0.id == wanted }) { self.select(wanted) }
                else { self.select(nil) }
            } catch {
                guard !Task.isCancelled, let self,
                    await self.isCurrent(run: run, binding: binding, generation: generation), self.readID == token
                else { return }
                self.readTask = nil
                if self.readDirty {
                    self.startRead(group: group, run: run, binding: binding, generation: generation,
                                   appending: false, cursor: nil)
                    return
                }
                self.memories = []
                self.detail = nil
                self.relatedMemories = [:]
                self.hasMoreRelatedHistory = false
                self.cursor = nil
                self.hasMore = false
                self.isLoading = false
                self.isLoadingDetail = false
                self.error = MiraError.safe(error)
            }
        }
    }

    private func reloadAfterEditing(preferredID: MemoryID?, run: UUID, binding: UUID, generation: UInt64) async {
        guard await isCurrent(run: run, binding: binding, generation: generation) else { return }
        if let preferredID { selectedID = preferredID }
        refresh()
        await readTask?.value
    }

    private func startAction(allowBindingChangeOnFailure: Bool = false,
                             _ operation: @escaping @MainActor () async throws -> Void) {
        guard actionTask == nil else { return }
        let capturedRun = runID
        let capturedBinding = bindingID
        let capturedGeneration = generation
        isWorking = true
        error = nil
        let task = Task { @MainActor [weak self] in
            do { try await operation() }
            catch {
                if let self, self.runID == capturedRun {
                    let canPublish: Bool
                    if allowBindingChangeOnFailure {
                        canPublish = (await self.library.status()).phase != .closed
                    } else if let capturedGeneration {
                        canPublish = await self.isCurrent(
                            run: capturedRun, binding: capturedBinding, generation: capturedGeneration)
                    } else {
                        canPublish = false
                    }
                    if canPublish {
                        // Failed maintenance/read boundaries must not leave source text cached.
                        if self.generation == nil { self.clearRevocableData() }
                        self.error = MiraError.safe(error)
                    }
                }
            }
            guard let self else { return }
            self.isWorking = false
            self.actionTask = nil
        }
        actionTask = task
    }

    private func isCurrent(run: UUID, binding: UUID, generation: UInt64) async -> Bool {
        guard runID == run, bindingID == binding, self.generation == generation else { return false }
        let status = await library.status()
        return runID == run && bindingID == binding && self.generation == generation
            && status.phase == .ready && status.generation == generation
    }

    private func invalidate(run: UUID) {
        guard runID == run else { return }
        bindingID = UUID()
        generation = nil
        group = nil
        stopReadTasks()
        clearRevocableData(preserveSelection: true)
        let business = businessTask
        businessTask = nil
        business?.cancel()
        if let business { retire([business]) }
    }

    private func clearRevocableData(preserveSelection: Bool = false) {
        memories = []; workspaces = []
        if !preserveSelection { selectedID = nil }
        detail = nil; relatedMemories = [:]; hasMoreRelatedHistory = false
        cursor = nil; hasMore = false; isLoading = false; isLoadingDetail = false
        error = nil
    }

    private func scheduleValidityRefresh(at date: Date?, run: UUID, binding: UUID, generation: UInt64) {
        validityTask?.cancel()
        validityTask = nil
        guard let date else { return }
        let delay = max(0.01, min(date.timeIntervalSinceNow, 86_400))
        validityTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self,
                  await self.isCurrent(run: run, binding: binding, generation: generation) else { return }
            self.validityTask = nil
            self.refresh()
        }
    }

    private func cancelDetailRead() {
        guard let task = detailTask else { return }
        detailTask = nil
        task.cancel()
        retire([task])
    }

    private func stopReadTasks() {
        validityTask?.cancel()
        validityTask = nil
        let tasks = [readTask, detailTask].compactMap { $0 }
        readTask = nil; detailTask = nil
        readID = UUID(); detailID = UUID(); readDirty = false
        tasks.forEach { $0.cancel() }
        retire(tasks)
    }

    private func retire(_ tasks: [Task<Void, Never>]) {
        guard !tasks.isEmpty else { return }
        let previous = retirementTask
        retirementTask = Task { [previous] in
            await previous?.value
            for task in tasks { await task.value }
        }
    }

    private func drain(_ tasks: [Task<Void, Never>]) async {
        for task in tasks { await task.value }
    }
}
