import Foundation

/// Records the normalized adapter stream at receipt, preserving delta boundaries.
struct AgentSessionStreamRecorder: Sendable {
    private(set) var records: [SessionMessageStreamRecord] = []
    private var indices: [String: Int] = [:]
    private var replay: JSONValue?
    private var lastTime: Int?
    private var finished = false

    mutating func consume(_ event: AgentModelStreamEvent, blocks: [AgentModelBlock], at date: Date) throws {
        let time = try logTime(date)
        switch event {
        case .blockStarted(let block):
            let index = indices.count
            indices[block.id] = index
            let type: String
            switch block.content {
            case .text: type = "text"
            case .thinking: type = "reasoning"
            case .toolCall: type = "tool-call"
            case .toolResult: type = "tool-result"
            }
            append(.blockStart(index: index, blockType: type), at: time)
            switch block.content {
            case .text(let text) where !text.isEmpty: append(.textDelta(index: index, text: text), at: time)
            case .thinking(let text) where !text.isEmpty: append(.reasoningDelta(index: index, text: text), at: time)
            case .toolCall(let call): append(.toolCallDelta(index: index, id: call.id, name: call.name, argumentsDelta: call.arguments), at: time)
            default: break
            }
        case .blockDelta(let id, let text):
            guard let index = indices[id], let block = blocks.first(where: { $0.id == id }) else { throw invalid }
            switch block.content {
            case .thinking:
                append(.reasoningDelta(index: index, text: text), at: time)
            case .toolCall(let call):
                append(.toolCallDelta(index: index, id: call.id, name: call.name,
                                      argumentsDelta: text), at: time)
            default:
                append(.textDelta(index: index, text: text), at: time)
            }
        case .blockFinished(let id):
            guard let index = indices[id], let block = blocks.first(where: { $0.id == id }) else { throw invalid }
            append(.blockEnd(index: index, block: SessionMessageContent(block)), at: time)
        case .continuation(let value):
            replay = try SessionCodec.decode(JSONValue.self, from: SessionCodec.encode(value))
        case .usage(let usage):
            if let value = SessionMessageUsage(tokenUsage: usage) { append(.usage(value), at: time) }
        case .finished(let reason):
            let kind: SessionMessageStreamFinishReason
            switch reason {
            case .stop: kind = .stop
            case .toolCalls: kind = .toolCalls
            case .outputLimit: kind = .maxTokens
            }
            append(.finish(reason: kind, replayState: replay), at: time)
            finished = true
        }
    }

    mutating func fail(_ error: MiraError, at date: Date) {
        guard !finished else { return }
        let failure = JSONValue.object(["code": .string(error.code.rawValue), "message": .string(error.message)])
        let reason: SessionMessageStreamFinishReason = error.code == .cancelled
            ? .aborted(failure: failure) : .error(failure: failure)
        // Error reporting must remain safe even if an injected clock is invalid.
        append(.finish(reason: reason), at: (try? logTime(date)) ?? lastTime ?? 0)
        finished = true
    }

    private mutating func append(_ chunk: SessionMessageStreamChunk, at time: Int) {
        let gap = lastTime.map { time.subtractingReportingOverflow($0) }
        switch chunk {
        case .textDelta(let index, let text):
            if let previous = records.last, case .textChunks(let start, let oldIndex, var dt, var texts) = previous,
               oldIndex == index, let gap, !gap.overflow, gap.partialValue >= 0 {
                records.removeLast(); dt.append(gap.partialValue); texts.append(text)
                records.append(.textChunks(time0: start, index: index, dt: dt, texts: texts))
            } else { records.append(.textChunks(time0: time, index: index, dt: [], texts: [text])) }
        case .reasoningDelta(let index, let text):
            if let previous = records.last, case .reasoningChunks(let start, let oldIndex, var dt, var texts) = previous,
               oldIndex == index, let gap, !gap.overflow, gap.partialValue >= 0 {
                records.removeLast(); dt.append(gap.partialValue); texts.append(text)
                records.append(.reasoningChunks(time0: start, index: index, dt: dt, texts: texts))
            } else { records.append(.reasoningChunks(time0: time, index: index, dt: [], texts: [text])) }
        case .toolCallDelta(let index, let id, let name, let arguments):
            if let previous = records.last,
               case .toolCallChunks(let start, let oldIndex, var dt, let oldID, let oldName, var args) = previous,
               oldIndex == index, oldID == id, oldName == name,
               let gap, !gap.overflow, gap.partialValue >= 0 {
                records.removeLast(); dt.append(gap.partialValue); args.append(arguments)
                records.append(.toolCallChunks(time0: start, index: index, dt: dt, id: id, name: name, args: args))
            } else {
                records.append(.toolCallChunks(time0: time, index: index, dt: [], id: id, name: name, args: [arguments]))
            }
        default: records.append(.chunk(time: time, chunk: chunk))
        }
        lastTime = time
    }

    private var invalid: MiraError { .init(.malformedStream, "The session stream references an unknown block.") }
}
