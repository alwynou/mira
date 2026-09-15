import MiraCore
import MiraProviders
import SwiftUI

/// Independent business accounting is observed through the library-owned application service.
struct MemoryExtractionInspector: View {
    @Environment(\.locale) private var locale
    let library: MacLibrary
    let sessionID: ConversationID
    let executionID: ExecutionID
    let workspaceID: WorkspaceID?
    @State private var reader = MacSessionReadModel<MemoryExtractionStatusPage>()
    @State private var before: MemoryExtractionStatusCursor?
    @State private var selectedID: MemoryExtractionJobID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Automatic memory").font(.subheadline.weight(.semibold))
            if let page = reader.value {
                if page.jobs.isEmpty {
                    Text("No extraction jobs recorded").font(.caption).foregroundStyle(.secondary)
                } else {
                    if page.jobs.count > 1 {
                        Picker("Extraction job", selection: $selectedID) {
                            Text("Latest job").tag(nil as MemoryExtractionJobID?)
                            ForEach(page.jobs) { job in
                                Text(job.createdAt, format: .dateTime.month().day().hour().minute().second())
                                    .tag(Optional(job.id))
                            }
                        }
                    }
                    if let job = page.jobs.first(where: { $0.id == selectedID }) ?? page.jobs.first {
                        ExtractionJobDetail(library: library, job: job).id(job.id)
                    }
                }
                HStack {
                    if before != nil {
                        Button("Latest jobs") {
                            selectedID = nil
                            before = nil
                        }
                    }
                    if let next = page.nextCursor {
                        Button("Earlier jobs") {
                            selectedID = nil
                            before = next
                        }
                    }
                }.font(.caption)
            } else if let error = reader.error {
                Text(L10n.error(error, locale: locale)).font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityIdentifier("conversation.extractionInspector")
        .task(id: before) {
            let cursor = before
            await reader.observe(library: library, sessionID: sessionID) { group in
                try await group.memories.extractionStatus(
                    sessionID: sessionID, executionID: executionID,
                    workspaceID: workspaceID, before: cursor)
            }
        }
    }
}

private struct ExtractionJobDetail: View {
    @Environment(\.locale) private var locale
    let library: MacLibrary
    let job: MemoryExtractionJobSummary
    @State private var reader = MacSessionReadModel<MemoryExtractionJobReport>()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let report = reader.value {
                LabeledContent("Status", value: L10n.string(report.job.state.extractionTitle, locale: locale))
                CostSummaryView(summary: .init(extractionAttempts: report.attempts), priority: .background)
                ForEach(report.attempts) { attempt in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("Status", value: L10n.string(attempt.state.extractionTitle, locale: locale))
                            LabeledContent("Budget reservation (tokens)") {
                                Text(attempt.reservedTokens, format: .number)
                            }
                            LabeledContent("Budget charge (tokens)") { Text(attempt.chargedTokens, format: .number) }
                            if attempt.dispatchedAt != nil {
                                UsageCostView(
                                    usage: attempt.usage ?? .init(), route: attempt.route,
                                    isComplete: attempt.state == .completed)
                            } else {
                                Text("No recorded calls").foregroundStyle(.secondary)
                            }
                            if attempt.bodyPurgedAt != nil {
                                Label("Audit content cleared", systemImage: "eye.slash").foregroundStyle(.secondary)
                            }
                        }.font(.caption)
                    } label: {
                        Text(L10n.format("Attempt %lld", locale: locale, Int64(attempt.ordinal))).font(.caption)
                    }
                }
            } else if let error = reader.error {
                Text(L10n.error(error, locale: locale)).font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            await reader.observe(library: library, sessionID: job.sessionID) { group in
                try await group.memories.extractionReport(
                    job.id, sessionID: job.sessionID,
                    executionID: job.executionID, workspaceID: job.workspaceID)
            }
        }
    }
}

extension MemoryExtractionJobState {
    fileprivate var extractionTitle: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .suppressed: "Suppressed"
        }
    }
}

extension MemoryExtractionAttemptState {
    fileprivate var extractionTitle: String {
        switch self {
        case .claimed: "Waiting for preparation"
        case .prepared: "Prepared"
        case .dispatched: "Dispatched"
        case .completed: "Completed"
        case .failed: "Failed"
        case .paused: "Paused"
        }
    }
}
