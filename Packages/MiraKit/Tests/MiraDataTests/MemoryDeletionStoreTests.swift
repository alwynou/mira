import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Memory deletion queue", .timeLimit(.minutes(1)))
struct MemoryDeletionStoreTests {
    @Test func queueIsDurableBodyFreeAndCannotBeMarkedCompleteWithoutMaintenance() async throws {
        try await withTaskWorkflow(
            outputs: [[.blockStarted(.init(id: "text", content: .text("received"))), .blockFinished(id: "text"), .finished(.stop)]],
            memoryEnabled: true
        ) { fixture in
            let store = try #require(fixture.memory)
            let address = try await fixture.run("Please forget my tea preference")
            let evidence = try await fixture.evidence(address)
            let memory = try await store.createMemory(
                draft: .init(content: "I prefer green tea", scope: .global),
                source: .userMessage(evidence: evidence, excerpt: "tea preference"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: try await fixture.authority.authorization(),
                at: TaskWorkflowFixture.now).memory
            let request = MemoryDeletionRequest(
                id: UUID(), target: .init(memoryID: memory.id, revision: memory.revision),
                source: evidence.reference, executionID: address.executionID, workspaceID: evidence.workspaceID,
                requestedAt: TaskWorkflowFixture.now)
            try await fixture.database.write { db in _ = try SQLiteMemoryStore.enqueueDeletionInTransaction(request, in: db) }
            let pending = try await store.pendingMemoryDeletions(limit: 8)
            #expect(pending == [request])
            let raw = try await fixture.database.read { db in
                try Data.fetchOne(db, sql: "SELECT source_json || json FROM memory_deletion_requests WHERE id = ?",
                                 arguments: [request.id.uuidString.lowercased()])
            }
            #expect(try #require(raw).count < 4_096)
            await #expect(throws: MiraError.self) {
                try await store.settleMemoryDeletion(request, state: .completed,
                                                     authorization: try await fixture.authority.authorization())
            }
            #expect(try await store.pendingMemoryDeletions(limit: 8) == [request])
        }
    }

    @Test func completedQueueRowRequiresTheExactDurableForgetOperation() async throws {
        try await withTaskWorkflow(
            outputs: [[.blockStarted(.init(id: "text", content: .text("received"))), .blockFinished(id: "text"), .finished(.stop)]],
            memoryEnabled: true
        ) { fixture in
            let store = try #require(fixture.memory)
            let address = try await fixture.run("Forget this exact preference")
            let evidence = try await fixture.evidence(address)
            let memory = try await store.createMemory(
                draft: .init(content: "I prefer oolong tea", scope: .global),
                source: .userMessage(evidence: evidence, excerpt: "exact preference"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: try await fixture.authority.authorization(),
                at: TaskWorkflowFixture.now).memory
            let request = MemoryDeletionRequest(
                id: UUID(), target: .init(memoryID: memory.id, revision: memory.revision),
                source: evidence.reference, executionID: address.executionID, workspaceID: evidence.workspaceID,
                requestedAt: TaskWorkflowFixture.now)
            try await fixture.database.write { db in _ = try SQLiteMemoryStore.enqueueDeletionInTransaction(request, in: db) }
            let initial = try await fixture.authority.authorization()
            let operation = try await fixture.authority.begin(request.maintenanceRequest, expected: initial)
            let scope = try await store.memoryForgetScope(operation: operation)
            try await store.purgeMemoryForget(scope, operation: operation)
            _ = try await fixture.authority.complete(operation, at: request.requestedAt)
            try await store.settleMemoryDeletion(request, state: .completed,
                                                  authorization: try await fixture.authority.authorization())
            #expect(try await store.pendingMemoryDeletions(limit: 8).isEmpty)
            let all = try await fixture.database.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_deletion_requests WHERE state = 'completed'")
            }
            #expect(all == 1)
        }
    }
}
