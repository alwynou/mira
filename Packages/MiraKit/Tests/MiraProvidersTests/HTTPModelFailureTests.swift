import Foundation
import Testing
import MiraCore
@testable import MiraProviders

private struct FailureCredentials: CredentialReader {
    func read(reference: String, version: Int) throws -> String { "synthetic-secret" }
}

private final class FailureTransport: HTTPStreamingTransport, @unchecked Sendable {
    let eventsToEmit: [HTTPTransportEvent]
    let terminalError: (any Error)?
    private let lock = NSLock()
    var closeCount: Int { lock.withLock { _closeCount } }
    var dispatchCount: Int { lock.withLock { _dispatchCount } }
    private var _closeCount = 0
    private var _dispatchCount = 0

    init(events: [HTTPTransportEvent], error: (any Error)? = nil) {
        self.eventsToEmit = events
        self.terminalError = error
    }

    func stream(request: URLRequest) -> HTTPTransportOperation {
        lock.withLock { _dispatchCount += 1 }
        let (events, continuation) = AsyncThrowingStream<HTTPTransportEvent, any Error>.makeStream()
        for event in eventsToEmit { continuation.yield(event) }
        if let terminalError { continuation.finish(throwing: terminalError) }
        else { continuation.finish() }
        return HTTPTransportOperation(events: events) {
            self.lock.withLock { self._closeCount += 1 }
        }
    }
}

@Suite("HTTP model failure classification", .timeLimit(.minutes(1)))
struct HTTPModelFailureTests {
    private func route() throws -> AgentModelRoute {
        .init(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
              modelDescriptorID: ModelDescriptorID(), modelRevision: 1,
              adapter: ProtocolFixture.standard.identity, modelID: "fixture",
              credential: .init(reference: "fixture", version: 1), contextWindow: 32_768,
              maximumOutputTokens: 1_024,
              capabilities: .init(streamsText: true, callsTools: false, producesThinking: false),
              configuration: try HTTPModelConfiguration(baseURL: "https://fixture.test").jsonValue())
    }

    private func input() -> AgentModelInput {
        .init(stepID: UUID(), executionID: ExecutionID(), instructions: "Answer.",
              messages: [.init(role: .user, text: "Hello")], tools: [])
    }

    private func failure(for status: Int, headers: [String: String] = [:], now: @escaping @Sendable () -> Date = Date.init) async throws -> AgentModelFailure {
        let transport = FailureTransport(events: [.response(.init(statusCode: status, headers: headers))])
        return try await failure(using: transport, now: now)
    }

    private func failure(using transport: FailureTransport,
                         now: @escaping @Sendable () -> Date = Date.init) async throws -> AgentModelFailure {
        let adapter = HTTPModelAdapter(fixture: .standard, credentials: FailureCredentials(), transport: transport, now: now)
        let route = try route()
        let operation = adapter.stream(try adapter.prepare(input(), route: route), route: route)
        do {
            for try await _ in operation.events {}
            Issue.record("Expected stream failure.")
            throw MiraError(.conflict, "Expected stream failure.")
        } catch let error as AgentModelFailure {
            await operation.close()
            #expect(transport.closeCount == 1)
            #expect(transport.dispatchCount == 1)
            try error.validate()
            return error
        } catch {
            await operation.close()
            throw error
        }
    }

    @Test func transientStatusAndRetryAfterSecondsAreClassified() async throws {
        let result = try await failure(for: 429, headers: ["Retry-After": "12"])
        #expect(result.error.code == .rateLimited)
        #expect(result.retryAdvice == .transient(minimumDelayMilliseconds: 12_000))
    }

    @Test func retryAfterDateUsesTheCapturedClock() async throws {
        let now = Date(timeIntervalSince1970: 0)
        let header = "Thu, 01 Jan 1970 00:10:00 GMT"
        let result = try await failure(for: 503, headers: ["Retry-After": header], now: { now })
        #expect(result.retryAdvice == .transient(minimumDelayMilliseconds: 600_000))
        let boundary = try await failure(for: 503, headers: ["Retry-After": "Fri, 02 Jan 1970 00:00:00 GMT"], now: { now })
        #expect(boundary.retryAdvice == .transient(minimumDelayMilliseconds: 86_400_000))
        let past = try await failure(for: 503, headers: ["Retry-After": "Wed, 31 Dec 1969 23:59:59 GMT"], now: { now })
        #expect(past.retryAdvice == .transient(minimumDelayMilliseconds: 0))
        let remoteFuture = try await failure(for: 503, headers: ["Retry-After": header],
            now: { Date(timeIntervalSince1970: 1e100) })
        #expect(remoteFuture.retryAdvice == .transient(minimumDelayMilliseconds: 0))
    }

    @Test func invalidRetryAfterDisablesAdviceWithoutExposingHeader() async throws {
        for value in ["", "-1", "1.5", "NaN", String(repeating: "9", count: 129), "86401",
                      "Thu, 01 Jan 1970 00:10:00 PST", "Xxx, 01 Jan 1970 00:10:00 GMT", "Fri, 01 Jan 1970 00:10:00 GMT", String(Int.max)] {
            let result = try await failure(for: 500, headers: ["Retry-After": value])
            #expect(result.retryAdvice == nil)
            if !value.isEmpty { #expect(!result.error.message.contains(value)) }
        }
    }

    @Test func permanentAndProtocolFailuresHaveNoAdvice() async throws {
        for status in [401, 403, 501, 505] {
            let permanent = try await failure(for: status)
            #expect(permanent.retryAdvice == nil)
        }

        let result = try await failure(using: FailureTransport(events: [.response(.init(statusCode: 200)), .end]))
        #expect(result.error.code == .interrupted && result.retryAdvice == nil)
    }

    @Test func selectedNetworkErrorsAreTransientButCancellationIsNot() async throws {
        for code in [URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet] {
            let result = try await failure(using: FailureTransport(events: [], error: URLError(code)))
            #expect(result.retryAdvice == .transient(minimumDelayMilliseconds: 0))
        }
        for code in [URLError.Code.secureConnectionFailed, .cancelled, .unknown] {
            let result = try await failure(using: FailureTransport(events: [], error: URLError(code)))
            #expect(result.retryAdvice == nil)
            if code == .cancelled { #expect(result.error.code == .cancelled) }
        }
    }

    @Test func allTransientStatusesAndNetworkAfterResponseAreClassified() async throws {
        for status in [408, 429, 500, 502, 503, 504] {
            let result = try await failure(for: status)
            #expect(result.retryAdvice == .transient(minimumDelayMilliseconds: 0))
        }
        for seconds in ["0", "86400"] {
            let result = try await failure(for: 429, headers: ["retry-after": seconds])
            #expect(result.retryAdvice == .transient(minimumDelayMilliseconds: Int(seconds)! * 1_000))
        }
        let result = try await failure(using: FailureTransport(events: [.response(.init(statusCode: 200))], error: URLError(.timedOut)))
        #expect(result.retryAdvice == .transient(minimumDelayMilliseconds: 0))
    }
}
