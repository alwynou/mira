import Foundation
import Observation
import MiraCore

struct KnowledgeImportOutcome: Identifiable {
    let id = UUID()
    let filename: String
    let receipt: KnowledgeImportReceipt?
    let error: MiraError?
}

@MainActor @Observable
final class KnowledgeModel {
    let application: MiraApplication
    private(set) var workspaceID: WorkspaceID?
    var sources: [KnowledgeSource] = []
    var hasMoreSources = false
    var searchHits: [KnowledgeSearchHit] = []
    var selectedID: KnowledgeSourceID?
    var selectedDetail: KnowledgeSourceDetail?
    var selectedChunk: SourceChunk?
    var query = ""
    var isLoading = false
    var isSearching = false
    var isImporting = false
    var error: MiraError?
    var importOutcomes: [KnowledgeImportOutcome] = []
    var searchIsTruncated = false
    var searchScannedCandidates = 0
    private var reloadGeneration = 0
    private var workspaceGeneration = 0
    private var searchGeneration = 0
    private var detailGeneration = 0
    private var chunkGeneration = 0
    private var requestedVersionID: SourceVersionID?
    private var detailLoadInFlight = false

    init(application: MiraApplication, workspaceID: WorkspaceID?) {
        self.application = application
        self.workspaceID = workspaceID
    }

    var searchIdentity: String {
        "\(workspaceID?.rawValue.uuidString ?? "global")|\(query)"
    }

    func updateWorkspace(_ workspaceID: WorkspaceID?) {
        guard self.workspaceID != workspaceID else { return }
        self.workspaceID = workspaceID
        workspaceGeneration += 1
        reloadGeneration += 1
        detailGeneration += 1
        chunkGeneration += 1
        searchGeneration += 1
        sources = []
        hasMoreSources = false
        searchHits = []
        selectedID = nil
        selectedDetail = nil
        selectedChunk = nil
        requestedVersionID = nil
        detailLoadInFlight = false
        error = nil
        importOutcomes = []
        searchIsTruncated = false
        searchScannedCandidates = 0
        isLoading = false
        isSearching = false
        isImporting = false
    }

    func observe() async {
        await reload()
        guard !Task.isCancelled else { return }
        let stream = await application.events()
        for await event in stream {
            guard !Task.isCancelled else { return }
            if case .changed = event { await reload() }
        }
    }

    func reload() async {
        let generation = reloadGeneration + 1
        reloadGeneration = generation
        isLoading = true
        do {
            let loaded = try await application.knowledgeSources(workspaceID: workspaceID, limit: 101)
            guard generation == reloadGeneration, !Task.isCancelled else { return }
            hasMoreSources = loaded.count > 100
            sources = Array(loaded.prefix(100))
            isLoading = false
            error = nil
            if let selectedID {
                await loadDetail(selectedID, versionID: requestedVersionID ?? selectedDetail?.selectedVersion?.id)
                guard generation == reloadGeneration, !Task.isCancelled else { return }
                if selectedDetail == nil, error?.code == .notFound {
                    self.selectedID = nil
                    selectedChunk = nil
                }
            }
            guard generation == reloadGeneration, !Task.isCancelled else { return }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await search() }
        } catch {
            guard generation == reloadGeneration, !Task.isCancelled else { return }
            isLoading = false
            self.error = MiraError.safe(error)
        }
    }

    func selectSource(_ id: KnowledgeSourceID?) {
        guard selectedID != id else { return }
        selectedID = id
        selectedDetail = nil
        selectedChunk = nil
        requestedVersionID = nil
        detailLoadInFlight = false
        detailGeneration += 1
        chunkGeneration += 1
    }

    func loadSelectedDetailIfNeeded() async {
        guard requestedVersionID == nil, selectedDetail == nil, !detailLoadInFlight else { return }
        await loadSelectedDetail()
    }

    func loadSelectedDetail() async {
        guard !detailLoadInFlight else { return }
        guard let selectedID else {
            selectedDetail = nil
            selectedChunk = nil
            return
        }
        let requestedVersionID = self.requestedVersionID
        self.requestedVersionID = nil
        await loadDetail(selectedID, versionID: requestedVersionID ?? selectedDetail?.selectedVersion?.id)
    }

    func selectVersion(_ versionID: SourceVersionID?) async {
        guard let selectedID else { return }
        await loadDetail(selectedID, versionID: versionID)
    }

    func openSearchHit(_ hit: KnowledgeSearchHit) async {
        guard hit.source.workspaceID == nil || hit.source.workspaceID == workspaceID else { return }
        if selectedID != hit.source.id {
            selectSource(hit.source.id)
        } else {
            selectedDetail = nil
            selectedChunk = nil
            requestedVersionID = hit.chunk.sourceVersionID
            detailGeneration += 1
            chunkGeneration += 1
        }
        requestedVersionID = hit.chunk.sourceVersionID
        await loadSelectedDetail()
        guard !Task.isCancelled, selectedDetail?.selectedVersion?.id == hit.chunk.sourceVersionID else { return }
        await loadChunk(hit.chunk)
    }

    func loadChunk(_ summary: SourceChunkSummary) async {
        guard selectedID == summary.sourceID else { return }
        let generation = chunkGeneration + 1
        chunkGeneration = generation
        do {
            let chunk = try await application.sourceChunk(summary.id, workspaceID: workspaceID)
            guard generation == chunkGeneration, !Task.isCancelled else { return }
            selectedChunk = chunk
            error = nil
        } catch {
            guard generation == chunkGeneration, !Task.isCancelled else { return }
            selectedChunk = nil
            self.error = MiraError.safe(error)
        }
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchHits = []
            searchIsTruncated = false
            searchScannedCandidates = 0
            isSearching = false
            return
        }
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        searchHits = []
        searchIsTruncated = false
        searchScannedCandidates = 0
        do {
            let result = try await application.searchKnowledge(query: trimmed, workspaceID: workspaceID, limit: 100)
            guard generation == searchGeneration, !Task.isCancelled else { return }
            searchHits = result.hits
            searchIsTruncated = result.isTruncated
            searchScannedCandidates = result.scannedCandidates
            isSearching = false
        } catch {
            guard generation == searchGeneration, !Task.isCancelled else { return }
            isSearching = false
            self.error = MiraError.safe(error)
        }
    }

    func importFiles(_ urls: [URL], updating source: KnowledgeSource? = nil) async {
        guard !urls.isEmpty, !isImporting else { return }
        guard urls.count <= 100, source == nil || urls.count == 1 else {
            error = MiraError(.invalidInput, "Select at most 100 Markdown files, or one file when updating a source.")
            return
        }
        let scope = workspaceID
        let generation = workspaceGeneration
        let sourceID = source?.id
        let expectedRevision = source?.revision
        if let source, source.workspaceID != scope {
            error = MiraError(.invalidInput, "The selected source belongs to another workspace.")
            return
        }
        isImporting = true
        importOutcomes = []
        error = nil
        for url in urls {
            guard !Task.isCancelled, scope == workspaceID, generation == workspaceGeneration else { break }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 10 * 1024 * 1024 {
                importOutcomes.append(.init(filename: url.lastPathComponent, receipt: nil,
                                            error: MiraError(.invalidInput, "The Markdown file exceeds the 10 MiB limit.")))
                continue
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let receipt = try await application.importMarkdownFile(url, workspaceID: scope,
                                                                         updating: sourceID,
                                                                         expectedRevision: expectedRevision)
                guard !Task.isCancelled, scope == workspaceID, generation == workspaceGeneration else { break }
                importOutcomes.append(.init(filename: url.lastPathComponent, receipt: receipt, error: nil))
                if selectedID == nil { selectedID = receipt.source.id }
            } catch {
                guard !Task.isCancelled, scope == workspaceID, generation == workspaceGeneration else { break }
                importOutcomes.append(.init(filename: url.lastPathComponent, receipt: nil, error: MiraError.safe(error)))
            }
        }
        guard !Task.isCancelled, scope == workspaceID, generation == workspaceGeneration else { isImporting = false; return }
        await reload()
        isImporting = false
    }

    @discardableResult
    func saveRemoteUse(_ allowed: Bool) async -> Bool {
        guard let source = selectedDetail?.source else { return false }
        let sourceID = source.id
        let expectedRevision = source.revision
        do {
            let updated = try await application.setSourceRemoteUse(sourceID, workspaceID: workspaceID,
                                                                    allowed: allowed, expectedRevision: expectedRevision)
            guard !Task.isCancelled, selectedID == sourceID,
                  selectedDetail?.source.id == sourceID else { return false }
            selectedDetail?.source = updated
            if let index = sources.firstIndex(where: { $0.id == updated.id }) { sources[index] = updated }
            error = nil
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            self.error = MiraError.safe(error)
            return false
        }
    }

    func deleteSelected() async {
        guard let source = selectedDetail?.source else { return }
        await delete(source)
    }

    func delete(_ source: KnowledgeSource) async {
        do {
            try await application.deleteKnowledgeSource(source.id, workspaceID: source.workspaceID, expectedRevision: source.revision)
            guard !Task.isCancelled else { return }
            if selectedID == source.id {
                selectedID = nil
                selectedDetail = nil
                selectedChunk = nil
            }
            await reload()
        } catch {
            guard !Task.isCancelled else { return }
            self.error = MiraError.safe(error)
        }
    }

    private func loadDetail(_ id: KnowledgeSourceID, versionID: SourceVersionID?) async {
        selectedID = id
        let generation = detailGeneration + 1
        detailGeneration = generation
        detailLoadInFlight = true
        chunkGeneration += 1
        if let chunk = selectedChunk, chunk.summary.sourceID != id || (versionID != nil && chunk.summary.sourceVersionID != versionID) {
            selectedChunk = nil
        }
        do {
            let detail = try await application.knowledgeSource(id, versionID: versionID, workspaceID: workspaceID)
            guard generation == detailGeneration, selectedID == id, !Task.isCancelled else {
                if generation == detailGeneration { detailLoadInFlight = false }
                return
            }
            selectedDetail = detail
            if selectedChunk?.summary.sourceVersionID != detail.selectedVersion?.id { selectedChunk = nil }
            detailLoadInFlight = false
            error = nil
        } catch {
            guard generation == detailGeneration, selectedID == id, !Task.isCancelled else {
                if generation == detailGeneration { detailLoadInFlight = false }
                return
            }
            selectedDetail = nil
            selectedChunk = nil
            detailLoadInFlight = false
            self.error = MiraError.safe(error)
        }
    }
}
