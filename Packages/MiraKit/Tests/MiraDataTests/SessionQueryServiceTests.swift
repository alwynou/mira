import Foundation
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Session query service", .timeLimit(.minutes(1)))
struct SessionQueryServiceTests {
    @Test func rejectsMessagePageMissingLatestExecutionEvidence() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Answer"))), .blockFinished(id: "text"), .finished(.stop)]]) { f in
            let address = try await f.run("Question")
            let projection = try SQLiteSessionProjection(
                path: f.directory.appendingPathComponent("malformed-query-\(UUID()).sqlite").path)
            let malformed = MissingLatestProjection(base: projection)
            let query = try SessionQueryService(
                journal: f.library, payloads: f.library, projection: malformed,
                access: f.access, scope: f.scope)
            do {
                await #expect(throws: MiraError(.storage, "The session query page is inconsistent.")) {
                    try await query.messagePage(sessionID: address.sessionID)
                }
                await query.close()
                try await projection.close()
            } catch {
                await query.close()
                try? await projection.close()
                throw error
            }
        }
    }

    @Test func failedNoOutputRetryRemainsVisibleAsLatestExecutionOnEveryMessagePage() async throws {
        try await withTaskWorkflow(outputs: [[], []]) { f in
            let original = try await f.run("Question", expectedStatus: .failed)
            let retryID = ExecutionID()
            let command = AgentSubmitCommand(
                id: UUID(), sessionID: original.sessionID, executionID: retryID,
                input: .retry(executionID: original.executionID),
                options: .init(instructions: "Retry", route: f.route))
            try taskRequireCommitted(await f.runtime.submit(command))
            try taskRequireCommitted(await f.runtime.waitForExecution(id: retryID, sessionID: original.sessionID))

            try await withQuery(f) { query, _ in
                try await query.synchronizeLibrary()
                let newest = try await query.messagePage(sessionID: original.sessionID, limit: 1)
                let user = try #require(newest.messages.first)
                #expect(newest.messages.count == 1)
                #expect(newest.executions.map(\.id) == [retryID, original.executionID])
                #expect(newest.session?.summary.latestExecutionID == retryID)

                let older = try await query.messagePage(
                    sessionID: original.sessionID, beforeSequence: user.summary.sequence, limit: 1)
                #expect(older.messages.isEmpty)
                #expect(older.executions.map(\.id) == [retryID])
            }
        }
    }

    @Test func failedTurnRetryReplacesOldBodyAndReopensWithLatestAnswer() async throws {
        let partialEvents: [AgentModelStreamEvent] = [
            .blockStarted(.init(id: "text", content: .text("Partial answer"))),
            .blockStarted(.init(id: "thinking", content: .thinking("Partial reasoning"))),
        ]
        let answerEvents: [AgentModelStreamEvent] = [
            .blockStarted(.init(id: "text", content: .text("Recovered answer"))),
            .blockFinished(id: "text"), .finished(.stop)
        ]
        try await withTaskWorkflow(outputs: [partialEvents, answerEvents]) { f in
            let original = try await f.run("Question", expectedStatus: .failed)
            let retryID = ExecutionID()
            let command = AgentSubmitCommand(
                id: UUID(), sessionID: original.sessionID, executionID: retryID,
                input: .retry(executionID: original.executionID),
                options: .init(instructions: "Retry", route: f.route))
            try taskRequireCommitted(await f.runtime.submit(command))
            try taskRequireCommitted(await f.runtime.waitForExecution(id: retryID, sessionID: original.sessionID))

            try await withQuery(f) { query, _ in
                try await query.synchronizeLibrary()
                let page = try await query.messagePage(sessionID: original.sessionID)
                let assistants = page.messages.filter { $0.summary.role == .assistant }
                #expect(assistants.count == 1)
                let latest = try #require(assistants.first)
                #expect(latest.summary.executionID == retryID)
                #expect(latest.body == .available("Recovered answer"))
                let user = try #require(page.messages.first { $0.summary.role == .user })
                #expect(user.body == .available("Question"))
                #expect(Set(page.executions.map(\.id)) == Set([original.executionID, retryID]))
                let originalAudit = try await query.executionAudit(
                    sessionID: original.sessionID, executionID: original.executionID)
                let retryAudit = try await query.executionAudit(
                    sessionID: original.sessionID, executionID: retryID)
                #expect(originalAudit.execution.completion?.status == .failed)
                #expect(retryAudit.execution.completion?.status == .completed)
                #expect(originalAudit.plan != .absent)
                #expect(originalAudit.attempts.first?.request != .absent)
                #expect(originalAudit.attempts.first?.failure != .absent)
            }

            // A new query service and projection represent projection/query reopen;
            // both execution rows remain auditable while the latest body is the
            // only assistant row retained by the disposable projection.
            try await withQuery(f) { query, _ in
                let reopened = try await query.messagePage(sessionID: original.sessionID)
                let assistants = reopened.messages.filter { $0.summary.role == .assistant }
                #expect(assistants.count == 1)
                let assistant = try #require(assistants.first)
                #expect(assistant.summary.executionID == retryID)
                #expect(assistant.body == .available("Recovered answer"))
                #expect(reopened.messages.first { $0.summary.role == .user }?.body == .available("Question"))
                #expect(Set(reopened.executions.map(\.id)) == Set([original.executionID, retryID]))
            }
        }
    }

    @Test func pagesLoadVisibleContentAndLinkedExecutionsWithoutDispatchingWork() async throws {
        try await withTaskWorkflow(outputs: [
            [.blockStarted(.init(id: "text", content: .text("First answer"))), .blockFinished(id: "text"), .finished(.stop)],
            [.blockStarted(.init(id: "text", content: .text("Second answer"))), .blockFinished(id: "text"), .finished(.stop)],
            [.blockStarted(.init(id: "text", content: .text("Other answer"))), .blockFinished(id: "text"), .finished(.stop)],
        ]) { f in
            let first = try await f.run("First question")
            let second = try await f.run("Second question", sessionID: first.sessionID)
            let other = try await f.run("Other question")
            try await withQuery(f) { query, _ in
                #expect(try await query.sessions().isEmpty)
                try await query.synchronizeLibrary()
                let sessions = try await query.sessions()
                #expect(Set(sessions.map(\.id)) == [first.sessionID, other.sessionID])
                #expect(sessions.allSatisfy { $0.title == .available("Synthetic task workflow") })
                let newest = try await query.messagePage(sessionID: first.sessionID, limit: 2)
                #expect(newest.messages.map(\.body) == [.available("Second answer"), .available("Second question")])
                #expect(newest.messages.allSatisfy { $0.thinking == .absent })
                #expect(newest.executions.map(\.id) == [second.executionID])
                #expect(newest.hasMore)
                let cursor = try #require(newest.messages.last?.summary.sequence)
                let older = try await query.messagePage(sessionID: first.sessionID, beforeSequence: cursor, limit: 2)
                #expect(older.messages.map(\.body) == [.available("First answer"), .available("First question")])
                #expect(older.executions.map(\.id) == [second.executionID, first.executionID])
                #expect(!older.hasMore)
                #expect(try await query.settledOutput(sessionID: first.sessionID) == nil)
                #expect(await f.model.inputs.count == 3)
            }
        }
    }

    @Test func pageBudgetRejectsBeforeAnyPayloadRead() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("An answer"))), .blockFinished(id: "text"), .finished(.stop)]]) { f in
            let address = try await f.run("A question")
            let reader = QueryPayloadProbe(base: f.library)
            try await withQuery(f, reader: reader, maximumPageBytes: 1) { query, _ in
                await #expect(throws: MiraError(.outputLimit, "The session query page exceeds its content limit.")) {
                    try await query.messagePage(sessionID: address.sessionID)
                }
                await #expect(throws: MiraError(.outputLimit, "The session query page exceeds its content limit.")) {
                    try await query.sessions()
                }
                #expect(await reader.references.isEmpty)
            }
        }
    }

    @Test func missingAndMalformedUninvalidatedContentFailInsteadOfBecomingEmpty() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Answer"))), .blockFinished(id: "text"), .finished(.stop)]]) { f in
            let address = try await f.run("Question")
            let reader = QueryPayloadProbe(base: f.library)
            try await withQuery(f, reader: reader) { query, _ in
                await reader.setFailure(.missing)
                await #expect(throws: MiraError(.notFound, "Synthetic payload is missing.")) {
                    try await query.messagePage(sessionID: address.sessionID)
                }
                await reader.setFailure(.invalidText)
                await #expect(throws: MiraError(.storage, "The session payload contains invalid text encoding.")) {
                    try await query.messagePage(sessionID: address.sessionID)
                }
                await reader.setFailure(nil)
                let page = try await query.messagePage(sessionID: address.sessionID)
                #expect(page.messages.first?.body == .available("Answer"))
            }
        }
    }

    @Test func closeDrainsNonCooperativeReadAndRejectsLatePlaintext() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Answer"))), .blockFinished(id: "text"), .finished(.stop)]]) { f in
            let address = try await f.run("Question")
            #expect(await f.runtime.shutdown().isSettled)
            let reader = QueryPayloadProbe(base: f.library)
            await reader.holdNextRead()
            try await withQuery(f, reader: reader) { query, _ in
                let read = Task { try await query.messagePage(sessionID: address.sessionID) }
                try await taskEventually { await reader.isHeld }
                let finished = QueryCompletionProbe()
                let close = Task {
                    await query.close()
                    await finished.mark()
                }
                do {
                    // Admission rejection proves close has entered before checking its drain.
                    try await taskEventually {
                        do {
                            _ = try await query.sessions()
                            return false
                        } catch let error as MiraError {
                            return error == MiraError(.busy, "The session query service is closed.")
                        } catch is CancellationError { return false }
                    }
                    #expect(await !finished.value)
                    #expect(await f.access.snapshot().activeResources == 1)
                    await reader.release()
                    await #expect(throws: (any Error).self) { try await read.value }
                    await close.value
                    #expect(await finished.value)
                    #expect(await f.access.snapshot().activeLeases == 0)
                } catch {
                    await reader.release()
                    _ = await read.result
                    await close.value
                    throw error
                }
            }
        }
    }

    @Test func maintenanceRevokesPendingReadAndCannotCompleteBeforeActualDrain() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Answer"))), .blockFinished(id: "text"), .finished(.stop)]]) { f in
            let address = try await f.run("Question")
            #expect(await f.runtime.shutdown().isSettled)
            let reader = QueryPayloadProbe(base: f.library)
            await reader.holdNextRead()
            try await withQuery(f, reader: reader) { query, _ in
                let read = Task { try await query.messagePage(sessionID: address.sessionID) }
                try await taskEventually { await reader.isHeld }
                do {
                    let expected = await f.access.snapshot().authorization
                    let operation = try await f.access.begin(
                        .init(
                            id: UUID(), namespace: "privacy.fixture", revision: 1,
                            scope: .library, requestedAt: TaskWorkflowFixture.now), expected: expected)
                    #expect(await f.access.snapshot().activeReads > 0)
                    await #expect(throws: MiraError(.busy, "Library access has not drained.")) {
                        try await f.access.complete(operation, at: TaskWorkflowFixture.now)
                    }
                    await reader.release()
                    await #expect(throws: (any Error).self) { try await read.value }
                    try await f.access.waitForQuiescence()
                    _ = try await f.access.complete(operation, at: TaskWorkflowFixture.now)
                    #expect(
                        try await query.messagePage(sessionID: address.sessionID).messages.first?.body
                            == .available("Answer"))
                } catch {
                    await reader.release()
                    _ = await read.result
                    throw error
                }
            }
        }
    }

}

private final class MissingLatestProjection: SessionProjectionStore, @unchecked Sendable {
    let base: any SessionProjectionStore

    init(base: any SessionProjectionStore) { self.base = base }

    func head(sessionID: ConversationID) async throws -> SessionJournalHead? {
        try await base.head(sessionID: sessionID)
    }

    func apply(_ batch: SessionBatch) async throws { try await base.apply(batch) }
    func reset(sessionID: ConversationID) async throws { try await base.reset(sessionID: sessionID) }
    func session(id: ConversationID) async throws -> SessionSummary? { try await base.session(id: id) }
    func sessions(scope: SessionQueryScope, includeArchived: Bool, after: SessionListCursor?, limit: Int) async throws
        -> [SessionSummary]
    {
        try await base.sessions(scope: scope, includeArchived: includeArchived, after: after, limit: limit)
    }
    func messages(sessionID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> [SessionMessageSummary] {
        try await base.messages(sessionID: sessionID, beforeSequence: beforeSequence, limit: limit)
    }
    func messagePage(sessionID: ConversationID, beforeSequence: Int64?, limit: Int) async throws
        -> SessionProjectionMessagePage
    {
        let page = try await base.messagePage(sessionID: sessionID, beforeSequence: beforeSequence, limit: limit)
        guard let session = page.session else { return page }
        let missingLatest = SessionSummary(
            id: session.id, workspaceID: session.workspaceID, title: session.title,
            revision: session.revision,
            isArchived: session.isArchived, createdAt: session.createdAt, updatedAt: session.updatedAt,
            activeExecutionID: session.activeExecutionID, latestExecutionID: nil, head: session.head)
        return .init(session: missingLatest, messages: page.messages, executions: page.executions, hasMore: page.hasMore)
    }
    func executions(sessionID: ConversationID, beforeSequence: Int64?, limit: Int) async throws
        -> [SessionExecutionSummary]
    {
        try await base.executions(sessionID: sessionID, beforeSequence: beforeSequence, limit: limit)
    }
    func close() async throws { try await base.close() }
}

private func withQuery(
    _ fixture: TaskWorkflowFixture, reader: (any SessionContentReader)? = nil,
    maximumPageBytes: Int = 64 * 1_024 * 1_024,
    _ body: (SessionQueryService, SQLiteSessionProjection) async throws -> Void
) async throws {
    let projection = try SQLiteSessionProjection(
        path: fixture.directory.appendingPathComponent("query-\(UUID()).sqlite").path)
    let service: SessionQueryService
    do {
        service = try SessionQueryService(
            journal: fixture.library, payloads: reader ?? fixture.library,
            projection: projection, access: fixture.access, scope: fixture.scope, maximumPageBytes: maximumPageBytes)
    } catch {
        try? await projection.close()
        throw error
    }
    do { try await body(service, projection) } catch {
        await service.close()
        try? await projection.close()
        throw error
    }
    await service.close()
    try await projection.close()
}

private actor QueryPayloadProbe: SessionContentReader {
    enum Failure { case missing, invalidText }
    let base: any SessionContentReader
    private var failure: Failure?
    private var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var references: [SessionContent] = []
    private(set) var isHeld = false
    init(base: any SessionContentReader) { self.base = base }
    func setFailure(_ failure: Failure?) { self.failure = failure }
    func holdNextRead() { hold = true }
    func release() {
        continuation?.resume()
        continuation = nil
        isHeld = false
    }
    func read(_ reference: SessionContent) async throws -> Data {
        references.append(reference)
        // Read real bytes before suspending so revocation must discard already obtained plaintext.
        let bytes = try await base.read(reference)
        if hold {
            hold = false
            isHeld = true
            await withCheckedContinuation { continuation = $0 }
        }
        if reference.kind == .visibleAnswer {
            switch failure {
            case .missing: throw MiraError(.notFound, "Synthetic payload is missing.")
            case .invalidText: return Data(repeating: 0xFF, count: reference.byteCount)
            case nil: break
            }
        }
        return bytes
    }
}

private actor QueryCompletionProbe {
    private(set) var value = false
    func mark() { value = true }
}

private func queryCommitted(_ result: SessionCommitResult) throws {
    if case .committed = result { return }
    if case .notCommitted(let error) = result { throw error }
    throw MiraError(.storage, "Synthetic query setup did not commit.")
}
