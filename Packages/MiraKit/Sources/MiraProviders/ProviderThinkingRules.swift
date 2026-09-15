import MiraCore

/// Wire controls are selected from the frozen invocation descriptor. This
/// policy deliberately contains no model-name or prefix matching.
enum ProviderThinkingRules {
    static func usesCompletionTokenLimit(for policy: HTTPModelPolicy) -> Bool {
        // DeepSeek's current Chat Completions contract still names this
        // field `max_tokens`; Kimi and OpenAI use `max_completion_tokens`.
        [.kimi, .openAI].contains(policy.kind.dialect)
    }

    static func preservesKimiThinking(for policy: HTTPModelPolicy) -> Bool {
        policy.kind.dialect == .kimi && policy.thinking.mode != .disabled
    }

    static func openAIThinkingType(for policy: HTTPModelPolicy, preservingHistory: Bool = false) -> String? {
        guard [.deepSeek, .kimi].contains(policy.kind.dialect) else { return nil }
        switch policy.thinking.mode {
        case .providerDefault: return policy.kind.dialect == .kimi && preservingHistory ? "enabled" : nil
        case .enabled: return "enabled"
        case .adaptive: return "enabled"
        case .disabled: return "disabled"
        }
    }

    static func openAIReasoningEffort(for policy: HTTPModelPolicy) -> String? {
        guard [.deepSeek, .kimi, .openAI].contains(policy.kind.dialect) else { return nil }
        switch policy.thinking.mode {
        case .providerDefault: return policy.thinking.effort?.rawValue
        case .disabled: return policy.kind.dialect == .openAI ? "none" : nil
        case .enabled, .adaptive: return policy.thinking.effort?.rawValue
        }
    }

    static func openRouterReasoning(for policy: HTTPModelPolicy) -> (enabled: Bool?, effort: String?, maxTokens: Int?)? {
        guard policy.kind.dialect == .openRouter else { return nil }
        let settings = policy.thinking
        guard settings.mode != .providerDefault || settings.effort != nil || settings.budgetTokens != nil else { return nil }
        return (
            enabled: settings.mode == .providerDefault ? nil : settings.mode == .enabled,
            effort: settings.mode == .disabled ? nil : settings.effort?.rawValue,
            maxTokens: settings.mode == .disabled ? nil : settings.budgetTokens
        )
    }

    static func anthropicThinking(for policy: HTTPModelPolicy) -> (type: String, budgetTokens: Int?)? {
        if policy.kind.isAnthropic {
            switch policy.thinking.mode {
            case .disabled: return ("disabled", nil)
            case .enabled: return ("enabled", policy.thinking.budgetTokens ?? 2_048)
            case .providerDefault:
                if policy.thinking.effort != nil { return ("adaptive", nil) }
                return policy.thinking.budgetTokens.map { ("enabled", $0) }
            case .adaptive: return ("adaptive", nil)
            }
        }
        return nil
    }

    static func anthropicOutputEffort(for policy: HTTPModelPolicy) -> String? {
        guard policy.kind.isAnthropic else { return nil }
        guard policy.thinking.mode == .adaptive || policy.thinking.mode == .enabled ||
                (policy.thinking.mode == .providerDefault && policy.thinking.effort != nil) else { return nil }
        return policy.thinking.effort?.rawValue
    }
}
