import Foundation
import GRDB
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Memory deletion workflow")
struct MemoryDeletionWorkflowTests {
    @Test("successful delete returns a pending receipt and preserves memory until maintenance")
    func successfulDelete() async throws {
        try await withTaskWorkflow(outputs: [reply("Acknowledged.")], memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let sourceAddress = try await fixture.run("I prefer green tea.")
            let sourceEvidence = try await fixture.evidence(sourceAddress)
            let memory = try await store.createMemory(
                draft: .init(content: "Prefers green tea", scope: .global, kind: .preference),
                source: .userMessage(evidence: sourceEvidence, excerpt: sourceEvidence.text), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: try await fixture.authority.authorization(), at: TaskWorkflowFixture.now
            ).memory
            let text = "Please forget my green tea preference."
            let call = try deleteCall(id: "delete", memory: memory, quote: text)
            await fixture.model.append([modelToolStream([call]), reply("Deletion request submitted.")])
            let address = try await fixture.run(text)
            let snapshot = try await fixture.runtime.sessionSnapshot(id: address.sessionID)
            let invocation = try #require(snapshot.invocations.values.first(where: { $0.invocation.toolName == "memory.delete" }))
            #expect(invocation.resolution?.status == .succeeded)
            let result = try SessionCodec.decode(JSONValue.self, from: await fixture.library.read(try #require(invocation.resolution?.result)))
            #expect(result["state"] == .string("pending"))
            let requestIDString = try #require(result["request_id"]?.stringValue)
            let requestID = try #require(UUID(uuidString: requestIDString))
            let pending = try #require(try await store.pendingMemoryDeletions(limit: 8).first(where: { $0.id == requestID }))
            #expect(pending.target == .init(memoryID: memory.id, revision: memory.revision))
            #expect(pending.source.sessionID == address.sessionID)
            #expect(pending.source.originalExecutionID == address.executionID)
            #expect(try await store.memoryDetail(memory.id, workspaceID: nil).memory.draft?.content == "Prefers green tea")
            let queueJSON = try await fixture.database.read { db in
                let bytes = try Data.fetchOne(db, sql: "SELECT json FROM memory_deletion_requests WHERE id = ?", arguments: [requestID.uuidString.lowercased()])
                return String(decoding: try #require(bytes), as: UTF8.self)
            }
            #expect(try SessionCodec.decode(MemoryDeletionRequest.self, from: Data(queueJSON.utf8)) == pending)
            #expect(!queueJSON.contains(text))
            let deleteEvidence = try await fixture.evidence(address)
            #expect(try await fixture.database.read { db in
                try SQLiteMemoryStore.memoryCaptureSuppressed(.userMessage(deleteEvidence.reference), in: db)
            })
            try await inspectArchive(fixture)
        }
    }

    @Test("maintenance completion purges memory and suppresses its original source")
    func completedDeleteSuppressesSource() async throws {
        try await withTaskWorkflow(outputs: [reply("Acknowledged.")], memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let sourceAddress = try await fixture.run("My favorite color is amber.")
            let evidence = try await fixture.evidence(sourceAddress)
            let memory = try await store.createMemory(
                draft: .init(content: "Favorite color amber", scope: .global),
                source: .userMessage(evidence: evidence, excerpt: evidence.text), operationID: UUID(), replacing: nil,
                expectedRevision: nil, authorization: try await fixture.authority.authorization(), at: TaskWorkflowFixture.now).memory
            let text = "Please forget my favorite color."
            let call = try deleteCall(id: "delete", memory: memory, quote: text)
            await fixture.model.append([modelToolStream([call]), reply("Deletion request submitted.")])
            let deleteAddress = try await fixture.run(text)
            let deleteEvidence = try await fixture.evidence(deleteAddress)
            let pending = try #require(try await store.pendingMemoryDeletions(limit: 8).first)
            try await complete(pending, fixture: fixture, store: store)
            #expect(try await store.memoryDetail(memory.id, workspaceID: nil).memory.draft == nil)
            #expect(try await fixture.database.read { db in
                try SQLiteMemoryStore.memoryCaptureSuppressed(.userMessage(evidence.reference), in: db)
            })
            await #expect(throws: MiraError.self) {
                _ = try await store.createMemory(
                    draft: .init(content: "Recreated amber", scope: .global),
                    source: .userMessage(evidence: deleteEvidence, excerpt: deleteEvidence.text), operationID: UUID(), replacing: nil,
                    expectedRevision: nil, authorization: try await fixture.authority.authorization(), at: TaskWorkflowFixture.now)
            }
            try await inspectArchive(fixture)
        }
    }

    @Test("stale, unauthorized-scope, and forged-quote deletes are rejected")
    func rejectsInvalidRequests() async throws {
        try await withTaskWorkflow(outputs: [], memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let memory = try await store.createMemory(draft: .init(content: "A fact", scope: .global), source: .manualEntry(id: UUID(), statement: "A fact"), operationID: UUID(), replacing: nil, expectedRevision: nil, authorization: try await fixture.authority.authorization(), at: TaskWorkflowFixture.now).memory
            let old = memory.revision
            _ = try await store.reviseMemory(memory.id, workspaceID: nil, draft: .init(content: "Changed", scope: .global), expectedRevision: old, operationID: UUID(), authorization: try await fixture.authority.authorization(), at: TaskWorkflowFixture.now)
            let call = try deleteCall(id: "stale", memory: memory, quote: "Forget the stale fact.", revision: old)
            await fixture.model.append([modelToolStream([call]), reply("Rejected.")])
            _ = try await fixture.run("Forget the stale fact.")
            #expect(try await store.pendingMemoryDeletions(limit: 8).isEmpty)
        }

        try await withTaskWorkflow(outputs: [], memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let workspaceA = Workspace(id: .init(), name: "A")
            let workspaceB = Workspace(id: .init(), name: "B")
            try await fixture.workspaces.saveWorkspace(workspaceA, expectedRevision: nil, authorization: try await fixture.authority.authorization())
            try await fixture.workspaces.saveWorkspace(workspaceB, expectedRevision: nil, authorization: try await fixture.authority.authorization())
            let memory = try await store.createMemory(draft: .init(content: "Private fact", scope: .workspace(workspaceA.id)), source: .manualEntry(id: UUID(), statement: "Private fact"), operationID: UUID(), replacing: nil, expectedRevision: nil, authorization: try await fixture.authority.authorization(), at: TaskWorkflowFixture.now).memory
            let call = try deleteCall(id: "scope", memory: memory, quote: "Forget the private fact.")
            await fixture.model.append([modelToolStream([call]), reply("Rejected.")])
            _ = try await fixture.run("Forget the private fact.", workspaceID: workspaceB.id)
            #expect(try await store.pendingMemoryDeletions(limit: 8).isEmpty)
        }

        try await withTaskWorkflow(outputs: [], memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let memory = try await store.createMemory(draft: .init(content: "Quoted fact", scope: .global), source: .manualEntry(id: UUID(), statement: "Quoted fact"), operationID: UUID(), replacing: nil, expectedRevision: nil, authorization: try await fixture.authority.authorization(), at: TaskWorkflowFixture.now).memory
            let call = try deleteCall(id: "quote", memory: memory, quote: "Absent from the user message.")
            await fixture.model.append([modelToolStream([call]), reply("Rejected.")])
            _ = try await fixture.run("Forget the quoted fact.")
            #expect(try await store.pendingMemoryDeletions(limit: 8).isEmpty)
        }
    }

    @Test("queue deduplication and transaction rollback preserve one-or-zero receipt")
    func dedupeAndRollback() async throws {
        try await withTaskWorkflow(outputs: [reply("Acknowledged.")], memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let sourceAddress = try await fixture.run("I remember one fact.")
            let sourceEvidence = try await fixture.evidence(sourceAddress)
            let memory = try await store.createMemory(draft: .init(content: "One fact", scope: .global), source: .userMessage(evidence: sourceEvidence, excerpt: sourceEvidence.text), operationID: UUID(), replacing: nil, expectedRevision: nil, authorization: try await fixture.authority.authorization(), at: TaskWorkflowFixture.now).memory
            let call = try deleteCall(id: "duplicate", memory: memory, quote: "Forget one fact.")
            await fixture.model.append([modelToolStream([call]), reply("Deletion request submitted.")])
            _ = try await fixture.run("Forget one fact.")
            let pending = try #require(try await store.pendingMemoryDeletions(limit: 8).first)
            let duplicate = try await fixture.database.write { db in try SQLiteMemoryStore.enqueueDeletionInTransaction(pending, in: db) }
            #expect(duplicate == pending)
            #expect(try await store.pendingMemoryDeletions(limit: 8).count == 1)
        }

        try await withTaskWorkflow(outputs: [reply("Acknowledged.")], memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let sourceAddress = try await fixture.run("I remember a rollback fact.")
            let sourceEvidence = try await fixture.evidence(sourceAddress)
            let memory = try await store.createMemory(draft: .init(content: "Rollback fact", scope: .global), source: .userMessage(evidence: sourceEvidence, excerpt: sourceEvidence.text), operationID: UUID(), replacing: nil, expectedRevision: nil, authorization: try await fixture.authority.authorization(), at: TaskWorkflowFixture.now).memory
            try await fixture.database.write { db in try db.execute(sql: "CREATE TRIGGER reject_memory_deletion BEFORE INSERT ON memory_deletion_requests BEGIN SELECT RAISE(ABORT, 'synthetic queue failure'); END") }
            let call = try deleteCall(id: "rollback", memory: memory, quote: "Forget the rollback fact.")
            await fixture.model.append([modelToolStream([call]), reply("Deletion request submitted.")])
            let address = try await fixture.run("Forget the rollback fact.")
            let state = try await fixture.runtime.sessionSnapshot(id: address.sessionID)
            #expect(state.invocations.values.allSatisfy { $0.resolution?.businessReceipt == nil })
            #expect(try await store.pendingMemoryDeletions(limit: 8).isEmpty)
        }
    }

    @Test("archive rejects a forged queued source")
    func archiveRejectsForgedSource() async throws {
        try await withTaskWorkflow(outputs: [reply("Acknowledged.")], memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let sourceAddress = try await fixture.run("I remember an archive fact.")
            let sourceEvidence = try await fixture.evidence(sourceAddress)
            let memory = try await store.createMemory(draft: .init(content: "Archive fact", scope: .global), source: .userMessage(evidence: sourceEvidence, excerpt: sourceEvidence.text), operationID: UUID(), replacing: nil, expectedRevision: nil, authorization: try await fixture.authority.authorization(), at: TaskWorkflowFixture.now).memory
            let call = try deleteCall(id: "archive", memory: memory, quote: "Forget the archive fact.")
            await fixture.model.append([modelToolStream([call]), reply("Deletion request submitted.")])
            _ = try await fixture.run("Forget the archive fact.")
            let archive = try SQLiteMemoryStore.archiveModule()
            try await inspectArchive(fixture)
            let pending = try #require(try await store.pendingMemoryDeletions(limit: 8).first)
            let forged = MemoryDeletionRequest(id: UUID(), target: pending.target, source: pending.source,
                executionID: pending.executionID, workspaceID: pending.workspaceID, requestedAt: pending.requestedAt)
            // The row is structurally valid and points at a real source, but no
            // committed journal invocation authorizes this forged request ID.
            try await fixture.database.write { db in
                try db.execute(sql: "UPDATE memory_deletion_requests SET id = ?, json = ? WHERE id = ?",
                    arguments: [forged.id.uuidString.lowercased(), try SessionCodec.encode(forged), pending.id.uuidString.lowercased()])
            }
            await #expect(throws: MiraError.self) {
                try await fixture.library.withSnapshot { snapshot in try fixture.database.read { db in try archive.inspect(db, snapshot) } }
            }
        }
    }
}

private func reply(_ text: String) -> [AgentModelStreamEvent] {
    [.blockStarted(.init(id: "text", content: .text(text))), .blockFinished(id: "text"), .finished(.stop)]
}
private func deleteCall(id: String, memory: Memory, quote: String, revision: Int? = nil) throws -> CanonicalToolCall {
    CanonicalToolCall(id: id, name: "memory.delete", arguments: try JSONValue.object([
        "memory_id": .string(memory.id.rawValue.uuidString.lowercased()), "revision": .number(Double(revision ?? memory.revision)), "quote": .string(quote)
    ]).jsonString())
}
private func inspectArchive(_ fixture: TaskWorkflowFixture) async throws {
    let archive = try SQLiteMemoryStore.archiveModule()
    _ = try await fixture.library.withSnapshot { snapshot in try fixture.database.read { db in try archive.inspect(db, snapshot) } }
}
private func complete(_ request: MemoryDeletionRequest, fixture: TaskWorkflowFixture, store: SQLiteMemoryStore) async throws {
    let operation = try await fixture.authority.begin(request.maintenanceRequest, expected: try await fixture.authority.authorization())
    let scope = try await store.memoryForgetScope(operation: operation)
    try await store.purgeMemoryForget(scope, operation: operation)
    _ = try await fixture.authority.complete(operation, at: request.requestedAt)
    try await store.settleMemoryDeletion(request, state: .completed, authorization: try await fixture.authority.authorization())
}
