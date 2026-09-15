import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Agent model settings application", .timeLimit(.minutes(1)))
struct AgentModelSettingsApplicationTests {
    @Test func poolCASIsAtomicAndPagesAreKeysetOrdered() async throws {
        try await withFixture { fixture in
            let first = fixture.connection
            try await fixture.application.saveConnection(first, expectedRevision: nil)

            // A failed pool CAS must not leave either half of the pair behind.
            await #expect(throws: MiraError.self) {
                try await fixture.application.savePoolModel(
                    fixture.model, preset: fixture.preset,
                    expectedModelRevision: nil, expectedPresetRevision: 2)
            }
            #expect(try await fixture.application.model(id: fixture.model.id) == nil)
            #expect(try await fixture.application.preset(id: fixture.preset.id) == nil)

            try await fixture.application.savePoolModel(
                fixture.model, preset: fixture.preset,
                expectedModelRevision: nil, expectedPresetRevision: nil)
            let second = fixture.connection.copy(id: .init(), name: "Second")
            try await fixture.application.saveConnection(second, expectedRevision: nil)
            let page = try await fixture.application.connections(after: nil, limit: 1)
            let tail = try await fixture.application.connections(
                after: try #require(page.last).id, limit: 1)
            #expect(
                (page + tail).map(\.id)
                    == [first.id, second.id].sorted { $0.rawValue.uuidString < $1.rawValue.uuidString })

            await #expect(throws: MiraError.self) {
                try await fixture.application.connections(after: nil, limit: 0)
            }
            await #expect(throws: MiraError.self) {
                try await fixture.application.connections(after: nil, limit: 129)
            }
        }
    }

    @Test func descriptorsFreezeRoutesAndMissingModulesFailClosed() async throws {
        try await withFixture { fixture in
            try await fixture.registerModules(
                includeModel: true, includeConfiguration: true, includeDiscovery: true)
            let configurations = try await fixture.application.configurationDescriptors(
                for: fixture.model.invocations[0])
            #expect(configurations.map(\.adapter) == [fixture.adapterIdentity])
            #expect(
                try await fixture.application.discoveryDescriptors().map(\.adapter) == [
                    fixture.adapterIdentity
                ])

            try await fixture.application.saveConnection(fixture.connection, expectedRevision: nil)
            try await fixture.application.savePoolModel(
                fixture.model, preset: fixture.preset,
                expectedModelRevision: nil, expectedPresetRevision: nil)
            try await fixture.application.saveBinding(
                .init(scope: .global, purpose: "test.chat", routeID: fixture.preset.id, revision: 1),
                expectedRevision: nil)
            let first = try await fixture.application.resolve(
                purpose: "test.chat", explicitRouteID: nil, sessionSelection: .inherit, workspaceID: nil)
            #expect(first.route.configuration == .object(["model": .string(fixture.model.modelID)]))

            let editedPreset = fixture.preset.copy(
                revision: 2,
                configuration: .init(
                    schema: fixtureSchema.identity,
                    value: .object(["temperature": .number(0.2)])))
            try await fixture.application.savePreset(editedPreset, expectedRevision: 1)
            let second = try await fixture.application.resolve(
                purpose: "test.chat", explicitRouteID: nil, sessionSelection: .inherit, workspaceID: nil)
            #expect(first.route != second.route)
            #expect(first.route.configuration == .object(["model": .string(fixture.model.modelID)]))

            let missingRegistry = RuntimeRegistry<AgentCapability>()
            let missingScope = RuntimeScope(kind: .library(fixture.authority.libraryID))
            let missing = try AgentModelSettingsApplication(
                store: fixture.settings, registry: missingRegistry,
                access: fixture.access, scope: missingScope)
            await #expect(throws: MiraError.self) {
                try await missing.resolve(
                    purpose: "test.chat", explicitRouteID: fixture.preset.id,
                    sessionSelection: .inherit, workspaceID: nil)
            }
            await missing.close()
            await missingScope.dispose()
        }
    }

    @Test func maintenanceAndClosedApplicationRejectOperations() async throws {
        try await withFixture { fixture in
            try await fixture.application.saveConnection(fixture.connection, expectedRevision: nil)
            let expected = fixture.authorization
            let request = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: "settings.test", revision: 1,
                scope: .library, requestedAt: Date())
            _ = try await fixture.access.begin(request, expected: expected)
            await #expect(throws: MiraError.self) {
                try await fixture.application.connection(id: fixture.connection.id)
            }
            await fixture.application.close()
            await #expect(throws: MiraError.self) {
                try await fixture.application.connections(after: nil, limit: 1)
            }
        }
    }

    @Test func cancelledReadWaitsForNonCooperativeStoreAndDiscardsLateValue() async throws {
        try await withGatedFixture { fixture in
            let query = Task { try await fixture.application.connection(id: fixture.connection.id) }
            try await waitUntil { await fixture.gate.didEnterRead }
            query.cancel()

            let closed = CloseProbe()
            let closing = Task {
                await fixture.application.close()
                await closed.mark()
            }
            try await waitForBusy {
                _ = try await fixture.application.connections(after: nil, limit: 1)
            }
            #expect(!(await closed.value))

            await fixture.gate.releaseRead()
            await #expect(throws: Error.self) { _ = try await query.value }
            await closing.value
            #expect(await fixture.gate.didRelease)
        }
    }

    @Test func acceptedWriteCommitsAfterCallerCancellationAndCloseDrainsIt() async throws {
        try await withGatedFixture { fixture in
            let updated = fixture.connection.copy(revision: 2, name: "Committed")
            let write = Task {
                try await fixture.application.saveConnection(updated, expectedRevision: 1)
            }
            try await waitUntil { await fixture.gate.didEnterWrite }
            write.cancel()
            #expect(try await fixture.settings.connection(id: updated.id) == updated)

            let closed = CloseProbe()
            let closing = Task {
                await fixture.application.close()
                await closed.mark()
            }
            try await waitForBusy {
                _ = try await fixture.application.connections(after: nil, limit: 1)
            }
            #expect(!(await closed.value))
            #expect(!(await fixture.gate.didRelease))
            await fixture.gate.releaseWrite()
            _ = try await write.value
            await closing.value
        }
    }

    @Test func revokedReadWaitsForNonCooperativeStoreAndRejectsLateValue() async throws {
        try await withGatedFixture { fixture in
            let query = Task { try await fixture.application.connection(id: fixture.connection.id) }
            try await waitUntil { await fixture.gate.didEnterRead }
            let request = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: "settings.test", revision: 1,
                scope: .library, requestedAt: Date())
            _ = try await fixture.access.begin(request, expected: fixture.authorization)
            let snapshot = await fixture.access.snapshot()
            #expect(snapshot.phase == .maintenance)
            #expect(snapshot.activeLeases == 1)
            #expect(snapshot.activeReads == 1)
            #expect(snapshot.activeResources == 1)

            let quiesced = CloseProbe()
            let waiting = Task {
                try? await fixture.access.waitForQuiescence()
                await quiesced.mark()
            }
            try await Task.sleep(for: .milliseconds(20))
            #expect(!(await quiesced.value))
            await fixture.gate.releaseRead()
            await #expect(throws: Error.self) { _ = try await query.value }
            await waiting.value
            #expect(await quiesced.value)
        }
    }
}

private struct SettingsApplicationFixture: Sendable {
    let database: DatabaseQueue
    let authority: SQLiteLibraryAuthority
    let authorization: AgentLibraryAuthorization
    let settings: SQLiteAgentModelSettings
    let access: AgentLibraryAccess
    let scope: RuntimeScope
    let registry: RuntimeRegistry<AgentCapability>
    let application: AgentModelSettingsApplication
    let connection: AgentConfiguredConnection
    let model: AgentConfiguredModel
    let preset: AgentRoutePreset
    let adapterIdentity: AgentAdapterIdentity

    func registerModules(includeModel: Bool, includeConfiguration: Bool, includeDiscovery: Bool)
        async throws
    {
        if includeModel {
            try await registry.register(
                id: "fixture.model", value: .model(FixtureModelAdapter(identity: adapterIdentity)),
                scope: scope)
        }
        if includeConfiguration {
            try await registry.register(
                id: "fixture.configuration",
                value: .modelConfiguration(FixtureConfigurationProvider(identity: adapterIdentity)),
                scope: scope)
        }
        if includeDiscovery {
            try await registry.register(
                id: "fixture.discovery",
                value: .modelDiscovery(FixtureDiscoveryProvider(identity: adapterIdentity)), scope: scope)
        }
    }
}

private func withFixture(_ body: (SettingsApplicationFixture) async throws -> Void) async throws {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
    let database = try DatabaseQueue(configuration: configuration)
    let authority = try SQLiteLibraryAuthority(database: database)
    let authorization = try await authority.authorization()
    let settings = try SQLiteAgentModelSettings(database: database, libraryID: authority.libraryID)
    let access = try await AgentLibraryAccess.open(store: authority)
    let scope = RuntimeScope(kind: .library(access.libraryID))
    let registry = RuntimeRegistry<AgentCapability>()
    let adapterIdentity = AgentAdapterIdentity(id: "adapter.fixture", revision: 1)
    let connection = AgentConfiguredConnection(id: .init(), revision: 1, configurationRevision: 1, name: "Fixture", isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: .init(schema: fixtureSchema.identity, value: .object([:])), credential: nil)], discovery: nil, defaultInvocation: nil)
    let model = AgentConfiguredModel(id: .init(), revision: 1, authorizationRevision: 1, reference: .init(connectionID: connection.id, modelID: "fixture-model"), displayName: nil, isEnabled: true, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: adapterIdentity, endpointID: "primary", contextWindow: 4_096, maximumOutputTokens: nil, capabilities: [AgentModelCapabilityID.streamingText: .declared], configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: modelParameterSchema)], facts: [])
    let preset = AgentRoutePreset(id: RouteID(model.id.rawValue), revision: 1, name: "Fixture route", modelDescriptorID: model.id, invocationID: "default", maximumOutputTokens: 256, configuration: .init(schema: fixtureSchema.identity, value: .object([:])))
    let application = try AgentModelSettingsApplication(
        store: settings, registry: registry, access: access, scope: scope)
    let fixture = SettingsApplicationFixture(
        database: database, authority: authority, authorization: authorization, settings: settings,
        access: access, scope: scope, registry: registry, application: application,
        connection: connection, model: model, preset: preset, adapterIdentity: adapterIdentity)
    do {
        try await body(fixture)
    } catch {
        await application.close()
        await scope.dispose()
        await access.close()
        await settings.close()
        await authority.close()
        try? database.close()
        throw error
    }
    await application.close()
    await scope.dispose()
    await access.close()
    await settings.close()
    await authority.close()
    try database.close()
}

private func withGatedFixture(_ body: (GatedSettingsFixture) async throws -> Void) async throws {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
    let database = try DatabaseQueue(configuration: configuration)
    let authority = try SQLiteLibraryAuthority(database: database)
    let authorization = try await authority.authorization()
    let settings = try SQLiteAgentModelSettings(database: database, libraryID: authority.libraryID)
    let access = try await AgentLibraryAccess.open(store: authority)
    let scope = RuntimeScope(kind: .library(access.libraryID))
    let registry = RuntimeRegistry<AgentCapability>()
    let connection = AgentConfiguredConnection(id: .init(), revision: 1, configurationRevision: 1, name: "Gated", isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: .init(schema: fixtureSchema.identity, value: .object([:])), credential: nil)], discovery: nil, defaultInvocation: nil)
    let gate = StoreGate()
    let store = ForwardingSettingsStore(base: settings, gate: gate)
    let application = try AgentModelSettingsApplication(
        store: store, registry: registry, access: access, scope: scope)
    let fixture = GatedSettingsFixture(
        database: database, authority: authority, authorization: authorization,
        settings: settings, access: access, scope: scope, application: application,
        connection: connection, gate: gate)
    try await settings.saveConnection(connection, expectedRevision: nil, authorization: authorization)
    do {
        try await body(fixture)
    } catch {
        await gate.releaseRead()
        await gate.releaseWrite()
        await application.close()
        await scope.dispose()
        await access.close()
        await settings.close()
        await authority.close()
        try? database.close()
        throw error
    }
    await gate.releaseRead()
    await gate.releaseWrite()
    await application.close()
    await scope.dispose()
    await access.close()
    await settings.close()
    await authority.close()
    try database.close()
}

private let fixtureSchema = AgentConfigurationSchema(
    identity: .init(id: "fixture.schema", revision: 1), title: "Fixture",
    schema: .object([
        "type": .string("object"),
        "properties": .object([
            "model": .object(["type": .string("string")]),
            "temperature": .object(["type": .string("number")]),
        ]),
        "additionalProperties": .bool(false),
    ]),
    defaults: .object([:]))

private actor StoreGate {
    private(set) var didEnterRead = false
    private(set) var didEnterWrite = false
    private(set) var didRelease = false
    private var readOpen = false
    private var writeOpen = false
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRead() async {
        didEnterRead = true
        guard !readOpen else { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }

    func waitForWrite() async {
        didEnterWrite = true
        guard !writeOpen else { return }
        await withCheckedContinuation { writeWaiters.append($0) }
    }

    func releaseRead() {
        readOpen = true
        didRelease = true
        let waiters = readWaiters
        readWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func releaseWrite() {
        writeOpen = true
        didRelease = true
        let waiters = writeWaiters
        writeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor CloseProbe {
    private(set) var value = false
    func mark() { value = true }
}

private struct GatedSettingsFixture: Sendable {
    let database: DatabaseQueue
    let authority: SQLiteLibraryAuthority
    let authorization: AgentLibraryAuthorization
    let settings: SQLiteAgentModelSettings
    let access: AgentLibraryAccess
    let scope: RuntimeScope
    let application: AgentModelSettingsApplication
    let connection: AgentConfiguredConnection
    let gate: StoreGate
}

private final class ForwardingSettingsStore: AgentModelSettingsStore, @unchecked Sendable {
    let base: SQLiteAgentModelSettings
    let gate: StoreGate
    init(base: SQLiteAgentModelSettings, gate: StoreGate) {
        self.base = base
        self.gate = gate
    }
    func discoverySnapshot(connectionID: ConnectionID) async throws -> AgentModelDiscoverySnapshot? {
        try await base.discoverySnapshot(connectionID: connectionID)
    }
    func saveDiscoverySnapshot(
        _ value: AgentModelDiscoverySnapshot, expectedRevision: Int?,
        authorization: AgentLibraryAuthorization
    ) async throws {
        try await base.saveDiscoverySnapshot(value, expectedRevision: expectedRevision, authorization: authorization)
    }
    func connection(id: ConnectionID) async throws -> AgentConfiguredConnection? {
        let value = try await base.connection(id: id)
        await gate.waitForRead()
        return value
    }
    func model(id: ModelDescriptorID) async throws -> AgentConfiguredModel? {
        try await base.model(id: id)
    }
    func preset(id: RouteID) async throws -> AgentRoutePreset? { try await base.preset(id: id) }
    func connections(after: ConnectionID?, limit: Int) async throws -> [AgentConfiguredConnection] {
        try await base.connections(after: after, limit: limit)
    }
    func models(connectionID: ConnectionID?, after: ModelDescriptorID?, limit: Int) async throws
        -> [AgentConfiguredModel]
    { try await base.models(connectionID: connectionID, after: after, limit: limit) }
    func presets(modelID: ModelDescriptorID?, after: RouteID?, limit: Int) async throws
        -> [AgentRoutePreset]
    { try await base.presets(modelID: modelID, after: after, limit: limit) }
    func ensureConversationDefault(authorization: AgentLibraryAuthorization) async throws -> AgentRouteBinding? {
        try await base.ensureConversationDefault(authorization: authorization)
    }
    func bindings(scope: AgentRouteScope) async throws -> [AgentRouteBinding] {
        try await base.bindings(scope: scope)
    }
    func select(
        purpose: String, explicitRouteID: RouteID?, workspaceID: WorkspaceID?
    ) async throws -> AgentModelRouteSelection {
        try await base.select(
            purpose: purpose, explicitRouteID: explicitRouteID, workspaceID: workspaceID)
    }
    func candidate(routeID: RouteID) async throws -> AgentModelRouteCandidate {
        try await base.candidate(routeID: routeID)
    }
    func saveConnection(
        _ value: AgentConfiguredConnection, expectedRevision: Int?,
        authorization: AgentLibraryAuthorization
    ) async throws {
        try await base.saveConnection(
            value, expectedRevision: expectedRevision, authorization: authorization)
        await gate.waitForWrite()
    }
    func saveModel(
        _ value: AgentConfiguredModel, expectedRevision: Int?, authorization: AgentLibraryAuthorization
    ) async throws {
        try await base.saveModel(
            value, expectedRevision: expectedRevision, authorization: authorization)
    }
    func savePreset(
        _ value: AgentRoutePreset, expectedRevision: Int?, authorization: AgentLibraryAuthorization
    ) async throws {
        try await base.savePreset(
            value, expectedRevision: expectedRevision, authorization: authorization)
    }
    func savePoolModel(
        _ model: AgentConfiguredModel, preset: AgentRoutePreset, expectedModelRevision: Int?,
        expectedPresetRevision: Int?, authorization: AgentLibraryAuthorization
    ) async throws {
        try await base.savePoolModel(
            model, preset: preset, expectedModelRevision: expectedModelRevision,
            expectedPresetRevision: expectedPresetRevision, authorization: authorization)
    }
    func saveBinding(
        _ value: AgentRouteBinding, expectedRevision: Int?, authorization: AgentLibraryAuthorization
    ) async throws {
        try await base.saveBinding(
            value, expectedRevision: expectedRevision, authorization: authorization)
    }
    func deleteConnection(
        id: ConnectionID, expectedRevision: Int, authorization: AgentLibraryAuthorization
    ) async throws {
        try await base.deleteConnection(
            id: id, expectedRevision: expectedRevision, authorization: authorization)
    }
    func deleteModel(
        id: ModelDescriptorID, expectedRevision: Int, authorization: AgentLibraryAuthorization
    ) async throws {
        try await base.deleteModel(
            id: id, expectedRevision: expectedRevision, authorization: authorization)
    }
    func deletePreset(id: RouteID, expectedRevision: Int, authorization: AgentLibraryAuthorization)
        async throws
    {
        try await base.deletePreset(
            id: id, expectedRevision: expectedRevision, authorization: authorization)
    }
    func deleteBinding(
        scope: AgentRouteScope, purpose: String, expectedRevision: Int,
        authorization: AgentLibraryAuthorization
    ) async throws {
        try await base.deleteBinding(
            scope: scope, purpose: purpose, expectedRevision: expectedRevision,
            authorization: authorization)
    }
}

private struct FixtureModelAdapter: AgentModelAdapter {
    let identity: AgentAdapterIdentity
    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        fatalError("Unused in settings tests")
    }
    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        fatalError("Unused in settings tests")
    }
    func replay(
        _ messages: [AgentModelMessage], from source: AgentModelRoute, to target: AgentModelRoute,
        boundary: AgentReplayBoundary
    ) throws -> AgentReplayDecision { fatalError("Unused in settings tests") }
}

private struct FixtureConfigurationProvider: AgentModelConfigurationProvider {
    let identity: AgentAdapterIdentity
    func descriptor(for invocation: AgentModelInvocationSpec) throws -> AgentModelConfigurationDescriptor {
        .init(
            adapter: identity, title: "Fixture", credential: .none, connection: fixtureSchema,
            route: fixtureSchema)
    }
    func configuration(for candidate: AgentModelRouteCandidate) throws -> JSONValue {
        .object(["model": .string(candidate.model.modelID)])
    }
}

private struct FixtureDiscoveryProvider: AgentModelDiscoveryProvider {
    let identity: AgentAdapterIdentity
    func descriptor() throws -> AgentModelDiscoveryDescriptor {
        .init(
            adapter: identity, title: "Fixture discovery", credential: .none, connection: fixtureSchema)
    }
    func discover(connection: AgentConfiguredConnection) -> AgentModelDiscoveryOperation {
        let producer = Task<[AgentDiscoveredModel], any Error> { [connection] in
            [AgentDiscoveredModel(id: connection.name)]
        }
        return AgentModelDiscoveryOperation(producer: producer, cancelAndDrain: {})
    }
}

extension AgentConfiguredConnection {
    fileprivate func copy(
        id: ConnectionID? = nil, revision: Int? = nil, configurationRevision: Int? = nil,
        name: String? = nil
    ) -> Self {
        .init(id: id ?? self.id, revision: revision ?? self.revision,
              configurationRevision: configurationRevision ?? self.configurationRevision,
              name: name ?? self.name, isEnabled: isEnabled, definitionID: definitionID,
              endpoints: endpoints, discovery: discovery, defaultInvocation: defaultInvocation)
    }
}

extension AgentRoutePreset {
    fileprivate func copy(revision: Int? = nil, configuration: AgentConfigurationValue? = nil) -> Self {
        .init(id: id, revision: revision ?? self.revision, name: name, modelDescriptorID: modelDescriptorID, invocationID: "default", maximumOutputTokens: maximumOutputTokens, configuration: configuration ?? self.configuration)
    }
}

private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            throw MiraError(.timeout, "Fixture gate did not open.")
        }
        await Task.yield()
    }
}

private func waitForBusy(_ operation: @escaping @Sendable () async throws -> Void) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        do {
            try await operation()
        } catch let error as MiraError where error.code == .busy {
            return
        } catch {
            // The operation may race the close turn; retry until the closed
            // state is observable, while preserving the bounded wait.
        }
        await Task.yield()
    }
    throw MiraError(.timeout, "The application close state was not observed.")
}
