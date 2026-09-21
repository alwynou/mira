import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Historical memory context source authorization")
struct MemoryContextSourceTests {
    @Test func exactRetainedRevisionSurvivesSupersessionButCurrentToolValidationDoesNot() async throws {
        try await withTaskWorkflow(outputs: [completion()], memoryEnabled: true) { fixture in
            let (store, source, old) = try await supersededMemory(in: fixture)
            let reference = memorySource(old.id, revision: 1)
            try await store.validateMemoryContextSources([reference], for: modelRequest(fixture), at: TaskWorkflowFixture.now)

            await #expect(throws: MiraError.self) {
                try await store.validateMemorySources([reference], for: modelRequest(fixture), at: TaskWorkflowFixture.now)
            }
            await #expect(throws: MiraError.self) {
                try await store.validateMemoryContextSources(
                    [memorySource(old.id, revision: 99)], for: modelRequest(fixture), at: TaskWorkflowFixture.now)
            }
            #expect(source.text == "I ride a blue bicycle.")
        }
    }

    @Test func historicalRevisionStillRequiresCurrentDisclosurePolicy() async throws {
        try await withTaskWorkflow(outputs: [completion()], memoryEnabled: true) { fixture in
            let (store, _, old) = try await supersededMemory(in: fixture)
            var restricted = try await store.memoryDetail(old.id, workspaceID: nil).memory
            restricted.revision += 1
            restricted.updatedAt = TaskWorkflowFixture.now.addingTimeInterval(1)
            restricted.draft?.allowsRemoteUse = false
            try await store.reviseMemory(
                old.id, workspaceID: nil, draft: try #require(restricted.draft),
                expectedRevision: restricted.revision - 1, operationID: UUID(),
                authorization: try await fixture.authority.authorization(), at: restricted.updatedAt)

            await #expect(throws: MiraError.self) {
                try await store.validateMemoryContextSources(
                    [memorySource(old.id, revision: 1)], for: modelRequest(fixture), at: TaskWorkflowFixture.now)
            }
        }
    }

    @Test func suppressedEvidenceRevokesHistoricalContextSource() async throws {
        try await withTaskWorkflow(outputs: [completion()], memoryEnabled: true) { fixture in
            let (store, source, old) = try await supersededMemory(in: fixture)
            try await fixture.database.write { db in
                try SQLiteMemoryStore.suppress(.userMessage(source.reference), strength: 1, in: db)
            }

            await #expect(throws: MiraError.self) {
                try await store.validateMemoryContextSources(
                    [memorySource(old.id, revision: 1)], for: modelRequest(fixture), at: TaskWorkflowFixture.now)
            }
        }
    }

    @Test func archivedMemoryCannotAuthorizeHistoricalContext() async throws {
        try await withTaskWorkflow(outputs: [completion()], memoryEnabled: true) { fixture in
            let (store, _, old) = try await supersededMemory(in: fixture)
            _ = try await store.changeMemoryState(
                old.id, workspaceID: nil, state: .archived, expectedRevision: old.revision,
                operationID: UUID(), authorization: try await fixture.authority.authorization(),
                at: TaskWorkflowFixture.now.addingTimeInterval(2))

            await #expect(throws: MiraError.self) {
                try await store.validateMemoryContextSources(
                    [memorySource(old.id, revision: 1)], for: modelRequest(fixture), at: TaskWorkflowFixture.now)
            }
        }
    }

    private func supersededMemory(in fixture: TaskWorkflowFixture) async throws
        -> (SQLiteMemoryStore, SessionUserEvidence, Memory) {
        let store = try #require(fixture.memory)
        let address = try await fixture.run("I ride a blue bicycle.")
        let source = try await fixture.evidence(address)
        let authorization = try await fixture.authority.authorization()
        let original = try await store.createMemory(
            draft: .init(content: "I ride a bicycle.", scope: .global),
            source: .userMessage(evidence: source, excerpt: source.text), operationID: UUID(),
            replacing: nil, expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now).memory
        let replacement = try await store.createMemory(
            draft: .init(content: "I ride a blue bicycle.", scope: .global),
            source: .userMessage(evidence: source, excerpt: source.text), operationID: UUID(),
            replacing: original.id, expectedRevision: original.revision,
            authorization: authorization, at: TaskWorkflowFixture.now.addingTimeInterval(1)).memory
        #expect(replacement.id != original.id)
        let old = try await store.memoryDetail(original.id, workspaceID: nil).memory
        #expect(old.supersededBy == replacement.id)
        return (store, source, old)
    }

    private func memorySource(_ id: MemoryID, revision: Int) -> AgentSourceReference {
        .domain(namespace: "memories", id: id.rawValue, revision: revision)
    }

    private func modelRequest(_ fixture: TaskWorkflowFixture) -> AgentContextRequest {
        .init(sessionID: .init(), executionID: .init(), workspaceID: nil,
              userText: "Synthetic continuation", authorizationEpoch: 0,
              destination: .model(fixture.route))
    }

    private func completion() -> [AgentModelStreamEvent] {
        [.blockStarted(.init(id: "text", content: .text("Synthetic completion"))),
         .blockFinished(id: "text"), .finished(.stop)]
    }
}
