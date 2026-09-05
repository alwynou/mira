import Foundation

public enum ApplicationEvent: Sendable {
    case changed
    case draft(ExecutionID, String)
    case failure(MiraError)
}
public struct LibrarySnapshot: Sendable {
    public var workspaces: [Workspace]
    public var conversations: [Conversation]
    public var configuration: ModelConfiguration
    public var routes: [ModelRoute] { configuration.routes }
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
    private let memoryApprovals: MemoryApprovalCoordinator
    private let memoryExtraction: MemoryExtractionWorker
    private var memoryExtractionEvents: Task<Void, Never>?
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

    public init(store: any MiraStore, provider: any ModelProviderPort, environment: RuntimeEnvironment = .init(), tools: ToolRegistry = .empty, limits: ExecutionLimits = .init(), memoryApprovals: MemoryApprovalCoordinator = .init()) throws {
        guard limits.maxSteps > 0, limits.maxSteps <= 20, limits.maxToolCalls > 0, limits.maxToolCalls <= 32,
              limits.maxParallelTools > 0, limits.maxParallelTools <= 4, limits.maxReservedOutputTokens > 0,
              limits.turnTimeout > .zero else { throw MiraError(.configuration, "Execution limits are invalid.") }
        self.store = store; self.provider = provider; self.environment = environment; self.tools = tools; self.limits = limits
        self.memoryApprovals = memoryApprovals
        self.memoryExtraction = MemoryExtractionWorker(store: store, provider: provider, environment: environment)
        try store.recoverInterrupted(at: environment.now())
        try store.recoverMemoryExtraction(at: environment.now())
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

    /// Called once by composition after opening the library, independent of view lifetime.
    public func startBackgroundWork() async {
        guard memoryExtractionEvents == nil, !isShuttingDown else { return }
        let stream = await memoryExtraction.events()
        memoryExtractionEvents = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.receiveMemoryExtractionEvent(event)
            }
        }
        await memoryExtraction.wake()
    }

    private func receiveMemoryExtractionEvent(_ event: MemoryExtractionWorkerEvent) {
        switch event {
        case .changed: emit(.changed)
        // Persistent job errors appear with their source; background failures
        // should not replace an unrelated foreground conversation's error.
        case .failure: emit(.changed)
        }
    }

    public func memoryCapturePolicy() throws -> MemoryCapturePolicy { try store.memoryCapturePolicy() }
    public func memoryExtractionBudget() throws -> MemoryExtractionBudget { try store.memoryExtractionBudget(at: environment.now()) }
    public func memoryExtractionJobs(conversationID: ConversationID? = nil, limit: Int = 50) throws -> [MemoryExtractionJob] {
        try store.memoryExtractionJobs(conversationID: conversationID, limit: limit)
    }
    public func saveMemoryCapturePolicy(mode: MemoryCaptureMode, dailyTokenLimit: Int, expectedRevision: Int) async throws {
        guard !isShuttingDown else { throw MiraError(.busy, "The app is shutting down and cannot start a new request.") }
        let current = try store.memoryCapturePolicy()
        guard current.revision == expectedRevision, current.revision < Int.max else { throw MiraError(.conflict, "The memory capture policy revision is out of date.") }
        let now = environment.now()
        let enabledAt: Date? = mode == .manualOnly ? nil : (current.mode == .manualOnly ? now : current.enabledAt)
        let next = MemoryCapturePolicy(revision: current.revision + 1, mode: mode, dailyTokenLimit: dailyTokenLimit, enabledAt: enabledAt)
        try store.saveMemoryCapturePolicy(next, expectedRevision: expectedRevision, at: now)
        await memoryExtraction.cancelCurrent()
        emit(.changed)
        await startBackgroundWork()
        await memoryExtraction.wake()
    }
    public func retryMemoryExtraction(_ id: MemoryExtractionJobID) async throws {
        guard !isShuttingDown else { throw MiraError(.busy, "The app is shutting down and cannot start a new request.") }
        _ = try store.retryMemoryExtraction(id, at: environment.now())
        emit(.changed)
        await startBackgroundWork()
        await memoryExtraction.wake()
    }

    private func invalidateMemoryExtraction() async {
        await memoryExtraction.cancelCurrent()
        if !isShuttingDown { await memoryExtraction.wake() }
    }

    public func library(includeArchived: Bool = false) throws -> LibrarySnapshot {
        .init(workspaces: try store.workspaces(), conversations: try store.conversations(includeArchived: includeArchived), configuration: try store.modelConfiguration())
    }

    public func memoryList(workspaceID: WorkspaceID?, states: Set<MemoryState>, query: String, limit: Int = 100) throws -> MemorySearchResult {
        try store.memoryList(workspaceID: workspaceID, states: states, query: query, limit: limit)
    }
    public func memoryDetail(_ id: MemoryID, workspaceID: WorkspaceID?) throws -> MemoryDetail {
        try store.memoryDetail(id, workspaceID: workspaceID)
    }
    public func memoryCitation(_ reference: MemoryCitationReference, executionID: ExecutionID, conversationID: ConversationID) throws -> MemoryCitationDetail {
        try store.memoryCitation(reference, executionID: executionID, conversationID: conversationID)
    }
    public func memoryApprovalEvents() async -> AsyncStream<[MemoryApprovalRequest]> { await memoryApprovals.events() }
    public func respondToMemoryApproval(_ id: UUID, approved: Bool) async { await memoryApprovals.respond(id, approved: approved) }
    public func createMemory(draft: MemoryDraft, source: MemorySourceInput, operationID: UUID, replacing: MemoryID? = nil, expectedRevision: Int? = nil) async throws -> MemoryWriteReceipt {
        let receipt = try store.createMemory(draft: draft, source: source, operationID: operationID, replacing: replacing, expectedRevision: expectedRevision, at: environment.now())
        if replacing != nil { await cancelMemoryConsumers() }
        emit(.changed)
        return receipt
    }
    public func reviseMemory(_ id: MemoryID, workspaceID: WorkspaceID?, draft: MemoryDraft, expectedRevision: Int) async throws -> Memory {
        let memory = try store.reviseMemory(id, workspaceID: workspaceID, draft: draft, expectedRevision: expectedRevision, at: environment.now())
        await cancelMemoryConsumers(); emit(.changed)
        return memory
    }
    public func changeMemoryState(_ id: MemoryID, workspaceID: WorkspaceID?, state: MemoryState, expectedRevision: Int) async throws -> Memory {
        let memory = try store.changeMemoryState(id, workspaceID: workspaceID, state: state, expectedRevision: expectedRevision, at: environment.now())
        await cancelMemoryConsumers(); emit(.changed)
        return memory
    }
    public func forgetMemory(_ id: MemoryID, workspaceID: WorkspaceID?, expectedRevision: Int) async throws -> MemoryForgetReceipt {
        let receipt = try store.forgetMemory(id, workspaceID: workspaceID, expectedRevision: expectedRevision, at: environment.now())
        for executionID in receipt.redactedExecutionIDs {
            tasks[executionID]?.cancel(); text[executionID] = nil; pendingSaves[executionID] = nil
            emit(.draft(executionID, ""))
        }
        await cancelMemoryConsumers(); emit(.changed)
        return receipt
    }
    public func confirmMemoryReplacement(_ candidateID: MemoryID, workspaceID: WorkspaceID?, replacingCurrent currentID: MemoryID, expectedCandidateRevision: Int, expectedCurrentRevision: Int) async throws -> Memory {
        let memory = try store.confirmMemoryReplacement(candidateID, workspaceID: workspaceID, replacingCurrent: currentID, expectedCandidateRevision: expectedCandidateRevision, expectedCurrentRevision: expectedCurrentRevision, at: environment.now())
        await cancelMemoryConsumers(); emit(.changed)
        return memory
    }
    private func cancelMemoryConsumers() async {
        // Conservative until dependency-specific live cancellation is needed. Store checks remain authoritative.
        for task in tasks.values { task.cancel() }
        await memoryExtraction.cancelCurrent()
        if !isShuttingDown { await memoryExtraction.wake() }
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
    public func createWorkspace(name: String, background: String, allowsRemoteSend: Bool, allowedConnectionIDs: Set<ConnectionID>? = nil) throws -> WorkspaceID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100, background.utf8.count <= 32_768 else { throw MiraError(.invalidInput, "Workspace name or background exceeds the limit.") }
        let workspace = Workspace(id: .init(environment.uuid()), name: name, background: background, allowsRemoteSend: allowsRemoteSend, allowedConnectionIDs: allowedConnectionIDs)
        try store.saveWorkspace(workspace, expectedRevision: nil); emit(.changed)
        return workspace.id
    }
    public func updateWorkspace(_ workspace: Workspace) async throws {
        guard !workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              workspace.name.count <= 100, workspace.background.utf8.count <= 32_768 else { throw MiraError(.invalidInput, "Workspace name or background exceeds the limit.") }
        var updated = workspace; updated.revision += 1
        try store.saveWorkspace(updated, expectedRevision: workspace.revision)
        // Tightened sending policy cancels any in-flight request too.
        if !updated.allowsRemoteSend || updated.allowedConnectionIDs != workspace.allowedConnectionIDs {
            let ids = Set(try store.conversations(includeArchived: true).filter { $0.workspaceID == updated.id }.map(\.id))
            for execution in active.values where ids.contains(execution.conversationID) { tasks[execution.id]?.cancel() }
        }
        await invalidateMemoryExtraction(); emit(.changed)
    }
    @discardableResult
    public func createConversation(workspaceID: WorkspaceID?) throws -> ConversationID {
        let now = environment.now(), id = ConversationID(environment.uuid())
        try store.createConversation(.init(id: id, workspaceID: workspaceID, title: "", createdAt: now, updatedAt: now))
        emit(.changed); return id
    }
    public func archiveConversation(_ id: ConversationID) async throws {
        try store.archiveConversation(id, at: environment.now()); await invalidateMemoryExtraction(); emit(.changed)
    }
    public func saveConnection(_ connection: ProviderConnection, expectedRevision: Int?) async throws {
        try connection.validate()
        try store.saveConnection(connection, expectedRevision: expectedRevision)
        for execution in active.values where execution.route.connectionID == connection.id { tasks[execution.id]?.cancel() }
        await invalidateMemoryExtraction(); emit(.changed)
    }
    public func removeConnection(_ id: ConnectionID) async throws {
        try store.removeConnection(id)
        for execution in active.values where execution.route.connectionID == id { tasks[execution.id]?.cancel() }
        await invalidateMemoryExtraction(); emit(.changed)
    }
    public func saveModel(_ model: ModelDescriptor, expectedRevision: Int?) async throws {
        try model.validate()
        try store.saveModel(model, expectedRevision: expectedRevision)
        for execution in active.values where execution.route.modelDescriptorID == model.id { tasks[execution.id]?.cancel() }
        await invalidateMemoryExtraction(); emit(.changed)
    }
    public func removeModel(_ id: ModelDescriptorID) async throws {
        try store.removeModel(id)
        for execution in active.values where execution.route.modelDescriptorID == id { tasks[execution.id]?.cancel() }
        await invalidateMemoryExtraction(); emit(.changed)
    }
    public func saveProbe(_ observation: ProbeObservation, for snapshot: ResolvedModelRouteSnapshot) async throws {
        try Task.checkCancellation()
        guard observation.state == .verified || observation.state == .failed else { return }
        let configuration = try store.modelConfiguration()
        guard let current = try? configuration.snapshot(routeID: snapshot.id, purpose: snapshot.purpose, selection: snapshot.selectionSource), current == snapshot,
              var model = configuration.models.first(where: { $0.id == snapshot.modelDescriptorID }) else {
            throw MiraError(.conflict, "The connection changed. Test results did not overwrite the new configuration.")
        }
        let previousRevision = model.revision
        model.textCapability = snapshot.textCapability; model.toolCapability = snapshot.toolCapability
        if observation.type == .text { model.textCapability = observation.state }
        else { model.toolCapability = observation.state }
        model.connectionRevision = snapshot.connectionRevision
        model.probeObservation = observation; model.revision += 1
        try await saveModel(model, expectedRevision: previousRevision)
    }
    public func saveRoute(_ route: ModelRoute, expectedRevision: Int?) async throws {
        try route.validate()
        try store.saveRoute(route, expectedRevision: expectedRevision)
        for execution in active.values where execution.route.id == route.id { tasks[execution.id]?.cancel() }
        await invalidateMemoryExtraction(); emit(.changed)
    }
    public func removeRoute(_ id: RouteID) async throws {
        try store.removeRoute(id)
        for execution in active.values where execution.route.id == id { tasks[execution.id]?.cancel() }
        await invalidateMemoryExtraction(); emit(.changed)
    }
    public func saveRouteBinding(_ binding: RouteBinding, expectedRevision: Int?) async throws {
        try store.saveRouteBinding(binding, expectedRevision: expectedRevision); await invalidateMemoryExtraction(); emit(.changed)
    }
    public func removeRouteBinding(_ binding: RouteBinding) async throws {
        try store.removeRouteBinding(binding); await invalidateMemoryExtraction(); emit(.changed)
    }
    public func exportBackup(to destination: URL) throws { try store.exportBackup(to: destination) }
    public func restoreBackup(from source: URL, to directory: URL) throws { try store.restoreBackup(from: source, to: directory) }

    @discardableResult
    public func send(conversationID: ConversationID, text input: String, routeID: RouteID? = nil) throws -> ExecutionID {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.utf8.count <= 262_144 else { throw MiraError(.invalidInput, "Enter a message (maximum 256 KiB).") }
        try checkAvailability(conversationID)
        let route = try resolveRoute(routeID, conversationID: conversationID)
        let execution = try store.enqueue(conversationID: conversationID, text: input, route: route,
                                          executionID: .init(environment.uuid()), messageID: .init(environment.uuid()), at: environment.now())
        launch(execution); return execution.id
    }
    @discardableResult
    public func retry(_ executionID: ExecutionID, routeID: RouteID? = nil) throws -> ExecutionID {
        try checkLifecycleAndCapacity()
        guard let previous = try store.execution(executionID) else { throw MiraError(.notFound, "The execution does not exist.") }
        let route = try resolveRoute(routeID, conversationID: previous.conversationID)
        let execution = try store.retry(executionID: executionID, newExecutionID: .init(environment.uuid()), route: route, at: environment.now())
        launch(execution); return execution.id
    }
    public func cancel(_ id: ExecutionID) { tasks[id]?.cancel() }
    public func retryPendingSave(_ id: ExecutionID) throws {
        guard let pending = pendingSaves[id], let execution = active[id] else { return }
        try finish(execution, status: pending.status, error: pending.error)
        pendingSaves[id] = nil; clearLiveState(id); emit(.changed)
        Task { if !isShuttingDown { await memoryExtraction.wake() } }
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
            emit(.failure(.init(.storage, "There are still replies that could not be saved, so shutdown was cancelled. Check available disk space, then retry saving.")))
            return false
        }
        await memoryExtraction.shutdown()
        memoryExtractionEvents?.cancel(); memoryExtractionEvents = nil
        return true
    }

    private func checkAvailability(_ conversationID: ConversationID) throws {
        try checkLifecycleAndCapacity()
        guard !active.values.contains(where: { $0.conversationID == conversationID }) else { throw MiraError(.busy, "This conversation is already generating a reply.") }
    }
    private func checkLifecycleAndCapacity() throws {
        guard !isShuttingDown else { throw MiraError(.busy, "The app is shutting down and cannot start a new request.") }
        guard active.count < 2 else { throw MiraError(.busy, "At most two replies can be processed at once. Wait for generation or saving to finish.") }
    }
    private func resolveRoute(_ id: RouteID?, conversationID: ConversationID) throws -> ResolvedModelRouteSnapshot {
        guard let conversation = try store.conversations(includeArchived: true).first(where: { $0.id == conversationID }), !conversation.isArchived else {
            throw MiraError(.notFound, "Conversation is no longer available.")
        }
        let workspace = try conversation.workspaceID.flatMap { workspaceID in try store.workspaces().first { $0.id == workspaceID } }
        return try store.modelConfiguration().resolve(purpose: .conversation, explicitRouteID: id, conversation: conversation, workspace: workspace)
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
                guard reservedOutput <= limits.maxReservedOutputTokens - execution.route.maxOutputTokens else { throw MiraError(.outputLimit, "Output reservation for this turn reached its limit. Start a new conversation.") }
                reservedOutput += execution.route.maxOutputTokens
                let conversations = try store.conversations(includeArchived: true)
                let messages = try store.messages(in: execution.conversationID)
                let workspaceID = conversations.first { $0.id == execution.conversationID }?.workspaceID
                let query = messages.first { $0.id == execution.triggerMessageID }?.text ?? ""
                let recalled = try store.recallMemories(query: query, workspaceID: workspaceID, connectionID: execution.route.connectionID, limit: 6, at: environment.now())
                let base = try ContextBuilder.build(execution: execution, conversations: conversations,
                                                    workspaces: store.workspaces(), messages: messages,
                                                    executions: store.executions(in: execution.conversationID),
                                                    memories: recalled.memories, suppressedMessageIDs: store.suppressedMemorySourceMessageIDs(), at: environment.now())
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
                if output.finishReason == .outputLimit { throw MiraError(.outputLimit, "Output limit reached. Adjust the model configuration and retry.") }
                if output.toolCalls.isEmpty {
                    guard !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MiraError(.providerRejected, "The model returned no text. Check this model's interface capabilities and retry.") }
                    finished = true; break
                }
                toolCount += output.toolCalls.count
                guard toolCount <= limits.maxToolCalls else {
                    for invocation in invocations { try store.finishToolInvocation(invocation.id, result: .init(status: .outputLimit, text: "This turn reached its tool-call limit; the calls were not executed."), at: environment.now()) }
                    throw MiraError(.outputLimit, "This turn reached its tool-call limit.")
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
                if repeatedExchanges >= 3 { throw MiraError(.outputLimit, "Three consecutive identical tool calls returned identical results. Stopped the no-progress loop.") }
            }
            guard finished else { throw MiraError(.outputLimit, "This turn reached the model decision-step limit.") }
        } catch {
            let safe = expired.contains(execution.id) ? MiraError(.timeout, "This turn reached the active execution time limit.") : MiraError.safe(error)
            finalError = safe
            finalStatus = safe.code == .cancelled ? .cancelled :
                (safe.code == .outputLimit || safe.code == .malformedStream || safe.code == .network || safe.code == .timeout || safe.code == .interrupted ? .interrupted : .failed)
        }
        do { try finish(execution, status: finalStatus, error: finalError) }
        catch {
            pendingSaves[execution.id] = .init(status: finalStatus, error: finalError)
            emit(.failure(.init(.storage, "Reply has not been saved and is being kept in the current app. Check available disk space, then click \"Retry Save.\"")))
        }
        await memoryApprovals.cancel(executionID: execution.id)
        if !isShuttingDown { await memoryExtraction.wake() }
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
            guard terminal == nil else { throw MiraError(.malformedStream, "Service returned data after the stream ended.") }
            switch event {
            case .textDelta(let delta):
                stepText += delta
                let newText = prefix + (prefix.isEmpty || stepText.isEmpty ? "" : "\n\n") + stepText
                guard newText.utf8.count <= 2_097_152 else { throw MiraError(.outputLimit, "Reply exceeded the local safety limit.") }
                text[execution.id] = newText
                if newText.utf8.count - (checkpointBytes[execution.id] ?? 0) >= 4096 { try checkpoint(execution.id) }
                emit(.draft(execution.id, newText))
            case .toolCalls(let batch):
                let previousIDs = Set(request.messages.flatMap { $0.toolCalls ?? [] }.map(\.id))
                guard !sawCalls, !(request.tools ?? []).isEmpty, !batch.isEmpty, batch.count <= 32,
                      Set(batch.map(\.id)).count == batch.count,
                      batch.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 256 && !previousIDs.contains($0.id) && !$0.name.isEmpty && $0.name.utf8.count <= 128 && $0.arguments.utf8.count <= 65_536 }) else {
                    throw MiraError(.malformedStream, "Service returned tool calls with missing identities, duplicates, or excessive limits.")
                }
                sawCalls = true; calls = batch
            case .usage(let next):
                guard (next.inputTokens ?? 0) >= 0, (next.outputTokens ?? 0) >= 0,
                      (next.inputTokens ?? 0) <= 100_000_000, (next.outputTokens ?? 0) <= 100_000_000 else { throw MiraError(.malformedStream, "Service returned invalid usage.") }
                attemptUsage = next
                usage[execution.id] = priorSteps == 0 ? next : .init(
                    inputTokens: priorUsage.inputTokens.flatMap { old in next.inputTokens.map { old + $0 } },
                    outputTokens: priorUsage.outputTokens.flatMap { old in next.outputTokens.map { old + $0 } })
            case .finished(let reason): terminal = reason
            }
        }
        try Task.checkCancellation()
        guard let terminal else { throw MiraError(.malformedStream, "Connection ended early; the reply may be incomplete.") }
        guard (terminal == .toolCalls) == !calls.isEmpty else { throw MiraError(.malformedStream, "Tool calls do not match the model's stop reason.") }
        // A missing report in any attempt keeps the aggregate unknown, rather than reusing the last attempt's total.
        usage[execution.id] = priorSteps == 0 ? attemptUsage : .init(
            inputTokens: priorUsage.inputTokens.flatMap { old in attemptUsage.inputTokens.map { old + $0 } },
            outputTokens: priorUsage.outputTokens.flatMap { old in attemptUsage.outputTokens.map { old + $0 } })
        return .init(text: stepText, toolCalls: calls, finishReason: terminal)
    }

    private func validateDispatch(_ execution: Execution) throws {
        try store.validateMemoryUsage(executionID: execution.id, at: environment.now())
        try Task.checkCancellation()
        let configuration = try store.modelConfiguration()
        guard let current = try? configuration.snapshot(routeID: execution.route.id, purpose: execution.route.purpose, selection: execution.route.selectionSource), current == execution.route else { throw MiraError(.connectionChanged, "Model configuration changed. Send the request again.") }
        guard let conversation = try store.conversations(includeArchived: true).first(where: { $0.id == execution.conversationID }), !conversation.isArchived else {
            throw MiraError(.notFound, "Conversation is no longer available.")
        }
        if let workspaceID = conversation.workspaceID {
            guard let workspace = try store.workspaces().first(where: { $0.id == workspaceID }), workspace.allowsRemoteSend,
                  workspace.allowedConnectionIDs.map({ $0.contains(execution.route.connectionID) }) ?? true else {
                throw MiraError(.unauthorized, "This workspace no longer allows sending; execution stopped.")
            }
        }
    }

    private func runTools(_ invocations: [ToolInvocation], execution: Execution) async throws -> [ToolResult] {
        var results: [UUID: ToolResult] = [:], cursor = 0
        while cursor < invocations.count {
            if Task.isCancelled {
                for invocation in invocations[cursor...] {
                    let result = ToolResult(status: .cancelledBeforeDispatch, text: "Stopped; the tool was not executed.")
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
                    let result = ToolResult(status: .cancelledBeforeDispatch, text: "Stopped; the tool was not executed.")
                    try store.finishToolInvocation(invocation.id, result: result, at: environment.now()); results[invocation.id] = result
                }
            }
        }
        return try invocations.map {
            guard let result = results[$0.id] else { throw MiraError(.storage, "Tool results have not all been saved.") }
            return result
        }
    }

    private func performTool(_ invocation: ToolInvocation, execution: Execution) async -> ToolResult {
        guard !Task.isCancelled else { return .init(status: .cancelledBeforeDispatch, text: "Stopped; the tool was not executed.") }
        guard let tool = tools.tool(named: invocation.call.name) else { return .init(status: .notFound, text: "This execution did not provide that tool.") }
        let arguments: JSONValue
        do { arguments = try ToolSchemaValidator.decode(invocation.call.arguments, schema: tool.descriptor.definition.inputSchema) }
        catch { return .init(status: .invalidArguments, text: "Tool arguments do not match the declared structure or size limits.") }
        let context: ToolContext
        do {
            try validateDispatch(execution)
            let conversation = try store.conversations(includeArchived: true).first { $0.id == execution.conversationID }
            guard let trigger = try store.messages(in: execution.conversationID).first(where: { $0.id == execution.triggerMessageID }) else { throw MiraError(.notFound, "Original user request is unavailable.") }
            context = .init(executionID: execution.id, invocationID: invocation.id, workspaceID: conversation?.workspaceID, userMessageID: execution.triggerMessageID, userText: trigger.text)
        } catch { return .init(status: Task.isCancelled ? .cancelledBeforeDispatch : .denied, text: "Current authorization or connection changed; the tool was not executed.") }
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
                    guard value.utf8.count <= tool.descriptor.maxResultBytes else { return .init(status: .outputLimit, text: "Tool result exceeded its size limit; content was not sent.") }
                    return .init(status: .succeeded, text: value)
                } catch {
                    if error is CancellationError || Task.isCancelled { return .init(status: .cancelled, text: "Tool stopped; check the operation result.") }
                    if let error = error as? MiraError, error.code == .unauthorized || error.code == .connectionChanged { return .init(status: .denied, text: "Tool authorization check failed; execution was not authorized.") }
                    return .init(status: .failed, text: "Tool could not complete. Check and retry.")
                }
            }
            group.addTask {
                do { try await toolClock.sleep(for: tool.descriptor.timeout); try Task.checkCancellation(); return .init(status: .timedOut, text: "Tool exceeded its execution time limit; cancellation was requested.") }
                catch { return .init(status: .cancelled, text: "Tool stopped.") }
            }
            let first = await group.next() ?? .init(status: .cancelled, text: "Tool stopped.")
            group.cancelAll()
            return first
        }
        if result.status == .cancelled,
           (try? store.toolInvocations(for: execution.id).first(where: { $0.id == invocation.id })?.dispatchedAt) == nil {
            return .init(status: .cancelledBeforeDispatch, text: "Stopped; the tool was not executed.")
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
