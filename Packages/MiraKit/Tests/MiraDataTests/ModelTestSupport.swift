import Foundation
@testable import MiraCore

let modelParameterSchema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([:]),
    "additionalProperties": .bool(false),
])

func modelTextStream(_ text: String, blockID: String = "text") -> [AgentModelStreamEvent] {
    [.blockStarted(.init(id: blockID, content: .text(""))),
     .blockDelta(id: blockID, text: text),
     .blockFinished(id: blockID),
     .finished(.stop)]
}

func modelPartialTextEvents(_ text: String, blockID: String = "partial-text") -> [AgentModelStreamEvent] {
    [.blockStarted(.init(id: blockID, content: .text(""))), .blockDelta(id: blockID, text: text)]
}

func modelThinkingStream(_ text: String, continuation: AgentModelContinuation? = nil,
                        blockID: String = "thinking") -> [AgentModelStreamEvent] {
    var events: [AgentModelStreamEvent] = [
        .blockStarted(.init(id: blockID, content: .thinking(""))),
        .blockDelta(id: blockID, text: text)
    ]
    if let continuation { events.append(.continuation(continuation)) }
    events.append(.blockFinished(id: blockID))
    events.append(.finished(.stop))
    return events
}

func modelToolStream(_ calls: [CanonicalToolCall], blockPrefix: String = "tool") -> [AgentModelStreamEvent] {
    var events: [AgentModelStreamEvent] = []
    for (index, call) in calls.enumerated() {
        let id = "\(blockPrefix)-\(index)"
        events.append(.blockStarted(.init(id: id, content: .toolCall(call))))
        events.append(.blockFinished(id: id))
    }
    events.append(.finished(.toolCalls))
    return events
}

func modelTextAndToolStream(_ text: String, calls: [CanonicalToolCall]) -> [AgentModelStreamEvent] {
    var events: [AgentModelStreamEvent] = [
        .blockStarted(.init(id: "text", content: .text(""))),
        .blockDelta(id: "text", text: text),
        .blockFinished(id: "text"), .finished(.stop)
    ]
    for (index, call) in calls.enumerated() {
        let id = "tool-\(index)"
        events.append(.blockStarted(.init(id: id, content: .toolCall(call))))
        events.append(.blockFinished(id: id))
    }
    events.append(.finished(.toolCalls))
    return events
}
