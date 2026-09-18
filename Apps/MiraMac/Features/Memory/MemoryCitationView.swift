import MiraCore
import SwiftUI

struct MemoryCitationList: View {
    let references: [MemoryCitationReference]
    let executionID: ExecutionID
    let conversationID: ConversationID
    let library: MacLibrary
    let onOpenConversation: (ConversationID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(references) { reference in
                MemoryCitationButton(
                    reference: reference, executionID: executionID,
                    conversationID: conversationID, library: library,
                    onOpenConversation: onOpenConversation)
            }
        }
    }
}

struct MemoryCitationButton: View {
    @Environment(\.locale) private var locale
    let reference: MemoryCitationReference
    let executionID: ExecutionID
    let conversationID: ConversationID
    let library: MacLibrary
    let onOpenConversation: (ConversationID) -> Void
    @State private var model = MemoryCitationModel()
    @State private var showingDetail = false

    private var identity: String {
        "\(conversationID.rawValue):\(executionID.rawValue):\(reference.id)"
    }
    private var available: Bool { model.value != nil }

    var body: some View {
        Button {
            showingDetail = true
        } label: {
            Label {
                Text(
                    available
                        ? L10n.format("Memory · revision %lld", locale: locale, Int64(reference.revision))
                        : L10n.string(
                            model.isLoading ? "Checking memory reference…" : "Memory reference unavailable",
                            locale: locale))
            } icon: {
                Image(systemName: available ? "quote.bubble" : "questionmark.circle")
            }
        }
        .buttonStyle(.link)
        .font(.caption)
        .disabled(!available)
        .help(Text(verbatim: reference.id))
        .task(id: identity) {
            await model.observe(library: library, sessionID: conversationID) { group in
                let session = try await group.application.sessionSnapshot(id: conversationID)
                return try await group.memories.citation(
                    reference, sessionID: conversationID, executionID: executionID,
                    workspaceID: session.header?.workspaceID)
            }
        }
        .sheet(isPresented: $showingDetail) {
            MemoryCitationSheet(
                reference: reference, executionID: executionID,
                conversationID: conversationID, library: library,
                onOpenConversation: onOpenConversation
            )
            .environment(\.locale, locale)
        }
    }
}

private struct MemoryCitationSheet: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    let reference: MemoryCitationReference
    let executionID: ExecutionID
    let conversationID: ConversationID
    let library: MacLibrary
    let onOpenConversation: (ConversationID) -> Void
    @State private var model = MemoryCitationModel()

    private var identity: String { "\(conversationID.rawValue):\(executionID.rawValue):\(reference.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Memory reference").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let detail = model.value {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(
                            L10n.format(
                                "Revision %lld used in this reply", locale: locale,
                                Int64(detail.revision.revision))
                        )
                        .font(.headline)
                        Text(verbatim: detail.revision.draft?.content ?? "").textSelection(.enabled)
                        if detail.memory.revision != detail.revision.revision {
                            Text("This memory has changed since the reply. The quoted version is shown here.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Divider()
                        Text("Evidence").font(.headline)
                        ForEach(detail.evidence) { evidence in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(
                                    L10n.string(
                                        memoryEvidenceLabel(evidence.source),
                                        locale: locale)
                                )
                                .font(.caption.weight(.semibold))
                                if let excerpt = evidence.excerpt {
                                    Text(verbatim: excerpt).textSelection(.enabled)
                                } else {
                                    Text("Evidence body is unavailable.").foregroundStyle(.secondary)
                                }
                                if case .userMessage(let source) = evidence.source {
                                    Button("Open conversation") {
                                        dismiss()
                                        onOpenConversation(source.sessionID)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let error = model.error {
                ContentUnavailableView(
                    "Memory reference unavailable", systemImage: "quote.bubble",
                    description: Text(L10n.error(error, locale: locale)))
            } else {
                ProgressView("Loading memory")
            }
        }
        .padding(24)
        .frame(width: 620, height: 500)
        .task(id: identity) {
            await model.observe(library: library, sessionID: conversationID) { group in
                let session = try await group.application.sessionSnapshot(id: conversationID)
                return try await group.memories.citation(
                    reference, sessionID: conversationID, executionID: executionID,
                    workspaceID: session.header?.workspaceID)
            }
        }
    }

    private func memoryEvidenceLabel(_ source: MemoryEvidenceSource) -> String {
        switch source {
        case .userMessage:
            return "Committed message"
        case .manualEntry:
            return "Manual entry"
        }
    }
}
