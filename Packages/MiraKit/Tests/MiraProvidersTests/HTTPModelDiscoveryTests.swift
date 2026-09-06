import Foundation
import Testing
import MiraCore
@testable import MiraProviders

private final class DiscoveryCredentials: CredentialReader, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var readCount = 0
    let value: String

    init(value: String = "fixture-secret") { self.value = value }

    func read(reference: String, version: Int) throws -> String {
        lock.lock(); readCount += 1; lock.unlock()
        return value
    }
}

private final class DiscoveryTransport: HTTPStreamingTransportCancellation, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [[HTTPTransportEvent]]
    private(set) var requests: [URLRequest] = []
    private(set) var cancellations: [URLRequest] = []

    init(pages: [[HTTPTransportEvent]]) { self.pages = pages }

    func stream(request: URLRequest) -> AsyncThrowingStream<HTTPTransportEvent, any Error> {
        lock.lock()
        requests.append(request)
        let events = pages.isEmpty ? [] : pages.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func cancel(request: URLRequest) {
        lock.lock(); cancellations.append(request); lock.unlock()
    }
}

private final class CancellationDiscoveryTransport: HTTPStreamingTransportCancellation, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<HTTPTransportEvent, any Error>.Continuation?
    private(set) var requests: [URLRequest] = []
    private(set) var cancelled = false

    func stream(request: URLRequest) -> AsyncThrowingStream<HTTPTransportEvent, any Error> {
        lock.lock(); requests.append(request); lock.unlock()
        return AsyncThrowingStream { continuation in
            self.lock.lock(); self.continuation = continuation; self.lock.unlock()
        }
    }

    func cancel(request: URLRequest) {
        lock.lock(); cancelled = true; let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.finish(throwing: URLError(.cancelled))
    }
}

private func connection(
    _ kind: ProviderKind = .openAICompatible,
    baseURL: String = "https://example.test/api/v1",
    isEnabled: Bool = true
) -> ProviderConnection {
    ProviderConnection(name: "Fixture", providerKind: kind, baseURL: baseURL, credentialReference: "fixture", isEnabled: isEnabled)
}

private func page(_ json: String, status: Int = 200) -> [HTTPTransportEvent] {
    [.response(HTTPTransportResponse(statusCode: status)), .bytes(Data(json.utf8)), .end]
}

private func assertMiraError(
    _ expectedCode: MiraError.Code,
    operation: () async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        try await operation()
        Issue.record("Expected discovery to fail with \(expectedCode).", sourceLocation: sourceLocation)
    } catch let error as MiraError {
        #expect(error.code == expectedCode, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Expected MiraError, got \(error).", sourceLocation: sourceLocation)
    }
}

@Test("OpenAI discovery uses the base path, auth header, and deterministic deduped ordering")
func openAIShapeAndOrdering() async throws {
    let transport = DiscoveryTransport(pages: [page(#"{"data":[{"id":"zeta"},{"id":"alpha","display_name":"Zed"},{"id":"alpha","display_name":"Alpha"}]}"#)])
    let credentials = DiscoveryCredentials()
    let discovery = HTTPModelDiscovery(credentials: credentials, transport: transport)

    let models = try await discovery.models(for: connection())

    #expect(models == [
        DiscoveredModel(id: "alpha", displayName: "Alpha"),
        DiscoveredModel(id: "zeta")
    ])
    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "https://example.test/api/v1/models")
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret")
    #expect(request.value(forHTTPHeaderField: "X-Mira-Request-ID")?.isEmpty == false)
    #expect(credentials.readCount == 1)
}

@Test("Anthropic discovery follows bounded after_id pagination and protocol headers")
func anthropicPagination() async throws {
    let transport = DiscoveryTransport(pages: [
        page(#"{"data":[{"id":"claude-2","display_name":"Claude 2"}],"has_more":true,"last_id":"claude-2"}"#),
        page(#"{"data":[{"id":"claude-3","display_name":"Claude 3"}],"has_more":false,"last_id":"claude-3"}"#)
    ])
    let discovery = HTTPModelDiscovery(credentials: DiscoveryCredentials(), transport: transport)

    let models = try await discovery.models(for: connection(.anthropic, baseURL: "https://example.test/custom/v1"))

    #expect(models.map(\.id) == ["claude-2", "claude-3"])
    #expect(transport.requests.count == 2)
    let first = try #require(transport.requests.first)
    let second = try #require(transport.requests.dropFirst().first)
    #expect(first.url?.absoluteString == "https://example.test/custom/v1/models?limit=1000")
    #expect(second.url?.absoluteString == "https://example.test/custom/v1/models?limit=1000&after_id=claude-2")
    #expect(first.value(forHTTPHeaderField: "x-api-key") == "fixture-secret")
    #expect(first.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(first.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(first.value(forHTTPHeaderField: "X-Mira-Request-ID") != second.value(forHTTPHeaderField: "X-Mira-Request-ID"))
}

@Test("Anthropic adds its v1 resource path only when the configured base omits it")
func anthropicImplicitV1Path() async throws {
    let transport = DiscoveryTransport(pages: [page(#"{"data":[{"id":"claude-3"}],"has_more":false}"#)])
    let discovery = HTTPModelDiscovery(credentials: DiscoveryCredentials(), transport: transport)

    _ = try await discovery.models(for: connection(.anthropic, baseURL: "https://example.test/custom"))

    #expect(transport.requests.first?.url?.absoluteString == "https://example.test/custom/v1/models?limit=1000")
}

@Test("Disabled connections fail before credential reads or transport calls")
func disabledConnectionBoundary() async {
    let credentials = DiscoveryCredentials()
    let transport = DiscoveryTransport(pages: [page(#"{"data":[]}"#)])
    let discovery = HTTPModelDiscovery(credentials: credentials, transport: transport)

    await assertMiraError(.unauthorized, operation: { _ = try await discovery.models(for: connection(isEnabled: false)) })
    #expect(credentials.readCount == 0)
    #expect(transport.requests.isEmpty)
}

@Test("Malformed IDs and malformed stream sequences are rejected safely")
func malformedBoundaries() async {
    for id in ["", "bad id", "bad\nline", String(repeating: "x", count: 301)] {
        let escaped = id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        let malformedID = DiscoveryTransport(pages: [page("{\"data\":[{\"id\":\"\(escaped)\"}]}")])
        await assertMiraError(.malformedStream, operation: {
            _ = try await HTTPModelDiscovery(credentials: DiscoveryCredentials(), transport: malformedID).models(for: connection())
        })
    }

    let bytesBeforeResponse = DiscoveryTransport(pages: [[.bytes(Data(#"{"data":[]}"#.utf8)), .response(HTTPTransportResponse(statusCode: 200)), .end]])
    await assertMiraError(.malformedStream, operation: {
        _ = try await HTTPModelDiscovery(credentials: DiscoveryCredentials(), transport: bytesBeforeResponse).models(for: connection())
    })

    let missingEnd = DiscoveryTransport(pages: [[.response(HTTPTransportResponse(statusCode: 200)), .bytes(Data(#"{"data":[]}"#.utf8))]])
    await assertMiraError(.interrupted, operation: {
        _ = try await HTTPModelDiscovery(credentials: DiscoveryCredentials(), transport: missingEnd).models(for: connection())
    })

    let missingAnthropicPagination = DiscoveryTransport(pages: [page(#"{"data":[{"id":"claude-3"}]}"#)])
    await assertMiraError(.malformedStream, operation: {
        _ = try await HTTPModelDiscovery(credentials: DiscoveryCredentials(), transport: missingAnthropicPagination).models(for: connection(.anthropic))
    })
}

@Test("Non-success status never exposes response body")
func statusBoundary() async {
    let transport = DiscoveryTransport(pages: [page(#"{"error":"secret provider body"}"#, status: 401)])
    let credentials = DiscoveryCredentials()
    await assertMiraError(.unauthorized, operation: {
        _ = try await HTTPModelDiscovery(credentials: credentials, transport: transport).models(for: connection())
    })
    #expect(transport.cancellations.count == 1)
    #expect(transport.cancellations.first?.value(forHTTPHeaderField: "X-Mira-Request-ID") == transport.requests.first?.value(forHTTPHeaderField: "X-Mira-Request-ID"))
}

@Test("Model count and page byte limits fail instead of returning partial results")
func resourceLimits() async {
    let manyModels = (0..<2_001).map { "{\"id\":\"model-\($0)\"}" }.joined(separator: ",")
    let tooMany = DiscoveryTransport(pages: [page("{\"data\":[\(manyModels)]}")])
    await assertMiraError(.outputLimit, operation: {
        _ = try await HTTPModelDiscovery(credentials: DiscoveryCredentials(), transport: tooMany).models(for: connection())
    })

    let oversized = DiscoveryTransport(pages: [[.response(HTTPTransportResponse(statusCode: 200)), .bytes(Data(repeating: 0x20, count: 2 * 1024 * 1024 + 1)), .end]])
    await assertMiraError(.outputLimit, operation: {
        _ = try await HTTPModelDiscovery(credentials: DiscoveryCredentials(), transport: oversized).models(for: connection())
    })

    let pageBody = String(repeating: "x", count: 1_800_000)
    let totalPages = (1...5).map { index in
        let more = index < 5 ? "true" : "false"
        let cursor = index < 5 ? ",\"last_id\":\"cursor-\(index)\"" : ""
        return page("{\"data\":[],\"has_more\":\(more)\(cursor),\"padding\":\"\(pageBody)\"}")
    }
    await assertMiraError(.outputLimit, operation: {
        _ = try await HTTPModelDiscovery(credentials: DiscoveryCredentials(), transport: DiscoveryTransport(pages: totalPages)).models(for: connection(.anthropic))
    })
}

@Test("Cancellation calls the transport hook for the active request")
func cancellationCancelsActiveRequest() async throws {
    let transport = CancellationDiscoveryTransport()
    let discovery = HTTPModelDiscovery(credentials: DiscoveryCredentials(), transport: transport)
    let task = Task {
        try await discovery.models(for: connection())
    }
    while transport.requests.isEmpty { await Task.yield() }
    task.cancel()
    _ = try? await task.value
    #expect(transport.cancelled)
}
