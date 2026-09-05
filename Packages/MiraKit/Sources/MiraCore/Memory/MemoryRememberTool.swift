import Foundation

/// A bounded, explicitly authorized write tool. The model can propose a write, but cannot grant it.
public struct MemoryRememberTool: ToolPort {
    private let store: any MiraStore
    private let approvals: MemoryApprovalCoordinator

    public init(store: any MiraStore, approvals: MemoryApprovalCoordinator) {
        self.store = store; self.approvals = approvals
    }

    public var descriptor: ToolDescriptor {
        .init(
            definition: .init(
                name: "memory.remember",
                description: "Save an explicitly authorized user memory. Provide the exact quoted text from the current user message; content is untrusted until the user approves it. Tool-created memories are local-only by default.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "content": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(8_192)]),
                        "quote": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(8_192)]),
                        "kind": .object(["type": .string("string"), "enum": .array(MemoryKind.allCases.map { .string($0.rawValue) })]),
                        "scope": .object(["type": .string("string"), "enum": .array([.string("current"), .string("global")])]),
                        "sensitive": .object(["type": .string("boolean")])
                    ]),
                    "required": .array([.string("content"), .string("quote"), .string("kind"), .string("scope"), .string("sensitive")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            executionMode: .exclusive,
            sideEffect: .write,
            timeout: .seconds(120),
            maxResultBytes: 4_096
        )
    }

    public func authorize(arguments: JSONValue, context: ToolContext) async throws {
        try Task.checkCancellation()
        let arguments = try normalizedArguments(arguments)
        let live = try liveProposal(context: context, arguments: arguments, requireDispatched: false)
        let parsed = try parse(arguments: arguments, conversation: live.conversation, trigger: live.trigger)
        guard live.trigger.text.range(of: parsed.quote) != nil else {
            throw MiraError(.invalidInput, "The quote must be an exact substring of the current user message.")
        }
        let request = MemoryApprovalRequest(
            invocationID: context.invocationID,
            executionID: live.execution.id,
            conversationID: live.conversation.id,
            draft: parsed.draft,
            evidenceExcerpt: parsed.quote,
            createdAt: Date()
        )
        let suppressedSources = try store.suppressedMemorySourceMessageIDs()
        if parsed.isDirectIntent && !suppressedSources.contains(live.trigger.id) {
            try await approvals.grantDirect(request, proposal: live.invocation.call)
            return
        }
        guard try await approvals.awaitApproval(request, proposal: live.invocation.call) else {
            throw MiraError(.unauthorized, "The memory save was not approved.")
        }
    }

    public func execute(arguments: JSONValue, context: ToolContext) async throws -> String {
        try Task.checkCancellation()
        let arguments = try normalizedArguments(arguments)
        let live = try liveProposal(context: context, arguments: arguments, requireDispatched: true)
        let parsed = try parse(arguments: arguments, conversation: live.conversation, trigger: live.trigger)
        guard live.trigger.text.range(of: parsed.quote) != nil else {
            throw MiraError(.invalidInput, "The quote must be an exact substring of the current user message.")
        }
        try await approvals.consumeGrant(invocationID: context.invocationID, executionID: live.execution.id, proposal: live.invocation.call)
        try Task.checkCancellation()
        let receipt = try store.rememberMemory(draft: parsed.draft, quote: parsed.quote, invocationID: context.invocationID, at: Date())
        try Task.checkCancellation()
        return try JSONValue.object([
            "memory_id": .string(receipt.memory.id.rawValue.uuidString.lowercased()),
            "revision": .number(Double(receipt.memory.revision)),
            "reference": .string(receipt.memory.citation),
            "state": .string(receipt.memory.state.rawValue),
            "allows_remote_use": .bool(false)
        ]).jsonString()
    }

    private struct ParsedArguments {
        let draft: MemoryDraft
        let quote: String
        let isDirectIntent: Bool
    }

    private struct LiveProposal {
        let execution: Execution
        let conversation: Conversation
        let trigger: Message
        let invocation: ToolInvocation
    }

    private func normalizedArguments(_ arguments: JSONValue) throws -> JSONValue {
        try ToolSchemaValidator.decode(try arguments.jsonString(), schema: descriptor.definition.inputSchema)
    }

    private func liveProposal(context: ToolContext, arguments: JSONValue, requireDispatched: Bool) throws -> LiveProposal {
        guard let execution = try store.execution(context.executionID), !execution.status.isTerminal, execution.bodyPurgedAt == nil,
              let conversation = try store.conversations(includeArchived: true).first(where: { $0.id == execution.conversationID }), !conversation.isArchived,
              context.userMessageID == execution.triggerMessageID, context.workspaceID == conversation.workspaceID,
              let trigger = try store.messages(in: conversation.id).first(where: { $0.id == execution.triggerMessageID && $0.role == .user && $0.status == .committed && $0.bodyPurgedAt == nil }),
              let invocation = try store.toolInvocations(for: execution.id).first(where: { $0.id == context.invocationID && $0.call.name == descriptor.definition.name }) else {
            throw MiraError(.unauthorized, "The memory tool context is no longer authorized.")
        }
        guard invocation.result == nil, invocation.completedAt == nil, invocation.bodyPurgedAt == nil else {
            throw MiraError(.unauthorized, "The memory proposal is no longer active.")
        }
        guard context.userText == trigger.text else {
            throw MiraError(.unauthorized, "The memory tool context is no longer authorized.")
        }
        if requireDispatched { guard invocation.dispatchedAt != nil else { throw MiraError(.unauthorized, "The memory proposal was not dispatched.") } }
        let proposalArguments = try ToolSchemaValidator.decode(invocation.call.arguments, schema: descriptor.definition.inputSchema)
        guard proposalArguments == arguments else {
            throw MiraError(.unauthorized, "The memory proposal changed after authorization.")
        }
        return .init(execution: execution, conversation: conversation, trigger: trigger, invocation: invocation)
    }

    private func parse(arguments: JSONValue, conversation: Conversation, trigger: Message) throws -> ParsedArguments {
        guard let content = arguments["content"]?.stringValue,
              let quote = arguments["quote"]?.stringValue,
              let kindValue = arguments["kind"]?.stringValue,
              let kind = MemoryKind(rawValue: kindValue) else {
            throw MiraError(.invalidInput, "Memory arguments are incomplete.")
        }
        guard let scopeValue = arguments["scope"]?.stringValue,
              let sensitive = arguments["sensitive"]?.boolValue else {
            throw MiraError(.invalidInput, "Memory scope and sensitivity are required.")
        }
        let scope: MemoryScope
        switch scopeValue {
        case "current": scope = conversation.workspaceID.map(MemoryScope.workspace) ?? .global
        case "global": scope = .global
        default: throw MiraError(.invalidInput, "The memory scope is invalid.")
        }
        let draft = MemoryDraft(content: content, scope: scope, subject: .user, kind: kind, sensitivity: sensitive ? .sensitive : .standard, allowsRemoteUse: false)
        try draft.validate()
        let isDirectIntent = Self.directIntentMatches(triggerText: trigger.text, content: content, quote: quote, scope: scopeValue, sensitive: sensitive)
        return .init(draft: draft, quote: quote, isDirectIntent: isDirectIntent)
    }

    static func directIntentMatches(triggerText: String, content: String, quote: String, scope: String, sensitive: Bool) -> Bool {
        let directSuffix = explicitIntentSuffix(in: triggerText)
        return scope == "current" && !sensitive && directSuffix == content && content == quote
    }

    private static func explicitIntentSuffix(in text: String) -> String? {
        guard let prefixes = try? loadPrefixes() else { return nil }
        let lowered = text.lowercased()
        for prefix in prefixes where lowered.hasPrefix(prefix.lowercased()) {
            return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // This small lexicon recognizes explicit user intent; it never localizes or changes built-in prompts.
    private static func loadPrefixes() throws -> [String] {
        struct Prefixes: Decodable { let englishPrefixes: [String]; let chinesePrefixes: [String] }
        guard let url = Bundle.module.url(forResource: "RememberIntentPrefixes", withExtension: "json") else { throw MiraError(.configuration, "Memory intent configuration is unavailable.") }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(Prefixes.self, from: data)
        return decoded.englishPrefixes + decoded.chinesePrefixes
    }
}

private extension JSONValue {
    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
}
