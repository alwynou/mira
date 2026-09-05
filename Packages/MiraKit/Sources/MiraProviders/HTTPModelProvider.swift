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

    public func stream(request: CanonicalModelRequest, route: ModelRoute) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        // Validate before constructing a request or reading Keychain. This is
        // also a defense against callers accidentally using an incomplete route.
        let endpoint: URL
        do {
            try route.validateForSending()
            endpoint = try route.validatedEndpoint()
            guard route.providerKind == .openAICompatible || route.providerKind == .anthropic else {
                throw MiraError(.unsupported, "此服务协议暂不支持。")
            }
        } catch {
            let safe = error as? MiraError ?? MiraError(.configuration, "服务配置无效。")
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
                        throw MiraError(.credentialMissing, "服务凭据不可用。")
                    }
                    guard !secret.isEmpty else { throw MiraError(.credentialMissing, "服务凭据不可用。") }
                    let urlRequest = try makeURLRequest(request: request, route: route, endpoint: endpoint, secret: secret)
                    activeRequest = urlRequest
                    try await run(urlRequest: urlRequest, route: route, continuation: continuation)
                    continuation.finish()
                } catch {
                    if let activeRequest { cancelTransport(for: activeRequest) }
                    if Task.isCancelled || error is CancellationError {
                        continuation.finish(throwing: MiraError(.cancelled, "已停止生成。"))
                    } else {
                        continuation.finish(throwing: safeProviderError(error))
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func makeURLRequest(request: CanonicalModelRequest, route: ModelRoute, endpoint: URL, secret: String) throws -> URLRequest {
        var result = URLRequest(url: endpoint)
        result.httpMethod = "POST"
        result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Gives the optional transport cancellation seam a unique, opaque
        // per-execution identity without putting secrets or user content in it.
        result.setValue(request.executionID.rawValue.uuidString, forHTTPHeaderField: "X-Mira-Request-ID")
        if route.providerKind == .openAICompatible {
            result.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            result.httpBody = try JSONEncoder().encode(OpenAIRequest(request: request, model: route.modelID, maxTokens: route.maxOutputTokens, includeUsage: route.requestsUsage))
        } else {
            result.setValue(secret, forHTTPHeaderField: "x-api-key")
            result.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            result.httpBody = try JSONEncoder().encode(AnthropicRequest(request: request, model: route.modelID, maxTokens: route.maxOutputTokens))
        }
        return result
    }

    private func run(
        urlRequest: URLRequest,
        route: ModelRoute,
        continuation: AsyncThrowingStream<CanonicalStreamEvent, any Error>.Continuation
    ) async throws {
        let input = transport.stream(request: urlRequest)
        var responseReceived = false
        var parser = SSEParser()
        var protocolFinished = false
        var openAIState = OpenAIStreamState()
        var anthropicState = AnthropicStreamState()

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

private struct OpenAIStreamState {
    private var finish: StreamFinishReason?
    private var sawDone = false
    private var usage: TokenUsage?
    private let decoder = JSONDecoder()

    var isFinished: Bool { sawDone }

    mutating func process(_ frame: SSEFrame, continuation: AsyncThrowingStream<CanonicalStreamEvent, any Error>.Continuation) throws {
        if frame.data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            guard !sawDone, finish != nil else { throw ProviderProtocolError.malformed }
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
            let next = TokenUsage(inputTokens: reported.promptTokens, outputTokens: reported.completionTokens)
            // Provider usage reports are cumulative snapshots. Never add them.
            if usage != next {
                usage = next
                try yieldCanonical(.usage(next), to: continuation)
            }
        }
        guard (chunk.choices?.count ?? 0) <= 1 else { throw ProviderProtocolError.malformed }
        for choice in chunk.choices ?? [] {
            if let delta = choice.delta {
                if finish != nil && (delta.content != nil || delta.toolCalls != nil || delta.functionCall != nil || choice.finishReason != nil) {
                    throw ProviderProtocolError.malformed
                }
                if delta.toolCalls?.isEmpty == false || delta.functionCall != nil {
                    throw ProviderProtocolError.unsupportedTools
                }
                if let text = delta.content, !text.isEmpty { try yieldText(text, to: continuation) }
            }
            if let reason = choice.finishReason {
                guard finish == nil else { throw ProviderProtocolError.malformed }
                switch reason {
                case "stop": finish = .stop
                case "length": finish = .outputLimit
                default: throw ProviderProtocolError.provider
                }
            }
        }
    }
}

private struct AnthropicStreamState {
    private let decoder = JSONDecoder()
    private var started = false
    private var sawStop = false
    private var textBlockOpen = false
    private var finish: StreamFinishReason?
    private var inputTokens: Int?
    private var outputTokens: Int?
    private var lastUsage: TokenUsage?
    private var nextBlockIndex = 0
    private var openBlockIndex: Int?

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
            let current = TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
            if message.usage != nil {
                lastUsage = current
                try yieldCanonical(.usage(current), to: continuation)
            }
        case "content_block_start":
            guard started, !sawStop else { throw ProviderProtocolError.malformed }
            let value: AnthropicContentBlockStart
            do { value = try decoder.decode(AnthropicContentBlockStart.self, from: Data(frame.data.utf8)) }
            catch { throw ProviderProtocolError.malformed }
            guard let contentBlock = value.contentBlock else { throw ProviderProtocolError.malformed }
            guard contentBlock.type == "text" else { throw ProviderProtocolError.unsupportedTools }
            guard let index = value.index, index == nextBlockIndex, openBlockIndex == nil else { throw ProviderProtocolError.malformed }
            textBlockOpen = true
            openBlockIndex = index
            if let text = contentBlock.text, !text.isEmpty { try yieldText(text, to: continuation) }
        case "content_block_delta":
            guard started, textBlockOpen, !sawStop else { throw ProviderProtocolError.malformed }
            let value: AnthropicContentBlockDelta
            do { value = try decoder.decode(AnthropicContentBlockDelta.self, from: Data(frame.data.utf8)) }
            catch { throw ProviderProtocolError.malformed }
            guard value.index == openBlockIndex else { throw ProviderProtocolError.malformed }
            guard let delta = value.delta else { throw ProviderProtocolError.malformed }
            guard delta.type == "text_delta" else { throw ProviderProtocolError.unsupportedTools }
            if let text = delta.text, !text.isEmpty { try yieldText(text, to: continuation) }
        case "content_block_stop":
            guard started, textBlockOpen else { throw ProviderProtocolError.malformed }
            let value: AnthropicContentBlockStop
            do { value = try decoder.decode(AnthropicContentBlockStop.self, from: Data(frame.data.utf8)) }
            catch { throw ProviderProtocolError.malformed }
            guard value.index == openBlockIndex else { throw ProviderProtocolError.malformed }
            textBlockOpen = false
            openBlockIndex = nil
            nextBlockIndex += 1
        case "message_delta":
            guard started, !sawStop else { throw ProviderProtocolError.malformed }
            let value: AnthropicMessageDelta
            do { value = try decoder.decode(AnthropicMessageDelta.self, from: Data(frame.data.utf8)) }
            catch { throw ProviderProtocolError.malformed }
            guard let delta = value.delta else { throw ProviderProtocolError.malformed }
            if let reason = delta.stopReason {
                switch reason {
                case "end_turn", "stop_sequence": finish = .stop
                case "max_tokens": finish = .outputLimit
                default: throw ProviderProtocolError.provider
                }
            }
            if let reported = value.usage {
                if let input = reported.inputTokens { inputTokens = input }
                if let output = reported.outputTokens { outputTokens = output }
                let current = TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
                if lastUsage != current {
                    lastUsage = current
                    try yieldCanonical(.usage(current), to: continuation)
                }
            }
        case "message_stop":
            guard started, !sawStop, finish != nil, !textBlockOpen else { throw ProviderProtocolError.malformed }
            sawStop = true
            try yieldCanonical(.finished(finish!), to: continuation)
        default: break
        }
    }
}

private func safeProviderError(_ error: any Error) -> MiraError {
    if let error = error as? MiraError { return error }
    if error is CancellationError { return MiraError(.cancelled, "已停止生成。") }
    if let status = error as? HTTPStatusError {
        switch status.statusCode {
        case 401, 403: return MiraError(.unauthorized, "服务凭据未被接受。")
        case 429: return MiraError(.rateLimited, "服务请求过于频繁，请稍后重试。")
        case 500...599: return MiraError(.network, "服务暂时不可用，请稍后重试。")
        default: return MiraError(.providerRejected, "服务拒绝了请求。")
        }
    }
    if let error = error as? ProviderProtocolError {
        switch error {
        case .unsupportedTools: return MiraError(.unsupported, "此请求包含当前服务不支持的工具内容。")
        case .provider: return MiraError(.providerRejected, "服务拒绝了请求。")
        case .prematureEOF: return MiraError(.interrupted, "服务连接在生成完成前中断。")
        case .malformed: return MiraError(.malformedStream, "服务返回了无法解析的流。")
        case .resourceLimit: return MiraError(.malformedStream, "服务流超出了大小限制。")
        }
    }
    if let urlError = error as? URLError, urlError.code == .cancelled { return MiraError(.cancelled, "已停止生成。") }
    return MiraError(.network, "无法连接到服务，请稍后重试。")
}

private struct HTTPStatusError: Error { let statusCode: Int }
private enum ProviderProtocolError: Error { case malformed, prematureEOF, provider, unsupportedTools, resourceLimit }

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
    let maxTokens: Int
    let streamOptions: OpenAIStreamOptions?

    init(request: CanonicalModelRequest, model: String, maxTokens: Int, includeUsage: Bool) {
        self.model = model
        self.messages = [OpenAIMessage(role: "system", content: request.system)] + request.messages.map { OpenAIMessage(role: $0.role.rawValue, content: $0.text) }
        self.stream = true
        self.maxTokens = maxTokens
        self.streamOptions = includeUsage ? OpenAIStreamOptions(includeUsage: true) : nil
    }
    enum CodingKeys: String, CodingKey { case model, messages, stream, maxTokens = "max_tokens", streamOptions = "stream_options" }
}
private struct OpenAIStreamOptions: Encodable { let includeUsage: Bool; enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" } }
private struct OpenAIMessage: Encodable { let role: String; let content: String }

private struct OpenAIChunk: Decodable {
    let choices: [OpenAIChoice]?
    let usage: OpenAIUsage?
    let error: OpenAIError?
}
private struct OpenAIChoice: Decodable { let delta: OpenAIDelta?; let finishReason: String?; enum CodingKeys: String, CodingKey { case delta; case finishReason = "finish_reason" } }
private struct OpenAIDelta: Decodable { let content: String?; let toolCalls: [OpenAIToolCall]?; let functionCall: OpenAIFunctionCall?; enum CodingKeys: String, CodingKey { case content; case toolCalls = "tool_calls"; case functionCall = "function_call" } }
private struct OpenAIToolCall: Decodable { let id: String?; let type: String?; let function: OpenAIFunctionCall? }
private struct OpenAIFunctionCall: Decodable { let name: String?; let arguments: String? }
private struct OpenAIUsage: Decodable { let promptTokens: Int?; let completionTokens: Int?; enum CodingKeys: String, CodingKey { case promptTokens = "prompt_tokens"; case completionTokens = "completion_tokens" } }
private struct OpenAIError: Decodable { let message: String?; let type: String? }

private struct AnthropicRequest: Encodable {
    let model: String
    let messages: [AnthropicMessage]
    let system: String
    let maxTokens: Int
    let stream: Bool
    init(request: CanonicalModelRequest, model: String, maxTokens: Int) {
        self.model = model
        self.messages = request.messages.map { AnthropicMessage(role: $0.role.rawValue, content: $0.text) }
        self.system = request.system
        self.maxTokens = maxTokens
        self.stream = true
    }
    enum CodingKeys: String, CodingKey { case model, messages, system, maxTokens = "max_tokens", stream }
}
private struct AnthropicMessage: Encodable { let role: String; let content: String }
private struct AnthropicMessageStart: Decodable { let message: AnthropicMessageEnvelope? }
private struct AnthropicMessageEnvelope: Decodable { let usage: AnthropicUsage? }
private struct AnthropicUsage: Decodable { let inputTokens: Int?; let outputTokens: Int?; enum CodingKeys: String, CodingKey { case inputTokens = "input_tokens"; case outputTokens = "output_tokens" } }
private struct AnthropicContentBlockStart: Decodable { let index: Int?; let contentBlock: AnthropicContentBlock?; enum CodingKeys: String, CodingKey { case index; case contentBlock = "content_block" } }
private struct AnthropicContentBlock: Decodable { let type: String?; let text: String? }
private struct AnthropicContentBlockDelta: Decodable { let index: Int?; let delta: AnthropicDelta? }
private struct AnthropicDelta: Decodable { let type: String?; let text: String?; let stopReason: String?; enum CodingKeys: String, CodingKey { case type, text; case stopReason = "stop_reason" } }
private struct AnthropicMessageDelta: Decodable { let delta: AnthropicDelta?; let usage: AnthropicUsage? }
private struct AnthropicContentBlockStop: Decodable { let index: Int? }
