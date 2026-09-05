import SwiftUI
import MiraCore

struct KnowledgeCitationList: View {
    let references: [SourceCitationReference]
    let executionID: ExecutionID
    let conversationID: ConversationID
    let application: MiraApplication

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(references) { reference in
                KnowledgeCitationButton(reference: reference, executionID: executionID, conversationID: conversationID, application: application)
            }
        }
    }
}

private struct KnowledgeCitationButton: View {
    @Environment(\.locale) private var locale
    let reference: SourceCitationReference
    let executionID: ExecutionID
    let conversationID: ConversationID
    let application: MiraApplication
    @State private var detail: SourceCitationDetail?
    @State private var error: MiraError?
    @State private var showingDetail = false
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                showingDetail = true
            } label: {
                Label("Source citation", systemImage: detail == nil ? "book.closed" : "book.pages")
            }
            .disabled(detail == nil)
            if let error {
                Text(L10n.error(error, locale: locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .buttonStyle(.link)
        .font(.caption)
        .task(id: reference.id) { await load() }
        .sheet(isPresented: $showingDetail) {
            if let detail {
                KnowledgeCitationDetailView(detail: detail).environment(\.locale, locale)
            } else if let error {
                ContentUnavailableView("Source citation unavailable", systemImage: "book.closed", description: Text(L10n.error(error, locale: locale)))
            } else {
                ProgressView("Loading source citation")
            }
        }
        .help(Text(verbatim: helpText))
    }

    private func load() async {
        do {
            let loaded = try await application.sourceCitation(reference, executionID: executionID, conversationID: conversationID)
            guard !Task.isCancelled else { return }
            detail = loaded
            error = nil
            isLoading = false
        } catch {
            guard !Task.isCancelled else { return }
            detail = nil
            self.error = MiraError.safe(error)
            isLoading = false
        }
    }

    private var helpText: String {
        if isLoading { return L10n.string("Checking source citation", locale: locale) }
        if let error { return L10n.error(error, locale: locale) }
        return L10n.string("Open source citation", locale: locale)
    }
}

private struct KnowledgeCitationDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let detail: SourceCitationDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: detail.source.title).font(.title2.weight(.semibold))
                    Text("Source version").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let heading = detail.chunk.summary.headingPath.last { Text(verbatim: heading).font(.headline) }
            Text(L10n.format("Lines %lld–%lld", locale: locale, Int64(detail.chunk.summary.startLine), Int64(detail.chunk.summary.endLine)))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(verbatim: detail.chunk.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(width: 700, height: 560)
    }
}
