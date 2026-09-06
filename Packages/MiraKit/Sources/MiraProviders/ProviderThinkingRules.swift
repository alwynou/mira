import MiraCore

/// Provider-specific thinking controls stay isolated from the common request
/// encoder and SSE assembler. Values are emitted only for an explicitly
/// supported protocol route; providerDefault otherwise leaves the wire default
/// untouched.
enum ProviderThinkingRules {
    static func usesCompletionTokenLimit(for route: ResolvedModelRouteSnapshot) -> Bool {
        route.protocolMode == .openAI || (route.protocolMode == .kimi && route.modelID == "kimi-k3")
    }

    static func preservesKimiThinking(for route: ResolvedModelRouteSnapshot) -> Bool {
        route.protocolMode == .kimi && route.modelID == "kimi-k2.6" && route.thinking.mode != .disabled
    }

    static func openAIThinkingType(for route: ResolvedModelRouteSnapshot) -> String? {
        guard route.protocolMode == .deepSeek || route.protocolMode == .kimi,
              !(route.protocolMode == .kimi && route.modelID == "kimi-k3") else { return nil }
        if preservesKimiThinking(for: route) { return "enabled" }
        switch route.thinking.mode {
        case .providerDefault: return nil
        case .enabled: return "enabled"
        case .disabled: return "disabled"
        }
    }

    static func openAIReasoningEffort(for route: ResolvedModelRouteSnapshot) -> String? {
        if route.protocolMode == .deepSeek, route.thinking.mode != .disabled {
            return route.thinking.effort.map { $0 == .medium ? "high" : $0.rawValue }
        }
        if route.protocolMode == .kimi, route.modelID == "kimi-k3", route.thinking.mode != .disabled {
            return route.thinking.effort?.rawValue
        }
        guard route.protocolMode == .openAI else { return nil }
        switch route.thinking.mode {
        case .providerDefault:
            return route.thinking.effort?.rawValue
        case .disabled:
            return "none"
        case .enabled:
            return route.thinking.effort?.rawValue ?? (route.thinkingCapabilities.efforts == [.high] ? "high" : "medium")
        }
    }

    static func openRouterReasoning(for route: ResolvedModelRouteSnapshot) -> (enabled: Bool?, effort: String?, maxTokens: Int?)? {
        guard route.protocolMode == .openRouter else { return nil }
        let settings = route.thinking
        guard settings.mode != .providerDefault || settings.effort != nil || settings.budgetTokens != nil else { return nil }
        return (
            enabled: settings.mode == .providerDefault ? nil : settings.mode == .enabled,
            effort: settings.mode == .disabled ? nil : settings.effort?.rawValue,
            maxTokens: settings.mode == .disabled ? nil : settings.budgetTokens
        )
    }

    static func anthropicThinking(for route: ResolvedModelRouteSnapshot) -> (type: String, budgetTokens: Int?)? {
        switch route.protocolMode {
        case .anthropicManual:
            switch route.thinking.mode {
            case .disabled:
                return ("disabled", nil)
            case .enabled:
                return ("enabled", route.thinking.budgetTokens ?? 2_048)
            case .providerDefault:
                return route.thinking.budgetTokens.map { ("enabled", $0) }
            }
        case .anthropicAdaptive:
            switch route.thinking.mode {
            case .disabled:
                return ("disabled", nil)
            case .enabled:
                return ("adaptive", nil)
            case .providerDefault:
                return route.thinking.effort == nil ? nil : ("adaptive", nil)
            }
        default:
            return nil
        }
    }

    static func anthropicOutputEffort(for route: ResolvedModelRouteSnapshot) -> String? {
        guard route.protocolMode == .anthropicAdaptive else { return nil }
        guard route.thinking.mode == .enabled ||
                (route.thinking.mode == .providerDefault && route.thinking.effort != nil) else { return nil }
        return route.thinking.effort?.rawValue
    }
}
