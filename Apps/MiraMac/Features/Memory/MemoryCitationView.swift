import SwiftUI
import MiraCore

struct MemoryCitationList: View {
    let references: [MemoryCitationReference]
    let executionID: ExecutionID
    let conversationID: ConversationID
    let application: MiraApplication
    var memoryNotices: [MemoryContextNotice] = []
    let onOpenConversation: (ConversationID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(references) { reference in
                MemoryCitationButton(reference: reference, executionID: executionID, conversationID: conversationID,
                                     application: application, memoryNotices: memoryNotices, onOpenConversation: onOpenConversation)
            }
        }
    }
}

struct MemoryCitationButton: View {
    @Environment(\.locale) private var locale
    let reference: MemoryCitationReference
    let executionID: ExecutionID
    let conversationID: ConversationID
    let application: MiraApplication
    var memoryNotices: [MemoryContextNotice] = []
    let onOpenConversation: (ConversationID) -> Void
    @State private var available = false
    @State private var isLoading = true
    @State private var showingDetail = false

    private var identity: String { "\(conversationID.rawValue):\(executionID.rawValue):\(reference.id):\(memoryNotices.map(\.id).joined(separator: ","))" }

    var body: some View {
        Button {
            showingDetail = true
        } label: {
            Label {
                Text(available ? L10n.format("Memory · revision %lld", locale: locale, Int64(reference.revision)) : L10n.string(isLoading ? "Checking memory reference…" : "Memory reference unavailable", locale: locale))
            } icon: { Image(systemName: available ? "quote.bubble" : "questionmark.circle") }
        }
        .buttonStyle(.link)
        .font(.caption)
        .disabled(!available)
        .help(Text(verbatim: reference.id))
        .task(id: identity) {
            available = false; isLoading = true
            let result = try? await application.memoryCitation(reference, executionID: executionID, conversationID: conversationID)
            guard !Task.isCancelled else { return }
            available = result != nil; isLoading = false
        }
        .sheet(isPresented: $showingDetail) {
            MemoryCitationSheet(reference: reference, executionID: executionID, conversationID: conversationID,
                                application: application, onOpenConversation: onOpenConversation)
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
    let application: MiraApplication
    let onOpenConversation: (ConversationID) -> Void
    @State private var detail: MemoryCitationDetail?
    @State private var error: MiraError?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Memory reference").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(L10n.format("Revision %lld used in this reply", locale: locale, Int64(detail.revision.revision)))
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
                                Text(L10n.string(evidence.sourceKind == .message ? "Committed message" : "Manual entry", locale: locale)).font(.caption.weight(.semibold))
                                if let excerpt = evidence.excerpt, evidence.bodyPurgedAt == nil {
                                    Text(verbatim: excerpt).textSelection(.enabled)
                                } else { Text("Evidence body is unavailable.").foregroundStyle(.secondary) }
                                if let sourceConversation = evidence.conversationID {
                                    Button("Open conversation") { dismiss(); onOpenConversation(sourceConversation) }
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let error {
                ContentUnavailableView("Memory reference unavailable", systemImage: "quote.bubble", description: Text(L10n.error(error, locale: locale)))
            } else { ProgressView("Loading memory") }
        }
        .padding(24)
        .frame(width: 620, height: 500)
        .task {
            let events = await application.events()
            await reload()
            for await event in events {
                guard !Task.isCancelled else { return }
                if case .changed = event { await reload() }
            }
        }
    }

    @MainActor private func reload() async {
        do {
            let value = try await application.memoryCitation(reference, executionID: executionID, conversationID: conversationID)
            guard !Task.isCancelled else { return }
            detail = value; error = nil
        } catch {
            guard !Task.isCancelled else { return }
            detail = nil; self.error = MiraError.safe(error)
        }
    }
}
