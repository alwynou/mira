import SwiftUI
import MiraCore

struct ExecutionInspector: View {
    @Environment(\.locale) private var locale
    @Bindable var model: ConversationModel
    @State private var selectedID: ExecutionID?
    @State private var loadedAttempts: [ModelAttempt] = []
    @State private var loadedInvocations: [ToolInvocation] = []
    @State private var auditExecutionID: ExecutionID?
    @State private var auditError: MiraError?
    private var execution: Execution? { model.executions.first { $0.id == selectedID } ?? model.executions.last }
    private var attempts: [ModelAttempt] { auditExecutionID == execution?.id ? loadedAttempts : [] }
    private var invocations: [ToolInvocation] { auditExecutionID == execution?.id ? loadedInvocations : [] }
    private var refreshID: String { "\(execution?.id.rawValue.uuidString ?? "none")-\(model.inspectionRevision)" }

    private func selectionTitle(_ source: RouteSelectionSource) -> String {
        switch source {
        case .explicit: "Explicit selection"
        case .conversation: "Conversation override"
        case .workspace: "Workspace default"
        case .global: "Global default"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Execution details").font(.headline)
                if model.executions.count > 1 {
                    Picker("Turn", selection: $selectedID) {
                        Text("Latest turn").tag(nil as ExecutionID?)
                        ForEach(model.executions) { item in
                            Text(item.createdAt, format: .dateTime.hour().minute().second()).tag(Optional(item.id))
                        }
                    }
                }
                if let execution {
                    LabeledContent("Status", value: L10n.string(execution.status.displayTitle, locale: locale))
                    LabeledContent("Model", value: execution.route.modelID)
                    LabeledContent("Route preset", value: execution.route.name)
                    LabeledContent("Route selection", value: L10n.string(selectionTitle(execution.route.selectionSource), locale: locale))
                    LabeledContent("Provider origin", value: execution.route.origin)
                    LabeledContent("Connection revision") { Text(execution.route.connectionRevision, format: .number) }
                    LabeledContent("Input tokens", value: execution.usage.totalInputTokens.map(String.init) ?? L10n.string("Service did not provide this", locale: locale))
                    LabeledContent("Output tokens", value: execution.usage.outputTokens.map(String.init) ?? L10n.string("Service did not provide this", locale: locale))
                    if auditExecutionID == execution.id {
                        CostSummaryView(calls: attempts.map { .init(id: $0.id, route: execution.route, usage: $0.usage, createdAt: $0.createdAt, isComplete: $0.status == .completed) }, isBackground: false)
                    }
                    if let metadata = execution.route.catalogMetadata, metadata.pricing != nil {
                        Text(L10n.format("Catalog retrieved: %@", locale: locale, metadata.retrievedAt)).font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: metadata.sourceRevision).font(.caption2).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    Divider()
                    Text("Local execution record").font(.subheadline.weight(.semibold))
                    Text("Includes actual requests, tool parameters, and results; API keys are excluded. Tool observations are reused only for the current turn.").font(.caption).foregroundStyle(.secondary)
                    if auditExecutionID != execution.id {
                        if let auditError {
                            Text(L10n.error(auditError, locale: locale)).font(.caption).foregroundStyle(.secondary)
                        } else { ProgressView() }
                    } else if attempts.isEmpty {
                        Text("Request not sent yet").foregroundStyle(.secondary)
                    }
                    ForEach(attempts) { attempt in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.format("Step %lld · Attempt %lld", locale: locale, Int64(attempt.stepIndex), Int64(attempt.attemptIndex))).font(.subheadline.weight(.semibold))
                            Text(L10n.string(attempt.status.displayTitle, locale: locale)).font(.caption).foregroundStyle(.secondary)
                            UsageCostView(usage: attempt.usage, route: execution.route, isComplete: attempt.status == .completed)
                            if let error = attempt.error { Text(L10n.error(error, locale: locale)).font(.caption).foregroundStyle(.orange) }
                            if let request = attempt.request {
                                DisclosureGroup("Request snapshot") {
                                    RequestSnapshotView(request: request, execution: execution, application: model.application) { sourceID in
                                        Task { await model.selectConversation(sourceID) }
                                    }
                                }
                            } else if attempt.bodyPurgedAt != nil {
                                Label("Audit content cleared after forgetting a memory", systemImage: "eye.slash").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(invocations.filter { $0.attemptID == attempt.id }) { invocation in
                                DisclosureGroup {
                                    Text(L10n.format("Call ID: %@", locale: locale, invocation.call.id)).font(.caption2).foregroundStyle(.secondary)
                                    if invocation.bodyPurgedAt != nil {
                                        Text("Tool content cleared after forgetting a memory").font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text(verbatim: invocation.call.arguments).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                        if let result = invocation.result { Text(verbatim: result.text).font(.caption).textSelection(.enabled) }
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(L10n.format("%lld. %@", locale: locale, Int64(invocation.modelOrder + 1), invocation.call.name)).font(.caption.weight(.semibold))
                                        Text(L10n.string(invocation.result?.status.displayTitle ?? (invocation.dispatchedAt == nil ? "Waiting for check" : "Running"), locale: locale))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }.padding(12).background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
                    }
                }
            }.padding(20)
        }
        .task(id: refreshID) {
            let id = execution?.id
            auditExecutionID = nil; loadedAttempts = []; loadedInvocations = []; auditError = nil
            guard let id else { return }
            do {
                let audit = try await model.application.audit(for: id)
                guard !Task.isCancelled, execution?.id == id else { return }
                loadedAttempts = audit.attempts; loadedInvocations = audit.invocations; auditExecutionID = id
            } catch {
                if !Task.isCancelled, execution?.id == id {
                    auditError = MiraError.safe(error); model.error = auditError
                }
            }
        }
    }
}

private struct RequestSnapshotView: View {
    @Environment(\.locale) private var locale
    let request: CanonicalModelRequest
    let execution: Execution
    let application: MiraApplication
    let onOpenConversation: (ConversationID) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let context = request.contextInfo {
                Text(L10n.format("Route revision %lld · Conservative input estimate %@", locale: locale, Int64(context.routeRevision), context.estimatedInputBytes.map(String.init) ?? L10n.string("Unknown", locale: locale))).font(.caption2).foregroundStyle(.secondary)
                Text("Estimate is based on UTF-8 and protocol overhead, not the provider's exact token count.").font(.caption2).foregroundStyle(.secondary)
                ForEach(Array(context.references.enumerated()), id: \.offset) { _, item in
                    if item.kind == "memory", let revision = item.revision, let uuid = UUID(uuidString: item.id) {
                        MemoryCitationButton(reference: .init(memoryID: MemoryID(uuid), revision: revision), executionID: execution.id,
                                             conversationID: execution.conversationID, application: application, onOpenConversation: onOpenConversation)
                    } else if let revision = item.revision {
                        Text(L10n.format("%@ · %@ · v%lld", locale: locale, item.kind, item.id, Int64(revision))).font(.caption2).textSelection(.enabled)
                    } else {
                        Text(L10n.format("%@ · %@", locale: locale, item.kind, item.id)).font(.caption2).textSelection(.enabled)
                    }
                }
                ForEach(context.omissions) { omission in
                    Text(L10n.format(omission.reason == .memoryContextInvalidated ? "Execution %@: related memory changed or is unavailable; the historical reply is excluded from model context." : "Execution %@: failed, cancelled, or interrupted replies are excluded from history.", locale: locale, omission.executionID.rawValue.uuidString))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(verbatim: encodedRequest).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }
    private var encodedRequest: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(request), as: UTF8.self)) ?? L10n.string("Request unavailable", locale: locale)
    }


}

private extension AttemptStatus {
    var displayTitle: String {
        switch self { case .prepared: "Waiting for model response"; case .completed: "Model call completed"; case .failed: "Model call failed"; case .interrupted: "Model call interrupted" }
    }
}
private extension ToolResultStatus {
    var displayTitle: String {
        switch self {
        case .succeeded: "Completed"
        case .invalidArguments: "Invalid arguments · not executed"
        case .notFound: "Tool unavailable · not executed"
        case .denied: "Not authorized"
        case .timedOut: "Timed out"
        case .cancelledBeforeDispatch: "Cancelled before execution"
        case .cancelled: "Stopped"
        case .failed: "Execution failed"
        case .outputLimit: "Limit exceeded"
        case .interrupted: "Interrupted · check the result"
        }
    }
}
