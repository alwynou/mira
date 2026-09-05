import Foundation
import Observation
import MiraCore

enum MemoryListFilter: String, CaseIterable, Identifiable {
    case active, candidate, archived, rejected, removed, all
    var id: Self { self }
    var states: Set<MemoryState> {
        switch self {
        case .all: Set(MemoryState.allCases)
        case .active: [.active]
        case .candidate: [.candidate]
        case .archived: [.archived]
        case .rejected: [.rejected]
        case .removed: [.removed]
        }
    }
    var titleKey: String {
        switch self {
        case .active: "Active"
        case .candidate: "Needs review"
        case .archived: "Archived"
        case .rejected: "Rejected"
        case .removed: "Removed"
        case .all: "All states"
        }
    }
}

@MainActor @Observable
final class MemoryModel {
    let application: MiraApplication
    private(set) var workspaceID: WorkspaceID?
    var memories: [Memory] = []
    var selectedID: MemoryID?
    var selectedDetail: MemoryDetail?
    var query = ""
    var filter: MemoryListFilter = .active
    var isLoading = false
    var error: MiraError?
    var listWasTruncated = false
    private var reloadGeneration = 0
    private var detailGeneration = 0

    init(application: MiraApplication, workspaceID: WorkspaceID?) {
        self.application = application
        self.workspaceID = workspaceID
    }

    var searchIdentity: String {
        "\(workspaceID?.rawValue.uuidString ?? "global")|\(filter.rawValue)|\(query)"
    }

    /// Clears the previous scope before the next scoped query starts. In-flight
    /// requests are invalidated so a result for the old workspace cannot land
    /// in the newly selected scope.
    func updateWorkspace(_ workspaceID: WorkspaceID?) {
        guard self.workspaceID != workspaceID else { return }
        self.workspaceID = workspaceID
        reloadGeneration += 1
        detailGeneration += 1
        memories = []
        selectedID = nil
        selectedDetail = nil
        listWasTruncated = false
        error = nil
        isLoading = false
    }

    /// Selects a memory opened from another surface. The all-state filter is
    /// required because extraction results can be candidates or removed rows.
    /// The existing workspace scope remains authoritative for both list and detail loads.
    func selectInitialMemory(_ id: MemoryID?) {
        guard let id else { return }
        guard selectedID != id || filter != .all || selectedDetail?.memory.id != id else { return }
        filter = .all
        reloadGeneration += 1
        detailGeneration += 1
        selectedID = id
        selectedDetail = nil
        error = nil
    }

    func observe() async {
        await reload()
        let stream = await application.events()
        for await event in stream {
            if Task.isCancelled { return }
            if case .changed = event { await reload() }
        }
    }

    func reload() async {
        let generation = reloadGeneration + 1
        reloadGeneration = generation
        isLoading = true
        defer {
            if generation == reloadGeneration { isLoading = false }
        }
        do {
            let result = try await application.memoryList(workspaceID: workspaceID, states: filter.states, query: query, limit: 100)
            guard generation == reloadGeneration else { return }
            memories = result.memories
            listWasTruncated = result.isTruncated
            if let selectedID, !memories.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
                selectedDetail = nil
            }
            if self.selectedID != nil { await loadSelectedDetail() }
            guard generation == reloadGeneration else { return }
            error = nil
        } catch {
            guard generation == reloadGeneration else { return }
            self.error = MiraError.safe(error)
        }
    }

    func loadSelectedDetail() async {
        guard let selectedID else { selectedDetail = nil; return }
        if selectedDetail?.memory.id != selectedID { selectedDetail = nil }
        let generation = detailGeneration + 1
        detailGeneration = generation
        do {
            let detail = try await application.memoryDetail(selectedID, workspaceID: workspaceID)
            guard generation == detailGeneration, self.selectedID == selectedID, !Task.isCancelled else { return }
            selectedDetail = detail
            error = nil
        } catch {
            guard generation == detailGeneration, !Task.isCancelled else { return }
            selectedDetail = nil
            self.error = MiraError.safe(error)
        }
    }

    func refreshAfterMutation() async {
        await reload()
        await loadSelectedDetail()
    }
}
