import SwiftUI

/// Displays the model family mark, keeping model identity separate from the
/// connection/provider that serves it.
struct MiraModelIcon: View {
    let modelID: String
    let providerID: String?
    var size: CGFloat = MiraTheme.Layout.providerModelIconSize

    var body: some View {
        if let assetName = Self.assetName(modelID: modelID, providerID: providerID) {
            Image(assetName)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "cube")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    private static func assetName(modelID: String, providerID: String?) -> String? {
        let model = modelID.lowercased()
        let provider = providerID?.lowercased()

        // These provider IDs are model catalogs, so their un-namespaced IDs
        // identify the corresponding model family directly.
        switch provider {
        case "openai" where openAIModels.contains(model): return "ProviderOpenAI"
        case "anthropic" where model.hasPrefix("claude-"): return "ModelClaude"
        case "deepseek" where model.hasPrefix("deepseek-"): return "ProviderDeepSeek"
        case "kimi-for-coding", "moonshotai-cn", "moonshotai":
            if kimiModels.contains(model) { return "ModelKimi" }
        default: break
        }

        // Recognize explicit model identities on custom proxies too. This is
        // presentation only and does not assign provider metadata or routing.
        if provider == nil {
            if openAIModels.contains(model) { return "ProviderOpenAI" }
            if model.hasPrefix("claude-") { return "ModelClaude" }
            if model.hasPrefix("deepseek-") { return "ProviderDeepSeek" }
            if kimiModels.contains(model) { return "ModelKimi" }
        }

        // OpenRouter IDs use a documented vendor namespace. Keep the mapping
        // explicit so an arbitrary substring in a custom ID cannot acquire a
        // third-party brand mark.
        guard provider == "openrouter" || model.contains("/") else { return nil }
        let components = model.split(separator: "/", maxSplits: 1).map(String.init)
        guard components.count == 2 else { return nil }
        let namespace = components[0].trimmingCharacters(in: CharacterSet(charactersIn: "~"))
        let family = components[1]

        switch namespace {
        case "openai": return "ProviderOpenAI"
        case "anthropic" where family.hasPrefix("claude"): return "ModelClaude"
        case "deepseek": return "ProviderDeepSeek"
        case "moonshotai" where family.hasPrefix("kimi"): return "ModelKimi"
        case "qwen": return "ModelQwen"
        case "google" where family.hasPrefix("gemma"): return "ModelGemma"
        case "google" where family.hasPrefix("gemini"): return "ModelGemini"
        case "meta-llama": return "ModelMeta"
        case "mistralai": return "ModelMistral"
        case "x-ai" where family.hasPrefix("grok"): return "ModelGrok"
        case "z-ai" where family.hasPrefix("glm"): return "ModelGLM"
        case "minimax": return "ModelMiniMax"
        case "cohere": return "ModelCohere"
        case "amazon" where family.hasPrefix("nova"): return "ModelNova"
        case "bytedance-seed": return "ModelByteDance"
        case "baidu": return "ModelBaidu"
        case "microsoft" where family.hasPrefix("phi") || family.hasPrefix("wizardlm"): return "ModelMicrosoft"
        case "nvidia" where family.hasPrefix("nemotron"): return "ModelNvidia"
        case "perplexity": return "ModelPerplexity"
        case "tencent" where family.hasPrefix("hunyuan") || family.hasPrefix("hy-"): return "ModelHunyuan"
        case "stepfun": return "ModelStepfun"
        default: return nil
        }
    }

    private static let openAIModels: Set<String> = [
        "chatgpt-image-latest", "gpt-3.5-turbo", "gpt-4", "gpt-4-turbo", "gpt-4.1",
        "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o", "gpt-4o-2024-05-13", "gpt-4o-2024-08-06",
        "gpt-4o-2024-11-20", "gpt-4o-mini", "gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5-pro",
        "gpt-5.1", "gpt-5.2", "gpt-5.2-chat-latest", "gpt-5.2-pro", "gpt-5.3-chat-latest",
        "gpt-5.3-codex", "gpt-5.3-codex-spark", "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano",
        "gpt-5.4-pro", "gpt-5.5", "gpt-5.5-pro", "gpt-5.6", "gpt-5.6-luna", "gpt-5.6-sol",
        "gpt-5.6-terra", "gpt-6-astra", "gpt-image-1", "gpt-image-1-mini", "gpt-image-1.5",
        "gpt-image-2", "gpt-realtime-2.1", "o1", "o1-pro", "o3", "o3-mini", "o3-pro", "o4-mini",
        "text-embedding-3-large", "text-embedding-3-small", "text-embedding-ada-002"
    ]

    private static let kimiModels: Set<String> = [
        "k3", "k3-256k", "kimi-for-coding", "kimi-for-coding-highspeed", "kimi-k2-0711-preview",
        "kimi-k2-0905-preview", "kimi-k2-thinking", "kimi-k2-thinking-turbo", "kimi-k2-turbo-preview",
        "kimi-k2.6", "kimi-k2.7-code", "kimi-k2.7-code-highspeed", "kimi-k3"
    ]
}
