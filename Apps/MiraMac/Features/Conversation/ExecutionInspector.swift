import SwiftUI
import MiraCore

struct ExecutionInspector: View {
    @Bindable var model: ConversationModel
    @State private var selectedID: ExecutionID?
    @State private var attempts: [ModelAttempt] = []
    @State private var invocations: [ToolInvocation] = []
    @State private var legacyRequest: CanonicalModelRequest?
    private var execution: Execution? { model.executions.first { $0.id == selectedID } ?? model.executions.last }
    private var refreshID: String { "\(execution?.id.rawValue.uuidString ?? "none")-\(model.inspectionRevision)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("执行详情").font(.headline)
                if model.executions.count > 1 {
                    Picker("回合", selection: $selectedID) {
                        Text("最新回合").tag(nil as ExecutionID?)
                        ForEach(model.executions) { item in
                            Text(item.createdAt, format: .dateTime.hour().minute().second()).tag(Optional(item.id))
                        }
                    }
                }
                if let execution {
                    LabeledContent("状态", value: execution.status.displayTitle)
                    LabeledContent("模型", value: execution.route.modelID)
                    LabeledContent("输入 Token", value: execution.usage.inputTokens.map(String.init) ?? "服务未提供")
                    LabeledContent("输出 Token", value: execution.usage.outputTokens.map(String.init) ?? "服务未提供")
                    Text("费用未估算；以服务商账单为准。").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("本机执行记录").font(.subheadline.weight(.semibold))
                    Text("包含实际请求、工具参数和结果，不包含 API Key。工具观察只在当前回合续用。").font(.caption).foregroundStyle(.secondary)
                    if attempts.isEmpty {
                        if let legacyRequest { RequestSnapshotView(request: legacyRequest) }
                        else { Text("尚未发送请求").foregroundStyle(.secondary) }
                    }
                    ForEach(attempts) { attempt in
                        VStack(alignment: .leading, spacing: 10) {
                            Text("步骤 \(attempt.stepIndex) · 尝试 \(attempt.attemptIndex)").font(.subheadline.weight(.semibold))
                            Text(attempt.status.displayTitle).font(.caption).foregroundStyle(.secondary)
                            if let error = attempt.error { Text(error.message).font(.caption).foregroundStyle(.orange) }
                            DisclosureGroup("请求快照") { RequestSnapshotView(request: attempt.request) }
                            ForEach(invocations.filter { $0.attemptID == attempt.id }) { invocation in
                                DisclosureGroup {
                                    Text("调用 ID：\(invocation.call.id)").font(.caption2).foregroundStyle(.secondary)
                                    Text(invocation.call.arguments).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    if let result = invocation.result { Text(result.text).font(.caption).textSelection(.enabled) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(invocation.modelOrder + 1). \(invocation.call.name)").font(.caption.weight(.semibold))
                                        Text(invocation.result?.status.displayTitle ?? (invocation.dispatchedAt == nil ? "等待检查" : "执行中"))
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
            guard let id else { attempts = []; invocations = []; legacyRequest = nil; return }
            do {
                let audit = try await model.application.audit(for: id)
                let legacy = audit.attempts.isEmpty ? try await model.application.request(for: id) : nil
                guard !Task.isCancelled, execution?.id == id else { return }
                attempts = audit.attempts; invocations = audit.invocations; legacyRequest = legacy
            } catch { if !Task.isCancelled { model.error = MiraError.safe(error) } }
        }
    }
}

private struct RequestSnapshotView: View {
    let request: CanonicalModelRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let context = request.contextInfo {
                Text("路线版本 \(context.routeRevision) · 输入保守估算 \(context.estimatedInputBytes.map(String.init) ?? "未知")").font(.caption2).foregroundStyle(.secondary)
                Text("估算以 UTF-8 与协议开销计算，不是服务商精确 Token 数。").font(.caption2).foregroundStyle(.secondary)
                ForEach(Array(context.references.enumerated()), id: \.offset) { _, item in
                    Text("\(item.kind) · \(item.id)\(item.revision.map { " · v\($0)" } ?? "")").font(.caption2).textSelection(.enabled)
                }
                ForEach(context.omissions, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
            }
            Text(encodedRequest).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }
    private var encodedRequest: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(request), as: UTF8.self)) ?? "请求不可用"
    }
}

private extension AttemptStatus {
    var displayTitle: String {
        switch self { case .prepared: "等待模型返回"; case .completed: "模型调用完成"; case .failed: "模型调用失败"; case .interrupted: "模型调用中断" }
    }
}
private extension ToolResultStatus {
    var displayTitle: String {
        switch self {
        case .succeeded: "已完成"
        case .invalidArguments: "参数无效 · 未执行"
        case .notFound: "工具不可用 · 未执行"
        case .denied: "未获授权"
        case .timedOut: "已超时"
        case .cancelledBeforeDispatch: "执行前取消"
        case .cancelled: "已停止"
        case .failed: "执行失败"
        case .outputLimit: "超出限额"
        case .interrupted: "已中断 · 请核对结果"
        }
    }
}
