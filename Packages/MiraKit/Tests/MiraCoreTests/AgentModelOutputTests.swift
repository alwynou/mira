import Foundation
import Testing
@testable import MiraCore

struct AgentModelOutputTests {
    @Test func activityTracksLatestBlockRatherThanRetainedThinking() throws {
        var accumulator = try AgentModelAccumulator(route: route())
        #expect(accumulator.outputPhase == .waiting)
        try accumulator.consume(.blockStarted(.init(id: "reasoning", content: .thinking("Plan"))))
        #expect(accumulator.outputPhase == .thinking)
        // Chat adapters can leave reasoning open until the complete response ends.
        try accumulator.consume(.blockStarted(.init(id: "answer", content: .text("Reply"))))
        #expect(accumulator.outputPhase == .answering)
        #expect(accumulator.thinkingText == "Plan")
        try accumulator.consume(.blockFinished(id: "reasoning"))
        #expect(accumulator.outputPhase == .answering)
        try accumulator.consume(.blockFinished(id: "answer"))
        #expect(accumulator.outputPhase == .waiting)
        try accumulator.consume(.blockStarted(.init(id: "tool", content: .toolCall(call("one")))))
        #expect(accumulator.outputPhase == .callingTool)
        try accumulator.consume(.blockFinished(id: "tool"))
        #expect(accumulator.outputPhase == .callingTool)
    }

    @Test func finishingThinkingUpdatesActivityWithoutAnAnswerDelta() throws {
        var accumulator = try AgentModelAccumulator(route: route())
        try accumulator.consume(.blockStarted(.init(id: "reasoning", content: .thinking("Plan"))))
        try accumulator.consume(.blockFinished(id: "reasoning"))
        #expect(accumulator.outputPhase == .waiting)
        #expect(accumulator.thinkingText == "Plan")
    }
    @Test func undeclaredThinkingRemainsFirstClassOutput() throws {
        let route = route(producesThinking: false)
        var accumulator = try AgentModelAccumulator(route: route)
        try accumulator.consume(.blockStarted(.init(id: "reasoning", content: .thinking("Provider output"))))
        try accumulator.consume(.blockFinished(id: "reasoning"))
        try accumulator.consume(.finished(.stop))
        let output = try accumulator.finish()
        #expect(output.thinkingText == "Provider output")
        try output.validate(for: route, replay: true)
    }
    @Test func preservesOrderedMultiBlockOutputAndProjections() throws {
        let call = CanonicalToolCall(id: "one", name: "tool", arguments: "{\"value\":1}")
        var accumulator = try AgentModelAccumulator(route: route())
        try accumulator.consume(.blockStarted(.init(id: "answer", content: .text(""))))
        try accumulator.consume(.blockDelta(id: "answer", text: "hello"))
        try accumulator.consume(.blockFinished(id: "answer"))
        try accumulator.consume(.blockStarted(.init(id: "reasoning", content: .thinking(""))))
        try accumulator.consume(.blockDelta(id: "reasoning", text: "private"))
        try accumulator.consume(.blockFinished(id: "reasoning"))
        try accumulator.consume(.blockStarted(.init(id: "call-block", content: .toolCall(call))))
        try accumulator.consume(.blockFinished(id: "call-block"))
        try accumulator.consume(.finished(.toolCalls))
        let output = try accumulator.finish()
        #expect(output.blocks.map(\.id) == ["answer", "reasoning", "call-block"])
        #expect(output.text == "hello")
        #expect(output.thinkingText == "private")
        #expect(output.toolCalls == [call])
        #expect(output.message.blocks == output.blocks)
    }

    @Test func hiddenContinuationDoesNotRequireVisibleThinking() throws {
        let adapter = AgentAdapterIdentity(id: "opaque.family", revision: 2)
        let continuation = AgentModelContinuation(adapter: adapter, format: "opaque.blocks",
            payload: .object(["signed": .string("raw")]), isComplete: true)
        var accumulator = try AgentModelAccumulator(route: route(adapter: adapter))
        try accumulator.consume(.blockStarted(.init(id: "answer", content: .text("visible"))))
        try accumulator.consume(.blockFinished(id: "answer"))
        try accumulator.consume(.continuation(continuation))
        try accumulator.consume(.finished(.stop))
        let output = try accumulator.finish()
        #expect(output.thinkingText.isEmpty)
        #expect(output.continuation == continuation)
        try output.validate(for: route(adapter: adapter), replay: true)
    }

    @Test func continuationCanStandAloneWhenVisibleOutputIsAbsent() throws {
        let adapter = AgentAdapterIdentity(id: "opaque.family", revision: 2)
        let continuation = AgentModelContinuation(adapter: adapter, format: "opaque.blocks", payload: .null, isComplete: true)
        var accumulator = try AgentModelAccumulator(route: route(adapter: adapter))
        try accumulator.consume(.continuation(continuation))
        try accumulator.consume(.finished(.stop))
        let output = try accumulator.finish()
        #expect(output.blocks.isEmpty)
        #expect(output.continuation == continuation)
    }

    @Test func requiresExplicitBlockCompletionAndRejectsLateEvents() throws {
        var accumulator = try AgentModelAccumulator(route: route())
        try accumulator.consume(.blockStarted(.init(id: "answer", content: .text("hello"))))
        #expect(throws: MiraError.self) { try accumulator.consume(.finished(.stop)) }
        try accumulator.consume(.blockFinished(id: "answer"))
        try accumulator.consume(.finished(.stop))
        #expect(throws: MiraError.self) {
            try accumulator.consume(.blockDelta(id: "answer", text: "late"))
        }
    }

    @Test func rejectsDuplicateBlocksToolIDsAndMalformedArguments() throws {
        var duplicateBlock = try AgentModelAccumulator(route: route())
        let block = AgentModelBlock(id: "answer", content: .text("x"))
        try duplicateBlock.consume(.blockStarted(block))
        #expect(throws: MiraError.self) { try duplicateBlock.consume(.blockStarted(block)) }

        var duplicateTool = try AgentModelAccumulator(route: route())
        let first = AgentModelBlock(id: "call-1", content: .toolCall(call("same")))
        try duplicateTool.consume(.blockStarted(first))
        try duplicateTool.consume(.blockFinished(id: first.id))
        #expect(throws: MiraError.self) {
            try duplicateTool.consume(.blockStarted(.init(id: "call-2", content: .toolCall(call("same")))))
        }

        var malformed = try AgentModelAccumulator(route: route())
        #expect(throws: MiraError.self) {
            try malformed.consume(.blockStarted(.init(id: "bad", content: .toolCall(.init(id: "bad", name: "tool", arguments: "[]")))))
        }
    }

    @Test func genuineSemanticBlockLimitRemainsEnforced() throws {
        var accumulator = try AgentModelAccumulator(route: route())
        for index in 0..<64 {
            let id = "block-\(index)"
            try accumulator.consume(.blockStarted(.init(id: id, content: .text("part"))))
            try accumulator.consume(.blockFinished(id: id))
        }
        #expect(accumulator.blocks.count == 64)
        #expect(throws: MiraError(.outputLimit, "The model output exceeded its block limit.")) {
            try accumulator.consume(.blockStarted(.init(id: "overflow", content: .text("part"))))
        }
    }

    @Test func enforcesBoundsCapabilitiesAndFinishReasons() throws {
        var text = try AgentModelAccumulator(route: route(), maximumTextBytes: 3)
        try text.consume(.blockStarted(.init(id: "answer", content: .text(""))))
        try text.consume(.blockDelta(id: "answer", text: "abc"))
        #expect(throws: MiraError.self) { try text.consume(.blockDelta(id: "answer", text: "d")) }

        var noTools = try AgentModelAccumulator(route: route(callsTools: false))
        #expect(throws: MiraError.self) {
            try noTools.consume(.blockStarted(.init(id: "call", content: .toolCall(call("one")))))
        }
        var noCalls = try AgentModelAccumulator(route: route())
        #expect(throws: MiraError.self) { try noCalls.consume(.finished(.toolCalls)) }
    }

    @Test func usageSnapshotsAreMonotonicAndRetainUnknownCounters() throws {
        var accumulator = try AgentModelAccumulator(route: route())
        try accumulator.consume(.usage(.init(inputTokens: 10, outputTokens: nil)))
        try accumulator.consume(.usage(.init(inputTokens: 12, outputTokens: 3)))
        #expect(accumulator.usage.inputTokens == 12)
        #expect(accumulator.usage.outputTokens == 3)
        #expect(throws: MiraError.self) { try accumulator.consume(.usage(.init(inputTokens: 11, outputTokens: 4))) }
    }

    private func call(_ id: String) -> CanonicalToolCall {
        .init(id: id, name: "tool", arguments: "{\"value\":1}")
    }

    private func route(adapter: AgentAdapterIdentity = .init(id: "output.family", revision: 1),
                       callsTools: Bool = true, producesThinking: Bool = true) -> AgentModelRoute {
        .init(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
              modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1,
              adapter: adapter, invocationID: "output-invocation", invocationRevision: 1,
              endpointID: "output-endpoint", metadataEvidence: [], modelID: "model", credential: nil,
              contextWindow: 8_192, maximumOutputTokens: 1_024,
              capabilities: .init(streamsText: true, callsTools: callsTools, producesThinking: producesThinking),
              configuration: .object([:]))
    }
}
