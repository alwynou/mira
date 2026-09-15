import Foundation
import MiraCore
import Observation

@MainActor @Observable
final class MemorySettingsModel {
    @ObservationIgnored let container: AppContainer
    var mode: MemoryCaptureMode = .manualOnly
    var dailyTokenLimitText = "10000"
    private var policyRevision = 1
    private var savedMode: MemoryCaptureMode = .manualOnly
    private var savedDailyTokenLimitText = "10000"
    private var savedEnabledAt: Date?
    private var extractionBindings: [AgentRouteBinding] = []
    private var loadedWorkgroup: MacLibraryWorkloads?
    var workspaces: [Workspace] = []
    var budget: MemoryExtractionBudget?
    var isDirty = false
    var isSaving = false
    private var isApplying = false
    private var changeGeneration = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveID: UUID?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadID: UUID?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var observationID: UUID?
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored private var retirementTask: Task<Void, Never>?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var bindingID = UUID()
    var error: MiraError?
    var statusKey: String?

    private struct SaveRequest: Sendable {
        let library: MacLibrary
        let group: MacLibraryWorkloads
        let policy: MemoryCapturePolicy
        let expectedRevision: Int
        let runID: UUID
        let bindingID: UUID
        let draftGeneration: Int
        let mode: MemoryCaptureMode
        let text: String
        let enabledAt: Date?
    }

    var hasMemoryExtractionRoute: Bool {
        extractionBindings.contains { $0.purpose == AgentModelPurposeID.memoryExtraction }
    }

    init(container: AppContainer) { self.container = container }

    func observe() async {
        let id = UUID()
        runID = id
        bindingID = UUID()
        clearRevocableMetadata()
        isSaving = false
        let previous = observationTask
        observationTask = nil
        observationID = nil
        let previousChanges = changesTask
        changesTask = nil
        previous?.cancel()
        previousChanges?.cancel()
        retire([previous, previousChanges].compactMap { $0 })
        await retirementTask?.value
        guard !Task.isCancelled, runID == id else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runObservation(id: id)
        }
        observationTask = task
        observationID = id
        await withTaskCancellationHandler(
            operation: {
                await task.value
            },
            onCancel: {
                task.cancel()
            })
        if observationID == id {
            observationTask = nil
            observationID = nil
        }
    }

    private func runObservation(id: UUID) async {
        await refresh(runID: id, force: false)
        guard !Task.isCancelled, runID == id, let library = container.library else { return }
        for await status in await library.observe() {
            guard !Task.isCancelled, runID == id else { break }
            if status.phase == .ready {
                await refresh(runID: id, force: false)
                guard !Task.isCancelled, runID == id,
                    let binding = try? await library.binding(),
                    binding.status.phase == .ready,
                    binding.status.generation == status.generation,
                    !Task.isCancelled, runID == id
                else { continue }
                await observeChanges(for: binding.workgroup, runID: id, bindingID: self.bindingID)
            } else {
                guard runID == id else { return }
                bindingID = UUID()
                clearRevocableMetadata()
                isSaving = false
                await stopChangesObservation()
            }
        }
        guard runID == id else { return }
        bindingID = UUID()
        clearRevocableMetadata()
        await stopChangesObservation()
    }

    /// Stops presentation-owned observers and waits for accepted settings work to return.
    /// A save is deliberately drained instead of cancelled after it has been accepted.
    func stop() async {
        runID = UUID()
        bindingID = UUID()
        let observation = observationTask
        observationTask = nil
        observation?.cancel()
        observationID = nil

        let changes = changesTask
        changesTask = nil
        changes?.cancel()

        let reload = reloadTask
        reloadTask = nil
        reloadID = nil
        reload?.cancel()

        isSaving = false
        let save = saveTask
        saveTask = nil
        saveID = nil
        clearRevocableMetadata()

        retire([observation, changes, reload, save].compactMap { $0 })
        await retirementTask?.value
    }

    func markDirty() {
        guard !isApplying else { return }
        isDirty = mode != savedMode || dailyTokenLimitText != savedDailyTokenLimitText
        changeGeneration &+= 1
        statusKey = nil
        error = nil
    }

    func startSave() {
        guard saveTask == nil, !container.isDemo else { return }
        let value = dailyTokenLimitText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let limit = Int(value), (1...10_000_000).contains(limit) else {
            error = MiraError(.invalidInput, "Enter a daily token limit from 1 to 10,000,000.")
            return
        }
        guard let library = container.library, let group = loadedWorkgroup,
            container.library === library
        else {
            error = MiraError(.storage, "The library is not open.")
            return
        }

        let capturedMode = mode
        let capturedText = dailyTokenLimitText
        let capturedEnabledAt = capturedMode == .manualOnly ? nil : (savedEnabledAt ?? Date())
        let expectedRevision = policyRevision
        let policy = MemoryCapturePolicy(
            revision: expectedRevision + 1, mode: capturedMode,
            dailyTokenLimit: limit, enabledAt: capturedEnabledAt)
        let request = SaveRequest(
            library: library, group: group, policy: policy, expectedRevision: expectedRevision,
            runID: runID, bindingID: bindingID, draftGeneration: changeGeneration,
            mode: capturedMode, text: capturedText, enabledAt: capturedEnabledAt)
        let id = UUID()
        saveID = id
        isSaving = true
        error = nil
        statusKey = nil
        saveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await performSave(request, id: id)
            if saveID == id {
                saveTask = nil
                saveID = nil
                isSaving = false
            }
        }
    }

    func discardAndReload() {
        isDirty = false
        changeGeneration &+= 1
        reloadID = nil
        if let reloadTask {
            reloadTask.cancel()
            retire([reloadTask])
        }
        let id = UUID()
        reloadID = id
        let idForRun = runID
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await refresh(runID: idForRun, force: true)
            if reloadID == id {
                reloadTask = nil
                reloadID = nil
            }
        }
    }

    private func refresh(
        runID expectedRunID: UUID, expectedBindingID: UUID? = nil, force: Bool
    ) async {
        guard !Task.isCancelled, runID == expectedRunID,
            expectedBindingID == nil || bindingID == expectedBindingID
        else { return }
        guard let library = container.library else {
            clearRevocableMetadata()
            return
        }
        do {
            let binding = try await library.binding()
            let group = binding.workgroup
            guard !Task.isCancelled, runID == expectedRunID,
                container.library === library
            else { return }
            guard expectedBindingID == nil || bindingID == expectedBindingID else { return }
            if loadedWorkgroup !== group { bindingID = UUID() }
            let expectedBindingID = bindingID
            let draftGeneration = changeGeneration
            do {
                let policy = try await group.memories.capturePolicy()
                let workspaces = try await group.workspaces.workspaces()
                var bindings = try await group.modelSettings.bindings(scope: .global)
                for workspace in workspaces {
                    bindings += try await group.modelSettings.bindings(scope: .workspace(workspace.id))
                }
                let budget = try await group.memories.extractionBudget()
                let current = await isCurrent(group: group, library: library, generation: binding.status.generation)
                guard current, !Task.isCancelled, runID == expectedRunID, bindingID == expectedBindingID
                else { return }

                loadedWorkgroup = group
                self.workspaces = workspaces
                self.extractionBindings = bindings
                self.budget = budget
                if draftGeneration == changeGeneration,
                    force || (!isDirty && !isSaving)
                {
                    apply(policy)
                }
                error = nil
            } catch {
                let current = await isCurrent(group: group, library: library, generation: binding.status.generation)
                guard current, !Task.isCancelled, runID == expectedRunID, bindingID == expectedBindingID
                else { return }
                self.error = MiraError.safe(error)
            }
        } catch {
            let current = try? await library.binding()
            guard current != nil, !Task.isCancelled, runID == expectedRunID,
                container.library === library
            else { return }
            self.error = MiraError.safe(error)
        }
    }

    private func performSave(_ request: SaveRequest, id: UUID) async {
        do {
            let binding = try await request.library.binding()
            guard binding.workgroup === request.group,
                binding.status.phase == .ready,
                isCurrentSave(request)
            else { return }
            try await request.group.memories.saveCapturePolicy(
                request.policy, expectedRevision: request.expectedRevision)
            let current = try await request.library.binding()
            guard current.workgroup === request.group, isCurrentSave(request) else { return }
            policyRevision = request.policy.revision
            savedMode = request.mode
            savedDailyTokenLimitText = request.text
            savedEnabledAt = request.enabledAt
            isDirty = mode != savedMode || dailyTokenLimitText != savedDailyTokenLimitText
            statusKey = "Memory capture settings saved."
            isSaving = false
            if request.draftGeneration == changeGeneration, !isDirty {
                await refresh(runID: request.runID, force: true)
            }
        } catch {
            let current = try? await request.library.binding()
            guard current?.workgroup === request.group, isCurrentSave(request) else { return }
            self.error = MiraError.safe(error)
            isDirty = true
            isSaving = false
        }
    }

    private func observeChanges(
        for group: MacLibraryWorkloads, runID expectedRunID: UUID, bindingID expectedBindingID: UUID
    ) async {
        await stopChangesObservation()
        guard runID == expectedRunID, bindingID == expectedBindingID else { return }
        changesTask = Task { @MainActor [weak self] in
            guard let stream = try? await group.changes.observe() else { return }
            for await _ in stream {
                guard !Task.isCancelled, let self,
                    self.runID == expectedRunID, self.bindingID == expectedBindingID
                else { return }
                await self.refresh(
                    runID: expectedRunID, expectedBindingID: expectedBindingID, force: false)
            }
        }
    }

    private func stopChangesObservation() async {
        let task = changesTask
        changesTask = nil
        task?.cancel()
        if let task {
            retire([task])
            await task.value
        }
    }

    private func isCurrent(group: MacLibraryWorkloads, library: MacLibrary, generation: UInt64) async -> Bool {
        guard let current = try? await library.binding() else { return false }
        return container.library === library && current.workgroup === group && current.status.generation == generation
    }

    private func retire(_ tasks: [Task<Void, Never>]) {
        guard !tasks.isEmpty else { return }
        let previous = retirementTask
        retirementTask = Task {
            await previous?.value
            for task in tasks { await task.value }
        }
    }

    private func isCurrentSave(_ request: SaveRequest) -> Bool {
        runID == request.runID && bindingID == request.bindingID
            && loadedWorkgroup === request.group
            && container.library === request.library
    }

    private func clearRevocableMetadata() {
        loadedWorkgroup = nil
        workspaces = []
        budget = nil
        extractionBindings = []
        error = nil
        statusKey = nil
    }

    private func apply(_ policy: MemoryCapturePolicy) {
        isApplying = true
        mode = policy.mode
        dailyTokenLimitText = String(policy.dailyTokenLimit)
        savedMode = mode
        savedDailyTokenLimitText = dailyTokenLimitText
        savedEnabledAt = policy.enabledAt
        policyRevision = policy.revision
        isDirty = false
        isApplying = false
    }
}
