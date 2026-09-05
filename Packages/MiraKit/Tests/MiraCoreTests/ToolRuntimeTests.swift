import Foundation
import Testing
import MiraCore
import MiraData

struct ToolRuntimeTests {
    @Test func twoStepsKeepCompleteExchangeButNextTurnDoesNotReuseToolObservations() async throws {
        let fixture = try ToolFixture()
        defer { fixture.cleanup() }
        let call = CanonicalToolCall(id: "call-1", name: "fixture.read", arguments: "{\"query\":\"hello\"}")
        let provider = ScriptedToolProvider(store: fixture.store, replies: [
            [.textDelta("Checking"), .toolCalls([call]), .usage(.init(inputTokens: 10, outputTokens: 3)), .finished(.toolCalls)],
            [.textDelta("Final answer"), .usage(.init(inputTokens: 20, outputTokens: 4)), .finished(.stop)],
            [.textDelta("Next answer"), .finished(.stop)]
        ])
        let tool = FixtureTool(name: "fixture.read") { _, _ in "ephemeral-secret-result" }
        let app = try MiraApplication(store: fixture.store, provider: provider, tools: ToolRegistry([tool]))
        let conversation = try await app.createConversation(workspaceID: nil)
        let id = try await app.send(conversationID: conversation, text: "current input", routeID: fixture.route.id)
        try await toolEventually { try fixture.store.executions(in: conversation).last?.status.isTerminal == true }
        #expect(try fixture.store.executions(in: conversation).last?.status == .completed)
        let requests = provider.requests
        #expect(requests.count == 2)
        #expect(Set(requests.map(\.dispatchID)).count == 2)
        #expect(provider.snapshotsWereDurable)
        #expect(requests[1].messages.filter { $0.role == .user && $0.text == "current input" }.count == 1)
        #expect(requests[1].messages.suffix(2).map(\.role) == [.assistant, .tool])
        #expect(requests[1].messages.last?.toolCallID == call.id)
        #expect(requests[1].messages.last?.text.contains("ephemeral-secret-result") == true)
        let audit = try await app.audit(for: id)
        #expect(audit.attempts.map(\.stepIndex) == [1, 2])
        #expect(audit.attempts.allSatisfy { $0.status == .completed })
        #expect(audit.invocations.map { $0.result?.status } == [.succeeded])
        #expect(try fixture.store.executions(in: conversation).last?.usage == .init(inputTokens: 30, outputTokens: 7))
        _ = try await app.send(conversationID: conversation, text: "next input", routeID: fixture.route.id)
        try await toolEventually { provider.requests.count == 3 }
        #expect(!provider.requests[2].messages.contains { $0.role == .tool || $0.toolCalls != nil || $0.text.contains("ephemeral-secret-result") })
        #expect(provider.requests[2].messages.map(\.text) == ["current input", "Checking\n\nFinal answer", "next input"])
        await app.shutdown()
    }

    @Test func invalidUnknownDeniedAndOversizedResultsArePairedInModelOrder() async throws {
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        let recorder = ToolRecorder()
        let calls = [
            CanonicalToolCall(id: "invalid", name: "fixture.read", arguments: "{\"query\":1}"),
            CanonicalToolCall(id: "missing", name: "missing.tool", arguments: "{}"),
            CanonicalToolCall(id: "denied", name: "fixture.write", arguments: "{\"query\":\"q\"}"),
            CanonicalToolCall(id: "large", name: "fixture.large", arguments: "{\"query\":\"q\"}")
        ]
        let provider = ScriptedToolProvider(store: fixture.store, replies: [[.toolCalls(calls), .finished(.toolCalls)], [.textDelta("All checked"), .finished(.stop)]])
        let read = FixtureTool(name: "fixture.read") { _, _ in await recorder.enter("invalid executed"); return "bad" }
        let write = FixtureTool(name: "fixture.write", mode: .exclusive, sideEffect: .write) { _, _ in await recorder.enter("denied executed"); return "bad" }
        let large = FixtureTool(name: "fixture.large", maxBytes: 4) { _, _ in "too much" }
        let app = try MiraApplication(store: fixture.store, provider: provider, tools: ToolRegistry([read, write, large]))
        let conversation = try await app.createConversation(workspaceID: nil)
        let id = try await app.send(conversationID: conversation, text: "do checks", routeID: fixture.route.id)
        try await toolEventually { try fixture.store.executions(in: conversation).last?.status.isTerminal == true }
        let audit = try await app.audit(for: id)
        #expect(audit.invocations.map { $0.result?.status } == [.invalidArguments, .notFound, .denied, .outputLimit])
        #expect(provider.requests.last?.messages.filter { $0.role == .tool }.map(\.toolCallID) == calls.map { Optional($0.id) })
        #expect(await recorder.events.isEmpty)
        await app.shutdown()
    }

    @Test func parallelSafeBatchesRespectExclusiveBarriersAndReturnOriginalOrder() async throws {
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        let recorder = ToolRecorder()
        let modes: [(String, ToolExecutionMode)] = [("a", .parallelSafe), ("b", .parallelSafe), ("barrier", .exclusive), ("c", .parallelSafe)]
        let ports: [any ToolPort] = modes.map { name, mode in
            FixtureTool(name: name, mode: mode) { _, _ in
                await recorder.start(name, exclusive: mode == .exclusive)
                try await Task.sleep(for: .milliseconds(name == "a" ? 30 : 10))
                await recorder.end(name)
                return name
            }
        }
        let calls = modes.map { CanonicalToolCall(id: $0.0, name: $0.0, arguments: "{\"query\":\"q\"}") }
        let provider = ScriptedToolProvider(store: fixture.store, replies: [[.toolCalls(calls), .finished(.toolCalls)], [.textDelta("done"), .finished(.stop)]])
        let app = try MiraApplication(store: fixture.store, provider: provider, tools: ToolRegistry(ports))
        let conversation = try await app.createConversation(workspaceID: nil)
        let id = try await app.send(conversationID: conversation, text: "parallel", routeID: fixture.route.id)
        try await toolEventually { try fixture.store.executions(in: conversation).last?.status.isTerminal == true }
        #expect(await recorder.peak == 2)
        #expect(await recorder.barrierViolations == 0)
        let events = await recorder.events
        #expect(events.firstIndex(of: "end a")! < events.firstIndex(of: "start barrier")!)
        #expect(events.firstIndex(of: "end b")! < events.firstIndex(of: "start barrier")!)
        #expect(events.firstIndex(of: "end barrier")! < events.firstIndex(of: "start c")!)
        #expect(try await app.audit(for: id).invocations.map { $0.result?.text } == ["a", "b", "barrier", "c"])
        await app.shutdown()
    }

    @Test func cancellationProducesReceiptsForUnscheduledToolsWithoutRunningThem() async throws {
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        let recorder = ToolRecorder()
        let hold = FixtureTool(name: "hold", mode: .exclusive) { _, _ in
            await recorder.enter("hold started")
            try await Task.sleep(for: .seconds(3_600)); return "unreachable"
        }
        let later = FixtureTool(name: "later") { _, _ in await recorder.enter("later executed"); return "wrong" }
        let calls = ["hold", "later", "later"].enumerated().map { CanonicalToolCall(id: "id-\($0.offset)", name: $0.element, arguments: "{\"query\":\"q\"}") }
        let provider = ScriptedToolProvider(store: fixture.store, replies: [[.textDelta("Starting"), .toolCalls(calls), .finished(.toolCalls)]])
        let app = try MiraApplication(store: fixture.store, provider: provider, tools: ToolRegistry([hold, later]))
        let conversation = try await app.createConversation(workspaceID: nil)
        let id = try await app.send(conversationID: conversation, text: "cancel", routeID: fixture.route.id)
        try await toolEventually { try fixture.store.toolInvocations(for: id).first?.dispatchedAt != nil }
        await app.cancel(id)
        try await toolEventually { try fixture.store.executions(in: conversation).last?.status.isTerminal == true }
        let audit = try await app.audit(for: id)
        #expect(audit.invocations.map { $0.result?.status } == [.cancelled, .cancelledBeforeDispatch, .cancelledBeforeDispatch])
        #expect(await recorder.events == ["hold started"])
        #expect(provider.requests.count == 1)
        #expect(try fixture.store.messages(in: conversation).last?.text == "Starting")
        await app.shutdown()
    }

    @Test func toolTimeoutUsesInjectedClockAndDoesNotClaimSuccess() async throws {
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        let began = AsyncSignal()
        let tool = FixtureTool(name: "slow", timeout: .seconds(1)) { _, _ in
            await began.signal()
            try await Task.sleep(for: .seconds(3_600)); return "unreachable"
        }
        let environment = RuntimeEnvironment(sleep: { duration in
            if duration == .seconds(1) { await began.wait() }
            else { try await Task.sleep(for: duration) }
        })
        let call = CanonicalToolCall(id: "slow-1", name: "slow", arguments: "{\"query\":\"q\"}")
        let provider = ScriptedToolProvider(store: fixture.store, replies: [[.toolCalls([call]), .finished(.toolCalls)], [.textDelta("Timed out"), .finished(.stop)]])
        let app = try MiraApplication(store: fixture.store, provider: provider, environment: environment, tools: ToolRegistry([tool]))
        let conversation = try await app.createConversation(workspaceID: nil)
        let id = try await app.send(conversationID: conversation, text: "slow", routeID: fixture.route.id)
        try await toolEventually { try fixture.store.executions(in: conversation).last?.status.isTerminal == true }
        #expect(try await app.audit(for: id).invocations.first?.result?.status == .timedOut)
        #expect(provider.requests.count == 2)
        await app.shutdown()
    }

    @Test func stepToolAndOutputReservationBudgetsStopBeforeExtraDispatch() async throws {
        for kind in 0..<3 {
            let fixture = try ToolFixture(); defer { fixture.cleanup() }
            let recorder = ToolRecorder()
            let tool = FixtureTool(name: "read") { _, _ in await recorder.enter("read"); return "read" }
            let calls = (0..<(kind == 1 ? 2 : 1)).map { CanonicalToolCall(id: "id-\($0)", name: "read", arguments: "{\"query\":\"q\"}") }
            let provider = ScriptedToolProvider(store: fixture.store, replies: [[.toolCalls(calls), .finished(.toolCalls)], [.textDelta("must not send"), .finished(.stop)]])
            let limits = ExecutionLimits(maxSteps: kind == 0 ? 1 : 20, maxToolCalls: kind == 1 ? 1 : 32, maxReservedOutputTokens: kind == 2 ? fixture.route.maxOutputTokens : 32_768)
            let app = try MiraApplication(store: fixture.store, provider: provider, tools: ToolRegistry([tool]), limits: limits)
            let conversation = try await app.createConversation(workspaceID: nil)
            let id = try await app.send(conversationID: conversation, text: "limits", routeID: fixture.route.id)
            try await toolEventually { try fixture.store.executions(in: conversation).last?.status.isTerminal == true }
            #expect(provider.requests.count == 1)
            #expect(try fixture.store.executions(in: conversation).last?.error?.code == .outputLimit)
            #expect(try await app.audit(for: id).invocations.allSatisfy { $0.result != nil })
            if kind == 1 { #expect(await recorder.events.isEmpty) }
            await app.shutdown()
        }
    }

    @Test func unknownCapabilityDoesNotExposeToolsAndMalformedPairingNeverExecutes() async throws {
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        var unverified = fixture.configuration.model
        unverified.toolCapability = .unknown
        unverified.revision += 1
        try fixture.store.saveModel(unverified, expectedRevision: fixture.configuration.model.revision)
        let recorder = ToolRecorder()
        let tool = FixtureTool(name: "read") { _, _ in await recorder.enter("unsafe"); return "wrong" }
        let provider = ScriptedToolProvider(store: fixture.store, replies: [[.toolCalls([.init(id: "id", name: "read", arguments: "{}")]), .finished(.toolCalls)]])
        let app = try MiraApplication(store: fixture.store, provider: provider, tools: ToolRegistry([tool]))
        let conversation = try await app.createConversation(workspaceID: nil)
        _ = try await app.send(conversationID: conversation, text: "unverified tools", routeID: fixture.route.id)
        try await toolEventually { try fixture.store.executions(in: conversation).last?.status.isTerminal == true }
        #expect(provider.requests.first?.tools == nil)
        #expect(await recorder.events.isEmpty)
        #expect(try fixture.store.executions(in: conversation).last?.error?.code == .malformedStream)
        await app.shutdown()
    }

    @Test func policyTighteningDuringAuthorizationPreventsDispatch() async throws {
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        let recorder = ToolRecorder()
        let tool = FixtureTool(name: "guarded", authorize: { _, _ in
            await recorder.enter("authorization began")
            try await Task.sleep(for: .seconds(3_600))
        }) { _, _ in await recorder.enter("must not execute"); return "wrong" }
        let provider = ScriptedToolProvider(store: fixture.store, replies: [[.toolCalls([.init(id: "guarded-1", name: "guarded", arguments: "{\"query\":\"q\"}")]), .finished(.toolCalls)]])
        let app = try MiraApplication(store: fixture.store, provider: provider, tools: ToolRegistry([tool]))
        let workspaceID = try await app.createWorkspace(name: "Private after start", background: "context", allowsRemoteSend: true)
        let conversation = try await app.createConversation(workspaceID: workspaceID)
        let id = try await app.send(conversationID: conversation, text: "guard", routeID: fixture.route.id)
        try await toolEventually { await recorder.events.contains("authorization began") }
        var workspace = try #require(fixture.store.workspaces().first)
        workspace.allowsRemoteSend = false
        try await app.updateWorkspace(workspace)
        try await toolEventually { try fixture.store.executions(in: conversation).last?.status.isTerminal == true }
        #expect(try await app.audit(for: id).invocations.first?.result?.status == .cancelledBeforeDispatch)
        #expect(try await app.audit(for: id).invocations.first?.dispatchedAt == nil)
        #expect(await recorder.events == ["authorization began"])
        #expect(provider.requests.count == 1)
        await app.shutdown()
    }

    @Test func entireTurnDeadlineIsDistinctFromUserCancellation() async throws {
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        let began = AsyncSignal()
        let tool = FixtureTool(name: "slow") { _, _ in
            await began.signal(); try await Task.sleep(for: .seconds(3_600)); return "unreachable"
        }
        let environment = RuntimeEnvironment(sleep: { duration in
            if duration == .seconds(1) { await began.wait() } else { try await Task.sleep(for: duration) }
        })
        let provider = ScriptedToolProvider(store: fixture.store, replies: [[.toolCalls([.init(id: "slow-1", name: "slow", arguments: "{\"query\":\"q\"}")]), .finished(.toolCalls)]])
        let app = try MiraApplication(store: fixture.store, provider: provider, environment: environment, tools: ToolRegistry([tool]), limits: .init(turnTimeout: .seconds(1)))
        let conversation = try await app.createConversation(workspaceID: nil)
        _ = try await app.send(conversationID: conversation, text: "deadline", routeID: fixture.route.id)
        try await toolEventually { try fixture.store.executions(in: conversation).last?.status.isTerminal == true }
        #expect(try fixture.store.executions(in: conversation).last?.error?.code == .timeout)
        #expect(try fixture.store.executions(in: conversation).last?.status == .interrupted)
        #expect(provider.requests.count == 1)
        await app.shutdown()
    }

    @Test func completeExchangeOverContextBudgetNeverDispatchesAnOrphanedRequest() async throws {
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        var small = fixture.configuration.model
        small.contextWindow = 8_192
        small.revision += 1
        try fixture.store.saveModel(small, expectedRevision: fixture.configuration.model.revision)
        let tool = FixtureTool(name: "read") { _, _ in String(repeating: "x", count: 9_000) }
        let provider = ScriptedToolProvider(store: fixture.store, replies: [[.toolCalls([.init(id: "read-1", name: "read", arguments: "{\"query\":\"q\"}")]), .finished(.toolCalls)]])
        let app = try MiraApplication(store: fixture.store, provider: provider, tools: ToolRegistry([tool]))
        let conversation = try await app.createConversation(workspaceID: nil)
        let id = try await app.send(conversationID: conversation, text: "budget", routeID: fixture.route.id)
        try await toolEventually { try fixture.store.executions(in: conversation).last?.status.isTerminal == true }
        #expect(try fixture.store.executions(in: conversation).last?.error?.code == .contextLimit)
        #expect(provider.requests.count == 1)
        #expect(try await app.audit(for: id).invocations.first?.result?.status == .succeeded)
        await app.shutdown()
    }

    @Test func repeatedCallsWithIdenticalObservationsStopWithoutARepeatedNetworkRequest() async throws {
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        let replies: [[CanonicalStreamEvent]] = (1...3).map { index in
            [.toolCalls([.init(id: "repeat-\(index)", name: "read", arguments: "{\"query\":\"q\"}")]), .finished(.toolCalls)]
        }
        let provider = ScriptedToolProvider(store: fixture.store, replies: replies)
        let tool = FixtureTool(name: "read") { _, _ in "unchanged observation" }
        let app = try MiraApplication(store: fixture.store, provider: provider, tools: ToolRegistry([tool]))
        let conversation = try await app.createConversation(workspaceID: nil)
        let id = try await app.send(conversationID: conversation, text: "repeat", routeID: fixture.route.id)
        try await toolEventually { try fixture.store.executions(in: conversation).last?.status.isTerminal == true }
        #expect(provider.requests.count == 3)
        #expect(try fixture.store.executions(in: conversation).last?.error?.code == .outputLimit)
        #expect(try await app.audit(for: id).invocations.count == 3)
        #expect(try await app.audit(for: id).invocations.allSatisfy { $0.result?.status == .succeeded })
        await app.shutdown()
    }

    @Test func schemaRejectsUnknownKeysAndRegistryRejectsWireNameCollisions() throws {
        let tool = FixtureTool(name: "memory.read") { _, _ in "" }
        #expect(throws: MiraError.self) { try ToolSchemaValidator.decode("{\"query\":\"q\",\"approved\":true}", schema: tool.descriptor.definition.inputSchema) }
        #expect(throws: MiraError.self) { try ToolSchemaValidator.decode("[]", schema: tool.descriptor.definition.inputSchema) }
        let collision = FixtureTool(name: "memory_read") { _, _ in "" }
        #expect(throws: MiraError.self) { try ToolRegistry([tool, collision]) }
    }
}

private struct ToolFixture {
    let directory: URL
    let store: SQLiteMiraStore
    let route: ResolvedModelRouteSnapshot
    let configuration: StoredRouteFixture
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiraToolRuntime-\(UUID())")
        store = try SQLiteMiraStore(directory: directory)
        var snapshot = ResolvedModelRouteSnapshot(name: "Tools fixture", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", modelID: "fixture", credentialReference: "no-key", contextWindow: 262_144)
        snapshot.toolCapability = .declared
        route = snapshot
        configuration = StoredRouteFixture(snapshot)
        try configuration.install(in: store)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
private struct FixtureTool: ToolPort {
    let descriptor: ToolDescriptor
    let operation: @Sendable (JSONValue, ToolContext) async throws -> String
    let authorization: (@Sendable (JSONValue, ToolContext) async throws -> Void)?
    init(name: String, mode: ToolExecutionMode = .parallelSafe, sideEffect: ToolSideEffect = .read, timeout: Duration = .seconds(30), maxBytes: Int = 32_768, authorize: (@Sendable (JSONValue, ToolContext) async throws -> Void)? = nil, operation: @escaping @Sendable (JSONValue, ToolContext) async throws -> String) {
        descriptor = .init(definition: .init(name: name, description: "Synthetic test tool", inputSchema: .object([
            "type": .string("object"), "properties": .object(["query": .object(["type": .string("string"), "maxLength": .number(100)])]),
            "required": .array([.string("query")]), "additionalProperties": .bool(false)
        ])), executionMode: mode, sideEffect: sideEffect, timeout: timeout, maxResultBytes: maxBytes)
        self.operation = operation; self.authorization = authorize
    }
    func authorize(arguments: JSONValue, context: ToolContext) async throws {
        if let authorization { try await authorization(arguments, context) }
        else if descriptor.sideEffect == .write { throw MiraError(.unauthorized, "Synthetic write denied") }
    }
    func execute(arguments: JSONValue, context: ToolContext) async throws -> String { try await operation(arguments, context) }
}
private final class ScriptedToolProvider: ModelProviderPort, @unchecked Sendable {
    private let lock = NSLock()
    private let store: SQLiteMiraStore
    private let replies: [[CanonicalStreamEvent]]
    private var captured: [CanonicalModelRequest] = []
    private var checks: [Bool] = []
    init(store: SQLiteMiraStore, replies: [[CanonicalStreamEvent]]) { self.store = store; self.replies = replies }
    var requests: [CanonicalModelRequest] { lock.withLock { captured } }
    var snapshotsWereDurable: Bool { lock.withLock { !checks.isEmpty && checks.allSatisfy { $0 } } }
    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        let response: [CanonicalStreamEvent] = lock.withLock {
            let index = captured.count; captured.append(request)
            checks.append((try? store.attempts(for: request.executionID).last?.request) == request)
            return index < replies.count ? replies[index] : []
        }
        return AsyncThrowingStream { continuation in
            response.forEach { continuation.yield($0) }; continuation.finish()
        }
    }
}
private actor ToolRecorder {
    private(set) var events: [String] = []
    private var active = Set<String>()
    private(set) var peak = 0
    private(set) var barrierViolations = 0
    func enter(_ value: String) { events.append(value) }
    func start(_ name: String, exclusive: Bool) {
        if exclusive && !active.isEmpty { barrierViolations += 1 }
        if active.contains("barrier") { barrierViolations += 1 }
        active.insert(name); peak = max(peak, active.count); events.append("start \(name)")
    }
    func end(_ name: String) { active.remove(name); events.append("end \(name)") }
}
private actor AsyncSignal {
    private var signalled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func signal() { signalled = true; continuations.forEach { $0.resume() }; continuations = [] }
    func wait() async { if !signalled { await withCheckedContinuation { continuations.append($0) } } }
}
private func toolEventually(_ predicate: @Sendable () async throws -> Bool) async throws {
    for _ in 0..<400 {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw MiraError(.timeout, "Synthetic tool runtime condition timed out")
}
