import Foundation
import MiraCore
import Observation

/// Owns one revocable read of session-scoped domain data.
///
/// The library and workgroup are replaceable around maintenance and export. A read
/// is therefore installed only when its observation run, library generation, and
/// workgroup binding are still current. Cancellation drains this model's tasks but
/// never cancels application-owned executions.
@MainActor @Observable
final class MacSessionReadModel<Value: Sendable> {
    private(set) var value: Value?
    private(set) var error: MiraError?
    private(set) var isLoading = false

    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var bindingID = UUID()
    @ObservationIgnored private var libraryGeneration: UInt64?
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var businessTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var readID = UUID()
    @ObservationIgnored private var readDirty = false
    @ObservationIgnored private var retirementTask: Task<Void, Never>?

    func observe(
        library: MacLibrary, sessionID: ConversationID,
        load: @escaping @Sendable (MacLibraryWorkloads) async throws -> Value
    ) async {
        let observationID = UUID()
        runID = observationID
        stopOwnedTasks()
        bindingID = UUID()
        libraryGeneration = nil
        value = nil
        error = nil
        isLoading = true

        let statuses = await library.observe()
        for await status in statuses {
            guard !Task.isCancelled, runID == observationID else { break }
            switch status.phase {
            case .ready:
                guard let binding = try? await library.binding(),
                    binding.status.phase == .ready,
                    binding.status.generation == status.generation
                else { continue }
                guard !Task.isCancelled, runID == observationID else { continue }
                guard libraryGeneration != status.generation || libraryGeneration == nil else { continue }
                await bind(
                    binding.workgroup, generation: status.generation, observationID: observationID,
                    sessionID: sessionID, load: load)
            case .starting:
                invalidate(observationID: observationID)
            case .maintaining, .closing, .closed:
                invalidate(observationID: observationID)
            case .failed:
                invalidate(observationID: observationID)
                error = status.failure
            }
        }

        guard runID == observationID else { return }
        stopOwnedTasks()
        value = nil
        error = nil
        isLoading = false
        let retirement = retirementTask
        await retirement?.value
        guard runID == observationID else { return }
        value = nil
        isLoading = false
    }

    private func bind(
        _ group: MacLibraryWorkloads, generation: UInt64, observationID: UUID,
        sessionID: ConversationID,
        load: @escaping @Sendable (MacLibraryWorkloads) async throws -> Value
    ) async {
        invalidate(observationID: observationID)
        let binding = UUID()
        bindingID = binding

        do {
            // Establish both feeds before the first read, so a concurrent revoke or
            // session change cannot be missed between the initial query and subscribe.
            let sessionEvents = try await group.application.observeSession(id: sessionID)
            let businessEvents = try await group.changes.observe()
            guard !Task.isCancelled, runID == observationID, bindingID == binding else { return }
            libraryGeneration = generation

            sessionTask = Task { @MainActor [weak self] in
                for await observation in sessionEvents {
                    guard !Task.isCancelled, let self,
                        self.runID == observationID, self.bindingID == binding
                    else { return }
                    if observation.isClosing {
                        self.invalidate(observationID: observationID)
                    } else {
                        self.scheduleRead(
                            group: group, observationID: observationID, bindingID: binding, load: load)
                    }
                }
            }
            businessTask = Task { @MainActor [weak self] in
                for await observation in businessEvents {
                    guard !Task.isCancelled, let self,
                        self.runID == observationID, self.bindingID == binding
                    else { return }
                    if observation.isClosed {
                        self.invalidate(observationID: observationID)
                    } else {
                        // The first event is also meaningful: it may represent a
                        // commit buffered while the initial session read was starting.
                        self.scheduleRead(
                            group: group, observationID: observationID, bindingID: binding, load: load)
                    }
                }
            }
        } catch {
            guard runID == observationID, bindingID == binding, !Task.isCancelled else { return }
            value = nil
            self.error = MiraError.safe(error)
            isLoading = false
        }
    }

    private func scheduleRead(
        group: MacLibraryWorkloads, observationID: UUID, bindingID: UUID,
        load: @escaping @Sendable (MacLibraryWorkloads) async throws -> Value
    ) {
        guard runID == observationID, self.bindingID == bindingID else { return }
        readDirty = true
        value = nil
        error = nil
        isLoading = true
        guard readTask == nil else { return }
        startRead(group: group, observationID: observationID, bindingID: bindingID, load: load)
    }

    private func startRead(
        group: MacLibraryWorkloads, observationID: UUID, bindingID: UUID,
        load: @escaping @Sendable (MacLibraryWorkloads) async throws -> Value
    ) {
        readDirty = false
        let readID = UUID()
        self.readID = readID
        readTask = Task { @MainActor [weak self] in
            do {
                let result = try await load(group)
                guard !Task.isCancelled, let self,
                    self.runID == observationID, self.bindingID == bindingID,
                    self.libraryGeneration != nil, self.readID == readID
                else { return }
                self.readTask = nil
                if self.readDirty {
                    self.value = nil
                    self.error = nil
                    self.startRead(
                        group: group, observationID: observationID, bindingID: bindingID, load: load)
                    return
                }
                self.value = result
                self.error = nil
                self.isLoading = false
            } catch {
                guard !Task.isCancelled, let self,
                    self.runID == observationID, self.bindingID == bindingID, self.readID == readID
                else { return }
                self.readTask = nil
                if self.readDirty {
                    self.value = nil
                    self.error = nil
                    self.startRead(
                        group: group, observationID: observationID, bindingID: bindingID, load: load)
                    return
                }
                self.value = nil
                self.error = MiraError.safe(error)
                self.isLoading = false
            }
        }
    }

    private func invalidate(observationID: UUID) {
        guard runID == observationID else { return }
        bindingID = UUID()
        readID = UUID()
        libraryGeneration = nil
        stopOwnedTasks()
        value = nil
        error = nil
        isLoading = false
    }

    private func stopOwnedTasks() {
        let tasks = [sessionTask, businessTask, readTask].compactMap { $0 }
        sessionTask = nil
        businessTask = nil
        readTask = nil
        readID = UUID()
        readDirty = false
        tasks.forEach { $0.cancel() }
        guard !tasks.isEmpty else { return }
        let previous = retirementTask
        retirementTask = Task { [previous] in
            await previous?.value
            for task in tasks { await task.value }
        }
    }
}
