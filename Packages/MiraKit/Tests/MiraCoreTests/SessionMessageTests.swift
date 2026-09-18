import Foundation
import XCTest
@testable import MiraCore

final class SessionMessageTests: XCTestCase {
    func testMessageRoundTripUsesDSHShapeAndPreservesRawArgumentsAndReplayState() throws {
        let message = SessionMessage(
            id: "message-1",
            role: .assistant,
            content: [
                .reasoning("first, then a tool"),
                .toolCall(id: "call-1", name: "search", arguments: "{ \"q\": \"Mira\", \"limit\": 2 }"),
                .text("Done"),
            ],
            source: .model(provider: "fixture", model: "fixture-model", replayState: .object([
                "providerId": .string("response-7"),
                "nested": .array([.bool(true), .number(2)]),
            ]))
        )

        let data = try JSONEncoder().encode(message)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "message-1")
        XCTAssertEqual(object["role"] as? String, "assistant")
        let source = try XCTUnwrap(object["source"] as? [String: Any])
        XCTAssertEqual(source["kind"] as? String, "model")
        XCTAssertNil(source["unused"])

        let decoded = try JSONDecoder().decode(SessionMessage.self, from: data)
        XCTAssertEqual(decoded, message)
        guard case .toolCall(_, _, let arguments) = decoded.content[1] else {
            return XCTFail("Expected the tool-call block to remain in order")
        }
        XCTAssertEqual(arguments, "{ \"q\": \"Mira\", \"limit\": 2 }")
    }

    func testToolResultUsesUserRoleCorrelationAndOmitsOptionalError() throws {
        let message = SessionMessage(
            id: "tool-result-1",
            role: .user,
            content: [.toolResult(toolCallID: "call-1", content: [.text("2 results")])],
            source: .tool(callID: "call-1")
        )

        let data = try JSONEncoder().encode(message)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let content = try XCTUnwrap((object["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(content["type"] as? String, "tool-result")
        XCTAssertEqual(content["toolCallId"] as? String, "call-1")
        XCTAssertNil(content["isError"])
        XCTAssertEqual(try JSONDecoder().decode(SessionMessage.self, from: data), message)
    }

    func testCompactStreamRoundTripAndExpansionPreserveOrderAndDeltaBoundaries() throws {
        let stream: SessionMessageStream = [
            .chunk(time: 100, chunk: .blockStart(index: 0, blockType: "text")),
            .textChunks(time0: 105, index: 0, dt: [3, -1], texts: ["He", "ll", "o"]),
            .reasoningChunks(time0: 110, index: 1, dt: [], texts: ["why"]),
            .toolCallChunks(time0: 120, index: 2, dt: [4], id: "call-1", name: "search", args: ["{\"q\"", ":1}"]),
            .chunk(time: 130, chunk: .blockEnd(index: 0, block: .text("Hello"))),
            .chunk(time: 131, chunk: .finish(reason: .stop)),
        ]

        let data = try JSONEncoder().encode(stream)
        let decoded = try JSONDecoder().decode(SessionMessageStream.self, from: data)
        XCTAssertEqual(decoded, stream)

        let expanded = try decoded.expanded()
        XCTAssertEqual(expanded.map(\.time), [100, 105, 108, 107, 110, 120, 124, 130, 131])
        XCTAssertEqual(expanded.count, 9)
        guard case .textDelta(_, let first) = expanded[1].chunk,
              case .textDelta(_, let second) = expanded[2].chunk,
              case .textDelta(_, let third) = expanded[3].chunk,
              case .toolCallDelta(_, _, _, let firstArgument) = expanded[5].chunk,
              case .toolCallDelta(_, _, _, let secondArgument) = expanded[6].chunk else {
            return XCTFail("Expanded stream lost record order")
        }
        XCTAssertEqual([first, second, third], ["He", "ll", "o"])
        XCTAssertEqual([firstArgument, secondArgument], ["{\"q\"", ":1}"])
    }

    func testUsageConversionKeepsMissingCountersMissingAndUsesDSHInputMeaning() throws {
        let source = TokenUsage(inputTokens: 8, outputTokens: 3, cacheReadTokens: 4,
                                cacheWriteTokens: 2, reasoningTokens: 1,
                                inputTokenBasis: .includesCache)
        let usage = try XCTUnwrap(SessionMessageUsage(tokenUsage: source))
        XCTAssertEqual(usage.inputTokens, 2)
        XCTAssertEqual(usage.tokenUsage.inputTokenBasis, .excludesCache)
        XCTAssertEqual(usage.tokenUsage.totalInputTokens, 8)
        XCTAssertNil(SessionMessageUsage(tokenUsage: TokenUsage(inputTokens: nil, outputTokens: 3)))
    }

    func testCancellationUsesDSHNestedCauseAndControlEventsRejectSurfaceMetadata() throws {
        let reason = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            SessionLogTurnEndReason.aborted(reason: .user))) as? [String: Any]
        XCTAssertEqual(reason?["kind"] as? String, "aborted")
        XCTAssertEqual((reason?["reason"] as? [String: String])?["kind"], "user")
        XCTAssertThrowsError(try SessionLogEvent(seq: 1, time: 1,
            data: .turnStart(turn: 1), surfaceOp: .append).validate())
        XCTAssertThrowsError(try JSONDecoder().decode(SessionMessageStreamFinishReason.self,
            from: Data(#"{"kind":"error"}"#.utf8)))
    }

    func testStreamValidationRejectsNegativeBlockIndexesAndInvalidUsage() throws {
        XCTAssertThrowsError(try SessionMessageStreamRecord.chunk(
            time: 1, chunk: .textDelta(index: -1, text: "x")).validate())
        let invalid = SessionMessageUsage(inputTokens: -1, outputTokens: 1)
        XCTAssertThrowsError(try invalid.validate())
    }

    func testLogEventCodecKeepsDirectUserPayloadAndRejectsUnknownRequiredEvents() throws {
        let event = SessionLogEvent(seq: 3, time: 1_800_144_000_040,
                                    data: .userMessage(SessionMessage(id: "user-1", role: .user,
                                        content: [.text("Hello")], source: .user)),
                                    surfaceOp: .append)
        let encoded = try SessionLogEventCodec.encode(event)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "user/message")
        XCTAssertEqual(object["seq"] as? Int, 3)
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertNotNil(data["id"])
        XCTAssertNil(data["message"])
        XCTAssertEqual(try SessionLogEventCodec.decode(encoded), event)

        let unknown = Data(#"{"type":"mira/future","seq":4,"time":9,"data":{"x":1}}"#.utf8)
        XCTAssertThrowsError(try SessionLogEventCodec.decode(unknown))
        let ignorable = Data(#"{"type":"mira/future","seq":4,"time":9,"data":{"x":1},"ignorable":true}"#.utf8)
        let decoded = try SessionLogEventCodec.decode(ignorable)
        guard case .unknown(let type, let value) = decoded.data else {
            return XCTFail("Expected an opaque ignorable event")
        }
        XCTAssertEqual(type, "mira/future")
        XCTAssertEqual(value["x"], .number(1))
    }

    func testSemanticValidationRejectsRoleSourceAndMalformedToolArguments() throws {
        let toolResult = SessionMessage(id: "tool-result", role: .assistant,
                                        content: [.text("wrong role")], source: .tool(callID: "call-1"))
        XCTAssertThrowsError(try toolResult.validate())

        let malformed = SessionMessage(id: "assistant-1", role: .assistant,
            content: [.toolCall(id: "call-1", name: "search", arguments: "not-json")],
            source: .model(provider: "fixture", model: "fixture-model"))
        XCTAssertThrowsError(try malformed.validate())
    }

    func testEventValidationRequiresSurfacePlacementAndBackwardSourceReferences() throws {
        let data = SessionLogEventData.userMessage(SessionMessage(id: "user-1", role: .user,
            content: [.text("hello")], source: .user))
        XCTAssertThrowsError(try SessionLogEvent(seq: 3, time: 10, data: data).validate())

        let event = SessionLogEvent(seq: 3, time: 10, data: data, surfaceOp: .append,
                                    sourceEventSeqs: [1, 2])
        XCTAssertNoThrow(try event.validate())
        XCTAssertThrowsError(try SessionLogEvent(seq: 3, time: 10, data: data,
            surfaceOp: .append, sourceEventSeqs: [3]).validate())
        XCTAssertThrowsError(try SessionLogSurfaceOperation.replace(startSeq: 5, endSeq: 2).validate())
    }
}
