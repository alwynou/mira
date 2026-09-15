import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Scoped model discovery", .timeLimit(.minutes(1)))
struct AgentModelDiscoveryServiceTests {
    @Test func arbitraryModuleReturnsAdvisoryIdentitiesWithoutWritingSettings() async throws {
        try await withFixture { f in
            await f.probe.releaseProducer()
            await f.probe.releaseDrain()
            let result = try await f.service.discover(connectionID: f.connection.id, adapter: f.provider.identity)
            #expect(result.connection == f.connection)
            #expect(result.adapter.id == "fixture.discovery.custom")
            #expect(result.models.map(\.id) == ["alpha", "zeta"])
            #expect(try await f.settings.models(connectionID: nil, after: nil, limit: 128).isEmpty)
            #expect(try await f.settings.bindings(scope: .global).isEmpty)
            let snapshot = try #require(try await f.settings.discoverySnapshot(connectionID: f.connection.id))
            #expect(snapshot.revision == 1)
            #expect(snapshot.configurationRevision == f.connection.configurationRevision)
            #expect(snapshot.adapter == f.provider.identity)
            #expect(snapshot.models == result.models)
            #expect(await f.access.snapshot().activeLeases == 0)
            #expect(await f.probe.drainCount == 1)
        }
    }

    @Test func successWaitsForUnderlyingDrainBeforePublishing() async throws {
        try await withFixture { f in
            await f.probe.releaseProducer()
            let finished = DiscoveryFlag()
            let task = Task {
                let result = try await f.service.discover(connectionID: f.connection.id, adapter: f.provider.identity)
                await finished.set()
                return result
            }
            do {
                try await wait { await f.probe.drainStarted }
                #expect(await finished.value == false)
                #expect(await f.access.snapshot().activeResources == 1)
                await f.probe.releaseDrain()
                _ = try await task.value
                #expect(await finished.value)
            } catch {
                await f.probe.releaseDrain()
                _ = await task.result
                throw error
            }
        }
    }

    @Test(arguments: ["configuration", "delete"])
    func editedConnectionRejectsLateResponse(change: String) async throws {
        try await withFixture { f in
            await f.probe.releaseDrain()
            let task = Task {
                try await f.service.discover(connectionID: f.connection.id, adapter: f.provider.identity)
            }
            do {
                try await wait { await f.probe.started }
                if change == "delete" {
                    try await f.settings.deleteConnection(id: f.connection.id, expectedRevision: 1, authorization: f.authority.authorization())
                } else {
                    let changed = AgentConfiguredConnection(id: f.connection.id, revision: 2, configurationRevision: change == "configuration" ? 2 : 1, name: "Edited", isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: change == "configuration"
                            ? .init(schema: discoverySchema.identity, value: .object(["marker": .string("new")]))
                            : f.connection.endpoints[0].configuration, credential: nil)], discovery: f.connection.discovery, defaultInvocation: nil)
                    try await f.settings.saveConnection(changed, expectedRevision: 1, authorization: f.authority.authorization())
                }
                await f.probe.releaseProducer()
                await expectCode(.conflict) { _ = try await task.value }
                #expect(await f.access.snapshot().activeLeases == 0)
            } catch {
                await f.probe.releaseProducer()
                _ = await task.result
                throw error
            }
        }
    }

    @Test(arguments: ["close", "scope", "maintenance", "timeout"])
    func stoppingRetainsOwnersUntilActualProducerAndTransportEnd(reason: String) async throws {
        try await withFixture(timeout: reason == "timeout" ? .milliseconds(100) : .seconds(30)) { f in
            let finished = DiscoveryFlag()
            let task = Task {
                let outcome = await Task {
                    try await f.service.discover(connectionID: f.connection.id, adapter: f.provider.identity)
                }.result
                await finished.set()
                return outcome
            }
            do {
                try await wait { await f.probe.started }
                var closer: Task<Void, Never>?
                switch reason {
                case "close": closer = Task { await f.service.close() }
                case "scope": closer = Task { await f.scope.dispose() }
                case "maintenance":
                    _ = try await f.access.begin(
                        .init(
                            id: UUID(), namespace: "fixture.discovery.maintenance", revision: 1, scope: .library,
                            requestedAt: Date()),
                        expected: f.authority.authorization())
                default: break
                }
                try await wait { await f.probe.drainStarted }
                #expect(await finished.value == false)
                #expect(await f.access.snapshot().activeLeases == 1)
                await f.probe.releaseDrain()
                #expect(await finished.value == false)
                await f.probe.releaseProducer()
                let outcome = await task.value
                if case .success = outcome { Issue.record("Stopped discovery must not publish results.") }
                if reason == "timeout", case .failure(let error) = outcome {
                    #expect((error as? MiraError)?.code == .timeout)
                }
                await closer?.value
                #expect(await f.access.snapshot().activeLeases == 0)
                #expect(await f.probe.drainCount == 1)
            } catch {
                await f.probe.releaseDrain()
                await f.probe.releaseProducer()
                _ = await task.value
                throw error
            }
        }
    }

    @Test func callerCancellationCannotAbandonProducer() async throws {
        try await withFixture { f in
            let task = Task {
                try await f.service.discover(connectionID: f.connection.id, adapter: f.provider.identity)
            }
            do {
                try await wait { await f.probe.started }
                task.cancel()
                try await wait { await f.probe.drainStarted }
                #expect(await f.access.snapshot().activeLeases == 1)
                await f.probe.releaseDrain()
                await f.probe.releaseProducer()
                await #expect(throws: CancellationError.self) { _ = try await task.value }
                #expect(await f.access.snapshot().activeLeases == 0)
            } catch {
                await f.probe.releaseDrain()
                await f.probe.releaseProducer()
                _ = await task.result
                throw error
            }
        }
    }

    @Test func concurrencyAndExactAdapterSelectionFailWithoutExtraProducer() async throws {
        try await withFixture { f in
            await expectCode(.notFound) {
                _ = try await f.service.discover(
                    connectionID: f.connection.id, adapter: .init(id: f.provider.identity.id, revision: 2))
            }
            #expect(await f.probe.started == false)
            let task = Task {
                try await f.service.discover(connectionID: f.connection.id, adapter: f.provider.identity)
            }
            do {
                try await wait { await f.probe.started }
                await expectCode(.busy) {
                    _ = try await f.service.discover(connectionID: f.connection.id, adapter: f.provider.identity)
                }
                await f.probe.releaseDrain()
                await f.probe.releaseProducer()
                _ = try await task.value
                await f.service.close()
                await expectCode(.cancelled) {
                    _ = try await f.service.discover(connectionID: f.connection.id, adapter: f.provider.identity)
                }
            } catch {
                await f.probe.releaseDrain()
                await f.probe.releaseProducer()
                _ = await task.result
                throw error
            }
        }
    }

    @Test(arguments: ["duplicate", "invalid", "oversize"])
    func malformedProviderResultsAreRejectedAndDrained(fault: String) async throws {
        let models: [AgentDiscoveredModel] =
            switch fault {
            case "duplicate": [.init(id: "same"), .init(id: "same")]
            case "invalid": [.init(id: "bad id")]
            default: (0..<2_001).map { .init(id: "model-\($0)") }
            }
        try await withFixture(models: models) { f in
            await f.probe.releaseProducer()
            await f.probe.releaseDrain()
            await expectCode(fault == "invalid" ? .malformedStream : .outputLimit) {
                _ = try await f.service.discover(connectionID: f.connection.id, adapter: f.provider.identity)
            }
            let snapshotAfterFailure = try await f.settings.discoverySnapshot(connectionID: f.connection.id)
            #expect(snapshotAfterFailure == nil)
            #expect(await f.probe.drainCount == 1)
            #expect(await f.access.snapshot().activeLeases == 0)
        }
    }

    @Test func duplicateDiscoveryIDsRejectCatalogAndReleaseScopeLeases() async throws {
        try await withFixture { f in
            try await f.registry.register(id: "fixture.second", value: .modelDiscovery(f.provider), scope: f.scope)
            await expectCode(.configuration) {
                _ = try await f.service.discover(connectionID: f.connection.id, adapter: f.provider.identity)
            }
            #expect(await f.probe.started == false)
            #expect(await f.access.snapshot().activeLeases == 0)
        }
    }
}

private let discoverySchema = AgentConfigurationSchema(
    identity: .init(id: "fixture.connection", revision: 1), title: "Fixture connection",
    schema: .object([
        "type": .string("object"), "properties": .object(["marker": .object(["type": .string("string")])]),
        "additionalProperties": .bool(false),
    ]),
    defaults: .object([:]))

private struct DiscoveryProvider: AgentModelDiscoveryProvider {
    let identity = AgentAdapterIdentity(id: "fixture.discovery.custom", revision: 1)
    let probe: DiscoveryProbe
    let models: [AgentDiscoveredModel]
    func descriptor() throws -> AgentModelDiscoveryDescriptor {
        .init(adapter: identity, title: "Custom discovery", credential: .none, connection: discoverySchema)
    }
    func discover(connection: AgentConfiguredConnection) -> AgentModelDiscoveryOperation {
        let producer = Task<[AgentDiscoveredModel], any Error> {
            await probe.produce()
            return models
        }
        return .init(producer: producer) { await probe.drain() }
    }
}

private actor DiscoveryProbe {
    var started = false
    var drainStarted = false
    var drainCount = 0
    private var producerOpen = false, drainOpen = false
    private var producerWaiters: [CheckedContinuation<Void, Never>] = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    func produce() async {
        started = true
        if !producerOpen { await withCheckedContinuation { producerWaiters.append($0) } }
    }
    func drain() async {
        drainStarted = true
        drainCount += 1
        if !drainOpen { await withCheckedContinuation { drainWaiters.append($0) } }
    }
    func releaseProducer() {
        producerOpen = true
        let waiters = producerWaiters
        producerWaiters = []
        for waiter in waiters { waiter.resume() }
    }
    func releaseDrain() {
        drainOpen = true
        let waiters = drainWaiters
        drainWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}
private actor DiscoveryFlag {
    var value = false
    func set() { value = true }
}
private struct DiscoveryFixture {
    let settings: SQLiteAgentModelSettings
    let authority: SQLiteLibraryAuthority
    let access: AgentLibraryAccess
    let scope: RuntimeScope
    let registry: RuntimeRegistry<AgentCapability>
    let connection: AgentConfiguredConnection
    let probe: DiscoveryProbe
    let provider: DiscoveryProvider
    let service: AgentModelDiscoveryService
}
private func withFixture(
    timeout: Duration = .seconds(30), models: [AgentDiscoveredModel] = [.init(id: "zeta"), .init(id: "alpha")],
    _ body: (DiscoveryFixture) async throws -> Void
) async throws {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
    let database = try DatabaseQueue(configuration: configuration)
    let authority = try SQLiteLibraryAuthority(database: database)
    let settings = try SQLiteAgentModelSettings(database: database, libraryID: authority.libraryID)
    let access = try await AgentLibraryAccess.open(store: authority)
    let scope = RuntimeScope(kind: .library(access.libraryID))
    let registry = RuntimeRegistry<AgentCapability>()
    let probe = DiscoveryProbe()
    let provider = DiscoveryProvider(probe: probe, models: models)
    let connection = AgentConfiguredConnection(id: .init(), revision: 1, configurationRevision: 1, name: "Synthetic", isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: .init(schema: discoverySchema.identity, value: .object([:])), credential: nil)], discovery: .init(adapter: provider.identity, endpointID: "primary"), defaultInvocation: nil)
    let service = try AgentModelDiscoveryService(
        settings: settings, registry: registry, access: access, scope: scope,
        maximumConcurrentRequests: 1, timeout: timeout)
    do {
        try await settings.saveConnection(connection, expectedRevision: nil, authorization: authority.authorization())
        try await registry.register(id: "fixture.discovery", value: .modelDiscovery(provider), scope: scope)
        try await body(
            .init(
                settings: settings, authority: authority, access: access, scope: scope, registry: registry,
                connection: connection, probe: probe, provider: provider, service: service))
    } catch {
        await probe.releaseProducer()
        await probe.releaseDrain()
        await service.close()
        await scope.dispose()
        await access.close()
        await settings.close()
        await authority.close()
        try? database.close()
        throw error
    }
    await probe.releaseProducer()
    await probe.releaseDrain()
    await service.close()
    await scope.dispose()
    await access.close()
    await settings.close()
    await authority.close()
    try database.close()
}
private func wait(_ condition: () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard clock.now < deadline else {
            throw MiraError(.timeout, "Discovery fixture did not reach the expected boundary.")
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}
private func expectCode(_ code: MiraError.Code, _ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Expected discovery failure.")
    } catch let error as MiraError { #expect(error.code == code) } catch {
        Issue.record("Expected a classified discovery error, received \(error).")
    }
}
