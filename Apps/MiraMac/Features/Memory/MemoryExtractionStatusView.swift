import SwiftUI
import MiraCore

@MainActor
struct MemoryExtractionStatusView: View {
    @Environment(\.locale) private var locale
    let application: MiraApplication
    let conversationID: ConversationID?
    let onOpenMemory: (MemoryID) -> Void
    let onOpenSource: (MessageID) -> Void

    @State private var jobs: [MemoryExtractionJob] = []
    @State private var isLoading = true
    @State private var error: MiraError?
    @State private var retrying: Set<MemoryExtractionJobID> = []
    @State private var retryTasks: [MemoryExtractionJobID: Task<Void, Never>] = [:]
    @State private var captureMode: MemoryCaptureMode = .manualOnly
    @State private var scopeGeneration = 0

    var body: some View {
        Group {
            if isLoading && jobs.isEmpty {
                ProgressView("Loading extraction status")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if jobs.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    captureModeStatus
                    List(jobs) { job in
                        jobRow(job)
                    }
                    .listStyle(.inset)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let error {
                Text(L10n.error(error, locale: locale))
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding()
            }
        }
        .task(id: conversationID) {
            resetForScope()
            await observeJobs()
        }
        .onDisappear {
            retryTasks.values.forEach { $0.cancel() }
            retryTasks.removeAll()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: emptyStateSystemImage)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(L10n.string(emptyStateTitleKey, locale: locale))
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(L10n.string(emptyStateDescriptionKey, locale: locale))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if captureMode == .manualOnly {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var captureModeStatus: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: captureModeSystemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.format("Capture mode: %@", locale: locale, L10n.string(captureModeKey, locale: locale)))
                    .font(.callout)
                Text(L10n.string(captureModeStatusDescriptionKey, locale: locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if captureMode == .manualOnly {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary)
    }

    private var emptyStateSystemImage: String {
        switch captureMode {
        case .manualOnly: "brain" // i18n-verbatim: SF Symbol identifier, not display copy.
        case .candidateOnly: "checkmark.circle" // i18n-verbatim: SF Symbol identifier, not display copy.
        case .automaticWithUndo: "sparkles" // i18n-verbatim: SF Symbol identifier, not display copy.
        }
    }

    private var emptyStateTitleKey: String {
        switch captureMode {
        case .manualOnly: "Automatic memory is off"
        case .candidateOnly: "No candidate extraction yet"
        case .automaticWithUndo: "No automatic capture yet"
        }
    }

    private var emptyStateDescriptionKey: String {
        switch captureMode {
        case .manualOnly:
            "Ordinary statements are not saved automatically. Enable automatic memory and choose a dedicated extraction route in Settings."
        case .candidateOnly:
            "After your next completed conversation, eligible memories will be extracted as candidates for your review. They will not enter recall automatically."
        case .automaticWithUndo:
            "After your next completed conversation, eligible memories may be saved automatically. You can undo, edit, archive, or forget them."
        }
    }

    private var captureModeKey: String {
        switch captureMode {
        case .manualOnly: "Manual only"
        case .candidateOnly: "Candidate review"
        case .automaticWithUndo: "Automatic with undo"
        }
    }

    private var captureModeSystemImage: String {
        switch captureMode {
        case .manualOnly: "pause.circle" // i18n-verbatim: SF Symbol identifier, not display copy.
        case .candidateOnly: "checkmark.circle" // i18n-verbatim: SF Symbol identifier, not display copy.
        case .automaticWithUndo: "sparkles" // i18n-verbatim: SF Symbol identifier, not display copy.
        }
    }

    private var captureModeStatusDescriptionKey: String {
        switch captureMode {
        case .manualOnly:
            "Automatic capture is off. Existing extraction jobs remain available below; ordinary statements are not saved automatically."
        case .candidateOnly:
            "Candidate capture is enabled. New eligible memories will wait for your review."
        case .automaticWithUndo:
            "Automatic capture is enabled. Eligible memories may be saved with undo controls."
        }
    }

    private func jobRow(_ job: MemoryExtractionJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.string(jobStateKey(job), locale: locale)).font(.headline)
                Spacer()
                Text(job.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text(L10n.format("Attempts: %lld", locale: locale, Int64(job.attemptCount)))
                Text(L10n.format("Memories: %lld", locale: locale, Int64(job.memoryIDs.count)))
                if !candidateMemoryIDs(for: job).isEmpty {
                    Text(L10n.format("Review required: %lld", locale: locale, Int64(candidateMemoryIDs(for: job).count)))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            CostSummaryView(calls: job.callUsages, isBackground: true)
            if !job.callUsages.isEmpty {
                DisclosureGroup("Model call usage") {
                    ForEach(job.callUsages) { call in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: call.route.modelID)
                            Text(call.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            UsageCostView(usage: call.usage, route: call.route, isComplete: call.isComplete)
                            if let metadata = call.route.catalogMetadata, metadata.pricing != nil {
                                Text(L10n.format("Catalog retrieved: %@", locale: locale, metadata.retrievedAt))
                                Text(verbatim: metadata.sourceRevision).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            }
                        }.font(.caption).padding(.vertical, 6)
                    }
                }
            }

            if let error = job.error {
                Text(L10n.error(error, locale: locale))
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button("Open source") { onOpenSource(job.sourceMessageID) }
                    .buttonStyle(.link)
                ForEach(job.memoryIDs, id: \.self) { memoryID in
                    Button("Open memory") {
                        onOpenMemory(memoryID)
                    }
                        .buttonStyle(.link)
                }
                if captureMode != .manualOnly && canRetry(job.state) {
                    Button("Retry") { retry(job) }
                        .buttonStyle(.bordered)
                        .disabled(retrying.contains(job.id))
                    if retrying.contains(job.id) { ProgressView().controlSize(.small) }
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private func canRetry(_ state: MemoryExtractionJobState) -> Bool {
        switch state {
        case .paused, .failed, .cancelled: true
        case .queued, .running, .completed, .suppressed: false
        }
    }

    private func candidateMemoryIDs(for job: MemoryExtractionJob) -> Set<MemoryID> {
        Set(job.candidateMemoryIDs).intersection(job.memoryIDs)
    }

    private func jobStateKey(_ job: MemoryExtractionJob) -> String {
        if job.state == .completed {
            if !candidateMemoryIDs(for: job).isEmpty { return "Needs review" }
            if job.memoryIDs.isEmpty { return "No memories extracted" }
            return "Completed"
        }
        switch job.state {
        case .queued: return "Queued"
        case .running: return "Processing"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .suppressed: return "Suppressed"
        }
    }

    private func observeJobs() async {
        await reload()
        guard !Task.isCancelled else { return }
        let stream = await application.events()
        for await event in stream {
            guard !Task.isCancelled else { return }
            if case .changed = event { await reload() }
        }
    }

    private func reload() async {
        let generation = scopeGeneration
        do {
            let policy = try await application.memoryCapturePolicy()
            guard !Task.isCancelled, generation == scopeGeneration else { return }
            let loaded = try await application.memoryExtractionJobs(conversationID: conversationID, limit: 10)
            guard !Task.isCancelled, generation == scopeGeneration else { return }
            captureMode = policy.mode
            jobs = loaded
            isLoading = false
            error = nil
        } catch {
            guard !Task.isCancelled, generation == scopeGeneration else { return }
            isLoading = false
            self.error = MiraError.safe(error)
        }
    }

    private func retry(_ job: MemoryExtractionJob) {
        guard captureMode != .manualOnly, canRetry(job.state), retrying.insert(job.id).inserted else { return }
        let generation = scopeGeneration
        let task = Task { @MainActor in
            defer {
                if generation == scopeGeneration {
                    retrying.remove(job.id)
                    retryTasks[job.id] = nil
                }
            }
            do {
                try await application.retryMemoryExtraction(job.id)
                guard !Task.isCancelled, generation == scopeGeneration else { return }
                await reload()
            } catch {
                guard !Task.isCancelled, generation == scopeGeneration else { return }
                self.error = MiraError.safe(error)
            }
        }
        retryTasks[job.id] = task
    }

    private func resetForScope() {
        scopeGeneration += 1
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
        retrying.removeAll()
        jobs.removeAll()
        error = nil
        isLoading = true
        captureMode = .manualOnly
    }
}
