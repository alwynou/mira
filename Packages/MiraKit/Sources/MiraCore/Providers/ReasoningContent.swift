import Foundation

public enum ThinkingMode: String, Codable, CaseIterable, Sendable {
    case providerDefault, enabled, disabled
}

public enum ThinkingEffort: String, Codable, CaseIterable, Sendable {
    case low, medium, high, xhigh, max
}

/// User-selected request controls, frozen with the route for the entire execution.
public struct ThinkingSettings: Codable, Sendable, Equatable {
    public var mode: ThinkingMode
    public var effort: ThinkingEffort?
    public var budgetTokens: Int?

    public init(mode: ThinkingMode = .providerDefault, effort: ThinkingEffort? = nil, budgetTokens: Int? = nil) {
        self.mode = mode; self.effort = effort; self.budgetTokens = budgetTokens
    }
}

/// Controls exposed by the chosen protocol. Model capability declarations and
/// transport acceptance remain distinct from a successful live probe.
public struct ThinkingCapabilities: Sendable {
    public var modes: [ThinkingMode]
    public var efforts: [ThinkingEffort]
    public var supportsBudget: Bool

    public init(protocolMode: ModelProtocolMode, modelID: String) {
        modes = [.providerDefault, .enabled, .disabled]
        efforts = []; supportsBudget = false
        switch protocolMode {
        case .standard:
            modes = [.providerDefault]
        case .deepSeek:
            efforts = [.low, .high, .max]
        case .kimi:
            if ["kimi-k2.5", "kimi-k2.6"].contains(modelID) {
                efforts = []
            } else {
                modes = [.providerDefault, .enabled]
                if modelID == "kimi-k3" { efforts = [.low, .high, .max] }
            }
        case .anthropicManual:
            supportsBudget = true
        case .anthropicAdaptive:
            efforts = [.low, .medium, .high]
            if modelID.contains("opus") || modelID.contains("fable") || modelID.contains("mythos") || modelID.hasPrefix("claude-sonnet-5") { efforts.append(.max) }
            if modelID.contains("fable") || modelID.contains("mythos") {
                modes = [.providerDefault, .enabled]
            }
        case .openAI:
            modes = [.providerDefault, .enabled]
            efforts = [.low, .medium, .high]
            let toggles = ["gpt-5.1", "gpt-5.2", "gpt-5.4", "gpt-5.5", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-6-astra"]
            let matched = toggles.first { modelID == $0 || modelID.hasPrefix($0 + "-20") }
            if let matched {
                modes.append(.disabled)
                if matched != "gpt-5.1" { efforts.append(.xhigh) }
                if matched.hasPrefix("gpt-5.6") || matched == "gpt-6-astra" { efforts.append(.max) }
            }
            if modelID == "gpt-5-pro" || modelID.hasPrefix("gpt-5-pro-20") { efforts = [.high] }
        case .openRouter:
            efforts = [.low, .medium, .high, .xhigh, .max]; supportsBudget = true
        }
    }
}

public enum ReasoningFormat: String, Codable, Sendable {
    case openAIContent, anthropicBlocks, openRouterDetails
}

/// Provider-returned thinking is separate from the answer. Replay blocks are
/// opaque protocol data, never instructions, memory evidence or ordinary logs.
public struct ReasoningContent: Codable, Sendable, Equatable {
    public var format: ReasoningFormat
    public var text: String
    /// Anthropic stores the complete ordered assistant content array, including
    /// signed/redacted blocks. OpenRouter stores its reasoning_details array.
    public var blocks: [JSONValue]
    public var isComplete: Bool

    public init(format: ReasoningFormat, text: String = "", blocks: [JSONValue] = [], isComplete: Bool = false) {
        self.format = format; self.text = text; self.blocks = blocks; self.isComplete = isComplete
    }

    public func validate() throws {
        guard text.utf8.count <= 2_097_152, blocks.count <= (format == .openRouterDetails ? 65_536 : 256),
              try JSONEncoder().encode(self).count <= 4_194_304 else {
            throw MiraError(.outputLimit, "Thinking content exceeded the local safety limit.")
        }
    }
}

public enum AssistantTrace {
    public static func validate(_ messages: [CanonicalMessage], complete: Bool = false) throws {
        guard messages.count <= 256, try JSONEncoder().encode(messages).count <= 8_388_608 else {
            throw MiraError(.outputLimit, "The assistant transcript exceeded the local safety limit.")
        }
        for message in messages {
            guard message.role == .assistant || message.role == .tool,
                  message.role == .assistant || message.reasoning == nil,
                  !complete || message.reasoning?.isComplete != false else {
                throw MiraError(.malformedStream, "The assistant transcript contains invalid thinking content.")
            }
            try message.reasoning?.validate()
        }
    }
}
