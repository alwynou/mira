import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Test
func memoryArchiveValidatesJournalSourceAndForgottenRowsAndDisablesCaptureOnRestore() async throws {
    try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("received"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
        let store = try #require(fixture.memory)
        let address = try await fixture.run("I prefer green tea")
        let evidence = try await fixture.evidence(address)
        let authorization = try await fixture.authority.authorization()
        let createOperationID = UUID()
        let memory = try await store.createMemory(
            draft: .init(content: "I prefer green tea", scope: .global),
            source: .userMessage(evidence: evidence, excerpt: evidence.text), operationID: createOperationID,
            replacing: nil, expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now
        ).memory
        let (originalEvidenceJSON, originalRequestHash, originalReceiptJSON) = try await fixture.database.read { db in
            guard
                let evidenceJSON = try Data.fetchOne(
                    db, sql: "SELECT json FROM memory_evidence WHERE memory_id = ?",
                    arguments: [memory.id.rawValue.uuidString.lowercased()]),
                let operation = try Row.fetchOne(
                    db, sql: "SELECT request_hash, receipt_json FROM memory_operations WHERE operation_id = ?",
                    arguments: [createOperationID.uuidString.lowercased()]),
                let requestHash: String = operation["request_hash"],
                let receiptJSON: Data = operation["receipt_json"]
            else { throw MiraError(.storage, "The memory archive fixture was not fully recorded.") }
            return (evidenceJSON, requestHash, receiptJSON)
        }

        var policy = try await store.memoryCapturePolicy()
        policy.revision = 2
        policy.mode = .candidateOnly
        policy.enabledAt = TaskWorkflowFixture.now
        try await store.saveMemoryCapturePolicy(
            policy, expectedRevision: 1, authorization: authorization, at: TaskWorkflowFixture.now)
        let maintenanceRequest = AgentLibraryMaintenanceRequest(
            id: UUID(), namespace: "memory.forget", revision: 1,
            scope: .sources([.domain(namespace: "memories", id: memory.id.rawValue, revision: memory.revision)]),
            requestedAt: TaskWorkflowFixture.now.addingTimeInterval(1))
        let maintenance = try await fixture.authority.begin(maintenanceRequest, expected: authorization)
        _ = try await store.purgeMemory(
            memory.id, workspaceID: nil, expectedRevision: memory.revision, maintenance: maintenance,
            at: maintenanceRequest.requestedAt)
        _ = try await fixture.authority.complete(maintenance, at: maintenanceRequest.requestedAt)

        let module = try SQLiteMemoryStore.archiveModule()
        try await fixture.library.withSnapshot { snapshot in
            try fixture.database.read { db in try module.inspect(db, snapshot) }
        }
        let forgottenEvidenceJSON = try await fixture.database.read { db in
            try #require(
                try Data.fetchOne(
                    db, sql: "SELECT json FROM memory_evidence WHERE memory_id = ?",
                    arguments: [memory.id.rawValue.uuidString.lowercased()]))
        }
        try await fixture.database.write { db in
            try db.execute(
                sql: "UPDATE memory_evidence SET json = ? WHERE memory_id = ?",
                arguments: [originalEvidenceJSON, memory.id.rawValue.uuidString.lowercased()])
        }
        await #expect(throws: MiraError.self) {
            try await fixture.library.withSnapshot { snapshot in
                try fixture.database.read { db in try module.inspect(db, snapshot) }
            }
        }
        try await fixture.database.write { db in
            try db.execute(
                sql: "UPDATE memory_evidence SET json = ? WHERE memory_id = ?",
                arguments: [forgottenEvidenceJSON, memory.id.rawValue.uuidString.lowercased()])
            try db.execute(
                sql: "UPDATE memory_operations SET request_hash = ?, receipt_json = ? WHERE operation_id = ?",
                arguments: [originalRequestHash, originalReceiptJSON, createOperationID.uuidString.lowercased()])
        }
        await #expect(throws: MiraError.self) {
            try await fixture.library.withSnapshot { snapshot in
                try fixture.database.read { db in try module.inspect(db, snapshot) }
            }
        }
        guard case .prepare(let apply, let verify) = module.restoration else {
            Issue.record("Memory archives must disable capture during restore preparation.")
            return
        }
        try await fixture.database.write { db in try apply(db, TaskWorkflowFixture.now) }
        try await fixture.database.read { db in
            try verify(db)
            let restored = try SQLiteMemoryStore.currentCapturePolicy(in: db)
            #expect(restored.revision == 2)
            #expect(restored.mode == .manualOnly)
            #expect(restored.enabledAt == nil)
        }
    }
}

@Test
func memoryArchiveRejectsMirroredRecordCorruptionBeforeUsingIt() async throws {
    try await withTaskWorkflow(memoryEnabled: true) { fixture in
        let store = try #require(fixture.memory)
        let authorization = try await fixture.authority.authorization()
        let memory = try await store.createMemory(
            draft: .init(content: "A bounded archive fixture", scope: .global),
            source: .manualEntry(id: UUID(), statement: "A bounded archive fixture"), operationID: UUID(),
            replacing: nil, expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now
        ).memory
        let module = try SQLiteMemoryStore.archiveModule()
        try await fixture.library.withSnapshot { snapshot in
            try fixture.database.read { db in try module.inspect(db, snapshot) }
        }
        try await fixture.database.write { db in
            try db.execute(
                sql: "UPDATE memory_records SET revision = revision + 1 WHERE id = ?",
                arguments: [memory.id.rawValue.uuidString.lowercased()])
        }
        await #expect(throws: MiraError.self) {
            try await fixture.library.withSnapshot { snapshot in
                try fixture.database.read { db in try module.inspect(db, snapshot) }
            }
        }
    }
}
