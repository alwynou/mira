import Foundation
import MiraCore
import Observation

struct PurposeRoutingOption: Identifiable, Equatable {
    let id: RouteID
    let title: String
}

/// Each card owns one explicit scope/purpose binding and its compare-and-swap baseline.
@MainActor @Observable
final class PurposeRoutingModel {
    let scope: AgentRouteScope
    let purpose: String
    var routeID: RouteID?
    var followsLastSelection = false
    @ObservationIgnored private var baselineFollowing = false
    @ObservationIgnored private let preferences: ConversationModelPreferences
    private(set) var options: [PurposeRoutingOption] = []
    private(set) var error: MiraError?
    private(set) var isLoading = false
    private(set) var isSaving = false
    @ObservationIgnored private let library: MacLibrary
    @ObservationIgnored private let isDemo: Bool
    @ObservationIgnored private var baseline: AgentRouteBinding?
    @ObservationIgnored private var latest: AgentRouteBinding?
    @ObservationIgnored private var didLoad = false
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var readID = UUID()
    @ObservationIgnored private var presentationID = UUID()

    init(scope: AgentRouteScope, purpose: String, library: MacLibrary, isDemo: Bool,
         preferences: ConversationModelPreferences = .shared) {
        self.scope = scope
        self.purpose = purpose
        self.library = library
        self.isDemo = isDemo
        self.preferences = preferences
    }
    var hasChanges: Bool { routeID != baseline?.routeID || followsLastSelection != baselineFollowing }
    var canSave: Bool {
        didLoad && !isDemo && !isLoading && !isSaving && hasChanges
            && (followsLastSelection || (routeID.map { id in options.contains { $0.id == id } } ?? true))
    }
    private var requiredCapabilities: Set<String> {
        purpose == AgentModelPurposeID.memoryExtraction
            ? [AgentModelCapabilityID.streamingText, AgentModelCapabilityID.jsonOutput]
            : [AgentModelCapabilityID.streamingText]
    }

    func refresh(options candidates: [PurposeRoutingOption]) async {
        let token = UUID()
        readID = token
        let old = readTask
        old?.cancel()
        await old?.value
        guard readID == token, !Task.isCancelled else { return }
        let presentation = presentationID
        let task = Task {
            isLoading = true
            defer {
                if readID == token {
                    isLoading = false
                    readTask = nil
                }
            }
            do {
                let binding = try await library.binding()
                let values = try await binding.workgroup.modelSettings.bindings(scope: scope)
                var eligible: [PurposeRoutingOption] = []
                for candidate in candidates {
                    try Task.checkCancellation()
                    do {
                        _ = try await resolve(candidate.id, with: binding.workgroup)
                        eligible.append(candidate)
                    } catch let error as MiraError
                        where error.code == .configuration || error.code == .credentialMissing
                            || error.code == .unsupported || error.code == .notFound
                    {
                        continue
                    }
                }
                guard readID == token, presentationID == presentation, !Task.isCancelled,
                    await isCurrent(binding)
                else { return }
                options = eligible
                latest = values.first { $0.purpose == purpose }
                if !didLoad || (!hasChanges && !isSaving) {
                    baseline = latest
                    routeID = latest?.routeID
                    baselineFollowing = preferences.followsLastSelection(libraryID: library.id, scope: scope) ?? false
                    followsLastSelection = baselineFollowing
                    error = nil
                } else if !isSaving, baseline != latest {
                    error = Self.conflict
                }
                didLoad = true
            } catch {
                guard readID == token, presentationID == presentation, !Task.isCancelled else { return }
                self.error = MiraError.safe(error)
            }
        }
        readTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func discardChanges() {
        guard !isSaving else { return }
        baseline = latest
        routeID = latest?.routeID
        baselineFollowing = preferences.followsLastSelection(libraryID: library.id, scope: scope) ?? false
        followsLastSelection = baselineFollowing
        error = nil
    }
    func save(onSaved: @escaping @MainActor () async -> Void) {
        guard canSave, saveTask == nil else { return }
        let previous = baseline
        let selected = routeID
        let following = followsLastSelection
        let presentation = presentationID
        isSaving = true
        error = nil
        saveTask = Task {
            defer {
                saveTask = nil
                isSaving = false
            }
            do {
                let binding = try await library.binding()
                let saved: AgentRouteBinding?
                if following {
                    saved = previous
                } else if let selected {
                    _ = try await resolve(selected, with: binding.workgroup)
                    guard (previous?.revision ?? 0) < Int.max else { throw Self.conflict }
                    let value = AgentRouteBinding(
                        scope: scope, purpose: purpose, routeID: selected, revision: (previous?.revision ?? 0) + 1)
                    try await binding.workgroup.modelSettings.saveBinding(value, expectedRevision: previous?.revision)
                    saved = value
                } else {
                    if let previous {
                        try await binding.workgroup.modelSettings.deleteBinding(
                            scope: scope, purpose: purpose, expectedRevision: previous.revision)
                    }
                    saved = nil
                }
                guard presentationID == presentation, await isCurrent(binding) else { return }
                if purpose == AgentModelPurposeID.conversation {
                    preferences.setFollowing(following ? true : (selected == nil ? nil : false),
                                             libraryID: library.id, scope: scope)
                }
                baselineFollowing = following
                baseline = saved
                latest = saved
                await onSaved()
            } catch {
                guard presentationID == presentation else { return }
                self.error = MiraError.safe(error)
            }
        }
    }
    func stop() async {
        presentationID = UUID()
        readID = UUID()
        let read = readTask
        let save = saveTask
        read?.cancel()
        await read?.value
        await save?.value
        isLoading = false
    }
    func waitForSave() async { await saveTask?.value }
    private func resolve(_ routeID: RouteID, with group: MacLibraryWorkloads) async throws -> AgentModelRouteResolution {
        let workspace: WorkspaceID?
        switch scope {
        case .global:
            workspace = nil
        case .workspace(let id): workspace = id
        }
        return try await group.modelSettings.resolve(
            purpose: purpose, explicitRouteID: routeID, sessionSelection: .inherit,
            workspaceID: workspace, requiredCapabilities: requiredCapabilities)
    }
    private func isCurrent(_ binding: MacLibraryWorkgroupBinding) async -> Bool {
        guard let current = try? await library.binding() else { return false }
        return current.status.generation == binding.status.generation && current.workgroup === binding.workgroup
    }
    private static var conflict: MiraError {
        .init(.conflict, "The provider configuration changed. Discard your draft and try again.")
    }
}
