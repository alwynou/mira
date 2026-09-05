import SwiftUI
import MiraCore

@MainActor
struct MemoryReplacementReviewView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    let application: MiraApplication
    let candidate: Memory
    let relation: MemoryReplacement
    let workspaceID: WorkspaceID?
    let workspaces: [Workspace]
    let onChanged: () async -> Void
    let onReject: () -> Void

    @State private var reviewedCandidate: Memory?
    @State private var reviewedRelation: MemoryReplacement?
    @State private var currentDetail: MemoryDetail?
    @State private var isLoading = true
    @State private var isConfirming = false
    @State private var requiresReload = false
    @State private var error: MiraError?
    @State private var unavailable: ReviewAvailability?
    @State private var loadGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Review replacement").font(.title2.weight(.semibold))
                    Text("Compare the proposed memory with the current version before confirming the replacement.")
                        .foregroundStyle(.secondary)

                    candidateSection
                    reviewState

                    if let error {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.error(error, locale: locale))
                                .font(.callout)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                            Button("Reload review") { reload() }
                        }
                    }
                }
                .padding(.bottom, 12)
            }

            Divider().padding(.vertical, 10)
            actionBar
        }
        .padding(28)
        .frame(width: 700)
        .frame(maxHeight: 650)
        .interactiveDismissDisabled(isConfirming)
        .task(id: loadGeneration) { await loadCurrentVersion() }
    }

    @ViewBuilder
    private var reviewState: some View {
        if isLoading {
            ProgressView("Loading current version")
                .frame(maxWidth: .infinity, alignment: .center)
        } else if let currentDetail {
            currentSection(currentDetail.memory)
            if let messageKey = availabilityMessageKey {
                unavailableContent(messageKey)
            }
        } else if let unavailable {
            unavailableContent(unavailable.messageKey)
        } else {
            unavailableContent("The current version is unavailable. Reload review or reject this candidate.")
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack {
            Button("Reject candidate", role: .destructive) {
                onReject()
                dismiss()
            }
            .disabled(isConfirming)

            Button("Close", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isConfirming)

            Spacer()

            Button("Confirm replacement") { confirm() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isConfirmable || isConfirming || isLoading)
            if isConfirming { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder
    private func unavailableContent(_ messageKey: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(messageKey).font(.callout).foregroundStyle(.orange)
            Button("Reload review") { reload() }
        }
    }

    private var candidateSnapshot: Memory { reviewedCandidate ?? candidate }

    private var candidateSection: some View {
        GroupBox("Proposed memory") {
            VStack(alignment: .leading, spacing: 8) {
                bodyView(candidateSnapshot.draft?.content, unavailableKey: "Candidate body unavailable.")
                metadataRow("Revision", value: String(candidateSnapshot.revision), localizeValue: false)
                scopeRow(candidateSnapshot.scope)
                metadataRow("Subject", value: candidateSnapshot.subject == .user ? "User" : "Workspace", localizeValue: true)
            }
        }
    }

    private func currentSection(_ current: Memory) -> some View {
        GroupBox("Current memory") {
            VStack(alignment: .leading, spacing: 8) {
                bodyView(current.draft?.content, unavailableKey: "Current body unavailable.")
                metadataRow("Revision", value: String(current.revision), localizeValue: false)
                scopeRow(current.scope)
                metadataRow("Subject", value: current.subject == .user ? "User" : "Workspace", localizeValue: true)
            }
        }
    }

    @ViewBuilder
    private func bodyView(_ content: String?, unavailableKey: LocalizedStringKey) -> some View {
        if let content {
            Text(verbatim: content)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(unavailableKey).foregroundStyle(.secondary)
        }
    }

    private func metadataRow(_ label: LocalizedStringKey, value: String, localizeValue: Bool) -> some View {
        LabeledContent(label) {
            if localizeValue { Text(L10n.string(value, locale: locale)) }
            else { Text(verbatim: value) }
        }
        .font(.caption)
    }

    private func scopeRow(_ scope: MemoryScope) -> some View {
        LabeledContent("Scope") {
            scopeValue(scope)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func scopeValue(_ scope: MemoryScope) -> some View {
        switch scope {
        case .global:
            Text("Global")
        case .workspace(let id):
            if let name = workspaces.first(where: { $0.id == id })?.name {
                Text(verbatim: name)
            } else {
                Text("Workspace")
            }
        }
    }

    private var availability: ReviewAvailability? {
        let candidate = candidateSnapshot
        guard let relation = reviewedRelation,
              relation.replacementID == candidate.id,
              relation.state == .proposed else { return .relationUnavailable }
        guard candidate.state == .candidate, candidate.deletedAt == nil,
              candidate.forgottenAt == nil, candidate.supersededBy == nil,
              candidate.draft?.content != nil else { return .candidateUnavailable }
        guard let current = currentDetail?.memory else { return nil }
        guard current.state == .active, current.deletedAt == nil,
              current.forgottenAt == nil, current.supersededBy == nil,
              current.draft?.content != nil else { return .currentUnavailable }
        guard current.scope == candidate.scope else { return .scopeMismatch }
        guard current.subject == candidate.subject else { return .subjectMismatch }
        return .available
    }

    private var isConfirmable: Bool {
        !requiresReload && availability == .available && reviewedCandidate != nil && reviewedRelation != nil
    }

    private var availabilityMessageKey: LocalizedStringKey? {
        guard let availability, availability != .available else { return nil }
        return availability.messageKey
    }

    private func loadCurrentVersion() async {
        let generation = loadGeneration
        isLoading = true
        reviewedCandidate = nil
        reviewedRelation = nil
        currentDetail = nil
        unavailable = nil
        error = nil
        requiresReload = false
        defer {
            if generation == loadGeneration { isLoading = false }
        }

        do {
            let candidateDetail = try await application.memoryDetail(candidate.id, workspaceID: workspaceID)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            guard candidateDetail.memory.id == candidate.id else {
                unavailable = .candidateUnavailable
                return
            }
            guard candidateDetail.memory.supersededBy == nil else {
                unavailable = .candidateUnavailable
                return
            }
            guard let actualRelation = candidateDetail.replacements.first(where: {
                $0.replacementID == candidate.id && $0.state == .proposed
            }) else {
                unavailable = .relationUnavailable
                return
            }
            reviewedCandidate = candidateDetail.memory
            reviewedRelation = actualRelation

            var nextID = actualRelation.previousID
            var visited = Set<MemoryID>()
            for _ in 0..<100 {
                guard generation == loadGeneration, !Task.isCancelled else { return }
                guard visited.insert(nextID).inserted else {
                    unavailable = .cycleDetected
                    return
                }
                let loaded = try await application.memoryDetail(nextID, workspaceID: workspaceID)
                guard generation == loadGeneration, !Task.isCancelled else { return }
                if loaded.memory.id == candidate.id {
                    unavailable = .cycleDetected
                    return
                }
                if let supersededBy = loaded.memory.supersededBy {
                    nextID = supersededBy
                } else {
                    currentDetail = loaded
                    return
                }
            }
            guard generation == loadGeneration, !Task.isCancelled else { return }
            unavailable = .chainTooLong
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            self.error = MiraError.safe(error)
        }
    }

    private func reload() {
        guard !isConfirming else { return }
        loadGeneration += 1
    }

    private func confirm() {
        guard isConfirmable,
              let candidate = reviewedCandidate,
              let current = currentDetail?.memory else { return }
        isConfirming = true
        error = nil
        let candidateID = candidate.id
        let candidateRevision = candidate.revision
        let currentID = current.id
        let currentRevision = current.revision
        Task { @MainActor in
            defer { isConfirming = false }
            do {
                _ = try await application.confirmMemoryReplacement(
                    candidateID,
                    workspaceID: workspaceID,
                    replacingCurrent: currentID,
                    expectedCandidateRevision: candidateRevision,
                    expectedCurrentRevision: currentRevision
                )
                await onChanged()
                dismiss()
            } catch {
                requiresReload = true
                self.error = MiraError.safe(error)
            }
        }
    }
}

private enum ReviewAvailability: Equatable {
    case available
    case relationUnavailable
    case candidateUnavailable
    case currentUnavailable
    case scopeMismatch
    case subjectMismatch
    case cycleDetected
    case chainTooLong

    var messageKey: LocalizedStringKey {
        switch self {
        case .available: ""
        case .relationUnavailable: "This candidate is not linked to the proposed replacement. Reload review or reject it."
        case .candidateUnavailable: "This candidate is no longer available for confirmation. Reload review or reject it."
        case .currentUnavailable: "The previous memory is no longer the current active version. Reload review or reject this candidate."
        case .scopeMismatch: "The candidate and current memory have different scopes. Reload review or reject this candidate."
        case .subjectMismatch: "The candidate and current memory have different subjects. Reload review or reject this candidate."
        case .cycleDetected: "The replacement chain contains a cycle. Reload review or reject this candidate."
        case .chainTooLong: "The replacement chain is too long to review safely. Reload review or reject this candidate."
        }
    }
}
