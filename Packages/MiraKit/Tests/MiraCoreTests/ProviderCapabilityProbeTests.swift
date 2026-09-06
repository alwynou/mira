import Foundation
import Testing
@testable import MiraCore

struct ProviderCapabilityProbeTests {
    @Test func unknownWindowFailsBeforeTransport() async {
        let provider = ProbeFixtureProvider(events: [])
        let result = await ProviderCapabilityProbe(provider: provider).run(route: route(window: nil), kind: .text)
        #expect(result.state == .failed)
        #expect(provider.requestCount == 0)
    }

    @Test func textRequiresNonEmptyStopAndToolRequiresExactCall() async {
        let text = ProbeFixtureProvider(events: [.textDelta("ok"), .finished(.stop)])
        let textResult = await ProviderCapabilityProbe(provider: text).run(route: route(), kind: .text)
        #expect(textResult.state == .verified)
        let tool = ProbeFixtureProvider(events: [.toolCalls([.init(id: "any", name: "probe.echo", arguments: "{ \"value\": \"MIRA_PROBE\" }")]), .finished(.toolCalls)])
        let toolResult = await ProviderCapabilityProbe(provider: tool).run(route: route(), kind: .tools)
        #expect(toolResult.state == .verified)
    }

    @Test func falsePositiveToolAndMissingTerminalFail() async {
        let wrong = ProbeFixtureProvider(events: [.toolCalls([.init(id: "x", name: "probe.echo", arguments: "{\"value\":\"wrong\"}")]), .finished(.toolCalls)])
        #expect((await ProviderCapabilityProbe(provider: wrong).run(route: route(), kind: .tools)).state == .failed)
        let missing = ProbeFixtureProvider(events: [.textDelta("ok")])
        #expect((await ProviderCapabilityProbe(provider: missing).run(route: route(), kind: .text)).state == .failed)
    }

    @Test func probeUsesSyntheticInputAndTemporaryCapabilitiesWithoutChangingRoute() async throws {
        let provider = ProbeFixtureProvider(events: [.textDelta("ok"), .finished(.stop)])
        var original = route(); original.textCapability = .unknown; original.toolCapability = .failed
        original.name = "personal route title must not be sent"
        let result = await ProviderCapabilityProbe(provider: provider).run(route: original, kind: .text)
        #expect(result.state == .verified)
        #expect(original.textCapability == .unknown)
        let sent = try #require(provider.requests.first)
        #expect(sent.tools == nil)
        #expect(sent.requestID != nil)
        #expect(sent.messages.count == 1)
        #expect(sent.messages[0].text.contains("MIRA_SYNTHETIC_TEXT_PROBE"))
        #expect(!sent.system.contains(original.name))
        #expect(provider.routes.first?.textCapability == .declared)
        #expect(provider.routes.first?.maxOutputTokens == 128)
    }

    @Test func malformedOrOversizedProbeStreamsCannotVerifyCapabilities() async {
        let cases: [[CanonicalStreamEvent]] = [
            [.textDelta(" "), .finished(.stop)],
            [.textDelta("ok"), .finished(.outputLimit)],
            [.textDelta("ok"), .finished(.stop), .textDelta("after terminal")],
            [.textDelta("ok"), .finished(.stop), .finished(.stop)],
            [.textDelta(String(repeating: "a", count: 10_000)), .textDelta(String(repeating: "b", count: 10_000)), .finished(.stop)]
        ]
        for events in cases {
            let result = await ProviderCapabilityProbe(provider: ProbeFixtureProvider(events: events)).run(route: route(), kind: .text)
            #expect(result.state == .failed)
        }
        for arguments in ["{\"value\":\"MIRA_PROBE\",\"approved\":\"yes\"}", "{", "[]"] {
            let provider = ProbeFixtureProvider(events: [.toolCalls([.init(id: "id", name: "probe.echo", arguments: arguments)]), .finished(.toolCalls)])
            let result = await ProviderCapabilityProbe(provider: provider).run(route: route(), kind: .tools)
            #expect(result.state == .failed)
            #expect(result.error?.code == .providerRejected)
        }
    }

    @Test func cancellingProbeDoesNotReportFailedCapabilityAndEndsItsStream() async throws {
        let provider = HangingProbeProvider()
        let service = ProviderCapabilityProbe(provider: provider)
        let route = route()
        let task = Task { await service.run(route: route, kind: .text) }
        for _ in 0..<200 {
            if provider.started { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(provider.started)
        task.cancel()
        let result = await task.value
        #expect(result.state == .unknown)
        #expect(result.error?.code == .cancelled)
        #expect(provider.terminated)
    }

    @Test func injectedDeadlineReportsTimeoutAndCancelsTransport() async {
        let provider = HangingProbeProvider()
        let environment = RuntimeEnvironment(sleep: { _ in
            while !provider.started { try Task.checkCancellation(); await Task.yield() }
        })
        let result = await ProviderCapabilityProbe(provider: provider, environment: environment).run(route: route(), kind: .text)
        #expect(result.state == .failed)
        #expect(result.error?.code == .timeout)
        #expect(provider.terminated)
    }

    @Test func jsonExtractionProbeRequiresExactJSONAndDoesNotDeclareTextOrTools() async throws {
        let provider = ProbeFixtureProvider(events: [.textDelta("{ \"value\": \"MIRA_PROBE\" }"), .finished(.stop)])
        let original = route()
        let result = await ProviderCapabilityProbe(provider: provider).run(route: original, kind: .jsonExtraction)
        #expect(result.state == .verified)
        #expect(result.type == .jsonExtraction)
        #expect(original.extractionCapability == .unknown)
        let request = try #require(provider.requests.first)
        #expect(request.tools == nil)
        #expect(request.messages[0].text.contains("MIRA_SYNTHETIC_JSON_PROBE"))
        #expect(provider.routes.first?.purpose == .memoryExtraction)
        #expect(provider.routes.first?.extractionCapability == .declared)
        for text in ["ok", "{}", "{\"value\":\"MIRA_PROBE\",\"extra\":\"no\"}", "```json\n{\"value\":\"MIRA_PROBE\"}\n```"] {
            let invalid = ProbeFixtureProvider(events: [.textDelta(text), .finished(.stop)])
            #expect((await ProviderCapabilityProbe(provider: invalid).run(route: original, kind: .jsonExtraction)).state == .failed)
        }
        let limited = ProbeFixtureProvider(events: [.textDelta("{\"value\":\"MIRA_PROBE\"}"), .finished(.outputLimit)])
        #expect((await ProviderCapabilityProbe(provider: limited).run(route: original, kind: .jsonExtraction)).state == .failed)
    }

    private func route(window: Int? = 8_192) -> ResolvedModelRouteSnapshot {
        .init(name: "fixture", providerKind: .openAICompatible, baseURL: "https://example.com/v1", modelID: "fixture", credentialReference: "fixture", contextWindow: window)
    }
}

private final class ProbeFixtureProvider: ModelProviderPort, @unchecked Sendable {
    let events: [CanonicalStreamEvent]
    private let lock = NSLock()
    private var capturedRequests: [CanonicalModelRequest] = []
    private var capturedRoutes: [ResolvedModelRouteSnapshot] = []
    var requests: [CanonicalModelRequest] { lock.withLock { capturedRequests } }
    var routes: [ResolvedModelRouteSnapshot] { lock.withLock { capturedRoutes } }
    var requestCount: Int { lock.withLock { capturedRequests.count } }
    init(events: [CanonicalStreamEvent]) { self.events = events }
    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        lock.withLock { capturedRequests.append(request); capturedRoutes.append(route) }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
private final class HangingProbeProvider: ModelProviderPort, @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didTerminate = false
    var started: Bool { lock.withLock { didStart } }
    var terminated: Bool { lock.withLock { didTerminate } }
    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        let pair = AsyncThrowingStream<CanonicalStreamEvent, any Error>.makeStream()
        pair.continuation.onTermination = { [weak self] _ in self?.markTerminated() }
        lock.withLock { didStart = true }
        return pair.stream
    }
    private func markTerminated() { lock.withLock { didTerminate = true } }
}
