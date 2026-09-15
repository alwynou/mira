import Foundation
import Testing
import MiraCore
@testable import MiraProviders

private final class AdapterCredentialProbe: CredentialReader, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func read(reference: String, version: Int) throws -> String {
        lock.withLock { count += 1 }
        return "synthetic-secret"
    }
}

private actor AdapterGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor AdapterCompletionProbe {
    var completed = false
    func finish() { completed = true }
}

/// A transport whose actual close cannot finish until the test releases it.
private final class AdapterDrainTransport: HTTPStreamingTransport, Sendable {
    let started = AdapterGate()
    let closing = AdapterGate()
    let allowClose = AdapterGate()
    let didClose = AdapterCompletionProbe()
    let terminal: Bool
    init(terminal: Bool) { self.terminal = terminal }
    func stream(request: URLRequest) -> HTTPTransportOperation {
        let (events, continuation) = AsyncThrowingStream<HTTPTransportEvent, any Error>.makeStream()
        continuation.yield(.response(.init(statusCode: 200)))
        if terminal {
            continuation.yield(.bytes(Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)))
        }
        let start = Task { await started.open() }
        return HTTPTransportOperation(events: events) {
            await start.value
            continuation.finish()
            await self.closing.open()
            await self.allowClose.wait()
            await self.didClose.finish()
        }
    }
}

@Suite("HTTP model adapter contract", .timeLimit(.minutes(1)))
struct HTTPModelAdapterContractTests {
    private func route(fixture: ProtocolFixture = .standard,
                       connectionID: ConnectionID = ConnectionID(),
                       configuration: JSONValue? = nil,
                       credentialVersion: Int = 1,
                       window: Int = 32_768) throws -> AgentModelRoute {
        .init(id: RouteID(), revision: 1, connectionID: connectionID, connectionRevision: 1,
              modelDescriptorID: ModelDescriptorID(), modelRevision: 1, adapter: fixture.adapter,
              modelID: "fixture", credential: .init(reference: "fixture", version: credentialVersion),
              contextWindow: window, maximumOutputTokens: 1_024,
              capabilities: .init(streamsText: true, callsTools: true, producesThinking: true),
              configuration: try configuration ?? HTTPModelConfiguration(baseURL: "https://fixture.test",
                  protocolID: fixture.protocolID, dialectProfileID: fixture.dialect).jsonValue())
    }

    private func input() -> AgentModelInput {
        .init(stepID: UUID(), executionID: ExecutionID(), instructions: "Answer briefly.",
              messages: [.init(role: .user, text: "Hello")], tools: [])
    }

    @Test(arguments: ProtocolFixture.allCases)
    func wireNameCollisionsFailBeforeCredentialsOrTransport(_ fixture: ProtocolFixture) throws {
        let credentials = AdapterCredentialProbe()
        let adapter = HTTPModelAdapter(fixture: fixture, credentials: credentials)
        let schema: JSONValue = .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])
        let request = AgentModelInput(stepID: UUID(), executionID: ExecutionID(), instructions: "Fixture",
            messages: [.init(role: .user, text: "Hello")], tools: [
                .init(name: "catalog.read", description: "First tool", inputSchema: schema),
                .init(name: "catalog_read", description: "Second tool", inputSchema: schema)
            ])
        let frozen = try route(fixture: fixture)
        try request.validate(for: frozen)
        #expect(throws: (any Error).self) { try adapter.prepare(request, route: frozen) }
        #expect(credentials.reads == 0)
    }

    @Test func preparationIsPureAndForgedWireCannotReadCredentials() async throws {
        let credentials = AdapterCredentialProbe()
        let transport = AdapterDrainTransport(terminal: true)
        let adapter = HTTPModelAdapter(fixture: .standard, credentials: credentials, transport: transport)
        let route = try route(), prepared = try adapter.prepare(input(), route: route)
        #expect(credentials.reads == 0)
        #expect(try adapter.prepare(prepared.input, route: route) == prepared)
        let forged = AgentPreparedModelRequest(adapter: prepared.adapter, input: prepared.input,
            wirePayload: .object(["model": .string("another-model")]), estimatedInputTokens: prepared.estimatedInputTokens)
        let operation = adapter.stream(forged, route: route)
        do {
            for try await _ in operation.events {}
            Issue.record("A changed preparation must fail before dispatch.")
        } catch let failure as AgentModelFailure {
            try failure.validate()
            #expect(failure.error.code == .conflict)
            #expect(failure.retryAdvice == nil)
        }
        await operation.close()
        #expect(credentials.reads == 0)
    }

    @Test func malformedConfigurationIsAConfigurationErrorBeforeSecrets() throws {
        let credentials = AdapterCredentialProbe()
        let adapter = HTTPModelAdapter(fixture: .standard, credentials: credentials)
        for configuration in [JSONValue.object(["baseURL": .number(42)]), .object(["invalid": .number(.nan)])] {
            let invalid = try route(configuration: configuration)
            do { _ = try adapter.prepare(input(), route: invalid); Issue.record("Expected invalid configuration.") }
            catch let error as MiraError { #expect(error.code == .configuration) }
        }
        #expect(credentials.reads == 0)
    }

    @Test func preparationEnforcesTheFrozenInputBudget() throws {
        let adapter = HTTPModelAdapter(fixture: .standard, credentials: AdapterCredentialProbe())
        let small = try route(window: 1_100)
        do { _ = try adapter.prepare(input(), route: small); Issue.record("Expected a context limit.") }
        catch let error as MiraError { #expect(error.code == .contextLimit) }
    }

    @Test func foreignHistoryDoesNotDecodeAnotherAdaptersConfiguration() throws {
        let target = try route(fixture: .deepSeek)
        let foreignIdentity = AgentAdapterIdentity(id: "fixture.local", revision: 3)
        let source = AgentModelRoute(id: RouteID(), revision: 1, connectionID: target.connectionID,
            connectionRevision: 1, modelDescriptorID: ModelDescriptorID(), modelRevision: 1,
            adapter: foreignIdentity, modelID: target.modelID, credential: nil,
            contextWindow: 32_768, maximumOutputTokens: 1_024, capabilities: target.capabilities,
            configuration: .object(["localModel": .string("fixture")]))
        let thinking = ThinkingSnapshot(text: "Visible thinking", continuation: .init(adapter: foreignIdentity,
            format: "fixture.opaque", payload: .object(["state": .string("opaque")]), isComplete: true), isComplete: true)
        let message = AgentModelMessage(role: .assistant, text: "Answer", thinking: thinking)
        let adapter = HTTPModelAdapter(fixture: .deepSeek, credentials: AdapterCredentialProbe())
        guard case .include(let replay) = try adapter.replay([message], from: source, to: target, boundary: .previousExecution) else {
            Issue.record("Ordinary eligible history remains available across adapters."); return
        }
        #expect(replay == [.init(role: .assistant, text: "Answer")])
        #expect(throws: MiraError.self) {
            try adapter.replay([message], from: source, to: target, boundary: .sameExecution)
        }
    }

    @Test func sameExecutionRequiresTheEntireFrozenRoute() throws {
        let original = try route(fixture: .deepSeek)
        let changed = AgentModelRoute(id: original.id, revision: original.revision,
            connectionID: original.connectionID, connectionRevision: original.connectionRevision,
            modelDescriptorID: original.modelDescriptorID, modelRevision: original.modelRevision,
            adapter: original.adapter, modelID: original.modelID,
            credential: .init(reference: "fixture", version: 2), contextWindow: original.contextWindow,
            maximumOutputTokens: original.maximumOutputTokens, capabilities: original.capabilities,
            configuration: original.configuration)
        let adapter = HTTPModelAdapter(fixture: .deepSeek, credentials: AdapterCredentialProbe())
        #expect(throws: MiraError.self) {
            try adapter.replay([.init(role: .assistant, text: "Answer")], from: original,
                               to: changed, boundary: .sameExecution)
        }
    }

    @Test func protocolCompletionWaitsForTheActualTransportClose() async throws {
        let transport = AdapterDrainTransport(terminal: true)
        let adapter = HTTPModelAdapter(fixture: .standard, credentials: AdapterCredentialProbe(), transport: transport)
        let route = try route()
        let operation = adapter.stream(try adapter.prepare(input(), route: route), route: route)
        let consumerDone = AdapterCompletionProbe()
        let consumer = Task {
            var events: [AgentModelStreamEvent] = []
            for try await event in operation.events { events.append(event) }
            await consumerDone.finish()
            return events
        }
        await transport.closing.wait()
        #expect(!(await consumerDone.completed))
        #expect(!(await transport.didClose.completed))
        await transport.allowClose.open()
        #expect(try await consumer.value == [.finished(.stop)])
        await operation.close()
        #expect(await transport.didClose.completed)
    }

    @Test func cancelledCloseStillDrainsTheTransport() async throws {
        let transport = AdapterDrainTransport(terminal: false)
        let adapter = HTTPModelAdapter(fixture: .standard, credentials: AdapterCredentialProbe(), transport: transport)
        let route = try route()
        let operation = adapter.stream(try adapter.prepare(input(), route: route), route: route)
        await transport.started.wait()
        let closed = AdapterCompletionProbe()
        let closer = Task { await operation.close(); await closed.finish() }
        closer.cancel()
        await transport.closing.wait()
        #expect(!(await closed.completed))
        await transport.allowClose.open()
        await closer.value
        await operation.close()
        #expect(await transport.didClose.completed)
        #expect(await closed.completed)
    }
}
