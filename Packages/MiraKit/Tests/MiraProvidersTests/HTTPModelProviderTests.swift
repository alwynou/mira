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
