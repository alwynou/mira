import Foundation

public struct AgentExecutionOptions: Sendable, Equatable {
    public let driverID: String
    public let driverRevision: Int
    public let instructions: String
    public let limits: AgentExecutionLimits
    public let priority: RuntimePriority
    public let route: AgentModelRoute?

    public init(driverID: String = "mira.default", driverRevision: Int = 1, instructions: String,
                limits: AgentExecutionLimits = .init(), priority: RuntimePriority = .foreground,
                route: AgentModelRoute?) {
        self.driverID = driverID; self.driverRevision = driverRevision; self.instructions = instructions
        self.limits = limits; self.priority = priority; self.route = route
    }

    func plan(runtimeID: UUID, generation: UInt64) throws -> AgentExecutionPlan {
        let value = AgentExecutionPlan(runtimeID: runtimeID, catalogGeneration: generation,
            driverID: driverID, driverRevision: driverRevision, instructions: instructions,
            limits: limits, priority: priority, route: route)
        try value.validate()
        return value
    }
}

public enum AgentTurnInput: Sendable, Equatable {
    case message(id: MessageID, text: String, timeZoneIdentifier: String)
    case retry(executionID: ExecutionID)
}

public struct AgentSessionOpening: Sendable, Equatable {
    public let title: String
    public let workspaceID: WorkspaceID?
    public init(title: String, workspaceID: WorkspaceID?) {
        self.title = title; self.workspaceID = workspaceID
    }
}

/// A selection change attached to admission is reduced in the same journal
/// batch as the first user message. The revision is the value observed by
/// the caller before it resolved the route.
public struct AgentSessionSelectionChange: Sendable, Equatable {
    public let selection: AgentSessionModelSelection
    public let expectedRevision: Int

    public init(selection: AgentSessionModelSelection, expectedRevision: Int) {
        self.selection = selection
        self.expectedRevision = expectedRevision
    }
}

/// A command identity must remain unchanged while the caller reconciles its result.
public struct AgentSubmitCommand: Sendable, Equatable {
    public let id: UUID
    public let sessionID: ConversationID
    public let executionID: ExecutionID
    public let input: AgentTurnInput
    public let options: AgentExecutionOptions
    public let opening: AgentSessionOpening?
    /// The session selection revision captured before route resolution.
    /// A default of zero keeps opening an unselected session convenient while
    /// admission still rejects it when the journal has advanced the revision.
    public let expectedSelectionRevision: Int
    public let selectionChange: AgentSessionSelectionChange?
    public init(id: UUID, sessionID: ConversationID, executionID: ExecutionID,
                input: AgentTurnInput, options: AgentExecutionOptions, opening: AgentSessionOpening? = nil,
                expectedSelectionRevision: Int = 0,
                selectionChange: AgentSessionSelectionChange? = nil) {
        self.id = id; self.sessionID = sessionID; self.executionID = executionID
        self.input = input; self.options = options; self.opening = opening
        self.expectedSelectionRevision = expectedSelectionRevision
        self.selectionChange = selectionChange
    }
}

public struct AgentExecutionAddress: Sendable, Hashable {
    public let sessionID: ConversationID
    public let executionID: ExecutionID
    public init(sessionID: ConversationID, executionID: ExecutionID) {
        self.sessionID = sessionID; self.executionID = executionID
    }
}

public enum AgentSessionChange: Sendable, Equatable {
    case open(title: String, workspaceID: WorkspaceID?)
    case setModelSelection(selection: AgentSessionModelSelection, expectedRevision: Int)
    case rename(title: String, expectedRevision: Int)
    case archive(expectedRevision: Int)
}

public enum AgentApplicationPhase: Sendable, Equatable { case recovering, ready, closing, closed }

public struct AgentApplicationShutdownReport: Sendable, Equatable {
    public let unresolvedCommands: [UUID: SessionCommitResult]
    public let unresolvedExecutions: [AgentExecutionAddress: SessionCommitResult]
    public let unresolvedSessions: [ConversationID: SessionObservation]
    public var isSettled: Bool {
        unresolvedCommands.isEmpty && unresolvedExecutions.isEmpty && unresolvedSessions.isEmpty
    }
}

/// Coalesced application state, not a replacement for durable session events.
public struct AgentApplicationSnapshot: Sendable, Equatable {
    public let phase: AgentApplicationPhase
    public let pendingAdmissions: Set<AgentExecutionAddress>
    public let pendingSessionCommands: Set<UUID>
    public let ownedExecutions: Set<AgentExecutionAddress>
    public let recoveryResults: [AgentExecutionAddress: SessionCommitResult]
    public let settlementFailures: [AgentExecutionAddress: SessionCommitResult]
    public let shutdownReport: AgentApplicationShutdownReport?
}

/// Owns admitted work independently of windows, observers, and caller task cancellation.
/// The composition owner opens the library first and closes its stores only after shutdown returns.
public actor AgentApplicationRuntime {
    public nonisolated let id: UUID
    private let journal: any SessionJournal
    private let libraryAccess: AgentLibraryAccess
    private let libraryLease: AgentLibraryAccessLease
    private let payloads: any SessionPayloadStore
    private let registry: RuntimeRegistry<AgentCapability>
    private let scope: RuntimeScope
    private var activation: RuntimeModuleActivation?
    private let policy: any AgentToolPolicy
    private let authority: any AgentEffectAuthority
    private let business: any AgentBusinessEffects
    private let authorizer: any AgentSourceAuthorizer
    private let approvals: RuntimeApprovalService
    private let scheduler: RuntimeScheduler
    private let environment: RuntimeEnvironment
    private let extensionSchemas: [String: Set<Int>]
    private let maximumOpenSessions: Int
    private let maximumPendingAdmissions: Int
    private var phase: AgentApplicationPhase = .recovering
    private var startupScanComplete = false
    private var sessions: [ConversationID: SessionRuntime] = [:]
    private var loads: [ConversationID: Task<SessionRuntime, any Error>] = [:]
    private var admissions: [UUID: Admission] = [:]
    private var changes: [UUID: Change] = [:]
    private var reservedSessions: [ConversationID: UUID] = [:]
    private var cancellationIntents: Set<AgentExecutionAddress> = []
    private var executions: [AgentExecutionAddress: Execution] = [:]
    private var observers: [UUID: AsyncStream<AgentApplicationSnapshot>.Continuation] = [:]
    private var shutdownTask: Task<AgentApplicationShutdownReport, Never>?
    private var shutdownReport: AgentApplicationShutdownReport?

    private enum CommandPhase { case running, uncertain }
    private struct Admission {
        let command: AgentSubmitCommand
        var phase: CommandPhase
        var task: Task<SessionCommitResult, Never>
        var catalog: AgentRuntimeCatalog?
    }
    private struct Change {
        let sessionID: ConversationID
        let value: AgentSessionChange
        var phase: CommandPhase
        var task: Task<SessionCommitResult, Never>
    }

    private enum Runner: Sendable {
        case kernel(AgentExecutionKernel)
        case recovery(AgentExecutionRecovery)
        func run() async -> SessionCommitResult {
            switch self { case .kernel(let value): await value.run(); case .recovery(let value): await value.settle() }
        }
        func retry() async -> SessionCommitResult {
            switch self { case .kernel(let value): await value.retrySettlement(); case .recovery(let value): await value.settle() }
        }
        func cancel() async { if case .kernel(let value) = self { await value.cancel() } }
        func shutdown() async -> SessionCommitResult {
            switch self { case .kernel(let value): await value.shutdown(); case .recovery(let value): await value.settle() }
        }
    }

    private struct Execution {
        let runner: Runner
        var task: Task<SessionCommitResult, Never>
        var operationID: UUID
        var isRunning: Bool
        var lastResult: SessionCommitResult?
        let startupRecovery: Bool
    }

    private init(id: UUID, journal: any SessionJournal, payloads: any SessionPayloadStore, libraryAccess: AgentLibraryAccess,
                 registry: RuntimeRegistry<AgentCapability>, scope: RuntimeScope, libraryLease: AgentLibraryAccessLease,
                 policy: any AgentToolPolicy, authority: any AgentEffectAuthority,
                 business: any AgentBusinessEffects, authorizer: any AgentSourceAuthorizer,
                 approvals: RuntimeApprovalService, scheduler: RuntimeScheduler, environment: RuntimeEnvironment,
                 maximumOpenSessions: Int, maximumPendingAdmissions: Int, extensionSchemas: [String: Set<Int>]) {
        self.id = id; self.journal = journal; self.payloads = payloads; self.registry = registry; self.scope = scope
        self.libraryAccess = libraryAccess; self.libraryLease = libraryLease
        self.policy = policy; self.authority = authority; self.business = business; self.authorizer = authorizer
        self.approvals = approvals; self.scheduler = scheduler; self.environment = environment
        self.maximumOpenSessions = maximumOpenSessions; self.maximumPendingAdmissions = maximumPendingAdmissions
        self.extensionSchemas = extensionSchemas
    }

    public static func open(journal: any SessionJournal, payloads: any SessionPayloadStore, libraryAccess: AgentLibraryAccess,
                            registry: RuntimeRegistry<AgentCapability>, modules: [any RuntimeModule],
                            policy: any AgentToolPolicy, authority: any AgentEffectAuthority,
                            business: any AgentBusinessEffects, authorizer: any AgentSourceAuthorizer,
                            approvals: RuntimeApprovalService, scheduler: RuntimeScheduler,
                            environment: RuntimeEnvironment = .init(), maximumOpenSessions: Int = 128,
                            maximumPendingAdmissions: Int = 64,
                            extensionSchemas: [String: Set<Int>] = [:]) async throws -> AgentApplicationRuntime {
        guard (1...4_096).contains(maximumOpenSessions), (1...1_024).contains(maximumPendingAdmissions) else {
            throw MiraError(.configuration, "The application runtime limits are invalid.")
        }
        try await libraryAccess.checkReady()
        let scope = RuntimeScope(kind: .application)
        let lease: AgentLibraryAccessLease
        do { lease = try await libraryAccess.acquire(in: scope) }
        catch { await scope.dispose(); throw error }
        let runtime = AgentApplicationRuntime(id: environment.uuid(), journal: journal, payloads: payloads, libraryAccess: libraryAccess,
            registry: registry, scope: scope, libraryLease: lease, policy: policy, authority: authority, business: business,
            authorizer: authorizer, approvals: approvals, scheduler: scheduler, environment: environment,
            maximumOpenSessions: maximumOpenSessions, maximumPendingAdmissions: maximumPendingAdmissions,
            extensionSchemas: extensionSchemas)
        do {
            let activation = try await RuntimeModuleHost(modules: modules).activate(in: scope)
            await runtime.setActivation(activation)
            try await runtime.recoverStartup()
            try await libraryAccess.checkReady()
            return runtime
        } catch {
            _ = await runtime.shutdown()
            throw error
        }
    }

    public func snapshot() -> AgentApplicationSnapshot {
        .init(phase: phase, pendingAdmissions: Set(admissions.values.map { Self.address($0.command) }),
              pendingSessionCommands: Set(changes.keys), ownedExecutions: Set(executions.keys),
              recoveryResults: executions.filter { $0.value.startupRecovery }.compactMapValues(\.lastResult),
              settlementFailures: executions.compactMapValues(\.lastResult), shutdownReport: shutdownReport)
    }

    public func observe() throws -> AsyncStream<AgentApplicationSnapshot> {
        guard observers.count < 256 else { throw MiraError(.busy, "The application observer limit was reached.") }
        let (stream, continuation) = AsyncStream<AgentApplicationSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(snapshot())
        guard phase != .closed else { continuation.finish(); return stream }
        let observerID = UUID()
        observers[observerID] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(observerID) } }
        return stream
    }

    public func sessionSnapshot(id: ConversationID) async throws -> SessionState {
        try await libraryLease.read { try await self.session(id).snapshot() }
    }
    /// Returns the journal-reduced selection. Configuration projections never
    /// participate in this read because they do not own session selection.
    public func modelSelection(sessionID: ConversationID) async throws -> AgentSessionModelSelection {
        try await sessionSnapshot(id: sessionID).modelSelection
    }
    public func observeSession(id: ConversationID) async throws -> AsyncStream<SessionObservation> {
        try await libraryLease.read { try await self.session(id).observations() }
    }
    /// Lossy visible output only. Durable observations and queries remain the recovery authority.
    public func observeSessionOutput(id: ConversationID) async throws -> AsyncStream<SessionOutputObservation> {
        try await libraryLease.read { try await self.session(id).outputObservations() }
    }
    public func readSession(id: ConversationID, after sequence: Int64, limit: Int = 128) async throws -> [SessionBatch] {
        try requireOpen()
        return try await libraryLease.read { [journal] in
            try await journal.read(sessionID: id, after: sequence, limit: limit)
        }
    }

    public func createSession(id: ConversationID, commandID: UUID,
                              title: String, workspaceID: WorkspaceID?) async -> SessionCommitResult {
        await changeSession(id: id, commandID: commandID, change: .open(title: title, workspaceID: workspaceID))
    }

    public func selectModel(sessionID: ConversationID, commandID: UUID,
                            expectedRevision: Int,
                            selection: AgentSessionModelSelection) async -> SessionCommitResult {
        await changeSession(id: sessionID, commandID: commandID,
                            change: .setModelSelection(selection: selection, expectedRevision: expectedRevision))
    }

    public func changeSession(id: ConversationID, commandID: UUID,
                              change: AgentSessionChange) async -> SessionCommitResult {
        if let pending = changes[commandID] {
            guard pending.sessionID == id, pending.value == change else { return .notCommitted(Self.commandConflict()) }
            return await pending.task.value
        }
        do {
            try Task.checkCancellation(); try await requireReady()
            try reserve(sessionID: id, commandID: commandID)
            let task = Task { await self.applyChange(id, commandID: commandID, change: change) }
            changes[commandID] = .init(sessionID: id, value: change, phase: .running, task: task)
            publish()
            return await task.value
        } catch { return .notCommitted(Self.safe(error)) }
    }

    public func reconcileSessionCommand(commandID: UUID) async -> SessionCommitResult {
        guard let pending = changes[commandID] else {
            return .notCommitted(.init(.notFound, "There is no pending session command."))
        }
        if pending.phase == .running { return await pending.task.value }
        guard phase != .closing, phase != .closed else { return .notCommitted(Self.closed()) }
        let task = Task { await self.resolveChange(pending.sessionID, commandID: commandID) }
        changes[commandID]?.phase = .running; changes[commandID]?.task = task
        return await task.value
    }

    public func submit(_ command: AgentSubmitCommand) async -> SessionCommitResult {
        if let pending = admissions[command.id] {
            guard pending.command == command else { return .notCommitted(Self.commandConflict()) }
            return await pending.task.value
        }
        do {
            guard command.expectedSelectionRevision >= 0,
                  command.selectionChange == nil || command.expectedSelectionRevision < Int.max else {
                throw Self.commandConflict()
            }
            try Task.checkCancellation(); try await requireReady()
            try reserve(sessionID: command.sessionID, commandID: command.id)
            let task = Task { await self.admit(command) }
            admissions[command.id] = .init(command: command, phase: .running, task: task, catalog: nil)
            publish()
            // Once reserved, admission belongs to the application, even if a view task disappears.
            return await task.value
        } catch { return .notCommitted(Self.safe(error)) }
    }

    public func reconcileAdmission(commandID: UUID) async -> SessionCommitResult {
        guard let pending = admissions[commandID] else {
            return .notCommitted(.init(.notFound, "There is no pending execution admission."))
        }
        if pending.phase == .running { return await pending.task.value }
        guard phase != .closing, phase != .closed else { return .notCommitted(Self.closed()) }
        let task = Task { await self.resolveAdmission(pending.command) }
        admissions[commandID]?.phase = .running; admissions[commandID]?.task = task
        return await task.value
    }

    public func cancel(sessionID: ConversationID) async {
        if let commandID = reservedSessions[sessionID], let admission = admissions[commandID] {
            cancellationIntents.insert(Self.address(admission.command))
        }
        guard let runtime = sessions[sessionID], let executionID = await runtime.snapshot().activeExecutionID else { return }
        await runtime.requestCancellation(executionID: executionID)
        await executions[.init(sessionID: sessionID, executionID: executionID)]?.runner.cancel()
    }

    public func waitForExecution(id executionID: ExecutionID, sessionID: ConversationID) async -> SessionCommitResult {
        if let execution = executions[.init(sessionID: sessionID, executionID: executionID)] { return await execution.task.value }
        do {
            let state = try await session(sessionID).snapshot()
            guard state.executions[executionID]?.completion != nil else {
                throw MiraError(.notFound, "The execution has no owned task or durable completion.")
            }
            return .committed(.init(sessionID: sessionID, sequence: state.sequence))
        } catch { return .notCommitted(Self.safe(error)) }
    }

    /// Retries only the original settlement. It never runs the driver again.
    public func retrySettlement(executionID: ExecutionID, sessionID: ConversationID) async -> SessionCommitResult {
        let address = AgentExecutionAddress(sessionID: sessionID, executionID: executionID)
        guard let execution = executions[address] else {
            return await waitForExecution(id: executionID, sessionID: sessionID)
        }
        if execution.isRunning { return await execution.task.value }
        guard phase != .closing, phase != .closed else { return .notCommitted(Self.closed()) }
        let operationID = UUID()
        let task = Task {
            let result = await execution.runner.retry()
            self.finished(address, operationID: operationID, result: result)
            return result
        }
        executions[address]?.task = task; executions[address]?.operationID = operationID
        executions[address]?.isRunning = true; executions[address]?.lastResult = nil
        publish()
        return await task.value
    }

    /// Only inactive sessions may be released. Executions remain application-owned when a window closes.
    public func releaseSession(id: ConversationID) async throws {
        try requireOpen(); try requireReleasable(id)
        guard let runtime = sessions[id] else { return }
        let state = await runtime.snapshot()
        try requireOpen(); try requireReleasable(id)
        guard state.activeExecutionID == nil, sessions[id] === runtime else {
            throw MiraError(.busy, "The session still owns application work.")
        }
        sessions.removeValue(forKey: id)
        await runtime.close()
    }

    @discardableResult
    public func shutdown() async -> AgentApplicationShutdownReport {
        if let shutdownTask { return await shutdownTask.value }
        phase = .closing; publish()
        let task = Task { await self.drain() }
        shutdownTask = task
        return await task.value
    }

    private func setActivation(_ value: RuntimeModuleActivation) { activation = value }

    private func session(_ id: ConversationID) async throws -> SessionRuntime {
        try requireOpen()
        if let value = sessions[id] { return value }
        if let task = loads[id] { return try await task.value }
        guard sessions.count + loads.count < maximumOpenSessions else {
            throw MiraError(.busy, "The open session limit was reached.")
        }
        let task = Task {
            do {
                let value = try await SessionRuntime.open(id: id, journal: journal, payloads: payloads,
                    environment: environment, extensionSchemas: extensionSchemas)
                loads.removeValue(forKey: id)
                guard phase != .closing, phase != .closed else {
                    await value.close(); throw Self.closed()
                }
                sessions[id] = value
                return value
            } catch { loads.removeValue(forKey: id); throw error }
        }
        loads[id] = task
        return try await task.value
    }

    private func reserve(sessionID: ConversationID, commandID: UUID) throws {
        guard admissions[commandID] == nil, changes[commandID] == nil else { throw Self.commandConflict() }
        guard admissions.count + changes.count < maximumPendingAdmissions, reservedSessions[sessionID] == nil else {
            throw MiraError(.busy, "The session already has a pending command or the runtime is full.")
        }
        reservedSessions[sessionID] = commandID
    }

    private func applyChange(_ sessionID: ConversationID, commandID: UUID, change: AgentSessionChange) async -> SessionCommitResult {
        do {
            let runtime = try await session(sessionID)
            try await requireReady()
            if let batch = try await journal.batch(id: commandID, sessionID: sessionID) {
                try await validateChange(change, batch: batch)
                return acceptChange(sessionID, commandID: commandID, result: .committed(batch.cursor))
            }
            let result = await runtime.commit(id: commandID) { context in
                switch change {
                case .open(let title, let workspaceID):
                    try Self.validateTitle(title)
                    guard context.state.header == nil else { throw MiraError(.conflict, "The session is already open.") }
                    let reference = try await context.stageBytes(Data(title.utf8), kind: .title, retentionGroup: UUID())
                    return [.opened(.init(workspaceID: workspaceID, title: reference))]
                case .setModelSelection(let selection, let expectedRevision):
                    try selection.validate()
                    return [.modelSelectionChanged(selection: selection, expectedRevision: expectedRevision)]
                case .rename(let title, let revision):
                    try Self.validateTitle(title); try Self.validateRevision(revision, state: context.state)
                    let reference = try await context.stageBytes(Data(title.utf8), kind: .title, retentionGroup: UUID())
                    return [.renamed(title: reference, revision: revision + 1)]
                case .archive(let revision):
                    try Self.validateRevision(revision, state: context.state)
                    return [.archived(revision: revision + 1)]
                }
            }
            return acceptChange(sessionID, commandID: commandID, result: result)
        } catch { return acceptChange(sessionID, commandID: commandID, result: .notCommitted(Self.safe(error))) }
    }

    private func validateChange(_ change: AgentSessionChange, batch: SessionBatch) async throws {
        guard batch.events.count == 1, let fact = batch.events.first?.fact else { throw Self.commandConflict() }
        switch (change, fact) {
        case (.open(let title, let workspaceID), .opened(let value)):
            guard workspaceID == value.workspaceID, try await payloads.read(value.title) == Data(title.utf8) else {
                throw Self.commandConflict()
            }
        case (.setModelSelection(let selection, let expectedRevision),
              .modelSelectionChanged(selection: let stored, expectedRevision: let storedRevision)):
            guard expectedRevision == storedRevision, selection == stored else { throw Self.commandConflict() }
        case (.rename(let title, let revision), .renamed(let reference, let next)):
            guard revision > 0, revision < Int.max, next == revision + 1,
                  try await payloads.read(reference) == Data(title.utf8) else { throw Self.commandConflict() }
        case (.archive(let revision), .archived(let next)):
            guard revision > 0, revision < Int.max, next == revision + 1 else { throw Self.commandConflict() }
        default: throw Self.commandConflict()
        }
    }

    private func resolveChange(_ sessionID: ConversationID, commandID: UUID) async -> SessionCommitResult {
        guard let runtime = sessions[sessionID] else { return .notCommitted(Self.closed()) }
        return acceptChange(sessionID, commandID: commandID, result: await runtime.reconcile())
    }

    private func acceptChange(_ sessionID: ConversationID, commandID: UUID, result: SessionCommitResult) -> SessionCommitResult {
        if case .indeterminate(let batchID, _) = result, batchID != commandID {
            changes.removeValue(forKey: commandID); reservedSessions.removeValue(forKey: sessionID)
            publish()
            return .notCommitted(Self.previousCommandPending())
        }
        if case .indeterminate = result { changes[commandID]?.phase = .uncertain }
        else { changes.removeValue(forKey: commandID); reservedSessions.removeValue(forKey: sessionID) }
        publish()
        return result
    }

    private func admit(_ command: AgentSubmitCommand) async -> SessionCommitResult {
        do {
            let runtime = try await session(command.sessionID)
            try await requireReady()
            if let existing = try await journal.batch(id: command.id, sessionID: command.sessionID) {
                try await validateAdmission(command, batch: existing)
                await releaseAdmission(command.id)
                return .committed(existing.cursor)
            }
            let state = await runtime.snapshot()
            guard (state.header == nil) == (command.opening != nil), !state.isArchived, state.activeExecutionID == nil else {
                throw MiraError(.busy, "The session cannot admit new work in its current state.")
            }
            guard command.expectedSelectionRevision >= 0,
                  command.expectedSelectionRevision == state.modelSelectionRevision else {
                throw MiraError(.conflict, "The session model selection changed while the message was prepared.")
            }
            if let selectionChange = command.selectionChange {
                guard selectionChange.expectedRevision == state.modelSelectionRevision else {
                    throw MiraError(.conflict, "The session model selection changed while the message was prepared.")
                }
                try selectionChange.selection.validate()
            }
            if let opening = command.opening { try Self.validateTitle(opening.title) }
            let snapshot = try await registry.freeze()
            let catalog: AgentRuntimeCatalog
            do { catalog = try AgentRuntimeCatalog(snapshot: snapshot) }
            catch { await snapshot.release(); throw error }
            admissions[command.id]?.catalog = catalog
            let plan = try command.options.plan(runtimeID: id, generation: catalog.generation)
            _ = try catalog.driver(id: plan.driverID, revision: plan.driverRevision)
            if let route = plan.route { _ = try catalog.model(identity: route.adapter) }
            try await requireReady()
            let result = await runtime.commit(id: command.id) { context in
                var facts: [SessionFact] = []
                var retryCleanupGroups: Set<UUID> = []
                if let opening = command.opening {
                    guard context.state.header == nil else { throw MiraError(.conflict, "The session is already open.") }
                    let title = try await context.stageBytes(Data(opening.title.utf8), kind: .title, retentionGroup: UUID())
                    facts.append(.opened(.init(workspaceID: opening.workspaceID, title: title)))
                }
                if let selectionChange = command.selectionChange {
                    guard selectionChange.expectedRevision == context.state.modelSelectionRevision else {
                        throw MiraError(.conflict, "The session model selection changed while the message was prepared.")
                    }
                    facts.append(.modelSelectionChanged(selection: selectionChange.selection,
                                                        expectedRevision: selectionChange.expectedRevision))
                }
                let messageID: MessageID
                let body: SessionPayloadReference?
                let retryID: ExecutionID?
                let zone: String
                switch command.input {
                case .message(let id, let text, let timeZone):
                    guard !text.isEmpty, text.utf8.count <= 2_097_152 else {
                        throw MiraError(.invalidInput, "The user message is empty or exceeds its supported bounds.")
                    }
                    messageID = id; retryID = nil; zone = timeZone
                    body = try await context.stageBytes(Data(text.utf8), kind: .userText, retentionGroup: UUID())
                case .retry(let previousID):
                    guard let previous = context.state.executions[previousID] else {
                        throw MiraError(.notFound, "The previous execution is unavailable.")
                    }
                    messageID = previous.admission.userMessageID; retryID = previousID
                    zone = previous.admission.timeZoneIdentifier; body = nil
                    retryCleanupGroups = context.state.retryCleanupGroups(forUserMessageID: previous.admission.userMessageID)
                }
                let effectiveSelection = command.selectionChange?.selection ?? context.state.modelSelection
                if case .selected(let selected) = effectiveSelection, let route = plan.route {
                    guard route.id == selected.routeID, route.modelDescriptorID == selected.modelConfigurationID,
                          route.connectionID == selected.model.connectionID, route.modelID == selected.model.modelID else {
                        throw MiraError(.conflict, "The execution route does not match the recorded session model selection.")
                    }
                }
                let reference = try await context.stage(plan, kind: .executionPlan, retentionGroup: UUID())
                let selectionRevision = context.state.modelSelectionRevision + (command.selectionChange == nil ? 0 : 1)
                guard selectionRevision == command.expectedSelectionRevision + (command.selectionChange == nil ? 0 : 1) else {
                    throw MiraError(.conflict, "The session model selection changed while the message was prepared.")
                }
                facts.append(.admitted(.init(executionID: command.executionID, userMessageID: messageID,
                    retryOfExecutionID: retryID, userBody: body, plan: reference, hasModelRoute: plan.route != nil,
                    authorizationEpoch: context.state.authorizationEpoch, timeZoneIdentifier: zone,
                    modelSelectionRevision: selectionRevision)))
                if let retryID {
                    facts.append(.retryCleared(.init(sourceExecutionID: retryID,
                        retryExecutionID: command.executionID, retentionGroups: retryCleanupGroups)))
                }
                return facts
            }
            return await acceptAdmission(command, runtime: runtime, result: result)
        } catch {
            await releaseAdmission(command.id)
            return .notCommitted(Self.safe(error))
        }
    }

    private func validateAdmission(_ command: AgentSubmitCommand, batch: SessionBatch) async throws {
        let prefixCount = (command.opening == nil ? 0 : 1) + (command.selectionChange == nil ? 0 : 1)
        let cleanupCount: Int
        switch command.input {
        case .message: cleanupCount = 0
        case .retry: cleanupCount = 1
        }
        let expectedEventCount = 1 + prefixCount + cleanupCount
        guard batch.events.count == expectedEventCount,
              case .admitted(let admission) = batch.events[prefixCount].fact,
              admission.executionID == command.executionID,
              admission.modelSelectionRevision == command.expectedSelectionRevision + (command.selectionChange == nil ? 0 : 1) else {
            throw Self.commandConflict()
        }
        var eventIndex = 0
        if let opening = command.opening {
            guard case .opened(let header) = batch.events[eventIndex].fact, header.workspaceID == opening.workspaceID,
                  try await payloads.read(header.title) == Data(opening.title.utf8) else { throw Self.commandConflict() }
            eventIndex += 1
        }
        if let selectionChange = command.selectionChange {
            guard case .modelSelectionChanged(selection: let selection, expectedRevision: let expectedRevision) = batch.events[eventIndex].fact,
                  selection == selectionChange.selection, expectedRevision == selectionChange.expectedRevision else {
                throw Self.commandConflict()
            }
        }
        let plan = try await AgentExecutionPlan.read(for: admission, from: payloads)
        let expected = try command.options.plan(runtimeID: plan.runtimeID, generation: plan.catalogGeneration)
        guard plan == expected else { throw Self.commandConflict() }
        switch command.input {
        case .message(let id, let text, let zone):
            guard admission.retryOfExecutionID == nil, admission.userMessageID == id,
                  admission.timeZoneIdentifier == zone, let reference = admission.userBody,
                  try await payloads.read(reference) == Data(text.utf8) else { throw Self.commandConflict() }
        case .retry(let id):
            guard admission.retryOfExecutionID == id, admission.userBody == nil else { throw Self.commandConflict() }
            guard case .retryCleared(let cleanup) = batch.events[prefixCount + 1].fact,
                  cleanup.sourceExecutionID == id, cleanup.retryExecutionID == command.executionID else {
                throw Self.commandConflict()
            }
        }
    }

    private func resolveAdmission(_ command: AgentSubmitCommand) async -> SessionCommitResult {
        guard let runtime = sessions[command.sessionID] else {
            return .notCommitted(.init(.notFound, "The pending admission session is unavailable."))
        }
        return await acceptAdmission(command, runtime: runtime, result: await runtime.reconcile())
    }

    private func acceptAdmission(_ command: AgentSubmitCommand, runtime: SessionRuntime,
                                 result: SessionCommitResult) async -> SessionCommitResult {
        switch result {
        case .indeterminate(let batchID, _):
            guard batchID == command.id else {
                await releaseAdmission(command.id)
                return .notCommitted(Self.previousCommandPending())
            }
            admissions[command.id]?.phase = .uncertain; publish()
        case .notCommitted:
            await releaseAdmission(command.id)
        case .committed:
            guard let catalog = admissions[command.id]?.catalog,
                  await runtime.snapshot().executions[command.executionID] != nil else {
                await releaseAdmission(command.id)
                return .notCommitted(.init(.storage, "The reconciled execution admission is unavailable."))
            }
            if cancellationIntents.contains(Self.address(command)) || phase == .closing {
                await runtime.requestCancellation(executionID: command.executionID)
            }
            var libraryLease: AgentLibraryAccessLease?
            do {
                let lease = try await libraryAccess.acquire(in: scope)
                libraryLease = lease
                let kernel = try await AgentExecutionKernel(runtime: runtime, journal: journal, payloads: payloads,
                    libraryLease: lease, executionID: command.executionID, runtimeID: id, catalog: catalog, policy: policy,
                    authority: authority, business: business, authorizer: authorizer,
                    approvals: approvals, scheduler: scheduler, environment: environment)
                admissions[command.id]?.catalog = nil
                launch(.kernel(kernel), address: Self.address(command), startup: false)
            } catch {
                await libraryLease?.release()
                await catalog.release(); admissions[command.id]?.catalog = nil
                launch(recovery(runtime, executionID: command.executionID, error: Self.safe(error)),
                       address: Self.address(command), startup: false)
            }
            await releaseAdmission(command.id)
        }
        return result
    }

    private func releaseAdmission(_ commandID: UUID) async {
        guard let pending = admissions.removeValue(forKey: commandID) else { return }
        reservedSessions.removeValue(forKey: pending.command.sessionID)
        cancellationIntents.remove(Self.address(pending.command))
        publish()
        await pending.catalog?.release()
    }

    private func recovery(_ runtime: SessionRuntime, executionID: ExecutionID, error: MiraError? = nil) -> Runner {
        .recovery(AgentExecutionRecovery(runtime: runtime, journal: journal, payloads: payloads,
            executionID: executionID, business: business, authorizer: authorizer, error: error, environment: environment))
    }

    private func launch(_ runner: Runner, address: AgentExecutionAddress, startup: Bool) {
        let operationID = UUID()
        let task = Task {
            let result = await runner.run()
            self.finished(address, operationID: operationID, result: result)
            return result
        }
        executions[address] = .init(runner: runner, task: task, operationID: operationID,
                                    isRunning: true, lastResult: nil, startupRecovery: startup)
        publish()
    }

    private func finished(_ address: AgentExecutionAddress, operationID: UUID, result: SessionCommitResult) {
        guard executions[address]?.operationID == operationID else { return }
        if case .committed = result { executions.removeValue(forKey: address) }
        else { executions[address]?.isRunning = false; executions[address]?.lastResult = result }
        if phase == .recovering, startupScanComplete, !executions.values.contains(where: \.startupRecovery) { phase = .ready }
        publish()
    }

    private func recoverStartup() async throws {
        let reader = JournalSessionReader(journal: journal, payloads: payloads, extensionSchemas: extensionSchemas)
        var cursor: ConversationID?
        while true {
            let ids = try await journal.sessions(after: cursor, limit: 128)
            if ids.isEmpty { break }
            for sessionID in ids {
                let summary = try await reader.recoverySummary(sessionID: sessionID)
                guard summary.activeExecutionID != nil else { continue }
                let runtime = try await session(sessionID)
                let state = await runtime.snapshot()
                if !state.erasedRetentionGroups.isEmpty {
                    try await payloads.purge(sessionID: sessionID, retentionGroups: state.erasedRetentionGroups)
                }
                if let executionID = state.activeExecutionID {
                    let address = AgentExecutionAddress(sessionID: sessionID, executionID: executionID)
                    launch(recovery(runtime, executionID: executionID), address: address, startup: true)
                    _ = await executions[address]?.task.value
                }
                if await runtime.snapshot().activeExecutionID == nil {
                    sessions.removeValue(forKey: sessionID); await runtime.close()
                }
            }
            cursor = ids.last
        }
        startupScanComplete = true
        phase = executions.values.contains(where: \.startupRecovery) ? .recovering : .ready
        publish()
    }

    private func drain() async -> AgentApplicationShutdownReport {
        var unresolvedCommands: [UUID: SessionCommitResult] = [:]
        var unresolvedExecutions: [AgentExecutionAddress: SessionCommitResult] = [:]
        var unresolvedSessions: [ConversationID: SessionObservation] = [:]
        for pending in admissions.values { cancellationIntents.insert(Self.address(pending.command)) }
        for execution in Array(executions.values) { await execution.runner.cancel() }
        for pending in Array(admissions.values) { _ = await pending.task.value }
        for pending in Array(changes.values) { _ = await pending.task.value }
        for (commandID, pending) in Array(changes) {
            let result = await resolveChange(pending.sessionID, commandID: commandID)
            if case .indeterminate = result { unresolvedCommands[commandID] = result }
        }
        for pending in Array(admissions.values) {
            let result = await resolveAdmission(pending.command)
            if case .indeterminate = result { unresolvedCommands[pending.command.id] = result }
            await releaseAdmission(pending.command.id)
        }
        for (address, execution) in Array(executions) {
            _ = await execution.task.value
            let result = await execution.runner.shutdown()
            if case .committed = result {} else { unresolvedExecutions[address] = result }
        }
        executions.removeAll(); changes.removeAll(); reservedSessions.removeAll()
        for task in Array(loads.values) { if let runtime = try? await task.value { await runtime.close() } }
        loads.removeAll()
        for (sessionID, runtime) in Array(sessions) {
            let observation = await runtime.currentObservation()
            if observation.requiresReconciliation || observation.activeExecutionID != nil { unresolvedSessions[sessionID] = observation }
            await runtime.close()
        }
        sessions.removeAll()
        await scheduler.shutdown()
        await approvals.shutdown()
        await activation?.dispose()
        await libraryLease.release()
        await scope.dispose()
        let report = AgentApplicationShutdownReport(unresolvedCommands: unresolvedCommands,
            unresolvedExecutions: unresolvedExecutions, unresolvedSessions: unresolvedSessions)
        shutdownReport = report; phase = .closed; publish()
        for continuation in observers.values { continuation.finish() }
        observers.removeAll()
        return report
    }

    private func requireOpen() throws {
        guard phase != .closing, phase != .closed else { throw Self.closed() }
    }
    private func requireReady() async throws {
        try await libraryAccess.checkReady()
        guard phase == .ready else { throw MiraError(.busy, "The application runtime is not ready to admit work.") }
    }
    private func requireReleasable(_ id: ConversationID) throws {
        guard reservedSessions[id] == nil, !executions.keys.contains(where: { $0.sessionID == id }), loads[id] == nil else {
            throw MiraError(.busy, "The session still owns application work.")
        }
    }
    private func publish() { let value = snapshot(); for continuation in observers.values { continuation.yield(value) } }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private static func validateTitle(_ title: String) throws {
        guard !title.isEmpty, title.utf8.count <= 4_096 else { throw MiraError(.invalidInput, "The session title is invalid.") }
    }
    private static func validateRevision(_ revision: Int, state: SessionState) throws {
        guard revision > 0, revision < Int.max, revision == state.revision else { throw MiraError(.conflict, "The session revision is stale.") }
    }
    private static func address(_ command: AgentSubmitCommand) -> AgentExecutionAddress {
        .init(sessionID: command.sessionID, executionID: command.executionID)
    }
    private static func commandConflict() -> MiraError { .init(.conflict, "The command identity belongs to another request.") }
    private static func previousCommandPending() -> MiraError { .init(.busy, "A previous session command requires reconciliation.") }
    private static func closed() -> MiraError { .init(.interrupted, "The application runtime is closed.") }
    private static func safe(_ error: any Error) -> MiraError {
        if let error = error as? MiraError { return error }
        if error is CancellationError { return .init(.cancelled, "The execution was cancelled.") }
        return .init(.storage, "The application runtime operation failed.")
    }
}
