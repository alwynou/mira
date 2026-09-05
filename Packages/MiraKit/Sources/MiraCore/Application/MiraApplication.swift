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
    private var tasks: [ExecutionID: Task<Void, Never>] = [:]
    private var active: [ExecutionID: Execution] = [:]
    private var text: [ExecutionID: String] = [:]
    private var usage: [ExecutionID: TokenUsage] = [:]
    private var checkpointBytes: [ExecutionID: Int] = [:]
    private struct PendingSave { let status: ExecutionStatus; let error: MiraError? }
    private var pendingSaves: [ExecutionID: PendingSave] = [:]
    private var isShuttingDown = false
    private var observers: [UUID: AsyncStream<ApplicationEvent>.Continuation] = [:]

    public init(store: any MiraStore, provider: any ModelProviderPort, environment: RuntimeEnvironment = .init()) throws {
        self.store = store; self.provider = provider; self.environment = environment
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
        let ticker = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)); try self.checkpoint(execution.id) }
                catch is CancellationError { return }
                catch { self.tasks[execution.id]?.cancel(); self.emit(.failure(MiraError.safe(error))); return }
            }
        }
        defer {
            ticker.cancel(); tasks[execution.id] = nil
            if pendingSaves[execution.id] == nil { clearLiveState(execution.id) }
            emit(.changed)
        }
        var finalStatus = ExecutionStatus.completed
        var finalError: MiraError?
        do {
            try Task.checkCancellation()
            let request = try ContextBuilder.build(execution: execution, conversations: store.conversations(includeArchived: true),
                                                   workspaces: store.workspaces(), messages: store.messages(in: execution.conversationID),
                                                   executions: store.executions(in: execution.conversationID))
            let currentRoute = try resolveRoute(execution.route.id)
            guard currentRoute == execution.route else { throw MiraError(.connectionChanged, "模型配置已改变，请重新发送。") }
            try store.prepare(executionID: execution.id, request: request, at: environment.now())
            emit(.changed)
            var terminal: StreamFinishReason?
            for try await event in provider.stream(request: request, route: execution.route) {
                try Task.checkCancellation()
                guard terminal == nil else { throw MiraError(.malformedStream, "服务在结束后仍返回数据。") }
                switch event {
                case .textDelta(let delta):
                    let newText = (text[execution.id] ?? "") + delta
                    guard newText.utf8.count <= 2_097_152 else { throw MiraError(.outputLimit, "回复超过本地安全上限。") }
                    text[execution.id] = newText
                    if newText.utf8.count - (checkpointBytes[execution.id] ?? 0) >= 4096 { try checkpoint(execution.id) }
                    emit(.draft(execution.id, newText))
                case .usage(let newUsage): usage[execution.id] = newUsage
                case .finished(let reason): terminal = reason
                }
            }
            try Task.checkCancellation()
            guard let terminal else { throw MiraError(.malformedStream, "连接提前结束，回复可能不完整。") }
            if terminal == .outputLimit { throw MiraError(.outputLimit, "已达到输出上限，可调整模型配置后重试。") }
            guard !(text[execution.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MiraError(.providerRejected, "模型未返回文本，请检查此模型的接口能力后重试。")
            }
        } catch {
            let safe = MiraError.safe(error)
            finalError = safe
            finalStatus = (error is CancellationError || safe.code == .cancelled) ? .cancelled :
                (safe.code == .outputLimit || safe.code == .malformedStream || safe.code == .network || safe.code == .timeout || safe.code == .interrupted ? .interrupted : .failed)
        }
        do { try finish(execution, status: finalStatus, error: finalError) }
        catch {
            pendingSaves[execution.id] = .init(status: finalStatus, error: finalError)
            emit(.failure(.init(.storage, "回复尚未保存，已保留在当前应用中。请检查磁盘空间，然后点击“重试保存”。")))
        }
    }
    private func clearLiveState(_ id: ExecutionID) {
        active[id] = nil; text[id] = nil; usage[id] = nil; checkpointBytes[id] = nil
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
