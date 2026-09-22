import Foundation
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Foreground memory retraction workflow", .timeLimit(.minutes(1)))
struct MemoryRetractionWorkflowTests {
    @Test func modelToolLoopArchivesExactTargetAndReturnsCommittedReceipt() async throws {
        try await withTaskWorkflow(memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let authorization = try await fixture.authority.authorization()
            let memory = try await store.createMemory(
                draft: .init(content: "I prefer early flights", scope: .global),
                source: .manualEntry(id: UUID(), statement: "I prefer early flights"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: authorization,
                at: TaskWorkflowFixture.now).memory
            let quote = "Actually that was only true for one trip because no other options."
            let call = CanonicalToolCall(id: "retract", name: "memory.retract", arguments: try JSONValue.object([
                "memory_id": .string(memory.id.rawValue.uuidString.lowercased()),
                "revision": .number(Double(memory.revision)), "quote": .string(quote)
            ]).jsonString())
            await fixture.model.append([modelToolStream([call]), completionReply("Acknowledged the withdrawal.")])

            let address = try await fixture.run(quote)
            let snapshot = try await fixture.runtime.sessionSnapshot(id: address.sessionID)
            let invocation = try #require(snapshot.invocations.values.first)
            #expect(invocation.resolution?.status == .succeeded)
            #expect(invocation.resolution?.businessReceipt != nil)
            let resultReference = try #require(invocation.resolution?.result)
            let result = try SessionCodec.decode(JSONValue.self, from: await fixture.library.read(resultReference))
            #expect(result["state"] == .string("archived"))
            #expect(result["disposition"] == .string("retracted"))
            #expect(result["acknowledgment"]?.stringValue?.contains("withdrawn") == true)
            // The mutation receipt must not advertise the archived assertion as
            // a new current fact or offer an unrecorded revision as a citation.
            #expect(result["reference"] == nil)
            #expect(result["allows_remote_use"] == nil)

            let detail = try await store.memoryDetail(memory.id, workspaceID: nil)
            #expect(detail.memory.state == .archived)
            #expect(detail.memory.retraction?.priorRevision == memory.revision)
            #expect(detail.memory.retraction?.revision == memory.revision + 1)
            #expect(detail.revisions.contains { $0.revision == memory.revision && $0.draft?.content == "I prefer early flights" })
            #expect(detail.memory.draft?.content == "I prefer early flights")
        }
    }

    @Test func staleTargetIsRejectedWithoutMutation() async throws {
        try await withTaskWorkflow(memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let authorization = try await fixture.authority.authorization()
            let memory = try await store.createMemory(
                draft: .init(content: "I prefer early flights", scope: .global),
                source: .manualEntry(id: UUID(), statement: "I prefer early flights"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: authorization,
                at: TaskWorkflowFixture.now).memory
            let quote = "Actually that was only true for one trip because no other options."
            let call = CanonicalToolCall(id: "stale", name: "memory.retract", arguments: try JSONValue.object([
                "memory_id": .string(memory.id.rawValue.uuidString.lowercased()),
                "revision": .number(Double(memory.revision + 1)), "quote": .string(quote)
            ]).jsonString())
            await fixture.model.append([modelToolStream([call]), completionReply("Could not withdraw the stale memory.")])
            let address = try await fixture.run(quote)
            let state = try await store.memoryDetail(memory.id, workspaceID: nil)
            #expect(state.memory.state == .active)
            #expect(state.memory.revision == memory.revision)
            let snapshot = try await fixture.runtime.sessionSnapshot(id: address.sessionID)
            #expect(snapshot.invocations.values.allSatisfy { $0.resolution?.businessReceipt == nil })
            #expect(state.memory.retraction == nil)
        }
    }
}

private func completionReply(_ text: String) -> [AgentModelStreamEvent] {
    [.blockStarted(.init(id: "text", content: .text(text))), .blockFinished(id: "text"), .finished(.stop)]
}
