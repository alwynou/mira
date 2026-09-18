import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Historical memory status from journal provenance", .timeLimit(.minutes(1)))
struct MemoryHistoryWorkflowTests {
    @Test func localCompletedReplyWithoutModelRouteHasNoMemoryNoticeError() async throws {
        try await withTaskWorkflow(memoryEnabled: true) { f in
            let sessionID = ConversationID()
            let executionID = ExecutionID()
            let runtime = try await SessionRuntime.open(id: sessionID, journal: f.library, payloads: f.library)
            defer { Task { await runtime.close() } }
            let admitted = await runtime.commit(id: UUID()) { context in
                let title = try await context.stageBytes(Data("Local fixture".utf8), kind: .title)
                let body = try await context.stageBytes(Data("Synthetic local question".utf8), kind: .userText)
                let plan = try await context.stage(AgentExecutionPlan(
                    runtimeID: UUID(), catalogGeneration: 0, driverID: "local.fixture", driverRevision: 1,
                    instructions: "Synthetic local reply", limits: .init(), priority: .foreground, route: nil),
                    kind: .executionPlan)
                return [.opened(.init(workspaceID: nil, title: title)),
                        .admitted(.init(executionID: executionID, userMessageID: MessageID(), userBody: body,
                                       plan: plan, hasModelRoute: false, authorizationEpoch: 0,
                                       timeZoneIdentifier: "UTC"))]
            }
            try taskRequireCommitted(admitted)
            let completed = await runtime.commit(id: UUID()) { context in
                let answer = try await context.stageBytes(Data("Synthetic local answer".utf8), kind: .visibleAnswer)
                return [.phaseChanged(executionID: executionID, phase: .settling),
                        .finished(.init(executionID: executionID, status: .completed,
                                       assistantMessageID: MessageID(), answer: answer))]
            }
            try taskRequireCommitted(completed)

            let memory = try #require(f.memory)
            let extraction = try SQLiteMemoryExtractionStore(database: f.database, libraryID: f.authority.libraryID)
            let app = MemoryApplication(store: memory, extractionStatusReader: extraction,
                reader: .init(journal: f.library, payloads: f.library),
                access: f.access, scope: f.scope)
            defer {
                Task { await app.close(); await extraction.close() }
            }
            #expect(try await app.contextNotices(sessionID: sessionID, executionIDs: [executionID], workspaceID: nil).isEmpty)
        }
    }

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
            let extraction = try SQLiteMemoryExtractionStore(database: f.database, libraryID: f.authority.libraryID)
            let reader = JournalSessionReader(journal: f.library, payloads: f.library)
            let app = MemoryApplication(
                store: store, extractionStatusReader: extraction,
                reader: reader, access: f.access, scope: f.scope,
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
                    store: store, extractionStatusReader: extraction,
                    reader: .init(journal: f.library, payloads: MissingHistoryRequest(base: f.library)),
                    access: f.access, scope: f.scope)
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
                await extraction.close()
                throw error
            }
            await extraction.close()
        }
    }
}

private struct MissingHistoryRequest: SessionContentReader {
    let base: FileSessionLibrary
    func read(_ reference: SessionContent) async throws -> Data {
        if reference.kind == .request { throw MiraError(.storage, "Synthetic missing request body.") }
        return try await base.read(reference)
    }
}
