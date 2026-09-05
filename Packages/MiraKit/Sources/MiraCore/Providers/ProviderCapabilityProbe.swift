import Foundation

public enum CapabilityProbeKind: String, Codable, Sendable { case text, tools }

public struct ProbeObservation: Codable, Sendable, Equatable {
    public var checkedAt: Date
    public var type: CapabilityProbeKind
    public var state: CapabilityState
    public var error: MiraError?

    public init(checkedAt: Date = Date(), type: CapabilityProbeKind, state: CapabilityState, error: MiraError? = nil) {
        self.checkedAt = checkedAt; self.type = type; self.state = state; self.error = error
    }
}

/// Performs an explicit, synthetic provider capability check. It never executes a ToolPort.
public struct ProviderCapabilityProbe: Sendable {
    private let provider: any ModelProviderPort
    private let timeout: Duration
    private let environment: RuntimeEnvironment

    public init(provider: any ModelProviderPort, timeout: Duration = .seconds(20), environment: RuntimeEnvironment = .init()) {
        self.provider = provider; self.timeout = timeout; self.environment = environment
    }

    public func run(route: ModelRoute, kind: CapabilityProbeKind) async -> ProbeObservation {
        let checkedAt = environment.now()
        do {
            try Task.checkCancellation()
            guard let window = route.contextWindow, window > 128 else {
                throw MiraError(.configuration, "请先配置大于 128 Token 的上下文窗口，再检测能力。")
            }
            var frozen = route
            frozen.maxOutputTokens = min(128, route.maxOutputTokens)
            frozen.textCapability = .declared
            frozen.toolCapability = .declared
            try frozen.validateForSending()
            let request = makeRequest(route: frozen, kind: kind)
            let requestSize = try JSONEncoder().encode(request).count
            guard requestSize + frozen.maxOutputTokens + max(512, window / 10) <= window else {
                throw MiraError(.contextLimit, "配置的模型窗口无法容纳合成检测请求，请确认窗口大小。")
            }
            let events = try await collect(request: request, route: frozen)
            try Task.checkCancellation()
            try validate(events: events, kind: kind)
            return .init(checkedAt: checkedAt, type: kind, state: .verified)
        } catch is CancellationError {
            return .init(checkedAt: checkedAt, type: kind, state: .unknown, error: MiraError(.cancelled, "能力检测已取消。"))
        } catch {
            let safe = MiraError.safe(error)
            if safe.code == .cancelled { return .init(checkedAt: checkedAt, type: kind, state: .unknown, error: safe) }
            return .init(checkedAt: checkedAt, type: kind, state: .failed, error: safe)
        }
    }

    private func makeRequest(route: ModelRoute, kind: CapabilityProbeKind) -> CanonicalModelRequest {
        let tool: ToolDefinition? = kind == .tools ? .init(
            name: "probe.echo", description: "Synthetic capability probe. Do not execute.",
            inputSchema: .object(["type": .string("object"), "properties": .object(["value": .object(["type": .string("string"), "enum": .array([.string("MIRA_PROBE")]), "maxLength": .number(10)])]), "required": .array([.string("value")]), "additionalProperties": .bool(false)])
        ) : nil
        return .init(
            executionID: .init(environment.uuid()),
            system: "Capability probe. Return only the requested synthetic result.",
            messages: [.init(role: .user, text: kind == .text ? "MIRA_SYNTHETIC_TEXT_PROBE: return a short non-empty text response and finish with stop." : "MIRA_SYNTHETIC_TOOL_PROBE: call probe.echo exactly once with JSON arguments {\"value\":\"MIRA_PROBE\"}, then finish with toolCalls. Do not add other arguments or text.")],
            requestID: environment.uuid(), tools: tool.map { [$0] }
        )
    }

    private func collect(request: CanonicalModelRequest, route: ModelRoute) async throws -> [CanonicalStreamEvent] {
        let probeClock = environment.clock
        let probeTimeout = timeout
        return try await withThrowingTaskGroup(of: [CanonicalStreamEvent].self) { group in
            defer { group.cancelAll() }
            group.addTask {
                var events: [CanonicalStreamEvent] = []
                var sawFinished = false
                var textBytes = 0
                for try await event in self.provider.stream(request: request, route: route) {
                    try Task.checkCancellation()
                    if sawFinished { throw MiraError(.malformedStream, "能力检测结束后仍返回事件。") }
                    if events.count >= 512 { throw MiraError(.outputLimit, "能力检测事件超出上限。") }
                    if case .textDelta(let value) = event {
                        textBytes += value.utf8.count
                        guard textBytes <= 16_384 else { throw MiraError(.outputLimit, "能力检测文本超出上限。") }
                    }
                    if case .toolCalls(let calls) = event {
                        guard calls.count == 1, calls[0].id.utf8.count <= 256, calls[0].arguments.utf8.count <= 1_024 else {
                            throw MiraError(.malformedStream, "能力检测工具调用超出上限。")
                        }
                    }
                    events.append(event)
                    if case .finished = event { sawFinished = true }
                }
                try Task.checkCancellation()
                guard sawFinished else { throw MiraError(.malformedStream, "能力检测响应缺少结束事件。") }
                return events
            }
            group.addTask {
                try await probeClock.sleep(for: probeTimeout)
                throw MiraError(.timeout, "能力检测超时。")
            }
            guard let result = try await group.next() else { throw MiraError(.timeout, "能力检测未返回结果。") }
            return result
        }
    }

    private func validate(events: [CanonicalStreamEvent], kind: CapabilityProbeKind) throws {
        guard let terminal = events.last, case .finished(let reason) = terminal else { throw MiraError(.malformedStream, "能力检测响应缺少结束事件。") }
        switch kind {
        case .text:
            let text = events.compactMap { if case .textDelta(let value) = $0 { value } else { nil } }.joined()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason == .stop,
                  !events.contains(where: { if case .toolCalls = $0 { true } else { false } }) else { throw MiraError(.providerRejected, "文本能力检测结果不符合要求。") }
        case .tools:
            guard reason == .toolCalls,
                  events.count(where: { if case .toolCalls = $0 { true } else { false } }) == 1,
                  let call = events.compactMap({ if case .toolCalls(let calls) = $0 { calls } else { nil } }).first,
                  call.count == 1, !call[0].id.isEmpty, call[0].name == "probe.echo",
                  (try? JSONDecoder().decode([String: String].self, from: Data(call[0].arguments.utf8))) == ["value": "MIRA_PROBE"] else { throw MiraError(.providerRejected, "工具能力检测未返回指定的 probe.echo 调用。") }
        }
    }
}
