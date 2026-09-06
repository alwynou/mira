import Foundation
import Testing
import MiraCore
import MiraData

struct MiraApplicationTests {
    @Test func failedFinalizationRetainsReplyAndCanBeRetriedWithoutCallingModel() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.cleanup() }
        let fault = FaultInjectingStore(fixture.store)
        let app = try MiraApplication(store: fault, provider: fixture.provider)
        let conversationID = try await app.createConversation(workspaceID: nil)
        let id = try await app.send(conversationID: conversationID, text: "retain this", routeID: fixture.route.id)
        try await eventually { fixture.provider.requestCount == 1 }
        fixture.provider.yield(.textDelta("complete but not saved"), for: id)
        fixture.provider.complete(id)
        for _ in 0..<400 {
            if try await app.conversation(conversationID).pendingSaveIDs.contains(id) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let pending = try await app.conversation(conversationID)
        #expect(pending.pendingSaveIDs == [id])
        #expect(pending.drafts.first?.text == "complete but not saved")
        #expect(await app.shutdown() == false)
        fault.allowFinalization()
        try await app.retryPendingSave(id)
        let saved = try await app.conversation(conversationID)
        #expect(saved.pendingSaveIDs.isEmpty)
        #expect(saved.executions.last?.status == .completed)
        #expect(saved.messages.last?.text == "complete but not saved")
        #expect(fixture.provider.requestCount == 1)
        #expect(await app.shutdown())
    }

    @Test func shutdownRejectsNewRequestsAndEmptyModelOutputFails() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.cleanup() }
        let app = try MiraApplication(store: fixture.store, provider: fixture.provider)
        let conversationID = try await app.createConversation(workspaceID: nil)
        let id = try await app.send(conversationID: conversationID, text: "empty", routeID: fixture.route.id)
        try await eventually { fixture.provider.requestCount == 1 }
        fixture.provider.complete(id)
        try await eventually { try fixture.store.executions(in: conversationID).last?.status == .failed }
        #expect(await app.shutdown())
        await #expect(throws: MiraError.self) { try await app.send(conversationID: conversationID, text: "too late", routeID: fixture.route.id) }
        await #expect(throws: MiraError.self) { try await app.retry(id, routeID: fixture.route.id) }
        #expect(try fixture.store.messages(in: conversationID).count == 1)
    }

    @Test func persistsRequestBeforeProviderAndRecoversLatestCheckpointOnCancellation() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.cleanup() }
        let app = try MiraApplication(store: fixture.store, provider: fixture.provider)
        let conversationID = try await app.createConversation(workspaceID: nil)
        let id = try await app.send(conversationID: conversationID, text: "synthetic first input", routeID: fixture.route.id)
        try await eventually { fixture.provider.requestCount == 1 }
        #expect(fixture.provider.snapshotWasDurableAtDispatch)
        fixture.provider.yield(.textDelta("durable partial"), for: id)
        try await eventually { try fixture.store.draft(for: id)?.text == "durable partial" }
        await app.cancel(id)
        try await eventually { try fixture.store.executions(in: conversationID).first?.status == .cancelled }
        let messages = try fixture.store.messages(in: conversationID)
        #expect(messages.map(\.text) == ["synthetic first input", "durable partial"])
        #expect(messages.last?.status == .interrupted)
        #expect(try fixture.store.draft(for: id) == nil)
        #expect(try fixture.store.request(for: id)?.messages.map(\.text) == ["synthetic first input"])
        await app.shutdown()
    }

    @Test func retriesWithoutDuplicatingUserOrRetainingFailedAnswerInNextContext() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.cleanup() }
        let app = try MiraApplication(store: fixture.store, provider: fixture.provider)
        let conversationID = try await app.createConversation(workspaceID: nil)
        let first = try await app.send(conversationID: conversationID, text: "question one", routeID: fixture.route.id)
        try await eventually { fixture.provider.requestCount == 1 }
        fixture.provider.yield(.textDelta("wrong partial"), for: first)
        fixture.provider.fail(MiraError(.network, "Connection was interrupted."), for: first)
        try await eventually { try fixture.store.executions(in: conversationID).last?.status == .interrupted }
        let replacement = try await app.retry(first, routeID: fixture.route.id)
        try await eventually { fixture.provider.requestCount == 2 }
        fixture.provider.yield(.textDelta("correct complete answer"), for: replacement)
        fixture.provider.yield(.usage(.init(inputTokens: 12, outputTokens: 8)), for: replacement)
        fixture.provider.complete(replacement)
        try await eventually { try fixture.store.executions(in: conversationID).last?.status == .completed }
        #expect(try fixture.store.messages(in: conversationID).filter { $0.role == .user }.count == 1)
        let next = try await app.send(conversationID: conversationID, text: "question two", routeID: fixture.route.id)
        try await eventually { fixture.provider.requestCount == 3 }
        #expect(try fixture.store.request(for: next)?.messages.map(\.text) == ["question one", "correct complete answer", "question two"])
        await app.shutdown()
    }

    @Test func blocksIncompleteRouteBeforeCommitAndPrivateWorkspaceBeforeNetwork() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.cleanup() }
        let app = try MiraApplication(store: fixture.store, provider: fixture.provider)
        var unknownModel = fixture.configuration.model
        unknownModel.id = .init()
        unknownModel.modelID = "fixture-incomplete"
        unknownModel.contextWindow = nil
        unknownModel.revision = 1
        try fixture.store.saveModel(unknownModel, expectedRevision: nil)
        var unknown = fixture.configuration.route
        unknown.id = .init()
        unknown.modelDescriptorID = unknownModel.id
        unknown.revision = 1
        try await app.saveRoute(unknown, expectedRevision: nil)
        let inbox = try await app.createConversation(workspaceID: nil)
        await #expect(throws: MiraError.self) { try await app.send(conversationID: inbox, text: "secret", routeID: unknown.id) }
        #expect(try fixture.store.messages(in: inbox).isEmpty)
        let workspace = try await app.createWorkspace(name: "Private", background: "private background", allowsRemoteSend: false)
        let conversationID = try await app.createConversation(workspaceID: workspace)
        await #expect(throws: MiraError.self) { try await app.send(conversationID: conversationID, text: "private message", routeID: fixture.route.id) }
        #expect(fixture.provider.requestCount == 0)
        #expect(try fixture.store.messages(in: conversationID).isEmpty)
        #expect(try fixture.store.executions(in: conversationID).isEmpty)
        await app.shutdown()
    }

    @Test func concurrentWindowSendsAreBoundedAndRouteMutationCancelsExecution() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.cleanup() }
        let app = try MiraApplication(store: fixture.store, provider: fixture.provider)
        let firstConversation = try await app.createConversation(workspaceID: nil)
        let secondConversation = try await app.createConversation(workspaceID: nil)
        let thirdConversation = try await app.createConversation(workspaceID: nil)
        _ = try await app.send(conversationID: firstConversation, text: "one", routeID: fixture.route.id)
        await #expect(throws: MiraError.self) { try await app.send(conversationID: firstConversation, text: "duplicate", routeID: fixture.route.id) }
        _ = try await app.send(conversationID: secondConversation, text: "two", routeID: fixture.route.id)
        await #expect(throws: MiraError.self) { try await app.send(conversationID: thirdConversation, text: "three", routeID: fixture.route.id) }
        #expect(try fixture.store.messages(in: firstConversation).count == 1)
        #expect(try fixture.store.messages(in: thirdConversation).isEmpty)
        var changed = fixture.configuration.model
        changed.revision += 1
        changed.modelID = "new-model"
        try await app.saveModel(changed, expectedRevision: fixture.configuration.model.revision)
        await app.shutdown()
        #expect(try fixture.store.executions(in: firstConversation).allSatisfy { $0.status == .cancelled })
        #expect(try fixture.store.executions(in: secondConversation).allSatisfy { $0.status == .cancelled })
    }

    @Test func staleProbeResultsCannotOverwriteChangedModelOrRouteConfiguration() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.cleanup() }
        let app = try MiraApplication(store: fixture.store, provider: fixture.provider)
        let observation = ProbeObservation(type: .text, state: .verified)

        var changedModel = fixture.configuration.model
        changedModel.revision += 1
        changedModel.modelID = "changed-before-probe"
        try await app.saveModel(changedModel, expectedRevision: fixture.configuration.model.revision)
        await #expect(throws: MiraError.self) { try await app.saveProbe(observation, for: fixture.route) }
        #expect(try fixture.store.modelConfiguration().models.first?.probeObservation == nil)

        let current = try fixture.store.modelConfiguration()
        let currentSnapshot = try current.snapshot(routeID: fixture.route.id)
        var changedRoute = try #require(current.routes.first)
        changedRoute.revision += 1
        changedRoute.maxOutputTokens += 1
        try await app.saveRoute(changedRoute, expectedRevision: current.routes.first?.revision)
        await #expect(throws: MiraError.self) { try await app.saveProbe(observation, for: currentSnapshot) }
        #expect(try fixture.store.modelConfiguration().models.first?.probeObservation == nil)

        let latest = try fixture.store.modelConfiguration()
        let latestSnapshot = try latest.snapshot(routeID: fixture.route.id)
        var changedConnection = try #require(latest.connections.first)
        changedConnection.revision += 1
        try await app.saveConnection(changedConnection, expectedRevision: latest.connections.first?.revision)
        await #expect(throws: MiraError.self) { try await app.saveProbe(observation, for: latestSnapshot) }
        #expect(try fixture.store.modelConfiguration().models.first?.probeObservation == nil)
        await app.shutdown()
    }

    @Test func prematureEOFAndOutputLimitDoNotBecomeSuccessfulHistory() async throws {
        for outputLimit in [false, true] {
            let fixture = try RuntimeFixture()
            defer { fixture.cleanup() }
            let app = try MiraApplication(store: fixture.store, provider: fixture.provider)
            let conversationID = try await app.createConversation(workspaceID: nil)
            let id = try await app.send(conversationID: conversationID, text: "test", routeID: fixture.route.id)
            try await eventually { fixture.provider.requestCount == 1 }
            fixture.provider.yield(.textDelta("incomplete"), for: id)
            if outputLimit { fixture.provider.yield(.finished(.outputLimit), for: id) }
            fixture.provider.end(id)
            try await eventually { try fixture.store.executions(in: conversationID).last?.status == .interrupted }
            #expect(try fixture.store.messages(in: conversationID).last?.status == .interrupted)
            await app.shutdown()
        }
    }
}

private struct RuntimeFixture {
    let directory: URL
    let store: SQLiteMiraStore
    let provider: ControlledProvider
    let route: ResolvedModelRouteSnapshot
    let configuration: StoredRouteFixture
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiraRuntimeTests-\(UUID().uuidString)")
        store = try SQLiteMiraStore(directory: directory)
        provider = ControlledProvider(store: store)
        let snapshot = ResolvedModelRouteSnapshot(name: "Synthetic", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", modelID: "fixture", credentialReference: "reference-only", contextWindow: 32_768)
        route = snapshot
        configuration = StoredRouteFixture(snapshot)
        try configuration.install(in: store)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

/// Every mutable field is protected by lock; no sleep is used to simulate provider output.
private final class ControlledProvider: ModelProviderPort, @unchecked Sendable {
    private let lock = NSLock()
    private let store: SQLiteMiraStore
    private var continuations: [ExecutionID: AsyncThrowingStream<CanonicalStreamEvent, any Error>.Continuation] = [:]
    private var requests: [CanonicalModelRequest] = []
    private var snapshotChecks: [Bool] = []
    init(store: SQLiteMiraStore) { self.store = store }
    var requestCount: Int { lock.withLock { requests.count } }
    var snapshotWasDurableAtDispatch: Bool { lock.withLock { !snapshotChecks.isEmpty && snapshotChecks.allSatisfy { $0 } } }
    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        let pair = AsyncThrowingStream<CanonicalStreamEvent, any Error>.makeStream()
        lock.withLock {
            continuations[request.executionID] = pair.continuation
            requests.append(request)
            snapshotChecks.append((try? store.request(for: request.executionID)) == request)
        }
        pair.continuation.onTermination = { [weak self] _ in self?.remove(request.executionID) }
        return pair.stream
    }
    private func continuation(_ id: ExecutionID) -> AsyncThrowingStream<CanonicalStreamEvent, any Error>.Continuation? { lock.withLock { continuations[id] } }
    private func remove(_ id: ExecutionID) { _ = lock.withLock { continuations.removeValue(forKey: id) } }
    func yield(_ event: CanonicalStreamEvent, for id: ExecutionID) { continuation(id)?.yield(event) }
    func fail(_ error: MiraError, for id: ExecutionID) { continuation(id)?.finish(throwing: error) }
    func end(_ id: ExecutionID) { continuation(id)?.finish() }
    func complete(_ id: ExecutionID) { yield(.finished(.stop), for: id); end(id) }
}

private func eventually(_ predicate: @Sendable () throws -> Bool) async throws {
    for _ in 0..<400 {
        if try predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw MiraError(.timeout, "Synthetic runtime condition did not become true within 2 seconds.")
}
