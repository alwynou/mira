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
    @State private var available = false
    @State private var error: MiraError?
    @State private var showingDetail = false
    @State private var isLoading = true

    private var identity: String { "\(conversationID.rawValue):\(executionID.rawValue):\(reference.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                showingDetail = true
            } label: {
                Label("Source citation", systemImage: available ? "book.pages" : "book.closed")
            }
            .disabled(!available)
            if let error {
                Text(L10n.error(error, locale: locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .buttonStyle(.link)
        .font(.caption)
        .task(id: identity) { await load() }
        .sheet(isPresented: $showingDetail) {
            KnowledgeCitationSheet(reference: reference, executionID: executionID,
                                   conversationID: conversationID, application: application)
                .environment(\.locale, locale)
        }
        .help(Text(verbatim: helpText))
    }

    private func load() async {
        available = false
        isLoading = true
        error = nil
        do {
            _ = try await application.sourceCitation(reference, executionID: executionID, conversationID: conversationID)
            guard !Task.isCancelled else { return }
            available = true
            error = nil
            isLoading = false
        } catch {
            guard !Task.isCancelled else { return }
            available = false
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

private struct KnowledgeCitationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let reference: SourceCitationReference
    let executionID: ExecutionID
    let conversationID: ConversationID
    let application: MiraApplication
    @State private var model = SourceCitationModel()

    private var identity: String { "\(conversationID.rawValue):\(executionID.rawValue):\(reference.id)" }

    var body: some View {
        Group {
            if let detail = model.detail {
                KnowledgeCitationDetailView(detail: detail)
            } else {
                VStack {
                    HStack {
                        Spacer()
                        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                    if let error = model.error {
                        ContentUnavailableView("Source citation unavailable", systemImage: "book.closed", description: Text(L10n.error(error, locale: locale)))
                    } else {
                        ProgressView("Loading source citation").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(24)
                .frame(width: 700, height: 560)
            }
        }
        .task(id: identity) {
            await model.observe(application: application, reference: reference,
                                executionID: executionID, conversationID: conversationID)
        }
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
