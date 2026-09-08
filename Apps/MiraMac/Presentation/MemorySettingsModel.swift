import Foundation
import Observation
import MiraCore

@MainActor @Observable
final class MemorySettingsModel {
    @ObservationIgnored let container: AppContainer
    var mode: MemoryCaptureMode = .manualOnly
    var dailyTokenLimitText = "10000"
    private var policyRevision = 1
    var configuration = ModelConfiguration(connections: [], models: [], routes: [], bindings: [])
    var workspaces: [Workspace] = []
    var budget: MemoryExtractionBudget?
    var isDirty = false
    var isSaving = false
    private var isApplying = false
    private var changeGeneration = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    var error: MiraError?
    var statusKey: String?

    init(container: AppContainer) { self.container = container }

    func observe() async {
        await refreshIfClean()
        guard !Task.isCancelled, let application = container.application else { return }
        let stream = await application.events()
        for await event in stream {
            guard !Task.isCancelled else { return }
            if case .changed = event { await refreshIfClean() }
        }
    }

    func markDirty() {
        guard !isApplying else { return }
        isDirty = true
        changeGeneration += 1
        statusKey = nil
        error = nil
    }

    func startSave() {
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor in
            await save()
            saveTask = nil
        }
    }

    func discardAndReload() {
        isDirty = false
        changeGeneration += 1
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            await load(force: true)
            reloadTask = nil
        }
    }

    private func refreshIfClean() async {
        guard !isDirty, !isSaving else { return }
        await load(force: false)
    }

    private func load(force: Bool) async {
        guard let application = container.application else { return }
        let generation = changeGeneration
        do {
            let policy = try await application.memoryCapturePolicy()
            guard !Task.isCancelled, generation == changeGeneration, force || (!isDirty && !isSaving) else { return }
            apply(policy)
            let library = try await application.library(includeArchived: true)
            guard !Task.isCancelled, generation == changeGeneration, force || (!isDirty && !isSaving) else { return }
            configuration = library.configuration
            workspaces = library.workspaces
            let currentBudget = try await application.memoryExtractionBudget()
            guard !Task.isCancelled, generation == changeGeneration, force || (!isDirty && !isSaving) else { return }
            budget = currentBudget
            error = nil
        } catch {
            guard !Task.isCancelled, generation == changeGeneration else { return }
            self.error = MiraError.safe(error)
        }
    }

    private func apply(_ policy: MemoryCapturePolicy) {
        isApplying = true
        mode = policy.mode
        dailyTokenLimitText = String(policy.dailyTokenLimit)
        policyRevision = policy.revision
        isDirty = false
        isApplying = false
    }

    private func save() async {
        guard !container.isDemo, let application = container.application else { return }
        let value = dailyTokenLimitText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let limit = Int(value), (1...10_000_000).contains(limit) else {
            error = MiraError(.invalidInput, "Enter a daily token limit from 1 to 10,000,000.")
            return
        }
        isSaving = true
        error = nil
        statusKey = nil
        do {
            try await application.saveMemoryCapturePolicy(mode: mode, dailyTokenLimit: limit, expectedRevision: policyRevision)
            guard !Task.isCancelled else { isSaving = false; return }
            isDirty = false
            changeGeneration += 1
            statusKey = "Memory capture settings saved."
            await load(force: true)
        } catch {
            self.error = MiraError.safe(error)
            isDirty = true
        }
        isSaving = false
    }
}
