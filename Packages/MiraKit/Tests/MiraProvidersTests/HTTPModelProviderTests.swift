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

private final class FixtureTransport: HTTPStreamingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let events: [HTTPTransportEvent]
    private(set) var requests: [URLRequest] = []
    private(set) var cancellationCount = 0
    private let asynchronous: Bool

    init(events: [HTTPTransportEvent], asynchronous: Bool = false) {
        self.events = events
        self.asynchronous = asynchronous
    }

    func stream(request: URLRequest) -> AsyncThrowingStream<HTTPTransportEvent, any Error> {
        lock.lock(); requests.append(request); lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.cancellationCount += 1; self.lock.unlock()
            }
            if asynchronous {
                Task {
                    for event in events {
                        if Task.isCancelled { return }
                        continuation.yield(event)
                        await Task.yield()
                    }
                    continuation.finish()
                }
            } else {
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}

private enum FixtureTransportError: Error { case broken }

private final class ControlledTransport: HTTPStreamingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<HTTPTransportEvent, any Error>.Continuation?
    private(set) var isReady = false
    private(set) var cancellationCount = 0

    func stream(request: URLRequest) -> AsyncThrowingStream<HTTPTransportEvent, any Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            self.continuation = continuation
            self.isReady = true
            lock.unlock()
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.cancellationCount += 1; self.lock.unlock()
            }
        }
    }

    func send(_ event: HTTPTransportEvent) {
        lock.lock(); let continuation = self.continuation; lock.unlock()
        continuation?.yield(event)
    }

    func fail() {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.finish(throwing: FixtureTransportError.broken)
    }

    func cancel(request: URLRequest) {
        lock.lock(); cancellationCount += 1; let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.finish(throwing: URLError(.cancelled))
    }
}

private final class MultiControlledTransport: HTTPStreamingTransportCancellation, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [String: AsyncThrowingStream<HTTPTransportEvent, any Error>.Continuation] = [:]
    private(set) var cancelledIDs: [String] = []

    var readyCount: Int {
        lock.lock(); defer { lock.unlock() }
        return continuations.count
    }

    func stream(request: URLRequest) -> AsyncThrowingStream<HTTPTransportEvent, any Error> {
        let id = request.value(forHTTPHeaderField: "X-Mira-Request-ID")!
        return AsyncThrowingStream { continuation in
            lock.lock(); continuations[id] = continuation; lock.unlock()
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.continuations.removeValue(forKey: id); self.lock.unlock()
            }
        }
    }

    func send(id: String, _ event: HTTPTransportEvent) {
        lock.lock(); let continuation = continuations[id]; lock.unlock()
        continuation?.yield(event)
    }

    func cancel(request: URLRequest) {
        guard let id = request.value(forHTTPHeaderField: "X-Mira-Request-ID") else { return }
        lock.lock(); cancelledIDs.append(id); let continuation = continuations.removeValue(forKey: id); lock.unlock()
        continuation?.finish(throwing: URLError(.cancelled))
    }
}

private func route(_ kind: ProviderKind = .openAICompatible, baseURL: String = "https://example.test") -> ModelRoute {
    ModelRoute(name: "Fixture", providerKind: kind, baseURL: baseURL, modelID: "fixture-model", credentialReference: "fixture", contextWindow: 4096, maxOutputTokens: 128, requestsUsage: true)
}

private func request() -> CanonicalModelRequest {
    CanonicalModelRequest(executionID: ExecutionID(), system: "Be concise.", messages: [CanonicalMessage(role: .user, text: "Hello")])
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
    let bytes = sse([
        ("", #"{"choices":[{"delta":{"content":"你"},"finish_reason":null}]}"#),
        ("", #"{"choices":[{"delta":{"content":"好"},"finish_reason":null}]}"#),
        ("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#),
        ("", #"{"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#),
        ("", "[DONE]")
    ])
    let transport = FixtureTransport(events: openAIEvents(split(bytes, sizes: [1, 2, 3, 5, 8])))
    let provider = HTTPModelProvider(credentials: FixtureCredentials(), transport: transport)
    var events: [CanonicalStreamEvent] = []
    for try await event in provider.stream(request: request(), route: route()) { events.append(event) }
    #expect(events == [.textDelta("你"), .textDelta("好"), .usage(TokenUsage(inputTokens: 3, outputTokens: 2)), .finished(.stop)])
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
    let provider = HTTPModelProvider(credentials: FixtureCredentials(), transport: transport)
    var events: [CanonicalStreamEvent] = []
    for try await event in provider.stream(request: request(), route: route(.anthropic, baseURL: "https://example.test/api")) { events.append(event) }
    #expect(events == [.usage(TokenUsage(inputTokens: 4, outputTokens: 0)), .textDelta("hello"), .usage(TokenUsage(inputTokens: 4, outputTokens: 7)), .finished(.outputLimit)])
}

@Test("OpenAI payload and Anthropic headers use the frozen route endpoint")
func requestShape() async throws {
    let openAIBytes = sse([
        ("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#), ("", "[DONE]")
    ])
    let credentials = FixtureCredentials()
    let transport = FixtureTransport(events: openAIEvents([Data(openAIBytes)]))
    let provider = HTTPModelProvider(credentials: credentials, transport: transport)
    for try await _ in provider.stream(request: request(), route: route()) {}
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
    let anthropicProvider = HTTPModelProvider(credentials: credentials, transport: anthropicTransport)
    for try await _ in anthropicProvider.stream(request: request(), route: route(.anthropic)) {}
    let anthropicRequest = try #require(anthropicTransport.requests.first)
    #expect(anthropicRequest.url?.absoluteString == "https://example.test/v1/messages")
    #expect(anthropicRequest.value(forHTTPHeaderField: "x-api-key") == "fixture-secret")
    #expect(anthropicRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
}

@Test("Validation happens before credential read and transport invocation")
func validatesBeforeSecrets() async throws {
    let credentials = FixtureCredentials()
    let transport = FixtureTransport(events: [])
    let provider = HTTPModelProvider(credentials: credentials, transport: transport)
    var route = route()
    route.contextWindow = nil
    do {
        for try await _ in provider.stream(request: request(), route: route) {}
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
    let provider = HTTPModelProvider(credentials: secret, transport: statusTransport)
    do {
        for try await _ in provider.stream(request: request(), route: route()) {}
        Issue.record("expected 401")
    } catch let error as MiraError {
        #expect(error.code == .unauthorized)
        #expect(!error.message.contains("do-not-leak"))
    }

    let malformed = FixtureTransport(events: openAIEvents([Data(sse([("", "{bad json")]))]))
    do {
        for try await _ in HTTPModelProvider(credentials: secret, transport: malformed).stream(request: request(), route: route()) {}
        Issue.record("expected malformed stream")
    } catch let error as MiraError { #expect(error.code == .malformedStream) }

    let eof = FixtureTransport(events: [.response(HTTPTransportResponse(statusCode: 200)), .bytes(Data(sse([("", #"{"choices":[]}"#)])))])
    do {
        for try await _ in HTTPModelProvider(credentials: secret, transport: eof).stream(request: request(), route: route()) {}
        Issue.record("expected premature EOF")
    } catch let error as MiraError { #expect(error.code == .interrupted) }

    let tools = FixtureTransport(events: openAIEvents([Data(sse([
        ("", #"{"choices":[{"delta":{"tool_calls":[{"id":"x"}]},"finish_reason":null}]}"#)
    ]))]))
    do {
        for try await _ in HTTPModelProvider(credentials: secret, transport: tools).stream(request: request(), route: route()) {}
        Issue.record("expected unsupported tool")
    } catch let error as MiraError { #expect(error.code == .unsupported) }
}

@Test("Consumer cancellation terminates the injected transport")
func cancellationPropagates() async throws {
    let bytes = Data(sse([("", #"{"choices":[{"delta":{"content":"waiting"},"finish_reason":null}]}"#)]))
    let transport = FixtureTransport(events: openAIEvents([bytes], status: 200), asynchronous: true)
    let provider = HTTPModelProvider(credentials: FixtureCredentials(), transport: transport)
    let task = Task {
        do {
            for try await _ in provider.stream(request: request(), route: route()) {
                try Task.checkCancellation()
            }
        } catch { }
    }
    for _ in 0..<100 where transport.requests.isEmpty {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    task.cancel()
    _ = await task.result
    #expect(transport.cancellationCount >= 1)
}

@Test("Text deltas are delivered before a later transport failure")
func streamsBeforeFailure() async throws {
    let transport = ControlledTransport()
    let provider = HTTPModelProvider(credentials: FixtureCredentials(), transport: transport)
    let consumer = Task { () -> ([CanonicalStreamEvent], MiraError?) in
        var events: [CanonicalStreamEvent] = []
        do {
            for try await event in provider.stream(request: request(), route: route()) { events.append(event) }
            return (events, nil)
        } catch let error as MiraError {
            return (events, error)
        } catch {
            return (events, MiraError.safe(error))
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
    #expect(result.0 == [.textDelta("partial")])
    #expect(result.1?.code == .network)
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
    var events: [CanonicalStreamEvent] = []
    for try await event in HTTPModelProvider(credentials: FixtureCredentials(), transport: transport).stream(request: request(), route: route()) { events.append(event) }
    #expect(events == [.usage(TokenUsage(inputTokens: 2, outputTokens: 1)), .usage(TokenUsage(inputTokens: 2, outputTokens: 3)), .finished(.stop)])

    let missing = sse([("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#), ("", "[DONE]")])
    var missingEvents: [CanonicalStreamEvent] = []
    for try await event in HTTPModelProvider(credentials: FixtureCredentials(), transport: FixtureTransport(events: openAIEvents([Data(missing)]))).stream(request: request(), route: route()) { missingEvents.append(event) }
    #expect(missingEvents == [.finished(.stop)])
}

@Test("Both protocols classify streaming error frames safely")
func streamingErrorFrames() async throws {
    let openAI = FixtureTransport(events: openAIEvents([Data(sse([("", #"{"error":{"message":"secret-provider-body"}}"#)]))]))
    do {
        for try await _ in HTTPModelProvider(credentials: FixtureCredentials("secret"), transport: openAI).stream(request: request(), route: route()) {}
        Issue.record("expected OpenAI error frame")
    } catch let error as MiraError {
        #expect(error.code == .providerRejected)
        #expect(!error.message.contains("secret-provider-body"))
    }

    let anthropic = FixtureTransport(events: anthropicEvents([Data(sse([("error", #"{"type":"error","error":{"message":"secret-provider-body"}}"#)]))]))
    do {
        for try await _ in HTTPModelProvider(credentials: FixtureCredentials("secret"), transport: anthropic).stream(request: request(), route: route(.anthropic)) {}
        Issue.record("expected Anthropic error frame")
    } catch let error as MiraError {
        #expect(error.code == .providerRejected)
        #expect(!error.message.contains("secret-provider-body"))
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
    for kind in [ProviderKind.openAICompatible, .anthropic] {
        let transport = FixtureTransport(events: [.response(HTTPTransportResponse(statusCode: testCase.status)), .end])
        do {
            for try await _ in HTTPModelProvider(credentials: FixtureCredentials("status-secret"), transport: transport).stream(request: request(), route: route(kind)) {}
            Issue.record("expected HTTP status failure")
        } catch let error as MiraError {
            #expect(error.code == testCase.code)
            #expect(!error.message.contains("status-secret"))
        }
    }
}

@Test("Malformed JSON and truncated UTF8 fail for both protocols")
func malformedAndTruncated() async throws {
    let malformedOpenAI = FixtureTransport(events: openAIEvents([Data(sse([("", "{bad")]))]))
    do {
        for try await _ in HTTPModelProvider(credentials: FixtureCredentials(), transport: malformedOpenAI).stream(request: request(), route: route()) {}
        Issue.record("expected malformed OpenAI JSON")
    } catch let error as MiraError { #expect(error.code == .malformedStream) }

    let malformedAnthropic = FixtureTransport(events: anthropicEvents([Data(sse([("message_start", "{bad")]))]))
    do {
        for try await _ in HTTPModelProvider(credentials: FixtureCredentials(), transport: malformedAnthropic).stream(request: request(), route: route(.anthropic)) {}
        Issue.record("expected malformed Anthropic JSON")
    } catch let error as MiraError { #expect(error.code == .malformedStream) }

    let truncated = FixtureTransport(events: openAIEvents([Data([0x64, 0x61, 0x74, 0x61, 0x3a, 0x20, 0xE4]), .init()]))
    do {
        for try await _ in HTTPModelProvider(credentials: FixtureCredentials(), transport: truncated).stream(request: request(), route: route()) {}
        Issue.record("expected truncated UTF8")
    } catch let error as MiraError { #expect(error.code == .malformedStream) }
}

@Test("Anthropic rejects invalid block order and index")
func invalidAnthropicOrdering() async throws {
    let frames = [
        ("message_start", #"{"type":"message_start","message":{"usage":{}}}"#),
        ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text"}}"#)
    ]
    let transport = FixtureTransport(events: anthropicEvents([Data(sse(frames))]))
    do {
        for try await _ in HTTPModelProvider(credentials: FixtureCredentials(), transport: transport).stream(request: request(), route: route(.anthropic)) {}
        Issue.record("expected invalid content block index")
    } catch let error as MiraError { #expect(error.code == .malformedStream) }
}

@Test("A terminal frame cancels a transport that never closes")
func terminalCancelsOpenTransport() async throws {
    let transport = ControlledTransport()
    let provider = HTTPModelProvider(credentials: FixtureCredentials(), transport: transport)
    let consumer = Task { () -> [CanonicalStreamEvent] in
        var result: [CanonicalStreamEvent] = []
        do {
            for try await event in provider.stream(request: request(), route: route()) { result.append(event) }
        } catch { }
        return result
    }
    for _ in 0..<100 where !transport.isReady { try? await Task.sleep(nanoseconds: 1_000_000) }
    transport.send(.response(HTTPTransportResponse(statusCode: 200)))
    transport.send(.bytes(Data(sse([("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#), ("", "[DONE]")]))))
    let events = await consumer.value
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
    var status: Int?
    for try await event in transport.stream(request: request) {
        if case .response(let response) = event { status = response.statusCode }
    }
    #expect(status == 302)
    #expect(RedirectURLProtocol.starts == 1)
}

@Test("URLSession task is cancelled at protocol terminal before peer EOF")
func URLSessionTerminalCleanup() async throws {
    HangingURLProtocol.reset()
    let transport = URLSessionStreamingTransport(protocolClasses: [HangingURLProtocol.self])
    let provider = HTTPModelProvider(credentials: FixtureCredentials(), transport: transport)
    var events: [CanonicalStreamEvent] = []
    for try await event in provider.stream(request: request(), route: route()) { events.append(event) }
    #expect(events == [.finished(.stop)])
    for _ in 0..<100 where HangingURLProtocol.stops == 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
    #expect(HangingURLProtocol.starts == 1)
    #expect(HangingURLProtocol.stops >= 1)
}

@Test("Per-execution cancellation does not cancel an identical concurrent request")
func cancellationUsesUniqueExecutionIdentity() async throws {
    let transport = MultiControlledTransport()
    let provider = HTTPModelProvider(credentials: FixtureCredentials(), transport: transport)
    let firstRequest = request()
    let secondRequest = request()
    let firstID = firstRequest.executionID.rawValue.uuidString
    let secondID = secondRequest.executionID.rawValue.uuidString
    let first = Task { () -> [CanonicalStreamEvent] in
        var result: [CanonicalStreamEvent] = []
        do { for try await event in provider.stream(request: firstRequest, route: route()) { result.append(event) } } catch { }
        return result
    }
    let second = Task { () -> [CanonicalStreamEvent] in
        var result: [CanonicalStreamEvent] = []
        do { for try await event in provider.stream(request: secondRequest, route: route()) { result.append(event) } } catch { }
        return result
    }
    for _ in 0..<100 where transport.readyCount < 2 { try? await Task.sleep(nanoseconds: 1_000_000) }
    transport.send(id: firstID, .response(HTTPTransportResponse(statusCode: 200)))
    transport.send(id: secondID, .response(HTTPTransportResponse(statusCode: 200)))
    first.cancel()
    _ = await first.value
    for _ in 0..<100 where !transport.cancelledIDs.contains(firstID) { try? await Task.sleep(nanoseconds: 1_000_000) }
    #expect(transport.cancelledIDs.contains(firstID))
    #expect(!transport.cancelledIDs.contains(secondID))
    transport.send(id: secondID, .bytes(Data(sse([("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#), ("", "[DONE]")]))))
    let secondEvents = await second.value
    #expect(secondEvents == [.finished(.stop)])
}

@Test("Slow consumers receive a bounded stream failure instead of dropped events")
func boundedCanonicalStream() async throws {
    let frame = Data(sse([("", #"{"choices":[{"delta":{"content":"x"},"finish_reason":null}]}"#)]))
    let events = (0..<256).map { _ in HTTPTransportEvent.bytes(frame) }
    let transport = FixtureTransport(events: [.response(HTTPTransportResponse(statusCode: 200))] + events + [.end])
    var received = 0
    do {
        for try await _ in HTTPModelProvider(credentials: FixtureCredentials(), transport: transport).stream(request: request(), route: route()) {
            received += 1
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("expected bounded stream failure")
    } catch let error as MiraError {
        #expect(error.code == .malformedStream)
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

private func toolRoute(_ kind: ProviderKind = .openAICompatible) -> ModelRoute {
    var result = route(kind)
    result.toolCapability = .verified
    return result
}

private func toolRequest(requestID: UUID = UUID()) -> CanonicalModelRequest {
    CanonicalModelRequest(
        executionID: ExecutionID(),
        system: "Use tools when needed.",
        messages: [
            CanonicalMessage(role: .user, text: "Search my memories"),
            CanonicalMessage(role: .assistant, text: "", toolCalls: [CanonicalToolCall(id: "call-1", name: "memory.search", arguments: #"{"query":"swift"}"#)]),
            CanonicalMessage(role: .tool, text: "A Swift memory", toolCallID: "call-1")
        ],
        requestID: requestID,
        tools: [toolDefinition()]
    )
}

@Test("Tool definitions and history use exact OpenAI and Anthropic wire shapes")
func toolRequestShapes() async throws {
    let openAIResponse = Data(sse([("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#), ("", "[DONE]")]))
    let openAITransport = FixtureTransport(events: openAIEvents([openAIResponse]))
    for try await _ in HTTPModelProvider(credentials: FixtureCredentials(), transport: openAITransport).stream(request: toolRequest(), route: toolRoute()) {}
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
    for try await _ in HTTPModelProvider(credentials: FixtureCredentials(), transport: anthropicTransport).stream(request: toolRequest(), route: toolRoute(.anthropic)) {}
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
    var events: [CanonicalStreamEvent] = []
    for try await event in HTTPModelProvider(credentials: FixtureCredentials(), transport: transport).stream(request: toolRequest(), route: toolRoute()) { events.append(event) }
    #expect(events == [
        .toolCalls([
            CanonicalToolCall(id: "a", name: "memory.search", arguments: #"{"q":"one"}"#),
            CanonicalToolCall(id: "b", name: "memory.search", arguments: #"{"q":"two"}"#)
        ]),
        .finished(.toolCalls)
    ])
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
    var events: [CanonicalStreamEvent] = []
    for try await event in HTTPModelProvider(credentials: FixtureCredentials(), transport: transport).stream(request: toolRequest(requestID: UUID()), route: toolRoute(.anthropic)) { events.append(event) }
    #expect(events == [
        .usage(TokenUsage(inputTokens: nil, outputTokens: nil)),
        .toolCalls([CanonicalToolCall(id: "toolu-1", name: "memory.search", arguments: #"{"query":"swift"}"#)]),
        .finished(.toolCalls)
    ])
}

@Test("Duplicate tool IDs and incomplete tool stops are rejected without tool events")
func invalidToolCallBoundaries() async throws {
    let duplicate = sse([
        ("", #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"same","type":"function","function":{"name":"memory.search","arguments":"{}"}},{"index":1,"id":"same","type":"function","function":{"name":"memory.search","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#),
        ("", "[DONE]")
    ])
    do {
        for try await _ in HTTPModelProvider(credentials: FixtureCredentials(), transport: FixtureTransport(events: openAIEvents([Data(duplicate)]))).stream(request: toolRequest(), route: toolRoute()) {}
        Issue.record("expected duplicate tool ID failure")
    } catch let error as MiraError { #expect(error.code == .malformedStream) }

    let limited = sse([
        ("", #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","type":"function","function":{"name":"memory.search","arguments":"{\"q\":"}}]},"finish_reason":"length"}]}"#),
        ("", "[DONE]")
    ])
    var events: [CanonicalStreamEvent] = []
    for try await event in HTTPModelProvider(credentials: FixtureCredentials(), transport: FixtureTransport(events: openAIEvents([Data(limited)]))).stream(request: toolRequest(), route: toolRoute()) { events.append(event) }
    #expect(events.last == .finished(.outputLimit))
    #expect(!events.contains { if case .toolCalls = $0 { true } else { false } })
}

@Test("Cancellation uses request dispatch IDs when attempts share an execution")
func cancellationUsesDispatchIdentity() async throws {
    let transport = MultiControlledTransport()
    let provider = HTTPModelProvider(credentials: FixtureCredentials(), transport: transport)
    let sharedExecution = ExecutionID()
    let firstRequest = CanonicalModelRequest(executionID: sharedExecution, system: "", messages: [], requestID: UUID())
    let secondRequest = CanonicalModelRequest(executionID: sharedExecution, system: "", messages: [], requestID: UUID())
    let firstID = firstRequest.dispatchID.uuidString
    let secondID = secondRequest.dispatchID.uuidString
    let first = Task { for try await _ in provider.stream(request: firstRequest, route: route()) {} }
    let second = Task { for try await _ in provider.stream(request: secondRequest, route: route()) {} }
    for _ in 0..<100 where transport.readyCount < 2 { try? await Task.sleep(nanoseconds: 1_000_000) }
    first.cancel()
    _ = await first.result
    for _ in 0..<100 where !transport.cancelledIDs.contains(firstID) { try? await Task.sleep(nanoseconds: 1_000_000) }
    #expect(transport.cancelledIDs.contains(firstID))
    #expect(!transport.cancelledIDs.contains(secondID))
    second.cancel()
    _ = await second.result
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
            for try await event in HTTPModelProvider(credentials: FixtureCredentials(), transport: transport).stream(request: toolRequest(), route: toolRoute()) {
                if case .toolCalls = event { emitted = true }
            }
            Issue.record("Expected bounded malformed tool proposal")
        } catch let error as MiraError { #expect(error.code == .malformedStream) }
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
    var events: [CanonicalStreamEvent] = []
    for try await event in HTTPModelProvider(credentials: FixtureCredentials(), transport: good).stream(request: toolRequest(), route: toolRoute(.anthropic)) { events.append(event) }
    #expect(events == [.toolCalls([.init(id: "empty-1", name: "unknown_tool", arguments: "{}")]), .finished(.toolCalls)])
    let bad = FixtureTransport(events: anthropicEvents([Data(sse(prefix + [
        ("content_block_start", #"{"index":1,"content_block":{"type":"text","text":"late"}}"#),
        ("content_block_stop", #"{"index":1}"#), ("message_stop", "{}")
    ]))]))
    do {
        for try await _ in HTTPModelProvider(credentials: FixtureCredentials(), transport: bad).stream(request: toolRequest(), route: toolRoute(.anthropic)) { }
        Issue.record("Expected rejection of content after a stop reason")
    } catch let error as MiraError { #expect(error.code == .malformedStream) }
}

@Test("Orphaned and incomplete tool histories are rejected before transport")
func malformedToolHistoryNeverDispatches() async throws {
    let scenarios: [[CanonicalMessage]] = [
        [.init(role: .tool, text: "orphan", toolCallID: "unknown")],
        [.init(role: .assistant, text: "", toolCalls: [.init(id: "id", name: "memory.search", arguments: "{}")])],
        [.init(role: .assistant, text: "", toolCalls: [.init(id: "id", name: "memory.search", arguments: "{}")]), .init(role: .user, text: "missing result")]
    ]
    for kind in [ProviderKind.openAICompatible, .anthropic] {
        for messages in scenarios {
            let transport = FixtureTransport(events: [])
            var malformed = toolRequest(); malformed.messages = messages
            do {
                for try await _ in HTTPModelProvider(credentials: FixtureCredentials(), transport: transport).stream(request: malformed, route: toolRoute(kind)) { }
                Issue.record("Expected rejection before dispatch")
            } catch let error as MiraError { #expect(error.code == .malformedStream) }
            #expect(transport.requests.isEmpty)
        }
    }
}
