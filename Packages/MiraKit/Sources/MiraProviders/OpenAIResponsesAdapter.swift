import Foundation
import MiraCore

/// OpenAI Responses is a separate protocol adapter. It always uses
/// `store:false`; Mira owns the ordered input/output item history and carries
/// encrypted reasoning items in an opaque continuation.
public struct OpenAIResponsesAdapter: AgentModelAdapter {
    public let identity = HTTPAdapterIdentity.responses
    private let credentials: any CredentialReader
    private let transport: any HTTPStreamingTransport
    private let now: @Sendable () -> Date

    public init(credentials: any CredentialReader,
                transport: any HTTPStreamingTransport = URLSessionStreamingTransport(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials; self.transport = transport; self.now = now
    }

    public func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        let policy = try policy(route)
        try validateProviderApplicationContext(input)
        try input.validate(for: route)
        try validateResponseWireNames(input)
        guard route.credential != nil else { throw MiraError(.credentialMissing, "The provider credential is unavailable.") }
        let payload = try makePayload(input: input, policy: policy)
        let bytes = try SessionCodec.encode(payload)
        let estimated = bytes.count + 32 * (input.messages.count + input.tools.count) + 256
        let prepared = AgentPreparedModelRequest(adapter: identity, input: input, wirePayload: payload,
                                                 estimatedInputTokens: estimated)
        try prepared.validate(for: route)
        return prepared
    }

    public func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        let (events, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        let task = Task {
            var operation: HTTPTransportOperation?
            do {
                try Task.checkCancellation()
                guard try prepare(request.input, route: route) == request else {
                    throw MiraError(.conflict, "The provider request differs from its frozen preparation.")
                }
                let policy = try self.policy(route)
                let endpoint = try policy.configuration.validatedEndpoint()
                guard let credential = route.credential else { throw MiraError(.credentialMissing, "The provider credential is unavailable.") }
                let secret: String
                do { secret = try credentials.read(reference: credential.reference, version: credential.version) }
                catch { throw MiraError(.credentialMissing, "The provider credential is unavailable.") }
                guard !secret.isEmpty, !secret.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    throw MiraError(.credentialMissing, "The provider credential is unavailable.")
                }
                var urlRequest = URLRequest(url: endpoint)
                urlRequest.httpMethod = "POST"
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                urlRequest.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
                urlRequest.setValue(request.input.stepID.uuidString, forHTTPHeaderField: "X-Mira-Request-ID")
                urlRequest.httpBody = try SessionCodec.encode(request.wirePayload)
                operation = transport.stream(request: urlRequest)
                try await parse(operation!.events, route: route, tools: request.input.tools, continuation: continuation)
                await operation!.close()
                continuation.finish()
            } catch {
                if let operation { await operation.close() }
                if Task.isCancelled || error is CancellationError {
                    continuation.finish(throwing: AgentModelFailure(error: MiraError(.cancelled, "Generation was stopped.")))
                } else if let failure = error as? AgentModelFailure {
                    continuation.finish(throwing: failure)
                } else {
                let safe = responsesError(error)
                let retry: AgentModelRetryAdvice?
                if let status = error as? ResponsesHTTPStatusError,
                   [408, 429, 500, 502, 503, 504].contains(status.statusCode) {
                    retry = retryAdvice(headers: status.headers, now: now)
                } else {
                    retry = nil
                }
                continuation.finish(throwing: AgentModelFailure(error: safe, retryAdvice: retry))
                }
            }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return AgentModelOperation(events: events) { task.cancel(); await task.value }
    }

    public func replay(_ messages: [AgentModelMessage], from source: AgentModelRoute,
                       to target: AgentModelRoute, boundary: AgentReplayBoundary) throws -> AgentReplayDecision {
        _ = try policy(target)
        if boundary == .sameExecution {
            guard source == target else { throw MiraError(.conflict, "The current provider continuation cannot change routes.") }
            for message in messages {
                try message.continuation?.validate()
                guard message.continuation?.adapter == identity || message.continuation == nil else {
                    throw MiraError(.malformedStream, "The model continuation belongs to a different adapter.")
                }
            }
            return .include(messages)
        }
        guard source.adapter == target.adapter, source.connectionID == target.connectionID,
              source.modelID == target.modelID,
              source.modelDescriptorID == target.modelDescriptorID,
              source.invocationID == target.invocationID,
              source.endpointID == target.endpointID,
              source.configuration["protocolID"] == target.configuration["protocolID"],
              source.configuration["dialectProfileID"] == target.configuration["dialectProfileID"] else {
            return .include(Self.withoutContinuation(messages))
        }
        let sourcePolicy = try policy(source)
        let targetPolicy = try policy(target)
        guard try sourcePolicy.configuration.validatedEndpoint() == targetPolicy.configuration.validatedEndpoint() else {
            return .include(Self.withoutContinuation(messages))
        }
        return .include(messages)
    }

    private func policy(_ route: AgentModelRoute) throws -> HTTPModelPolicy {
        let policy = try HTTPModelPolicy(route: route)
        guard policy.protocolID == .responses, policy.dialectProfileID == .openAI,
              route.adapter == identity else {
            throw MiraError(.configuration, "The frozen route is not an OpenAI Responses invocation.")
        }
        return policy
    }

    private func makePayload(input: AgentModelInput, policy: HTTPModelPolicy) throws -> JSONValue {
        var fields: [String: JSONValue] = [
            "model": .string(policy.modelID),
            "instructions": .string(input.instructions),
            "input": .array(try inputItems(input.messages, tools: input.tools)),
            "stream": .bool(true),
            "store": .bool(false),
            "include": .array([.string("reasoning.encrypted_content")]),
            "max_output_tokens": .number(Double(policy.maximumOutputTokens))
        ]
        if let effort = policy.thinking.effort {
            fields["reasoning"] = .object(["effort": .string(effort.rawValue)])
        } else if policy.thinking.mode == .disabled {
            fields["reasoning"] = .object(["effort": .string("none")])
        }
        let toolValues = input.tools.map { definition in
            JSONValue.object([
                "type": .string("function"), "name": .string(ResponsesToolNameMap(definitions: input.tools).wireName(for: definition.name)),
                "description": .string(definition.description), "parameters": definition.inputSchema
            ])
        }
        if !toolValues.isEmpty { fields["tools"] = .array(toolValues) }
        return .object(fields)
    }

    private func inputItems(_ messages: [AgentModelMessage], tools: [ToolDefinition]) throws -> [JSONValue] {
        let names = ResponsesToolNameMap(definitions: tools)
        var items: [JSONValue] = []
        for message in messages {
            if message.role == .tool {
                for result in message.toolResults {
                    items.append(.object(["type": .string("function_call_output"), "call_id": .string(result.callID), "output": .string(result.text)]))
                }
                continue
            }
            if message.role == .assistant, let continuation = message.continuation {
                guard continuation.adapter == identity,
                      continuation.format == "openai.responses.items",
                      case .array(let rawItems) = continuation.payload,
                      continuation.isComplete else { throw ResponsesProtocolError.malformed }
                try validateResponseHistory(message: message, rawItems: rawItems, names: names)
                items.append(contentsOf: rawItems)
                continue
            }
            let role = message.role == .assistant ? "assistant" : "user"
            if !message.text.isEmpty {
                items.append(.object(["type": .string("message"), "role": .string(role),
                                     "content": .array([.object(["type": .string(role == "assistant" ? "output_text" : "input_text"), "text": .string(message.text)])])]))
            }
            for call in message.toolCalls {
                items.append(.object(["type": .string("function_call"), "call_id": .string(call.id),
                                     "name": .string(names.wireName(for: call.name)), "arguments": .string(call.arguments)]))
            }
        }
        return items
    }

    private func validateResponseHistory(message: AgentModelMessage, rawItems: [JSONValue], names: ResponsesToolNameMap) throws {
        guard rawItems.count <= ResponsesStreamLimits.maxItems,
              try SessionCodec.encode(JSONValue.array(rawItems)).count <= ResponsesStreamLimits.maxRawBytes else {
            throw ResponsesProtocolError.resourceLimit
        }
        var visibleText = ""
        var calls: [CanonicalToolCall] = []
        for item in rawItems {
            guard case .object(let fields) = item, let type = fields["type"]?.stringValue else {
                throw ResponsesProtocolError.malformed
            }
            switch type {
            case "message":
                guard let content = fields["content"], case .array(let parts) = content else { continue }
                for part in parts {
                    switch part["type"]?.stringValue {
                    case "output_text":
                        guard let text = part["text"]?.stringValue else { throw ResponsesProtocolError.malformed }
                        visibleText.append(text)
                    case "refusal":
                        guard let refusal = part["refusal"]?.stringValue else { throw ResponsesProtocolError.malformed }
                        visibleText.append(refusal)
                    default:
                        continue
                    }
                }
            case "function_call":
                guard let callID = fields["call_id"]?.stringValue, !callID.isEmpty,
                      let name = fields["name"]?.stringValue, !name.isEmpty,
                      let arguments = fields["arguments"]?.stringValue else { throw ResponsesProtocolError.malformed }
                calls.append(CanonicalToolCall(id: callID, name: try names.internalName(for: name), arguments: arguments))
            default: continue
            }
        }
        guard visibleText == message.text, calls == message.toolCalls else {
            throw ResponsesProtocolError.malformed
        }
    }

    private static func withoutContinuation(_ messages: [AgentModelMessage]) -> [AgentModelMessage] {
        messages.map { message in
            .init(role: message.role,
                  blocks: message.blocks.filter { if case .thinking = $0.content { return false }; return true },
                  continuation: nil)
        }
    }
}

private extension OpenAIResponsesAdapter {
    func parse(_ input: AsyncThrowingStream<HTTPTransportEvent, any Error>, route: AgentModelRoute,
               tools: [ToolDefinition],
               continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation) async throws {
        var responseReceived = false
        var parser = ResponsesSSEParser()
        var state = ResponsesStreamState(adapter: identity, toolDefinitions: route.capabilities.callsTools ? tools : [])
        func process(_ frame: ResponsesSSEFrame) throws { try state.process(frame, continuation: continuation) }
        for try await event in input {
            try Task.checkCancellation()
            switch event {
            case .response(let response):
                guard !responseReceived else { throw ResponsesProtocolError.malformed }
                responseReceived = true
                guard (200..<300).contains(response.statusCode) else { throw ResponsesHTTPStatusError(statusCode: response.statusCode, headers: response.headers) }
            case .bytes(let data):
                guard responseReceived else { throw ResponsesProtocolError.malformed }
                try parser.feed(data, emit: process)
            case .end:
                try parser.finish(emit: process)
                guard state.finished else { throw ResponsesProtocolError.prematureEOF }
                return
            }
        }
        throw ResponsesProtocolError.prematureEOF
    }
}

private enum ResponsesStreamLimits {
    static let maxItems = 64
    static let maxArgumentsBytes = 65_536
    static let maxRawBytes = 4_194_304
}

private struct ResponsesStreamState {
    let adapter: AgentAdapterIdentity
    let toolNames: ResponsesToolNameMap
    var items: [String: JSONValue] = [:]
    var itemOrder: [String] = []
    var textStarted = Set<String>()
    var thinkingStarted = Set<String>()
    var arguments: [String: String] = [:]
    var calls: [String: CanonicalToolCall] = [:]
    var functionCallIDs = Set<String>()
    var pendingFunctionCalls = Set<String>()
    var deferredIDs = Set<String>()
    var completedItems = Set<String>()
    var responseID: String?
    var usage: TokenUsage?
    var finished = false

    init(adapter: AgentAdapterIdentity, toolDefinitions: [ToolDefinition]) {
        self.adapter = adapter
        self.toolNames = ResponsesToolNameMap(definitions: toolDefinitions)
    }

    mutating func process(_ frame: ResponsesSSEFrame, continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation) throws {
        guard !finished else { throw ResponsesProtocolError.malformed }
        guard let data = frame.data.data(using: .utf8), let value = try? SessionCodec.decode(JSONValue.self, from: data),
              case .object(let object) = value, let type = object["type"]?.stringValue else {
            throw ResponsesProtocolError.malformed
        }
        switch type {
        case "response.created", "response.in_progress":
            guard let response = object["response"],
                  let id = response["id"]?.stringValue, !id.isEmpty,
                  response["type"]?.stringValue == "response" else { throw ResponsesProtocolError.malformed }
            if let responseID, responseID != id { throw ResponsesProtocolError.malformed }
            responseID = id
            if let status = response["status"]?.stringValue {
                guard ["queued", "in_progress"].contains(status) else { throw ResponsesProtocolError.malformed }
            }
        case "response.output_item.added":
            guard let item = object["item"], let id = item["id"]?.stringValue, !id.isEmpty,
                  items[id] == nil, itemOrder.count < ResponsesStreamLimits.maxItems else { throw ResponsesProtocolError.malformed }
            if item["type"]?.stringValue == "function_call" {
                functionCallIDs.insert(id)
                pendingFunctionCalls.insert(id)
            } else if hasEarlierFunctionCall {
                // Visible items after a function call are buffered until the
                // terminal boundary, where canonical item order is known.
                deferredIDs.insert(id)
            }
            items[id] = item
            itemOrder.append(id)
            try validateRawBounds()
            if item["type"]?.stringValue == "message", !deferredIDs.contains(id) { try startText(id: id, continuation: continuation) }
            if item["type"]?.stringValue == "reasoning", !deferredIDs.contains(id) { try startThinking(id: id, continuation: continuation) }
        case "response.output_text.delta":
            guard let id = object["item_id"]?.stringValue, let delta = object["delta"]?.stringValue,
                  itemType(id) == "message" else { throw ResponsesProtocolError.malformed }
            try appendMessageText(id: id, delta: delta)
            if !deferredIDs.contains(id) {
                try startText(id: id, continuation: continuation)
                try yield(.blockDelta(id: id, text: delta), to: continuation)
            }
        case "response.output_text.done":
            guard let id = object["item_id"]?.stringValue,
                  let text = object["text"]?.stringValue,
                  itemType(id) == "message" else { throw ResponsesProtocolError.malformed }
            try setVisiblePart(id: id, type: "output_text", text: text)
        case "response.refusal.delta":
            guard let id = object["item_id"]?.stringValue, let delta = object["delta"]?.stringValue,
                  itemType(id) == "message" else { throw ResponsesProtocolError.malformed }
            try appendVisiblePart(id: id, type: "refusal", text: delta)
            if !deferredIDs.contains(id) {
                try startText(id: id, continuation: continuation)
                try yield(.blockDelta(id: id, text: delta), to: continuation)
            }
        case "response.refusal.done":
            guard let id = object["item_id"]?.stringValue,
                  let refusal = object["refusal"]?.stringValue,
                  itemType(id) == "message" else { throw ResponsesProtocolError.malformed }
            if let existing = refusalText(id: id) {
                guard existing == refusal else { throw ResponsesProtocolError.malformed }
            } else {
                try setVisiblePart(id: id, type: "refusal", text: refusal)
            }
        case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
            guard let id = object["item_id"]?.stringValue, let delta = object["delta"]?.stringValue,
                  itemType(id) == "reasoning" else { throw ResponsesProtocolError.malformed }
            try appendReasoningText(id: id, delta: delta)
            if !deferredIDs.contains(id) {
                try startThinking(id: id, continuation: continuation)
                try yield(.blockDelta(id: id, text: delta), to: continuation)
            }
        case "response.function_call_arguments.delta":
            guard let id = object["item_id"]?.stringValue, let delta = object["delta"]?.stringValue,
                  itemType(id) == "function_call", !completedItems.contains(id) else { throw ResponsesProtocolError.malformed }
            var value = arguments[id, default: ""]
            value.append(delta)
            guard value.utf8.count <= ResponsesStreamLimits.maxArgumentsBytes else { throw ResponsesProtocolError.resourceLimit }
            arguments[id] = value
            try appendFunctionArguments(id: id, value: value)
        case "response.output_item.done":
            guard let item = object["item"], let id = item["id"]?.stringValue,
                  items[id] != nil, !completedItems.contains(id) else { throw ResponsesProtocolError.malformed }
            if item["type"]?.stringValue == "function_call" {
                guard let callID = item["call_id"]?.stringValue, !callID.isEmpty,
                      let arguments = item["arguments"]?.stringValue,
                      item["name"]?.stringValue?.isEmpty == false else { throw ResponsesProtocolError.malformed }
                try validateToolArguments(arguments)
            }
            try mergeItem(id: id, item: item)
            completedItems.insert(id)
            if itemType(id) == "function_call" { try finishCall(item: items[id]!, id: id) }
            else if !deferredIDs.contains(id), textStarted.contains(id) { try yield(.blockFinished(id: id), to: continuation) }
            else if !deferredIDs.contains(id), thinkingStarted.contains(id) { try yield(.blockFinished(id: id), to: continuation) }
            pendingFunctionCalls.remove(id)
        case "response.completed":
            try finishResponse(object["response"], reason: .stop, continuation: continuation)
        case "response.incomplete":
            try finishResponse(object["response"], reason: .outputLimit, continuation: continuation, complete: false)
        case "response.failed": throw ResponsesProtocolError.provider
        default: break
        }
    }

    private mutating func startText(id: String, continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation) throws {
        guard textStarted.insert(id).inserted else { return }
        try yield(.blockStarted(.init(id: id, content: .text(""))), to: continuation)
    }
    private mutating func startThinking(id: String, continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation) throws {
        guard thinkingStarted.insert(id).inserted else { return }
        try yield(.blockStarted(.init(id: id, content: .thinking(""))), to: continuation)
    }
    private func itemType(_ id: String) -> String? {
        items[id]?["type"]?.stringValue
    }

    private var hasEarlierFunctionCall: Bool {
        !functionCallIDs.isEmpty
    }

    private func hasEarlierFunctionCall(id: String) -> Bool {
        guard let index = itemOrder.firstIndex(of: id) else { return true }
        return functionCallIDs.contains { pendingID in
            guard let pendingIndex = itemOrder.firstIndex(of: pendingID) else { return true }
            return pendingIndex < index
        }
    }

    private mutating func appendMessageText(id: String, delta: String) throws {
        try appendVisiblePart(id: id, type: "output_text", text: delta)
    }

    private mutating func appendVisiblePart(id: String, type: String, text: String) throws {
        guard case .object(var item) = items[id] else { throw ResponsesProtocolError.malformed }
        var parts: [JSONValue] = []
        if case .array(let existing) = item["content"] { parts = existing }
        if let index = parts.firstIndex(where: { $0["type"]?.stringValue == type }) {
            guard case .object(var part) = parts[index] else { throw ResponsesProtocolError.malformed }
            let key = type == "refusal" ? "refusal" : "text"
            let prior = part[key]?.stringValue ?? ""
            part[key] = .string(prior + text)
            parts[index] = .object(part)
        } else {
            let key = type == "refusal" ? "refusal" : "text"
            parts.append(.object(["type": .string(type), key: .string(text)]))
        }
        item["content"] = .array(parts)
        items[id] = .object(item)
        try validateRawBounds()
    }

    private mutating func setVisiblePart(id: String, type: String, text: String) throws {
        guard case .object(var item) = items[id] else { throw ResponsesProtocolError.malformed }
        var parts: [JSONValue] = []
        if case .array(let existing) = item["content"] { parts = existing }
        guard let index = parts.firstIndex(where: { $0["type"]?.stringValue == type }) else {
            try appendVisiblePart(id: id, type: type, text: text); return
        }
        guard case .object(var part) = parts[index] else { throw ResponsesProtocolError.malformed }
        let key = type == "refusal" ? "refusal" : "text"
        guard part[key]?.stringValue == nil || part[key]?.stringValue == text else { throw ResponsesProtocolError.malformed }
        part[key] = .string(text)
        parts[index] = .object(part)
        item["content"] = .array(parts)
        items[id] = .object(item)
        try validateRawBounds()
    }

    private func refusalText(id: String) -> String? {
        guard case .array(let parts) = items[id]?["content"] else { return nil }
        return parts.compactMap { part in
            part["type"]?.stringValue == "refusal" ? part["refusal"]?.stringValue : nil
        }.joined()
    }
    private mutating func appendReasoningText(id: String, delta: String) throws {
        guard case .object(var item) = items[id] else { throw ResponsesProtocolError.malformed }
        var summary = ""
        if case .array(let parts) = item["summary"] {
            summary = parts.compactMap { part in
                part["type"]?.stringValue == "summary_text" ? part["text"]?.stringValue : nil
            }.joined()
        }
        item["summary"] = .array([.object(["type": .string("summary_text"), "text": .string(summary + delta)])])
        items[id] = .object(item)
        try validateRawBounds()
    }
    private mutating func appendFunctionArguments(id: String, value: String) throws {
        guard case .object(var item) = items[id] else { throw ResponsesProtocolError.malformed }
        item["arguments"] = .string(value)
        items[id] = .object(item)
        try validateRawBounds()
    }
    private mutating func mergeItem(id: String, item: JSONValue) throws {
        guard case .object(let incoming) = item,
              case .object(var previous) = items[id],
              incoming["id"]?.stringValue == id,
              incoming["type"]?.stringValue == previous["type"]?.stringValue else { throw ResponsesProtocolError.malformed }
        for (key, value) in incoming {
            if let prior = previous[key] {
                switch key {
                case "content":
                    guard try visibleContentText(prior) == visibleContentText(value) else { throw ResponsesProtocolError.malformed }
                case "summary":
                    if prior != .null {
                        guard try summaryText(prior) == summaryText(value) else { throw ResponsesProtocolError.malformed }
                    }
                case "encrypted_content":
                    guard encryptedContentMatches(prior, value) else { throw ResponsesProtocolError.malformed }
                case "id", "type", "role", "arguments", "call_id", "name":
                    guard prior == value else { throw ResponsesProtocolError.malformed }
                default:
                    break
                }
            }
            previous[key] = value
        }
        if incoming["content"] == nil, let value = previous["content"] { previous["content"] = value }
        if incoming["arguments"] == nil, let value = previous["arguments"] { previous["arguments"] = value }
        items[id] = .object(previous)
        try validateRawBounds()
    }

    private func visibleContentText(_ value: JSONValue) throws -> String {
        guard case .array(let parts) = value else { throw ResponsesProtocolError.malformed }
        var result = ""
        for part in parts {
            guard case .object = part, let type = part["type"]?.stringValue else { throw ResponsesProtocolError.malformed }
            if type == "output_text" {
                guard let text = part["text"]?.stringValue else { throw ResponsesProtocolError.malformed }
                result.append(text)
            } else if type == "refusal" {
                guard let refusal = part["refusal"]?.stringValue else { throw ResponsesProtocolError.malformed }
                result.append(refusal)
            }
        }
        return result
    }

    private func summaryText(_ value: JSONValue) throws -> String {
        guard case .array(let parts) = value else { throw ResponsesProtocolError.malformed }
        return try parts.map { part in
            guard case .object = part, part["type"]?.stringValue == "summary_text",
                  let text = part["text"]?.stringValue else { throw ResponsesProtocolError.malformed }
            return text
        }.joined()
    }

    private func encryptedContentMatches(_ prior: JSONValue, _ incoming: JSONValue) -> Bool {
        if prior == incoming { return true }
        if prior == .null, case .string = incoming { return true }
        return false
    }
    private mutating func finishCall(item: JSONValue, id: String) throws {
        guard let callID = item["call_id"]?.stringValue, !callID.isEmpty,
              let name = item["name"]?.stringValue, !name.isEmpty,
              let raw = item["arguments"]?.stringValue else { throw ResponsesProtocolError.malformed }
        try validateToolArguments(raw)
        let call = CanonicalToolCall(id: callID, name: try toolNames.internalName(for: name), arguments: raw)
        calls[id] = call
    }
    private mutating func finishResponse(_ response: JSONValue?, reason: StreamFinishReason,
                                         continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation, complete: Bool = true) throws {
        guard !finished, case .object(let responseObject) = response,
              let output = responseObject["output"], case .array(let values) = output,
              values.count == itemOrder.count,
              let responseID = responseObject["id"]?.stringValue, !responseID.isEmpty else { throw ResponsesProtocolError.malformed }
        if let knownResponseID = self.responseID, knownResponseID != responseID {
            throw ResponsesProtocolError.malformed
        }
        self.responseID = responseID
        guard responseObject["status"]?.stringValue == (complete ? "completed" : "incomplete") else {
            throw ResponsesProtocolError.malformed
        }
        for (index, value) in values.enumerated() {
            guard let id = value["id"]?.stringValue, id == itemOrder[index] else { throw ResponsesProtocolError.malformed }
            guard let status = value["status"]?.stringValue else { throw ResponsesProtocolError.malformed }
            let valid = complete ? status == "completed" : ["completed", "incomplete"].contains(status)
            guard valid else { throw ResponsesProtocolError.malformed }
            if value["type"]?.stringValue == "function_call" {
                guard let callID = value["call_id"]?.stringValue, !callID.isEmpty,
                      let arguments = value["arguments"]?.stringValue,
                      value["name"]?.stringValue?.isEmpty == false else { throw ResponsesProtocolError.malformed }
                try validateToolArguments(arguments)
            }
            try mergeItem(id: id, item: value)
        }
        for id in itemOrder where !completedItems.contains(id) {
            completedItems.insert(id)
            if itemType(id) == "function_call" {
                try finishCall(item: items[id]!, id: id)
            } else if textStarted.contains(id) {
                try yield(.blockFinished(id: id), to: continuation)
            } else if thinkingStarted.contains(id) {
                try yield(.blockFinished(id: id), to: continuation)
            }
        }
        if let usage = responseObject["usage"] {
            let parsed = try parseUsage(usage)
            if self.usage != parsed {
                self.usage = parsed
                try yield(.usage(parsed), to: continuation)
            }
        }
        try emitDeferredBlocksAndCalls(complete: complete, continuation: continuation)
        let raw = try itemOrder.map { id -> JSONValue in
            guard let value = items[id] else { throw ResponsesProtocolError.malformed }
            return value
        }
        try validateRawBounds()
        let continuationValue = AgentModelContinuation(adapter: adapter, format: "openai.responses.items", payload: .array(raw), isComplete: complete)
        try yield(.continuation(continuationValue), to: continuation)
        if self.usage == nil { try yield(.usage(.init()), to: continuation) }
        let finalReason: StreamFinishReason = complete && !calls.isEmpty ? .toolCalls : reason
        try yield(.finished(finalReason), to: continuation)
        finished = true
    }

    private mutating func emitDeferredBlocksAndCalls(complete: Bool,
                                                     continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation) throws {
        for id in itemOrder {
            if complete, let call = calls[id] {
                try yield(.blockStarted(.init(id: id, content: .toolCall(call))), to: continuation)
                try yield(.blockFinished(id: id), to: continuation)
            }
            guard deferredIDs.contains(id) else { continue }
            switch itemType(id) {
            case "message":
                let text = try visibleContentText(items[id]?["content"] ?? .array([]))
                try yield(.blockStarted(.init(id: id, content: .text(""))), to: continuation)
                if !text.isEmpty { try yield(.blockDelta(id: id, text: text), to: continuation) }
                try yield(.blockFinished(id: id), to: continuation)
            case "reasoning":
                let text: String
                if let summary = items[id]?["summary"] { text = try summaryText(summary) } else { text = "" }
                try yield(.blockStarted(.init(id: id, content: .thinking(""))), to: continuation)
                if !text.isEmpty { try yield(.blockDelta(id: id, text: text), to: continuation) }
                try yield(.blockFinished(id: id), to: continuation)
            default:
                throw ResponsesProtocolError.malformed
            }
        }
    }

    private func validateRawBounds() throws {
        guard itemOrder.count <= ResponsesStreamLimits.maxItems else { throw ResponsesProtocolError.resourceLimit }
        let values = itemOrder.compactMap { items[$0] }
        guard values.count == itemOrder.count,
              try SessionCodec.encode(JSONValue.array(values)).count <= ResponsesStreamLimits.maxRawBytes else {
            throw ResponsesProtocolError.resourceLimit
        }
    }
}

private func parseUsage(_ value: JSONValue) throws -> TokenUsage {
    guard case .object(let object) = value else { throw ResponsesProtocolError.malformed }
    func counter(_ value: JSONValue?) throws -> Int? {
        guard let value else { return nil }
        guard case .number(let number) = value,
              number.isFinite, number >= 0, number.rounded(.towardZero) == number,
              number < Double(Int.max) else { throw ResponsesProtocolError.malformed }
        return Int(number)
    }
    func nestedCounter(_ outer: String, _ inner: String) throws -> Int? {
        guard let value = object[outer] else { return nil }
        guard case .object(let nested) = value else { throw ResponsesProtocolError.malformed }
        return try counter(nested[inner])
    }
    let input = try counter(object["input_tokens"])
    let output = try counter(object["output_tokens"])
    let details = try nestedCounter("output_tokens_details", "reasoning_tokens")
    let cached = try nestedCounter("input_tokens_details", "cached_tokens")
    let usage = TokenUsage(inputTokens: input, outputTokens: output, cacheReadTokens: cached, reasoningTokens: details)
    try usage.validate(); return usage
}

private extension JSONValue {
    var numberValue: Double? { if case .number(let value) = self { return value }; return nil }
}

private func yield(_ event: AgentModelStreamEvent,
                  to continuation: AsyncThrowingStream<AgentModelStreamEvent, any Error>.Continuation) throws {
    if case .dropped = continuation.yield(event) { throw ResponsesProtocolError.resourceLimit }
}

private func responsesError(_ error: any Error) -> MiraError {
    if let error = error as? MiraError { return error }
    if error is CancellationError { return MiraError(.cancelled, "Generation was stopped.") }
    if error is ResponsesProtocolError { return MiraError(.malformedStream, "The provider returned an unparseable Responses stream.") }
    if let status = error as? ResponsesHTTPStatusError {
        switch status.statusCode { case 401, 403: return MiraError(.unauthorized, "The provider credential was rejected."); case 429: return MiraError(.rateLimited, "Too many requests; try again later."); case 500...599: return MiraError(.network, "The provider is temporarily unavailable; try again later."); default: return MiraError(.providerRejected, "The provider rejected the request.") }
    }
    return MiraError(.network, "Unable to connect to the provider; try again later.")
}

private struct ResponsesHTTPStatusError: Error { let statusCode: Int; let headers: [String: String] }

private struct ResponsesToolNameMap {
    let definitions: [ToolDefinition]
    func wireName(for name: String) -> String {
        name.replacingOccurrences(of: ".", with: "_")
    }
    func internalName(for target: String) throws -> String {
        guard let definition = definitions.first(where: { self.wireName(for: $0.name) == target }) else {
            throw ResponsesProtocolError.malformed
        }
        return definition.name
    }
}

private func validateToolArguments(_ raw: String) throws {
    guard raw.utf8.count <= 65_536,
          let data = raw.data(using: .utf8),
          let value = try? SessionCodec.decode(JSONValue.self, from: data),
          case .object = value else { throw ResponsesProtocolError.malformed }
}

private func validateResponseWireNames(_ input: AgentModelInput) throws {
    var names = Set<String>()
    for definition in input.tools {
        let wire = ResponsesToolNameMap(definitions: input.tools).wireName(for: definition.name)
        guard wire.utf8.count <= 128, names.insert(wire).inserted else { throw ResponsesProtocolError.malformed }
    }
}
