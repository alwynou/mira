import Foundation
import Testing
@testable import MiraCore

@Suite("Agent session stream recorder")
struct AgentSessionStreamRecorderTests {
    @Test func coalescesAdjacentTextDeltasAndPreservesElapsedMilliseconds() throws {
        var recorder = AgentSessionStreamRecorder()
        let block = AgentModelBlock(id: "answer", content: .text(""))
        let start = Date(timeIntervalSince1970: 1_000)
        try recorder.consume(.blockStarted(block), blocks: [block], at: start)
        try recorder.consume(.blockDelta(id: block.id, text: "A"), blocks: [block], at: start.addingTimeInterval(0.010))
        try recorder.consume(.blockDelta(id: block.id, text: "B"), blocks: [block], at: start.addingTimeInterval(0.025))

        guard case .textChunks(let time0, let index, let dt, let texts) = recorder.records.last else {
            Issue.record("Adjacent text deltas were not compacted")
            return
        }
        let firstTime = try logTime(start.addingTimeInterval(0.010))
        let secondTime = try logTime(start.addingTimeInterval(0.025))
        #expect(time0 == firstTime)
        #expect(index == 0)
        #expect(dt == [secondTime - firstTime])
        #expect(texts == ["A", "B"])
        #expect(Array(try recorder.records.expanded().map(\.time).suffix(2)) ==
            [firstTime, secondTime])
    }

    @Test func backwardsClockStartsANewTextRun() throws {
        var recorder = AgentSessionStreamRecorder()
        let block = AgentModelBlock(id: "answer", content: .text(""))
        let first = Date(timeIntervalSince1970: 2_000)
        try recorder.consume(.blockStarted(block), blocks: [block], at: first)
        try recorder.consume(.blockDelta(id: block.id, text: "A"), blocks: [block], at: first.addingTimeInterval(0.020))
        try recorder.consume(.blockDelta(id: block.id, text: "B"), blocks: [block], at: first.addingTimeInterval(-0.010))

        let runs = recorder.records.compactMap { record -> (Int, [Int], [String])? in
            guard case .textChunks(let time0, _, let dt, let texts) = record else { return nil }
            return (time0, dt, texts)
        }
        #expect(runs.count == 2)
        let forwardTime = try logTime(first.addingTimeInterval(0.020))
        let backwardTime = try logTime(first.addingTimeInterval(-0.010))
        #expect(runs[0].0 == forwardTime)
        #expect(runs[0].1.isEmpty)
        #expect(runs[0].2 == ["A"])
        #expect(runs[1].0 == backwardTime)
        #expect(runs[1].1.isEmpty)
        #expect(runs[1].2 == ["B"])
    }

    @Test func toolCallArgumentDeltasRemainToolCallChunksAndGroup() throws {
        var recorder = AgentSessionStreamRecorder()
        let initial = CanonicalToolCall(id: "call-1", name: "lookup", arguments: "{")
        let first = AgentModelBlock(id: "tool", content: .toolCall(initial))
        let second = AgentModelBlock(id: "tool", content: .toolCall(
            .init(id: initial.id, name: initial.name, arguments: "{\"id\":1}")))
        let start = Date(timeIntervalSince1970: 2_500)
        try recorder.consume(.blockStarted(first), blocks: [first], at: start)
        try recorder.consume(.blockDelta(id: first.id, text: "\"id\":1}"), blocks: [second],
            at: start.addingTimeInterval(0.005))

        guard case .toolCallChunks(let time0, let index, let dt, let id, let name, let args) = recorder.records.first(where: {
            if case .toolCallChunks = $0 { return true }
            return false
        }) else {
            Issue.record("Tool-call deltas were recorded as a non-tool stream chunk")
            return
        }
        #expect(time0 == 2_500_000)
        #expect(index == 0)
        let deltaEnd = try logTime(start.addingTimeInterval(0.005))
        let deltaStart = try logTime(start)
        let deltaTime = deltaEnd - deltaStart
        #expect(dt == [deltaTime])
        #expect(id == initial.id)
        #expect(name == initial.name)
        #expect(args == ["{", "\"id\":1}"])
    }

    @Test func failureEmitsSafeTerminalRecordWhenClockCannotBeEncoded() throws {
        var recorder = AgentSessionStreamRecorder()
        let block = AgentModelBlock(id: "answer", content: .text(""))
        try recorder.consume(.blockStarted(block), blocks: [block], at: Date(timeIntervalSince1970: 3_000))
        recorder.fail(.init(.cancelled, "synthetic cancellation"), at: Date(timeIntervalSince1970: -.infinity))

        guard case .chunk(let time, let chunk) = recorder.records.last,
              case .finish(let reason, replayState: nil) = chunk else {
            Issue.record("Failure did not emit a terminal stream record")
            return
        }
        #expect(time == 3_000_000)
        #expect(reason == .aborted(failure: .object(["code": .string(MiraError.Code.cancelled.rawValue),
            "message": .string("synthetic cancellation")])))
    }
}
