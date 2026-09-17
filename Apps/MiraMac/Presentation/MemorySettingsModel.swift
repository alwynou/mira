import Foundation
import MiraCore
import Observation

@MainActor @Observable
final class MemorySettingsModel {
    @ObservationIgnored let container: AppContainer
    private var loadedWorkgroup: MacLibraryWorkloads?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var observationID: UUID?
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored private var modelPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var modelPreparationID: UUID?
    @ObservationIgnored private var modelStatusTask: Task<Void, Never>?
    @ObservationIgnored private var retirementTask: Task<Void, Never>?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var bindingID = UUID()
    var error: MiraError?
    var localModelStatus: MemoryEmbeddingStatus = .unavailable

    init(container: AppContainer) { self.container = container }

    func prepareLocalModel() {
        guard let group = loadedWorkgroup, !container.isDemo else { return }
        let previous = modelPreparationTask
        previous?.cancel()
        if let previous { retire([previous]) }
        let preparationID = UUID()
        modelPreparationID = preparationID
        let expectedRunID = runID
        let expectedBindingID = bindingID
        let task = Task { @MainActor [weak self] in
            await group.prepareLocalMemoryModel()
            guard let self, !Task.isCancelled,
                self.runID == expectedRunID,
                self.bindingID == expectedBindingID,
                let current = self.loadedWorkgroup, current === group,
                self.modelPreparationID == preparationID
            else { return }
            let status = await group.localMemoryModelStatus()
            guard !Task.isCancelled,
                self.runID == expectedRunID,
                self.bindingID == expectedBindingID,
                let current = self.loadedWorkgroup, current === group,
                self.modelPreparationID == preparationID
            else { return }
            self.localModelStatus = status
            self.modelPreparationTask = nil
            self.modelPreparationID = nil
        }
        modelPreparationTask = task
    }

    func observe() async {
        let id = UUID()
        runID = id
        bindingID = UUID()
        clearRevocableMetadata()

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
            operation: { await task.value },
            onCancel: { task.cancel() })
        if observationID == id {
            observationTask = nil
            observationID = nil
        }
    }

    private func runObservation(id: UUID) async {
        await refresh(runID: id)
        guard !Task.isCancelled, runID == id, let library = container.library else { return }
        for await status in await library.observe() {
            guard !Task.isCancelled, runID == id else { break }
            if status.phase == .ready {
                await refresh(runID: id)
                guard !Task.isCancelled, runID == id,
                    let binding = try? await library.binding(),
                    binding.status.phase == .ready,
                    binding.status.generation == status.generation,
                    !Task.isCancelled, runID == id
                else { continue }
                await observeChanges(for: binding.workgroup, runID: id, bindingID: bindingID)
            } else {
                guard runID == id else { return }
                bindingID = UUID()
                clearRevocableMetadata()
                await stopChangesObservation()
            }
        }
        guard runID == id else { return }
        bindingID = UUID()
        clearRevocableMetadata()
        await stopChangesObservation()
    }

    /// Stops presentation-owned observers and waits for local model work to return.
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

        let preparation = modelPreparationTask
        modelPreparationTask = nil
        modelPreparationID = nil
        preparation?.cancel()

        let modelStatus = modelStatusTask
        modelStatusTask = nil
        modelStatus?.cancel()

        clearRevocableMetadata()
        retire([observation, changes, preparation, modelStatus].compactMap { $0 })
        await retirementTask?.value
    }

    private func refresh(runID expectedRunID: UUID) async {
        guard !Task.isCancelled, runID == expectedRunID, let library = container.library else {
            clearRevocableMetadata()
            return
        }
        do {
            let binding = try await library.binding()
            let group = binding.workgroup
            guard !Task.isCancelled, runID == expectedRunID, container.library === library else { return }
            if loadedWorkgroup !== group { bindingID = UUID() }
            let expectedBindingID = bindingID
            let localModelStatus = await group.localMemoryModelStatus()
            let current = await isCurrent(group: group, library: library, generation: binding.status.generation)
            guard current, !Task.isCancelled, runID == expectedRunID, bindingID == expectedBindingID else { return }
            loadedWorkgroup = group
            self.localModelStatus = localModelStatus
            error = nil
        } catch {
            let current = try? await library.binding()
            guard current != nil, !Task.isCancelled, runID == expectedRunID, container.library === library else { return }
            self.error = MiraError.safe(error)
        }
    }

    private func observeChanges(
        for group: MacLibraryWorkloads, runID expectedRunID: UUID, bindingID expectedBindingID: UUID
    ) async {
        await stopChangesObservation()
        guard runID == expectedRunID, bindingID == expectedBindingID else { return }
        modelStatusTask?.cancel()
        modelStatusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let status = await group.localMemoryModelStatus()
                guard let self, self.runID == expectedRunID, self.bindingID == expectedBindingID else { return }
                self.localModelStatus = status
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        changesTask = Task { @MainActor [weak self] in
            guard let stream = try? await group.changes.observe() else { return }
            for await _ in stream {
                guard !Task.isCancelled, let self, self.runID == expectedRunID, self.bindingID == expectedBindingID else { return }
                await self.refresh(runID: expectedRunID)
            }
        }
    }

    private func stopChangesObservation() async {
        let modelStatus = modelStatusTask
        modelStatusTask = nil
        modelStatus?.cancel()
        if let modelStatus { await modelStatus.value }
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

    private func clearRevocableMetadata() {
        loadedWorkgroup = nil
        error = nil
        localModelStatus = .unavailable
    }
}
