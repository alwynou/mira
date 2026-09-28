import Foundation
import MiraCore

/// Applies to all tool types. Unknown capabilities never inherit a safe classification.
struct MacToolPermissionPolicy: Sendable {
    enum Risk { case routine, readOnlyCommand, guarded }

    static func risk(of proposal: AgentToolProposal) -> Risk {
        let name = proposal.descriptor.definition.name
        if proposal.effect == .read,
           ["memory.search", "memory.get", "knowledge.search", "source.open", "source.read_chunk", "task.list"].contains(name) {
            return .routine
        }
        if proposal.effect == .localWrite {
            switch (name, proposal.businessNamespace) {
            case ("memory.remember", "memory.remember"), ("memory.retract", "memory.retract"), ("task.change", "tasks.change"):
                return .routine
            default: break
            }
        }
        if proposal.effect == .externalWrite, proposal.descriptor == MacBashTool().descriptor,
           let command = proposal.plan.input["command"]?.stringValue,
           MacBashReadOnlyCommand.canonical(command) == command {
            return .readOnlyCommand
        }
        return .guarded
    }

    static func decision(for proposal: AgentToolProposal, level: ToolPermissionLevel, now: Date) throws -> AgentToolPolicyDecision {
        let risk = risk(of: proposal)
        if risk == .routine || level == .fullAccess || (level == .automatic && risk == .readOnlyCommand) {
            return .allow
        }
        let prompt: String
        if proposal.effect == .externalWrite, proposal.descriptor == MacBashTool().descriptor {
            prompt = try MacBashCommand.parse(proposal.plan.input, defaultDirectory: FileManager.default.homeDirectoryForCurrentUser.path).approvalPrompt
        } else {
            // Raw, exact tool identity/input and targets are review data, not translated UI copy.
            prompt = try JSONValue.object([
                "tool": .string(proposal.descriptor.definition.name),
                "input": proposal.plan.input,
                "targets": SessionCodec.decode(JSONValue.self, from: SessionCodec.encode(proposal.plan.targets))
            ]).jsonString()
        }
        // Never truncate an action into a materially different review. Oversized reviews fail closed.
        guard prompt.utf8.count <= 4_096 else {
            throw MiraError(.invalidInput, "The tool action exceeds the approval review limit.")
        }
        return .requireApproval(prompt: prompt, expiresAt: now.addingTimeInterval(300))
    }
}
