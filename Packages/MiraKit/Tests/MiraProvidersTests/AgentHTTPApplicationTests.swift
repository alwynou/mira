import Foundation
import Testing
import MiraCore
import MiraData
@testable import MiraProviders

@Suite("HTTP adapter application integration", .timeLimit(.minutes(1)))
struct AgentHTTPApplicationTests {
    @Test func httpAdapterRunsToolTurnPreservesThinkingAndDoesNotRedispatchOnRecovery() async throws {
        let fixture = try await HTTPApplicationFixture.make(responses: [Self.toolTurn, Self.answerTurn])
        do {
            let command = fixture.command()
            try requireCommitted(await fixture.application.submit(command))
            try requireCommitted(await fixture.application.waitForExecution(id: command.executionID, sessionID: command.sessionID))

            let state = try await fixture.application.sessionSnapshot(id: command.sessionID)
            let completion = try #require(state.executions[command.executionID]?.completion)
            #expect(completion.status == .completed)
            let answerReference = try #require(completion.answer)
            let thinkingReference = try #require(completion.visibleThinking)
            let answer = try await fixture.library.read(answerReference)
            let thinking = try await fixture.library.read(thinkingReference)
            #expect(answer == Data("answer".utf8))
            #expect(thinking == Data("planfinal plan".utf8))
            #expect(await fixture.tool.executeCount == 1)
            #expect(fixture.transport.requestCount == 2)

            let second = try #require(fixture.transport.requests[safe: 1])
            let secondPayload = try SessionCodec.decode(JSONValue.self, from: try #require(second.httpBody))
            try Self.assertSecondRequestContainsPriorExchange(secondPayload)

            let beforeRecovery = completion
            try await fixture.reopen()
            let recovered = try await fixture.application.sessionSnapshot(id: command.sessionID)
            let recoveredCompletion = try #require(recovered.executions[command.executionID]?.completion)
            #expect(recoveredCompletion == beforeRecovery)
            #expect(try await fixture.library.read(try #require(recoveredCompletion.answer)) == answer)
            #expect(try await fixture.library.read(try #require(recoveredCompletion.visibleThinking)) == thinking)
            #expect(fixture.transport.requestCount == 2)
            #expect(await fixture.tool.executeCount == 1)
            #expect(await fixture.application.snapshot().phase == .ready)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    @Test func interruptedThinkingPersistsPartialOutputAndDoesNotRerunAfterRecovery() async throws {
        let fixture = try await HTTPApplicationFixture.make(responses: [Self.interruptedThinking])
        do {
            let command = fixture.command()
            try requireCommitted(await fixture.application.submit(command))
            try requireCommitted(await fixture.application.waitForExecution(id: command.executionID, sessionID: command.sessionID))

            let state = try await fixture.application.sessionSnapshot(id: command.sessionID)
            let completion = try #require(state.executions[command.executionID]?.completion)
            #expect(completion.status == .failed)
            let error = try SessionCodec.decode(MiraError.self, from: await fixture.library.read(try #require(completion.error)))
            #expect(error.code == .interrupted)
            #expect(completion.answer == nil)
            let attemptID = try #require(state.executions[command.executionID]?.attemptIDs.last)
            let attempt = try #require(state.attempts[attemptID])
            let outputReference = try #require(attempt.resolution?.output)
            let output = try SessionCodec.decode(AgentModelOutput.self, from: await fixture.library.read(outputReference))
            #expect(output.thinkingText == "partial")
            #expect(output.finishReason == .outputLimit)
            #expect(output.continuation?.adapter.id == "mira.http.chat-completions")
            #expect(output.continuation?.format == "openai.content")
            #expect(output.continuation?.isComplete == false)
            #expect(attempt.resolution?.stream.isEmpty == false)
            let thinkingReference = try #require(completion.visibleThinking)
            #expect(try await fixture.library.read(thinkingReference) == Data("partial".utf8))
            #expect(fixture.transport.requestCount == 1)

            try await fixture.reopen()
            let recovered = try await fixture.application.sessionSnapshot(id: command.sessionID)
            let recoveredCompletion = try #require(recovered.executions[command.executionID]?.completion)
            #expect(recoveredCompletion == completion)
            #expect(try await fixture.library.read(try #require(recoveredCompletion.visibleThinking)) == Data("partial".utf8))
            #expect(fixture.transport.requestCount == 1)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    @Test func ordinaryFragmentedReplyCompletesPersistsAndReopens() async throws {
        let pieces = (0..<96).map { "word-\($0) " }
        let thoughts = ["first ", "second ", "third"]
        let frames = thoughts.map { "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"\($0)\"}}]}\n\n" }
            + pieces.map { "data: {\"choices\":[{\"delta\":{\"content\":\"\($0)\"}}]}\n\n" }
            + ["data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"]
        let fixture = try await HTTPApplicationFixture.make(responses: [Data(frames.joined().utf8)])
        do {
            let command = fixture.command()
            try requireCommitted(await fixture.application.submit(command))
            try requireCommitted(await fixture.application.waitForExecution(id: command.executionID, sessionID: command.sessionID))
            let state = try await fixture.application.sessionSnapshot(id: command.sessionID)
            let completion = try #require(state.executions[command.executionID]?.completion)
            #expect(completion.status == .completed)
            #expect(try await fixture.library.read(try #require(completion.answer)) == Data(pieces.joined().utf8))
            #expect(try await fixture.library.read(try #require(completion.visibleThinking)) == Data(thoughts.joined().utf8))
            #expect(fixture.transport.requestCount == 1)
            #expect(await fixture.tool.executeCount == 0)
            try await fixture.reopen()
            let reopened = try await fixture.application.sessionSnapshot(id: command.sessionID)
            #expect(reopened.executions[command.executionID]?.completion == completion)
            #expect(fixture.transport.requestCount == 1)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func retryAdmissionFencesAndRecoversWithoutRedispatch(reopen: Bool) async throws {
        let fault = RetryJournalFault()
        let partial = Data("""
        data: {"choices":[{"delta":{"reasoning_content":"old thinking"}}]}

        data: {"choices":[{"delta":{"content":"old partial answer"}}]}

        """.utf8)
        let fixture = try await HTTPApplicationFixture.make(
            responses: [partial, Self.answerTurn], faultInjector: { try fault.check($0) })
        do {
            let original = fixture.command()
            try requireCommitted(await fixture.application.submit(original))
            try requireCommitted(await fixture.application.waitForExecution(id: original.executionID, sessionID: original.sessionID))
            let before = try await fixture.application.sessionSnapshot(id: original.sessionID)
            let source = try #require(before.executions[original.executionID])
            let completion = try #require(source.completion)
            #expect(completion.status == .failed)
            let oldAnswer = try #require(completion.answer)
            let oldThinking = try #require(completion.visibleThinking)
            #expect(try await fixture.library.read(oldAnswer) == Data("old partial answer".utf8))
            #expect(try await fixture.library.read(oldThinking) == Data("old thinking".utf8))
            let retry = AgentSubmitCommand(id: UUID(), sessionID: original.sessionID, executionID: ExecutionID(),
                input: .retry(executionID: original.executionID), options: original.options)
            fault.setArmed(true)
            let pending = await fixture.application.submit(retry)
            guard case .indeterminate(let batchID, _) = pending else {
                Issue.record("A failed retry deletion must fence dispatch"); await fixture.close(); return
            }
            #expect(batchID == retry.id)
            #expect(fixture.transport.requestCount == 1)
            let queued = try await fixture.application.sessionSnapshot(id: original.sessionID)
            // An uncertain append is not reflected in the authoritative state
            // until reconciliation; exposing its tentative queued execution
            // would let admission appear durable before the journal outcome is known.
            #expect(queued.executions[retry.executionID] == nil)
            #expect(await fixture.application.submit(retry) == pending)

            if reopen {
                // Shutdown cannot finish the armed deletion. A fresh file library
                // must delete the retired bytes before startup settles the retry.
                try await fixture.reopen()
                #expect(fixture.transport.requestCount == 1)
                let recovered = try await fixture.application.sessionSnapshot(id: original.sessionID)
                #expect(recovered.executions[retry.executionID]?.completion != nil)
                #expect(recovered.activeExecutionID == nil)
            } else {
                fault.setArmed(false)
                try requireCommitted(await fixture.application.reconcileAdmission(commandID: retry.id))
                try requireCommitted(await fixture.application.waitForExecution(id: retry.executionID, sessionID: retry.sessionID))
                let answered = try await fixture.application.sessionSnapshot(id: original.sessionID)
                let answer = try #require(answered.executions[retry.executionID]?.completion)
                #expect(answer.status == .completed)
                #expect(try await fixture.library.read(try #require(answer.answer)) == Data("answer".utf8))
                #expect(fixture.transport.requestCount == 2)
                let request = try #require(fixture.transport.requests.last?.httpBody)
                let requestText = String(decoding: request, as: UTF8.self)
                #expect(requestText.contains("Question"))
                #expect(!requestText.contains("old partial answer"))
                #expect(!requestText.contains("old thinking"))
                try requireCommitted(await fixture.application.submit(retry))
                #expect(fixture.transport.requestCount == 2)
                try await fixture.reopen()
                #expect(fixture.transport.requestCount == 2)
            }
            #expect(try await fixture.library.read(oldAnswer) == Data("old partial answer".utf8))
            #expect(try await fixture.library.read(oldThinking) == Data("old thinking".utf8))
            #expect(try await fixture.library.read(try #require(source.admission.userBody)) == Data("Question".utf8))
            #expect(try await fixture.library.read(source.admission.plan).isEmpty == false)
            await fixture.close()
        } catch {
            fault.setArmed(false)
            await fixture.close()
            throw error
        }
    }

    private static let toolTurn = Data("""
    data: {"choices":[{"delta":{"reasoning_content":"plan"}}]}

    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"tests_read","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}

    data: [DONE]

    """.utf8)

    private static let answerTurn = Data("""
    data: {"choices":[{"delta":{"reasoning_content":"final plan"}}]}

    data: {"choices":[{"delta":{"content":"answer"}}]}

    data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

    data: [DONE]

    """.utf8)

    private static let interruptedThinking = Data("""
    data: {"choices":[{"delta":{"reasoning_content":"partial"}}]}

    """.utf8)

    private static func assertSecondRequestContainsPriorExchange(_ payload: JSONValue) throws {
        guard case .array(let messages) = payload["messages"] else {
            Issue.record("The second HTTP request did not contain messages")
            return
        }
        let assistant = try #require(messages.compactMap { value -> JSONValue? in
            guard value["role"] == .string("assistant") else { return nil }
            return value
        }.first)
        #expect(assistant["reasoning_content"] == .string("plan"))
        guard case .array(let calls) = assistant["tool_calls"], let call = calls.first else {
            Issue.record("The prior assistant tool call was not replayed")
            return
        }
        #expect(call["id"] == .string("call-1"))
        #expect(call["function"]?["name"] == .string("tests_read"))
        let tool = try #require(messages.compactMap { value -> JSONValue? in
            guard value["role"] == .string("tool") else { return nil }
            return value
        }.first)
        #expect(tool["tool_call_id"] == .string("call-1"))
        let result = try SessionCodec.decode(JSONValue.self, from: Data(try #require(tool["content"]?.stringValue).utf8))
        #expect(result["authority"] == .string("untrusted_tool_observation"))
        #expect(result["content"] == .object(["ok": .bool(true)]))
    }
}

private final class RetryJournalFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    func setArmed(_ value: Bool) { lock.withLock { armed = value } }
    func check(_ stage: SessionStorageFaultStage) throws {
        if stage == .afterJournalWrite, lock.withLock({ armed }) {
            throw MiraError(.storage, "Fixture retry journal write became uncertain.")
        }
    }
}

private actor FixtureLibraryMaintenanceStore: AgentLibraryMaintenanceStore {
    private let value = AgentLibraryAuthorization(libraryID: UUID(), epoch: 0)
    func state() async throws -> AgentLibraryMaintenanceState { .init(authorization: value, pending: nil) }
    func operation(id: UUID) async throws -> AgentLibraryMaintenanceOperation? { nil }
    func begin(_ request: AgentLibraryMaintenanceRequest, expected: AgentLibraryAuthorization) async throws -> AgentLibraryMaintenanceOperation { throw MiraError(.unsupported, "Fixture maintenance is unavailable.") }
    func complete(_ operation: AgentLibraryMaintenanceOperation, at date: Date) async throws -> AgentLibraryMaintenanceOperation { throw MiraError(.unsupported, "Fixture maintenance is unavailable.") }
}

private final class HTTPApplicationFixture: @unchecked Sendable {
    let directory: URL
    let transport: FixtureTransport
    let credentials: FixtureCredentials
    let tool: FixtureReadTool
    let libraryAccess: AgentLibraryAccess
    var library: FileSessionLibrary
    var application: AgentApplicationRuntime
    private var closed = false

    private init(directory: URL, transport: FixtureTransport, credentials: FixtureCredentials,
                 tool: FixtureReadTool, library: FileSessionLibrary, application: AgentApplicationRuntime, libraryAccess: AgentLibraryAccess) {
        self.directory = directory; self.transport = transport; self.credentials = credentials
        self.tool = tool; self.library = library; self.application = application; self.libraryAccess = libraryAccess
    }

    static func make(responses: [Data], faultInjector: SessionStorageFaultInjector? = nil) async throws -> HTTPApplicationFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-http-application-\(UUID().uuidString)")
        let transport = FixtureTransport(responses: responses)
        let credentials = FixtureCredentials()
        let tool = FixtureReadTool()
        var library: FileSessionLibrary?
        do {
            let openedLibrary = try FileSessionLibrary(directory: directory, faultInjector: faultInjector)
            library = openedLibrary
            let adapter = HTTPModelAdapter(fixture: .deepSeek, credentials: credentials, transport: transport)
            let registry = RuntimeRegistry<AgentCapability>()
            let libraryAccess = try await AgentLibraryAccess.open(store: FixtureLibraryMaintenanceStore())
            let application = try await AgentApplicationRuntime.open(journal: openedLibrary, payloads: openedLibrary, libraryAccess: libraryAccess, registry: registry,
                modules: [HTTPFixtureModule(registry: registry, adapter: adapter, tool: tool)], policy: AllowFixturePolicy(),
                authority: AllowFixtureAuthority(value: await libraryAccess.snapshot().authorization), business: NoopFixtureBusiness(), authorizer: AllowFixtureAuthorizer(),
                approvals: RuntimeApprovalService(), scheduler: RuntimeScheduler(modelCapacity: 1, backgroundCapacity: 1))
            return .init(directory: directory, transport: transport, credentials: credentials, tool: tool,
                         library: openedLibrary, application: application, libraryAccess: libraryAccess)
        } catch {
            try? await library?.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func command() -> AgentSubmitCommand {
        .init(id: UUID(), sessionID: ConversationID(), executionID: ExecutionID(),
              input: .message(id: MessageID(), text: "Question", timeZoneIdentifier: "UTC"),
              options: .init(instructions: "Answer", route: route()),
              opening: .init(title: "HTTP fixture", workspaceID: nil))
    }

    func reopen() async throws {
        _ = await application.shutdown()
        try await library.close()
        library = try FileSessionLibrary(directory: directory)
        let adapter = HTTPModelAdapter(fixture: .deepSeek, credentials: credentials, transport: transport)
        let registry = RuntimeRegistry<AgentCapability>()
        application = try await AgentApplicationRuntime.open(journal: library, payloads: library, libraryAccess: libraryAccess, registry: registry,
            modules: [HTTPFixtureModule(registry: registry, adapter: adapter, tool: tool)], policy: AllowFixturePolicy(),
            authority: AllowFixtureAuthority(value: await libraryAccess.snapshot().authorization), business: NoopFixtureBusiness(), authorizer: AllowFixtureAuthorizer(),
            approvals: RuntimeApprovalService(), scheduler: RuntimeScheduler(modelCapacity: 1, backgroundCapacity: 1))
    }

    func close() async {
        guard !closed else { return }
        closed = true
        _ = await application.shutdown()
        await libraryAccess.close()
        try? await library.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func route() -> AgentModelRoute {
        .init(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
              modelDescriptorID: ModelDescriptorID(), modelRevision: 1, adapter: ProtocolFixture.deepSeek.identity,
              modelID: "fixture-thinking", credential: .init(reference: "fixture", version: 1), contextWindow: 32_768,
              maximumOutputTokens: 4_096,
              capabilities: .init(streamsText: true, callsTools: true, producesThinking: true),
              configuration: try! HTTPModelConfiguration(baseURL: "https://fixture.test/v1",
                  protocolID: ProtocolFixture.deepSeek.protocolID, dialectProfileID: ProtocolFixture.deepSeek.dialect,
                  thinking: .init(mode: .enabled)).jsonValue())
    }
}

private final class FixtureCredentials: CredentialReader, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var readCount = 0
    func read(reference: String, version: Int) throws -> String {
        lock.lock(); readCount += 1; lock.unlock()
        return "fixture-secret"
    }
}

private final class FixtureTransport: HTTPStreamingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Data]
    private(set) var requests: [URLRequest] = []
    init(responses: [Data]) { self.responses = responses }
    var requestCount: Int { lock.withLock { requests.count } }
    func stream(request: URLRequest) -> HTTPTransportOperation {
        let response: Data = lock.withLock {
            requests.append(request)
            return responses.isEmpty ? Data() : responses.removeFirst()
        }
        let (events, continuation) = AsyncThrowingStream<HTTPTransportEvent, any Error>.makeStream()
        continuation.yield(.response(.init(statusCode: 200)))
        continuation.yield(.bytes(response))
        continuation.yield(.end)
        continuation.finish()
        return HTTPTransportOperation(events: events) {}
    }
}

private actor FixtureReadTool: AgentReadTool {
    nonisolated let policy: AgentToolPolicyRequirement = .hostOnly
    let descriptor: AgentToolDescriptor
    private(set) var executeCount = 0

    init() {
        let definition = ToolDefinition(name: "tests.read", description: "Read fixture data.", inputSchema: .object([
            "type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)
        ]))
        descriptor = .init(definition: definition, revision: 1, outputSchema: .object([
            "type": .string("object"), "properties": .object(["ok": .object(["type": .string("boolean")])]),
            "required": .array([.string("ok")]), "additionalProperties": .bool(false)
        ]), executionMode: .exclusive, timeoutMilliseconds: 1_000, maximumResultBytes: 1_024)
    }

    func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan {
        .init(input: arguments, sources: [], targets: [])
    }

    func execute(_ plan: AgentToolPlan, context: AgentToolContext) async throws -> JSONValue {
        executeCount += 1
        return .object(["ok": .bool(true)])
    }
}

private struct HTTPFixtureModule: RuntimeModule {
    let registry: RuntimeRegistry<AgentCapability>
    let adapter: HTTPModelAdapter
    let tool: FixtureReadTool
    let id = "tests.http"
    let dependencies: Set<String> = []
    func activate(in scope: RuntimeScope) async throws {
        try await registry.register(id: "model", value: .model(adapter), scope: scope)
        try await registry.register(id: "tool", value: .tool(.read(tool)), scope: scope)
        try await registry.register(id: "driver", value: .driver(DefaultAgentDriver()), scope: scope)
    }
}

private struct AllowFixturePolicy: AgentToolPolicy {
    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision { .allow }
    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws {}
}
private struct AllowFixtureAuthority: AgentEffectAuthority {
    let value: AgentLibraryAuthorization
    func authorization(for proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentLibraryAuthorization { value }
    func validate(_ authorization: AgentLibraryAuthorization, proposal: AgentToolProposal, context: AgentToolContext) async throws {}
}
private struct AllowFixtureAuthorizer: AgentSourceAuthorizer {
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {}
}
private struct NoopFixtureBusiness: AgentBusinessEffects {
    func fenceExecution(sessionID: ConversationID, executionID: ExecutionID) async throws {}
    func commit(_ proof: AgentEffectProof) async -> AgentBusinessCommitOutcome { .notCommitted(.init(.unsupported, "No business effects in fixture.")) }
    func receipt(for proof: AgentEffectProof) async -> AgentBusinessReceiptLookup { .absent }
    func unpublished(after receiptID: UUID?, limit: Int) async throws -> [AgentReceiptPublication] { [] }
    func acknowledge(_ receipt: AgentBusinessReceiptReference, at cursor: SessionCursor) async throws {}
}

private func requireCommitted(_ result: SessionCommitResult) throws {
    guard case .committed = result else {
        Issue.record("Expected committed result: \(result)")
        throw MiraError(.storage, "Fixture operation did not commit.")
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
