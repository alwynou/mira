import Foundation
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Memory forget through the current kernel", .timeLimit(.minutes(1)))
struct MemoryForgetWorkflowTests {
    @Test func forgetPurgesDomainRecordsWithoutChangingSessionHistory() async throws {
        let input: JSONValue = .object([
            "content": .string("I prefer green tea"), "quote": .string("I prefer green tea"),
            "kind": .string("preference"), "scope": .string("current"), "sensitive": .bool(false),
        ])
        let remember = try CanonicalToolCall(
            id: "remember", name: "memory.remember", arguments: input.jsonString())
        try await withTaskWorkflow(
            outputs: [
                modelToolStream([remember]),
                [.blockStarted(.init(id: "text", content: .text("Saved locally."))), .blockFinished(id: "text"), .finished(.stop)],
            ], memoryEnabled: true
        ) { f in
            let source = try await f.run("Remember: I prefer green tea")
            let store = try #require(f.memory)
            let original = try #require(
                try await store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 10).memories.first)
            let request = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: "memory.forget", revision: 1,
                scope: .sources([.domain(namespace: "memories", id: original.id.rawValue, revision: original.revision)]),
                requestedAt: TaskWorkflowFixture.now)
            let expected = try await f.authority.authorization()
            #expect(await f.runtime.shutdown().isSettled)
            let operation = try await f.access.begin(request, expected: expected)
            let handler = MemoryForgetHandler(memories: store)
            try await handler.apply(operation)
            try await handler.verify(operation)
            _ = try await f.access.complete(operation, at: TaskWorkflowFixture.now)

            let detail = try await store.memoryDetail(original.id, workspaceID: nil)
            #expect(detail.memory.forgottenAt == request.requestedAt)
            #expect(detail.memory.draft == nil)
            #expect(detail.revisions.allSatisfy { $0.draft == nil && $0.bodyPurgedAt != nil })
            #expect(detail.evidence.allSatisfy { $0.excerpt == nil && $0.sourceHash == nil })

            let head = try await f.library.head(sessionID: source.sessionID)
            #expect(head != nil)
            let state = try await JournalSessionReader(journal: f.library, payloads: f.library)
                .snapshot(sessionID: source.sessionID).state
            #expect(state.executions[source.executionID] != nil)
        }
    }
}
