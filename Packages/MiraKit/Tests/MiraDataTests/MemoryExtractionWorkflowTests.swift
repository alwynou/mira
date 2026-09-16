import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Memory extraction through journal and shared runtime", .timeLimit(.minutes(1)))
struct MemoryExtractionWorkflowTests {
    @Test(arguments: [false, true])
    func foregroundCompletionFeedsOwnedBackgroundJob(disableConnectionDuringStream: Bool) async throws {
        let text = "I prefer green tea"
        let turns = [text, "I prefer concise answers", "I work in the morning", "I prefer paper books"]
        let structured: JSONValue = .object([
            "version": .number(3),
            "items": .array([
                .object([
                    "content": .string("I enjoy concise replies"), "inputIndex": .number(1), "kind": .string("preference"),
                    "subject": .string("user"),
                    "sensitivity": .string("standard"), "inferred": .bool(false), "stable": .bool(true),
                    "confidence": .string("high"),
                    "validFrom": .null, "validUntil": .null,
                    "assertion": .object([
                        "mode": .string("directStable"), "aspectKey": .string("communication.style"),
                        "changeIntent": .string("independent"),
                    ]),
                ]),
                .object([
                    "content": .string("I enjoy paper books"), "inputIndex": .number(3), "kind": .string("preference"),
                    "subject": .string("user"), "sensitivity": .string("standard"), "inferred": .bool(false), "stable": .bool(true),
                    "confidence": .string("high"), "validFrom": .null, "validUntil": .null,
                    "assertion": .object(["mode": .string("directStable"), "aspectKey": .string("reading.format"), "changeIntent": .string("independent")])
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
        try await withTaskWorkflow(outputs: Array(repeating: [.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)], count: 4) + [output], memoryEnabled: true) {
            f in
            let memories = try #require(f.memory)
            let address = try await f.run(turns[0], sessionID: ConversationID())
            _ = try await f.run(turns[1], sessionID: address.sessionID)
            _ = try await f.run(turns[2], sessionID: address.sessionID)
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
                if disableConnectionDuringStream { await f.model.holdStream(number: 5) }
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
                _ = try await f.run(turns[3], sessionID: address.sessionID)
                if disableConnectionDuringStream {
                    try await wait { await f.model.streamHeld }
                    let connection = try #require(try await f.settings.connection(id: f.route.connectionID))
                    try await f.settings.saveConnection(.init(id: connection.id, revision: connection.revision + 1,
                        configurationRevision: connection.configurationRevision + 1, name: connection.name,
                        isEnabled: false, definitionID: connection.definitionID, endpoints: connection.endpoints,
                        discovery: connection.discovery, defaultInvocation: connection.defaultInvocation),
                        expectedRevision: connection.revision, authorization: f.authority.authorization())
                    await f.model.releaseStream()
                    try await wait {
                        try await store.memoryExtractionJobs(sessionID: address.sessionID, state: .paused, limit: 4).count == 1
                    }
                    await worker.close()
                    let job = try #require(
                        try await store.memoryExtractionJobs(sessionID: address.sessionID, state: nil, limit: 4).first)
                    #expect(job.state == .paused)
                    #expect(job.memoryIDs.isEmpty)
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
                    #expect(job.memoryIDs.count == 2 && job.candidateMemoryIDs.isEmpty)
                    let saved = try await memories.memoryList(workspaceID: nil, states: [.active], query: "", limit: 8)
                    #expect(saved.memories.count == 2)
                    let contents = saved.memories.compactMap { $0.draft?.content }
                    #expect(contents.contains("I enjoy concise replies"))
                    #expect(contents.contains("I enjoy paper books"))
                    for memory in saved.memories {
                        let detail = try await memories.memoryDetail(memory.id, workspaceID: nil)
                        #expect(detail.evidence.count == 4)
                        #expect(job.turns.allSatisfy { turn in detail.evidence.contains { $0.source == .userMessage(turn.source) } })
                    }
                    // Repeated catch-up/wake cannot issue another model call or duplicate an assertion.
                    await opened.wake()
                    await worker.wake()
                    await worker.close()
                    #expect(
                        try await store.memoryExtractionJobs(sessionID: address.sessionID, state: nil, limit: 4).count
                            == 1)
                }
                let inputs = await f.model.inputs
                #expect(inputs.count == 5)
                #expect(inputs.dropLast().count == 4)
                let foreground = try #require(inputs.dropLast().last)
                let extraction = try #require(inputs.last)
                #expect(extraction.tools == foreground.tools)
                #expect(extraction.instructions == foreground.instructions)
                #expect(extraction.allowsToolCalls == false)
                #expect(extraction.prefixMessageCount == foreground.messages.count)
                #expect(Array(extraction.messages.dropLast()) == foreground.messages)
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
