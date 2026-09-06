import Foundation
import Testing
@testable import MiraProviders
import MiraCore

private final class UsageCredentials: CredentialReader, @unchecked Sendable {
    func read(reference: String, version: Int) throws -> String { "fixture-secret" }
}

private final class UsageTransport: HTTPStreamingTransport, @unchecked Sendable {
    let events: [HTTPTransportEvent]

    init(events: [HTTPTransportEvent]) { self.events = events }

    func stream(request: URLRequest) -> AsyncThrowingStream<HTTPTransportEvent, any Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private func usageRoute(_ providerKind: ProviderKind = .openAICompatible) -> ResolvedModelRouteSnapshot {
    ResolvedModelRouteSnapshot(name: "Usage fixture", providerKind: providerKind,
                               baseURL: "https://example.test", modelID: "fixture-model",
                               credentialReference: "fixture", contextWindow: 4096,
                               maxOutputTokens: 128, requestsUsage: true)
}

private func usageRequest() -> CanonicalModelRequest {
    CanonicalModelRequest(executionID: ExecutionID(), system: "Be concise.",
                          messages: [CanonicalMessage(role: .user, text: "Hello")])
}

private func usageSSE(_ frames: [(String, String)]) -> Data {
    Data(frames.flatMap { event, payload in
        Array("\(event.isEmpty ? "" : "event: \(event)\n")data: \(payload)\n\n".utf8)
    })
}

private func usageEvents(_ data: Data) -> [HTTPTransportEvent] {
    [.response(HTTPTransportResponse(statusCode: 200)), .bytes(data), .end]
}

private func collectUsage(_ transport: UsageTransport, route: ResolvedModelRouteSnapshot) async -> ([CanonicalStreamEvent], MiraError?) {
    var events: [CanonicalStreamEvent] = []
    do {
        for try await event in HTTPModelProvider(credentials: UsageCredentials(), transport: transport).stream(request: usageRequest(), route: route) {
            events.append(event)
        }
        return (events, nil)
    } catch {
        return (events, MiraError.safe(error))
    }
}

@Test("OpenAI cumulative usage keeps cache and reasoning details without summing snapshots")
func openAICumulativeUsageIsNormalized() async throws {
    let data = usageSSE([
        ("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#),
        ("", #"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":10,"prompt_tokens_details":{"cached_tokens":20},"completion_tokens_details":{"reasoning_tokens":4}}}"#),
        ("", #"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":15,"prompt_tokens_details":{"cached_tokens":60},"completion_tokens_details":{"reasoning_tokens":7}}}"#),
        ("", "[DONE]")
    ])
    let (events, error) = await collectUsage(UsageTransport(events: usageEvents(data)), route: usageRoute())
    #expect(error == nil)
    #expect(events == [
        .usage(.init(inputTokens: 100, outputTokens: 10, cacheReadTokens: 20, reasoningTokens: 4)),
        .usage(.init(inputTokens: 100, outputTokens: 15, cacheReadTokens: 60, reasoningTokens: 7)),
        .finished(.stop)
    ])
}

@Test("DeepSeek and Kimi cache fields map to cache reads and leave missing writes unknown")
func compatibleCacheUsageIsNormalized() async throws {
    let deepSeek = usageSSE([
        ("", #"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_cache_hit_tokens":40}}"#),
        ("", "[DONE]")
    ])
    let deepSeekResult = await collectUsage(UsageTransport(events: usageEvents(deepSeek)), route: usageRoute())
    #expect(deepSeekResult.0 == [.usage(.init(inputTokens: 100, outputTokens: 5, cacheReadTokens: 40)), .finished(.stop)])
    #expect(deepSeekResult.1 == nil)

    let kimi = usageSSE([
        ("", #"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":5,"cached_tokens":40}}"#),
        ("", "[DONE]")
    ])
    let kimiResult = await collectUsage(UsageTransport(events: usageEvents(kimi)), route: usageRoute())
    #expect(kimiResult.0 == [.usage(.init(inputTokens: 100, outputTokens: 5, cacheReadTokens: 40)), .finished(.stop)])
    #expect(kimiResult.1 == nil)
}

@Test("Conflicting compatible cache fields are rejected")
func conflictingCacheFieldsFailSafely() async throws {
    let data = usageSSE([
        ("", #"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":5,"cached_tokens":40,"prompt_tokens_details":{"cached_tokens":20}}}"#),
        ("", "[DONE]")
    ])
    let result = await collectUsage(UsageTransport(events: usageEvents(data)), route: usageRoute())
    #expect(result.0.isEmpty)
    #expect(result.1?.code == .malformedStream)
}

@Test("Anthropic partial usage preserves message-start fields while replacing cumulative values")
func anthropicUsageMergesPartials() async throws {
    let data = usageSSE([
        ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":100,"cache_read_input_tokens":20,"cache_creation_input_tokens":10,"output_tokens":0}}}"#),
        ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"hello"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}"#),
        ("message_stop", #"{"type":"message_stop"}"#)
    ])
    let result = await collectUsage(UsageTransport(events: usageEvents(data)), route: usageRoute(.anthropic))
    #expect(result.1 == nil)
    #expect(result.0 == [
        .usage(.init(inputTokens: 100, outputTokens: 0, cacheReadTokens: 20, cacheWriteTokens: 10,
                     inputTokenBasis: .excludesCache)),
        .textDelta("hello"),
        .usage(.init(inputTokens: 100, outputTokens: 7, cacheReadTokens: 20, cacheWriteTokens: 10,
                     inputTokenBasis: .excludesCache)),
        .finished(.stop)
    ])
}

@Test("Unknown usage fields are ignored and absent counters remain nil")
func unknownUsageFieldsDoNotInventCounters() async throws {
    let data = usageSSE([
        ("", #"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"provider_future":{"cache_write_tokens":99}}}"#),
        ("", "[DONE]")
    ])
    let result = await collectUsage(UsageTransport(events: usageEvents(data)), route: usageRoute())
    #expect(result.1 == nil)
    #expect(result.0 == [.usage(.init(inputTokens: 3, outputTokens: 2)), .finished(.stop)])
}

@Test("Malformed usage counters reject the stream")
func malformedUsageCountersFailSafely() async throws {
    let payloads = [
        #"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":-1,"completion_tokens":2}}"#,
        #"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":2,"prompt_tokens_details":{"cached_tokens":101}}}"#,
        #"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":2,"completion_tokens_details":{"reasoning_tokens":3}}}"#
    ]
    for payload in payloads {
        let result = await collectUsage(UsageTransport(events: usageEvents(usageSSE([("", payload), ("", "[DONE]")]))), route: usageRoute())
        #expect(result.0.isEmpty)
        #expect(result.1?.code == .malformedStream)
    }
}

@Test("Usage emitted before an interrupted stream is retained")
func interruptedStreamRetainsUsage() async throws {
    let data = usageSSE([
        ("", #"{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":4}}"#),
        ("", #"{"choices":[{"delta":{"content":"partial"},"finish_reason":null}]}"#)
    ])
    let result = await collectUsage(UsageTransport(events: [
        .response(HTTPTransportResponse(statusCode: 200)), .bytes(data), .end
    ]), route: usageRoute())
    #expect(result.0 == [.usage(.init(inputTokens: 12, outputTokens: 4)), .textDelta("partial")])
    #expect(result.1?.code == .interrupted)
}
