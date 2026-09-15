import Foundation
import Testing
@testable import MiraProviders
import MiraCore

private final class FixtureCredentials: CredentialReader, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var reads = 0
    let value: String
    init(_ value: String = "fixture-secret") { self.value = value }
    func read(reference: String, version: Int) throws -> String {
        lock.lock(); reads += 1; lock.unlock()
        return value
    }
}

private final class FixtureOperationState: @unchecked Sendable {
    private let lock = NSLock()
    private let onClose: @Sendable () -> Void
    private var continuation: AsyncThrowingStream<HTTPTransportEvent, any Error>.Continuation?
    private var task: Task<Void, Never>?
    private var closed = false
    init(onClose: @escaping @Sendable () -> Void) { self.onClose = onClose }
    func install(_ continuation: AsyncThrowingStream<HTTPTransportEvent, any Error>.Continuation) { lock.lock(); self.continuation = continuation; lock.unlock() }
    func install(_ task: Task<Void, Never>) { lock.lock(); self.task = task; lock.unlock() }
    func yield(_ event: HTTPTransportEvent) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(event)
    }
    func fail(_ error: any Error) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.finish(throwing: error)
    }
    private func beginClose() -> Task<Void, Never>? {
        lock.lock()
        guard !closed else { lock.unlock(); return nil }
        closed = true
        let task = self.task
        let continuation = self.continuation
        lock.unlock()
        onClose()
        task?.cancel()
        continuation?.finish(throwing: URLError(.cancelled))
        return task
    }
    func close() async {
        let task = beginClose()
        await task?.value
    }
}

private final class FixtureTransport: HTTPStreamingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let events: [HTTPTransportEvent]
    private(set) var requests: [URLRequest] = []
    private(set) var cancellationCount = 0
    private let asynchronous: Bool
    init(events: [HTTPTransportEvent], asynchronous: Bool = false) { self.events = events; self.asynchronous = asynchronous }
    func stream(request: URLRequest) -> HTTPTransportOperation {
        lock.lock(); requests.append(request); lock.unlock()
        let state = FixtureOperationState { [weak self] in self?.lock.lock(); self?.cancellationCount += 1; self?.lock.unlock() }
        let stream = AsyncThrowingStream<HTTPTransportEvent, any Error> { continuation in
            state.install(continuation)
            if asynchronous {
                let task = Task {
                    for event in self.events {
                        if Task.isCancelled { return }
                        continuation.yield(event); await Task.yield()
                    }
                    continuation.finish()
                }
                state.install(task)
            } else {
                for event in self.events { continuation.yield(event) }
                continuation.finish()
            }
        }
        return HTTPTransportOperation(events: stream) { await state.close() }
    }
}

private enum FixtureTransportError: Error { case broken }

private final class ControlledTransport: HTTPStreamingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var state: FixtureOperationState?
    private(set) var isReady = false
    private(set) var cancellationCount = 0
    func stream(request: URLRequest) -> HTTPTransportOperation {
        let state = FixtureOperationState { [weak self] in self?.lock.lock(); self?.cancellationCount += 1; self?.lock.unlock() }
        let stream = AsyncThrowingStream<HTTPTransportEvent, any Error> { continuation in
            state.install(continuation); self.lock.lock(); self.state = state; self.isReady = true; self.lock.unlock()
        }
        return HTTPTransportOperation(events: stream) { await state.close() }
    }
    func send(_ event: HTTPTransportEvent) { lock.lock(); let state = self.state; lock.unlock(); state?.yield(event) }
    func fail() { lock.lock(); let state = self.state; self.state = nil; lock.unlock(); state?.fail(FixtureTransportError.broken) }
}

private final class MultiControlledTransport: HTTPStreamingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: [(token: String, state: FixtureOperationState)]] = [:]
    private(set) var cancelledIDs: [String] = []
    var readyCount: Int { lock.lock(); defer { lock.unlock() }; return states.values.reduce(0) { $0 + $1.count } }
    func stream(request: URLRequest) -> HTTPTransportOperation {
        let id = request.value(forHTTPHeaderField: "X-Mira-Request-ID")!
        let token = UUID().uuidString
        let state = FixtureOperationState { [weak self] in
            self?.lock.lock(); self?.cancelledIDs.append("\(id)#\(token)")
            self?.states[id]?.removeAll { $0.token == token }
            if self?.states[id]?.isEmpty == true { self?.states.removeValue(forKey: id) }
            self?.lock.unlock()
        }
        let stream = AsyncThrowingStream<HTTPTransportEvent, any Error> { continuation in
            state.install(continuation); self.lock.lock(); self.states[id, default: []].append((token, state)); self.lock.unlock()
        }
        return HTTPTransportOperation(events: stream) { await state.close() }
    }
    func send(id: String, _ event: HTTPTransportEvent) { lock.lock(); let state = states[id]?.first?.state; lock.unlock(); state?.yield(event) }
}

private struct FixtureAdapter: Sendable {
    let fixture: ProtocolFixture
    let credentials: any CredentialReader
    let transport: any HTTPStreamingTransport
    init(fixture: ProtocolFixture = .standard, credentials: any CredentialReader, transport: any HTTPStreamingTransport) {
        self.fixture = fixture; self.credentials = credentials; self.transport = transport
    }
    func operation(input: AgentModelInput, route: AgentModelRoute) throws -> AgentModelOperation {
        let adapter = HTTPModelAdapter(fixture: fixture, credentials: credentials, transport: transport)
        return adapter.stream(try adapter.prepare(input, route: route), route: route)
    }
    func collect(input: AgentModelInput, route: AgentModelRoute) async throws -> [AgentModelStreamEvent] {
        let operation = try operation(input: input, route: route)
        var result: [AgentModelStreamEvent] = []
        do {
            for try await event in operation.events { result.append(event) }
            await operation.close()
            return result
        } catch {
            await operation.close()
            throw error
        }
    }
}

private func route(_ fixture: ProtocolFixture = .standard, baseURL: String = "https://example.test",
                   modelID: String = "fixture-model", thinking: ThinkingSettings = .init(), callsTools: Bool = false,
                   contextWindow: Int = 4096) -> AgentModelRoute {
    let configuration = HTTPModelConfiguration(baseURL: baseURL, protocolID: fixture.protocolID,
                                                dialectProfileID: fixture.dialect, thinking: thinking)
    return .init(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
                 modelDescriptorID: ModelDescriptorID(), modelRevision: 1, adapter: fixture.adapter,
                 modelID: modelID, credential: .init(reference: "fixture", version: 1), contextWindow: contextWindow,
                 maximumOutputTokens: 128, capabilities: .init(streamsText: true, callsTools: callsTools, producesThinking: true),
                 configuration: try! configuration.jsonValue())
}

private func request() -> AgentModelInput {
    .init(stepID: UUID(), executionID: ExecutionID(), instructions: "Be concise.", messages: [.init(role: .user, text: "Hello")], tools: [])
}

private func sse(_ frames: [(String, String)]) -> [UInt8] {
    Array(frames.flatMap { event, data in Array("\(event.isEmpty ? "" : "event: \(event)\n")data: \(data)\n\n".utf8) })
}

private func split(_ bytes: [UInt8], sizes: [Int]) -> [Data] {
    var result: [Data] = []
    var offset = 0
    var index = 0
    while offset < bytes.count {
        let size = sizes[index % sizes.count]
        let end = min(bytes.count, offset + size)
        result.append(Data(bytes[offset..<end]))
        offset = end; index += 1
    }
    return result
}

private func openAIEvents(_ chunks: [Data], status: Int = 200) -> [HTTPTransportEvent] {
    [.response(HTTPTransportResponse(statusCode: status))] + chunks.map(HTTPTransportEvent.bytes) + [.end]
}

private func anthropicEvents(_ chunks: [Data], status: Int = 200) -> [HTTPTransportEvent] {
    [.response(HTTPTransportResponse(statusCode: status))] + chunks.map(HTTPTransportEvent.bytes) + [.end]
}

@Test("OpenAI text, usage and terminal are normalized across split UTF8 bytes")
func openAIHappyPath() async throws {
    // Keep these Chinese scalars to verify UTF-8 bytes split across network chunks.
    let bytes = sse([
        ("", #"{"choices":[{"delta":{"content":"你"},"finish_reason":null}]}"#), // i18n-fixture: Preserve non-ASCII input to verify Unicode behavior.
        ("", #"{"choices":[{"delta":{"content":"好"},"finish_reason":null}]}"#), // i18n-fixture: Preserve non-ASCII input to verify Unicode behavior.
        ("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#),
        ("", #"{"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#),
        ("", "[DONE]")
    ])
    let transport = FixtureTransport(events: openAIEvents(split(bytes, sizes: [1, 2, 3, 5, 8])))
    let provider = FixtureAdapter(credentials: FixtureCredentials(), transport: transport)
    var events: [AgentModelStreamEvent] = []
    events = try await provider.collect(input: request(), route: route())
    #expect(textDeltas(events) == ["你", "好"]) // i18n-fixture: Preserve non-ASCII input to verify Unicode behavior.
    #expect(events.contains(.usage(TokenUsage(inputTokens: 3, outputTokens: 2))))
    #expect(events.last == .finished(.stop))
}

@Test("Anthropic handles multiline data, ping and output limit")
func anthropicPath() async throws {
    let frames = [
        ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":4,"output_tokens":0}}}"#),
        ("ping", #"{"type":"ping"}"#),
        ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":7}}"#),
        ("message_stop", #"{"type":"message_stop"}"#)
    ]
    let transport = FixtureTransport(events: anthropicEvents(split(sse(frames), sizes: [2, 7, 1, 11])))
    let provider = FixtureAdapter(fixture: .anthropic, credentials: FixtureCredentials(), transport: transport)
    var events: [AgentModelStreamEvent] = []
    events = try await provider.collect(input: request(), route: route(.anthropic, baseURL: "https://example.test/api"))
    #expect(events.first == .usage(TokenUsage(inputTokens: 4, outputTokens: 0, inputTokenBasis: .excludesCache)))
    #expect(textDeltas(events) == ["hello"])
    #expect(events.contains(.usage(TokenUsage(inputTokens: 4, outputTokens: 7, inputTokenBasis: .excludesCache))))
    #expect(events.last == .finished(.outputLimit))
}

@Test("OpenAI payload and Anthropic headers use the frozen route endpoint")
func requestShape() async throws {
    let openAIBytes = sse([
        ("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#), ("", "[DONE]")
    ])
    let credentials = FixtureCredentials()
    let transport = FixtureTransport(events: openAIEvents([Data(openAIBytes)]))
    let provider = FixtureAdapter(credentials: credentials, transport: transport)
    _ = try await provider.collect(input: request(), route: route())
    let sent = try #require(transport.requests.first)
    #expect(sent.url?.absoluteString == "https://example.test/chat/completions")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret")
    let body = try #require(sent.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["model"] as? String == "fixture-model")
    #expect(object["stream"] as? Bool == true)
    #expect(object["max_tokens"] as? Int == 128)
    #expect((object["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)

    let anthropicTransport = FixtureTransport(events: anthropicEvents([Data(sse([
        ("message_start", #"{"type":"message_start","message":{"usage":{}}}"#),
        ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#),
        ("message_stop", #"{"type":"message_stop"}"#)
    ]))]))
    let anthropicProvider = FixtureAdapter(fixture: .anthropic, credentials: credentials, transport: anthropicTransport)
    _ = try await anthropicProvider.collect(input: request(), route: route(.anthropic))
    let anthropicRequest = try #require(anthropicTransport.requests.first)
    #expect(anthropicRequest.url?.absoluteString == "https://example.test/v1/messages")
    #expect(anthropicRequest.value(forHTTPHeaderField: "x-api-key") == "fixture-secret")
    #expect(anthropicRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
}

@Test("Validation happens before credential read and transport invocation")
func validatesBeforeSecrets() async throws {
    let credentials = FixtureCredentials()
    let transport = FixtureTransport(events: [])
    let provider = FixtureAdapter(credentials: credentials, transport: transport)
    let invalidRoute = route(contextWindow: 0)
    do {
        _ = try await provider.collect(input: request(), route: invalidRoute)
        Issue.record("expected route validation to fail")
    } catch let error as MiraError {
        #expect(error.code == .configuration)
    }
    #expect(credentials.reads == 0)
    #expect(transport.requests.isEmpty)
}

@Test("Status, malformed stream, EOF and tools become safe failures")
func safeFailures() async throws {
    let secret = FixtureCredentials("do-not-leak")
    let statusTransport = FixtureTransport(events: openAIEvents([], status: 401))
    let provider = FixtureAdapter(credentials: secret, transport: statusTransport)
    do {
        _ = try await provider.collect(input: request(), route: route())
        Issue.record("expected 401")
    } catch let failure as AgentModelFailure {
        try failure.validate()
        #expect(failure.error.code == .unauthorized)
        #expect(!failure.error.message.contains("do-not-leak"))
    }

    let malformed = FixtureTransport(events: openAIEvents([Data(sse([("", "{bad json")]))]))
    do {
        _ = try await FixtureAdapter(credentials: secret, transport: malformed).collect(input: request(), route: route())
        Issue.record("expected malformed stream")
    } catch let failure as AgentModelFailure { try failure.validate(); #expect(failure.error.code == .malformedStream); #expect(failure.retryAdvice == nil) }

    let eof = FixtureTransport(events: [.response(HTTPTransportResponse(statusCode: 200)), .bytes(Data(sse([("", #"{"choices":[]}"#)])))])
    do {
        _ = try await FixtureAdapter(credentials: secret, transport: eof).collect(input: request(), route: route())
        Issue.record("expected premature EOF")
    } catch let failure as AgentModelFailure { try failure.validate(); #expect(failure.error.code == .interrupted); #expect(failure.retryAdvice == nil) }

    let tools = FixtureTransport(events: openAIEvents([Data(sse([
        ("", #"{"choices":[{"delta":{"tool_calls":[{"id":"x"}]},"finish_reason":null}]}"#)
    ]))]))
    do {
        _ = try await FixtureAdapter(credentials: secret, transport: tools).collect(input: request(), route: route())
        Issue.record("expected unsupported tool")
    } catch let failure as AgentModelFailure { try failure.validate(); #expect(failure.error.code == .unsupported); #expect(failure.retryAdvice == nil) }
}

@Test("Consumer cancellation terminates the injected transport")
func cancellationPropagates() async throws {
    let bytes = Data(sse([("", #"{"choices":[{"delta":{"content":"waiting"},"finish_reason":null}]}"#)]))
    let transport = FixtureTransport(events: openAIEvents([bytes], status: 200), asynchronous: true)
    let provider = FixtureAdapter(credentials: FixtureCredentials(), transport: transport)
    let operation = try provider.operation(input: request(), route: route())
    let task = Task {
        do {
            for try await _ in operation.events {
                try Task.checkCancellation()
            }
        } catch { }
    }
    for _ in 0..<100 where transport.requests.isEmpty {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    task.cancel(); await operation.close()
    _ = await task.result
    #expect(transport.cancellationCount >= 1)
}

@Test("Text deltas are delivered before a later transport failure")
func streamsBeforeFailure() async throws {
    let transport = ControlledTransport()
    let provider = FixtureAdapter(credentials: FixtureCredentials(), transport: transport)
    let operation = try provider.operation(input: request(), route: route())
    let consumer = Task { () -> ([AgentModelStreamEvent], AgentModelFailure?) in
        var events: [AgentModelStreamEvent] = []
        do {
            for try await event in operation.events { events.append(event) }
            return (events, nil)
        } catch let failure as AgentModelFailure {
            return (events, failure)
        } catch {
            return (events, nil)
        }
    }
    for _ in 0..<100 where !transport.isReady {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    transport.send(.response(HTTPTransportResponse(statusCode: 200)))
    let delta = Data(sse([("", #"{"choices":[{"delta":{"content":"partial"},"finish_reason":null}]}"#)]))
    transport.send(.bytes(delta))
    for _ in 0..<10 { await Task.yield() }
    transport.fail()
    let result = await consumer.value
    await operation.close()
    #expect(textDeltas(result.0) == ["partial"])
    try #require(result.1).validate()
    #expect(result.1?.error.code == .network)
}

@Test("OpenAI cumulative usage snapshots are not summed and missing usage stays absent")
func openAIUsageSemantics() async throws {
    let cumulative = sse([
        ("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#),
        ("", #"{"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":1}}"#),
        ("", #"{"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":3}}"#),
        ("", "[DONE]")
    ])
    let transport = FixtureTransport(events: openAIEvents([Data(cumulative)]))
    var events: [AgentModelStreamEvent] = []
    events = try await FixtureAdapter(credentials: FixtureCredentials(), transport: transport).collect(input: request(), route: route())
    #expect(events == [.usage(TokenUsage(inputTokens: 2, outputTokens: 1)), .usage(TokenUsage(inputTokens: 2, outputTokens: 3)), .finished(.stop)])

    let missing = sse([("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#), ("", "[DONE]")])
    var missingEvents: [AgentModelStreamEvent] = []
    missingEvents = try await FixtureAdapter(credentials: FixtureCredentials(), transport: FixtureTransport(events: openAIEvents([Data(missing)]))).collect(input: request(), route: route())
    #expect(missingEvents == [.finished(.stop)])
}

@Test("Both protocols classify streaming error frames safely")
func streamingErrorFrames() async throws {
    let openAI = FixtureTransport(events: openAIEvents([Data(sse([("", #"{"error":{"message":"secret-provider-body"}}"#)]))]))
    do {
        _ = try await FixtureAdapter(credentials: FixtureCredentials("secret"), transport: openAI).collect(input: request(), route: route())
        Issue.record("expected OpenAI error frame")
    } catch let failure as AgentModelFailure {
        try failure.validate()
        #expect(failure.error.code == .providerRejected)
        #expect(!failure.error.message.contains("secret-provider-body"))
        #expect(failure.retryAdvice == nil)
    }

    let anthropic = FixtureTransport(events: anthropicEvents([Data(sse([("error", #"{"type":"error","error":{"message":"secret-provider-body"}}"#)]))]))
    do {
        _ = try await FixtureAdapter(fixture: .anthropic, credentials: FixtureCredentials("secret"), transport: anthropic).collect(input: request(), route: route(.anthropic))
        Issue.record("expected Anthropic error frame")
    } catch let failure as AgentModelFailure {
        try failure.validate()
        #expect(failure.error.code == .providerRejected)
        #expect(!failure.error.message.contains("secret-provider-body"))
        #expect(failure.retryAdvice == nil)
    }
}

struct StatusCase: Sendable {
    let status: Int
    let code: MiraError.Code
}

@Test("HTTP status failures are safe", arguments: [
    StatusCase(status: 401, code: .unauthorized),
    StatusCase(status: 429, code: .rateLimited),
    StatusCase(status: 500, code: .network)
])
func statusFailures(_ testCase: StatusCase) async throws {
    for kind in [ProtocolFixture.standard, .anthropic] {
        let transport = FixtureTransport(events: [.response(HTTPTransportResponse(statusCode: testCase.status)), .end])
        do {
            _ = try await FixtureAdapter(fixture: kind, credentials: FixtureCredentials("status-secret"), transport: transport).collect(input: request(), route: route(kind))
            Issue.record("expected HTTP status failure")
        } catch let failure as AgentModelFailure {
            try failure.validate()
            #expect(failure.error.code == testCase.code)
            #expect(!failure.error.message.contains("status-secret"))
            #expect((failure.retryAdvice != nil) == (testCase.code == .rateLimited || testCase.code == .network))
        }
    }
}

@Test("Malformed JSON and truncated UTF8 fail for both protocols")
func malformedAndTruncated() async throws {
    let malformedOpenAI = FixtureTransport(events: openAIEvents([Data(sse([("", "{bad")]))]))
    do {
        _ = try await FixtureAdapter(credentials: FixtureCredentials(), transport: malformedOpenAI).collect(input: request(), route: route())
        Issue.record("expected malformed OpenAI JSON")
    } catch let failure as AgentModelFailure { try failure.validate(); #expect(failure.error.code == .malformedStream); #expect(failure.retryAdvice == nil) }

    let malformedAnthropic = FixtureTransport(events: anthropicEvents([Data(sse([("message_start", "{bad")]))]))
    do {
        _ = try await FixtureAdapter(fixture: .anthropic, credentials: FixtureCredentials(), transport: malformedAnthropic).collect(input: request(), route: route(.anthropic))
        Issue.record("expected malformed Anthropic JSON")
    } catch let failure as AgentModelFailure { try failure.validate(); #expect(failure.error.code == .malformedStream); #expect(failure.retryAdvice == nil) }

    let truncated = FixtureTransport(events: openAIEvents([Data([0x64, 0x61, 0x74, 0x61, 0x3a, 0x20, 0xE4]), .init()]))
    do {
        _ = try await FixtureAdapter(credentials: FixtureCredentials(), transport: truncated).collect(input: request(), route: route())
        Issue.record("expected truncated UTF8")
    } catch let failure as AgentModelFailure { try failure.validate(); #expect(failure.error.code == .malformedStream); #expect(failure.retryAdvice == nil) }
}

@Test("Anthropic rejects invalid block order and index")
func invalidAnthropicOrdering() async throws {
    let frames = [
        ("message_start", #"{"type":"message_start","message":{"usage":{}}}"#),
        ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text"}}"#)
    ]
    let transport = FixtureTransport(events: anthropicEvents([Data(sse(frames))]))
    do {
        _ = try await FixtureAdapter(fixture: .anthropic, credentials: FixtureCredentials(), transport: transport).collect(input: request(), route: route(.anthropic))
        Issue.record("expected invalid content block index")
    } catch let failure as AgentModelFailure { try failure.validate(); #expect(failure.error.code == .malformedStream); #expect(failure.retryAdvice == nil) }
}

@Test("A terminal frame cancels a transport that never closes")
func terminalCancelsOpenTransport() async throws {
    let transport = ControlledTransport()
    let provider = FixtureAdapter(credentials: FixtureCredentials(), transport: transport)
    let operation = try provider.operation(input: request(), route: route())
    let consumer = Task { () -> [AgentModelStreamEvent] in
        var result: [AgentModelStreamEvent] = []
        do {
            for try await event in operation.events { result.append(event) }
        } catch { }
        return result
    }
    for _ in 0..<100 where !transport.isReady { try? await Task.sleep(nanoseconds: 1_000_000) }
    transport.send(.response(HTTPTransportResponse(statusCode: 200)))
    transport.send(.bytes(Data(sse([("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#), ("", "[DONE]")]))))
    let events = await consumer.value
    await operation.close()
    #expect(events == [.finished(.stop)])
    #expect(transport.cancellationCount >= 1)
}

private final class RedirectURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var starts = 0
    static func reset() { starts = 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.starts += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://redirected.invalid/final"] )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class HangingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var starts = 0
    nonisolated(unsafe) static var stops = 0
    static func reset() { starts = 0; stops = 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.starts += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"] )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let bytes = Data(sse([("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#), ("", "[DONE]")]))
        client?.urlProtocol(self, didLoad: bytes)
        // Deliberately never signal EOF. The provider must cancel at protocol terminal.
    }
    override func stopLoading() { Self.stops += 1 }
}

@Test("URLSession transport declines redirects")
func redirectsAreDeclined() async throws {
    RedirectURLProtocol.reset()
    let transport = URLSessionStreamingTransport(protocolClasses: [RedirectURLProtocol.self])
    let request = URLRequest(url: URL(string: "https://origin.invalid/start")!)
    let operation = transport.stream(request: request)
    var status: Int?
    do {
        for try await event in operation.events {
            if case .response(let response) = event { status = response.statusCode }
        }
        await operation.close()
    } catch {
        await operation.close()
        throw error
    }
    #expect(status == 302)
    #expect(RedirectURLProtocol.starts == 1)
}

@Test("URLSession task is cancelled at protocol terminal before peer EOF")
func URLSessionTerminalCleanup() async throws {
    HangingURLProtocol.reset()
    let transport = URLSessionStreamingTransport(protocolClasses: [HangingURLProtocol.self])
    let provider = FixtureAdapter(credentials: FixtureCredentials(), transport: transport)
    var events: [AgentModelStreamEvent] = []
    events = try await provider.collect(input: request(), route: route())
    #expect(events == [.finished(.stop)])
    for _ in 0..<100 where HangingURLProtocol.stops == 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
    #expect(HangingURLProtocol.starts == 1)
    #expect(HangingURLProtocol.stops >= 1)
}

@Test("Per-execution cancellation does not cancel an identical concurrent request")
func cancellationUsesUniqueExecutionIdentity() async throws {
    let transport = MultiControlledTransport()
    let provider = FixtureAdapter(credentials: FixtureCredentials(), transport: transport)
    let firstRequest = request()
    let secondRequest = request()
    let firstID = firstRequest.stepID.uuidString
    let secondID = secondRequest.stepID.uuidString
    let first = Task { () -> [AgentModelStreamEvent] in
        var result: [AgentModelStreamEvent] = []
        do { result = try await provider.collect(input: firstRequest, route: route()) } catch { }
        return result
    }
    let second = Task { () -> [AgentModelStreamEvent] in
        var result: [AgentModelStreamEvent] = []
        do { result = try await provider.collect(input: secondRequest, route: route()) } catch { }
        return result
    }
    for _ in 0..<100 where transport.readyCount < 2 { try? await Task.sleep(nanoseconds: 1_000_000) }
    transport.send(id: firstID, .response(HTTPTransportResponse(statusCode: 200)))
    transport.send(id: secondID, .response(HTTPTransportResponse(statusCode: 200)))
    first.cancel()
    _ = await first.value
    for _ in 0..<100 where !transport.cancelledIDs.contains(where: { $0.hasPrefix(firstID + "#") }) { try? await Task.sleep(nanoseconds: 1_000_000) }
    #expect(transport.cancelledIDs.contains { $0.hasPrefix(firstID + "#") })
    #expect(!transport.cancelledIDs.contains { $0.hasPrefix(secondID + "#") })
    transport.send(id: secondID, .bytes(Data(sse([("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#), ("", "[DONE]")]))))
    let secondEvents = await second.value
    #expect(secondEvents == [.finished(.stop)])
}

@Test("Slow consumers receive a bounded stream failure instead of dropped events")
func boundedCanonicalStream() async throws {
    // Each fragment exceeds the coalescing threshold, so the fixture tests
    // sustained consumer backlog rather than harmless token fragmentation.
    let fragment = String(repeating: "x", count: 4_096)
    let frame = Data(sse([("", "{\"choices\":[{\"delta\":{\"content\":\"\(fragment)\"},\"finish_reason\":null}]}")]))
    let events = (0..<256).map { _ in HTTPTransportEvent.bytes(frame) }
    let transport = FixtureTransport(events: [.response(HTTPTransportResponse(statusCode: 200))] + events + [.end])
    var received = 0
    do {
        let operation = try FixtureAdapter(credentials: FixtureCredentials(), transport: transport).operation(input: request(), route: route())
        do {
            // Do not consume until the producer has closed: overflow is now
            // deterministic and independent of machine speed or task priority.
            let deadline = ContinuousClock.now + .seconds(5)
            while transport.cancellationCount == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(transport.cancellationCount == 1)
            for try await _ in operation.events { received += 1 }
            await operation.close()
        } catch {
            await operation.close()
            throw error
        }
        Issue.record("expected bounded stream failure")
    } catch let failure as AgentModelFailure {
        try failure.validate()
        #expect(failure.error.code == .malformedStream)
        #expect(failure.retryAdvice == nil)
    }
    // The explicit overflow failure above proves the producer stopped instead
    // of silently dropping an unbounded number of events.
    #expect(received < 256)
}

private func toolDefinition(_ name: String = "memory.search") -> ToolDefinition {
    ToolDefinition(name: name, description: "Search local memories", inputSchema: .object([
        "type": .string("object"),
        "properties": .object(["query": .object(["type": .string("string")])]),
        "required": .array([.string("query")])
    ]))
}

private func toolRoute(_ fixture: ProtocolFixture = .standard) -> AgentModelRoute {
    route(fixture, callsTools: true)
}

private func toolRequest(stepID: UUID = UUID()) -> AgentModelInput {
    .init(stepID: stepID, executionID: ExecutionID(), instructions: "Use tools when needed.", messages: [
        .init(role: .user, text: "Search my memories"),
        .init(role: .assistant, text: "", toolCalls: [.init(id: "call-1", name: "memory.search", arguments: #"{"query":"swift"}"#)]),
        .init(role: .tool, text: "A Swift memory", toolCallID: "call-1")
    ], tools: [toolDefinition()])
}

@Test("Tool definitions and history use exact OpenAI and Anthropic wire shapes")
func toolRequestShapes() async throws {
    let openAIResponse = Data(sse([("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#), ("", "[DONE]")]))
    let openAITransport = FixtureTransport(events: openAIEvents([openAIResponse]))
    _ = try await FixtureAdapter(credentials: FixtureCredentials(), transport: openAITransport).collect(input: toolRequest(), route: toolRoute())
    let openAIBody = try #require(openAITransport.requests.first?.httpBody)
    let openAIObject = try #require(JSONSerialization.jsonObject(with: openAIBody) as? [String: Any])
    let openAITools = try #require(openAIObject["tools"] as? [[String: Any]])
    let openAIFunction = try #require(openAITools.first?["function"] as? [String: Any])
    #expect(openAIFunction["name"] as? String == "memory_search")
    let openAIMessages = try #require(openAIObject["messages"] as? [[String: Any]])
    #expect(openAIMessages[2]["role"] as? String == "assistant")
    #expect((openAIMessages[2]["tool_calls"] as? [[String: Any]])?.first?["id"] as? String == "call-1")
    #expect(openAIMessages[3]["role"] as? String == "tool")
    #expect(openAIMessages[3]["tool_call_id"] as? String == "call-1")

    let anthropicResponse = Data(sse([
        ("message_start", #"{"type":"message_start","message":{"usage":{}}}"#),
        ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#),
        ("message_stop", #"{"type":"message_stop"}"#)
    ]))
    let anthropicTransport = FixtureTransport(events: anthropicEvents([anthropicResponse]))
    _ = try await FixtureAdapter(fixture: .anthropic, credentials: FixtureCredentials(), transport: anthropicTransport).collect(input: toolRequest(), route: toolRoute(.anthropic))
    let anthropicBody = try #require(anthropicTransport.requests.first?.httpBody)
    let anthropicObject = try #require(JSONSerialization.jsonObject(with: anthropicBody) as? [String: Any])
    let anthropicTools = try #require(anthropicObject["tools"] as? [[String: Any]])
    #expect(anthropicTools.first?["name"] as? String == "memory_search")
    #expect(anthropicTools.first?["input_schema"] is [String: Any])
    let anthropicMessages = try #require(anthropicObject["messages"] as? [[String: Any]])
    #expect(anthropicMessages.count == 3)
    #expect(anthropicMessages[1]["role"] as? String == "assistant")
    let assistantBlocks = try #require(anthropicMessages[1]["content"] as? [[String: Any]])
    #expect(assistantBlocks.first?["type"] as? String == "tool_use")
    #expect(assistantBlocks.first?["name"] as? String == "memory_search")
    #expect(anthropicMessages[2]["role"] as? String == "user")
    let resultBlocks = try #require(anthropicMessages[2]["content"] as? [[String: Any]])
    #expect(resultBlocks.first?["type"] as? String == "tool_result")
    #expect(resultBlocks.first?["tool_use_id"] as? String == "call-1")
}

@Test("System instructions precede stable history and turn-scoped context on both wires")
func systemPrefixAndTurnContextWireOrder() async throws {
    let canonical = AgentModelInput(stepID: UUID(), executionID: ExecutionID(), instructions: "Stable instructions", messages: [
        .init(role: .user, text: "Earlier question"), .init(role: .assistant, text: "Earlier answer"),
        .init(role: .context, text: "Untrusted retrieved facts"), .init(role: .user, text: "Current question")
    ], tools: [])
    for fixture in [ProtocolFixture.standard, .openAI] {
        let snapshot = route(fixture)
        let transport = FixtureTransport(events: openAIEvents([Data(sse([
            ("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#), ("", "[DONE]")
        ]))]))
        _ = try await FixtureAdapter(fixture: fixture, credentials: FixtureCredentials(), transport: transport).collect(input: canonical, route: snapshot)
        let body = try #require(transport.requests.first?.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == [fixture == .openAI ? "developer" : "system", "user", "assistant", "user", "user"])
        #expect(messages.map { $0["content"] as? String } == [canonical.instructions] + canonical.messages.map(\.text))
    }
    let transport = FixtureTransport(events: anthropicEvents([Data(sse([
        ("message_start", #"{"type":"message_start","message":{"usage":{}}}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#),
        ("message_stop", #"{"type":"message_stop"}"#)
    ]))]))
    _ = try await FixtureAdapter(fixture: .anthropic, credentials: FixtureCredentials(), transport: transport).collect(input: canonical, route: route(.anthropic))
    let body = try #require(transport.requests.first?.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["system"] as? String == canonical.instructions)
    let messages = try #require(object["messages"] as? [[String: Any]])
    #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user", "user"])
    #expect(messages.map { $0["content"] as? String } == canonical.messages.map(\.text))
}

@Test("Application context is data-only, unique, and immediately before the current user")
func rejectsInvalidApplicationContextBeforeCredentialAccess() async throws {
    let context = AgentModelMessage(role: .context, text: "Retrieved facts")
    let user = AgentModelMessage(role: .user, text: "Current question")
    let scenarios: [[AgentModelMessage]] = [
        [.init(role: .context, text: "Invalid", thinking: .init(text: "Invalid", continuation: nil, isComplete: true)), user],
        [.init(role: .context, text: "Invalid", toolCalls: [.init(id: "invalid", name: "echo", arguments: "{}")]), user],
        [.init(role: .context, text: "Invalid", toolCallID: "invalid"), user],
        [context, context, user], [user, context], [context],
        [context, .init(role: .user, text: "Earlier question"), .init(role: .assistant, text: "Earlier answer"), user]
    ]
    for messages in scenarios {
        for fixture in [ProtocolFixture.standard, .anthropic] {
            let credentials = FixtureCredentials(), transport = FixtureTransport(events: [])
            let input = AgentModelInput(stepID: UUID(), executionID: ExecutionID(), instructions: "Instructions", messages: messages, tools: [])
            await #expect(throws: MiraError.self) {
                _ = try await FixtureAdapter(fixture: fixture, credentials: credentials, transport: transport).collect(input: input, route: route(fixture))
            }
            #expect(credentials.reads == 0); #expect(transport.requests.isEmpty)
        }
    }
    let base = toolRequest()
    var messages = base.messages
    messages.insert(.init(role: .context, text: "Invalid placement"), at: 2)
    let malformed = AgentModelInput(stepID: base.stepID, executionID: base.executionID,
                                    instructions: base.instructions, messages: messages, tools: base.tools)
    let credentials = FixtureCredentials(), transport = FixtureTransport(events: [])
    await #expect(throws: MiraError.self) {
        _ = try await FixtureAdapter(credentials: credentials, transport: transport).collect(input: malformed, route: toolRoute())
    }
    #expect(credentials.reads == 0); #expect(transport.requests.isEmpty)
}

@Test("OpenAI interleaved tool arguments are emitted once in model order")
func openAIInterleavedToolCalls() async throws {
    let bytes = sse([
        ("", #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","type":"function","function":{"name":"memory.search","arguments":"{\"q\":"}}]},"finish_reason":null}]}"#),
        ("", #"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"b","type":"function","function":{"name":"memory.search","arguments":"{\"q\":"}}]},"finish_reason":null}]}"#),
        ("", #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"one\"}"}},{"index":1,"function":{"arguments":"\"two\"}"}}]},"finish_reason":null}]}"#),
        ("", #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#),
        ("", "[DONE]")
    ])
    let transport = FixtureTransport(events: openAIEvents(split(bytes, sizes: [1, 3, 2, 7])))
    var events: [AgentModelStreamEvent] = []
    events = try await FixtureAdapter(credentials: FixtureCredentials(), transport: transport).collect(input: toolRequest(), route: toolRoute())
    #expect(containsToolCall(events, id: "a", name: "memory.search", arguments: #"{"q":"one"}"#))
    #expect(containsToolCall(events, id: "b", name: "memory.search", arguments: #"{"q":"two"}"#))
    #expect(events.last == .finished(.toolCalls))
}

@Test("Anthropic input_json_delta is assembled and mapped back to the internal tool name")
func anthropicToolCallStream() async throws {
    let frames = [
        ("message_start", #"{"type":"message_start","message":{"usage":{}}}"#),
        ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu-1","name":"memory_search","input":{}}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"swift\"}"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#),
        ("message_stop", #"{"type":"message_stop"}"#)
    ]
    let transport = FixtureTransport(events: anthropicEvents(split(sse(frames), sizes: [1, 2, 5, 8])))
    var events: [AgentModelStreamEvent] = []
    events = try await FixtureAdapter(fixture: .anthropic, credentials: FixtureCredentials(), transport: transport).collect(input: toolRequest(stepID: UUID()), route: toolRoute(.anthropic))
    #expect(events.contains(.usage(TokenUsage(inputTokens: nil, outputTokens: nil, inputTokenBasis: .excludesCache))))
    #expect(containsToolCall(events, id: "toolu-1", name: "memory.search", arguments: #"{"query":"swift"}"#))
    #expect(events.last == .finished(.toolCalls))
}

@Test("Duplicate tool IDs and incomplete tool stops are rejected without tool events")
func invalidToolCallBoundaries() async throws {
    let duplicate = sse([
        ("", #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"same","type":"function","function":{"name":"memory.search","arguments":"{}"}},{"index":1,"id":"same","type":"function","function":{"name":"memory.search","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#),
        ("", "[DONE]")
    ])
    do {
        _ = try await FixtureAdapter(credentials: FixtureCredentials(), transport: FixtureTransport(events: openAIEvents([Data(duplicate)]))).collect(input: toolRequest(), route: toolRoute())
        Issue.record("expected duplicate tool ID failure")
    } catch let failure as AgentModelFailure { try failure.validate(); #expect(failure.error.code == .malformedStream); #expect(failure.retryAdvice == nil) }

    let limited = sse([
        ("", #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","type":"function","function":{"name":"memory.search","arguments":"{\"q\":"}}]},"finish_reason":"length"}]}"#),
        ("", "[DONE]")
    ])
    var events: [AgentModelStreamEvent] = []
    events = try await FixtureAdapter(credentials: FixtureCredentials(), transport: FixtureTransport(events: openAIEvents([Data(limited)]))).collect(input: toolRequest(), route: toolRoute())
    #expect(events.last == .finished(.outputLimit))
    #expect(!events.contains { isToolCallEvent($0) })
}

@Test("Duplicate terminal frames are rejected after completion")
func duplicateTerminalFrameIsMalformed() async throws {
    let duplicate = sse([
        ("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#),
        ("", "[DONE]"), ("", "[DONE]")
    ])
    do {
        _ = try await FixtureAdapter(credentials: FixtureCredentials(),
            transport: FixtureTransport(events: openAIEvents([Data(duplicate)]))).collect(input: request(), route: route())
        Issue.record("expected duplicate terminal failure")
    } catch let failure as AgentModelFailure {
        try failure.validate()
        #expect(failure.error.code == .malformedStream)
    }
}

@Test("Cancellation keeps identical step IDs and requests isolated")
func cancellationUsesDispatchIdentity() async throws {
    let transport = MultiControlledTransport()
    let provider = FixtureAdapter(credentials: FixtureCredentials(), transport: transport)
    let sharedExecution = ExecutionID()
    let stepID = UUID()
    let firstRequest = AgentModelInput(stepID: stepID, executionID: sharedExecution, instructions: "", messages: [.init(role: .user, text: "same")], tools: [])
    let secondRequest = AgentModelInput(stepID: stepID, executionID: sharedExecution, instructions: "", messages: [.init(role: .user, text: "same")], tools: [])
    let firstOperation = try provider.operation(input: firstRequest, route: route())
    let secondOperation = try provider.operation(input: secondRequest, route: route())
    let first = Task { do { for try await _ in firstOperation.events {} } catch { } }
    let second = Task { () throws -> [AgentModelStreamEvent] in
        var events: [AgentModelStreamEvent] = []
        for try await event in secondOperation.events { events.append(event) }
        return events
    }
    for _ in 0..<100 where transport.readyCount < 2 { try? await Task.sleep(nanoseconds: 1_000_000) }
    first.cancel(); await firstOperation.close()
    _ = await first.result
    for _ in 0..<100 where transport.cancelledIDs.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000) }
    #expect(transport.cancelledIDs.count == 1)
    #expect(transport.readyCount == 1)
    transport.send(id: stepID.uuidString, .response(.init(statusCode: 200)))
    transport.send(id: stepID.uuidString, .bytes(Data(sse([("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#), ("", "[DONE]")]))))
    let secondResult = await second.result
    await secondOperation.close()
    #expect(try secondResult.get() == [.finished(.stop)])
    #expect(transport.cancelledIDs.count == 2)
}

@Test("Tool argument syntax and size limits are checked before emitting a runnable batch")
func toolArgumentLimitsBeforeEmission() async throws {
    for scenario in 0..<3 {
        let arguments = scenario == 0 ? "{" : (scenario == 1 ? String(repeating: "x", count: 65_537) : "{}")
        let count = scenario == 2 ? 33 : 1
        let calls: [[String: Any]] = (0..<count).map { ["index": $0, "id": "id-\($0)", "type": "function", "function": ["name": "memory_search", "arguments": arguments]] }
        let object: [String: Any] = ["choices": [["delta": ["tool_calls": calls], "finish_reason": "tool_calls"]]]
        let frame = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let transport = FixtureTransport(events: openAIEvents([Data(sse([("", frame), ("", "[DONE]")]))]))
        var emitted = false
        do {
            let events = try await FixtureAdapter(credentials: FixtureCredentials(), transport: transport).collect(input: toolRequest(), route: toolRoute())
            emitted = events.contains { isToolCallEvent($0) }
            Issue.record("Expected bounded malformed tool proposal")
        } catch let failure as AgentModelFailure { try failure.validate(); #expect(failure.error.code == .malformedStream); #expect(failure.retryAdvice == nil) }
        #expect(!emitted)
    }
}

@Test("Anthropic accepts an empty input object without deltas and rejects content after stop reason")
func anthropicEmptyToolInputAndStopOrdering() async throws {
    let prefix = [
        ("message_start", #"{"message":{}}"#),
        ("content_block_start", #"{"index":0,"content_block":{"type":"tool_use","id":"empty-1","name":"unknown_tool","input":{}}}"#),
        ("content_block_stop", #"{"index":0}"#),
        ("message_delta", #"{"delta":{"stop_reason":"tool_use"}}"#)
    ]
    let good = FixtureTransport(events: anthropicEvents([Data(sse(prefix + [("message_stop", #"{}"#)]))]))
    var events: [AgentModelStreamEvent] = []
    events = try await FixtureAdapter(fixture: .anthropic, credentials: FixtureCredentials(), transport: good).collect(input: toolRequest(), route: toolRoute(.anthropic))
    #expect(containsToolCall(events, id: "empty-1", name: "unknown_tool", arguments: "{}"))
    #expect(events.last == .finished(.toolCalls))
    let bad = FixtureTransport(events: anthropicEvents([Data(sse(prefix + [
        ("content_block_start", #"{"index":1,"content_block":{"type":"text","text":"late"}}"#),
        ("content_block_stop", #"{"index":1}"#), ("message_stop", "{}")
    ]))]))
    do {
        _ = try await FixtureAdapter(fixture: .anthropic, credentials: FixtureCredentials(), transport: bad).collect(input: toolRequest(), route: toolRoute(.anthropic))
        Issue.record("Expected rejection of content after a stop reason")
    } catch let failure as AgentModelFailure { try failure.validate(); #expect(failure.error.code == .malformedStream); #expect(failure.retryAdvice == nil) }
}

@Test("Orphaned and incomplete tool histories are rejected before transport")
func malformedToolHistoryNeverDispatches() async throws {
    let scenarios: [[AgentModelMessage]] = [
        [.init(role: .tool, text: "orphan", toolCallID: "unknown")],
        [.init(role: .assistant, text: "", toolCalls: [.init(id: "id", name: "memory.search", arguments: "{}")])],
        [.init(role: .assistant, text: "", toolCalls: [.init(id: "id", name: "memory.search", arguments: "{}")]), .init(role: .user, text: "missing result")]
    ]
    for kind in [ProtocolFixture.standard, .anthropic] {
        for messages in scenarios {
            let transport = FixtureTransport(events: [])
            let base = toolRequest()
            let malformed = AgentModelInput(stepID: base.stepID, executionID: base.executionID,
                                             instructions: base.instructions, messages: messages, tools: base.tools)
            do {
                _ = try await FixtureAdapter(fixture: kind, credentials: FixtureCredentials(), transport: transport).collect(input: malformed, route: toolRoute(kind))
                Issue.record("Expected rejection before dispatch")
            } catch let error as MiraError { #expect(error.code == .malformedStream) }
            #expect(transport.requests.isEmpty)
        }
    }
}

@Test("Chat transport fragments remain two complete semantic blocks", arguments: [ProtocolFixture.standard, .deepSeek, .kimi, .openRouter], [false, true])
func fragmentedChatReplyUsesStableBlocks(fixture: ProtocolFixture, asynchronous: Bool) async throws {
    let thoughts = (0..<160).map { "reason-\($0) " }
    let answer = (0..<240).map { "answer-\($0) " }
    var frames = thoughts.map { ("", "{\"choices\":[{\"delta\":{\"reasoning_content\":\"\($0)\"}}]}") }
    frames += answer.map { ("", "{\"choices\":[{\"delta\":{\"content\":\"\($0)\"}}]}") }
    frames += [("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#), ("", "[DONE]")]
    let transport = FixtureTransport(events: openAIEvents(split(sse(frames), sizes: [31, 7, 191])), asynchronous: asynchronous)
    let frozen = route(fixture)
    let events = try await FixtureAdapter(fixture: fixture, credentials: FixtureCredentials(), transport: transport)
        .collect(input: request(), route: frozen)
    var accumulator = try AgentModelAccumulator(route: frozen)
    for event in events { try accumulator.consume(event) }
    let output = try accumulator.finish()
    #expect(output.blocks.count == 2)
    #expect(output.thinkingText == thoughts.joined())
    #expect(output.text == answer.joined())
    #expect(output.continuation?.isComplete == true)
    #expect(output.finishReason == .stop)
    try output.validate(for: frozen)
}

@Test("Anthropic deltas retain their provider block boundaries and complete thinking")
func fragmentedAnthropicReplyUsesStableBlocks() async throws {
    let thoughts = (0..<160).map { "reason-\($0) " }
    let answer = (0..<240).map { "answer-\($0) " }
    var frames: [(String, String)] = [
        ("message_start", #"{"message":{"usage":{}}}"#),
        ("content_block_start", #"{"index":0,"content_block":{"type":"thinking","thinking":""}}"#)
    ]
    frames += thoughts.map { ("content_block_delta", "{\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"\($0)\"}}") }
    frames += [
        ("content_block_delta", #"{"index":0,"delta":{"type":"signature_delta","signature":"synthetic-signature"}}"#),
        ("content_block_stop", #"{"index":0}"#),
        ("content_block_start", #"{"index":1,"content_block":{"type":"text","text":""}}"#)
    ]
    frames += answer.map { ("content_block_delta", "{\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"\($0)\"}}") }
    frames += [
        ("content_block_stop", #"{"index":1}"#),
        ("content_block_start", #"{"index":2,"content_block":{"type":"text","text":"tail"}}"#),
        ("content_block_stop", #"{"index":2}"#),
        ("message_delta", #"{"delta":{"stop_reason":"end_turn"}}"#),
        ("message_stop", #"{}"#)
    ]
    let transport = FixtureTransport(events: anthropicEvents(split(sse(frames), sizes: [31, 7, 191])), asynchronous: true)
    let frozen = route(.anthropic)
    let events = try await FixtureAdapter(fixture: .anthropic, credentials: FixtureCredentials(), transport: transport)
        .collect(input: request(), route: frozen)
    var accumulator = try AgentModelAccumulator(route: frozen)
    for event in events { try accumulator.consume(event) }
    let output = try accumulator.finish()
    #expect(output.blocks.count == 3)
    #expect(output.thinkingText == thoughts.joined())
    #expect(output.text == answer.joined() + "tail")
    guard case .array(let payload) = output.continuation?.payload else { Issue.record("Missing continuation"); return }
    #expect(payload[0]["thinking"]?.stringValue == thoughts.joined())
    #expect(payload[0]["signature"]?.stringValue == "synthetic-signature")
    try output.validate(for: frozen)
}

@Test("Large Chat deltas split within the same block and semantic changes retain order")
func chatLargeDeltaAndSemanticBoundaries() async throws {
    let large = String(repeating: "x", count: 70_000)
    let frames: [(String, String)] = [
        ("", "{\"choices\":[{\"delta\":{\"content\":\"\(large)\"}}]}"),
        ("", #"{"choices":[{"delta":{"reasoning_content":"reconsider"}}]}"#),
        ("", #"{"choices":[{"delta":{"content":"tail"}}]}"#),
        ("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#),
        ("", "[DONE]")
    ]
    let transport = FixtureTransport(events: openAIEvents([Data(sse(frames))]))
    let frozen = route(.deepSeek)
    let events = try await FixtureAdapter(fixture: .deepSeek, credentials: FixtureCredentials(), transport: transport)
        .collect(input: request(), route: frozen)
    var accumulator = try AgentModelAccumulator(route: frozen)
    for event in events {
        if case .blockDelta(_, let text) = event { #expect(text.utf8.count <= 65_536) }
        try accumulator.consume(event)
    }
    let output = try accumulator.finish()
    #expect(output.blocks.map(\.content) == [.text(large), .thinking("reconsider"), .text("tail")])
}

@Test("Anthropic tools preserve surrounding content order and are omitted on truncation", arguments: [false, true])
func anthropicToolContentOrder(outputLimited: Bool) async throws {
    let reason = outputLimited ? "max_tokens" : "tool_use"
    let frames: [(String, String)] = [
        ("message_start", #"{"message":{"usage":{}}}"#),
        ("content_block_start", #"{"index":0,"content_block":{"type":"text","text":"before"}}"#),
        ("content_block_stop", #"{"index":0}"#),
        ("content_block_start", #"{"index":1,"content_block":{"type":"tool_use","id":"call-1","name":"memory_search","input":{"query":"fixture"}}}"#),
        ("content_block_stop", #"{"index":1}"#),
        ("content_block_start", #"{"index":2,"content_block":{"type":"thinking","thinking":"after-tool"}}"#),
        ("content_block_delta", #"{"index":2,"delta":{"type":"signature_delta","signature":"synthetic-signature"}}"#),
        ("content_block_stop", #"{"index":2}"#),
        ("content_block_start", #"{"index":3,"content_block":{"type":"text","text":"after"}}"#),
        ("content_block_stop", #"{"index":3}"#),
        ("message_delta", "{\"delta\":{\"stop_reason\":\"\(reason)\"}}"),
        ("message_stop", #"{}"#)
    ]
    let transport = FixtureTransport(events: anthropicEvents([Data(sse(frames))]))
    let frozen = toolRoute(.anthropic)
    let events = try await FixtureAdapter(fixture: .anthropic, credentials: FixtureCredentials(), transport: transport)
        .collect(input: toolRequest(), route: frozen)
    var accumulator = try AgentModelAccumulator(route: frozen)
    for event in events { try accumulator.consume(event) }
    let output = try accumulator.finish()
    let content = output.blocks.map(\.content)
    if outputLimited {
        #expect(content == [.text("before"), .thinking("after-tool"), .text("after")])
        #expect(output.toolCalls.isEmpty)
        #expect(output.finishReason == .outputLimit)
    } else {
        let call = try #require(output.toolCalls.first)
        #expect(call.id == "call-1")
        #expect(content == [.text("before"), .toolCall(call), .thinking("after-tool"), .text("after")])
        #expect(output.finishReason == .toolCalls)
    }
    try output.validate(for: frozen)
}
