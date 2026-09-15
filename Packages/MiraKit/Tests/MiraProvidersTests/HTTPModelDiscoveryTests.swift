import Foundation
import MiraCore
import Testing

@testable import MiraProviders

private final class DiscoveryCredentials: CredentialReader, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    let value: String
    var readCount: Int { lock.withLock { reads } }
    init(value: String = "fixture-secret") { self.value = value }
    func read(reference: String, version: Int) throws -> String {
        lock.withLock { reads += 1 }
        return value
    }
}

private final class DiscoveryTransport: HTTPStreamingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [[HTTPTransportEvent]]
    private var recordedRequests: [URLRequest] = []
    private var recordedCancellations: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recordedRequests } }
    var cancellations: [URLRequest] { lock.withLock { recordedCancellations } }
    init(pages: [[HTTPTransportEvent]]) { self.pages = pages }
    func stream(request: URLRequest) -> HTTPTransportOperation {
        let events = lock.withLock {
            recordedRequests.append(request)
            return pages.isEmpty ? [] : pages.removeFirst()
        }
        let stream = AsyncThrowingStream<HTTPTransportEvent, any Error> { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
        return .init(events: stream) { [weak self] in
            self?.lock.withLock { self?.recordedCancellations.append(request) }
        }
    }
}

private final class CancellationDiscoveryTransport: HTTPStreamingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<HTTPTransportEvent, any Error>.Continuation?
    private var recordedRequests: [URLRequest] = []
    private var wasCancelled = false
    var requests: [URLRequest] { lock.withLock { recordedRequests } }
    var cancelled: Bool { lock.withLock { wasCancelled } }
    func stream(request: URLRequest) -> HTTPTransportOperation {
        lock.withLock { recordedRequests.append(request) }
        let stream = AsyncThrowingStream<HTTPTransportEvent, any Error> { continuation in
            self.lock.withLock { self.continuation = continuation }
        }
        return .init(events: stream) { [weak self] in self?.cancelAndFinish() }
    }
    private func cancelAndFinish() {
        let continuation = lock.withLock {
            wasCancelled = true
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.finish(throwing: URLError(.cancelled))
    }
}

private struct DrainingDiscoveryTransport: HTTPStreamingTransport {
    let gate = DiscoveryDrainGate()
    func stream(request: URLRequest) -> HTTPTransportOperation {
        let stream = AsyncThrowingStream<HTTPTransportEvent, any Error> { continuation in
            continuation.yield(.response(.init(statusCode: 200)))
            continuation.yield(.bytes(Data(#"{"data":[{"id":"alpha"}]}"#.utf8)))
            continuation.yield(.end)
            continuation.finish()
        }
        return .init(events: stream) { await gate.wait() }
    }
}
private actor DiscoveryDrainGate {
    private(set) var closeCount = 0
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        closeCount += 1
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}
private func waitForDiscovery(_ condition: () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard clock.now < deadline else { throw MiraError(.timeout, "Discovery fixture timed out.") }
        try await Task.sleep(for: .milliseconds(1))
    }
}
private actor CloseProbe {
    private(set) var returned = false
    func markReturned() { returned = true }
}

private func connection(
    baseURL: String = "https://example.test/api/v1", isEnabled: Bool = true,
    credential: AgentCredentialReference? = .init(reference: "fixture", version: 1),
    schema: AgentConfigurationIdentity = .init(id: "mira.http.connection", revision: 2), value: JSONValue? = nil,
    discoveryProtocol: HTTPModelDiscoveryProtocol = .openAI
) -> AgentConfiguredConnection {
    .init(
        id: .init(), revision: 1, configurationRevision: 1, name: "Fixture", isEnabled: isEnabled,
        credential: credential,
        configuration: .init(
            schema: schema, value: value ?? .object(["baseURL": .string(baseURL), "allowsLoopbackHTTP": .bool(false)])),
        discovery: .init(adapter: discoveryProtocol.identity, endpointID: "primary"))
}
private func page(_ json: String, status: Int = 200) -> [HTTPTransportEvent] {
    [.response(.init(statusCode: status)), .bytes(Data(json.utf8)), .end]
}
private func result(_ operation: AgentModelDiscoveryOperation) async throws -> [AgentDiscoveredModel] {
    do {
        let value = try await operation.result()
        await operation.close()
        return value
    } catch {
        await operation.close()
        throw error
    }
}
private func assertMiraError(
    _ code: MiraError.Code, operation: () async throws -> Void, sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        try await operation()
        Issue.record("Expected discovery to fail with \(code).", sourceLocation: sourceLocation)
    } catch let error as MiraError { #expect(error.code == code, sourceLocation: sourceLocation) } catch {
        Issue.record("Expected MiraError, got \(error).", sourceLocation: sourceLocation)
    }
}

@Test("OpenAI discovery uses the base path, auth header, and deterministic deduped ordering")
func openAIShapeAndOrdering() async throws {
    let transport = DiscoveryTransport(pages: [
        page(#"{"data":[{"id":"zeta"},{"id":"alpha","display_name":"Zed"},{"id":"alpha","display_name":"Alpha"}]}"#)
    ])
    let credentials = DiscoveryCredentials()
    let provider = HTTPModelDiscovery(protocolKind: .openAI, credentials: credentials, transport: transport)
    let models = try await result(provider.discover(connection: connection()))
    #expect(models == [.init(id: "alpha", displayName: "Alpha"), .init(id: "zeta")])
    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "https://example.test/api/v1/models")
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret")
    #expect(credentials.readCount == 1)
}

@Test("Anthropic discovery follows bounded after_id pagination and protocol headers")
func anthropicPagination() async throws {
    let transport = DiscoveryTransport(pages: [
        page(#"{"data":[{"id":"claude-2","display_name":"Claude 2"}],"has_more":true,"last_id":"claude-2"}"#),
        page(#"{"data":[{"id":"claude-3","display_name":"Claude 3"}],"has_more":false,"last_id":"claude-3"}"#),
    ])
    let provider = HTTPModelDiscovery(
        protocolKind: .anthropic, credentials: DiscoveryCredentials(), transport: transport)
    let models = try await result(provider.discover(connection: connection(baseURL: "https://example.test/custom/v1", discoveryProtocol: .anthropic)))
    #expect(models.map(\.id) == ["claude-2", "claude-3"])
    #expect(transport.requests.count == 2)
    let first = try #require(transport.requests.first)
    let second = try #require(transport.requests.dropFirst().first)
    #expect(first.url?.absoluteString == "https://example.test/custom/v1/models?limit=1000")
    #expect(second.url?.absoluteString == "https://example.test/custom/v1/models?limit=1000&after_id=claude-2")
    #expect(first.value(forHTTPHeaderField: "x-api-key") == "fixture-secret")
    #expect(first.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(first.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(
        first.value(forHTTPHeaderField: "X-Mira-Request-ID") != second.value(forHTTPHeaderField: "X-Mira-Request-ID"))
}

@Test("Anthropic discovery adds its v1 resource path only when omitted")
func anthropicImplicitV1Path() async throws {
    let transport = DiscoveryTransport(pages: [page(#"{"data":[{"id":"claude-3"}],"has_more":false}"#)])
    let provider = HTTPModelDiscovery(
        protocolKind: .anthropic, credentials: DiscoveryCredentials(), transport: transport)
    _ = try await result(provider.discover(connection: connection(baseURL: "https://example.test", discoveryProtocol: .anthropic)))
    #expect(transport.requests.first?.url?.absoluteString == "https://example.test/v1/models?limit=1000")
}

@Test("Anthropic discovery preserves a customv1 base path before adding v1")
func anthropicCustomV1BasePath() async throws {
    let transport = DiscoveryTransport(pages: [page(#"{"data":[{"id":"claude-3"}],"has_more":false}"#)])
    let provider = HTTPModelDiscovery(
        protocolKind: .anthropic, credentials: DiscoveryCredentials(), transport: transport)
    _ = try await result(provider.discover(connection: connection(baseURL: "https://example.test/customv1", discoveryProtocol: .anthropic)))
    #expect(transport.requests.first?.url?.absoluteString == "https://example.test/customv1/v1/models?limit=1000")
}

@Test("Disabled, missing-credential, and invalid schemas fail before I/O")
func configurationBoundary() async {
    let dc = DiscoveryCredentials()
    let dt = DiscoveryTransport(pages: [page(#"{"data":[]}"#)])
    let disabled = HTTPModelDiscovery(protocolKind: .openAI, credentials: dc, transport: dt)
    await assertMiraError(
        .unauthorized, operation: { _ = try await result(disabled.discover(connection: connection(isEnabled: false))) })
    #expect(dc.readCount == 0)
    #expect(dt.requests.isEmpty)
    let mc = DiscoveryCredentials()
    let mt = DiscoveryTransport(pages: [page(#"{"data":[]}"#)])
    let missing = HTTPModelDiscovery(protocolKind: .openAI, credentials: mc, transport: mt)
    await assertMiraError(
        .credentialMissing,
        operation: { _ = try await result(missing.discover(connection: connection(credential: nil))) })
    #expect(mc.readCount == 0)
    #expect(mt.requests.isEmpty)
    let it = DiscoveryTransport(pages: [page(#"{"data":[]}"#)])
    let invalid = HTTPModelDiscovery(protocolKind: .openAI, credentials: DiscoveryCredentials(), transport: it)
    await assertMiraError(
        .configuration,
        operation: {
            _ = try await result(
                invalid.discover(connection: connection(schema: .init(id: "mira.http.foreign", revision: 1))))
        })
    #expect(it.requests.isEmpty)
    let unknownTransport = DiscoveryTransport(pages: [page(#"{"data":[]}"#)])
    let unknown = HTTPModelDiscovery(
        protocolKind: .openAI, credentials: DiscoveryCredentials(), transport: unknownTransport)
    await assertMiraError(
        .invalidInput,
        operation: {
            _ = try await result(
                unknown.discover(
                    connection: connection(
                        value: .object([
                            "baseURL": .string("https://example.test"), "allowsLoopbackHTTP": .bool(false),
                            "unexpected": .bool(true),
                        ]))))
        })
    #expect(unknownTransport.requests.isEmpty)
    let endpointTransport = DiscoveryTransport(pages: [page(#"{"data":[]}"#)])
    let endpoint = HTTPModelDiscovery(
        protocolKind: .openAI, credentials: DiscoveryCredentials(), transport: endpointTransport)
    await assertMiraError(
        .configuration,
        operation: { _ = try await result(endpoint.discover(connection: connection(baseURL: "http://example.test"))) })
    #expect(endpointTransport.requests.isEmpty)
}

@Test("Malformed IDs, stream sequences, and pagination cursors fail safely")
func malformedBoundaries() async {
    for id in [
        "", "bad id", "bad\nline", String(repeating: "x", count: 513), String(repeating: "\u{00E9}", count: 257),
    ] {
        let escaped = id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let transport = DiscoveryTransport(pages: [page("{\"data\":[{\"id\":\"\(escaped)\"}]}")])
        await assertMiraError(
            .malformedStream,
            operation: {
                _ = try await result(
                    HTTPModelDiscovery(protocolKind: .openAI, credentials: DiscoveryCredentials(), transport: transport)
                        .discover(connection: connection()))
            })
    }
    let longDisplay = DiscoveryTransport(pages: [
        page("{\"data\":[{\"id\":\"model\",\"display_name\":\"\(String(repeating: "x", count: 513))\"}]}")
    ])
    let displayResult = try? await result(
        HTTPModelDiscovery(protocolKind: .openAI, credentials: DiscoveryCredentials(), transport: longDisplay).discover(
            connection: connection()))
    #expect(displayResult?.map(\.id) == ["model"])
    #expect(displayResult?.first?.displayName == nil)
    let bytes = DiscoveryTransport(pages: [
        [.bytes(Data(#"{"data":[]}"#.utf8)), .response(.init(statusCode: 200)), .end]
    ])
    await assertMiraError(
        .malformedStream,
        operation: {
            _ = try await result(
                HTTPModelDiscovery(protocolKind: .openAI, credentials: DiscoveryCredentials(), transport: bytes)
                    .discover(connection: connection()))
        })
    let eof = DiscoveryTransport(pages: [[.response(.init(statusCode: 200)), .bytes(Data(#"{"data":[]}"#.utf8))]])
    await assertMiraError(
        .interrupted,
        operation: {
            _ = try await result(
                HTTPModelDiscovery(protocolKind: .openAI, credentials: DiscoveryCredentials(), transport: eof).discover(
                    connection: connection()))
        })
    let missingPagination = DiscoveryTransport(pages: [page(#"{"data":[{"id":"claude-3"}]}"#)])
    await assertMiraError(
        .malformedStream,
        operation: {
            _ = try await result(
                HTTPModelDiscovery(
                    protocolKind: .anthropic, credentials: DiscoveryCredentials(), transport: missingPagination
                ).discover(connection: connection(baseURL: "https://example.test", discoveryProtocol: .anthropic)))
        })
    let cursor = DiscoveryTransport(pages: [
        page(#"{"data":[],"has_more":true,"last_id":"same"}"#), page(#"{"data":[],"has_more":true,"last_id":"same"}"#),
    ])
    await assertMiraError(
        .malformedStream,
        operation: {
            _ = try await result(
                HTTPModelDiscovery(protocolKind: .anthropic, credentials: DiscoveryCredentials(), transport: cursor)
                    .discover(connection: connection(baseURL: "https://example.test", discoveryProtocol: .anthropic)))
        })
}

@Test("Non-success status never exposes response body")
func statusBoundary() async {
    let transport = DiscoveryTransport(pages: [page(#"{"error":"secret provider body"}"#, status: 401)])
    let provider = HTTPModelDiscovery(protocolKind: .openAI, credentials: DiscoveryCredentials(), transport: transport)
    await assertMiraError(
        .unauthorized, operation: { _ = try await result(provider.discover(connection: connection())) })
    #expect(transport.cancellations.count == 1)
    #expect(
        transport.cancellations.first?.value(forHTTPHeaderField: "X-Mira-Request-ID")
            == transport.requests.first?.value(forHTTPHeaderField: "X-Mira-Request-ID"))
}

@Test("Model count and page byte limits fail instead of returning partial results")
func resourceLimits() async {
    let many = (0..<2_001).map { "{\"id\":\"model-\($0)\"}" }.joined(separator: ",")
    let tooMany = DiscoveryTransport(pages: [page("{\"data\":[\(many)]}")])
    await assertMiraError(
        .outputLimit,
        operation: {
            _ = try await result(
                HTTPModelDiscovery(protocolKind: .openAI, credentials: DiscoveryCredentials(), transport: tooMany)
                    .discover(connection: connection()))
        })
    let oversized = DiscoveryTransport(pages: [
        [.response(.init(statusCode: 200)), .bytes(Data(repeating: 0x20, count: 2 * 1024 * 1024 + 1)), .end]
    ])
    await assertMiraError(
        .outputLimit,
        operation: {
            _ = try await result(
                HTTPModelDiscovery(protocolKind: .openAI, credentials: DiscoveryCredentials(), transport: oversized)
                    .discover(connection: connection()))
        })
    let body = String(repeating: "x", count: 1_800_000)
    let pages = (1...5).map { i in
        page(
            "{\"data\":[],\"has_more\":\(i < 5 ? "true" : "false")\(i < 5 ? ",\"last_id\":\"cursor-\(i)\"" : ""),\"padding\":\"\(body)\"}"
        )
    }
    await assertMiraError(
        .outputLimit,
        operation: {
            _ = try await result(
                HTTPModelDiscovery(
                    protocolKind: .anthropic, credentials: DiscoveryCredentials(),
                    transport: DiscoveryTransport(pages: pages)
                ).discover(connection: connection(baseURL: "https://example.test", discoveryProtocol: .anthropic)))
        })
}

@Test("Cancellation closes the active discovery operation and transport")
func cancellationCancelsActiveRequest() async throws {
    let transport = CancellationDiscoveryTransport()
    let provider = HTTPModelDiscovery(protocolKind: .openAI, credentials: DiscoveryCredentials(), transport: transport)
    let operation = provider.discover(connection: connection())
    let task = Task { try await operation.result() }
    do {
        try await waitForDiscovery { !transport.requests.isEmpty }
        task.cancel()
        _ = await task.result
        await operation.close()
        #expect(transport.cancelled)
    } catch {
        task.cancel()
        await operation.close()
        _ = await task.result
        throw error
    }
}

@Test("Closing waits for the finished producer's underlying transport drain")
func closeWaitsForTransportDrain() async throws {
    let transport = DrainingDiscoveryTransport()
    let provider = HTTPModelDiscovery(protocolKind: .openAI, credentials: DiscoveryCredentials(), transport: transport)
    let operation = provider.discover(connection: connection())
    let resultTask = Task { try await operation.result() }
    let probe = CloseProbe()
    do {
        try await waitForDiscovery { await transport.gate.closeCount == 1 }
        let closeTask = Task {
            await operation.close()
            await probe.markReturned()
        }
        // The underlying drain is already entered and cannot return until its gate opens.
        #expect(await probe.returned == false)
        await transport.gate.open()
        _ = await resultTask.result
        await closeTask.value
        #expect(await probe.returned)
        #expect(await transport.gate.closeCount == 1)
    } catch {
        await transport.gate.open()
        await operation.close()
        _ = await resultTask.result
        throw error
    }
}

@Test("Anthropic discovery stops before requesting an eleventh page")
func pageCountBoundary() async {
    let pages = (0..<11).map { page("{\"data\":[],\"has_more\":true,\"last_id\":\"cursor-\($0)\"}") }
    let transport = DiscoveryTransport(pages: pages)
    let provider = HTTPModelDiscovery(
        protocolKind: .anthropic, credentials: DiscoveryCredentials(), transport: transport)
    await assertMiraError(.outputLimit) { _ = try await result(provider.discover(connection: connection(discoveryProtocol: .anthropic))) }
    #expect(transport.requests.count == 10)
    #expect(transport.cancellations.count == 10)
}
