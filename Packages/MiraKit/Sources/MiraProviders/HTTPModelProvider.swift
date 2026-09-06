import Foundation
import MiraCore

public struct HTTPModelProvider: ModelProviderPort, Sendable {
    public let credentials: any CredentialReader
    public let transport: any HTTPStreamingTransport

    public init(
        credentials: any CredentialReader,
        transport: any HTTPStreamingTransport = URLSessionStreamingTransport()
    ) {
        self.credentials = credentials
        self.transport = transport
    }

    public func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        // Validate before constructing a request or reading Keychain. This is
        // also a defense against callers accidentally using an incomplete route.
        let endpoint: URL
        do {
            try route.validateForSending()
            endpoint = try route.validatedEndpoint()
            guard route.providerKind == .openAICompatible || route.providerKind == .anthropic else {
                throw MiraError(.unsupported, "This provider protocol is not supported.")
            }
            let hasToolContent = try validateToolHistory(request)
            if request.tools?.isEmpty == false || hasToolContent {
                guard route.toolCapability == .declared || route.toolCapability == .verified else {
                    throw MiraError(.unsupported, "This route has not declared or verified tool-call capability.")
                }
            }
        } catch {
            let safe = safeProviderError(error)
            return AsyncThrowingStream { $0.finish(throwing: safe) }
        }

        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(128)) { continuation in
            let task = Task {
                var activeRequest: URLRequest?
                do {
                    let secret: String
                    do {
                        secret = try credentials.read(reference: route.credentialReference, version: route.credentialVersion)
                    } catch {
                        throw MiraError(.credentialMissing, "The provider credential is unavailable.")
                    }
                    guard !secret.isEmpty else { throw MiraError(.credentialMissing, "The provider credential is unavailable.") }
                    let urlRequest = try makeURLRequest(request: request, route: route, endpoint: endpoint, secret: secret)
                    activeRequest = urlRequest
                    try await run(urlRequest: urlRequest, route: route, request: request, continuation: continuation)
                    continuation.finish()
                } catch {
                    if let activeRequest { cancelTransport(for: activeRequest) }
                    if Task.isCancelled || error is CancellationError {
                        continuation.finish(throwing: MiraError(.cancelled, "Generation was stopped."))
                    } else {
                        continuation.finish(throwing: safeProviderError(error))
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func makeURLRequest(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot, endpoint: URL, secret: String) throws -> URLRequest {
        var result = URLRequest(url: endpoint)
        result.httpMethod = "POST"
        result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A Step may retry under the same execution. Cancellation must target
        // this dispatch only, never every attempt in the execution.
        result.setValue(request.dispatchID.uuidString, forHTTPHeaderField: "X-Mira-Request-ID")
        if route.providerKind == .openAICompatible {
            result.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            result.httpBody = try JSONEncoder().encode(OpenAIRequest(request: request, route: route))
        } else {
            result.setValue(secret, forHTTPHeaderField: "x-api-key")
            result.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            result.httpBody = try JSONEncoder().encode(AnthropicRequest(request: request, route: route))
        }
        return result
    }

    private func run(
        urlRequest: URLRequest,
        route: ResolvedModelRouteSnapshot,
        request: CanonicalModelRequest,
        continuation: AsyncThrowingStream<CanonicalStreamEvent, any Error>.Continuation
    ) async throws {
        let input = transport.stream(request: urlRequest)
        var responseReceived = false
        var parser = SSEParser()
        var protocolFinished = false
        var openAIState = OpenAIStreamState(toolDefinitions: request.tools ?? [], toolsEnabled: request.tools?.isEmpty == false, protocolMode: route.protocolMode)
        var anthropicState = AnthropicStreamState(toolDefinitions: request.tools ?? [], toolsEnabled: request.tools?.isEmpty == false, protocolMode: route.protocolMode)

        defer {
            if !protocolFinished && !Task.isCancelled {
                if route.providerKind == .openAICompatible {
                    try? openAIState.flushReasoning(continuation: continuation)
                } else {
                    try? anthropicState.flushReasoning(continuation: continuation)
                }
            }
        }
        for try await event in input {
            try Task.checkCancellation()
            switch event {
            case .response(let response):
                guard !responseReceived else { throw ProviderProtocolError.malformed }
                responseReceived = true
                guard (200..<300).contains(response.statusCode) else {
                    throw HTTPStatusError(statusCode: response.statusCode)
                }
            case .bytes(let data):
                guard responseReceived else { throw ProviderProtocolError.malformed }
                try parser.feed(data) { frame in
                    if protocolFinished { return }
                    if route.providerKind == .openAICompatible {
                        try openAIState.process(frame, continuation: continuation)
                        protocolFinished = openAIState.isFinished
                    } else {
                        try anthropicState.process(frame, continuation: continuation)
                        protocolFinished = anthropicState.isFinished
                    }
                }
                // A protocol terminal is sufficient. Explicitly cancel the underlying
                // URL task; a peer may otherwise leave the HTTP connection open.
                if protocolFinished {
                    cancelTransport(for: urlRequest)
                    return
                }
            case .end:
                try parser.finish { frame in
                    if protocolFinished { return }
                    if route.providerKind == .openAICompatible {
                        try openAIState.process(frame, continuation: continuation)
                        protocolFinished = openAIState.isFinished
                    } else {
                        try anthropicState.process(frame, continuation: continuation)
                        protocolFinished = anthropicState.isFinished
                    }
                }
                if protocolFinished {
                    cancelTransport(for: urlRequest)
                    return
                }
                throw ProviderProtocolError.prematureEOF
            }
        }

        guard responseReceived else { throw ProviderProtocolError.prematureEOF }
        throw ProviderProtocolError.prematureEOF
    }

    private func cancelTransport(for request: URLRequest) {
        (transport as? any HTTPStreamingTransportCancellation)?.cancel(request: request)
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

/// Validates the protocol pairing before credentials are read or any network
/// request is dispatched. Tool results are one contiguous batch following the
/// assistant call that produced their IDs.
private func validateToolHistory(_ request: CanonicalModelRequest) throws -> Bool {
    let definitions = request.tools ?? []
    var wireNames = Set<String>()
    for definition in definitions {
        guard !definition.name.isEmpty, definition.name.utf8.count <= ProviderLimits.maxToolNameBytes,
              wireNames.insert(definition.wireName).inserted else {
            throw ProviderProtocolError.malformed
        }
    }
    var pending = Set<String>()
    var seenCallIDs = Set<String>()
    var sawToolContent = false
    for message in request.messages {
        guard message.role == .assistant || message.reasoning == nil else { throw ProviderProtocolError.malformed }
        switch message.role {
        case .assistant:
            guard message.toolCallID == nil else { throw ProviderProtocolError.malformed }
            if let calls = message.toolCalls, !calls.isEmpty {
                guard pending.isEmpty else { throw ProviderProtocolError.malformed }
                sawToolContent = true
                for call in calls {
                    guard !call.id.isEmpty, call.id.utf8.count <= ProviderLimits.maxToolIDBytes,
                          !call.name.isEmpty, call.name.utf8.count <= ProviderLimits.maxToolNameBytes,
                          seenCallIDs.insert(call.id).inserted else {
                        throw ProviderProtocolError.malformed
                    }
                    try validateToolArguments(call.arguments)
                    pending.insert(call.id)
                }
            } else {
                guard pending.isEmpty else { throw ProviderProtocolError.malformed }
            }
        case .tool:
            sawToolContent = true
            guard message.toolCalls == nil else { throw ProviderProtocolError.malformed }
            guard let id = message.toolCallID, !id.isEmpty, id.utf8.count <= ProviderLimits.maxToolIDBytes,
                  pending.remove(id) != nil else {
                throw ProviderProtocolError.malformed
            }
        case .user:
            guard pending.isEmpty else { throw ProviderProtocolError.malformed }
            guard message.toolCalls == nil, message.toolCallID == nil else { throw ProviderProtocolError.malformed }
        }
    }
    guard pending.isEmpty else { throw ProviderProtocolError.malformed }
    return sawToolContent
}

private func yieldCanonical(
    _ event: CanonicalStreamEvent,
    to continuation: AsyncThrowingStream<CanonicalStreamEvent, any Error>.Continuation
) throws {
    if case .dropped = continuation.yield(event) {
        throw ProviderProtocolError.resourceLimit
    }
}

private func yieldText(
    _ text: String,
    to continuation: AsyncThrowingStream<CanonicalStreamEvent, any Error>.Continuation
) throws {
    var piece = ""
    piece.reserveCapacity(min(text.utf8.count, 65_536))
    for scalar in text.unicodeScalars {
        let scalarSize = scalar.utf8.count
        if !piece.isEmpty && piece.utf8.count + scalarSize > 65_536 {
            try yieldCanonical(.textDelta(piece), to: continuation)
            piece.removeAll(keepingCapacity: true)
        }
        piece.unicodeScalars.append(scalar)
    }
    if !piece.isEmpty { try yieldCanonical(.textDelta(piece), to: continuation) }
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
    private var reasoningPendingBytes = 0
    private var reasoningDetailsPendingBytes = 0
    private var reasoningDetailsBytes = 0
    private var emittedReasoningSnapshot = false
    private var lastReasoningEmission: ContinuousClock.Instant?
    private var hasReasoning = false
    private let protocolMode: ModelProtocolMode
    private let decoder = JSONDecoder()
    private let names: ToolNameMap
    private let toolsEnabled: Bool

    init(toolDefinitions: [ToolDefinition], toolsEnabled: Bool, protocolMode: ModelProtocolMode) {
        self.names = ToolNameMap(definitions: toolDefinitions)
        self.toolsEnabled = toolsEnabled
        self.protocolMode = protocolMode
    }

    var isFinished: Bool { sawDone }

    mutating func process(_ frame: SSEFrame, continuation: AsyncThrowingStream<CanonicalStreamEvent, any Error>.Continuation) throws {
        if frame.data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            guard !sawDone, finish != nil else { throw ProviderProtocolError.malformed }
            if finish == .toolCalls {
                let calls = try finalizeCalls()
                try flushReasoning(continuation: continuation)
                try finishReasoning(continuation: continuation)
                try yieldCanonical(.toolCalls(calls), to: continuation)
            } else if !calls.isEmpty {
                // A provider cannot turn a tool proposal into a normal stop.
                // A length stop is allowed, but its partial JSON is never sent
                // as a runnable call.
                guard finish == .outputLimit else { throw ProviderProtocolError.malformed }
            }
            if finish != .toolCalls { try flushReasoning(continuation: continuation); try finishReasoning(continuation: continuation) }
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
                var receivedDetails = false
                if let details = delta.reasoningDetails {
                    guard case .array(let fragments) = details else { throw ProviderProtocolError.malformed }
                    guard fragments.count <= ProviderLimits.maxReasoningDetails else { throw ProviderProtocolError.resourceLimit }
                    for fragment in fragments {
                        guard case .object(let object) = fragment else { throw ProviderProtocolError.malformed }
                        if let visible = object["text"] ?? object["summary"] {
                            guard let text = visible.stringValue else { throw ProviderProtocolError.malformed }
                            try appendReasoningText(text, continuation: nil)
                            detailHasVisibleText = detailHasVisibleText || !text.isEmpty
                        }
                        let fragmentBytes = try JSONEncoder().encode(fragment).count
                        guard reasoningDetailsBytes + fragmentBytes <= ProviderLimits.maxReasoningPayloadBytes else { throw ProviderProtocolError.resourceLimit }
                        reasoningDetailsBytes += fragmentBytes
                        reasoningDetailsPendingBytes += fragmentBytes
                    }
                    reasoningDetails.append(contentsOf: fragments)
                    guard reasoningDetails.count <= ProviderLimits.maxReasoningDetails else { throw ProviderProtocolError.resourceLimit }
                    if !fragments.isEmpty {
                        receivedDetails = true
                        sawReasoningDetails = true
                        hasReasoning = true
                    }
                }
                if !detailHasVisibleText {
                    let alias = delta.reasoningContent ?? delta.reasoning ?? ""
                    if !alias.isEmpty { try appendReasoningText(alias, continuation: continuation) }
                }
                if receivedDetails {
                    try emitReasoningIfNeeded(continuation: continuation)
                }
                if finish != nil && (delta.content != nil || delta.toolCalls != nil || delta.functionCall != nil || choice.finishReason != nil) {
                    throw ProviderProtocolError.malformed
                }
                if let text = delta.content, !text.isEmpty {
                    try flushReasoning(continuation: continuation)
                    try yieldText(text, to: continuation)
                }
                if let toolDeltas = delta.toolCalls {
                    try flushReasoning(continuation: continuation)
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

    private mutating func appendReasoningText(_ fragment: String, continuation: AsyncThrowingStream<CanonicalStreamEvent, any Error>.Continuation?) throws {
        guard reasoningText.utf8.count + fragment.utf8.count <= ProviderLimits.maxReasoningTextBytes else { throw ProviderProtocolError.resourceLimit }
        reasoningText.append(fragment)
        hasReasoning = true
        reasoningPendingBytes += fragment.utf8.count
        if let continuation { try emitReasoningIfNeeded(continuation: continuation) }
    }

    mutating func flushReasoning(continuation: AsyncThrowingStream<CanonicalStreamEvent, any Error>.Continuation) throws {
        guard hasReasoning, reasoningPendingBytes > 0 || reasoningDetailsPendingBytes > 0 else { return }
        try emitReasoning(continuation: continuation)
    }

    private mutating func emitReasoningIfNeeded(continuation: AsyncThrowingStream<CanonicalStreamEvent, any Error>.Continuation) throws {
        guard !emittedReasoningSnapshot ||
                reasoningPendingBytes + reasoningDetailsPendingBytes >= ProviderLimits.reasoningSnapshotBytes ||
                lastReasoningEmission.map({ ContinuousClock.now - $0 >= .milliseconds(100) }) == true else { return }
        try emitReasoning(continuation: continuation)
    }

    private var reasoningFormat: ReasoningFormat {
        sawReasoningDetails || protocolMode == .openRouter ? .openRouterDetails : .openAIContent
    }

    private mutating func emitReasoning(continuation: AsyncThrowingStream<CanonicalStreamEvent, any Error>.Continuation) throws {
        let content = ReasoningContent(format: reasoningFormat, text: reasoningText, blocks: reasoningDetails, isComplete: false)
        do { try content.validate() } catch { throw ProviderProtocolError.resourceLimit }
        try yieldCanonical(.reasoning(content), to: continuation)
        reasoningPendingBytes = 0
        reasoningDetailsPendingBytes = 0
        emittedReasoningSnapshot = true
        lastReasoningEmission = .now
    }

    private mutating func finishReasoning(continuation: AsyncThrowingStream<CanonicalStreamEvent, any Error>.Continuation) throws {
        guard hasReasoning else { return }
        let content = ReasoningContent(format: reasoningFormat, text: reasoningText, blocks: reasoningDetails, isComplete: true)
        do { try content.validate() } catch { throw ProviderProtocolError.resourceLimit }
        try yieldCanonical(.reasoning(content), to: continuation)
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
    private var reasoningPendingBytes = 0
    private var emittedReasoningSnapshot = false
    private var lastReasoningEmission: ContinuousClock.Instant?
    private let names: ToolNameMap
    private let toolsEnabled: Bool
    private let protocolMode: ModelProtocolMode

    init(toolDefinitions: [ToolDefinition], toolsEnabled: Bool, protocolMode: ModelProtocolMode) {
        self.names = ToolNameMap(definitions: toolDefinitions)
        self.toolsEnabled = toolsEnabled
        self.protocolMode = protocolMode
    }

    var isFinished: Bool { sawStop }

    mutating func process(_ frame: SSEFrame, continuation: AsyncThrowingStream<CanonicalStreamEvent, any Error>.Continuation) throws {
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
                if let text = contentBlock.text, !text.isEmpty {
                    try flushReasoning(continuation: continuation)
                    try yieldText(text, to: continuation)
                }
            case "tool_use":
                guard toolsEnabled else { throw ProviderProtocolError.unsupportedTools }
                guard toolCalls.count < ProviderLimits.maxToolCalls else { throw ProviderProtocolError.resourceLimit }
                openBlockKind = .tool
                toolCalls[index] = try AnthropicToolAccumulator(id: contentBlock.id, name: contentBlock.name, input: contentBlock.input)
            case "thinking":
                openBlockKind = .thinking
                reasoningStarted = true
                if let text = contentBlock.thinking, !text.isEmpty {
                    guard reasoningText.utf8.count + text.utf8.count <= ProviderLimits.maxReasoningTextBytes else { throw ProviderProtocolError.resourceLimit }
                    reasoningText.append(text)
                    reasoningPendingBytes += text.utf8.count
                    try emitReasoningIfNeeded(continuation: continuation)
                }
            case "redacted_thinking":
                openBlockKind = .redactedThinking
                reasoningStarted = true
                reasoningPendingBytes += try JSONEncoder().encode(contentBlocks[index]).count
                try emitReasoningIfNeeded(continuation: continuation)
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
                    try flushReasoning(continuation: continuation)
                    try yieldText(text, to: continuation)
                    try appendBlockText(text, at: openBlockIndex!)
                }
            case (.tool, "input_json_delta"):
                try flushReasoning(continuation: continuation)
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
                    reasoningPendingBytes += text.utf8.count
                    let currentThinking = contentBlocks[openBlockIndex!]["thinking"]?.stringValue ?? ""
                    try appendBlockField("thinking", value: .string(currentThinking + text), at: openBlockIndex!)
                    try emitReasoningIfNeeded(continuation: continuation)
                }
            case (.thinking, "signature_delta"), (.redactedThinking, "signature_delta"):
                guard let signature = delta.signature else { throw ProviderProtocolError.malformed }
                let previousSignature = contentBlocks[openBlockIndex!]["signature"]?.stringValue ?? ""
                try appendBlockField("signature", value: .string(previousSignature + signature), at: openBlockIndex!)
                reasoningStarted = true
                reasoningPendingBytes += signature.utf8.count
                try emitReasoningIfNeeded(continuation: continuation)
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
            if finish == .toolCalls {
                let calls = try finalizeCalls()
                try emitReasoning(continuation: continuation, complete: true)
                try yieldCanonical(.toolCalls(calls), to: continuation)
            } else if !toolCalls.isEmpty {
                guard finish == .outputLimit else { throw ProviderProtocolError.malformed }
            }
            if finish != .toolCalls { try emitReasoning(continuation: continuation, complete: true) }
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

    private mutating func emitReasoningIfNeeded(continuation: AsyncThrowingStream<CanonicalStreamEvent, any Error>.Continuation) throws {
        guard !emittedReasoningSnapshot ||
                reasoningPendingBytes >= ProviderLimits.reasoningSnapshotBytes ||
                lastReasoningEmission.map({ ContinuousClock.now - $0 >= .milliseconds(100) }) == true else { return }
        try emitReasoning(continuation: continuation, complete: false)
    }

    mutating func flushReasoning(continuation: AsyncThrowingStream<CanonicalStreamEvent, any Error>.Continuation) throws {
        guard reasoningPendingBytes > 0 else { return }
        try emitReasoning(continuation: continuation, complete: false)
    }

    private mutating func emitReasoning(continuation: AsyncThrowingStream<CanonicalStreamEvent, any Error>.Continuation, complete: Bool) throws {
        guard reasoningStarted else { return }
        if complete { try validateAnthropicThinkingBlocks(contentBlocks) }
        let content = ReasoningContent(format: .anthropicBlocks, text: reasoningText, blocks: contentBlocks, isComplete: complete)
        do { try content.validate() } catch { throw ProviderProtocolError.resourceLimit }
        try yieldCanonical(.reasoning(content), to: continuation)
        reasoningPendingBytes = 0
        emittedReasoningSnapshot = true
        lastReasoningEmission = .now
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
private enum ProviderProtocolError: Error { case malformed, prematureEOF, provider, unsupportedTools, unsupportedReasoning, resourceLimit }

private enum ProviderLimits {
    static let maxToolCalls = 32
    static let maxToolJSONBytes = 65_536
    static let maxToolIDBytes = 256
    static let maxToolNameBytes = 128
    static let maxReasoningTextBytes = 2_097_152
    static let maxReasoningBlocks = 256
    static let maxReasoningDetails = 65_536
    static let maxReasoningPayloadBytes = 4_194_304
    static let reasoningSnapshotBytes = 4_096
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

private struct SSEFrame: Sendable {
    let event: String
    let data: String
}

private struct SSEParser {
    private var bytes: [UInt8] = []
    private var dataLines: [String] = []
    private var eventName = ""
    private var eventSize = 0
    private var totalSize = 0
    private let maxLineSize = 1_048_576
    private let maxEventSize = 4_194_304
    // Bound the complete wire response held by the parser. This is a stream
    // guardrail, not a license to persist provider data.
    private let maxTotalSize = 2_097_152

    mutating func feed(_ data: Data, emit: (SSEFrame) throws -> Void) throws {
        totalSize += data.count
        guard totalSize <= maxTotalSize else { throw ProviderProtocolError.malformed }
        bytes.append(contentsOf: data)
        while true {
            var delimiterIndex: Int?
            var delimiterLength = 1
            for index in bytes.indices {
                if bytes[index] == 10 { delimiterIndex = index; break }
                if bytes[index] == 13 {
                    guard index + 1 < bytes.count else { break }
                    delimiterIndex = index
                    delimiterLength = bytes[index + 1] == 10 ? 2 : 1
                    break
                }
            }
            guard let index = delimiterIndex else {
                guard bytes.count <= maxLineSize else { throw ProviderProtocolError.malformed }
                break
            }
            let line = Array(bytes[..<index])
            bytes.removeFirst(index + delimiterLength)
            try process(line, emit: emit)
        }
    }

    mutating func finish(emit: (SSEFrame) throws -> Void) throws {
        if !bytes.isEmpty {
            guard bytes.count <= maxLineSize else { throw ProviderProtocolError.malformed }
            let line = bytes
            bytes.removeAll(keepingCapacity: false)
            try process(line, emit: emit)
        }
        try dispatch(emit: emit)
    }

    private mutating func process(_ lineBytes: [UInt8], emit: (SSEFrame) throws -> Void) throws {
        guard let line = String(bytes: lineBytes, encoding: .utf8) else { throw ProviderProtocolError.malformed }
        if line.isEmpty { try dispatch(emit: emit); return }
        if line.first == ":" { return }
        let separator = line.firstIndex(of: ":")
        let field: String
        var value: String
        if let separator {
            field = String(line[..<separator])
            value = String(line[line.index(after: separator)...])
            if value.first == " " { value.removeFirst() }
        } else {
            field = line
            value = ""
        }
        switch field {
        case "event": eventName = value
        case "data":
            eventSize += value.utf8.count + (dataLines.isEmpty ? 0 : 1)
            guard eventSize <= maxEventSize else { throw ProviderProtocolError.malformed }
            dataLines.append(value)
        default: break
        }
    }

    private mutating func dispatch(emit: (SSEFrame) throws -> Void) throws {
        guard !dataLines.isEmpty else {
            eventName = ""
            eventSize = 0
            return
        }
        try emit(SSEFrame(event: eventName, data: dataLines.joined(separator: "\n")))
        eventName = ""
        dataLines.removeAll(keepingCapacity: true)
        eventSize = 0
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
    let thinking: OpenAIThinking?
    let reasoningEffort: String?
    let reasoning: OpenRouterReasoning?

    init(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) throws {
        self.model = route.modelID
        let names = ToolNameMap(definitions: request.tools ?? [])
        self.messages = try [OpenAIMessage(role: route.protocolMode == .openAI ? "developer" : "system", content: request.system, toolCalls: nil, toolCallID: nil, reasoning: nil, mode: route.protocolMode)] + request.messages.map {
            let calls = $0.toolCalls?.map { call in
                OpenAIToolCall(id: call.id, type: "function", function: OpenAIFunction(name: names.wireName(for: call.name), arguments: call.arguments))
            }
            let role: String
            switch $0.role {
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .tool: role = "tool"
            }
            return try OpenAIMessage(role: role, content: $0.text, toolCalls: calls, toolCallID: $0.toolCallID, reasoning: $0.reasoning, mode: route.protocolMode)
        }
        self.stream = true
        self.maxTokens = ProviderThinkingRules.usesCompletionTokenLimit(for: route) ? nil : route.maxOutputTokens
        self.maxCompletionTokens = ProviderThinkingRules.usesCompletionTokenLimit(for: route) ? route.maxOutputTokens : nil
        self.streamOptions = route.requestsUsage ? OpenAIStreamOptions(includeUsage: true) : nil
        self.tools = request.tools?.map { definition in
            OpenAIToolDefinition(type: "function", function: OpenAIFunctionDefinition(name: definition.wireName, description: definition.description, parameters: definition.inputSchema))
        }
        self.thinking = ProviderThinkingRules.openAIThinkingType(for: route).map {
            OpenAIThinking(type: $0, keep: ProviderThinkingRules.preservesKimiThinking(for: route) ? "all" : nil)
        }
        self.reasoningEffort = ProviderThinkingRules.openAIReasoningEffort(for: route)
        if let router = ProviderThinkingRules.openRouterReasoning(for: route) {
            self.reasoning = OpenRouterReasoning(enabled: router.enabled, effort: router.effort, maxTokens: router.maxTokens)
        } else {
            self.reasoning = nil
        }
    }
    enum CodingKeys: String, CodingKey { case model, messages, stream, maxTokens = "max_tokens", maxCompletionTokens = "max_completion_tokens", streamOptions = "stream_options", tools, thinking, reasoningEffort = "reasoning_effort", reasoning }
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

    init(role: String, content: String?, toolCalls: [OpenAIToolCall]?, toolCallID: String?, reasoning: ReasoningContent?, mode: ModelProtocolMode) throws {
        self.role = role; self.content = content; self.toolCalls = toolCalls; self.toolCallID = toolCallID
        var reasoningContent: String? = role == "assistant" && (mode == .deepSeek || mode == .kimi) ? "" : nil
        var reasoningDetails: [JSONValue]? = nil
        var reasoningText: String? = nil
        if role == "assistant", let reasoning {
            try reasoning.validate()
            if mode == .openRouter {
                guard reasoning.format == .openRouterDetails else { throw ProviderProtocolError.malformed }
            } else if mode != .standard {
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
    let thinking: AnthropicThinking?
    let outputConfig: AnthropicOutputConfig?
    init(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) throws {
        self.model = route.modelID
        self.messages = try AnthropicMessageBuilder.build(request.messages, definitions: request.tools ?? [])
        self.system = request.system
        self.maxTokens = route.maxOutputTokens
        self.stream = true
        self.tools = request.tools?.map { definition in
            AnthropicToolDefinition(name: definition.wireName, description: definition.description, inputSchema: definition.inputSchema)
        }
        if let thinking = ProviderThinkingRules.anthropicThinking(for: route) {
            self.thinking = AnthropicThinking(type: thinking.type, budgetTokens: thinking.budgetTokens)
        } else {
            self.thinking = nil
        }
        self.outputConfig = ProviderThinkingRules.anthropicOutputEffort(for: route).map { AnthropicOutputConfig(effort: $0) }
    }
    enum CodingKeys: String, CodingKey { case model, messages, system, maxTokens = "max_tokens", stream, tools, thinking; case outputConfig = "output_config" }
}
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
    static func build(_ messages: [CanonicalMessage], definitions: [ToolDefinition]) throws -> [AnthropicMessage] {
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
                guard let id = message.toolCallID, !id.isEmpty else { throw ProviderProtocolError.malformed }
                pendingResults.append(.toolResult(id: id, content: message.text))
                continue
            }
            flushResults()
            if message.role == .assistant, let reasoning = message.reasoning {
                try validateAnthropicReplay(reasoning, message: message, names: names)
                result.append(AnthropicMessage(role: "assistant", content: .blocks(reasoning.blocks.map(AnthropicContentBlock.raw))))
            } else if message.role == .assistant, let calls = message.toolCalls, !calls.isEmpty {
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

    private static func validateAnthropicReplay(_ reasoning: ReasoningContent, message: CanonicalMessage, names: ToolNameMap) throws {
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
        guard text == message.text, calls.count == (message.toolCalls?.count ?? 0) else { throw ProviderProtocolError.malformed }
        for (actual, expected) in zip(calls, message.toolCalls ?? []) {
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
