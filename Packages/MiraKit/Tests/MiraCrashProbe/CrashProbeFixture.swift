import Foundation
import GRDB
import MiraCore
import MiraData

struct ProbeExecution: Codable, Sendable {
    let sessionID: ConversationID
    let executionID: ExecutionID
    let commandID: UUID
    let route: AgentModelRoute
    var command: AgentSubmitCommand {
        .init(
            id: commandID, sessionID: sessionID, executionID: executionID,
            input: .message(
                id: MessageID(executionID.rawValue), text: "Record the synthetic counter.", timeZoneIdentifier: "UTC"),
            options: .init(instructions: "Use the registered counter once.", route: route),
            opening: .init(title: "Crash recovery", workspaceID: nil))
    }
}

/// Owns physical stores, while each application owns its scheduler, approvals and module activation.
final class CrashProbeFixture: Sendable {
    let context: CrashProbeContext
    let gate: ProbeCrashGate
    let database: DatabaseQueue
    let library: FileSessionLibrary
    let journal: ProbeJournal
    let authority: SQLiteLibraryAuthority
    let access: AgentLibraryAccess
    let settings: SQLiteAgentModelSettings
    let contextPolicy: SQLiteAgentContextPolicy
    let business: SQLiteBusinessEffects
    let workspaces: SQLiteWorkspaceStore
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let interruptedThought = String(repeating: "Synthetic thought. ", count: 320)
    static let interruptedContinuation = AgentModelContinuation(
        adapter: .init(id: "crash.model", revision: 1),
        format: "crash.opaque", payload: .object(["token": .string("opaque-retained")]), isComplete: false)

    private init(
        context: CrashProbeContext, gate: ProbeCrashGate, database: DatabaseQueue,
        library: FileSessionLibrary, journal: ProbeJournal, authority: SQLiteLibraryAuthority,
        access: AgentLibraryAccess, settings: SQLiteAgentModelSettings, contextPolicy: SQLiteAgentContextPolicy,
        business: SQLiteBusinessEffects, workspaces: SQLiteWorkspaceStore
    ) {
        self.context = context
        self.gate = gate
        self.database = database
        self.library = library
        self.journal = journal
        self.authority = authority
        self.access = access
        self.settings = settings
        self.contextPolicy = contextPolicy
        self.business = business
        self.workspaces = workspaces
    }

    static func open(_ context: CrashProbeContext) async throws -> CrashProbeFixture {
        let gate = ProbeCrashGate(context: context)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
        let db = try DatabaseQueue(path: context.businessPath, configuration: configuration)
        var library: FileSessionLibrary?
        var authority: SQLiteLibraryAuthority?
        var access: AgentLibraryAccess?
        var settings: SQLiteAgentModelSettings?
        var policy: SQLiteAgentContextPolicy?
        var business: SQLiteBusinessEffects?
        var workspaces: SQLiteWorkspaceStore?
        do {
            try await db.write { db in
                try db.execute(
                    sql: "CREATE TABLE IF NOT EXISTS probe_counts(kind TEXT PRIMARY KEY, value INTEGER NOT NULL)")
                try db.execute(sql: "INSERT OR IGNORE INTO probe_counts VALUES ('business',0),('model',0)")
            }
            let a = try SQLiteLibraryAuthority(
                database: db,
                validators: [
                    .init(
                        identity: .init(namespace: "crash.privacy", revision: 1),
                        validate: { request, _ in try request.validate() })
                ])
            authority = a
            let l = try FileSessionLibrary(directory: context.journalDirectory, faultInjector: gate.storage)
            library = l
            let j = ProbeJournal(library: l, gate: gate)
            let x = try await AgentLibraryAccess.open(store: a)
            access = x
            let w = try SQLiteWorkspaceStore(database: db, libraryID: a.libraryID)
            workspaces = w
            let s = try SQLiteAgentModelSettings(database: db, libraryID: a.libraryID)
            settings = s
            let p = try SQLiteAgentContextPolicy(database: db, libraryID: a.libraryID)
            policy = p
            let b = try SQLiteBusinessEffects(
                database: db, libraryID: a.libraryID,
                resolver: JournalAgentEffectResolver(journal: j, payloads: l), handlers: [ProbeCounterHandler()],
                validator: ProbeCounterValidator(), afterCommitHook: { try gate.businessCommitted() })
            business = b
            return .init(
                context: context, gate: gate, database: db, library: l, journal: j, authority: a,
                access: x, settings: s, contextPolicy: p, business: b, workspaces: w)
        } catch {
            await access?.close()
            try? await business?.close()
            await policy?.close()
            await settings?.close()
            await workspaces?.close()
            await authority?.close()
            try? await library?.close()
            try? db.close()
            throw error
        }
    }

    func close() async throws {
        await access.close()
        try await business.close()
        await contextPolicy.close()
        await settings.close()
        await workspaces.close()
        await authority.close()
        try await library.close()
        try database.close()
    }

    func newExecution() async throws -> ProbeExecution {
        let value = AgentConfigurationValue(schema: .init(id: "crash.model", revision: 1), value: .object([:]))
        let connection = AgentConfiguredConnection(id: .init(), revision: 1, configurationRevision: 1, name: "Synthetic crash model", isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: value, credential: nil)], discovery: nil, defaultInvocation: nil)
        let model = AgentConfiguredModel(id: .init(), revision: 1, authorizationRevision: 1, reference: .init(connectionID: connection.id, modelID: "synthetic"), displayName: nil, isEnabled: true, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: ProbeModel.identity, endpointID: "primary", contextWindow: 16_384, maximumOutputTokens: nil, capabilities: [
                AgentModelCapabilityID.streamingText: .declared, AgentModelCapabilityID.toolCalls: .declared,
                AgentModelCapabilityID.thinking: .declared,
            ], configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]))], facts: [])
        let preset = AgentRoutePreset(id: RouteID(model.id.rawValue), revision: 1, name: "Synthetic crash route", modelDescriptorID: model.id, invocationID: "default", maximumOutputTokens: 1024, configuration: value)
        try await settings.saveConnection(connection, expectedRevision: nil, authorization: authority.authorization())
        try await settings.savePoolModel(
            model, preset: preset, expectedModelRevision: nil, expectedPresetRevision: nil,
            authorization: authority.authorization())
        let route = try await settings.candidate(routeID: preset.id).freeze(configuration: .object([:]))
        return .init(sessionID: .init(), executionID: .init(), commandID: UUID(), route: route)
    }

    func openApplication() async throws -> AgentApplicationRuntime {
        let registry = RuntimeRegistry<AgentCapability>()
        let authorizer = JournalAgentSourceAuthorizer(
            reader: .init(journal: journal, payloads: library),
            policy: contextPolicy, domains: RuntimeRegistry<any AgentDomainSourceAuthority>())
        let scheduler = RuntimeScheduler()
        let approvals = RuntimeApprovalService()
        do {
            return try await AgentApplicationRuntime.open(
                journal: journal, payloads: library, libraryAccess: access,
                registry: registry,
                modules: [ProbeModule(registry: registry, model: ProbeModel(database: database, gate: gate))],
                policy: ProbeAllowPolicy(), authority: business, business: business, authorizer: authorizer,
                approvals: approvals, scheduler: scheduler, environment: .init(now: { Self.now }))
        } catch {
            await scheduler.shutdown()
            await approvals.shutdown()
            throw error
        }
    }

    func count(_ kind: String) async throws -> Int {
        try await database.read { db in
            guard
                let count = try Int.fetchOne(
                    db, sql: "SELECT value FROM probe_counts WHERE kind = ?", arguments: [kind])
            else {
                throw MiraError(.storage, "The probe counter is missing.")
            }
            return count
        }
    }
}

final class ProbeCrashGate: @unchecked Sendable {
    private let lock = NSLock()
    private var scenario: String?
    private var transcriptCheckpointCount = 0
    private let context: CrashProbeContext
    init(context: CrashProbeContext) { self.context = context }
    func arm(_ scenario: String) { lock.withLock { self.scenario = scenario } }
    var emitsInterruptedThinking: Bool { lock.withLock { scenario == "thinkingDraft" } }
    func businessCommitted() throws {
        if lock.withLock({ scenario == "businessCommitted" }) { try context.pause() }
    }
    func storage(_ stage: SessionStorageFaultStage) throws {
        if stage == .afterPayloadDelete, lock.withLock({ scenario == "privacyBodyDeleted" }) { try context.pause() }
    }
    func appended(_ batch: SessionBatch) throws {
        let scenario = lock.withLock { self.scenario }
        let selected = lock.withLock {
            batch.events.contains { event in
                switch event.fact {
                case .toolResolved(let value): return scenario == "toolResultPublished" && value.businessReceipt != nil
                case .invalidated: return scenario == "privacyInvalidated"
                case .admitted: return scenario == "admissionPublished"
                case .draftCheckpoint(let value):
                    guard scenario == "thinkingDraft" && value.part == .transcript else { return false }
                    transcriptCheckpointCount += 1
                    // The first checkpoint can precede a separately delivered continuation event.
                    // Pause after the next complete transcript so recovery verifies opaque data.
                    return transcriptCheckpointCount >= 2
                case .finished: return scenario == "terminalPublished"
                default: return false
                }
            }
        }
        if selected { try context.pause() }
    }
}

struct ProbeJournal: SessionJournal {
    let library: FileSessionLibrary
    let gate: ProbeCrashGate
    func append(_ batch: SessionBatch) async -> SessionAppendOutcome {
        let result = await library.append(batch)
        if case .committed = result {
            do { try gate.appended(batch) } catch { return .indeterminate(.init(.storage, "The probe pause failed.")) }
        }
        return result
    }
    func reconcile(_ batch: SessionBatch) async -> SessionAppendOutcome { await library.reconcile(batch) }
    func batch(id: UUID, sessionID: ConversationID) async throws -> SessionBatch? {
        try await library.batch(id: id, sessionID: sessionID)
    }
    func head(sessionID: ConversationID) async throws -> SessionJournalHead {
        try await library.head(sessionID: sessionID)
    }
    func read(sessionID: ConversationID, after sequence: Int64, limit: Int) async throws -> [SessionBatch] {
        try await library.read(sessionID: sessionID, after: sequence, limit: limit)
    }
    func sessions(after: ConversationID?, limit: Int) async throws -> [ConversationID] {
        try await library.sessions(after: after, limit: limit)
    }
    func flush() async throws { try await library.flush() }
    func close() async throws { try await library.close() }
}

private struct ProbeModule: RuntimeModule {
    let id = "crash.module"
    let dependencies: Set<String> = []
    let registry: RuntimeRegistry<AgentCapability>
    let model: ProbeModel
    func activate(in scope: RuntimeScope) async throws {
        try await registry.register(id: "crash.driver", value: .driver(DefaultAgentDriver()), scope: scope)
        try await registry.register(id: "crash.model", value: .model(model), scope: scope)
        try await registry.register(id: "crash.tool", value: .tool(.localWrite(ProbeCounterTool())), scope: scope)
    }
}
private struct ProbeModel: AgentModelAdapter {
    static let identity: AgentAdapterIdentity = .init(id: "crash.model", revision: 1)
    var identity: AgentAdapterIdentity { Self.identity }
    let database: DatabaseQueue
    let gate: ProbeCrashGate
    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        try input.validate(for: route)
        return .init(adapter: identity, input: input, wirePayload: .object([:]), estimatedInputTokens: 100)
    }
    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        let (events, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
        let task = Task {
            do {
                try await database.write { db in
                    try db.execute(sql: "UPDATE probe_counts SET value = value + 1 WHERE kind = 'model'")
                }
                try Task.checkCancellation()
                if gate.emitsInterruptedThinking {
                    continuation.yield(.blockStarted(.init(id: "thinking", content: .thinking(CrashProbeFixture.interruptedThought))))
                    continuation.yield(.continuation(CrashProbeFixture.interruptedContinuation))
                    // Simulate an open transport. The journal checkpoint, rather than elapsed time, triggers the crash.
                    try await Task.sleep(for: .seconds(60))
                    throw MiraError(.timeout, "The stalled probe transport was not interrupted.")
                }
                if request.input.messages.last?.role == .tool {
                    continuation.yield(.blockStarted(.init(id: "text", content: .text("The synthetic counter was recorded."))))
                    continuation.yield(.blockFinished(id: "text"))
                    continuation.yield(.finished(.stop))
                } else {
                    continuation.yield(.blockStarted(.init(id: "tool-0", content: .toolCall(.init(id: "counter", name: "crash.counter", arguments: "{}")))))
                    continuation.yield(.blockFinished(id: "tool-0"))
                    continuation.yield(.finished(.toolCalls))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        return .init(events: events) {
            task.cancel()
            await task.value
        }
    }
    func replay(
        _ messages: [AgentModelMessage], from source: AgentModelRoute, to target: AgentModelRoute,
        boundary: AgentReplayBoundary
    ) throws -> AgentReplayDecision { .include(messages) }
}
private struct ProbeCounterTool: AgentLocalWriteTool {
    let businessNamespace = "crash.counter"
    let policy = AgentToolPolicyRequirement.hostOnly
    var descriptor: AgentToolDescriptor {
        .init(
            definition: .init(
                name: "crash.counter", description: "Increment the isolated recovery counter.",
                inputSchema: .object([
                    "type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false),
                ])),
            revision: 1,
            outputSchema: .object([
                "type": .string("object"), "properties": .object(["value": .object(["type": .string("integer")])]),
                "required": .array([.string("value")]), "additionalProperties": .bool(false),
            ]),
            executionMode: .exclusive, timeoutMilliseconds: 10_000, maximumResultBytes: 1024)
    }
    func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan {
        .init(input: arguments, sources: [], targets: [])
    }
}
private struct ProbeCounterHandler: SQLiteBusinessCommandHandler {
    let namespace = "crash.counter"
    func businessKey(for effect: AgentResolvedEffect) throws -> String { effect.context.invocationID.uuidString }
    func apply(effect: AgentResolvedEffect, in db: Database) throws -> JSONValue {
        try db.execute(sql: "UPDATE probe_counts SET value = value + 1 WHERE kind = 'business'")
        let value = try Int.fetchOne(db, sql: "SELECT value FROM probe_counts WHERE kind = 'business'") ?? -1
        return .object(["value": .number(Double(value))])
    }
}
private struct ProbeCounterValidator: SQLiteBusinessAuthorizationValidator {
    func validate(effect: AgentResolvedEffect, isReplay: Bool, in db: Database) throws {
        guard effect.proposal.effect == .localWrite, effect.proposal.businessNamespace == "crash.counter",
            effect.proposal.descriptor.definition.name == "crash.counter"
        else {
            throw MiraError(.unauthorized, "The recovery probe rejected an unrelated business command.")
        }
    }
}
private struct ProbeAllowPolicy: AgentToolPolicy {
    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision {
        .allow
    }
    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws {}
}
