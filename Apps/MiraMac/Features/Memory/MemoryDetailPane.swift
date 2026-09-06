import SwiftUI
import MiraCore

struct MemoryDetailPane: View {
    @Environment(\.locale) private var locale
    let detail: MemoryDetail
    let workspaces: [Workspace]
    let application: MiraApplication
    let workspaceID: WorkspaceID?
    let onEdit: (Memory) -> Void
    let onReplace: (Memory) -> Void
    let onOpenConversation: (ConversationID) -> Void
    let onChanged: () async -> Void
    @State private var isWorking = false
    @State private var showingForgetConfirmation = false
    @State private var replacementReview: MemoryReplacement?
    @State private var error: MiraError?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                contentSection
                metadataSection
                if !detail.evidence.isEmpty { evidenceSection }
                if !detail.replacements.isEmpty { replacementsSection }
                if !detail.revisions.isEmpty { revisionsSection }
                if let error { Text(L10n.error(error, locale: locale)).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .confirmationDialog("Forget this memory?", isPresented: $showingForgetConfirmation, titleVisibility: .visible) {
            Button("Forget memory", role: .destructive) { forget() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The memory content and revisions will be cleared, and Mira will stop recalling it. Historical messages and replies remain visible in conversation history with a forgotten-memory status tag.")
        }
        .sheet(item: $replacementReview) { relation in
            MemoryReplacementReviewView(application: application, candidate: detail.memory, relation: relation,
                                        workspaceID: workspaceID, workspaces: workspaces, onChanged: onChanged,
                                        onReject: { changeState(.rejected) })
                .environment(\.locale, locale)
        }
    }

    private var header: some View {
        let lifecycleStatus = detail.memory.lifecycleStatus(at: .now)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.string(memoryKindKey(detail.memory.draft?.kind ?? .context), locale: locale)).font(.title2.weight(.semibold))
                Text(L10n.string(memoryLifecycleStatusKey(lifecycleStatus), locale: locale)).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 8) {
                scopeView(detail.memory.scope)
                Text(L10n.string(memorySubjectKey(detail.memory.subject), locale: locale))
                Text(L10n.format("Revision %@", locale: locale, String(detail.memory.revision)))
            }.font(.caption).foregroundStyle(.secondary)
            actions
        }
    }

    @ViewBuilder private var actions: some View {
        HStack {
            if canEdit {
                Button("Edit") { onEdit(detail.memory) }.keyboardShortcut("e", modifiers: [.command])
                Button("Replace memory") { onReplace(detail.memory) }
            }
            if detail.memory.state == .candidate {
                Button("Approve") { changeState(.active) }.buttonStyle(.borderedProminent).disabled(hasUnresolvedReplacement)
                if let proposedReplacement { Button("Review replacement") { replacementReview = proposedReplacement } }
                Button("Reject", role: .destructive) { changeState(.rejected) }
            }
            if detail.memory.state == .active || detail.memory.state == .candidate { Button("Archive") { changeState(.archived) } }
            if detail.memory.state == .archived { Button("Restore") { changeState(.active) } }
            if detail.memory.state == .rejected { Button("Restore for review") { changeState(.candidate) } }
            if detail.memory.state == .removed, detail.memory.forgottenAt == nil {
                Button("Restore for review") { changeState(.candidate) }
                Button("Forget…", role: .destructive) { showingForgetConfirmation = true }
            } else if [.active, .candidate, .archived, .rejected].contains(detail.memory.state) {
                Button("Remove", role: .destructive) { changeState(.removed) }
                Button("Forget…", role: .destructive) { showingForgetConfirmation = true }
            }
            if isWorking { ProgressView().controlSize(.small) }
        }
        .buttonStyle(.bordered)
        .disabled(isWorking)
        if hasUnresolvedReplacement {
            Text("A competing replacement is awaiting review. Reject it or review the current successor before approving.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var canEdit: Bool { detail.memory.draft != nil && detail.memory.state != .removed && detail.memory.forgottenAt == nil }
    private var hasUnresolvedReplacement: Bool {
        proposedReplacement != nil
    }
    private var proposedReplacement: MemoryReplacement? {
        detail.replacements.first { $0.replacementID == detail.memory.id && $0.state == .proposed }
    }
    private var contentSection: some View {
        GroupBox("Memory content") {
            if let content = detail.memory.draft?.content { Text(verbatim: content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            else { Label("Memory content was forgotten and is no longer available.", systemImage: "eye.slash").foregroundStyle(.secondary) }
        }
    }
    private var metadataSection: some View {
        GroupBox("Details") {
            VStack(alignment: .leading, spacing: 7) {
                detailRow("Origin", value: memoryOriginKey(detail.memory.origin))
                detailRow("Authority", value: memoryAuthorityKey(detail.memory.authority))
                detailRow("Sensitivity", value: memorySensitivityKey(detail.memory.draft?.sensitivity ?? .standard))
                if let draft = detail.memory.draft {
                    detailRow("Remote use", value: draft.allowsRemoteUse ? "Allowed" : "Not allowed")
                    if let from = draft.validFrom { dateRow("Valid from", date: from) }
                    if let until = draft.validUntil { dateRow("Valid until", date: until) }
                }
                if let supersededBy = detail.memory.supersededBy { Text(L10n.format("Superseded by %@", locale: locale, supersededBy.rawValue.uuidString)).font(.caption) }
                if let forgottenAt = detail.memory.forgottenAt { dateRow("Forgotten", date: forgottenAt) }
            }
        }
    }
    private var evidenceSection: some View {
        GroupBox("Evidence") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(detail.evidence) { evidence in
                    EvidenceRow(evidence: evidence, onOpenConversation: onOpenConversation)
                }
            }
        }
    }
    private var replacementsSection: some View {
        GroupBox("Replacement history") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(detail.replacements) { replacement in
                    HStack {
                        Text(L10n.string(replacementStateKey(replacement.state), locale: locale))
                        Text(L10n.format("Previous %@", locale: locale, replacement.previousID.rawValue.uuidString)).font(.caption)
                        Text(L10n.format("Replacement %@", locale: locale, replacement.replacementID.rawValue.uuidString)).font(.caption)
                    }
                }
            }
        }
    }
    private var revisionsSection: some View {
        GroupBox("Revisions") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(detail.revisions) { revision in
                    DisclosureGroup {
                        if revision.bodyPurgedAt != nil {
                            Text("Revision body was cleared after forgetting this memory.").font(.caption).foregroundStyle(.secondary)
                        } else if let content = revision.draft?.content {
                            Text(verbatim: content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("Revision content unavailable.").font(.caption).foregroundStyle(.secondary)
                        }
                    } label: {
                        HStack {
                            Text(L10n.format("Revision %@", locale: locale, String(revision.revision)))
                            Text(verbatim: revision.actor).font(.caption)
                            Spacer()
                            Text(revision.changedAt, format: .dateTime).font(.caption)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func scopeView(_ scope: MemoryScope) -> some View {
        switch scope {
        case .global: Text("Global")
        case .workspace(let id):
            if let name = workspaces.first(where: { $0.id == id })?.name { Text(verbatim: name) }
            else { Text("Workspace") }
        }
    }
    private func detailRow(_ label: LocalizedStringKey, value: String) -> some View { LabeledContent(label) { Text(L10n.string(value, locale: locale)) } }
    private func dateRow(_ label: LocalizedStringKey, date: Date) -> some View { LabeledContent(label) { Text(date, format: .dateTime) } }

    private func changeState(_ state: MemoryState) {
        isWorking = true; error = nil
        let memory = detail.memory
        Task { @MainActor in
            defer { isWorking = false }
            do {
                _ = try await application.changeMemoryState(memory.id, workspaceID: workspaceID, state: state, expectedRevision: memory.revision)
                await onChanged()
            } catch { self.error = MiraError.safe(error) }
        }
    }
    private func forget() {
        isWorking = true; error = nil
        let memory = detail.memory
        Task { @MainActor in
            defer { isWorking = false }
            do {
                _ = try await application.forgetMemory(memory.id, workspaceID: workspaceID, expectedRevision: memory.revision)
                await onChanged()
            } catch { self.error = MiraError.safe(error) }
        }
    }
}

private struct EvidenceRow: View {
    @Environment(\.locale) private var locale
    let evidence: MemoryEvidence
    let onOpenConversation: (ConversationID) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L10n.string(evidence.sourceKind == .message ? "Committed message" : "Manual entry", locale: locale)).font(.caption.weight(.semibold))
                Text(L10n.string(evidence.speakerRole == .user ? "User" : "Assistant", locale: locale)).font(.caption).foregroundStyle(.secondary)
                Text(L10n.format("Source revision %@", locale: locale, String(evidence.sourceRevision))).font(.caption).foregroundStyle(.secondary)
                Text(evidence.createdAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if let excerpt = evidence.excerpt, evidence.bodyPurgedAt == nil { Text(verbatim: excerpt).font(.callout).textSelection(.enabled) }
            else { Text("Evidence body is unavailable.").font(.callout).foregroundStyle(.secondary) }
            HStack {
                Text(verbatim: evidence.sourceID.uuidString).font(.caption2).foregroundStyle(.tertiary)
                if let conversationID = evidence.conversationID { Button("Open conversation") { onOpenConversation(conversationID) }.buttonStyle(.link) }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
    }
}

private func memoryLifecycleStatusKey(_ status: MemoryLifecycleStatus) -> String {
    switch status {
    case .active: "Active"
    case .candidate: "Needs review"
    case .archived: "Archived"
    case .rejected: "Rejected"
    case .removed: "Removed"
    case .forgotten: "Forgotten"
    case .superseded: "Superseded"
    case .expired: "Expired"
    case .notYetValid: "Not yet valid"
    }
}
private func memoryKindKey(_ kind: MemoryKind) -> String { switch kind { case .fact: "Fact"; case .preference: "Preference"; case .decision: "Decision"; case .goal: "Goal"; case .constraint: "Constraint"; case .procedure: "Procedure"; case .learning: "Learning"; case .context: "Context" } }
private func memorySubjectKey(_ subject: MemorySubject) -> String { subject == .user ? "User" : "Workspace" }
private func memoryOriginKey(_ origin: MemoryOrigin) -> String { switch origin { case .explicitUser: "Explicit user"; case .observedUserStatement: "Observed user statement"; case .agentInference: "Agent inference" } }
private func memoryAuthorityKey(_ authority: MemoryAuthority) -> String { switch authority { case .explicitUser: "Explicit user"; case .observedUser: "Observed user"; case .inferred: "Inferred" } }
private func memorySensitivityKey(_ sensitivity: MemorySensitivity) -> String { sensitivity == .sensitive ? "Sensitive" : "Standard" }
private func replacementStateKey(_ state: MemoryReplacementState) -> String { switch state { case .proposed: "Needs review"; case .confirmed: "Confirmed"; case .rejected: "Rejected" } }
