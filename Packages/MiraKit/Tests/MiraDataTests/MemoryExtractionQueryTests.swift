import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Independent extraction accounting queries", .timeLimit(.minutes(2)))
struct MemoryExtractionQueryTests {
    @Test(arguments: [false, true])
    func allAttemptsRemainDistinctAcrossRetryReopenAndBodyCleanup(missingCounters: Bool) async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { f in
            try await enable(in: f)
            let address = try await f.run("Synthetic source that must never appear in accounting")
            let source = try await f.evidence(address)
            let job = try await enqueue(source, in: f)
            let store = try SQLiteMemoryExtractionStore(database: f.database, libraryID: f.authority.libraryID)
            do {
                let auth = try await f.authority.authorization()
                let first = try await claim(job.id, ordinal: 1, source: source, store: store, f: f)
                try await store.failMemoryExtraction(
                    first, error: .init(.configuration, "Synthetic unsent failure"),
                    authorization: auth, at: TaskWorkflowFixture.now)
                let unsentFailure = try await store.memoryExtractionReport(
                    job.id, sessionID: address.sessionID,
                    executionID: address.executionID, workspaceID: nil)
                #expect(unsentFailure.job.state == .failed)
                #expect(unsentFailure.job.errorCode == .configuration)
                #expect(try await store.memoryExtractionStatus(
                    sessionID: address.sessionID, executionID: address.executionID,
                    workspaceID: nil, before: nil, limit: 8).jobs.first?.errorCode == .configuration)
                _ = try await store.retryMemoryExtraction(
                    job.id, source: source, authorization: auth, at: TaskWorkflowFixture.now)
                #expect(try await store.memoryExtractionReport(
                    job.id, sessionID: address.sessionID,
                    executionID: address.executionID, workspaceID: nil).job.errorCode == nil)
                let second = try await claim(job.id, ordinal: 2, source: source, store: store, f: f)
                let ceiling = try await dispatch(second, source: source, store: store, f: f)
                try await store.failMemoryExtraction(
                    second, error: .init(.interrupted, "Synthetic dispatched failure"),
                    authorization: auth, at: TaskWorkflowFixture.now)
                let dispatchedFailure = try await store.memoryExtractionReport(
                    job.id, sessionID: address.sessionID,
                    executionID: address.executionID, workspaceID: nil)
                #expect(dispatchedFailure.job.state == .paused)
                #expect(dispatchedFailure.job.errorCode == .interrupted)
                _ = try await store.retryMemoryExtraction(
                    job.id, source: source, authorization: auth, at: TaskWorkflowFixture.now)
                #expect(try await store.memoryExtractionReport(
                    job.id, sessionID: address.sessionID,
                    executionID: address.executionID, workspaceID: nil).job.errorCode == nil)
                let third = try await claim(job.id, ordinal: 3, source: source, store: store, f: f)
                _ = try await dispatch(third, source: source, store: store, f: f)
                let usage =
                    missingCounters
                    ? TokenUsage(inputTokens: 10, outputTokens: 2, cacheReadTokens: 3, inputTokenBasis: .excludesCache)
                    : TokenUsage(
                        inputTokens: 10, outputTokens: 2, cacheReadTokens: 3, cacheWriteTokens: 0, reasoningTokens: 1)
                _ = try await store.completeMemoryExtraction(
                    third, source: source,
                    output: .init(
                        blocks: [.init(id: "text", content: .text("{\"version\":3,\"items\":[]}"))], continuation: nil, usage: usage,
                        finishReason: .stop),
                    authorization: auth, at: TaskWorkflowFixture.now)
                let before = try await store.memoryExtractionReport(
                    job.id, sessionID: address.sessionID,
                    executionID: address.executionID, workspaceID: nil)
                #expect(before.job.state == .completed && before.job.attemptCount == 3)
                #expect(before.job.errorCode == nil)
                #expect(before.attempts.map(\.state) == [.failed, .paused, .completed])
                #expect(before.attempts.map(\.id) == [first.attemptID, second.attemptID, third.attemptID])
                #expect(before.attempts.map(\.chargedTokens) == [0, ceiling, missingCounters ? ceiling : 12])
                #expect(before.attempts.map(\.usage) == [nil, nil, usage])
                #expect(before.attempts.allSatisfy { $0.route == f.route })
                let text = String(decoding: try SessionCodec.encode(before.attempts), as: UTF8.self)
                #expect(
                    !text.contains(source.text) && !text.contains("Synthetic dispatched failure")
                        && !text.contains("items"))
                await store.close()
                // A separate database connection and store read the persisted record.
                let reopenedDB = try DatabaseQueue(path: f.directory.appendingPathComponent("business.sqlite").path)
                let reopened = try SQLiteMemoryExtractionStore(database: reopenedDB, libraryID: f.authority.libraryID)
                do {
                    #expect(
                        try await reopened.memoryExtractionReport(
                            job.id, sessionID: address.sessionID,
                            executionID: address.executionID, workspaceID: nil) == before)
                    // Exercise the extraction domain's actual cleanup writer. Full journal privacy
                    // orchestration is covered by MemoryForgetWorkflowTests, not simulated here.
                    try await f.database.write { db in
                        try SQLiteMemoryExtractionStore.purge(
                            source: .userMessage(source.reference), at: TaskWorkflowFixture.now, in: db)
                    }
                    let purged = try await reopened.memoryExtractionReport(
                        job.id, sessionID: address.sessionID,
                        executionID: address.executionID, workspaceID: nil)
                    #expect(purged.job.state == .suppressed)
                    #expect(purged.job.errorCode == nil)
                    #expect(purged.attempts.map(\.usage) == before.attempts.map(\.usage))
                    #expect(purged.attempts.map(\.chargedTokens) == before.attempts.map(\.chargedTokens))
                    #expect(purged.attempts.allSatisfy { $0.route == nil && $0.bodyPurgedAt != nil })
                } catch {
                    await reopened.close()
                    try? reopenedDB.close()
                    throw error
                }
                await reopened.close()
                try reopenedDB.close()
            } catch {
                await store.close()
                throw error
            }
            await store.close()
        }
    }

    @Test func purgingFailedSourceRemovesItsDiagnosticCode() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { f in
            let address = try await f.run("Synthetic failed extraction source")
            let source = try await f.evidence(address)
            let job = try await enqueue(source, in: f)
            let store = try SQLiteMemoryExtractionStore(database: f.database, libraryID: f.authority.libraryID)
            do {
                let claim = try await claim(job.id, ordinal: 1, source: source, store: store, f: f)
                _ = try await dispatch(claim, source: source, store: store, f: f)
                try await store.failMemoryExtraction(
                    claim, error: .init(.invalidInput, "Synthetic invalid output"),
                    authorization: f.authority.authorization(), at: TaskWorkflowFixture.now)
                let before = try await store.memoryExtractionReport(
                    job.id, sessionID: address.sessionID, executionID: address.executionID, workspaceID: nil)
                #expect(before.job.errorCode == .invalidInput)
                try await f.database.write { db in
                    try SQLiteMemoryExtractionStore.purge(
                        source: .userMessage(source.reference), at: TaskWorkflowFixture.now, in: db)
                }
                let after = try await store.memoryExtractionReport(
                    job.id, sessionID: address.sessionID, executionID: address.executionID, workspaceID: nil)
                #expect(after.job.state == .suppressed)
                #expect(after.job.errorCode == nil)
                #expect(after.attempts.first?.usage == nil)
                #expect(after.attempts.first?.chargedTokens == before.attempts.first?.chargedTokens)
            } catch {
                await store.close()
                throw error
            }
            await store.close()
        }
    }

    @Test func keysetPagesAndReportsAreScopedBeforeSQLLimits() async throws {
        try await withTaskWorkflow(
            outputs: Array(repeating: [.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)], count: 3), memoryEnabled: true
        ) { f in
            try await enable(in: f)
            let workspace = Workspace(id: .init(), name: "Synthetic separate workspace")
            try await f.workspaces.saveWorkspace(
                workspace, expectedRevision: nil, authorization: f.authority.authorization())
            let address = try await f.run("Synthetic selected source")
            let source = try await f.evidence(address)
            let other = try await f.run("Synthetic other turn", sessionID: address.sessionID)
            let foreign = try await f.run("Synthetic foreign source", workspaceID: workspace.id)
            let otherSource = try await f.evidence(other)
            let foreignSource = try await f.evidence(foreign)
            let store = try SQLiteMemoryExtractionStore(database: f.database, libraryID: f.authority.libraryID)
            do {
                var expected: [MemoryExtractionJobID] = []
                for _ in 2...2 {
                    expected.append(try await enqueue(source, in: f).id)
                    _ = try await enqueue(otherSource, in: f)
                    _ = try await enqueue(foreignSource, in: f)
                }
                var seen: [MemoryExtractionJobID] = []
                var cursor: MemoryExtractionStatusCursor?
                repeat {
                    let page = try await store.memoryExtractionStatus(
                        sessionID: address.sessionID,
                        executionID: address.executionID, workspaceID: nil, before: cursor, limit: 2)
                    #expect(page.jobs.count <= 2)
                    seen += page.jobs.map(\.id)
                    cursor = page.nextCursor
                } while cursor != nil
                #expect(seen == expected.sorted { $0.rawValue.uuidString > $1.rawValue.uuidString })
                #expect(Set(seen).count == 1)
                #expect(
                    try await store.memoryExtractionStatus(
                        sessionID: address.sessionID, executionID: address.executionID,
                        workspaceID: workspace.id, before: nil, limit: 1
                    ).jobs.isEmpty)
                for (session, execution, scope) in [
                    (foreign.sessionID, address.executionID, nil),
                    (address.sessionID, other.executionID, nil),
                    (address.sessionID, address.executionID, Optional(workspace.id)),
                ] {
                    await #expect(throws: MiraError.self) {
                        try await store.memoryExtractionReport(
                            expected[0], sessionID: session, executionID: execution, workspaceID: scope)
                    }
                }
                let wrong = MemoryExtractionStatusCursor(
                    workspaceID: workspace.id, sessionID: address.sessionID,
                    executionID: address.executionID, createdAt: TaskWorkflowFixture.now, jobID: expected[0])
                await #expect(throws: MiraError.self) {
                    try await store.memoryExtractionStatus(
                        sessionID: address.sessionID, executionID: address.executionID,
                        workspaceID: nil, before: wrong, limit: 2)
                }
                for limit in [0, 33] {
                    await #expect(throws: MiraError.self) {
                        try await store.memoryExtractionStatus(
                            sessionID: address.sessionID, executionID: address.executionID,
                            workspaceID: nil, before: nil, limit: limit)
                    }
                }
            } catch {
                await store.close()
                throw error
            }
            await store.close()
        }
    }

    @Test func compactQueriesRejectCorruptionAndNeverDecodeRequestBodies() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { f in
            try await enable(in: f)
            let address = try await f.run("Synthetic request body")
            let source = try await f.evidence(address)
            let job = try await enqueue(source, in: f)
            let store = try SQLiteMemoryExtractionStore(database: f.database, libraryID: f.authority.libraryID)
            do {
                let claim = try await claim(job.id, ordinal: 1, source: source, store: store, f: f)
                _ = try await dispatch(claim, source: source, store: store, f: f)
                let before = try await store.memoryExtractionReport(
                    job.id, sessionID: address.sessionID,
                    executionID: address.executionID, workspaceID: nil)
                try await f.database.write { db in
                    // Inaccessible/corrupt payload JSON must not be loaded by accounting reads.
                    try db.execute(
                        sql: "UPDATE memory_extraction_attempts SET json = ?",
                        arguments: [Data("body unavailable".utf8)])
                }
                #expect(
                    try await store.memoryExtractionReport(
                        job.id, sessionID: address.sessionID,
                        executionID: address.executionID, workspaceID: nil) == before)
                try await f.database.write { db in
                    let bytes = try #require(
                        try Data.fetchOne(db, sql: "SELECT accounting FROM memory_extraction_attempts"))
                    var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                    json["reservedTokens"] = 9
                    try db.execute(
                        sql: "UPDATE memory_extraction_attempts SET accounting = ?",
                        arguments: [try JSONSerialization.data(withJSONObject: json)])
                }
                await #expect(throws: MiraError.self) {
                    try await store.memoryExtractionReport(
                        job.id, sessionID: address.sessionID,
                        executionID: address.executionID, workspaceID: nil)
                }
            } catch {
                await store.close()
                throw error
            }
            await store.close()
        }
    }

    private func enable(in f: TaskWorkflowFixture) async throws { _ = f }

    private func enqueue(_ source: SessionUserEvidence, in f: TaskWorkflowFixture) async throws -> MemoryExtractionJob {
        let origin = try await f.library.withSnapshot { snapshot in
            for batch in try snapshot.readBatches(sessionID: source.reference.sessionID) {
                for event in batch.events {
                    if case .finished(let completion) = event.fact,
                        completion.executionID == source.reference.originalExecutionID
                    {
                        return MemoryExtractionOrigin(
                            source: source.reference, completedExecutionID: completion.executionID,
                            completionEventID: event.id, completionHead: .init(cursor: batch.cursor, batchID: batch.id))
                    }
                }
            }
            throw MiraError(.storage, "Synthetic completion is missing.")
        }
        return try await f.database.write { db in
            try #require(
                try SQLiteMemoryExtractionStore.enqueue(
                    origin: origin, source: source, at: TaskWorkflowFixture.now, in: db))
        }
    }

    private func claim(
        _ id: MemoryExtractionJobID, ordinal: Int, source: SessionUserEvidence,
        store: SQLiteMemoryExtractionStore, f: TaskWorkflowFixture
    ) async throws -> MemoryExtractionClaim {
        try #require(
            await store.claimMemoryExtraction(
                id, expectedAttemptCount: ordinal - 1, source: source,
                selection: .init(
                    route: f.route,
                    binding: nil), authorization: f.authority.authorization(),
                at: TaskWorkflowFixture.now))
    }

    private func dispatch(
        _ claim: MemoryExtractionClaim, source: SessionUserEvidence,
        store: SQLiteMemoryExtractionStore, f: TaskWorkflowFixture
    ) async throws -> Int {
        let request = AgentPreparedModelRequest(
            adapter: claim.route.adapter,
            input: try MemoryExtractionRequestBuilder.input(for: claim), wirePayload: .object([:]),
            estimatedInputTokens: 1)
        let reserved = try await store.prepareMemoryExtraction(
            claim, request: request, source: source,
            authorization: f.authority.authorization(), at: TaskWorkflowFixture.now)
        try await store.markMemoryExtractionDispatched(
            claim, source: source,
            authorization: f.authority.authorization(), at: TaskWorkflowFixture.now)
        return reserved
    }
}
