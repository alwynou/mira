import Foundation

public enum ContextBuilder {
    public static func build(execution: Execution, conversations: [Conversation], workspaces: [Workspace], messages: [Message], executions: [Execution]) throws -> CanonicalModelRequest {
        try execution.route.validateForSending()
        guard let conversation = conversations.first(where: { $0.id == execution.conversationID }), !conversation.isArchived,
              let trigger = messages.first(where: { $0.id == execution.triggerMessageID && $0.conversationID == conversation.id && $0.role == .user }) else {
            throw MiraError(.notFound, "当前对话或消息不可用。")
        }
        var system = "你是 Mira，一位认真、简洁的个人助理。当前仅支持文本对话，不声称已保存记忆、检索文件或执行工具。"
        if let workspaceID = conversation.workspaceID {
            guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { throw MiraError(.notFound, "工作空间不可用。") }
            guard workspace.allowsRemoteSend else { throw MiraError(.unauthorized, "此工作空间禁止发送到模型服务，请在工作空间设置中修改。") }
            if !workspace.background.isEmpty { system += "\n\n用户固定的项目背景：\n" + workspace.background }
        }
        var history: [CanonicalMessage] = []
        let successful = executions.filter { $0.conversationID == conversation.id && $0.status == .completed }
        for message in messages.sorted(by: { $0.sequence < $1.sequence }) where message.conversationID == conversation.id && message.role == .user && message.sequence < trigger.sequence {
            guard let prior = successful.first(where: { $0.triggerMessageID == message.id }),
                  let answer = messages.first(where: { $0.executionID == prior.id && $0.role == .assistant && $0.status == .committed && $0.conversationID == conversation.id }) else { continue }
            history.append(.init(role: .user, text: message.text))
            history.append(.init(role: .assistant, text: answer.text))
        }
        history.append(.init(role: .user, text: trigger.text))
        // UTF-8 byte count is a conservative estimate for the initial un-tokenized text adapter.
        // Never silently trim canonical history; a future Compact operation owns that decision.
        let estimatedInput = system.utf8.count + history.reduce(0) { $0 + $1.text.utf8.count + 16 }
        let window = execution.route.contextWindow ?? 0
        let margin = max(512, window / 10)
        guard estimatedInput + execution.route.maxOutputTokens + margin <= window else {
            throw MiraError(.contextLimit, "对话超出保守上下文预算。请新建对话，或确认并调整模型窗口；当前版本不自动压缩历史。")
        }
        return .init(executionID: execution.id, system: system, messages: history)
    }
}
