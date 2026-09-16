import Foundation
import Testing
@testable import MiraCore

struct AgentRequestManifestTests {
    @Test func readPreservesTypedEntriesAndContinuation() async throws {
        let sid = ConversationID(), eid = ExecutionID(), step = UUID()
        let adapter = AgentAdapterIdentity(id: "manifest.test", revision: 1)
        let route = AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
            modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1,
            adapter: adapter, invocationID: "invoke", invocationRevision: 1, endpointID: "endpoint", metadataEvidence: [],
            modelID: "model", credential: nil, contextWindow: 8192, maximumOutputTokens: 512,
            capabilities: .init(streamsText: true, callsTools: false, producesThinking: true), configuration: .object([:]))
        let request = AgentContextRequest(sessionID: sid, executionID: eid, workspaceID: nil, userText: "last", authorizationEpoch: 1, destination: .model(route))
        let continuation = AgentModelContinuation(adapter: adapter, format: "opaque", payload: .object(["x": .string("y")]), isComplete: true)
        let messages = [
            AgentModelMessage(role: .user, blocks: [.init(id: "u-old", content: .text("old"))]),
            AgentModelMessage(role: .assistant, blocks: [.init(id: "thinking-7", content: .thinking("t")), .init(id: "answer-9", content: .text("a"))], continuation: continuation),
            AgentModelMessage(role: .user, blocks: [.init(id: "u-final", content: .text("last"))])]
        let headerRef = ref(sid, .requestComponent), firstRef = ref(sid, .requestComponent), secondRef = ref(sid, .requestComponent), finalRef = ref(sid, .userText), requestRef = ref(sid, .request)
        let header = AgentRequestManifest.Header(instructions: "instructions", tools: [], allowsToolCalls: false, outputTokenLimit: 100, adapter: adapter)
        let manifest = AgentRequestManifest(request: request, executionID: eid, stepID: step, header: headerRef, prefixMessageCount: 2, estimatedInputTokens: 10, currentUserMessageIndex: 2, inheritedSources: [], evidence: [], omissions: [], entries: [
            .init(reference: firstRef, representation: .message), .init(reference: secondRef, representation: .message), .init(reference: finalRef, representation: .userText, blockID: "u-final")])
        let reader = Reader(values: [headerRef: try SessionCodec.encode(header), firstRef: try SessionCodec.encode(messages[0]), secondRef: try SessionCodec.encode(messages[1]), finalRef: Data("last".utf8), requestRef: try SessionCodec.encode(manifest)])
        let restored = try await AgentRequestRecord.read(requestRef, payloads: reader)
        #expect(restored.input.messages == messages)
        #expect(restored.input.prefixMessageCount == 2)
        #expect(restored.input.messages[1].continuation == continuation)
    }

    @Test func wrongKindAndMissingComponentAreRejected() async throws {
        let sid = ConversationID(), bad = ref(sid, .modelOutput)
        let reader = Reader(values: [:])
        await #expect(throws: MiraError.self) { try await AgentRequestRecord.read(bad, payloads: reader) }
    }

    private func ref(_ sid: ConversationID, _ kind: SessionPayloadKind) -> SessionPayloadReference {
        .init(id: UUID(), sessionID: sid, batchID: UUID(), retentionGroup: UUID(), kind: kind, byteCount: 1, digest: String(repeating: "0", count: 64))
    }
}

private struct Reader: SessionPayloadReader {
    let values: [SessionPayloadReference: Data]
    func read(_ reference: SessionPayloadReference) async throws -> Data { guard let data = values[reference] else { throw MiraError(.storage, "missing") }; return data }
}
