import Foundation
import MiraCore

/// One explicitly selected wire kind. Preparation is pure; only stream reads a credential.
/// Shared transport orchestration for the concrete protocol registrations
/// below. It stays module-internal so callers cannot select an omnibus adapter.
struct HTTPModelAdapter: AgentModelAdapter {
    private let kind: HTTPInvocationKind
    public var identity: AgentAdapterIdentity { kind.identity }
    private let credentials: any CredentialReader
    private let transport: any HTTPStreamingTransport
    private let now: @Sendable () -> Date

    fileprivate init(kind: HTTPInvocationKind, credentials: any CredentialReader,
                transport: any HTTPStreamingTransport = URLSessionStreamingTransport(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.kind = kind; self.credentials = credentials; self.transport = transport; self.now = now
    }

    init(dialect: HTTPDialectProfileID, protocolID: HTTPProtocolID = .chatCompletions,
         credentials: any CredentialReader,
         transport: any HTTPStreamingTransport = URLSessionStreamingTransport(),
         now: @escaping @Sendable () -> Date = Date.init) throws {
        let kind = try HTTPInvocationKind(protocolID: protocolID, dialectProfileID: dialect)
        self.init(kind: kind, credentials: credentials, transport: transport, now: now)
    }

    public func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        do {
            let policy = try HTTPModelPolicy(route: route, kind: kind)
            try validateProviderApplicationContext(input)
            try input.validate(for: route)
            try validateWireNames(input)
            guard route.credential != nil else { throw MiraError(.credentialMissing, "The provider credential is unavailable.") }
            let bytes: Data
            if kind.isAnthropic { bytes = try SessionCodec.encode(AnthropicRequest(request: input, route: policy)) }
            else { bytes = try SessionCodec.encode(OpenAIRequest(request: input, route: policy)) }
            let payload = try SessionCodec.decode(JSONValue.self, from: bytes)
            // A conservative byte estimate includes framing allowance. It is not a vendor tokenizer.
            let estimated = bytes.count + 32 * (input.messages.count + input.tools.count) + 256
            let prepared = AgentPreparedModelRequest(adapter: identity, input: input, wirePayload: payload, estimatedInputTokens: estimated)
            try prepared.validate(for: route)
            return prepared
        } catch is EncodingError {
            throw MiraError(.configuration, "The model request cannot be encoded.")
        } catch is DecodingError {
            throw MiraError(.configuration, "The model request configuration is invalid.")
        } catch { throw safeProviderError(error) }
    }

    public func outputTokenLimit(for requested: Int, route: AgentModelRoute) throws -> Int {
        guard requested > 0 else {
            throw MiraError(.configuration, "The requested model output limit must be positive.")
        }
        let bounded = min(requested, route.maximumOutputTokens)
        guard kind.isAnthropic else { return bounded }
        let policy = try HTTPModelPolicy(route: route, kind: kind)
        guard let thinkingBudget = ProviderThinkingRules.anthropicThinking(for: policy)?.budgetTokens else {
            return bounded
        }
        let legal = thinkingBudget == Int.max ? Int.max : thinkingBudget + 1
        guard legal <= route.maximumOutputTokens else {
            throw MiraError(.configuration, "The frozen route cannot fit the Anthropic thinking budget.")
        }
        return max(bounded, legal)
    }

    public func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        let (events, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        let task = Task {
            do {
                try Task.checkCancellation()
                guard try prepare(request.input, route: route) == request else {
                    throw MiraError(.conflict, "The provider request differs from its frozen preparation.")
                }
                let policy = try HTTPModelPolicy(route: route, kind: kind)
                let endpoint = try policy.configuration.validatedEndpoint(kind: kind)
                guard let credential = route.credential else { throw MiraError(.credentialMissing, "The provider credential is unavailable.") }
                let secret: String
                do { secret = try credentials.read(reference: credential.reference, version: credential.version) }
                catch { throw MiraError(.credentialMissing, "The provider credential is unavailable.") }
                guard !secret.isEmpty else { throw MiraError(.credentialMissing, "The provider credential is unavailable.") }
                try Task.checkCancellation()
                var urlRequest = URLRequest(url: endpoint)
                urlRequest.httpMethod = "POST"
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                urlRequest.setValue(request.input.stepID.uuidString, forHTTPHeaderField: "X-Mira-Request-ID")
                if kind.isAnthropic {
                    urlRequest.setValue(secret, forHTTPHeaderField: "x-api-key")
                    urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                } else { urlRequest.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
                urlRequest.httpBody = try SessionCodec.encode(request.wirePayload)
                let operation = transport.stream(request: urlRequest)
                do {
                    try await run(input: operation.events, request: request.input, continuation: continuation)
                    await operation.close()
                    continuation.finish()
                } catch {
                    await operation.close()
                    throw error
                }
            } catch {
                let failure: AgentModelFailure
                if Task.isCancelled || error is CancellationError {
                    failure = AgentModelFailure(error: MiraError(.cancelled, "Generation was stopped."))
                } else if let typed = error as? AgentModelFailure { failure = typed }
                else if let streamError = error as? HTTPStreamError {
                    failure = classifyStreamFailure(streamError, now: now)
                } else {
                    failure = AgentModelFailure(error: safeProviderError(error))
                }
                continuation.finish(throwing: failure)
            }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return AgentModelOperation(events: events) { task.cancel(); await task.value }
    }

    public func replay(_ messages: [AgentModelMessage], from source: AgentModelRoute,
                       to target: AgentModelRoute, boundary: AgentReplayBoundary) throws -> AgentReplayDecision {
        do {
            _ = try HTTPModelPolicy(route: target, kind: kind)
            if boundary == .sameExecution {
                guard source == target else { throw MiraError(.conflict, "The current provider continuation cannot change routes.") }
                for message in messages { try validateContinuation(message.continuation, for: identity, replay: true) }
                try validateReplay(messages)
                return .include(messages)
            }
            // New Anthropic turns rebuild retrieved context, so they cannot retain an old signed prefix.
            // Foreign adapters own their configuration format; never decode it as an HTTP configuration.
            guard source.adapter == target.adapter, source.connectionID == target.connectionID,
                  source.modelID == target.modelID,
                  source.modelDescriptorID == target.modelDescriptorID,
                  source.invocationID == target.invocationID,
                  source.endpointID == target.endpointID,
                  source.configuration["protocolID"] == target.configuration["protocolID"],
                  source.configuration["dialectProfileID"] == target.configuration["dialectProfileID"],
                  !kind.isAnthropic else {
                return .include(Self.withoutThinking(messages))
            }
            let sourcePolicy = try HTTPModelPolicy(route: source, kind: kind)
            let targetPolicy = try HTTPModelPolicy(route: target, kind: kind)
            guard try sourcePolicy.configuration.validatedEndpoint(kind: kind) ==
                    targetPolicy.configuration.validatedEndpoint(kind: kind) else {
                return .include(Self.withoutThinking(messages))
            }
            for message in messages { try validateContinuation(message.continuation, for: identity, replay: true) }
            try validateReplay(messages)
            return .include(messages)
        } catch { throw safeProviderError(error) }
    }

    private func validateReplay(_ messages: [AgentModelMessage]) throws {
        if kind.isAnthropic { _ = try AnthropicMessageBuilder.build(messages, definitions: []) }
        else {
            for message in messages where message.role == .assistant {
                _ = try OpenAIMessage(role: "assistant", content: message.text, toolCalls: nil, toolCallID: nil,
                    reasoning: try message.continuation.map { try HTTPReasoning($0) }, mode: kind)
            }
        }
    }

    private static func withoutThinking(_ messages: [AgentModelMessage]) -> [AgentModelMessage] {
        messages.map {
            let blocks = $0.blocks.filter { if case .thinking = $0.content { return false }; return true }
            return .init(role: $0.role, blocks: blocks, continuation: nil)
        }
    }

    private func run(input: AsyncThrowingStream<HTTPTransportEvent, any Error>, request: AgentModelInput,
                     continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation) async throws {
        var responseReceived = false, protocolFinished = false
        var responseStatus: Int?
        var responseHeaders: [String: String] = [:]
        var parser = HTTPChatSSEParser()
        var openAI = OpenAIStreamState(toolDefinitions: request.tools, toolsEnabled: request.allowsToolCalls && !request.tools.isEmpty, kind: kind)
        var anthropic = AnthropicStreamState(toolDefinitions: request.tools, toolsEnabled: request.allowsToolCalls && !request.tools.isEmpty, kind: kind)
        defer {
            if !protocolFinished {
                if kind.isAnthropic { try? anthropic.flushReasoning(continuation: continuation, includeContinuation: true) }
                else { try? openAI.flushReasoning(continuation: continuation, includeContinuation: true) }
            }
        }
        func process(_ frame: HTTPChatSSEFrame) throws {
            guard !protocolFinished else { throw ProviderProtocolError.malformed }
            if kind.isAnthropic { try anthropic.process(frame, continuation: continuation); protocolFinished = anthropic.isFinished }
            else { try openAI.process(frame, continuation: continuation); protocolFinished = openAI.isFinished }
        }
        do {
            for try await event in input {
                try Task.checkCancellation()
                switch event {
                case .response(let response):
                    guard !responseReceived else { throw ProviderProtocolError.malformed }
                    responseReceived = true
                    responseStatus = response.statusCode
                    responseHeaders = response.headers
                    guard (200..<300).contains(response.statusCode) else { throw HTTPStatusError(statusCode: response.statusCode) }
                case .bytes(let data):
                    guard responseReceived else { throw ProviderProtocolError.malformed }
                    try parser.feed(data, emit: process)
                    if protocolFinished { return }
                case .end:
                    try parser.finish(emit: process)
                    if protocolFinished { return }
                    throw ProviderProtocolError.prematureEOF
                }
            }
            throw ProviderProtocolError.prematureEOF
        } catch {
            throw HTTPStreamError(error: error, statusCode: responseStatus, headers: responseHeaders)
        }
    }
}

/// Application context is provider-owned input data with one deliberately
/// narrow placement rule. Core validates the general message shape, while the
/// wire adapter also rejects context blocks that could be interpreted as
/// provider instructions or as a second current turn.
func validateProviderApplicationContext(_ input: AgentModelInput) throws {
    let contexts = input.messages.enumerated().filter { $0.element.role == .context }
    guard contexts.isEmpty || contexts.count == 1 else {
        throw MiraError(.configuration, "Application context must contain at most one message.")
    }
    guard let context = contexts.first else { return }
    let index = context.offset
    guard index + 1 < input.messages.count,
          input.messages[index + 1].role == .user else {
        throw MiraError(.configuration, "Application context must immediately precede the current user message.")
    }
    guard !context.element.blocks.isEmpty,
          context.element.blocks.allSatisfy({ block in
        if case .text = block.content { return true }
        return false
    }) else {
        throw MiraError(.configuration, "Application context may contain text blocks only.")
    }
}

/// Concrete Chat Completions registration. Dialect differences remain frozen
/// configuration on this one protocol implementation.
public struct ChatCompletionsAdapter: AgentModelAdapter {
    private let fixedDialect: HTTPDialectProfileID?
    private let credentials: any CredentialReader
    private let transport: any HTTPStreamingTransport
    private let now: @Sendable () -> Date
    public var identity: AgentAdapterIdentity { HTTPAdapterIdentity.chatCompletions }
    /// Test and explicitly pinned construction. Production callers should use
    /// the route-driven initializer so the frozen invocation selects the
    /// dialect inside MiraProviders rather than in the host.
    public init(dialect: HTTPDialectProfileID = .generic, credentials: any CredentialReader,
                transport: any HTTPStreamingTransport = URLSessionStreamingTransport(),
                now: @escaping @Sendable () -> Date = Date.init) throws {
        _ = try HTTPInvocationKind(protocolID: .chatCompletions, dialectProfileID: dialect)
        self.fixedDialect = dialect; self.credentials = credentials; self.transport = transport; self.now = now
    }
    /// Route-driven construction for the registered Chat Completions adapter.
    /// The transport is retained and reused for every invocation.
    public init(credentials: any CredentialReader,
                transport: any HTTPStreamingTransport = URLSessionStreamingTransport(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.fixedDialect = nil; self.credentials = credentials; self.transport = transport; self.now = now
    }
    private func implementation(for route: AgentModelRoute) throws -> HTTPModelAdapter {
        let configuration = try SessionCodec.decode(HTTPModelConfiguration.self,
            from: SessionCodec.encode(route.configuration))
        let dialect = fixedDialect ?? configuration.dialectProfileID
        return try HTTPModelAdapter(dialect: dialect, protocolID: .chatCompletions,
                                    credentials: credentials, transport: transport, now: now)
    }
    public func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        try implementation(for: route).prepare(input, route: route)
    }
    public func outputTokenLimit(for requested: Int, route: AgentModelRoute) throws -> Int {
        try implementation(for: route).outputTokenLimit(for: requested, route: route)
    }
    public func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        do { return try implementation(for: route).stream(request, route: route) }
        catch { return failedOperation(safeProviderError(error)) }
    }
    public func replay(_ messages: [AgentModelMessage], from source: AgentModelRoute, to target: AgentModelRoute, boundary: AgentReplayBoundary) throws -> AgentReplayDecision {
        try implementation(for: target).replay(messages, from: source, to: target, boundary: boundary)
    }
}

private func failedOperation(_ error: MiraError) -> AgentModelOperation {
    let (events, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
    continuation.finish(throwing: AgentModelFailure(error: error))
    return AgentModelOperation(events: events, cancelAndDrain: {})
}

/// Concrete Anthropic Messages registration. Manual and adaptive thinking are
/// parameter controls selected by the dialect profile.
public struct AnthropicMessagesAdapter: AgentModelAdapter {
    private let implementation: HTTPModelAdapter
    public var identity: AgentAdapterIdentity { HTTPAdapterIdentity.anthropicMessages }
    public init(dialect: HTTPDialectProfileID = .anthropic, credentials: any CredentialReader,
                transport: any HTTPStreamingTransport = URLSessionStreamingTransport(),
                now: @escaping @Sendable () -> Date = Date.init) throws {
        guard dialect == .anthropic else {
            throw MiraError(.configuration, "The selected Anthropic Messages controls are unavailable.")
        }
        implementation = HTTPModelAdapter(
            kind: try HTTPInvocationKind(protocolID: .anthropicMessages, dialectProfileID: .anthropic),
            credentials: credentials, transport: transport, now: now)
    }
    public func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest { try implementation.prepare(input, route: route) }
    public func outputTokenLimit(for requested: Int, route: AgentModelRoute) throws -> Int { try implementation.outputTokenLimit(for: requested, route: route) }
    public func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation { implementation.stream(request, route: route) }
    public func replay(_ messages: [AgentModelMessage], from source: AgentModelRoute, to target: AgentModelRoute, boundary: AgentReplayBoundary) throws -> AgentReplayDecision { try implementation.replay(messages, from: source, to: target, boundary: boundary) }
}

private enum HTTPReasoningFormat: String, Codable, Sendable {
    case openAIContent = "openai.content", anthropicBlocks = "anthropic.blocks", openRouterDetails = "openrouter.details"
}

/// Adapter-private projection of the exact wire continuation array.
private struct HTTPReasoning: Codable, Sendable {
    let format: HTTPReasoningFormat
    let text: String
    let blocks: [JSONValue]
    let isComplete: Bool
    init(format: HTTPReasoningFormat, text: String, blocks: [JSONValue], isComplete: Bool) {
        self.format = format; self.text = text; self.blocks = blocks; self.isComplete = isComplete
    }
    init(_ continuationValue: AgentModelContinuation) throws {
        guard let format = HTTPReasoningFormat(rawValue: continuationValue.format),
              case .array(let blocks) = continuationValue.payload else { throw ProviderProtocolError.malformed }
        self.init(format: format, text: "", blocks: blocks, isComplete: continuationValue.isComplete)
        try validate()
    }
    init(_ message: AgentModelMessage) throws {
        guard let continuation = message.continuation,
              let format = HTTPReasoningFormat(rawValue: continuation.format),
              case .array(let blocks) = continuation.payload,
              continuation.isComplete else { throw ProviderProtocolError.malformed }
        self.init(format: format, text: message.thinkingText, blocks: blocks, isComplete: continuation.isComplete)
        try validate()
    }
    func validate() throws {
        guard text.utf8.count <= 2_097_152,
              blocks.count <= (format == .openRouterDetails ? 65_536 : 256),
              try SessionCodec.encode(self).count <= 4_194_304 else { throw ProviderProtocolError.resourceLimit }
    }
    func continuation(for identity: AgentAdapterIdentity) -> AgentModelContinuation {
        .init(adapter: identity, format: format.rawValue, payload: .array(blocks), isComplete: isComplete)
    }
}

private func validateContinuation(_ continuation: AgentModelContinuation?, for identity: AgentAdapterIdentity, replay: Bool) throws {
    guard let continuation else { return }
    try continuation.validate()
    guard continuation.adapter == identity, !replay || continuation.isComplete else {
        throw ProviderProtocolError.malformed
    }
}

private func validateToolArguments(_ raw: String) throws {
    guard raw.utf8.count <= ProviderLimits.maxToolJSONBytes,
          let data = raw.data(using: .utf8),
          let value = try? JSONDecoder().decode(JSONValue.self, from: data),
          case .object = value else {
        throw ProviderProtocolError.malformed
    }
}

private func validateWireNames(_ request: AgentModelInput) throws {
    var wireNames = Set<String>()
    for definition in request.tools {
        guard definition.name.utf8.count <= ProviderLimits.maxToolNameBytes,
              wireNames.insert(definition.wireName).inserted else { throw ProviderProtocolError.malformed }
    }
}

private func yieldCanonical(
    _ event: AgentModelStreamEvent,
    to continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation
) throws {
    if case .dropped = continuation.yield(event) {
        throw ProviderProtocolError.resourceLimit
    }
}

/// Content identity follows semantic blocks, never SSE frames or network packets.
private struct HTTPContentBlockEmitter {
    enum Kind: String { case text, thinking }
    private var active: (id: String, kind: Kind)?
    private var nextID = 0
    private var pending = ""
    private var pendingBytes = 0
    private var lastEmission: ContinuousClock.Instant?

    mutating func begin(_ kind: Kind, to continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation) throws {
        try finish(to: continuation)
        let id = "\(kind.rawValue)-\(nextID)"
        nextID += 1
        active = (id, kind)
        lastEmission = nil
        let block = AgentModelBlock(id: id, content: kind == .text ? .text("") : .thinking(""))
        try yieldCanonical(.blockStarted(block), to: continuation)
    }

    mutating func append(_ text: String, kind: Kind,
                         to continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation) throws {
        guard !text.isEmpty else { return }
        if active?.kind != kind { try begin(kind, to: continuation) }
        guard active != nil else { throw ProviderProtocolError.malformed }
        var piece = ""
        var pieceBytes = 0
        for scalar in text.unicodeScalars {
            let size = scalar.utf8.count
            if pieceBytes + size > 65_536 {
                try enqueue(piece, bytes: pieceBytes, to: continuation)
                piece.removeAll(keepingCapacity: true)
                pieceBytes = 0
            }
            piece.unicodeScalars.append(scalar)
            pieceBytes += size
        }
        if !piece.isEmpty { try enqueue(piece, bytes: pieceBytes, to: continuation) }
    }

    mutating func finish(to continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation) throws {
        guard let active else { return }
        try flush(to: continuation)
        try yieldCanonical(.blockFinished(id: active.id), to: continuation)
        self.active = nil
    }

    /// Coalesce small deltas without inventing new blocks or overflowing the
    /// event queue on a packet containing many tokens. Pending text is bounded
    /// and flushed on a semantic boundary, terminal event, or transport failure.
    private mutating func enqueue(_ text: String, bytes: Int,
                                  to continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation) throws {
        if pendingBytes + bytes > 65_536 { try flush(to: continuation) }
        pending.append(text)
        pendingBytes += bytes
        if lastEmission == nil || pendingBytes >= 4_096 ||
            lastEmission.map({ ContinuousClock.now - $0 >= .milliseconds(100) }) == true {
            try flush(to: continuation)
        }
    }

    private mutating func flush(to continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation) throws {
        guard let active, !pending.isEmpty else { return }
        try yieldCanonical(.blockDelta(id: active.id, text: pending), to: continuation)
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0
        lastEmission = .now
    }
}

private func yieldToolCalls(
    _ calls: [CanonicalToolCall],
    to continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation
) throws {
    for call in calls {
        let id = "tool-" + call.id
        try yieldCanonical(.blockStarted(.init(id: id, content: .toolCall(call))), to: continuation)
        try yieldCanonical(.blockFinished(id: id), to: continuation)
    }
}

private func validatedProviderUsage(_ usage: TokenUsage) throws -> TokenUsage {
    do {
        try usage.validate()
        return usage
    } catch {
        throw ProviderProtocolError.malformed
    }
}

private struct OpenAIStreamState {
    private var finish: StreamFinishReason?
    private var sawDone = false
    private var usage: TokenUsage?
    private var calls: [Int: OpenAIToolAccumulator] = [:]
    private var reasoningText = ""
    private var reasoningDetails: [JSONValue] = []
    private var sawReasoningDetails = false
    private var reasoningDetailsBytes = 0
    private var hasReasoning = false
    private var contentEmitter = HTTPContentBlockEmitter()
    private let kind: HTTPInvocationKind
    private let decoder = JSONDecoder()
    private let names: ToolNameMap
    private let toolsEnabled: Bool

    init(toolDefinitions: [ToolDefinition], toolsEnabled: Bool, kind: HTTPInvocationKind) {
        self.names = ToolNameMap(definitions: toolDefinitions)
        self.toolsEnabled = toolsEnabled
        self.kind = kind
    }

    var isFinished: Bool { sawDone }

    mutating func process(_ frame: HTTPChatSSEFrame, continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation) throws {
        if frame.data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            guard !sawDone, finish != nil else { throw ProviderProtocolError.malformed }
            if finish == .toolCalls {
                let calls = try finalizeCalls()
                try finishReasoning(continuation: continuation)
                try yieldToolCalls(calls, to: continuation)
            } else if !calls.isEmpty {
                // A provider cannot turn a tool proposal into a normal stop.
                // A length stop is allowed, but its partial JSON is never sent
                // as a runnable call.
                guard finish == .outputLimit else { throw ProviderProtocolError.malformed }
            }
            if finish != .toolCalls { try finishReasoning(continuation: continuation) }
            sawDone = true
            try yieldCanonical(.finished(finish!), to: continuation)
            return
        }
        guard !sawDone else { throw ProviderProtocolError.malformed }
        // Chat Completions has no event field in its normal SSE stream. An
        // explicitly unknown event remains forward-compatible.
        if !frame.event.isEmpty && frame.event != "message" { return }
        let chunk: OpenAIChunk
        do { chunk = try decoder.decode(OpenAIChunk.self, from: Data(frame.data.utf8)) }
        catch { throw ProviderProtocolError.malformed }
        if chunk.error != nil { throw ProviderProtocolError.provider }

        if let reported = chunk.usage {
            let next = try reported.tokenUsage()
            // Provider usage reports are cumulative snapshots. Never add them.
            if usage != next {
                usage = next
                try yieldCanonical(.usage(next), to: continuation)
            }
        }
        guard (chunk.choices?.count ?? 0) <= 1 else { throw ProviderProtocolError.malformed }
        if finish != nil, !(chunk.choices ?? []).isEmpty {
            throw ProviderProtocolError.malformed
        }
        for choice in chunk.choices ?? [] {
            if let delta = choice.delta {
                var detailHasVisibleText = false
                if let details = delta.reasoningDetails {
                    guard case .array(let fragments) = details else { throw ProviderProtocolError.malformed }
                    guard fragments.count <= ProviderLimits.maxReasoningDetails else { throw ProviderProtocolError.resourceLimit }
                    for fragment in fragments {
                        guard case .object(let object) = fragment else { throw ProviderProtocolError.malformed }
                        if let visible = object["text"] ?? object["summary"] {
                            guard let text = visible.stringValue else { throw ProviderProtocolError.malformed }
                            try appendReasoningText(text, continuation: continuation)
                            detailHasVisibleText = detailHasVisibleText || !text.isEmpty
                        }
                        let fragmentBytes = try JSONEncoder().encode(fragment).count
                        guard reasoningDetailsBytes + fragmentBytes <= ProviderLimits.maxReasoningPayloadBytes else { throw ProviderProtocolError.resourceLimit }
                        reasoningDetailsBytes += fragmentBytes
                    }
                    reasoningDetails.append(contentsOf: fragments)
                    guard reasoningDetails.count <= ProviderLimits.maxReasoningDetails else { throw ProviderProtocolError.resourceLimit }
                    if !fragments.isEmpty {
                        sawReasoningDetails = true
                        hasReasoning = true
                    }
                }
                if !detailHasVisibleText {
                    let alias = delta.reasoningContent ?? delta.reasoning ?? ""
                    if !alias.isEmpty { try appendReasoningText(alias, continuation: continuation) }
                }
                if finish != nil && (delta.content != nil || delta.toolCalls != nil || delta.functionCall != nil || choice.finishReason != nil) {
                    throw ProviderProtocolError.malformed
                }
                if let text = delta.content, !text.isEmpty {
                    try contentEmitter.append(text, kind: .text, to: continuation)
                }
                if let toolDeltas = delta.toolCalls {
                    for toolDelta in toolDeltas { try append(toolDelta) }
                }
                if delta.functionCall != nil { throw ProviderProtocolError.unsupportedTools }
            }
            if let reason = choice.finishReason {
                guard finish == nil else { throw ProviderProtocolError.malformed }
                switch reason {
                case "stop": finish = .stop
                case "length": finish = .outputLimit
                case "tool_calls":
                    guard !calls.isEmpty else { throw ProviderProtocolError.malformed }
                    finish = .toolCalls
                default: throw ProviderProtocolError.provider
                }
            }
        }
    }

    private mutating func appendReasoningText(_ fragment: String, continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation) throws {
        guard reasoningText.utf8.count + fragment.utf8.count <= ProviderLimits.maxReasoningTextBytes else { throw ProviderProtocolError.resourceLimit }
        reasoningText.append(fragment)
        hasReasoning = true
        try contentEmitter.append(fragment, kind: .thinking, to: continuation)
    }

    private var reasoningFormat: HTTPReasoningFormat {
        sawReasoningDetails || kind.dialect == .openRouter ? .openRouterDetails : .openAIContent
    }

    mutating func flushReasoning(continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation,
                                 includeContinuation: Bool = false) throws {
        try contentEmitter.finish(to: continuation)
        guard hasReasoning, includeContinuation else { return }
        try emitContinuation(complete: false, to: continuation)
    }

    private mutating func finishReasoning(continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation) throws {
        try contentEmitter.finish(to: continuation)
        if hasReasoning { try emitContinuation(complete: true, to: continuation) }
    }

    private func emitContinuation(complete: Bool, to continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation) throws {
        let content = HTTPReasoning(format: reasoningFormat, text: reasoningText, blocks: reasoningDetails, isComplete: complete)
        do { try content.validate() } catch { throw ProviderProtocolError.resourceLimit }
        try yieldCanonical(.continuation(content.continuation(for: kind.identity)), to: continuation)
    }

    private mutating func append(_ delta: OpenAIResponseToolCall) throws {
        guard toolsEnabled else { throw ProviderProtocolError.unsupportedTools }
        guard let index = delta.index, index >= 0 else { throw ProviderProtocolError.malformed }
        if calls[index] == nil {
            guard calls.count < ProviderLimits.maxToolCalls else { throw ProviderProtocolError.resourceLimit }
            calls[index] = OpenAIToolAccumulator()
        }
        var call = calls[index]!
        if let type = delta.type, type != "function" { throw ProviderProtocolError.unsupportedTools }
        if let id = delta.id {
            guard !id.isEmpty, id.utf8.count <= ProviderLimits.maxToolIDBytes else { throw ProviderProtocolError.malformed }
            if let old = call.id, old != id { throw ProviderProtocolError.malformed }
            call.id = id
        }
        if let function = delta.function {
            if let name = function.name {
                guard !name.isEmpty, name.utf8.count <= ProviderLimits.maxToolNameBytes else { throw ProviderProtocolError.malformed }
                if let old = call.name, old != name { throw ProviderProtocolError.malformed }
                call.name = name
            }
            if let arguments = function.arguments {
                call.append(arguments)
                guard call.arguments.utf8.count <= ProviderLimits.maxToolJSONBytes else {
                    throw ProviderProtocolError.resourceLimit
                }
            }
        }
        calls[index] = call
    }

    private func finalizeCalls() throws -> [CanonicalToolCall] {
        guard !calls.isEmpty, calls.count <= ProviderLimits.maxToolCalls else {
            throw ProviderProtocolError.malformed
        }
        let indexes = calls.keys.sorted()
        guard indexes == Array(0..<calls.count) else { throw ProviderProtocolError.malformed }
        var ids = Set<String>()
        return try indexes.map { index in
            guard let call = calls[index], let id = call.id, !id.isEmpty,
                  id.utf8.count <= ProviderLimits.maxToolIDBytes,
                  let name = call.name, !name.isEmpty,
                  name.utf8.count <= ProviderLimits.maxToolNameBytes else { throw ProviderProtocolError.malformed }
            guard ids.insert(id).inserted else { throw ProviderProtocolError.malformed }
            try validateToolArguments(call.arguments)
            return CanonicalToolCall(id: id, name: names.internalName(for: name), arguments: call.arguments)
        }
    }
}

private struct AnthropicStreamState {
    private let decoder = JSONDecoder()
    private var started = false
    private var sawStop = false
    private var openBlockKind: AnthropicBlockKind?
    private var finish: StreamFinishReason?
    private var inputTokens: Int?
    private var outputTokens: Int?
    private var cacheReadTokens: Int?
    private var cacheWriteTokens: Int?
    private var lastUsage: TokenUsage?
    private var nextBlockIndex = 0
    private var openBlockIndex: Int?
    private var toolCalls: [Int: AnthropicToolAccumulator] = [:]
    private var contentBlocks: [JSONValue] = []
    private var reasoningText = ""
    private var reasoningStarted = false
    private var contentEmitter = HTTPContentBlockEmitter()
    private var deferredContentStart: Int?
    private let names: ToolNameMap
    private let toolsEnabled: Bool
    private let kind: HTTPInvocationKind

    init(toolDefinitions: [ToolDefinition], toolsEnabled: Bool, kind: HTTPInvocationKind) {
        self.names = ToolNameMap(definitions: toolDefinitions)
        self.toolsEnabled = toolsEnabled
        self.kind = kind
    }

    var isFinished: Bool { sawStop }

    mutating func process(_ frame: HTTPChatSSEFrame, continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation) throws {
        let type = frame.event
        if type.isEmpty { return }
        if type != "ping" && type != "message_start" && type != "content_block_start" && type != "content_block_delta" && type != "content_block_stop" && type != "message_delta" && type != "message_stop" && type != "error" {
            return
        }
        if type == "ping" { return }
        if type == "error" { throw ProviderProtocolError.provider }

        switch type {
        case "message_start":
            guard !started else { throw ProviderProtocolError.malformed }
            let value: AnthropicMessageStart
            do { value = try decoder.decode(AnthropicMessageStart.self, from: Data(frame.data.utf8)) }
            catch { throw ProviderProtocolError.malformed }
            guard let message = value.message else { throw ProviderProtocolError.malformed }
            started = true
            inputTokens = message.usage?.inputTokens
            outputTokens = message.usage?.outputTokens
            cacheReadTokens = message.usage?.cacheReadInputTokens
            cacheWriteTokens = message.usage?.cacheCreationInputTokens
            let current = try validatedProviderUsage(.init(inputTokens: inputTokens, outputTokens: outputTokens,
                                                           cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens,
                                                           inputTokenBasis: .excludesCache))
            if message.usage != nil {
                lastUsage = current
                try yieldCanonical(.usage(current), to: continuation)
            }
        case "content_block_start":
            guard started, !sawStop, finish == nil else { throw ProviderProtocolError.malformed }
            let value: AnthropicContentBlockStart
            do { value = try decoder.decode(AnthropicContentBlockStart.self, from: Data(frame.data.utf8)) }
            catch { throw ProviderProtocolError.malformed }
            guard let contentBlock = value.contentBlock else { throw ProviderProtocolError.malformed }
            guard let index = value.index, index == nextBlockIndex, openBlockIndex == nil else { throw ProviderProtocolError.malformed }
            guard contentBlocks.count < ProviderLimits.maxReasoningBlocks else { throw ProviderProtocolError.resourceLimit }
            let envelope = try decoder.decode(JSONValue.self, from: Data(frame.data.utf8))
            guard case .object(let rawBlock) = envelope["content_block"] else { throw ProviderProtocolError.malformed }
            contentBlocks.append(.object(rawBlock))
            openBlockIndex = index
            switch contentBlock.type {
            case "text":
                openBlockKind = .text
                if deferredContentStart == nil { try contentEmitter.begin(.text, to: continuation) }
                if let text = contentBlock.text, !text.isEmpty {
                    if deferredContentStart == nil { try contentEmitter.append(text, kind: .text, to: continuation) }
                }
            case "tool_use":
                guard toolsEnabled else { throw ProviderProtocolError.unsupportedTools }
                guard toolCalls.count < ProviderLimits.maxToolCalls else { throw ProviderProtocolError.resourceLimit }
                openBlockKind = .tool
                if deferredContentStart == nil { deferredContentStart = index }
                toolCalls[index] = try AnthropicToolAccumulator(id: contentBlock.id, name: contentBlock.name, input: contentBlock.input)
            case "thinking":
                openBlockKind = .thinking
                if deferredContentStart == nil { try contentEmitter.begin(.thinking, to: continuation) }
                reasoningStarted = true
                if let text = contentBlock.thinking, !text.isEmpty {
                    guard reasoningText.utf8.count + text.utf8.count <= ProviderLimits.maxReasoningTextBytes else { throw ProviderProtocolError.resourceLimit }
                    reasoningText.append(text)
                    if deferredContentStart == nil { try contentEmitter.append(text, kind: .thinking, to: continuation) }
                }
            case "redacted_thinking":
                openBlockKind = .redactedThinking
                reasoningStarted = true
            default:
                throw ProviderProtocolError.malformed
            }
        case "content_block_delta":
            guard started, openBlockKind != nil, !sawStop, finish == nil else { throw ProviderProtocolError.malformed }
            let value: AnthropicContentBlockDelta
            do { value = try decoder.decode(AnthropicContentBlockDelta.self, from: Data(frame.data.utf8)) }
            catch { throw ProviderProtocolError.malformed }
            guard value.index == openBlockIndex else { throw ProviderProtocolError.malformed }
            guard let delta = value.delta else { throw ProviderProtocolError.malformed }
            switch (openBlockKind, delta.type) {
            case (.text, "text_delta"):
                if let text = delta.text, !text.isEmpty {
                    if deferredContentStart == nil { try contentEmitter.append(text, kind: .text, to: continuation) }
                    try appendBlockText(text, at: openBlockIndex!)
                }
            case (.tool, "input_json_delta"):
                guard let partial = delta.partialJSON else { throw ProviderProtocolError.malformed }
                guard var call = toolCalls[openBlockIndex!] else { throw ProviderProtocolError.malformed }
                try call.append(partial)
                toolCalls[openBlockIndex!] = call
            case (.thinking, "thinking_delta"):
                guard let text = delta.thinking else { throw ProviderProtocolError.malformed }
                reasoningStarted = true
                if !text.isEmpty {
                    guard reasoningText.utf8.count + text.utf8.count <= ProviderLimits.maxReasoningTextBytes else { throw ProviderProtocolError.resourceLimit }
                    reasoningText.append(text)
                    if deferredContentStart == nil { try contentEmitter.append(text, kind: .thinking, to: continuation) }
                    let currentThinking = contentBlocks[openBlockIndex!]["thinking"]?.stringValue ?? ""
                    try appendBlockField("thinking", value: .string(currentThinking + text), at: openBlockIndex!)
                }
            case (.thinking, "signature_delta"), (.redactedThinking, "signature_delta"):
                guard let signature = delta.signature else { throw ProviderProtocolError.malformed }
                let previousSignature = contentBlocks[openBlockIndex!]["signature"]?.stringValue ?? ""
                try appendBlockField("signature", value: .string(previousSignature + signature), at: openBlockIndex!)
                reasoningStarted = true
            default:
                throw ProviderProtocolError.malformed
            }
        case "content_block_stop":
            guard started, openBlockKind != nil, finish == nil else { throw ProviderProtocolError.malformed }
            let value: AnthropicContentBlockStop
            do { value = try decoder.decode(AnthropicContentBlockStop.self, from: Data(frame.data.utf8)) }
            catch { throw ProviderProtocolError.malformed }
            guard value.index == openBlockIndex else { throw ProviderProtocolError.malformed }
            if openBlockKind == .tool, let index = openBlockIndex, let call = toolCalls[index] {
                guard let input = try? JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8)), case .object = input else { throw ProviderProtocolError.malformed }
                try appendBlockField("input", value: input, at: index)
                toolCalls[index] = call
            }
            try contentEmitter.finish(to: continuation)
            openBlockKind = nil
            openBlockIndex = nil
            nextBlockIndex += 1
        case "message_delta":
            guard started, !sawStop else { throw ProviderProtocolError.malformed }
            let value: AnthropicMessageDelta
            do { value = try decoder.decode(AnthropicMessageDelta.self, from: Data(frame.data.utf8)) }
            catch { throw ProviderProtocolError.malformed }
            guard let delta = value.delta else { throw ProviderProtocolError.malformed }
            if let reason = delta.stopReason {
                guard finish == nil else { throw ProviderProtocolError.malformed }
                switch reason {
                case "end_turn", "stop_sequence": finish = .stop
                case "max_tokens": finish = .outputLimit
                case "tool_use":
                    guard !toolCalls.isEmpty else { throw ProviderProtocolError.malformed }
                    finish = .toolCalls
                default: throw ProviderProtocolError.provider
                }
            }
            if let reported = value.usage {
                if let input = reported.inputTokens { inputTokens = input }
                if let output = reported.outputTokens { outputTokens = output }
                if let cacheRead = reported.cacheReadInputTokens { cacheReadTokens = cacheRead }
                if let cacheWrite = reported.cacheCreationInputTokens { cacheWriteTokens = cacheWrite }
                let current = try validatedProviderUsage(.init(inputTokens: inputTokens, outputTokens: outputTokens,
                                                               cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens,
                                                               inputTokenBasis: .excludesCache))
                if lastUsage != current {
                    lastUsage = current
                    try yieldCanonical(.usage(current), to: continuation)
                }
            }
        case "message_stop":
            guard started, !sawStop, finish != nil, openBlockKind == nil else { throw ProviderProtocolError.malformed }
            if !toolCalls.isEmpty, finish != .toolCalls, finish != .outputLimit { throw ProviderProtocolError.malformed }
            let calls = finish == .toolCalls ? try finalizeCalls() : []
            try emitReasoning(continuation: continuation, complete: true)
            try flushDeferredContent(calls: calls, continuation: continuation)
            sawStop = true
            try yieldCanonical(.finished(finish!), to: continuation)
        default: break
        }
    }

    private mutating func appendBlockText(_ fragment: String, at index: Int) throws {
        guard index < contentBlocks.count, case .object(let block) = contentBlocks[index] else { throw ProviderProtocolError.malformed }
        let current = block["text"]?.stringValue ?? ""
        try appendBlockField("text", value: .string(current + fragment), at: index)
    }

    private mutating func appendBlockField(_ key: String, value: JSONValue, at index: Int) throws {
        guard index < contentBlocks.count, case .object(var block) = contentBlocks[index] else { throw ProviderProtocolError.malformed }
        block[key] = value
        contentBlocks[index] = .object(block)
    }

    mutating func flushReasoning(continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation,
                                 includeContinuation: Bool = false) throws {
        try contentEmitter.finish(to: continuation)
        try flushDeferredContent(calls: [], continuation: continuation)
        if includeContinuation { try emitReasoning(continuation: continuation, complete: false) }
    }

    private func emitReasoning(continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation, complete: Bool) throws {
        guard reasoningStarted else { return }
        if complete { try validateAnthropicThinkingBlocks(contentBlocks) }
        let content = HTTPReasoning(format: .anthropicBlocks, text: reasoningText, blocks: contentBlocks, isComplete: complete)
        do { try content.validate() } catch { throw ProviderProtocolError.resourceLimit }
        try yieldCanonical(.continuation(content.continuation(for: kind.identity)), to: continuation)
    }

    /// Tools are published only after a valid terminal reason. Content after a
    /// tool stays in the already bounded wire block array until then, preserving
    /// order without turning a truncated proposal into an executable call.
    private mutating func flushDeferredContent(calls: [CanonicalToolCall],
                                               continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation) throws {
        guard let start = deferredContentStart else { return }
        deferredContentStart = nil
        for block in contentBlocks[start...] {
            switch block["type"]?.stringValue {
            case "text", "thinking":
                let isThinking = block["type"]?.stringValue == "thinking"
                let contentKind: HTTPContentBlockEmitter.Kind = isThinking ? .thinking : .text
                try contentEmitter.begin(contentKind, to: continuation)
                try contentEmitter.append(block[isThinking ? "thinking" : "text"]?.stringValue ?? "",
                                          kind: contentKind, to: continuation)
                try contentEmitter.finish(to: continuation)
            case "tool_use":
                if let call = calls.first(where: { $0.id == block["id"]?.stringValue }) {
                    try yieldToolCalls([call], to: continuation)
                }
            default: break
            }
        }
    }

    private func finalizeCalls() throws -> [CanonicalToolCall] {
        guard !toolCalls.isEmpty, toolCalls.count <= ProviderLimits.maxToolCalls else {
            throw ProviderProtocolError.malformed
        }
        let indexes = toolCalls.keys.sorted()
        var ids = Set<String>()
        return try indexes.map { index in
            guard let call = toolCalls[index], let id = call.id, !id.isEmpty,
                  id.utf8.count <= ProviderLimits.maxToolIDBytes,
                  let name = call.name, !name.isEmpty,
                  name.utf8.count <= ProviderLimits.maxToolNameBytes else { throw ProviderProtocolError.malformed }
            guard ids.insert(id).inserted else { throw ProviderProtocolError.malformed }
            try validateToolArguments(call.arguments)
            return CanonicalToolCall(id: id, name: names.internalName(for: name), arguments: call.arguments)
        }
    }
}

private func safeProviderError(_ error: any Error) -> MiraError {
    if let error = error as? MiraError { return error }
    if error is CancellationError { return MiraError(.cancelled, "Generation was stopped.") }
    if let status = error as? HTTPStatusError {
        switch status.statusCode {
        case 401, 403: return MiraError(.unauthorized, "The provider credential was rejected.")
        case 408: return MiraError(.timeout, "The provider request timed out; try again later.")
        case 429: return MiraError(.rateLimited, "Too many requests; try again later.")
        case 500...599: return MiraError(.network, "The provider is temporarily unavailable; try again later.")
        default: return MiraError(.providerRejected, "The provider rejected the request.")
        }
    }
    if let error = error as? ProviderProtocolError {
        switch error {
        case .unsupportedTools: return MiraError(.unsupported, "This request contains tool content unsupported by the provider.")
        case .unsupportedReasoning: return MiraError(.unsupported, "This provider returned reasoning content that Mira cannot continue safely.")
        case .provider: return MiraError(.providerRejected, "The provider rejected the request.")
        case .prematureEOF: return MiraError(.interrupted, "The provider connection ended before generation completed.")
        case .malformed: return MiraError(.malformedStream, "The provider returned an unparseable stream.")
        case .resourceLimit: return MiraError(.malformedStream, "The provider stream exceeded its size limit.")
        }
    }
    if let urlError = error as? URLError, urlError.code == .cancelled { return MiraError(.cancelled, "Generation was stopped.") }
    return MiraError(.network, "Unable to connect to the provider; try again later.")
}

private struct HTTPStatusError: Error { let statusCode: Int }
enum ProviderProtocolError: Error { case malformed, prematureEOF, provider, unsupportedTools, unsupportedReasoning, resourceLimit }
private struct HTTPStreamError: Error {
    let error: any Error
    let statusCode: Int?
    let headers: [String: String]
}

private func classifyStreamFailure(_ failure: HTTPStreamError, now: @Sendable () -> Date) -> AgentModelFailure {
    let error = safeProviderError(failure.error)
    if let urlError = failure.error as? URLError,
       [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet].contains(urlError.code) {
        return AgentModelFailure(error: error, retryAdvice: .transient(minimumDelayMilliseconds: 0))
    }
    guard let statusCode = failure.statusCode else {
        return AgentModelFailure(error: error)
    }
    guard [408, 429, 500, 502, 503, 504].contains(statusCode) else { return AgentModelFailure(error: error) }
    return AgentModelFailure(error: error, retryAdvice: retryAdvice(headers: failure.headers, now: now))
}

func retryAdvice(headers: [String: String], now: @Sendable () -> Date) -> AgentModelRetryAdvice? {
    guard let raw = headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame })?.value else {
        return .transient(minimumDelayMilliseconds: 0)
    }
    guard raw.utf8.count <= 128, !raw.isEmpty else { return nil }
    let delay: Int?
    if raw.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) {
        var seconds: UInt64 = 0
        for scalar in raw.unicodeScalars {
            let digit = UInt64(scalar.value - 48)
            if seconds > (86_400 - digit) / 10 { return nil }
            seconds = seconds * 10 + digit
        }
        delay = seconds <= 86_400 ? Int(seconds * 1_000) : nil
    } else {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard raw.utf8.count == 29, raw.hasSuffix(" GMT") else { return nil }
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        let current = now()
        guard let date = formatter.date(from: raw),
              formatter.string(from: date) == raw, current.timeIntervalSince1970.isFinite,
              date.timeIntervalSince(current).isFinite else { return nil }
        let seconds = date.timeIntervalSince(current)
        guard seconds <= 86_400 else { return nil }
        delay = Int(ceil(max(0, seconds) * 1_000))
    }
    guard let delay else { return nil }
    return .transient(minimumDelayMilliseconds: delay)
}

private enum ProviderLimits {
    static let maxToolCalls = 32
    static let maxToolJSONBytes = 65_536
    static let maxToolIDBytes = 256
    static let maxToolNameBytes = 128
    static let maxReasoningTextBytes = 2_097_152
    static let maxReasoningBlocks = 256
    static let maxReasoningDetails = 65_536
    static let maxReasoningPayloadBytes = 4_194_304
}

private struct OpenAIToolAccumulator {
    var id: String?
    var name: String?
    var arguments = "{}"
    var sawArgumentDelta = false

    mutating func append(_ fragment: String) {
        if !sawArgumentDelta {
            arguments.removeAll(keepingCapacity: true)
            sawArgumentDelta = true
        }
        arguments.append(fragment)
    }
}

private enum AnthropicBlockKind: Equatable { case text, tool, thinking, redactedThinking }

private struct AnthropicToolAccumulator {
    var id: String?
    var name: String?
    var arguments = ""
    var initialWasPlaceholder = true
    var sawJSONDelta = false

    init(id: String?, name: String?, input: JSONValue?) throws {
        self.id = id
        self.name = name
        if let input {
            guard case .object = input else { throw ProviderProtocolError.malformed }
            self.arguments = try input.jsonString()
            self.initialWasPlaceholder = input == .object([:])
        }
    }

    mutating func append(_ partial: String) throws {
        if !initialWasPlaceholder { throw ProviderProtocolError.malformed }
        if !sawJSONDelta {
            arguments.removeAll(keepingCapacity: true)
            sawJSONDelta = true
        }
        arguments.append(partial)
        guard arguments.utf8.count <= ProviderLimits.maxToolJSONBytes else {
            throw ProviderProtocolError.resourceLimit
        }
    }
}


private struct OpenAIRequest: Encodable {
    let model: String
    let messages: [OpenAIMessage]
    let stream: Bool
    let maxTokens: Int?
    let maxCompletionTokens: Int?
    let streamOptions: OpenAIStreamOptions?
    let tools: [OpenAIToolDefinition]?
    let toolChoice: String?
    let thinking: OpenAIThinking?
    let reasoningEffort: String?
    let reasoning: OpenRouterReasoning?

    init(request: AgentModelInput, route: HTTPModelPolicy) throws {
        self.model = route.modelID
        let names = ToolNameMap(definitions: request.tools)
        self.messages = try [OpenAIMessage(role: route.kind.dialect == .openAI ? "developer" : "system", content: request.instructions, toolCalls: nil, toolCallID: nil, reasoning: nil, mode: route.kind)] + request.messages.map {
            let calls = $0.toolCalls.map { call in
                OpenAIToolCall(id: call.id, type: "function", function: OpenAIFunction(name: names.wireName(for: call.name), arguments: call.arguments))
            }
            let role: String
            switch $0.role {
            case .user, .context: role = "user"
            case .assistant: role = "assistant"
            case .tool: role = "tool"
            }
            let messageText = $0.role == .tool ? $0.toolResults.map(\.text).joined() : $0.text
            return try OpenAIMessage(role: role, content: messageText, toolCalls: calls.isEmpty ? nil : calls,
                toolCallID: $0.toolResults.first?.callID,
                reasoning: $0.continuation == nil ? nil : try HTTPReasoning($0), mode: route.kind)
        }
        self.stream = true
        let outputLimit = request.outputTokenLimit ?? route.maximumOutputTokens
        self.maxTokens = ProviderThinkingRules.usesCompletionTokenLimit(for: route) ? nil : outputLimit
        self.maxCompletionTokens = ProviderThinkingRules.usesCompletionTokenLimit(for: route) ? outputLimit : nil
        self.streamOptions = route.configuration.requestsUsage ? OpenAIStreamOptions(includeUsage: true) : nil
        self.tools = request.tools.isEmpty ? nil : request.tools.map { definition in
            OpenAIToolDefinition(type: "function", function: OpenAIFunctionDefinition(name: definition.wireName, description: definition.description, parameters: definition.inputSchema))
        }
        self.toolChoice = request.allowsToolCalls ? nil : "none"
        let preservesReasoningHistory = request.messages.contains {
            $0.role == .assistant && $0.continuation != nil
        }
        self.thinking = ProviderThinkingRules.openAIThinkingType(for: route,
            preservingHistory: preservesReasoningHistory).map {
            OpenAIThinking(type: $0, keep: ProviderThinkingRules.preservesKimiThinking(for: route) ? "all" : nil)
        }
        self.reasoningEffort = ProviderThinkingRules.openAIReasoningEffort(for: route)
        if let router = ProviderThinkingRules.openRouterReasoning(for: route) {
            self.reasoning = OpenRouterReasoning(enabled: router.enabled, effort: router.effort, maxTokens: router.maxTokens)
        } else {
            self.reasoning = nil
        }
    }
    enum CodingKeys: String, CodingKey { case model, messages, stream, maxTokens = "max_tokens", maxCompletionTokens = "max_completion_tokens", streamOptions = "stream_options", tools, toolChoice = "tool_choice", thinking, reasoningEffort = "reasoning_effort", reasoning }
}
private struct OpenAIThinking: Encodable { let type: String; let keep: String? }
private struct OpenRouterReasoning: Encodable {
    let enabled: Bool?
    let effort: String?
    let maxTokens: Int?
    enum CodingKeys: String, CodingKey { case enabled, effort; case maxTokens = "max_tokens" }
}
private struct OpenAIStreamOptions: Encodable { let includeUsage: Bool; enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" } }
private struct OpenAIMessage: Encodable {
    let role: String
    let content: String?
    let toolCalls: [OpenAIToolCall]?
    let toolCallID: String?
    let reasoningContent: String?
    let reasoningDetails: [JSONValue]?
    let reasoningText: String?

    init(role: String, content: String?, toolCalls: [OpenAIToolCall]?, toolCallID: String?, reasoning: HTTPReasoning?, mode: HTTPInvocationKind) throws {
        self.role = role; self.content = content; self.toolCalls = toolCalls; self.toolCallID = toolCallID
        var reasoningContent: String? = role == "assistant" && (mode.dialect == .deepSeek || mode.dialect == .kimi) ? "" : nil
        var reasoningDetails: [JSONValue]? = nil
        var reasoningText: String? = nil
        if role == "assistant", let reasoning {
            try reasoning.validate()
            if mode.dialect == .openRouter {
                guard reasoning.format == .openRouterDetails else { throw ProviderProtocolError.malformed }
            } else if mode.dialect != .generic {
                guard reasoning.format == .openAIContent else { throw ProviderProtocolError.malformed }
            }
            switch reasoning.format {
            case .openAIContent:
                guard reasoning.isComplete else { throw ProviderProtocolError.malformed }
                reasoningContent = reasoning.text
            case .openRouterDetails:
                guard reasoning.isComplete else { throw ProviderProtocolError.malformed }
                reasoningDetails = reasoning.blocks.isEmpty ? nil : reasoning.blocks
                reasoningText = reasoning.blocks.isEmpty ? reasoning.text : nil
            case .anthropicBlocks:
                throw ProviderProtocolError.malformed
            }
        }
        self.reasoningContent = reasoningContent
        self.reasoningDetails = reasoningDetails
        self.reasoningText = reasoningText
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case reasoningContent = "reasoning_content"
        case reasoningDetails = "reasoning_details"
        case reasoningText = "reasoning"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        if let toolCalls { try container.encode(toolCalls, forKey: .toolCalls) }
        if let toolCallID { try container.encode(toolCallID, forKey: .toolCallID) }
        if let reasoningContent { try container.encode(reasoningContent, forKey: .reasoningContent) }
        if let reasoningDetails { try container.encode(reasoningDetails, forKey: .reasoningDetails) }
        if let reasoningText { try container.encode(reasoningText, forKey: .reasoningText) }
    }
}
private struct OpenAIToolDefinition: Encodable { let type: String; let function: OpenAIFunctionDefinition }
private struct OpenAIFunctionDefinition: Encodable { let name: String; let description: String; let parameters: JSONValue }
private struct OpenAIToolCall: Encodable { let id: String; let type: String; let function: OpenAIFunction }
private struct OpenAIFunction: Encodable { let name: String; let arguments: String }
private struct AnthropicToolDefinition: Encodable {
    let name: String
    let description: String
    let inputSchema: JSONValue
    enum CodingKeys: String, CodingKey { case name, description; case inputSchema = "input_schema" }
}

private struct OpenAIChunk: Decodable {
    let choices: [OpenAIChoice]?
    let usage: OpenAIUsage?
    let error: OpenAIError?
}
private struct OpenAIChoice: Decodable { let delta: OpenAIDelta?; let finishReason: String?; enum CodingKeys: String, CodingKey { case delta; case finishReason = "finish_reason" } }
private struct OpenAIDelta: Decodable {
    let content: String?
    let toolCalls: [OpenAIResponseToolCall]?
    let functionCall: OpenAIFunctionCall?
    let reasoningContent: String?
    let reasoningDetails: JSONValue?
    let reasoning: String?
    enum CodingKeys: String, CodingKey {
        case content
        case toolCalls = "tool_calls"
        case functionCall = "function_call"
        case reasoningContent = "reasoning_content"
        case reasoningDetails = "reasoning_details"
        case reasoning
    }
}
private struct OpenAIResponseToolCall: Decodable {
    let index: Int?
    let id: String?
    let type: String?
    let function: OpenAIFunctionCall?
}
private struct OpenAIFunctionCall: Decodable { let name: String?; let arguments: String? }
private struct OpenAIUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let promptTokensDetails: OpenAITokenDetails?
    let completionTokensDetails: OpenAITokenDetails?
    let cachedTokens: Int?
    let promptCacheHitTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case promptTokensDetails = "prompt_tokens_details"
        case completionTokensDetails = "completion_tokens_details"
        case cachedTokens = "cached_tokens"
        case promptCacheHitTokens = "prompt_cache_hit_tokens"
    }

    func tokenUsage() throws -> TokenUsage {
        let cacheReads = [promptTokensDetails?.cachedTokens, cachedTokens, promptCacheHitTokens].compactMap { $0 }
        guard Set(cacheReads).count <= 1 else { throw ProviderProtocolError.malformed }
        return try validatedProviderUsage(.init(inputTokens: promptTokens, outputTokens: completionTokens,
                                                cacheReadTokens: cacheReads.first,
                                                reasoningTokens: completionTokensDetails?.reasoningTokens))
    }
}
private struct OpenAITokenDetails: Decodable {
    let cachedTokens: Int?
    let reasoningTokens: Int?
    enum CodingKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
        case reasoningTokens = "reasoning_tokens"
    }
}
private struct OpenAIError: Decodable { let message: String?; let type: String? }

private struct AnthropicRequest: Encodable {
    let model: String
    let messages: [AnthropicMessage]
    let system: String
    let maxTokens: Int
    let stream: Bool
    let tools: [AnthropicToolDefinition]?
    let toolChoice: AnthropicToolChoice?
    let thinking: AnthropicThinking?
    let outputConfig: AnthropicOutputConfig?
    init(request: AgentModelInput, route: HTTPModelPolicy) throws {
        self.model = route.modelID
        self.messages = try AnthropicMessageBuilder.build(request.messages, definitions: request.tools)
        self.system = request.instructions
        let outputLimit = request.outputTokenLimit ?? route.maximumOutputTokens
        if let thinking = ProviderThinkingRules.anthropicThinking(for: route),
           outputLimit <= (thinking.budgetTokens ?? 0) {
            throw MiraError(.configuration, "The requested output limit must exceed the Anthropic thinking budget.")
        }
        self.maxTokens = outputLimit
        self.stream = true
        self.tools = request.tools.isEmpty ? nil : request.tools.map { definition in
            AnthropicToolDefinition(name: definition.wireName, description: definition.description, inputSchema: definition.inputSchema)
        }
        self.toolChoice = request.allowsToolCalls ? nil : AnthropicToolChoice(type: "none")
        if let thinking = ProviderThinkingRules.anthropicThinking(for: route) {
            self.thinking = AnthropicThinking(type: thinking.type, budgetTokens: thinking.budgetTokens)
        } else {
            self.thinking = nil
        }
        self.outputConfig = ProviderThinkingRules.anthropicOutputEffort(for: route).map { AnthropicOutputConfig(effort: $0) }
    }
    enum CodingKeys: String, CodingKey { case model, messages, system, maxTokens = "max_tokens", stream, tools, toolChoice = "tool_choice", thinking; case outputConfig = "output_config" }
}
private struct AnthropicToolChoice: Encodable { let type: String }
private struct AnthropicThinking: Encodable {
    let type: String
    let budgetTokens: Int?
    enum CodingKeys: String, CodingKey { case type; case budgetTokens = "budget_tokens" }
}
private struct AnthropicOutputConfig: Encodable { let effort: String }
private struct AnthropicMessage: Encodable {
    let role: String
    let content: AnthropicContent
}
private enum AnthropicContent: Encodable {
    case text(String)
    case blocks([AnthropicContentBlock])

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .text(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .blocks(let value):
            var container = encoder.unkeyedContainer()
            for block in value { try container.encode(block) }
        }
    }
}
private enum AnthropicContentBlock: Encodable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(id: String, content: String)
    case raw(JSONValue)

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: DynamicCodingKey("type"))
            try container.encode(value, forKey: DynamicCodingKey("text"))
        case .toolUse(let id, let name, let input):
            try container.encode("tool_use", forKey: DynamicCodingKey("type"))
            try container.encode(id, forKey: DynamicCodingKey("id"))
            try container.encode(name, forKey: DynamicCodingKey("name"))
            try container.encode(input, forKey: DynamicCodingKey("input"))
        case .toolResult(let id, let content):
            try container.encode("tool_result", forKey: DynamicCodingKey("type"))
            try container.encode(id, forKey: DynamicCodingKey("tool_use_id"))
            try container.encode(content, forKey: DynamicCodingKey("content"))
        case .raw(let value):
            guard case .object(let fields) = value else { throw ProviderProtocolError.malformed }
            // Use one container per encoder. Opening a second single-value
            // container can corrupt sibling array positions on older Foundation.
            for (key, field) in fields { try container.encode(field, forKey: DynamicCodingKey(key)) }
        }
    }
}
private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private struct ToolNameMap {
    let definitions: [ToolDefinition]
    init(definitions: [ToolDefinition]) { self.definitions = definitions }
    func wireName(for name: String) -> String {
        definitions.first(where: { $0.name == name })?.wireName ?? name.replacingOccurrences(of: ".", with: "_")
    }
    func internalName(for wireName: String) -> String {
        definitions.first(where: { $0.wireName == wireName })?.name ?? wireName
    }
}

private enum AnthropicMessageBuilder {
    static func build(_ messages: [AgentModelMessage], definitions: [ToolDefinition]) throws -> [AnthropicMessage] {
        let names = ToolNameMap(definitions: definitions)
        var result: [AnthropicMessage] = []
        var pendingResults: [AnthropicContentBlock] = []
        func flushResults() {
            if !pendingResults.isEmpty {
                result.append(AnthropicMessage(role: "user", content: .blocks(pendingResults)))
                pendingResults.removeAll(keepingCapacity: true)
            }
        }
        for message in messages {
            if message.role == .tool {
                for result in message.toolResults {
                    guard !result.callID.isEmpty else { throw ProviderProtocolError.malformed }
                    pendingResults.append(.toolResult(id: result.callID, content: result.text))
                }
                continue
            }
            flushResults()
            if message.role == .assistant, message.continuation != nil {
                let reasoning = try HTTPReasoning(message)
                try validateAnthropicReplay(reasoning, message: message, names: names)
                result.append(AnthropicMessage(role: "assistant", content: .blocks(reasoning.blocks.map(AnthropicContentBlock.raw))))
            } else if message.role == .assistant, !message.toolCalls.isEmpty {
                let calls = message.toolCalls
                var blocks: [AnthropicContentBlock] = []
                if !message.text.isEmpty { blocks.append(.text(message.text)) }
                for call in calls {
                    guard !call.id.isEmpty, !call.name.isEmpty,
                          let input = try? JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8)) else {
                        throw ProviderProtocolError.malformed
                    }
                    blocks.append(.toolUse(id: call.id, name: names.wireName(for: call.name), input: input))
                }
                result.append(AnthropicMessage(role: "assistant", content: .blocks(blocks)))
            } else {
                let role = message.role == .assistant ? "assistant" : "user"
                result.append(AnthropicMessage(role: role, content: .text(message.text)))
            }
        }
        flushResults()
        return result
    }

    private static func validateAnthropicReplay(_ reasoning: HTTPReasoning, message: AgentModelMessage, names: ToolNameMap) throws {
        guard reasoning.format == .anthropicBlocks, reasoning.isComplete else { throw ProviderProtocolError.malformed }
        do { try reasoning.validate() } catch { throw ProviderProtocolError.malformed }
        try validateAnthropicThinkingBlocks(reasoning.blocks)
        var text = ""
        var calls: [(String, String, JSONValue)] = []
        for block in reasoning.blocks {
            guard case .object(let object) = block, let type = object["type"]?.stringValue else { throw ProviderProtocolError.malformed }
            switch type {
            case "text":
                guard let value = object["text"]?.stringValue else { throw ProviderProtocolError.malformed }
                text.append(value)
            case "tool_use":
                guard let id = object["id"]?.stringValue, let name = object["name"]?.stringValue,
                      let input = object["input"], case .object = input else { throw ProviderProtocolError.malformed }
                calls.append((id, name, input))
            case "thinking", "redacted_thinking":
                continue
            default:
                throw ProviderProtocolError.malformed
            }
        }
        guard text == message.text, calls.count == (message.toolCalls.count) else { throw ProviderProtocolError.malformed }
        for (actual, expected) in zip(calls, message.toolCalls) {
            guard actual.0 == expected.id,
                  actual.1 == names.wireName(for: expected.name),
                  let expectedInput = try? JSONDecoder().decode(JSONValue.self, from: Data(expected.arguments.utf8)),
                  actual.2 == expectedInput else { throw ProviderProtocolError.malformed }
        }
    }
}
/// Complete signed/redacted continuation must be available before exposing a
/// runnable tool batch. Partial snapshots are retained only for recovery/display.
private func validateAnthropicThinkingBlocks(_ blocks: [JSONValue]) throws {
    for block in blocks {
        switch block["type"]?.stringValue {
        case "thinking":
            guard block["thinking"]?.stringValue != nil,
                  let signature = block["signature"]?.stringValue, !signature.isEmpty else { throw ProviderProtocolError.malformed }
        case "redacted_thinking":
            guard let data = block["data"]?.stringValue, !data.isEmpty else { throw ProviderProtocolError.malformed }
        default: break
        }
    }
}

private struct AnthropicMessageStart: Decodable { let message: AnthropicMessageEnvelope? }
private struct AnthropicMessageEnvelope: Decodable { let usage: AnthropicUsage? }
private struct AnthropicUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }
}
private struct AnthropicContentBlockStart: Decodable { let index: Int?; let contentBlock: AnthropicWireContentBlock?; enum CodingKeys: String, CodingKey { case index; case contentBlock = "content_block" } }
private struct AnthropicWireContentBlock: Decodable {
    let type: String?
    let text: String?
    let id: String?
    let name: String?
    let input: JSONValue?
    let thinking: String?
    let signature: String?
    let data: String?
}
private struct AnthropicContentBlockDelta: Decodable { let index: Int?; let delta: AnthropicDelta? }
private struct AnthropicDelta: Decodable {
    let type: String?
    let text: String?
    let thinking: String?
    let partialJSON: String?
    let stopReason: String?
    let signature: String?
    enum CodingKeys: String, CodingKey { case type, text, thinking, signature; case partialJSON = "partial_json"; case stopReason = "stop_reason" }
}
private struct AnthropicMessageDelta: Decodable { let delta: AnthropicDelta?; let usage: AnthropicUsage? }
private struct AnthropicContentBlockStop: Decodable { let index: Int? }

/// HTTP wire identity conversion belongs to this adapter, not the core tool registry.
private extension ToolDefinition {
    var wireName: String { name.replacingOccurrences(of: ".", with: "_") }
}
