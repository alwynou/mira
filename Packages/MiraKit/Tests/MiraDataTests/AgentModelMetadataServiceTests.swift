import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Scoped model metadata", .timeLimit(.minutes(1)))
struct AgentModelMetadataServiceTests {
    @Test func refreshPublishesAndSubsequentSnapshotReadsCachedDocument() async throws {
        try await withFixture { f in
            await f.probe.releaseProducer()
            let result = try await f.service.refresh(sourceID: f.sourceID)
            #expect(result.revision == 1)
            #expect(result.document == f.document)
            #expect(try await f.service.snapshot(sourceID: f.sourceID) == result)
            #expect(await f.probe.started)
            #expect(await f.probe.drainCount == 1)
            #expect(await f.access.snapshot().activeLeases == 0)
        }
    }

    @Test func malformedRefreshRetainsPreviouslyPublishedCache() async throws {
        try await withFixture(document: .init(
            schema: .init(id: "metadata.document", revision: 1), sourceRevision: "bad",
            observedAt: Date(timeIntervalSince1970: 1_800_000_000), payload: .string("not an object"))) { f in
            let cached = f.snapshot(revision: 1, marker: "cached")
            try await f.store.publish(cached, expectedRevision: nil, updates: [], authorization: f.authorization)
            await f.probe.releaseProducer()
            await #expect(throws: MiraError.self) {
                _ = try await f.service.refresh(sourceID: f.sourceID)
            }
            #expect(try await f.store.snapshot(sourceID: f.sourceID, authorization: f.authorization) == cached)
            #expect(await f.probe.drainCount == 1)
            #expect(await f.access.snapshot().activeLeases == 0)
        }
    }

    @Test func timeoutClosesOwnedOperationAndDrainsCancellationInsensitiveProducer() async throws {
        try await withFixture(timeout: .milliseconds(40)) { f in
            let task = Task { () -> Result<AgentModelMetadataSnapshot, any Error> in
                do { return .success(try await f.service.refresh(sourceID: f.sourceID)) }
                catch { return .failure(error) }
            }
            try await wait { await f.probe.started }
            try await wait { await f.probe.drainStarted }
            let outcome = await task.value
            guard case .failure(let error) = outcome else {
                Issue.record("A blocked metadata producer must time out.")
                return
            }
            #expect((error as? MiraError)?.code == .timeout)
            #expect(await f.probe.finished)
            #expect(await f.probe.drainCount == 1)
            #expect(await f.access.snapshot().activeLeases == 0)
        }
    }

    @Test func scopeCloseCancelsAndDrainsInFlightRefresh() async throws {
        try await withFixture { f in
            let task = Task { () -> Result<AgentModelMetadataSnapshot, any Error> in
                do { return .success(try await f.service.refresh(sourceID: f.sourceID)) }
                catch { return .failure(error) }
            }
            try await wait { await f.probe.started }
            let close = Task { await f.scope.dispose() }
            try await wait { await f.probe.drainStarted }
            let outcome = await task.value
            _ = await close.value
            guard case .failure = outcome else {
                Issue.record("A scope close must cancel an in-flight metadata refresh.")
                return
            }
            #expect(await f.probe.finished)
            #expect(await f.probe.drainCount == 1)
            #expect(await f.access.snapshot().activeLeases == 0)
        }
    }

    @Test func refreshCASConflictLeavesCompetingSnapshotUntouched() async throws {
        try await withFixture { f in
            let task = Task { () -> Result<AgentModelMetadataSnapshot, any Error> in
                do { return .success(try await f.service.refresh(sourceID: f.sourceID)) }
                catch { return .failure(error) }
            }
            try await wait { await f.probe.started }
            let competing = f.snapshot(revision: 1, marker: "competing")
            try await f.store.publish(competing, expectedRevision: nil, updates: [], authorization: f.authorization)
            await f.probe.releaseProducer()
            let outcome = await task.value
            guard case .failure(let error) = outcome else {
                Issue.record("A concurrent metadata generation must fail the refresh CAS.")
                return
            }
            #expect((error as? MiraError)?.code == .conflict)
            #expect(try await f.store.snapshot(sourceID: f.sourceID, authorization: f.authorization) == competing)
            #expect(await f.probe.finished)
            #expect(await f.access.snapshot().activeLeases == 0)
        }
    }
}

private struct MetadataServiceProvider: AgentModelMetadataProvider {
    let identity = AgentAdapterIdentity(id: "fixture.metadata", revision: 1)
    let probe: MetadataServiceProbe
    let document: AgentModelMetadataDocument
    func fetch() -> AgentModelMetadataOperation {
        let producer = Task<AgentModelMetadataDocument, any Error> {
            await probe.produce()
            return document
        }
        return .init(producer: producer) { await probe.drain() }
    }
    func updates(document: AgentModelMetadataDocument, connections: [AgentConfiguredConnection],
                 models: [AgentConfiguredModel]) throws -> [AgentModelMetadataUpdate] { [] }
}

private actor MetadataServiceProbe {
    var started = false
    var drainStarted = false
    var drainCount = 0
    var finished = false
    private var producerOpen = false
    private var producerWaiters: [CheckedContinuation<Void, Never>] = []

    func produce() async {
        started = true
        if !producerOpen { await withCheckedContinuation { producerWaiters.append($0) } }
        finished = true
    }
    func drain() {
        drainStarted = true
        drainCount += 1
        producerOpen = true
        let waiters = producerWaiters
        producerWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func releaseProducer() {
        producerOpen = true
        let waiters = producerWaiters
        producerWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private struct MetadataServiceFixture: Sendable {
    let settings: SQLiteAgentModelSettings
    let store: SQLiteAgentModelMetadataStore
    let authority: SQLiteLibraryAuthority
    let authorization: AgentLibraryAuthorization
    let access: AgentLibraryAccess
    let scope: RuntimeScope
    let registry: RuntimeRegistry<AgentCapability>
    let service: AgentModelMetadataService
    let probe: MetadataServiceProbe
    let sourceID: String
    let document: AgentModelMetadataDocument

    func snapshot(revision: Int, marker: String) -> AgentModelMetadataSnapshot {
        .init(sourceID: sourceID, revision: revision, document: .init(
            schema: .init(id: "metadata.document", revision: 1), sourceRevision: "v\(revision)",
            observedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(revision)),
            payload: .object(["marker": .string(marker)])))
    }
}

private func withFixture(
    timeout: Duration = .seconds(5),
    document: AgentModelMetadataDocument = .init(
        schema: .init(id: "metadata.document", revision: 1), sourceRevision: "v1",
        observedAt: Date(timeIntervalSince1970: 1_800_000_000),
        payload: .object(["marker": .string("remote")])) ,
    _ body: (MetadataServiceFixture) async throws -> Void
) async throws {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
    let database = try DatabaseQueue(configuration: configuration)
    let authority = try SQLiteLibraryAuthority(database: database)
    let authorization = try await authority.authorization()
    let settings = try SQLiteAgentModelSettings(database: database, libraryID: authority.libraryID)
    let store = try SQLiteAgentModelMetadataStore(database: database, libraryID: authority.libraryID)
    let access = try await AgentLibraryAccess.open(store: authority)
    let scope = RuntimeScope(kind: .library(access.libraryID))
    let registry = RuntimeRegistry<AgentCapability>()
    let probe = MetadataServiceProbe()
    let provider = MetadataServiceProvider(probe: probe, document: document)
    let sourceID = "fixture.metadata"
    let connection = AgentConfiguredConnection(
        id: .init(), revision: 1, configurationRevision: 1, name: "Metadata service fixture", isEnabled: true,
        definitionID: nil,
        endpoints: [.init(id: "primary", configuration: .init(
            schema: .init(id: "metadata.connection", revision: 1), value: .object([:])), credential: nil)],
        discovery: nil, defaultInvocation: nil)
    try await settings.saveConnection(connection, expectedRevision: nil, authorization: authorization)
    try await registry.register(id: sourceID, value: .modelMetadata(provider), scope: scope)
    let service = try AgentModelMetadataService(settings: settings, store: store, registry: registry,
                                                access: access, scope: scope, timeout: timeout)
    let fixture = MetadataServiceFixture(settings: settings, store: store, authority: authority,
                                         authorization: authorization, access: access, scope: scope,
                                         registry: registry, service: service, probe: probe,
                                         sourceID: sourceID, document: document)
    do {
        try await body(fixture)
    } catch {
        await probe.releaseProducer()
        await service.close()
        await scope.dispose()
        await access.close()
        await settings.close()
        await authority.close()
        try? database.close()
        throw error
    }
    await probe.releaseProducer()
    await service.close()
    await scope.dispose()
    await access.close()
    await settings.close()
    await authority.close()
    try database.close()
}

private func wait(_ condition: @escaping () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard clock.now < deadline else { throw MiraError(.timeout, "Metadata fixture did not reach the expected boundary.") }
        try await Task.sleep(for: .milliseconds(1))
    }
}
