import MiraCore
import SwiftUI

struct KnowledgeCitationList: View {
    let references: [SourceCitationReference]
    let executionID: ExecutionID
    let conversationID: ConversationID
    let library: MacLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(references) { reference in
                KnowledgeCitationButton(
                    reference: reference, executionID: executionID,
                    conversationID: conversationID, library: library)
            }
        }
    }
}

private struct KnowledgeCitationButton: View {
    @Environment(\.locale) private var locale
    let reference: SourceCitationReference
    let executionID: ExecutionID
    let conversationID: ConversationID
    let library: MacLibrary
    @State private var model = SourceCitationModel()
    @State private var showingDetail = false

    private var identity: String { "\(conversationID.rawValue):\(executionID.rawValue):\(reference.id)" }
    private var available: Bool { model.value != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                showingDetail = true
            } label: {
                Label("Source citation", systemImage: available ? "book.pages" : "book.closed")
            }
            .disabled(!available)
            if let error = model.error {
                Text(L10n.error(error, locale: locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .buttonStyle(.link)
        .font(.caption)
        .task(id: identity) {
            await model.observe(library: library, sessionID: conversationID) { group in
                let session = try await group.application.sessionSnapshot(id: conversationID)
                return try await group.knowledge.citation(
                    reference, sessionID: conversationID, executionID: executionID,
                    workspaceID: session.header?.workspaceID)
            }
        }
        .sheet(isPresented: $showingDetail) {
            KnowledgeCitationSheet(
                reference: reference, executionID: executionID,
                conversationID: conversationID, library: library
            )
            .environment(\.locale, locale)
        }
        .help(Text(verbatim: helpText))
    }

    private var helpText: String {
        if model.isLoading { return L10n.string("Checking source citation", locale: locale) }
        if let error = model.error { return L10n.error(error, locale: locale) }
        return L10n.string("Open source citation", locale: locale)
    }
}

private struct KnowledgeCitationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let reference: SourceCitationReference
    let executionID: ExecutionID
    let conversationID: ConversationID
    let library: MacLibrary
    @State private var model = SourceCitationModel()

    private var identity: String { "\(conversationID.rawValue):\(executionID.rawValue):\(reference.id)" }

    var body: some View {
        Group {
            if let detail = model.value {
                KnowledgeCitationDetailView(detail: detail)
            } else {
                VStack {
                    HStack {
                        Spacer()
                        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                    if let error = model.error {
                        ContentUnavailableView(
                            "Source citation unavailable", systemImage: "book.closed",
                            description: Text(L10n.error(error, locale: locale)))
                    } else {
                        ProgressView("Loading source citation")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(24)
                .frame(width: 700, height: 560)
            }
        }
        .task(id: identity) {
            await model.observe(library: library, sessionID: conversationID) { group in
                let session = try await group.application.sessionSnapshot(id: conversationID)
                return try await group.knowledge.citation(
                    reference, sessionID: conversationID, executionID: executionID,
                    workspaceID: session.header?.workspaceID)
            }
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
            if let heading = detail.chunk.summary.headingPath.last {
                Text(verbatim: heading).font(.headline)
            }
            Text(
                L10n.format(
                    "Lines %lld–%lld", locale: locale,
                    Int64(detail.chunk.summary.startLine), Int64(detail.chunk.summary.endLine))
            )
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
