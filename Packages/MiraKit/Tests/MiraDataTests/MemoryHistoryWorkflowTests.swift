import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Historical memory status from journal provenance", .timeLimit(.minutes(1)))
struct MemoryHistoryWorkflowTests {
    @Test func noticesUseOnlySelectedCompletedRepliesAndRecordedRevisions() async throws {
        let call = CanonicalToolCall(id: "search", name: "memory.search", arguments: "{\"query\":\"synthetic tea\"}")
        try await withTaskWorkflow(
            outputs: [
                modelToolStream([call]), [.blockStarted(.init(id: "text", content: .text("Synthetic tea answer"))), .blockFinished(id: "text"), .finished(.stop)],
                [.blockStarted(.init(id: "text", content: .text("Unrelated answer"))), .blockFinished(id: "text"), .finished(.stop)], [.blockStarted(.init(id: "text", content: .text("Partial answer")))],
            ], memoryEnabled: true
        ) { f in
            let store = try #require(f.memory)
            let memory = try await store.createMemory(
                draft: .init(content: "Synthetic tea preference", scope: .global),
                source: .manualEntry(id: UUID(), statement: "Synthetic tea preference"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: f.authority.authorization(),
                at: TaskWorkflowFixture.now
            ).memory
            let address = try await f.run("Which synthetic tea?")
            let unrelated = try await f.run("Answer an unrelated question")
            let failed = try await f.run("Which synthetic tea?", sessionID: address.sessionID, expectedStatus: .failed)
            let plans = try SQLiteSessionPrivacyPlanStore(database: f.database, libraryID: f.authority.libraryID)
            let extraction = try SQLiteMemoryExtractionStore(database: f.database, libraryID: f.authority.libraryID)
            let reader = JournalSessionReader(journal: f.library, payloads: f.library)
            let app = MemoryApplication(
                store: store, capturePolicyStore: store, extractionBudgetReader: extraction, extractionStatusReader: extraction,
                reader: reader, privacyHistory: plans, access: f.access, scope: f.scope,
                now: { TaskWorkflowFixture.now })
            do {
                #expect(
                    try await app.contextNotices(
                        sessionID: address.sessionID,
                        executionIDs: [address.executionID], workspaceID: nil
                    ).isEmpty)
                _ = try await app.reviseMemory(
                    memory.id, workspaceID: nil,
                    draft: .init(content: "Synthetic tea with revised wording", scope: .global), expectedRevision: 1,
                    operationID: UUID())
                let state = try await reader.snapshot(sessionID: address.sessionID)
                #expect(
                    try await app.contextNotices(
                        sessionID: address.sessionID,
                        executionIDs: [address.executionID, failed.executionID], workspaceID: nil)
                        == [address.executionID: [.init(memoryID: memory.id, reason: .updated)]])
                #expect(
                    try await app.contextNotices(
                        sessionID: unrelated.sessionID,
                        executionIDs: [unrelated.executionID], workspaceID: nil
                    ).isEmpty)
                await #expect(throws: MiraError.self) {
                    try await app.contextNotices(
                        sessionID: unrelated.sessionID, executionIDs: [address.executionID], workspaceID: nil)
                }
                await #expect(throws: MiraError.self) {
                    try await app.contextNotices(
                        sessionID: address.sessionID, executionIDs: [address.executionID], workspaceID: .init())
                }
                #expect(try await reader.snapshot(sessionID: address.sessionID) == state)
                let detail = try await app.citation(
                    .init(memoryID: memory.id, revision: 1), sessionID: address.sessionID,
                    executionID: address.executionID, workspaceID: nil)
                #expect(detail.revision.draft?.content == "Synthetic tea preference")
                await #expect(throws: MiraError.self) {
                    try await app.citation(
                        .init(memoryID: memory.id, revision: 2), sessionID: address.sessionID,
                        executionID: address.executionID, workspaceID: nil)
                }
                let broken = MemoryApplication(
                    store: store, capturePolicyStore: store, extractionBudgetReader: extraction, extractionStatusReader: extraction,
                    reader: .init(journal: f.library, payloads: MissingHistoryRequest(base: f.library)),
                    privacyHistory: plans, access: f.access, scope: f.scope)
                await #expect(throws: MiraError.self) {
                    try await broken.contextNotices(
                        sessionID: address.sessionID,
                        executionIDs: [address.executionID], workspaceID: nil)
                }
                await broken.close()
                await app.close()
                await #expect(throws: MiraError.self) {
                    try await app.contextNotices(sessionID: address.sessionID, executionIDs: [], workspaceID: nil)
                }
            } catch {
                await app.close()
                await plans.close()
                await extraction.close()
                throw error
            }
            await plans.close()
            await extraction.close()
        }
    }
}

private struct MissingHistoryRequest: SessionPayloadReader {
    let base: FileSessionLibrary
    func read(_ reference: SessionPayloadReference) async throws -> Data {
        if reference.kind == .request { throw MiraError(.storage, "Synthetic missing request body.") }
        return try await base.read(reference)
    }
}
