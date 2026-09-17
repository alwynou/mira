import Foundation
import MiraCore
import MiraData
import Testing

@Suite("macOS composed agent execution", .timeLimit(.minutes(1)))
struct LibraryExecutionTests {
    @Test func defaultDriverExecutesBusinessToolAndReopenDoesNotDispatchAgain() async throws {
        try await withDirectory { directory in
            let quote = "create a task to review notes"
            let arguments = JSONValue.object([
                "operation": .string("create"), "title": .string("review notes"),
                "quote": .string(quote), "remind": .bool(false),
            ])
            let model = CompositionModel(outputs: [
                [
                    .blockStarted(.init(id: "thinking", content: .thinking(""))),
                    .blockDelta(id: "thinking", text: "Planning the task"),
                    .blockFinished(id: "thinking"),
                    .blockStarted(.init(id: "tool", content: .toolCall(
                        .init(id: "task-1", name: "task.change", arguments: try arguments.jsonString())))),
                    .blockFinished(id: "tool"),
                    .finished(.toolCalls),
                ],
                [
                    .blockStarted(.init(id: "text", content: .text(""))),
                    .blockDelta(id: "text", text: "Task processed"),
                    .blockFinished(id: "text"),
                    .finished(.stop),
                ],
            ])
            let storage = try await MacLibraryStorage.open(embeddings: OfflineMemoryEmbedding(), directory: directory)
            let route: AgentModelRoute
            do {
                let configuration = AgentConfigurationValue(
                    schema: .init(id: "tests.composition", revision: 1), value: .object([:]))
                let endpoint = AgentModelEndpoint(id: "primary", configuration: configuration, credential: nil)
                let connection = AgentConfiguredConnection(
                    id: .init(), revision: 1, configurationRevision: 1,
                    name: "Synthetic connection", isEnabled: true, definitionID: nil,
                    endpoints: [endpoint], discovery: nil, defaultInvocation: nil)
                let invocation = AgentModelInvocationSpec(
                    id: "default", revision: 1, adapter: model.identity, endpointID: endpoint.id,
                    contextWindow: 32_768, maximumOutputTokens: 1_024,
                    capabilities: [
                        AgentModelCapabilityID.streamingText: .declared,
                        AgentModelCapabilityID.toolCalls: .declared,
                        AgentModelCapabilityID.thinking: .declared,
                    ], configuration: configuration,
                    parameterSchema: .object([
                        "type": .string("object"), "properties": .object([:]),
                        "additionalProperties": .bool(false),
                    ]))
                let configured = AgentConfiguredModel(
                    id: .init(), revision: 1, authorizationRevision: 1,
                    reference: .init(connectionID: connection.id, modelID: "synthetic"), displayName: nil,
                    isEnabled: true, invocations: [invocation], facts: [])
                let preset = AgentRoutePreset(
                    id: .init(configured.id.rawValue), revision: 1, name: "Synthetic route",
                    modelDescriptorID: configured.id, invocationID: invocation.id,
                    maximumOutputTokens: 1_024, configuration: configuration)
                try await storage.settings.saveConnection(connection, expectedRevision: nil, authorization: storage.authority.state().authorization)
                try await storage.settings.savePoolModel(
                    configured, preset: preset, expectedModelRevision: nil, expectedPresetRevision: nil, authorization: storage.authority.state().authorization)
                route = try await storage.settings.candidate(routeID: preset.id).freeze(configuration: .object([:]))
                #expect(await storage.close() == nil)
            } catch {
                _ = await storage.close()
                throw error
            }
            let module: MacLibrary.ModuleFactory = { [CompositionModelModule(registry: $0, model: model)] }
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: directory, notifications: CompositionNotifications(), credentials: CompositionCredentials(), modules: module)
            let command = AgentSubmitCommand(
                id: UUID(), sessionID: .init(), executionID: .init(),
                input: .message(id: .init(), text: quote, timeZoneIdentifier: "UTC"),
                options: .init(instructions: "Use the task tool.", route: route),
                opening: .init(title: "Synthetic tool execution", workspaceID: nil))
            do {
                let group = try await library.workloads()
                try committed(await group.application.submit(command))
                try committed(
                    await group.application.waitForExecution(id: command.executionID, sessionID: command.sessionID))
                let state = try await group.application.sessionSnapshot(id: command.sessionID)
                #expect(state.executions[command.executionID]?.completion?.status == .completed)
                let invocation = try #require(state.invocations.values.first)
                #expect(invocation.resolution?.businessReceipt != nil)
                let page = try await group.queries.messagePage(sessionID: command.sessionID)
                let userMessage = try #require(page.messages.first { $0.summary.role == .user })
                let assistantMessage = try #require(page.messages.first { $0.summary.role == .assistant })
                #expect(userMessage.body == .available(quote))
                #expect(assistantMessage.body == .available("Task processed"))
                #expect(assistantMessage.thinking == .available("Planning the task"))
                #expect(page.executions.contains {
                    $0.id == command.executionID && $0.completion?.status == .completed
                })
                let task = try #require(try await group.tasks.tasks(workspaceID: nil).first)
                let search = try await group.search.search(.init(text: "processed"))
                #expect(search.hits.map(\.snippet) == ["Task processed"])
                #expect(search.hits.first?.location.executionID == command.executionID)
                #expect(try await group.search.search(.init(text: "Planning")).hits.first?.location.part == .thinking)
                #expect(task.draft.title == "review notes")
                #expect(task.evidence?.source.originalExecutionID == command.executionID)
                #expect(task.evidence?.quote == quote)
                #expect(await model.inputs.count == 2)
                #expect(await model.inputs.last?.messages.contains { $0.role == .tool } == true)
                #expect(await library.close().isSettled)
                await #expect(throws: MiraError(.busy, "The session search service is closed.")) {
                    try await group.search.search(.init(text: "processed"))
                }
                #expect(await model.closedOperations == 2)
            } catch {
                _ = await library.close()
                throw error
            }
            let reopened = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: directory, notifications: CompositionNotifications(), credentials: CompositionCredentials(), modules: module)
            do {
                let group = try await reopened.workloads()
                #expect(try await group.search.search(.init(text: "processed")).hits.map(\.snippet) == ["Task processed"])
                #expect(try await group.tasks.tasks(workspaceID: nil).count == 1)
                #expect(try await group.application.sessionSnapshot(id: command.sessionID).activeExecutionID == nil)
                #expect(await model.inputs.count == 2)
                #expect(await reopened.close().isSettled)
            } catch {
                _ = await reopened.close()
                throw error
            }
        }
    }
}

private struct CompositionModelModule: RuntimeModule {
    let id = "tests.composition"
    let dependencies: Set<String> = []
    let registry: RuntimeRegistry<AgentCapability>
    let model: CompositionModel
    func activate(in scope: RuntimeScope) async throws {
        try await registry.register(id: id, value: .model(model), scope: scope)
    }
}

private actor CompositionModel: AgentModelAdapter {
    nonisolated let identity = AgentAdapterIdentity(id: "tests.composition", revision: 1)
    private var outputs: [[AgentModelStreamEvent]]
    var inputs: [AgentModelInput] = []
    var closedOperations = 0
    init(outputs: [[AgentModelStreamEvent]]) { self.outputs = outputs }
    nonisolated func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        .init(adapter: identity, input: input, wirePayload: .object([:]), estimatedInputTokens: 1)
    }
    nonisolated func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        let (events, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
        let producer = Task {
            do {
                for event in try await next(request.input) { continuation.yield(event) }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        return .init(
            events: events,
            cancelAndDrain: {
                producer.cancel()
                await producer.value
                await self.didClose()
            })
    }
    nonisolated func replay(
        _ messages: [AgentModelMessage], from source: AgentModelRoute, to target: AgentModelRoute,
        boundary: AgentReplayBoundary
    ) throws -> AgentReplayDecision { .include(messages) }
    private func next(_ input: AgentModelInput) throws -> [AgentModelStreamEvent] {
        inputs.append(input)
        guard !outputs.isEmpty else { throw MiraError(.malformedStream, "Synthetic model output was exhausted.") }
        return outputs.removeFirst()
    }
    private func didClose() { closedOperations += 1 }
}
