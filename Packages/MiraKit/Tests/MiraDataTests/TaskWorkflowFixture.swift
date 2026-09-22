import Foundation
import GRDB
import Testing
@testable import MiraCore
@testable import MiraData

struct TaskWorkflowFixture: Sendable {
    let directory: URL
    let database: DatabaseQueue
    let library: FileSessionLibrary
    let authority: SQLiteLibraryAuthority
    let access: AgentLibraryAccess
    let scope: RuntimeScope
    let workspaces: SQLiteWorkspaceStore
    let settings: SQLiteAgentModelSettings
    let store: SQLiteTaskStore
    let memory: SQLiteMemoryStore?
    let knowledge: SQLiteKnowledgeStore?
    let business: SQLiteBusinessEffects
    let tasks: TaskApplication
    let reminders: ReminderScheduler
    let notifications: TaskNotificationFixture
    let runtime: AgentApplicationRuntime
    let scheduler: RuntimeScheduler
    let route: AgentModelRoute
    let model: TaskModelFixture
    let contextPolicy: SQLiteAgentContextPolicy
    let sourceAuthorities: RuntimeRegistry<any AgentDomainSourceAuthority>
    let authorizer: JournalAgentSourceAuthorizer
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    func run(_ text: String, sessionID: ConversationID = .init(), messageID: MessageID = .init(),
             workspaceID: WorkspaceID? = nil, timeZone: String = "Asia/Shanghai", expectedStatus: ExecutionStatus = .completed,
             instructions: String = "Use the available task tools.") async throws -> AgentExecutionAddress {
        let executionID = ExecutionID()
        let opening: AgentSessionOpening? = try await runtime.sessionSnapshot(id: sessionID).header == nil
            ? .init(title: "Synthetic task workflow", workspaceID: workspaceID) : nil
        let command = AgentSubmitCommand(id: UUID(), sessionID: sessionID, executionID: executionID,
            input: .message(id: messageID, text: text, timeZoneIdentifier: timeZone),
            options: .init(instructions: instructions, route: route),
            opening: opening)
        try taskRequireCommitted(await runtime.submit(command))
        try taskRequireCommitted(await runtime.waitForExecution(id: executionID, sessionID: sessionID))
        let state = try await runtime.sessionSnapshot(id: sessionID)
        #expect(state.executions[executionID]?.completion?.status == expectedStatus)
        return .init(sessionID: sessionID, executionID: executionID)
    }

    func evidence(_ address: AgentExecutionAddress) async throws -> SessionUserEvidence {
        let lease = try await access.acquire(in: scope)
        do {
            let result = try await lease.read {
                try await JournalSessionReader(journal: library, payloads: library)
                    .userEvidence(sessionID: address.sessionID, executionID: address.executionID)
            }
            await lease.release(); return result
        } catch { await lease.release(); throw error }
    }

    func save(id: MiraTaskID = .init(), workspaceID: WorkspaceID? = nil, draft: TaskDraft,
              status: MiraTaskStatus = .open, expectedRevision: Int? = nil, operationID: UUID = UUID()) async throws -> MiraTask {
        try await tasks.save(id: id, workspaceID: workspaceID, draft: draft, status: status,
                             expectedRevision: expectedRevision, operationID: operationID)
    }


}

func withTaskWorkflow(outputs: [[AgentModelStreamEvent]] = [], permission: NotificationPermission = .allowed, memoryEnabled: Bool = false,
                      knowledgeEnabled: Bool = false, environment: RuntimeEnvironment? = nil,
                      thinkingEnabled: Bool = false,
                      _ body: (TaskWorkflowFixture) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-task-workflow-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = Configuration()
    config.foreignKeysEnabled = true
    config.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
    let database = try DatabaseQueue(path: directory.appendingPathComponent("business.sqlite").path, configuration: config)
    defer { try? database.close() }
    let library = try FileSessionLibrary(directory: directory.appendingPathComponent("sessions"))
    var authority: SQLiteLibraryAuthority?
    var access: AgentLibraryAccess?
    var workspaces: SQLiteWorkspaceStore?
    var store: SQLiteTaskStore?
    var memory: SQLiteMemoryStore?
    var knowledge: SQLiteKnowledgeStore?
    var settings: SQLiteAgentModelSettings?
    var business: SQLiteBusinessEffects?
    var contextPolicy: SQLiteAgentContextPolicy?
    var runtime: AgentApplicationRuntime?
    var tasks: TaskApplication?
    var reminders: ReminderScheduler?
    var modelFixture: TaskModelFixture?
    let scheduler = RuntimeScheduler(), scope = RuntimeScope(kind: .application)
    let notifications = TaskNotificationFixture(permission: permission)
    do {
        let a = try SQLiteLibraryAuthority(database: database, validators: [SQLiteMemoryStore.maintenanceValidator,
            .init(identity: .init(namespace: "privacy.fixture", revision: 1), validate: { request, _ in try request.validate() })]
            + SQLiteKnowledgeStore.maintenanceValidators); authority = a
        let gate = try await AgentLibraryAccess.open(store: a); access = gate
        let w = try SQLiteWorkspaceStore(database: database, libraryID: a.libraryID); workspaces = w
        let t = try SQLiteTaskStore(database: database, libraryID: a.libraryID); store = t
        if memoryEnabled { memory = try SQLiteMemoryStore(database: database, libraryID: a.libraryID) }
        if knowledgeEnabled {
            knowledge = try SQLiteKnowledgeStore(database: database, libraryID: a.libraryID,
                                                 directory: directory.appendingPathComponent("knowledge"))
        }
        let s = try SQLiteAgentModelSettings(database: database, libraryID: a.libraryID); settings = s
        let configuration = AgentConfigurationValue(schema: .init(id: "task.fixture", revision: 1), value: .object([:]))
        let connection = AgentConfiguredConnection(id: .init(), revision: 1, configurationRevision: 1, name: "Synthetic tasks", isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: configuration, credential: nil)], discovery: nil, defaultInvocation: nil)
        var capabilities: [String: CapabilityState] = [
            AgentModelCapabilityID.streamingText: .declared,
            AgentModelCapabilityID.toolCalls: .declared,
            AgentModelCapabilityID.jsonOutput: .declared
        ]
        if thinkingEnabled { capabilities[AgentModelCapabilityID.thinking] = .declared }
        let model = AgentConfiguredModel(id: .init(), revision: 1, authorizationRevision: 1, reference: .init(connectionID: connection.id, modelID: "fixture"), displayName: nil, isEnabled: true, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: .init(id: "task.fixture", revision: 1), endpointID: "primary", contextWindow: 32768, maximumOutputTokens: nil, capabilities: capabilities, configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: modelParameterSchema)], facts: [])
        let preset = AgentRoutePreset(id: RouteID(model.id.rawValue), revision: 1, name: "Task fixture", modelDescriptorID: model.id, invocationID: "default", maximumOutputTokens: 1024, configuration: configuration)
        try await s.saveConnection(connection, expectedRevision: nil, authorization: a.authorization())
        try await s.savePoolModel(model, preset: preset, expectedModelRevision: nil, expectedPresetRevision: nil, authorization: a.authorization())
        let route = try await s.candidate(routeID: preset.id).freeze(configuration: .object([:]))
        let handler = SQLiteTaskCommandHandler(now: { TaskWorkflowFixture.now })
        let b = try SQLiteBusinessEffects(database: database, libraryID: a.libraryID,
            resolver: JournalAgentEffectResolver(journal: library, payloads: library),
            handlers: memoryEnabled ? [handler, SQLiteMemoryRememberHandler(now: { TaskWorkflowFixture.now }), SQLiteMemoryRetractHandler(now: { TaskWorkflowFixture.now })] : [handler],
            validator: TaskWorkflowValidator(memoryEnabled: memoryEnabled, knowledgeEnabled: knowledgeEnabled))
        business = b
        let taskApplication = TaskApplication(store: t, reader: .init(journal: library, payloads: library),
            access: gate, scope: scope, now: { TaskWorkflowFixture.now }); tasks = taskApplication
        let reminderScheduler = ReminderScheduler(store: t, notifications: notifications, namespace: "workflow",
            access: gate, scope: scope, now: { TaskWorkflowFixture.now }); reminders = reminderScheduler
        let probe = TaskModelFixture(outputs: outputs), registry = RuntimeRegistry<AgentCapability>()
        modelFixture = probe
        let domains = RuntimeRegistry<any AgentDomainSourceAuthority>()
        let policy = try SQLiteAgentContextPolicy(database: database, libraryID: a.libraryID); contextPolicy = policy
        let authorizer = JournalAgentSourceAuthorizer(reader: .init(journal: library, payloads: library), policy: policy, domains: domains)
        var modules: [any RuntimeModule] = [TaskModule(registry: registry, store: t, sourceAuthorities: domains), TaskRuntimeModule(registry: registry, model: probe)]
        if let memory {
            modules.append(MemoryModule(registry: registry, store: memory,
                                        sourceAuthorities: domains, now: { TaskWorkflowFixture.now }))
        }
        if let knowledge {
            modules.append(KnowledgeModule(registry: registry, store: knowledge, sourceAuthorities: domains))
        }
        let app = try await AgentApplicationRuntime.open(journal: library, payloads: library, libraryAccess: gate,
            registry: registry, modules: modules,
            policy: TaskAllowPolicy(), authority: b, business: b, authorizer: authorizer,
            approvals: RuntimeApprovalService(), scheduler: scheduler,
            environment: environment ?? .init(now: { TaskWorkflowFixture.now }))
        runtime = app
        let fixture = TaskWorkflowFixture(directory: directory, database: database, library: library, authority: a,
            access: gate, scope: scope, workspaces: w, settings: s, store: t, memory: memory, knowledge: knowledge, business: b, tasks: taskApplication,
            reminders: reminderScheduler, notifications: notifications, runtime: app, scheduler: scheduler, route: route, model: probe, contextPolicy: policy, sourceAuthorities: domains, authorizer: authorizer)
        try await body(fixture)
    } catch {
        await modelFixture?.releaseStream(); await notifications.releaseInstall(); await reminders?.close(); await tasks?.close()
        _ = await runtime?.shutdown(); await scheduler.shutdown(); await access?.close(); await scope.dispose()
        try? await business?.close(); await memory?.close(); await knowledge?.close(); await store?.close(); await workspaces?.close(); await settings?.close()
        await contextPolicy?.close(); await authority?.close(); try? await library.close(); throw error
    }
    await modelFixture?.releaseStream(); await notifications.releaseInstall(); await reminders?.close(); await tasks?.close()
    if let runtime { #expect(await runtime.shutdown().isSettled) }
    await scheduler.shutdown(); await access?.close(); await scope.dispose()
    try? await business?.close(); await memory?.close(); await knowledge?.close(); await store?.close(); await workspaces?.close(); await settings?.close()
    await contextPolicy?.close(); await authority?.close(); try? await library.close()
}

actor TaskModelFixture: AgentModelAdapter {
    nonisolated let identity = AgentAdapterIdentity(id: "task.fixture", revision: 1)
    nonisolated let preparations = TaskPreparationProbe()
    private var outputs: [[AgentModelStreamEvent]]
    private(set) var inputs: [AgentModelInput] = []
    private var heldStreamNumber: Int?
    private var heldEventIndex = 0
    private var streamContinuation: CheckedContinuation<Void, Never>?
    private(set) var streamHeld = false
    private(set) var streamDrained = false
    init(outputs: [[AgentModelStreamEvent]]) { self.outputs = outputs }
    func append(_ outputs: [[AgentModelStreamEvent]]) { self.outputs += outputs }
    func holdStream(number: Int, afterEvents: Int = 0) { heldStreamNumber = number; heldEventIndex = afterEvents }
    func releaseStream() {
        heldStreamNumber = nil; streamHeld = false
        streamContinuation?.resume(); streamContinuation = nil
    }
    private func markStreamDrained() { streamDrained = true }
    nonisolated func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        preparations.record()
        return .init(adapter: identity, input: input, wirePayload: .object([:]), estimatedInputTokens: 1)
    }
    private func next(_ input: AgentModelInput) throws -> (number: Int, events: [AgentModelStreamEvent]) {
        inputs.append(input)
        guard !outputs.isEmpty else { throw MiraError(.malformedStream, "Synthetic task model output was exhausted.") }
        return (inputs.count, outputs.removeFirst())
    }
    private func waitAtBoundary(streamNumber: Int, eventIndex: Int) async {
        if streamNumber == heldStreamNumber, eventIndex == heldEventIndex {
            streamHeld = true
            // Deliberately ignores cancellation to expose the actual producer lifetime.
            await withCheckedContinuation { streamContinuation = $0 }
        }
    }
    nonisolated func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        let (events, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
        let producer = Task {
            do {
                let batch = try await self.next(request.input)
                for (index, event) in batch.events.enumerated() {
                    await self.waitAtBoundary(streamNumber: batch.number, eventIndex: index)
                    continuation.yield(event)
                }
                await self.waitAtBoundary(streamNumber: batch.number, eventIndex: batch.events.count)
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
            await self.markStreamDrained()
        }
        return .init(events: events, cancelAndDrain: { producer.cancel(); await producer.value })
    }
    nonisolated func replay(_ messages: [AgentModelMessage], from source: AgentModelRoute, to target: AgentModelRoute,
                            boundary: AgentReplayBoundary) throws -> AgentReplayDecision { .include(messages) }
}

final class TaskPreparationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}

private struct TaskRuntimeModule: RuntimeModule {
    let id = "task.fixture"
    let dependencies: Set<String> = []
    let registry: RuntimeRegistry<AgentCapability>
    let model: TaskModelFixture
    func activate(in scope: RuntimeScope) async throws {
        try await registry.register(id: "task.fixture.model", value: .model(model), scope: scope)
        try await registry.register(id: "task.fixture.driver", value: .driver(DefaultAgentDriver()), scope: scope)
    }
}
private struct TaskAllowPolicy: AgentToolPolicy {
    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision { .allow }
    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws {}
}

actor TaskNotificationFixture: LocalNotificationPort {
    var permissionState: NotificationPermission
    private var values: [String: ReminderNotification] = [:]
    private(set) var installs = 0
    private(set) var removes = 0
    private var blockNext = false
    private(set) var blocked = false
    private var held: CheckedContinuation<Void, Never>?
    init(permission: NotificationPermission) { permissionState = permission }
    func permission() async -> NotificationPermission { permissionState }
    func requestPermission() async throws -> Bool { permissionState = .allowed; return true }
    func pending() async -> [ReminderNotification] { Array(values.values) }
    func install(_ notification: ReminderNotification) async throws {
        installs += 1
        if blockNext {
            blockNext = false; blocked = true
            await withCheckedContinuation { held = $0 }
            blocked = false
        }
        // Deliberately ignores cancellation: ownership must wait for actual completion.
        values[notification.identifier] = notification
    }
    func remove(_ identifier: String) async { removes += 1; values[identifier] = nil }
    func blockNextInstall() { blockNext = true }
    func releaseInstall() { held?.resume(); held = nil }
}

func taskRequireCommitted(_ result: SessionCommitResult) throws {
    guard case .committed = result else { throw MiraError(.storage, "Synthetic task session did not commit: \(result)") }
}
func taskEventually(_ predicate: @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw MiraError(.timeout, "Synthetic task workflow condition timed out.") }
        try await Task.sleep(for: .milliseconds(1))
    }
}
func taskArguments(title: String = "review notes", quote: String, remind: Bool = false,
                   timeQuote: String? = nil, time: String? = nil, dayOffset: Int? = nil) -> JSONValue {
    var result: [String: JSONValue] = ["operation": .string("create"), "title": .string(title), "quote": .string(quote), "remind": .bool(remind)]
    if let timeQuote { result["time_quote"] = .string(timeQuote) }
    if let time { result["time"] = .string(time) }
    if let dayOffset { result["day_offset"] = .number(Double(dayOffset)) }
    return .object(result)
}
func taskReplies(_ arguments: JSONValue, count: Int = 1) throws -> [[AgentModelStreamEvent]] {
    let calls = try (0..<count).map { CanonicalToolCall(id: "task-\($0)", name: "task.change", arguments: try arguments.jsonString()) }
    return [modelToolStream(calls), [.blockStarted(.init(id: "text", content: .text("Task processed"))), .blockFinished(id: "text"), .finished(.stop)]]
}

private struct TaskWorkflowValidator: SQLiteBusinessAuthorizationValidator {
    let memoryEnabled: Bool
    let knowledgeEnabled: Bool
    func validate(effect: AgentResolvedEffect, isReplay: Bool, in db: Database) throws {
        if memoryEnabled, effect.proposal.descriptor.definition.name.hasPrefix("memory.") {
            if effect.proposal.descriptor.definition.name == "memory.retract" {
                try SQLiteMemoryRetractHandler(now: { TaskWorkflowFixture.now }).validate(effect: effect, isReplay: isReplay, in: db)
            } else {
                try SQLiteMemoryRememberHandler(now: { TaskWorkflowFixture.now }).validate(effect: effect, isReplay: isReplay, in: db)
            }
        } else if knowledgeEnabled,
                  ["knowledge.search", "source.open", "source.read_chunk"].contains(effect.proposal.descriptor.definition.name) {
            try SQLiteKnowledgeReadValidator().validate(effect: effect, isReplay: isReplay, in: db)
        } else {
            try SQLiteTaskCommandHandler(now: { TaskWorkflowFixture.now }).validate(effect: effect, isReplay: isReplay, in: db)
        }
    }
}
