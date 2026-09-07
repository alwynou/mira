import Foundation
import MiraCore

/// A display-only projection of the existing append-only execution trace.
/// Stored text, tool arguments and provider continuation data are never modified.
struct TranscriptPresentation: Equatable {
    struct Tool: Identifiable, Equatable {
        let id: String
        let name: String
        var observation: String?
        var hasResult: Bool { observation != nil }

        var output: String? {
            guard let observation else { return nil }
            // Decode only when a tool disclosure is expanded. Historical tool
            // bodies must not be parsed on every live answer snapshot.
            let envelope = try? JSONDecoder().decode(JSONValue.self, from: Data(observation.utf8))
            return envelope?["content"]?.stringValue ?? observation
        }
    }

    struct Round: Identifiable, Equatable {
        // The canonical trace has no message IDs. Its assistant sequence is stable
        // as each snapshot appends content to the current turn, including after reopen.
        let id: Int
        let thinking: String?
        let isThinkingComplete: Bool
        var intermediateText: String
        var tools: [Tool]
    }

    let rounds: [Round]
    let answer: String

    init(text: String, trace: [CanonicalMessage]) {
        var groups: [Round] = []
        for message in trace {
            if message.role == .assistant {
                groups.append(Round(
                    id: groups.count,
                    thinking: message.reasoning?.text,
                    isThinkingComplete: message.reasoning?.isComplete ?? true,
                    intermediateText: message.text,
                    tools: (message.toolCalls ?? []).map { Tool(id: $0.id, name: $0.name) }
                ))
            } else if message.role == .tool, let callID = message.toolCallID,
                      let group = groups.lastIndex(where: { $0.tools.contains { $0.id == callID } }),
                      let tool = groups[group].tools.firstIndex(where: { $0.id == callID }) {
                groups[group].tools[tool].observation = message.text
            }
        }

        let finalIndex = trace.last?.role == .assistant && groups.last?.tools.isEmpty == true ? groups.indices.last : nil
        let intermediate = groups.filter { $0.id != finalIndex }.map(\.intermediateText).filter { !$0.isEmpty }.joined(separator: "\n\n")
        if intermediate.isEmpty {
            answer = text
        } else if text == intermediate {
            answer = ""
        } else if text.hasPrefix(intermediate + "\n\n") {
            // Draft text is published more often than trace snapshots. Keep the
            // live final suffix even when the latest trace still ends in a tool.
            answer = String(text.dropFirst(intermediate.count + 2))
        } else {
            // A coalesced trace may briefly arrive ahead of its matching draft.
            answer = finalIndex.map { groups[$0].intermediateText } ?? ""
        }
        if let finalIndex { groups[finalIndex].intermediateText = "" }
        rounds = groups
    }

    var isThinking: Bool { rounds.last?.isThinkingComplete == false }
    var pendingTools: [Tool] { rounds.last?.tools.filter { !$0.hasResult } ?? [] }
}
