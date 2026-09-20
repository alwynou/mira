import MiraCore
import SwiftUI

struct MemoryManagementDetail: View {
    let detail: MemoryDetail
    let library: MacLibrary
    let workspaceName: String
    let isWorking: Bool
    var relatedMemories: [MemoryID: Memory] = [:]
    var selectRelated: (Memory) -> Void = { _ in }
    var confirmReplacement: (Memory, Memory) -> Void = { _, _ in }
    let edit: () -> Void
    let replace: () -> Void
    let changeState: (MemoryState) -> Void
    let forget: () -> Void
    let openSource: (SessionEvidenceReference) -> Void
    @Environment(\.locale) private var locale
    @State private var confirmsReplacement: Memory?

    private var memory: Memory { detail.memory }
    private var status: MemoryManagementStatus { memory.managementStatus(at: .now) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
                HStack {
                    Label(L10n.string(memoryManagementStatusKey(status), locale: locale),
                          systemImage: status == .current ? "checkmark.circle" : "clock")
                    Spacer()
                    Text(memory.updatedAt, format: .dateTime.year().month().day())
                }
                .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)

                if let draft = memory.draft, memory.forgottenAt == nil {
                    Text(verbatim: draft.content)
                        .font(.system(size: 20, weight: .medium)).lineSpacing(5).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(draft.content)
                        .accessibilityIdentifier("memory.content")
                    actions
                    if memory.state == .candidate {
                        ForEach(relatedMemories.values.filter { $0.isCurrent }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }) { current in
                            VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                                Text("Previous memory").font(MiraTheme.Typography.section)
                                Text(verbatim: current.draft?.content ?? "").font(MiraTheme.Typography.body)
                                Button("Confirm replacement") { confirmsReplacement = current }.disabled(isWorking)
                            }
                        }
                    }
                    Divider()
                    properties(draft)
                    Divider()
                    sources
                    history
                    Divider()
                    Button(role: .destructive, action: forget) { Label("Forget memory", systemImage: "trash") }
                        .buttonStyle(.plain).foregroundStyle(MiraTheme.Colors.failure)
                        .disabled(isWorking).accessibilityIdentifier("memory.forget")
                    Text("Forgetting also clears earlier wording and source excerpts. The original conversation stays on this device.")
                        .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                } else {
                    Label("Forgotten memory", systemImage: "lock.slash").font(MiraTheme.Typography.title)
                    Text("The content and source excerpts have been cleared. This record prevents the same memory from being learned again.")
                        .foregroundStyle(MiraTheme.Colors.secondaryText)
                    metadataRow("Scope", value: workspaceName)
                    history
                }
            }
            .padding(MiraTheme.Spacing.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.detail")
        .confirmationDialog("Confirm replacement", isPresented: Binding(
            get: { confirmsReplacement != nil }, set: { if !$0 { confirmsReplacement = nil } }), titleVisibility: .visible
        ) {
            Button("Confirm replacement") {
                if let current = confirmsReplacement { confirmReplacement(memory, current) }
                confirmsReplacement = nil
            }
            Button("Cancel", role: .cancel) { confirmsReplacement = nil }
        } message: { Text("This pending memory will become current. The current memory will remain in history.") }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MiraTheme.Spacing.sm) { actionButtons }
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) { actionButtons }
        }
        .disabled(isWorking)
    }

    @ViewBuilder private var actionButtons: some View {
        if memory.supersededBy == nil && memory.state != .removed && memory.state != .rejected {
            Button("Edit wording", action: edit).accessibilityIdentifier("memory.edit")
        }
        if memory.isCurrent {
            Button("Replace with new memory", action: replace).accessibilityIdentifier("memory.replace")
        }
        if memory.state == .active || memory.state == .candidate || (memory.state == .archived && memory.supersededBy == nil) {
        Menu {
            if memory.state == .active { Button("Archive memory") { changeState(.archived) } }
            if memory.state == .archived && memory.supersededBy == nil {
                Button("Restore memory") { changeState(.active) }
            }
            if memory.state == .candidate { Button("Reject replacement") { changeState(.rejected) } }
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More memory actions")
        }
    }

    private func properties(_ draft: MemoryDraft) -> some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
            metadataRow("Scope", value: workspaceName)
            metadataRow("Kind", value: L10n.string(memoryManagementKindKey(draft.kind), locale: locale))
            metadataRow("Subject", value: L10n.string(draft.subject == .user ? "User" : "Workspace", locale: locale))
            metadataRow("Remote use", value: L10n.string(draft.allowsRemoteUse ? "Allowed" : "Local only", locale: locale))
            if draft.sensitivity == .sensitive { Label("Sensitive information", systemImage: "lock.shield") }
            if draft.allowedConnectionIDs != nil {
                Text("Remote use is restricted to selected connections.")
                    .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
            }
            if let date = draft.validFrom { dateRow("Valid from", date: date) }
            if let date = draft.validUntil { dateRow("Valid until", date: date) }
            Text("Scope controls where this memory applies. Remote use also depends on workspace and source permissions.")
                .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
        }
    }

    private func metadataRow(_ key: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(MiraTheme.Colors.secondaryText).frame(width: 90, alignment: .leading)
            Text(verbatim: value).textSelection(.enabled)
            Spacer(minLength: 0)
        }.font(MiraTheme.Typography.body)
    }
    private func dateRow(_ key: LocalizedStringKey, date: Date) -> some View {
        HStack {
            Text(key).foregroundStyle(MiraTheme.Colors.secondaryText).frame(width: 90, alignment: .leading)
            Text(date, format: .dateTime.year().month().day().hour().minute())
        }.font(MiraTheme.Typography.body)
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
            Text("Source").font(MiraTheme.Typography.section.weight(.semibold))
            ForEach(detail.evidence) { evidence in
                if case .userMessage(let reference) = evidence.source {
                    MemoryManagementSource(library: library, memoryID: memory.id,
                        workspaceID: memory.scope.workspaceID, evidenceID: evidence.id,
                        reference: reference, openSource: openSource)
                } else {
                    VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                        HStack {
                            Label("Manual entry", systemImage: "square.and.pencil")
                            Spacer()
                            Text(evidence.createdAt, format: .dateTime.year().month().day())
                        }
                        .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                        if evidence.bodyPurgedAt == nil, let excerpt = evidence.excerpt {
                            Text(verbatim: excerpt).font(MiraTheme.Typography.body).textSelection(.enabled)
                        }
                    }
                    .padding(MiraTheme.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MiraTheme.Colors.inset, in: RoundedRectangle(cornerRadius: MiraTheme.Radius.row))
                }
            }
        }
    }

    private var history: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.lg) {
                ForEach(Array(detail.replacements.prefix(32))) { relation in
                    relationship(relation)
                }
                if detail.replacements.count > 32 {
                    Text("Showing the 32 most recent replacement links.")
                        .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                }
                ForEach(detail.revisions) { revision in
                    VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                        HStack {
                            Text(L10n.format("Revision %lld", locale: locale, Int64(revision.revision)))
                            Spacer()
                            Text(revision.changedAt, format: .dateTime.year().month().day())
                        }
                        .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                        if memory.forgottenAt == nil, revision.bodyPurgedAt == nil, let draft = revision.draft {
                            Text(verbatim: draft.content).font(MiraTheme.Typography.body).textSelection(.enabled)
                        } else { Text("Content cleared").foregroundStyle(MiraTheme.Colors.secondaryText) }
                    }
                }
            }
            .padding(.top, MiraTheme.Spacing.md)
        } label: { Text("History").font(MiraTheme.Typography.section.weight(.semibold)) }
    }

    private func relationship(_ relation: MemoryReplacement) -> some View {
        let otherID = relation.replacementID == memory.id ? relation.previousID : relation.replacementID
        let other = relatedMemories[otherID]
        return VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
            Text(L10n.string(relation.state == .proposed ? "Pending replacement" : relation.state == .confirmed ? "Replacement recorded" : "Rejected replacement", locale: locale))
                .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
            if let other {
                Button { selectRelated(other) } label: {
                    Text(other.draft?.content ?? L10n.string("Forgotten memory", locale: locale)).lineLimit(3)
                }.buttonStyle(.link)
            } else { Text("Related memory unavailable").font(MiraTheme.Typography.caption) }
        }
    }
}

private struct MemoryManagementSourceValue: Sendable {
    let title: String?
    let excerpt: String
    let createdAt: Date
}

private struct MemoryManagementSource: View {
    let library: MacLibrary
    let memoryID: MemoryID
    let workspaceID: WorkspaceID?
    let evidenceID: UUID
    let reference: SessionEvidenceReference
    let openSource: (SessionEvidenceReference) -> Void
    @State private var model = MacSessionReadModel<MemoryManagementSourceValue>()

    var body: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
            Label("Conversation", systemImage: "bubble.left.and.bubble.right")
                .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
            if let value = model.value {
                Text(value.createdAt, format: .dateTime.year().month().day())
                    .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
                if let title = value.title, !title.isEmpty { Text(verbatim: title).font(MiraTheme.Typography.section.weight(.semibold)) }
                Text(verbatim: value.excerpt).font(MiraTheme.Typography.body).textSelection(.enabled)
                Button { openSource(reference) } label: { Label("View original message", systemImage: "arrow.up.forward") }
                    .buttonStyle(.link).accessibilityIdentifier("memory.source")
            } else if model.isLoading { ProgressView("Checking source").controlSize(.small) }
            else { Text("Source unavailable").font(MiraTheme.Typography.body).foregroundStyle(MiraTheme.Colors.secondaryText) }
        }
        .padding(MiraTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MiraTheme.Colors.inset, in: RoundedRectangle(cornerRadius: MiraTheme.Radius.row))
        .task(id: evidenceID) {
            await model.observe(library: library, sessionID: reference.sessionID) { group in
                try reference.validate()
                guard reference.admissionSequence < Int64.max else { throw MiraError(.notFound, "The memory source is unavailable.") }
                let detail = try await group.memories.detail(memoryID, workspaceID: workspaceID)
                let state = try await group.application.sessionSnapshot(id: reference.sessionID)
                guard detail.memory.forgottenAt == nil,
                    let evidence = detail.evidence.first(where: { $0.id == evidenceID }),
                    evidence.bodyPurgedAt == nil, let excerpt = evidence.excerpt,
                    evidence.source == .userMessage(reference),
                    let execution = state.executions[reference.originalExecutionID],
                    execution.admission.retryOfExecutionID == nil,
                    execution.admission.userMessageID == reference.userMessageID,
                    execution.admissionEventID == reference.admissionEventID,
                    execution.admissionSequence == reference.admissionSequence
                else { throw MiraError(.notFound, "The memory source is unavailable.") }
                let page = try await group.queries.messagePage(sessionID: reference.sessionID,
                    beforeSequence: reference.admissionSequence + 1, limit: 1)
                guard let message = page.messages.first(where: { $0.id == reference.userMessageID }),
                      message.summary.role == .user, message.body.text?.contains(excerpt) == true
                else { throw MiraError(.notFound, "The memory source is unavailable.") }
                return MemoryManagementSourceValue(title: page.session?.title.text, excerpt: excerpt, createdAt: evidence.createdAt)
            }
        }
    }
}
