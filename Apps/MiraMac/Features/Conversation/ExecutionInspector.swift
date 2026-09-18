import MiraCore
import MiraProviders
import SwiftUI

struct ExecutionInspector: View {
    @Environment(\.locale) private var locale
    let model: ConversationModel
    @Bindable var page: ConversationPageState
    @State private var reader = MacSessionReadModel<SessionExecutionAuditPage>()
    @State private var cursorExecutionID: ExecutionID?
    @State private var beforeSequence: Int64?

    private var execution: SessionExecutionSummary? {
        page.executions.first { $0.id == page.inspectedExecutionID }
            ?? page.executions.max { $0.sequence < $1.sequence }
    }
    private var cursor: Int64? { cursorExecutionID == execution?.id ? beforeSequence : nil }
    private struct ReadIdentity: Hashable {
        let sessionID: ConversationID?
        let executionID: ExecutionID?
        let beforeSequence: Int64?
    }
    private var identity: ReadIdentity {
        .init(sessionID: page.conversationID, executionID: execution?.id, beforeSequence: cursor)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Execution details").font(.headline)
                if page.executions.count > 1 {
                    Picker("Turn", selection: $page.inspectedExecutionID) {
                        Text("Latest turn").tag(nil as ExecutionID?)
                        ForEach(page.executions) { item in
                            Text(item.admittedAt, format: .dateTime.hour().minute().second()).tag(Optional(item.id))
                        }
                    }
                }
                if let audit = reader.value, audit.execution.id == execution?.id {
                    ExecutionAuditSummary(audit: audit)
                    CostSummaryView(
                        summary: .init(attempts: audit.modelUsage, route: audit.plan.availableValue?.route),
                        priority: audit.plan.availableValue?.priority)
                    Divider()
                    Text("Local execution record").font(.subheadline.weight(.semibold))
                    Text("Includes recorded requests, tool parameters, and results. API keys are excluded.")
                        .font(.caption).foregroundStyle(.secondary)
                    if audit.attempts.isEmpty {
                        Text("No model calls recorded").foregroundStyle(.secondary)
                    }
                    ForEach(audit.attempts) { attempt in
                        ExecutionAttemptView(
                            attempt: attempt, route: audit.plan.availableValue?.route,
                            library: model.library, sessionID: audit.execution.sessionID,
                            executionID: audit.execution.id
                        ) { id in
                            Task { await model.selectConversation(id) }
                        }
                    }
                    HStack {
                        if cursor != nil {
                            Button("Latest calls") { beforeSequence = nil }
                        }
                        if audit.hasMore, let last = audit.attempts.last {
                            Button("Earlier calls") {
                                cursorExecutionID = audit.execution.id
                                beforeSequence = last.sequence
                            }
                        }
                    }
                } else if let error = reader.error {
                    Text(L10n.error(error, locale: locale)).font(.caption).foregroundStyle(.secondary)
                } else if execution != nil {
                    ProgressView()
                }
                if let sessionID = page.conversationID, let execution {
                    Divider()
                    MemoryExtractionInspector(library: model.library, sessionID: sessionID,
                        executionID: execution.id, workspaceID: page.workspaceID)
                        .id(execution.id)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .labeledContentStyle(ExecutionFieldStyle())
        .accessibilityIdentifier("conversation.executionInspector")
        .task(id: identity) {
            guard let sessionID = identity.sessionID, let executionID = identity.executionID else { return }
            let before = identity.beforeSequence
            await reader.observe(library: model.library, sessionID: sessionID) { group in
                try await group.queries.executionAudit(
                    sessionID: sessionID, executionID: executionID,
                    beforeSequence: before, limit: 32)
            }
        }
    }
}

private struct ExecutionFieldStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                configuration.label
                Spacer(minLength: 0)
                configuration.content
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 4) {
                configuration.label.foregroundStyle(.secondary)
                configuration.content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ExecutionAuditSummary: View {
    @Environment(\.locale) private var locale
    let audit: SessionExecutionAuditPage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Status", value: L10n.string(audit.execution.displayTitle, locale: locale))
            if let plan = audit.plan.availableValue {
                LabeledContent("Driver", value: plan.driverID)
                if let route = plan.route {
                    LabeledContent("Model", value: route.modelID)
                    LabeledContent("Adapter", value: route.adapter.id)
                    LabeledContent("Route preset ID", value: route.id.rawValue.uuidString)
                    LabeledContent("Connection revision") { Text(route.connectionRevision, format: .number) }
                    if let completion = audit.execution.completion {
                        LabeledContent("Input tokens", value: count(completion.usage.totalInputTokens))
                        LabeledContent("Output tokens", value: count(completion.usage.outputTokens))
                    }
                }
            }
            if let error = audit.error.availableValue {
                Text(L10n.error(error, locale: locale)).font(.caption).foregroundStyle(.orange)
            }
        }
    }
    private func count(_ value: Int?) -> String {
        value.map { $0.formatted(.number.locale(locale)) }
            ?? L10n.string("Service did not provide this", locale: locale)
    }
}

private struct ExecutionAttemptView: View {
    @Environment(\.locale) private var locale
    let attempt: SessionAuditAttempt
    let route: AgentModelRoute?
    let library: MacLibrary
    let sessionID: ConversationID
    let executionID: ExecutionID
    let onOpenConversation: (ConversationID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                L10n.format(
                    "Step %lld · Attempt %lld", locale: locale,
                    Int64(attempt.attempt.stepIndex), Int64(attempt.attempt.attemptIndex))
            )
            .font(.subheadline.weight(.semibold))
            Text(attempt.startedAt, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(
                .secondary)
            Text(L10n.string((attempt.resolution?.status ?? .prepared).displayTitle, locale: locale))
                .font(.caption).foregroundStyle(.secondary)
            if let route {
                UsageCostView(
                    usage: attempt.resolution?.usage ?? .init(), route: route,
                    isComplete: attempt.resolution?.status == .completed)
            }
            if let failure = attempt.failure.availableValue {
                Text(L10n.error(failure.failure.error, locale: locale)).font(.caption).foregroundStyle(.orange)
            }
            if let request = attempt.request.availableValue {
                DisclosureGroup("Request context") {
                    RequestContextView(
                        request: request, library: library, sessionID: sessionID,
                        executionID: executionID, onOpenConversation: onOpenConversation)
                }
            }
            if let output = attempt.output.availableValue {
                DisclosureGroup("Recorded model output") { AuditJSONView(value: output) }
            }
            ForEach(attempt.invocations) { invocation in ExecutionInvocationView(invocation: invocation) }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }
}

private struct ExecutionInvocationView: View {
    @Environment(\.locale) private var locale
    let invocation: SessionAuditInvocation
    var body: some View {
        DisclosureGroup {
            if let call = invocation.call.availableValue {
                Text(L10n.format("Call ID: %@", locale: locale, call.id)).font(.caption2).foregroundStyle(.secondary)
                Text(verbatim: call.arguments).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            if let proposal = invocation.proposal.availableValue {
                DisclosureGroup("Prepared tool proposal") { AuditJSONView(value: proposal) }
            }
            if let result = invocation.result.availableValue {
                AuditJSONView(value: result)
            }
            if invocation.state.resolution?.effectIsKnown == false {
                Text("Interrupted · check the result").font(.caption).foregroundStyle(.orange)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    L10n.format(
                        "%lld. %@", locale: locale,
                        Int64(invocation.state.invocation.modelOrder + 1), invocation.state.invocation.toolName)
                )
                .font(.caption.weight(.semibold))
                Text(
                    L10n.string(
                        invocation.state.resolution?.status.displayTitle
                            ?? (invocation.state.dispatchedAt == nil ? "Waiting for check" : "Running"), locale: locale)
                )
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct RequestContextView: View {
    @Environment(\.locale) private var locale
    let request: AgentSessionRequest
    let library: MacLibrary
    let sessionID: ConversationID
    let executionID: ExecutionID
    let onOpenConversation: (ConversationID) -> Void

    private struct RecordedMessage: Identifiable {
        let executionID: ExecutionID
        let ordinal: Int
        let message: AgentModelMessage
        var id: String { "\(executionID.rawValue.uuidString):\(ordinal)" }
    }
    // Context entries are immutable within the recorded execution.
    private var orderedMessages: [RecordedMessage] {
        request.contextMessages.enumerated().map {
            .init(executionID: request.request.executionID, ordinal: $0.offset + 1, message: $0.element)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("System instructions").font(.caption.weight(.semibold))
            Text(verbatim: request.instructions)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            if !request.tools.isEmpty {
                DisclosureGroup("Tool definitions") { AuditJSONView(value: request.tools) }
            }
            Text("Context contributions").font(.caption.weight(.semibold))
            Text(
                "Conversation history comes from the session journal. The entries below are the context added for this turn."
            )
            .font(.caption2).foregroundStyle(.secondary)
            ForEach(orderedMessages) { entry in
                Text(
                    L10n.format(
                        "%lld. %@", locale: locale, Int64(entry.ordinal),
                        L10n.string(entry.message.role.auditTitle, locale: locale))
                )
                .font(.caption.weight(.semibold))
                AuditJSONView(value: entry.message)
            }
            LabeledContent("Conservative input estimate") {
                Text(request.estimatedInputTokens, format: .number)
            }
            .font(.caption2)
            Text("Estimate is based on UTF-8 and protocol overhead, not the provider's exact token count.")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(request.sources, id: \.self) { source in
                switch source {
                case .domain(let namespace, let id, let revision):
                    if namespace == "memories" {
                        MemoryCitationButton(
                            reference: .init(memoryID: MemoryID(id), revision: revision),
                            executionID: executionID, conversationID: sessionID,
                            library: library, onOpenConversation: onOpenConversation)
                    } else {
                        Text(L10n.format("%@ · %@ · v%lld", locale: locale, namespace, id.uuidString, Int64(revision)))
                            .font(.caption2).textSelection(.enabled)
                    }
                case .sessionExecution(let id, let execution):
                    Button("Open conversation") { onOpenConversation(id) }
                        .help(execution.rawValue.uuidString)
                }
            }
            if !request.omissions.isEmpty {
                DisclosureGroup("Context omissions") { AuditJSONView(value: request.omissions) }
            }
            DisclosureGroup("Request metadata") { AuditJSONView(value: request) }
        }
    }
}

private struct AuditJSONView<Value: Encodable>: View {
    @Environment(\.locale) private var locale
    let value: Value
    var body: some View {
        Text(verbatim: text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
    }
    private var text: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do { return String(decoding: try encoder.encode(value), as: UTF8.self) } catch {
            return L10n.string("Request unavailable", locale: locale)
        }
    }
}

extension SessionAuditContent {
    fileprivate var availableValue: Value? { if case .available(let value) = self { value } else { nil } }
}

extension SessionExecutionSummary {
    var displayTitle: String {
        if let completion {
            switch completion.status {
            case .completed: return "Completed"
            case .failed: return "Failed"
            case .cancelled: return "Stopped"
            case .interrupted: return "Interrupted"
            case .queued: return "Queued"
            case .waitingForModel: return "Generating"
            }
        }
        return switch phase {
        case .queued: "Queued"
        case .preparing: "Preparing"
        case .waitingForModel: "Generating"
        case .waitingForTools: "Running tools"
        case .waitingForUser: "Waiting for approval"
        case .settling: "Saving"
        case .cancelling: "Stopping"
        }
    }
}

extension AttemptStatus {
    fileprivate var displayTitle: String {
        switch self {
        case .prepared: "Waiting for model response"
        case .completed: "Model call completed"
        case .failed: "Model call failed"
        case .interrupted: "Model call interrupted"
        }
    }
}
extension ToolResultStatus {
    fileprivate var displayTitle: String {
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

extension CanonicalRole {
    fileprivate var auditTitle: String {
        switch self {
        case .context: "Retrieved context"
        case .user: "User message"
        case .assistant: "Assistant message"
        case .tool: "Tool result"
        }
    }
}
