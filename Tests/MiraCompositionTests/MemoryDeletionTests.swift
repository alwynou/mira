import Foundation
import MiraCore
import MiraData
import Testing

@Suite("Conversational memory deletion", .timeLimit(.minutes(1)))
struct MemoryDeletionTests {
    @Test(arguments: [DeletionScenario.complete, .stale, .reopen, .maintenanceInterrupted, .purgeInterrupted])
    func libraryOwnsDeferredPurgeAndDurableOutcome(scenario: DeletionScenario) async throws {
        try await withDirectory { directory in
            let model = DeletionModel()
            let storage = try await MacLibraryStorage.open(embeddings: OfflineMemoryEmbedding(), directory: directory)
            let route = try await seedDeletionRoute(storage, model: model)
            let memory = try await storage.memories.createMemory(
                draft: .init(content: "I prefer green tea", scope: .global),
                source: .manualEntry(id: UUID(), statement: "I prefer green tea"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: storage.authority.state().authorization,
                at: Date()).memory
            #expect(await storage.close() == nil)
            await model.setTarget(memory)
            let modules: MacLibrary.ModuleFactory = { [DeletionModule(registry: $0, model: model)] }
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory,
                notifications: CompositionNotifications(), credentials: CompositionCredentials(), modules: modules)
            let command = AgentSubmitCommand(id: UUID(), sessionID: .init(), executionID: .init(),
                input: .message(id: .init(), text: "Delete my green tea memory", timeZoneIdentifier: "UTC"),
                options: .init(instructions: ConversationInstructions.default, route: route),
                opening: .init(title: "Synthetic deletion", workspaceID: nil))
            do {
                let group = try await library.workloads()
                let generation = await library.status().generation
                try committed(await group.application.submit(command))
                try await eventually { await model.replyStarted }
                let pending = try await group.memories.deletionRequests(sessionID: command.sessionID,
                    executionIDs: [command.executionID], workspaceID: nil)
                #expect(pending.count == 1)
                #expect(pending.first?.state == .pending)
                #expect(await library.status().generation == generation)
                #expect(try await group.memories.detail(memory.id, workspaceID: nil).memory.draft != nil)
                if scenario == .stale {
                    _ = try await group.memories.reviseMemory(memory.id, workspaceID: nil,
                        draft: .init(content: "An updated preference", scope: .global),
                        expectedRevision: memory.revision, operationID: UUID())
                }
                if scenario == .reopen || scenario == .maintenanceInterrupted || scenario == .purgeInterrupted {
                    // Closing cancels the held reply and wakes its owner before draining
                    // the deletion processor. The committed request must survive.
                    #expect(await library.close().isSettled)
                    if scenario == .maintenanceInterrupted || scenario == .purgeInterrupted {
                        let interrupted = try await MacLibraryStorage.open(embeddings: OfflineMemoryEmbedding(), directory: directory)
                        do {
                            let request = try #require(try await interrupted.memories.pendingMemoryDeletions(limit: 1).first)
                            let operation = try await interrupted.authority.begin(request.maintenanceRequest,
                                expected: interrupted.authority.state().authorization)
                            if scenario == .purgeInterrupted {
                                let handler = MemoryForgetHandler(memories: interrupted.memories)
                                try await handler.apply(operation)
                                try await handler.verify(operation)
                            }
                            // Simulate process loss before the durable completion fact,
                            // both before and after the memory-domain purge commits.
                            #expect(await interrupted.close() == nil)
                        } catch { _ = await interrupted.close(); throw error }
                    }
                    let reopened = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory,
                        notifications: CompositionNotifications(), credentials: CompositionCredentials(), modules: modules)
                    do {
                        try await expectOutcome(reopened, command: command, memory: memory, state: .completed)
                        #expect(await model.calls == 2)
                        #expect(await reopened.close().isSettled)
                    } catch { _ = await reopened.close(); throw error }
                } else {
                    await model.release()
                    try committed(await group.application.waitForExecution(id: command.executionID, sessionID: command.sessionID))
                    try await expectOutcome(library, command: command, memory: memory,
                                            state: scenario == .stale ? .failed : .completed)
                    if scenario == .complete {
                        let current = try await library.workloads()
                        let requests = try await current.memories.deletionRequests(sessionID: command.sessionID,
                            executionIDs: [command.executionID], workspaceID: nil)
                        #expect(requests.count == 1)
                        let page = try await current.queries.messagePage(sessionID: command.sessionID)
                        #expect(page.messages.contains { $0.body == .available("Delete my green tea memory") })
                        #expect(page.messages.contains { $0.body == .available("Deletion request submitted.") })
                    }
                    #expect(await library.close().isSettled)
                }
            } catch { await model.release(); _ = await library.close(); throw error }
        }
    }

    private func expectOutcome(_ library: MacLibrary, command: AgentSubmitCommand,
                               memory: Memory, state: MemoryDeletionRequest.State) async throws {
        do { try await eventually {
            guard let group = try? await library.workloads(),
                  let requests = try? await group.memories.deletionRequests(sessionID: command.sessionID,
                      executionIDs: [command.executionID], workspaceID: nil) else { return false }
            return requests.first?.state == state
        } } catch {
            let status = await library.status()
            Issue.record("Deletion did not settle: phase=\(status.phase), failure=\(String(describing: status.failure)), pending=\(await library.pendingMaintenance() != nil)")
            throw error
        }
        let group = try await library.workloads()
        let detail = try await group.memories.detail(memory.id, workspaceID: nil)
        if state == .completed {
            #expect(detail.memory.forgottenAt != nil)
            #expect(detail.memory.draft == nil)
            #expect(detail.revisions.allSatisfy { $0.draft == nil })
            #expect(detail.evidence.allSatisfy { $0.excerpt == nil })
        } else {
            #expect(detail.memory.forgottenAt == nil)
            #expect(detail.memory.draft?.content == "An updated preference")
        }
    }
}

enum DeletionScenario: Sendable { case complete, stale, reopen, maintenanceInterrupted, purgeInterrupted }

private struct DeletionModule: RuntimeModule {
    let id = "tests.deletion"
    let dependencies: Set<String> = []
    let registry: RuntimeRegistry<AgentCapability>
    let model: DeletionModel
    func activate(in scope: RuntimeScope) async throws {
        try await registry.register(id: id, value: .model(model), scope: scope)
    }
}

private actor DeletionModel: AgentModelAdapter {
    nonisolated let identity = AgentAdapterIdentity(id: "tests.deletion", revision: 1)
    private var target: Memory?
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var replyStarted = false
    private(set) var calls = 0
    func setTarget(_ memory: Memory) { target = memory }
    func release() { released = true; let old = waiters; waiters.removeAll(); old.forEach { $0.resume() } }
    private func cancelStream() { if replyStarted { release() } }
    nonisolated func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        .init(adapter: identity, input: input, wirePayload: .object([:]), estimatedInputTokens: 1)
    }
    nonisolated func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        let (events, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
        let producer = Task {
            do {
                for event in try await next() { continuation.yield(event) }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        return .init(events: events, cancelAndDrain: {
            producer.cancel()
            await self.cancelStream()
            await producer.value
        })
    }
    nonisolated func replay(_ messages: [AgentModelMessage], from source: AgentModelRoute,
                            to target: AgentModelRoute, boundary: AgentReplayBoundary) throws -> AgentReplayDecision {
        .include(messages)
    }
    private func next() async throws -> [AgentModelStreamEvent] {
        calls += 1
        if calls == 1 {
            let target = try #require(target)
            let arguments = try JSONValue.object([
                "memory_id": .string(target.id.rawValue.uuidString.lowercased()),
                "revision": .number(Double(target.revision)), "quote": .string("Delete my green tea memory")
            ]).jsonString()
            return [.blockStarted(.init(id: "delete", content: .toolCall(.init(id: "delete-one", name: "memory.delete", arguments: arguments)))),
                    .blockFinished(id: "delete"), .finished(.toolCalls)]
        }
        replyStarted = true
        if !released { await withCheckedContinuation { waiters.append($0) } }
        try Task.checkCancellation()
        return [.blockStarted(.init(id: "answer", content: .text("Deletion request submitted."))),
                .blockFinished(id: "answer"), .finished(.stop)]
    }
}

private func seedDeletionRoute(_ storage: MacLibraryStorage, model: DeletionModel) async throws -> AgentModelRoute {
    let configuration = AgentConfigurationValue(schema: .init(id: "tests.deletion", revision: 1), value: .object([:]))
    let endpoint = AgentModelEndpoint(id: "primary", configuration: configuration, credential: nil)
    let connection = AgentConfiguredConnection(id: .init(), revision: 1, configurationRevision: 1,
        name: "Synthetic deletion", isEnabled: true, definitionID: nil, endpoints: [endpoint], discovery: nil, defaultInvocation: nil)
    let invocation = AgentModelInvocationSpec(id: "default", revision: 1, adapter: model.identity, endpointID: endpoint.id,
        contextWindow: 32_768, maximumOutputTokens: 1_024,
        capabilities: [AgentModelCapabilityID.streamingText: .declared, AgentModelCapabilityID.toolCalls: .declared],
        configuration: configuration,
        parameterSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]))
    let configured = AgentConfiguredModel(id: .init(), revision: 1, authorizationRevision: 1,
        reference: .init(connectionID: connection.id, modelID: "synthetic"), displayName: nil, isEnabled: true, invocations: [invocation], facts: [])
    let preset = AgentRoutePreset(id: .init(configured.id.rawValue), revision: 1, name: "Synthetic deletion",
        modelDescriptorID: configured.id, invocationID: invocation.id, maximumOutputTokens: 1_024, configuration: configuration)
    try await storage.settings.saveConnection(connection, expectedRevision: nil, authorization: storage.authority.state().authorization)
    try await storage.settings.savePoolModel(configured, preset: preset, expectedModelRevision: nil,
        expectedPresetRevision: nil, authorization: storage.authority.state().authorization)
    return try await storage.settings.candidate(routeID: preset.id).freeze(configuration: .object([:]))
}
