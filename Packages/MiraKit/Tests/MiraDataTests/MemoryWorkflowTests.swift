import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Memory through the journal and current agent modules", .timeLimit(.minutes(1)))
struct MemoryWorkflowTests {
    @Test func explicitRememberCommitsFullEvidenceAndLocalOnlyReceipt() async throws {
        let content = "I prefer green tea"
        let text = "Remember: I prefer green tea"
        let call = try CanonicalToolCall(
            id: "remember", name: "memory.remember", arguments: arguments(content: content).jsonString())
        try await withTaskWorkflow(
            outputs: [modelToolStream([call]), [.blockStarted(.init(id: "text", content: .text("Saved locally."))), .blockFinished(id: "text"), .finished(.stop)]],
            memoryEnabled: true
        ) { f in
            let address = try await f.run(text)
            let store = try #require(f.memory)
            let memory = try #require(
                try await store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 10).memories.first)
            #expect(memory.draft?.allowsRemoteUse == false)
            let detail = try await store.memoryDetail(memory.id, workspaceID: nil)
            #expect(detail.evidence.first?.source == .userMessage(try await f.evidence(address).reference))
            let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
            let invocation = try #require(state.invocations.values.first)
            #expect(invocation.resolution?.status == .succeeded)
            #expect(invocation.resolution?.businessReceipt != nil)
            #expect(
                try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM business_operations") } == 1
            )
            let request = try await context(f, address)
            #expect(
                try await store.recallMemories(
                    query: "green tea", request: request, limit: 6, at: TaskWorkflowFixture.now
                ).memories.isEmpty)
        }
    }

    @Test func receiptInsertionFailureRollsBackMemoryAndEvidence() async throws {
        let call = try CanonicalToolCall(
            id: "remember", name: "memory.remember", arguments: arguments(content: "I prefer tea").jsonString())
        try await withTaskWorkflow(
            outputs: [
                modelToolStream([call]), [.blockStarted(.init(id: "text", content: .text("No memory was saved."))), .blockFinished(id: "text"), .finished(.stop)],
            ], memoryEnabled: true
        ) { f in
            try await f.database.write {
                try $0.execute(
                    sql:
                        "CREATE TRIGGER reject_memory_receipt BEFORE INSERT ON business_receipts BEGIN SELECT RAISE(ABORT, 'Synthetic failure'); END"
                )
            }
            _ = try await f.run("Remember: I prefer tea")
            let store = try #require(f.memory)
            #expect(
                try await store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 10).memories.isEmpty)
            #expect(
                try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_evidence") } == 0)
            #expect(
                try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_operations") } == 0)
        }
    }

    @Test func recalledMemoryUsesActualSourceAndHistoricalCitationRevision() async throws {
        let call = CanonicalToolCall(id: "search", name: "memory.search", arguments: "{\"query\":\"green tea\"}")
        try await withTaskWorkflow(
            outputs: [
                modelToolStream([call]), [.blockStarted(.init(id: "text", content: .text("Green tea answer"))), .blockFinished(id: "text"), .finished(.stop)],
            ], memoryEnabled: true
        ) { f in
            let store = try #require(f.memory)
            let authorization = try await f.authority.authorization()
            let memory = try await store.createMemory(
                draft: .init(content: "I prefer green tea", scope: .global),
                source: .manualEntry(id: UUID(), statement: "I prefer green tea"), operationID: UUID(), replacing: nil,
                expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now
            ).memory
            let address = try await f.run("Which tea do I prefer?")
            let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
            #expect(state.invocations.values.first?.resolution?.status == .succeeded)
            let extraction = try SQLiteMemoryExtractionStore(database: f.database, libraryID: f.authority.libraryID)
            let privacy = try SQLiteSessionPrivacyPlanStore(database: f.database, libraryID: f.authority.libraryID)
            let application = MemoryApplication(
                store: store, capturePolicyStore: store,
                extractionBudgetReader: extraction, extractionStatusReader: extraction, reader: .init(journal: f.library, payloads: f.library),
                privacyHistory: privacy, access: f.access, scope: f.scope)
            do {
                _ = try await application.reviseMemory(
                    memory.id, workspaceID: nil,
                    draft: .init(content: "Green tea, with clearer wording", scope: .global), expectedRevision: 1,
                    operationID: UUID())
                let detail = try await application.citation(
                    .init(memoryID: memory.id, revision: 1), sessionID: address.sessionID,
                    executionID: address.executionID, workspaceID: nil)
                #expect(detail.revision.draft?.content == "I prefer green tea")
                await #expect(throws: MiraError.self) {
                    _ = try await application.citation(
                        .init(memoryID: memory.id, revision: 2), sessionID: address.sessionID,
                        executionID: address.executionID, workspaceID: nil)
                }
                await application.close()
                await extraction.close(); await privacy.close()
            } catch {
                await application.close()
                await extraction.close(); await privacy.close()
                throw error
            }
        }
    }

    @Test func globalMemoryRetainsSourceWorkspacePolicyAndRejectsForgedQuotes() async throws {
        try await withTaskWorkflow(
            outputs: [
                [.blockStarted(.init(id: "text", content: .text("Source received"))), .blockFinished(id: "text"), .finished(.stop)], [.blockStarted(.init(id: "text", content: .text("Target received"))), .blockFinished(id: "text"), .finished(.stop)],
            ], memoryEnabled: true
        ) { f in
            let store = try #require(f.memory)
            let authorization = try await f.authority.authorization()
            var workspace = Workspace(id: .init(), name: "Original source")
            try await f.workspaces.saveWorkspace(workspace, expectedRevision: nil, authorization: authorization)
            let sourceAddress = try await f.run("I prefer jasmine tea", workspaceID: workspace.id)
            let evidence = try await f.evidence(sourceAddress)
            let memory = try await store.createMemory(
                draft: .init(content: "I prefer jasmine tea", scope: .global),
                source: .userMessage(evidence: evidence, excerpt: evidence.text), operationID: UUID(), replacing: nil,
                expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now
            ).memory
            await #expect(throws: MiraError.self) {
                _ = try await store.createMemory(
                    draft: .init(content: "Forged", scope: .global),
                    source: .userMessage(evidence: evidence, excerpt: "Not said by the user"), operationID: UUID(),
                    replacing: nil, expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now)
            }
            let target = try await f.run("Target with independent context")
            let request = try await context(f, target)
            #expect(
                try await store.recallMemory(memory.id, request: request, at: TaskWorkflowFixture.now).id == memory.id)
            workspace.revision += 1
            workspace.allowsRemoteSend = false
            try await f.workspaces.saveWorkspace(workspace, expectedRevision: 1, authorization: authorization)
            #expect(
                try await store.recallMemories(
                    query: "jasmine tea", request: request, limit: 6, at: TaskWorkflowFixture.now
                ).memories.isEmpty)
            await #expect(throws: MiraError.self) {
                try await store.validateMemorySources(
                    [.domain(namespace: "memories", id: memory.id.rawValue, revision: 1)], for: request,
                    at: TaskWorkflowFixture.now)
            }
        }
    }

    @Test func validityAndDisclosureFiltersPrecedeCandidateLimit() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Context"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { f in
            let store = try #require(f.memory)
            let authorization = try await f.authority.authorization()
            let now = TaskWorkflowFixture.now
            let address = try await f.run("Context request")
            let request = try await context(f, address)
            let valid = try await store.createMemory(
                draft: .init(
                    content: "Valid tea", scope: .global, validFrom: now.addingTimeInterval(-60),
                    validUntil: now.addingTimeInterval(60)), source: .manualEntry(id: UUID(), statement: "Valid tea"),
                operationID: UUID(), replacing: nil, expectedRevision: nil, authorization: authorization, at: now
            ).memory
            _ = try await store.createMemory(
                draft: .init(content: "Expired tea", scope: .global, validUntil: now.addingTimeInterval(-1)),
                source: .manualEntry(id: UUID(), statement: "Expired tea"), operationID: UUID(), replacing: nil,
                expectedRevision: nil, authorization: authorization, at: now)
            // One actual SQL transaction inserts an ineligible prefix larger than the search candidate cap.
            try await f.database.write { db in
                for index in 0..<2_005 {
                    _ = try SQLiteMemoryStore.createMemoryInTransaction(
                        draft: .init(content: "Private tea \(index)", scope: .global, allowsRemoteUse: false),
                        source: .manualEntry(id: UUID(), statement: "Private tea \(index)"), operationID: UUID(),
                        replacing: nil, expectedRevision: nil, at: now, in: db)
                }
            }
            let result = try await store.recallMemories(query: "tea", request: request, limit: 6, at: now)
            #expect(result.memories.map(\.id) == [valid.id])
            #expect(!result.isTruncated)
        }
    }

    @Test(arguments: [false, true])
    func capturePolicyDistinguishesOrdinaryStatementsFromExplicitReview(explicit: Bool) async throws {
        let content = "I prefer herbal tea"
        let input: JSONValue = .object([
            "content": .string(content), "quote": .string(content), "kind": .string("preference"),
            "scope": .string("global"), "sensitive": .bool(true),
        ])
        let call = try CanonicalToolCall(id: "remember", name: "memory.remember", arguments: input.jsonString())
        try await withTaskWorkflow(
            outputs: [
                modelToolStream([call]), [.blockStarted(.init(id: "text", content: .text("No save was approved."))), .blockFinished(id: "text"), .finished(.stop)],
            ], memoryEnabled: true
        ) { f in
            let store = try #require(f.memory)
            let authorization = try await f.authority.authorization()
            try await store.saveMemoryCapturePolicy(
                .init(revision: 2, mode: .candidateOnly, enabledAt: TaskWorkflowFixture.now),
                expectedRevision: 1, authorization: authorization, at: TaskWorkflowFixture.now)
            let address = try await f.run(explicit ? "Remember: " + content : content)
            let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
            let invocation = try #require(state.invocations.values.first)
            #expect((invocation.approval != nil) == explicit)
            #expect(invocation.dispatchedAt == nil)
            #expect(
                try await store.memoryList(workspaceID: nil, states: [.active, .candidate], query: "", limit: 10)
                    .memories.isEmpty)
        }
    }

    private func arguments(content: String) -> JSONValue {
        .object([
            "content": .string(content), "quote": .string(content), "kind": .string("preference"),
            "scope": .string("current"), "sensitive": .bool(false),
        ])
    }
    private func context(_ f: TaskWorkflowFixture, _ address: AgentExecutionAddress) async throws -> AgentContextRequest
    {
        let evidence = try await f.evidence(address)
        return .init(
            sessionID: address.sessionID, executionID: address.executionID, workspaceID: evidence.workspaceID,
            userText: evidence.text, authorizationEpoch: evidence.sessionAuthorizationEpoch,
            destination: .model(f.route))
    }
}
