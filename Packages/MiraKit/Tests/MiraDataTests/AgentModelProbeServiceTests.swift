import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Scoped model capability probes", .timeLimit(.minutes(1)))
struct AgentModelProbeServiceTests {
    @Test func unknownStreamingProbeRunsWithoutAutoSaving() async throws {
        try await withProbeFixture { f in
            let descriptors = try await f.service.descriptors()
            #expect(descriptors.map(\.id) == ["fixture.text"])
            let observation = try await f.service.probe(routeID: f.preset.id, probeID: "fixture.text")
            #expect(observation.outcome == .verified)
            #expect(try await f.settings.model(id: f.model.id)?.facts.isEmpty == true)
            #expect(try await f.settings.model(id: f.model.id)?.invocations.first?.capabilities.isEmpty == true)
            #expect(await f.adapter.gate.drainCount == 1)
        }
    }

    @Test func explicitUnknownCapabilityCanBeRetested() async throws {
        try await withProbeFixture(initialCapabilities: [AgentModelCapabilityID.streamingText: .unknown]) { f in
            let observation = try await f.service.probe(routeID: f.preset.id, probeID: "fixture.text")
            #expect(observation.outcome == .verified)
            #expect(
                try await f.settings.model(id: f.model.id)?.invocations.first?.capabilities[AgentModelCapabilityID.streamingText]
                    == .unknown)
        }
    }

    @Test func failedCapabilityCanBeRetestedWithoutBeingPersisted() async throws {
        try await withProbeFixture(initialCapabilities: [AgentModelCapabilityID.streamingText: .failed]) { f in
            let observation = try await f.service.probe(routeID: f.preset.id, probeID: "fixture.text")
            #expect(observation.outcome == .verified)
            #expect(
                try await f.settings.model(id: f.model.id)?.invocations.first?.capabilities[AgentModelCapabilityID.streamingText]
                    == .failed)
        }
    }

    @Test func standaloneExecutionRunsAnUnsavedCandidate() async throws {
        try await withProbeFixture { f in
            let store = try SQLiteAgentModelProbeStore(database: f.database, libraryID: f.authority.libraryID)
            let authorization = try await f.authority.authorization()
            let candidate = try await store.candidate(routeID: f.preset.id, authorization: authorization)
            let lease = try await f.access.acquire(in: f.scope)
            do {
                let execution = try AgentModelProbeExecution(registry: f.registry)
                let observation = try await execution.run(
                    candidate: candidate, probeID: "fixture.text", lease: lease)
                #expect(observation.outcome == .verified)
                await lease.release()
            } catch {
                await lease.release()
                throw error
            }
        }
    }

    @Test func timeoutClosesOperationBeforeReturningAndWaitsDrain() async throws {
        try await withProbeFixture(timeout: .milliseconds(10), producerOpen: false, drainOpen: false) { f in
            let task = Task { try await f.service.probe(routeID: f.preset.id, probeID: "fixture.text") }
            try await wait { await f.adapter.gate.started }
            try await wait { await f.adapter.gate.drainStarted }
            #expect(await f.access.snapshot().activeResources == 1)
            await f.adapter.gate.releaseDrain()
            await f.adapter.gate.releaseProducer()
            await #expect(throws: MiraError.self) { _ = try await task.value }
            #expect(await f.adapter.gate.drainCount == 1)
            #expect(await f.access.snapshot().activeLeases == 0)
        }
    }

    @Test func callerCancellationAndServiceCloseDrainAcceptedProducer() async throws {
        try await withProbeFixture(producerOpen: false, drainOpen: false) { f in
            let task = Task { try await f.service.probe(routeID: f.preset.id, probeID: "fixture.text") }
            try await wait { await f.adapter.gate.started }
            task.cancel()
            try await wait { await f.adapter.gate.drainStarted }
            let closer = Task { await f.service.close() }
            #expect(await f.access.snapshot().activeLeases == 1)
            await f.adapter.gate.releaseDrain()
            await f.adapter.gate.releaseProducer()
            _ = await task.result
            await closer.value
            #expect(await f.access.snapshot().activeLeases == 0)
        }
    }

    @Test func maximumConcurrencyRejectsSecondProbe() async throws {
        try await withProbeFixture(producerOpen: false, maximumConcurrentOperations: 1) { f in
            let first = Task { try await f.service.probe(routeID: f.preset.id, probeID: "fixture.text") }
            try await wait { await f.adapter.gate.started }
            await expectCode(.busy) {
                _ = try await f.service.probe(routeID: f.preset.id, probeID: "fixture.text")
            }
            await f.adapter.gate.releaseProducer()
            _ = try await first.value
        }
    }

    @Test func transportFailureDoesNotProduceObservation() async throws {
        try await withProbeFixture(failure: true) { f in
            await expectCode(.network) {
                _ = try await f.service.probe(routeID: f.preset.id, probeID: "fixture.text")
            }
            #expect(await f.access.snapshot().activeLeases == 0)
        }
    }

    @Test func invalidPreparationCannotUpgradeCapabilityOrRoute() async throws {
        try await withProbeFixture(badPreparation: true) { f in
            await expectCode(.configuration) {
                _ = try await f.service.probe(routeID: f.preset.id, probeID: "fixture.text")
            }
            #expect(await f.adapter.gate.started == false)
        }
    }

    @Test(arguments: ["connection", "model", "preset"])
    func everyRouteComponentChangeRejectsLateObservation(change: String) async throws {
        try await withProbeFixture(producerOpen: false) { f in
            let task = Task { try await f.service.probe(routeID: f.preset.id, probeID: "fixture.text") }
            try await wait { await f.adapter.gate.started }
            let authorization = try await f.authority.authorization()
            switch change {
            case "connection":
                let value = AgentConfiguredConnection(id: f.connection.id, revision: 2, configurationRevision: 1, name: "Edited", isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: f.connection.endpoints[0].configuration, credential: nil)], discovery: f.connection.discovery, defaultInvocation: nil)
                try await f.settings.saveConnection(value, expectedRevision: 1, authorization: authorization)
            case "model":
                let value = AgentConfiguredModel(id: f.model.id, revision: 2, authorizationRevision: 1, reference: .init(connectionID: f.model.connectionID, modelID: f.model.modelID), displayName: nil, isEnabled: true, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: f.model.invocations[0].adapter, endpointID: "primary", contextWindow: f.model.invocations[0].contextWindow, maximumOutputTokens: nil, capabilities: f.model.invocations[0].capabilities, configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: modelParameterSchema)], facts: [])
                try await f.settings.saveModel(value, expectedRevision: 1, authorization: authorization)
            default:
                let value = AgentRoutePreset(id: f.preset.id, revision: 2, name: "Edited", modelDescriptorID: f.preset.modelDescriptorID, invocationID: "default", maximumOutputTokens: f.preset.maximumOutputTokens, configuration: f.preset.configuration)
                try await f.settings.savePreset(value, expectedRevision: 1, authorization: authorization)
            }
            await f.adapter.gate.releaseProducer()
            await expectCode(.conflict) { _ = try await task.value }
        }
    }

    @Test func saveCloseWaitsForOwnedStoreOperation() async throws {
        let store = ProbeStore()
        try await withProbeFixture(producerOpen: true, probeStore: store) { f in
            let observation = try await f.service.probe(routeID: f.preset.id, probeID: "fixture.text")
            let save = Task { try await f.service.save(observation) }
            try await wait { await store.entered }
            let close = Task { await f.access.close() }
            #expect(await f.access.snapshot().activeLeases == 1)
            await store.release()
            _ = await save.result
            await close.value
            await f.service.close()
            #expect(await store.saveCount == 1)
        }
    }
}

private struct ProbeFixture {
    let database: DatabaseQueue
    let authority: SQLiteLibraryAuthority
    let settings: SQLiteAgentModelSettings
    let access: AgentLibraryAccess
    let scope: RuntimeScope
    let registry: RuntimeRegistry<AgentCapability>
    let adapter: FixtureProbeAdapter
    let connection: AgentConfiguredConnection
    let model: AgentConfiguredModel
    let preset: AgentRoutePreset
    let service: AgentModelProbeService
}

private func withProbeFixture(
    timeout: Duration = .seconds(2), producerOpen: Bool = true, drainOpen: Bool = true,
    failure: Bool = false, maximumConcurrentOperations: Int = 8,
    badPreparation: Bool = false,
    initialCapabilities: [String: CapabilityState] = [:],
    probeStore: (any AgentModelProbeStore)? = nil,
    _ body: (ProbeFixture) async throws -> Void
) async throws {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
    let database = try DatabaseQueue(configuration: configuration)
    let authority = try SQLiteLibraryAuthority(database: database)
    let settings = try SQLiteAgentModelSettings(database: database, libraryID: authority.libraryID)
    let access = try await AgentLibraryAccess.open(store: authority)
    let scope = RuntimeScope(kind: .application)
    let registry = RuntimeRegistry<AgentCapability>()
    let schema = AgentConfigurationSchema(
        identity: .init(id: "fixture.probe.schema", revision: 1), title: "Probe",
        schema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]),
        defaults: .object([:]))
    let value = AgentConfigurationValue(schema: schema.identity, value: .object([:]))
    let connection = AgentConfiguredConnection(id: .init(), revision: 1, configurationRevision: 1, name: "Fixture", isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: value, credential: nil)], discovery: nil, defaultInvocation: nil)
    let model = AgentConfiguredModel(id: .init(), revision: 1, authorizationRevision: 1, reference: .init(connectionID: connection.id, modelID: "fixture"), displayName: nil, isEnabled: true, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: .init(id: "fixture.probe.adapter", revision: 1), endpointID: "primary", contextWindow: 4096, maximumOutputTokens: nil, capabilities: initialCapabilities, configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: modelParameterSchema)], facts: [])
    let preset = AgentRoutePreset(id: RouteID(model.id.rawValue), revision: 1, name: "Fixture", modelDescriptorID: model.id, invocationID: "default", maximumOutputTokens: 128, configuration: value)
    let adapter = FixtureProbeAdapter(gate: .init(producerOpen: producerOpen, drainOpen: drainOpen), failure: failure)
    let provider = FixtureProbeProvider(schema: schema, adapter: adapter.identity, badPreparation: badPreparation)
    try await settings.saveConnection(connection, expectedRevision: nil, authorization: authority.authorization())
    try await settings.savePoolModel(
        model, preset: preset, expectedModelRevision: nil, expectedPresetRevision: nil,
        authorization: authority.authorization())
    try await registry.register(id: "probe.adapter", value: .model(adapter), scope: scope)
    try await registry.register(id: "probe.configuration", value: .modelConfiguration(provider), scope: scope)
    try await registry.register(id: "probe.definitions", value: .modelProbe(provider), scope: scope)
    let sqliteProbeStore = try SQLiteAgentModelProbeStore(database: database, libraryID: authority.libraryID)
    if let gated = probeStore as? ProbeStore { await gated.setBase(sqliteProbeStore) }
    let serviceStore: any AgentModelProbeStore = probeStore ?? sqliteProbeStore
    let service = try AgentModelProbeService(
        probeStore: serviceStore, registry: registry,
        access: access, scope: scope, timeout: timeout, maximumConcurrentOperations: maximumConcurrentOperations)
    do {
        try await body(
            .init(
                database: database, authority: authority, settings: settings, access: access, scope: scope,
                registry: registry, adapter: adapter, connection: connection, model: model, preset: preset,
                service: service))
    } catch {
        await adapter.gate.releaseDrain()
        await adapter.gate.releaseProducer()
        await service.close()
        await scope.dispose()
        await access.close()
        await settings.close()
        await authority.close()
        try? database.close()
        throw error
    }
    await adapter.gate.releaseDrain()
    await adapter.gate.releaseProducer()
    await service.close()
    await scope.dispose()
    await access.close()
    await settings.close()
    await authority.close()
    try database.close()
}

private struct FixtureProbeProvider: AgentModelConfigurationProvider, AgentModelProbeProvider {
    let schema: AgentConfigurationSchema
    let identity: AgentAdapterIdentity
    let badPreparation: Bool
    init(schema: AgentConfigurationSchema, adapter: AgentAdapterIdentity, badPreparation: Bool = false) {
        self.schema = schema
        identity = adapter
        self.badPreparation = badPreparation
    }
    func descriptor(for invocation: AgentModelInvocationSpec) throws -> AgentModelConfigurationDescriptor {
        .init(adapter: identity, title: "Fixture", credential: .none, connection: schema, route: schema)
    }
    func configuration(for candidate: AgentModelRouteCandidate) throws -> JSONValue {
        candidate.preset.configuration.value
    }
    func probes() throws -> [AgentModelProbeDefinition] {
        [
            try .init(
                identity: .init(
                    id: "fixture.text", revision: 1, title: "Fixture text",
                    capabilityIDs: [AgentModelCapabilityID.streamingText]),
                preparationCapabilityIDs: [AgentModelCapabilityID.streamingText],
                prepareCandidate: { candidate in
                    let m = candidate.model
                    let original = try #require(m.invocations.first)
                    var caps = original.capabilities
                    caps[AgentModelCapabilityID.streamingText] = badPreparation ? .verified : .declared
                    let preparedInvocation = AgentModelInvocationSpec(
                        id: original.id, revision: original.revision, adapter: original.adapter,
                        endpointID: original.endpointID, contextWindow: original.contextWindow,
                        maximumOutputTokens: original.maximumOutputTokens, capabilities: caps,
                        configuration: original.configuration, parameterSchema: original.parameterSchema,
                        maximumInputTokens: original.maximumInputTokens)
                    return .init(
                        connection: candidate.connection,
                        model: .init(id: m.id, revision: m.revision, authorizationRevision: m.authorizationRevision,
                                     reference: m.reference, displayName: m.displayName, isEnabled: m.isEnabled,
                                     invocations: [preparedInvocation], facts: m.facts),
                        preset: candidate.preset)
                },
                makeInput: { step, execution, _ in
                    .init(
                        stepID: step, executionID: execution, instructions: "probe",
                        messages: [.init(role: .user, blocks: [.init(id: "text", content: .text("probe"))])], tools: [])
                }, evaluate: { $0.text == "OK" ? .verified : .unsupported })
        ]
    }
}

private struct FixtureProbeAdapter: AgentModelAdapter {
    let identity = AgentAdapterIdentity(id: "fixture.probe.adapter", revision: 1)
    let gate: ProbeGate
    let failure: Bool
    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        .init(adapter: identity, input: input, wirePayload: .object([:]), estimatedInputTokens: 1)
    }
    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        let (events, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
        let task = Task {
            await gate.markStarted()
            if failure {
                continuation.finish(throwing: MiraError(.network, "fixture transport"))
                return
            }
            await gate.waitProducer()
            continuation.yield(.blockStarted(.init(id: "text", content: .text(""))))
            continuation.yield(.blockDelta(id: "text", text: "OK"))
            continuation.yield(.blockFinished(id: "text"))
            continuation.yield(.finished(.stop))
            continuation.finish()
        }
        return .init(events: events) {
            await gate.beginDrain()
            await gate.releaseProducer()
            task.cancel()
            _ = await task.result
            await gate.finishDrain()
        }
    }
    func replay(
        _ messages: [AgentModelMessage], from source: AgentModelRoute, to target: AgentModelRoute,
        boundary: AgentReplayBoundary
    ) throws -> AgentReplayDecision { .include(messages) }
}

private actor ProbeGate {
    var started = false, drainStarted = false, drainCount = 0
    private var producerOpen: Bool, drainOpen: Bool
    private var producerWaiters: [CheckedContinuation<Void, Never>] = [],
        drainWaiters: [CheckedContinuation<Void, Never>] = []
    init(producerOpen: Bool, drainOpen: Bool) {
        self.producerOpen = producerOpen
        self.drainOpen = drainOpen
    }
    func markStarted() { started = true }
    func waitProducer() async { if !producerOpen { await withCheckedContinuation { producerWaiters.append($0) } } }
    func beginDrain() {
        drainStarted = true
        drainCount += 1
    }
    func finishDrain() async { if !drainOpen { await withCheckedContinuation { drainWaiters.append($0) } } }
    func releaseProducer() {
        producerOpen = true
        let ws = producerWaiters
        producerWaiters.removeAll()
        ws.forEach { $0.resume() }
    }
    func releaseDrain() {
        drainOpen = true
        let ws = drainWaiters
        drainWaiters.removeAll()
        ws.forEach { $0.resume() }
    }
}

private actor ProbeStore: AgentModelProbeStore {
    private var base: SQLiteAgentModelProbeStore?
    var entered = false, saveCount = 0
    private var open = false, waiters: [CheckedContinuation<Void, Never>] = []
    func setBase(_ base: SQLiteAgentModelProbeStore) { self.base = base }
    func candidate(routeID: RouteID, authorization: AgentLibraryAuthorization) async throws -> AgentModelRouteCandidate
    {
        guard let base else { throw MiraError(.storage, "Probe fixture store was not initialized.") }
        return try await base.candidate(routeID: routeID, authorization: authorization)
    }
    func save(_ observation: AgentModelProbeObservation, authorization: AgentLibraryAuthorization) async throws {
        entered = true
        if !open { await withCheckedContinuation { waiters.append($0) } }
        saveCount += 1
        guard let base else { throw MiraError(.storage, "Probe fixture store was not initialized.") }
        try await base.save(observation, authorization: authorization)
    }
    func release() {
        open = true
        let ws = waiters
        waiters.removeAll()
        ws.forEach { $0.resume() }
    }
}

private func wait(_ condition: @escaping () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard clock.now < deadline else { throw MiraError(.timeout, "Probe fixture did not reach its gate.") }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private func expectCode(_ code: MiraError.Code, _ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Expected probe failure.")
    } catch let error as MiraError { #expect(error.code == code) } catch {
        Issue.record("Expected classified probe failure, received \(error).")
    }
}
