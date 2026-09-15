import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Memory extraction through journal and shared runtime", .timeLimit(.minutes(1)))
struct MemoryExtractionWorkflowTests {
    @Test(arguments: [false, true])
    func foregroundCompletionFeedsOwnedBackgroundJob(disableDuringStream: Bool) async throws {
        let text = "I prefer green tea"
        let structured: JSONValue = .object([
            "version": .number(2),
            "items": .array([
                .object([
                    "content": .string(text), "quote": .string(text), "kind": .string("preference"),
                    "subject": .string("user"),
                    "sensitivity": .string("standard"), "inferred": .bool(false), "stable": .bool(true),
                    "confidence": .string("high"),
                    "validFrom": .null, "validUntil": .null,
                    "assertion": .object([
                        "mode": .string("directStable"), "aspectKey": .string("drink.preference"),
                        "changeIntent": .string("independent"),
                    ]),
                ])
            ]),
        ])
        let output: [AgentModelStreamEvent] = [
            .blockStarted(.init(id: "text", content: .text(try structured.jsonString()))),
            .blockFinished(id: "text"),
            .usage(
                .init(
                    inputTokens: 10, outputTokens: 2, cacheReadTokens: 3, cacheWriteTokens: 7,
                    inputTokenBasis: .excludesCache)), .finished(.stop),
        ]
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)], output], memoryEnabled: true) {
            f in
            let memories = try #require(f.memory)
            try await memories.saveMemoryCapturePolicy(
                .init(
                    revision: 2, mode: .automaticWithUndo,
                    dailyTokenLimit: 100_000, enabledAt: TaskWorkflowFixture.now), expectedRevision: 1,
                authorization: f.authority.authorization(), at: TaskWorkflowFixture.now)
            try await f.settings.saveBinding(
                .init(
                    scope: .global, purpose: AgentModelPurposeID.memoryExtraction,
                    routeID: f.route.id, revision: 1), expectedRevision: nil, authorization: f.authority.authorization())
            let address = try await f.run(text)
            let source = try await f.evidence(address)
            let scope = RuntimeScope(kind: .application)
            let registry = RuntimeRegistry<AgentCapability>()
            let store = try SQLiteMemoryExtractionStore(database: f.database, libraryID: f.authority.libraryID)
            let consumer = try SQLiteSessionConsumer(
                database: f.database, identity: SQLiteMemoryExtractionConsumer.identity,
                handler: SQLiteMemoryExtractionConsumer(
                    journal: f.library, payloads: f.library, access: f.access,
                    scope: scope, now: { TaskWorkflowFixture.now }))
            try await registry.register(id: "extract.consumer", value: .consumer(consumer), scope: scope)
            try await registry.register(id: "extract.model", value: .model(f.model), scope: scope)
            try await registry.register(
                id: "extract.configuration", value: .modelConfiguration(ExtractionConfiguration()), scope: scope)
            let catalog = try AgentRuntimeCatalog(snapshot: await registry.freeze())
            let worker = MemoryExtractionWorker(
                store: store, reader: .init(journal: f.library, payloads: f.library),
                settings: f.settings, catalog: catalog, scheduler: f.scheduler, access: f.access, scope: scope,
                environment: .init(now: { TaskWorkflowFixture.now }))
            var service: AgentSessionConsumerService?
            var subscription: Task<Void, Never>?
            do {
                if disableDuringStream { await f.model.holdStream(number: 2) }
                let opened = try await AgentSessionConsumerService.open(
                    journal: f.library, registry: registry,
                    access: f.access, scope: scope)
                service = opened
                let hints = try await opened.events()
                subscription = try await scope.ownTask {
                    for await hint in hints {
                        if Task.isCancelled { break }
                        switch hint {
                        case .advanced, .reconciled: await worker.wake()
                        case .failure: break
                        }
                    }
                }
                if disableDuringStream {
                    try await wait { await f.model.streamHeld }
                    let reserved = try await store.memoryExtractionBudget(at: TaskWorkflowFixture.now).reservedTokens
                    #expect(reserved > 0)
                    try await memories.saveMemoryCapturePolicy(
                        .init(revision: 3, mode: .manualOnly, dailyTokenLimit: 100_000),
                        expectedRevision: 2, authorization: f.authority.authorization(), at: TaskWorkflowFixture.now)
                    await f.model.releaseStream()
                    await worker.close()
                    let job = try #require(
                        try await store.memoryExtractionJobs(sessionID: address.sessionID, state: nil, limit: 4).first)
                    #expect(job.state == .paused)
                    #expect(job.memoryIDs.isEmpty)
                    let budget = try await store.memoryExtractionBudget(at: TaskWorkflowFixture.now)
                    #expect(budget.reservedTokens == 0 && budget.chargedTokens == reserved)
                    #expect(
                        try await memories.memoryList(
                            workspaceID: nil, states: [.active, .candidate], query: "", limit: 8
                        ).memories.isEmpty)
                } else {
                    try await wait {
                        try await store.memoryExtractionJobs(sessionID: address.sessionID, state: .completed, limit: 4)
                            .count == 1
                    }
                    let job = try #require(
                        try await store.memoryExtractionJobs(sessionID: address.sessionID, state: .completed, limit: 4)
                            .first)
                    #expect(job.memoryIDs.count == 1 && job.candidateMemoryIDs.isEmpty)
                    let memory = try await memories.memoryDetail(job.memoryIDs[0], workspaceID: nil)
                    #expect(memory.memory.origin == .observedUserStatement && memory.memory.authority == .observedUser)
                    #expect(memory.memory.draft?.content == text)
                    #expect(memory.evidence.first?.source == .userMessage(source.reference))
                    let budget = try await store.memoryExtractionBudget(at: TaskWorkflowFixture.now)
                    #expect(budget.reservedTokens == 0 && budget.chargedTokens == 22)
                    // Repeated catch-up/wake cannot issue another model call or duplicate an assertion.
                    await opened.wake()
                    await worker.wake()
                    await worker.close()
                    #expect(
                        try await store.memoryExtractionJobs(sessionID: address.sessionID, state: nil, limit: 4).count
                            == 1)
                }
                let inputs = await f.model.inputs
                #expect(inputs.count == 2)
                #expect(inputs[1].executionID != address.executionID)
                #expect(inputs[1].tools.isEmpty)
                #expect(inputs[1].messages.count == 1)
                await service?.close()
                await subscription?.value
                await worker.close()
                await consumer.close()
                await store.close()
                await catalog.release()
                await scope.dispose()
            } catch {
                await f.model.releaseStream()
                await service?.close()
                await subscription?.value
                await worker.close()
                await consumer.close()
                await store.close()
                await catalog.release()
                await scope.dispose()
                throw error
            }
        }
    }

    private func wait(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
        for _ in 0..<2_000 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw MiraError(.timeout, "The extraction workflow did not reach its expected state.")
    }
}

private struct ExtractionConfiguration: AgentModelConfigurationProvider {
    let identity = AgentAdapterIdentity(id: "task.fixture", revision: 1)
    func descriptor(for invocation: AgentModelInvocationSpec) throws -> AgentModelConfigurationDescriptor {
        let schema = AgentConfigurationSchema(
            identity: .init(id: "task.fixture", revision: 1), title: "Synthetic extraction settings",
            schema: .object([
                "type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false),
            ]), defaults: .object([:]))
        return .init(
            adapter: identity, title: "Synthetic extraction model", credential: .none, connection: schema, route: schema
        )
    }
    func configuration(for candidate: AgentModelRouteCandidate) throws -> JSONValue { .object([:]) }
}
