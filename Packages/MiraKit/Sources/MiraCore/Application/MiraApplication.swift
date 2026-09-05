import Foundation

public enum ApplicationEvent: Sendable {
    case changed
    case draft(ExecutionID, String)
    case failure(MiraError)
}
public struct LibrarySnapshot: Sendable {
    public var workspaces: [Workspace]
    public var conversations: [Conversation]
    public var routes: [ModelRoute]
}
public struct ConversationSnapshot: Sendable {
    public var messages: [Message]
    public var executions: [Execution]
    public var drafts: [Draft]
    public var pendingSaveIDs: Set<ExecutionID>
}

/// One instance per running app. Window lifetime never owns an execution.
public actor MiraApplication {
    private let store: any MiraStore
    private let provider: any ModelProviderPort
    private let environment: RuntimeEnvironment
    private let tools: ToolRegistry
    private let limits: ExecutionLimits
    private var expired: Set<ExecutionID> = []
    private var tasks: [ExecutionID: Task<Void, Never>] = [:]
    private var active: [ExecutionID: Execution] = [:]
    private var text: [ExecutionID: String] = [:]
    private var usage: [ExecutionID: TokenUsage] = [:]
    private var checkpointBytes: [ExecutionID: Int] = [:]
    private struct PendingSave { let status: ExecutionStatus; let error: MiraError? }
    private var pendingSaves: [ExecutionID: PendingSave] = [:]
    private var isShuttingDown = false
    private var observers: [UUID: AsyncStream<ApplicationEvent>.Continuation] = [:]

    public init(store: any MiraStore, provider: any ModelProviderPort, environment: RuntimeEnvironment = .init(), tools: ToolRegistry = .empty, limits: ExecutionLimits = .init()) throws {
        guard limits.maxSteps > 0, limits.maxSteps <= 20, limits.maxToolCalls > 0, limits.maxToolCalls <= 32,
              limits.maxParallelTools > 0, limits.maxParallelTools <= 4, limits.maxReservedOutputTokens > 0,
              limits.turnTimeout > .zero else { throw MiraError(.configuration, "执行限额无效。") }
        self.store = store; self.provider = provider; self.environment = environment; self.tools = tools; self.limits = limits
        try store.recoverInterrupted(at: environment.now())
    }

    public func events() -> AsyncStream<ApplicationEvent> {
        let id = environment.uuid()
        let pair = AsyncStream<ApplicationEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
        observers[id] = pair.continuation
        pair.continuation.yield(.changed)
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return pair.stream
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func emit(_ event: ApplicationEvent) { for observer in observers.values { observer.yield(event) } }

    public func library(includeArchived: Bool = false) throws -> LibrarySnapshot {
        .init(workspaces: try store.workspaces(), conversations: try store.conversations(includeArchived: includeArchived), routes: try store.routes())
    }
    public func conversation(_ id: ConversationID) throws -> ConversationSnapshot {
        let executions = try store.executions(in: id)
        let drafts = try executions.filter { !$0.status.isTerminal }.compactMap { execution -> Draft? in
            if let live = text[execution.id] { return Draft(executionID: execution.id, text: live, updatedAt: environment.now()) }
            return try store.draft(for: execution.id)
        }
        return .init(messages: try store.messages(in: id), executions: executions, drafts: drafts, pendingSaveIDs: Set(pendingSaves.keys))
    }
    public func diagnostics() throws -> StorageDiagnostics { try store.diagnostics() }
    public func request(for id: ExecutionID) throws -> CanonicalModelRequest? { try store.request(for: id) }
    public func audit(for id: ExecutionID) throws -> ExecutionAudit {
        .init(attempts: try store.attempts(for: id), invocations: try store.toolInvocations(for: id))
    }

    @discardableResult
    public func createWorkspace(name: String, background: String, allowsRemoteSend: Bool) throws -> WorkspaceID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100, background.utf8.count <= 32_768 else { throw MiraError(.invalidInput, "工作空间名称或背景超出限制。") }
        let workspace = Workspace(id: .init(environment.uuid()), name: name, background: background, allowsRemoteSend: allowsRemoteSend)
        try store.saveWorkspace(workspace, expectedRevision: nil); emit(.changed)
        return workspace.id
    }
    public func updateWorkspace(_ workspace: Workspace) throws {
        guard !workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              workspace.name.count <= 100, workspace.background.utf8.count <= 32_768 else { throw MiraError(.invalidInput, "工作空间名称或背景超出限制。") }
        var updated = workspace; updated.revision += 1
        try store.saveWorkspace(updated, expectedRevision: workspace.revision)
        // Tightened sending policy cancels any in-flight request too.
        if !updated.allowsRemoteSend {
            let ids = Set(try store.conversations(includeArchived: true).filter { $0.workspaceID == updated.id }.map(\.id))
            for execution in active.values where ids.contains(execution.conversationID) { tasks[execution.id]?.cancel() }
        }
        emit(.changed)
    }
    @discardableResult
    public func createConversation(workspaceID: WorkspaceID?) throws -> ConversationID {
        let now = environment.now(), id = ConversationID(environment.uuid())
        try store.createConversation(.init(id: id, workspaceID: workspaceID, title: "新对话", createdAt: now, updatedAt: now))
        emit(.changed); return id
    }
    public func archiveConversation(_ id: ConversationID) throws {
        try store.archiveConversation(id, at: environment.now()); emit(.changed)
    }
    public func saveRoute(_ route: ModelRoute, expectedRevision: Int?) throws {
        _ = try route.validatedEndpoint()
        guard !route.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MiraError(.configuration, "请填写 Model ID。") }
        try store.saveRoute(route, expectedRevision: expectedRevision)
        for execution in active.values where execution.route.id == route.id { tasks[execution.id]?.cancel() }
        emit(.changed)
    }
    public func removeRoute(_ id: RouteID) throws {
        try store.removeRoute(id)
        for execution in active.values where execution.route.id == id { tasks[execution.id]?.cancel() }
        emit(.changed)
    }
    public func exportBackup(to destination: URL) throws { try store.exportBackup(to: destination) }
    public func restoreBackup(from source: URL, to directory: URL) throws { try store.restoreBackup(from: source, to: directory) }

    @discardableResult
    public func send(conversationID: ConversationID, text input: String, routeID: RouteID) throws -> ExecutionID {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.utf8.count <= 262_144 else { throw MiraError(.invalidInput, "请输入消息（最多 256 KiB）。") }
        try checkAvailability(conversationID)
        let route = try resolveRoute(routeID)
        let execution = try store.enqueue(conversationID: conversationID, text: input, route: route,
                                          executionID: .init(environment.uuid()), messageID: .init(environment.uuid()), at: environment.now())
        launch(execution); return execution.id
    }
    @discardableResult
    public func retry(_ executionID: ExecutionID, routeID: RouteID) throws -> ExecutionID {
        try checkLifecycleAndCapacity()
        let route = try resolveRoute(routeID)
        let execution = try store.retry(executionID: executionID, newExecutionID: .init(environment.uuid()), route: route, at: environment.now())
        launch(execution); return execution.id
    }
    public func cancel(_ id: ExecutionID) { tasks[id]?.cancel() }
    public func retryPendingSave(_ id: ExecutionID) throws {
        guard let pending = pendingSaves[id], let execution = active[id] else { return }
        try finish(execution, status: pending.status, error: pending.error)
        pendingSaves[id] = nil; clearLiveState(id); emit(.changed)
    }
    @discardableResult
    public func shutdown() async -> Bool {
        isShuttingDown = true
        let running = Array(tasks.values)
        running.forEach { $0.cancel() }
        for task in running { await task.value }
        for id in Array(pendingSaves.keys) { try? retryPendingSave(id) }
        if !pendingSaves.isEmpty {
            isShuttingDown = false
            emit(.failure(.init(.storage, "仍有回复未能保存，已取消退出。请检查磁盘空间，然后重试保存。")))
            return false
        }
        return true
    }

    private func checkAvailability(_ conversationID: ConversationID) throws {
        try checkLifecycleAndCapacity()
        guard !active.values.contains(where: { $0.conversationID == conversationID }) else { throw MiraError(.busy, "这个对话正在生成回复。") }
    }
    private func checkLifecycleAndCapacity() throws {
        guard !isShuttingDown else { throw MiraError(.busy, "应用正在退出，无法启动新请求。") }
        guard active.count < 2 else { throw MiraError(.busy, "最多同时处理两段回复，请等待生成或保存完成。") }
    }
    private func resolveRoute(_ id: RouteID) throws -> ModelRoute {
        guard let route = try store.routes().first(where: { $0.id == id }) else { throw MiraError(.configuration, "请先配置并选择模型服务。") }
        try route.validateForSending(); return route
    }
    private func launch(_ execution: Execution) {
        active[execution.id] = execution; text[execution.id] = ""; usage[execution.id] = .init(); checkpointBytes[execution.id] = 0
        tasks[execution.id] = Task { await self.run(execution) }
        emit(.changed)
    }

    private func run(_ execution: Execution) async {
        let deadlineClock = environment.clock
        let turnTimeout = limits.turnTimeout
        let deadline = Task { [weak self] in
            do {
                try await deadlineClock.sleep(for: turnTimeout)
                try Task.checkCancellation()
                await self?.expireExecution(execution.id)
            } catch { }
        }
        let ticker = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)); try self.checkpoint(execution.id) }
                catch is CancellationError { return }
                catch { self.tasks[execution.id]?.cancel(); self.emit(.failure(MiraError.safe(error))); return }
            }
        }
        defer {
            ticker.cancel(); deadline.cancel(); tasks[execution.id] = nil
            if pendingSaves[execution.id] == nil { clearLiveState(execution.id) }
            emit(.changed)
        }
        var finalStatus = ExecutionStatus.completed
        var finalError: MiraError?
        do {
            var exchanges: [CanonicalMessage] = []
            let definitions = (execution.route.toolCapability == .declared || execution.route.toolCapability == .verified) ? tools.definitions : []
            var toolCount = 0, reservedOutput = 0
            var priorExchange: String?, repeatedExchanges = 0
            var finished = false
            for step in 1...limits.maxSteps {
                try Task.checkCancellation()
                guard reservedOutput <= limits.maxReservedOutputTokens - execution.route.maxOutputTokens else { throw MiraError(.outputLimit, "本回合已达到模型输出预留预算，请新建对话。") }
                reservedOutput += execution.route.maxOutputTokens
                let base = try ContextBuilder.build(execution: execution, conversations: store.conversations(includeArchived: true),
                                                    workspaces: store.workspaces(), messages: store.messages(in: execution.conversationID),
                                                    executions: store.executions(in: execution.conversationID))
                let attemptID = environment.uuid()
                let request = try ContextBuilder.extending(base, requestID: attemptID, exchanges: exchanges, tools: definitions, route: execution.route)
                try validateDispatch(execution)
                let attempt = ModelAttempt(id: attemptID, executionID: execution.id, stepID: environment.uuid(), stepIndex: step, request: request, createdAt: environment.now())
                try store.prepareAttempt(attempt)
                emit(.changed)
                let output: ModelOutput
                var attemptUsage = TokenUsage()
                do {
                    output = try await receiveOutput(request: request, execution: execution, priorSteps: step - 1, attemptUsage: &attemptUsage)
                } catch {
                    try store.finishAttempt(attemptID, output: nil, invocations: [], usage: attemptUsage, error: MiraError.safe(error), at: environment.now())
                    throw error
                }
                let invocations = output.toolCalls.enumerated().map { ToolInvocation(id: environment.uuid(), attemptID: attemptID, modelOrder: $0.offset, call: $0.element) }
                try store.finishAttempt(attemptID, output: output, invocations: invocations, usage: attemptUsage, error: nil, at: environment.now())
                try checkpoint(execution.id)
                emit(.changed)
                if output.finishReason == .outputLimit { throw MiraError(.outputLimit, "已达到输出上限，可调整模型配置后重试。") }
                if output.toolCalls.isEmpty {
                    guard !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MiraError(.providerRejected, "模型未返回文本，请检查此模型的接口能力后重试。") }
                    finished = true; break
                }
                toolCount += output.toolCalls.count
                guard toolCount <= limits.maxToolCalls else {
                    for invocation in invocations { try store.finishToolInvocation(invocation.id, result: .init(status: .outputLimit, text: "本回合工具调用数量已达上限，未执行。"), at: environment.now()) }
                    throw MiraError(.outputLimit, "本回合工具调用数量已达上限。")
                }
                let results = try await runTools(invocations, execution: execution)
                try Task.checkCancellation()
                exchanges.append(.init(role: .assistant, text: output.text, toolCalls: output.toolCalls))
                for (invocation, result) in zip(invocations, results) {
                    exchanges.append(.init(role: .tool, text: try result.observation(), toolCallID: invocation.call.id))
                }
                let signature = try zip(invocations, results).map { invocation, result in
                    let arguments = (try? JSONDecoder().decode(JSONValue.self, from: Data(invocation.call.arguments.utf8)).jsonString()) ?? invocation.call.arguments
                    return invocation.call.name + "\n" + arguments + "\n" + (try result.observation())
                }.joined(separator: "\n---\n")
                repeatedExchanges = signature == priorExchange ? repeatedExchanges + 1 : 1
                priorExchange = signature
                if repeatedExchanges >= 3 { throw MiraError(.outputLimit, "连续三次相同工具调用返回相同结果，已停止无进展循环。") }
            }
            guard finished else { throw MiraError(.outputLimit, "本回合已达到模型决策步骤上限。") }
        } catch {
            let safe = expired.contains(execution.id) ? MiraError(.timeout, "本回合已达到活动执行时间上限。") : MiraError.safe(error)
            finalError = safe
            finalStatus = safe.code == .cancelled ? .cancelled :
                (safe.code == .outputLimit || safe.code == .malformedStream || safe.code == .network || safe.code == .timeout || safe.code == .interrupted ? .interrupted : .failed)
        }
        do { try finish(execution, status: finalStatus, error: finalError) }
        catch {
            pendingSaves[execution.id] = .init(status: finalStatus, error: finalError)
            emit(.failure(.init(.storage, "回复尚未保存，已保留在当前应用中。请检查磁盘空间，然后点击“重试保存”。")))
        }
    }
    private func expireExecution(_ id: ExecutionID) {
        guard !Task.isCancelled, tasks[id] != nil else { return }
        expired.insert(id); tasks[id]?.cancel()
    }
    private func receiveOutput(request: CanonicalModelRequest, execution: Execution, priorSteps: Int, attemptUsage: inout TokenUsage) async throws -> ModelOutput {
        var terminal: StreamFinishReason?, calls: [CanonicalToolCall] = [], sawCalls = false, stepText = ""
        let priorUsage = usage[execution.id] ?? .init()
        let prefix = text[execution.id] ?? ""
        for try await event in provider.stream(request: request, route: execution.route) {
            try Task.checkCancellation()
            guard terminal == nil else { throw MiraError(.malformedStream, "服务在结束后仍返回数据。") }
            switch event {
            case .textDelta(let delta):
                stepText += delta
                let newText = prefix + (prefix.isEmpty || stepText.isEmpty ? "" : "\n\n") + stepText
                guard newText.utf8.count <= 2_097_152 else { throw MiraError(.outputLimit, "回复超过本地安全上限。") }
                text[execution.id] = newText
                if newText.utf8.count - (checkpointBytes[execution.id] ?? 0) >= 4096 { try checkpoint(execution.id) }
                emit(.draft(execution.id, newText))
            case .toolCalls(let batch):
                let previousIDs = Set(request.messages.flatMap { $0.toolCalls ?? [] }.map(\.id))
                guard !sawCalls, !(request.tools ?? []).isEmpty, !batch.isEmpty, batch.count <= 32,
                      Set(batch.map(\.id)).count == batch.count,
                      batch.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 256 && !previousIDs.contains($0.id) && !$0.name.isEmpty && $0.name.utf8.count <= 128 && $0.arguments.utf8.count <= 65_536 }) else {
                    throw MiraError(.malformedStream, "服务返回的工具调用缺失身份、重复或超出限制。")
                }
                sawCalls = true; calls = batch
            case .usage(let next):
                guard (next.inputTokens ?? 0) >= 0, (next.outputTokens ?? 0) >= 0,
                      (next.inputTokens ?? 0) <= 100_000_000, (next.outputTokens ?? 0) <= 100_000_000 else { throw MiraError(.malformedStream, "服务返回的用量无效。") }
                attemptUsage = next
                usage[execution.id] = priorSteps == 0 ? next : .init(
                    inputTokens: priorUsage.inputTokens.flatMap { old in next.inputTokens.map { old + $0 } },
                    outputTokens: priorUsage.outputTokens.flatMap { old in next.outputTokens.map { old + $0 } })
            case .finished(let reason): terminal = reason
            }
        }
        try Task.checkCancellation()
        guard let terminal else { throw MiraError(.malformedStream, "连接提前结束，回复可能不完整。") }
        guard (terminal == .toolCalls) == !calls.isEmpty else { throw MiraError(.malformedStream, "工具调用与模型停止原因不匹配。") }
        // A missing report in any attempt keeps the aggregate unknown, rather than reusing the last attempt's total.
        usage[execution.id] = priorSteps == 0 ? attemptUsage : .init(
            inputTokens: priorUsage.inputTokens.flatMap { old in attemptUsage.inputTokens.map { old + $0 } },
            outputTokens: priorUsage.outputTokens.flatMap { old in attemptUsage.outputTokens.map { old + $0 } })
        return .init(text: stepText, toolCalls: calls, finishReason: terminal)
    }

    private func validateDispatch(_ execution: Execution) throws {
        try Task.checkCancellation()
        guard try resolveRoute(execution.route.id) == execution.route else { throw MiraError(.connectionChanged, "模型配置已改变，请重新发送。") }
        guard let conversation = try store.conversations(includeArchived: true).first(where: { $0.id == execution.conversationID }), !conversation.isArchived else {
            throw MiraError(.notFound, "当前对话已不可用。")
        }
        if let workspaceID = conversation.workspaceID {
            guard let workspace = try store.workspaces().first(where: { $0.id == workspaceID }), workspace.allowsRemoteSend else {
                throw MiraError(.unauthorized, "此工作空间已禁止发送，执行已停止。")
            }
        }
    }

    private func runTools(_ invocations: [ToolInvocation], execution: Execution) async throws -> [ToolResult] {
        var results: [UUID: ToolResult] = [:], cursor = 0
        while cursor < invocations.count {
            if Task.isCancelled {
                for invocation in invocations[cursor...] {
                    let result = ToolResult(status: .cancelledBeforeDispatch, text: "已停止，工具尚未执行。")
                    try store.finishToolInvocation(invocation.id, result: result, at: environment.now()); results[invocation.id] = result
                }
                break
            }
            let start = cursor
            if tools.tool(named: invocations[cursor].call.name)?.descriptor.executionMode == .parallelSafe {
                while cursor < invocations.count && tools.tool(named: invocations[cursor].call.name)?.descriptor.executionMode == .parallelSafe { cursor += 1 }
            } else { cursor += 1 }
            let batch = Array(invocations[start..<cursor])
            try await withThrowingTaskGroup(of: (UUID, ToolResult).self) { group in
                var next = 0
                func schedule(_ invocation: ToolInvocation) {
                    group.addTask { (invocation.id, await self.performTool(invocation, execution: execution)) }
                }
                while next < min(batch.count, limits.maxParallelTools) { schedule(batch[next]); next += 1 }
                while let (id, result) = try await group.next() {
                    try store.finishToolInvocation(id, result: result, at: environment.now()); results[id] = result
                    emit(.changed)
                    if next < batch.count && !Task.isCancelled { schedule(batch[next]); next += 1 }
                }
                for invocation in batch[next...] {
                    let result = ToolResult(status: .cancelledBeforeDispatch, text: "已停止，工具尚未执行。")
                    try store.finishToolInvocation(invocation.id, result: result, at: environment.now()); results[invocation.id] = result
                }
            }
        }
        return try invocations.map {
            guard let result = results[$0.id] else { throw MiraError(.storage, "工具结果尚未完整保存。") }
            return result
        }
    }

    private func performTool(_ invocation: ToolInvocation, execution: Execution) async -> ToolResult {
        guard !Task.isCancelled else { return .init(status: .cancelledBeforeDispatch, text: "已停止，工具尚未执行。") }
        guard let tool = tools.tool(named: invocation.call.name) else { return .init(status: .notFound, text: "本次执行未提供此工具。") }
        let arguments: JSONValue
        do { arguments = try ToolSchemaValidator.decode(invocation.call.arguments, schema: tool.descriptor.definition.inputSchema) }
        catch { return .init(status: .invalidArguments, text: "工具参数不符合声明的结构或大小限制。") }
        let context: ToolContext
        do {
            try validateDispatch(execution)
            let conversation = try store.conversations(includeArchived: true).first { $0.id == execution.conversationID }
            guard let trigger = try store.messages(in: execution.conversationID).first(where: { $0.id == execution.triggerMessageID }) else { throw MiraError(.notFound, "原始用户请求不可用。") }
            context = .init(executionID: execution.id, invocationID: invocation.id, workspaceID: conversation?.workspaceID, userMessageID: execution.triggerMessageID, userText: trigger.text)
        } catch { return .init(status: Task.isCancelled ? .cancelledBeforeDispatch : .denied, text: "当前权限或连接已改变，工具未执行。") }
        let toolClock = environment.clock
        let result = await withTaskGroup(of: ToolResult.self) { group in
            group.addTask {
                do {
                    try await tool.authorize(arguments: arguments, context: context)
                    try Task.checkCancellation()
                    try await self.markToolDispatch(invocation.id, execution: execution)
                    try Task.checkCancellation()
                    let value = try await tool.execute(arguments: arguments, context: context)
                    try Task.checkCancellation()
                    guard value.utf8.count <= tool.descriptor.maxResultBytes else { return .init(status: .outputLimit, text: "工具结果超出大小限制，未发送正文。") }
                    return .init(status: .succeeded, text: value)
                } catch {
                    if error is CancellationError || Task.isCancelled { return .init(status: .cancelled, text: "工具已停止；请查看操作结果。") }
                    if let error = error as? MiraError, error.code == .unauthorized || error.code == .connectionChanged { return .init(status: .denied, text: "工具权限检查未通过，未授权执行。") }
                    return .init(status: .failed, text: "工具未能完成，请检查后重试。")
                }
            }
            group.addTask {
                do { try await toolClock.sleep(for: tool.descriptor.timeout); try Task.checkCancellation(); return .init(status: .timedOut, text: "工具超过执行时间限制，已请求取消。") }
                catch { return .init(status: .cancelled, text: "工具已停止。") }
            }
            let first = await group.next() ?? .init(status: .cancelled, text: "工具已停止。")
            group.cancelAll()
            return first
        }
        if result.status == .cancelled,
           (try? store.toolInvocations(for: execution.id).first(where: { $0.id == invocation.id })?.dispatchedAt) == nil {
            return .init(status: .cancelledBeforeDispatch, text: "已停止，工具尚未执行。")
        }
        return result
    }

    private func markToolDispatch(_ id: UUID, execution: Execution) throws {
        // This actor check follows tool-specific authorization and immediately precedes its operation.
        try validateDispatch(execution)
        try store.markToolDispatched(id, at: environment.now()); emit(.changed)
    }

    private func clearLiveState(_ id: ExecutionID) {
        active[id] = nil; text[id] = nil; usage[id] = nil; checkpointBytes[id] = nil; expired.remove(id)
    }
    private func checkpoint(_ id: ExecutionID) throws {
        guard let value = text[id], value.utf8.count != checkpointBytes[id] else { return }
        try store.checkpoint(executionID: id, text: value, at: environment.now())
        checkpointBytes[id] = value.utf8.count
    }
    private func finish(_ execution: Execution, status: ExecutionStatus, error: MiraError?) throws {
        try store.finish(executionID: execution.id, status: status, text: text[execution.id] ?? "",
                         usage: usage[execution.id] ?? .init(), error: error,
                         assistantMessageID: .init(environment.uuid()), at: environment.now())
    }
}
