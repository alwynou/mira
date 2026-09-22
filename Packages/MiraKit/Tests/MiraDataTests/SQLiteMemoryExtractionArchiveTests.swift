import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("SQLite memory extraction archives", .timeLimit(.minutes(2)))
struct SQLiteMemoryExtractionArchiveTests {
    @Test
    func archiveKeepsQueuedDispatchedAndCompletedHistoryAndPausesLiveWorkOnRestore() async throws {
        try await withTaskWorkflow(
            outputs: [
                [.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)],
                [.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)],
                [.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)],
            ], memoryEnabled: true
        ) { fixture in
            try await enableCapture(in: fixture)
            let first = try await completedSource(in: fixture, text: "I prefer green tea")
            let second = try await completedSource(in: fixture, text: "I work from Shanghai")
            let third = try await completedSource(in: fixture, text: "I read paper books")
            let firstJob = try #require(
                await enqueue(origin: origin(for: first, in: fixture), source: first, in: fixture))
            let secondJob = try #require(
                await enqueue(origin: origin(for: second, in: fixture), source: second, in: fixture))
            let thirdJob = try #require(
                await enqueue(origin: origin(for: third, in: fixture), source: third, in: fixture))

            try await withExtractionStore(fixture) { store in
                let auth = try await fixture.authority.authorization()
                let selection = selection(for: fixture)
                let completedClaim = try #require(
                    try await store.claimMemoryExtraction(
                        thirdJob.id, expectedAttemptCount: 0, source: third, selection: selection,
                        authorization: auth, at: TaskWorkflowFixture.now))
                let completedRequest = try preparedRequest(claim: completedClaim)
                _ = try await store.prepareMemoryExtraction(
                    completedClaim, request: completedRequest, source: third,
                    authorization: auth, at: TaskWorkflowFixture.now)
                try await store.markMemoryExtractionDispatched(
                    completedClaim, source: third, authorization: auth, at: TaskWorkflowFixture.now)
                _ = try await store.completeMemoryExtraction(
                    completedClaim, source: third,
                    output: .init(blocks: [.init(id: "text", content: .text("{\"version\":4,\"items\":[],\"retractions\":[]}"))], continuation: nil, usage: .init(), finishReason: .stop),
                    authorization: auth, at: TaskWorkflowFixture.now)

                let liveClaim = try #require(
                    try await store.claimMemoryExtraction(
                        secondJob.id, expectedAttemptCount: 0, source: second, selection: selection,
                        authorization: auth, at: TaskWorkflowFixture.now))
                let liveRequest = try preparedRequest(claim: liveClaim)
                _ = try await store.prepareMemoryExtraction(
                    liveClaim, request: liveRequest, source: second,
                    authorization: auth, at: TaskWorkflowFixture.now)
                try await store.markMemoryExtractionDispatched(
                    liveClaim, source: second, authorization: auth, at: TaskWorkflowFixture.now)

                // A dispatched attempt owns a reservation which restoration must settle into
                // the charged total exactly once.

                let module = try SQLiteMemoryExtractionStore.archiveModule()
                try await inspect(module, fixture: fixture)
                #expect(
                    try await store.memoryExtractionJobs(sessionID: first.reference.sessionID, state: .queued, limit: 8)
                        .contains { $0.id == firstJob.id })
                #expect(
                    try await store.memoryExtractionJobs(
                        sessionID: second.reference.sessionID, state: .running, limit: 8
                    ).contains { $0.id == secondJob.id })
                #expect(
                    try await store.memoryExtractionJobs(
                        sessionID: third.reference.sessionID, state: .completed, limit: 8
                    ).contains { $0.id == thirdJob.id })

                guard case .prepare(let apply, let verify) = module.restoration else {
                    Issue.record("Memory extraction archive must pause unfinished jobs during restoration.")
                    return
                }
                try await fixture.database.write { db in try apply(db, TaskWorkflowFixture.now.addingTimeInterval(10)) }
                try await fixture.database.read { db in try verify(db) }
                let paused = try await store.memoryExtractionJobs(
                    sessionID: first.reference.sessionID, state: .paused, limit: 8)
                #expect(paused.contains { $0.id == firstJob.id })
                #expect(
                    try await store.memoryExtractionJobs(
                        sessionID: second.reference.sessionID, state: .paused, limit: 8
                    ).contains { $0.id == secondJob.id })
                #expect(
                    try await store.memoryExtractionJobs(
                        sessionID: third.reference.sessionID, state: .completed, limit: 8
                    ).contains { $0.id == thirdJob.id })
                try await inspect(module, fixture: fixture)
            }
        }
    }

    @Test(arguments: ["source", "completion", "mirror", "ordinal", "accounting"])
    func archiveRejectsForgedOriginAndSQLMirrors(_ mutation: String) async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            try await enableCapture(in: fixture)
            let source = try await completedSource(in: fixture, text: "I prefer jasmine tea")
            let job = try #require(await enqueue(origin: origin(for: source, in: fixture), source: source, in: fixture))
            try await withExtractionStore(fixture) { store in
                let auth = try await fixture.authority.authorization()
                let selection = selection(for: fixture)
                if mutation == "ordinal" || mutation == "accounting" {
                    let claim = try #require(
                        try await store.claimMemoryExtraction(
                            job.id, expectedAttemptCount: 0, source: source, selection: selection,
                            authorization: auth, at: TaskWorkflowFixture.now))
                    let request = try preparedRequest(claim: claim)
                    _ = try await store.prepareMemoryExtraction(
                        claim, request: request, source: source, authorization: auth, at: TaskWorkflowFixture.now)
                    try await store.markMemoryExtractionDispatched(
                        claim, source: source, authorization: auth, at: TaskWorkflowFixture.now)
                    try await fixture.database.write { db in
                        try db.execute(
                            sql: mutation == "ordinal"
                                ? "UPDATE memory_extraction_attempts SET ordinal = 99 WHERE job_id = ?"
                                : "UPDATE memory_extraction_attempts SET accounting_digest = '\(String(repeating: "0", count: 64))' WHERE job_id = ?",
                            arguments: [job.id.rawValue.uuidString.lowercased()])
                    }
                } else {
                    try await fixture.database.write { db in
                        guard
                            let row = try Row.fetchOne(
                                db, sql: "SELECT json FROM memory_extraction_jobs WHERE id = ?",
                                arguments: [job.id.rawValue.uuidString.lowercased()]),
                            let bytes: Data = row["json"]
                        else { throw MiraError(.storage, "Missing extraction fixture.") }
                        var forged = try SessionCodec.decode(MemoryExtractionJob.self, from: bytes)
                        if mutation == "completion" {
                            forged = MemoryExtractionJob(
                                id: forged.id,
                                origin: .init(
                                    source: forged.origin.source,
                                    completedExecutionID: forged.origin.completedExecutionID,
                                    completionEventID: UUID(), completionHead: forged.origin.completionHead),
                                workspaceID: forged.workspaceID,
                                extractorRevision: forged.extractorRevision, state: forged.state,
                                attemptCount: forged.attemptCount, createdAt: forged.createdAt,
                                updatedAt: forged.updatedAt, error: forged.error,
                                memoryIDs: forged.memoryIDs, candidateMemoryIDs: forged.candidateMemoryIDs)
                        } else if mutation == "source" {
                            let forgedReference = SessionEvidenceReference(
                                sessionID: forged.origin.source.sessionID,
                                originalExecutionID: forged.origin.source.originalExecutionID,
                                userMessageID: forged.origin.source.userMessageID,
                                admissionEventID: forged.origin.source.admissionEventID,
                                admissionSequence: forged.origin.source.admissionSequence + 1)
                            forged = MemoryExtractionJob(
                                id: forged.id,
                                origin: .init(
                                    source: forgedReference, completedExecutionID: forged.origin.completedExecutionID,
                                    completionEventID: forged.origin.completionEventID,
                                    completionHead: forged.origin.completionHead),
                                workspaceID: forged.workspaceID,
                                extractorRevision: forged.extractorRevision, state: forged.state,
                                attemptCount: forged.attemptCount, createdAt: forged.createdAt,
                                updatedAt: forged.updatedAt, error: forged.error,
                                memoryIDs: forged.memoryIDs, candidateMemoryIDs: forged.candidateMemoryIDs)
                        }
                        if mutation == "source" {
                            let recomputedSourceKey = try SQLiteMemoryExtractionStore.sourceKey(forged.origin.source)
                            try db.execute(
                                sql: "UPDATE memory_extraction_jobs SET source_key = ?, json = ? WHERE id = ?",
                                arguments: [
                                    recomputedSourceKey, try SessionCodec.encode(forged),
                                    job.id.rawValue.uuidString.lowercased(),
                                ])
                        } else {
                            try db.execute(
                                sql: "UPDATE memory_extraction_jobs SET json = ? WHERE id = ?",
                                arguments: [try SessionCodec.encode(forged), job.id.rawValue.uuidString.lowercased()])
                        }
                    }
                }
                if mutation == "mirror" {
                    try await fixture.database.write { db in
                        try db.execute(
                            sql: "UPDATE memory_extraction_jobs SET source_key = ? WHERE id = ?",
                            arguments: [String(repeating: "0", count: 64), job.id.rawValue.uuidString.lowercased()])
                    }
                }
                let module = try SQLiteMemoryExtractionStore.archiveModule()
                await #expect(throws: MiraError.self) { try await inspect(module, fixture: fixture) }
            }
        }
    }
}

private func enableCapture(in fixture: TaskWorkflowFixture) async throws { _ = fixture }

private func completedSource(in fixture: TaskWorkflowFixture, text: String) async throws -> SessionUserEvidence {
    let address = try await fixture.run(text)
    return try await fixture.evidence(address)
}

private func origin(for source: SessionUserEvidence, in fixture: TaskWorkflowFixture) async throws
    -> MemoryExtractionOrigin
{
    let (eventID, head) = try await fixture.library.withSnapshot { snapshot in
        for batch in try snapshot.readBatches(sessionID: source.reference.sessionID) {
            for event in batch.events {
                if case .finished(let completion) = event.fact,
                    completion.executionID == source.reference.originalExecutionID
                {
                    return (event.id, SessionJournalHead(cursor: batch.cursor, batchID: batch.id))
                }
            }
        }
        throw MiraError(.storage, "The completed extraction origin was not found in the journal.")
    }
    return .init(
        source: source.reference, completedExecutionID: source.reference.originalExecutionID,
        completionEventID: eventID, completionHead: head)
}

private func enqueue(
    origin: MemoryExtractionOrigin, source: SessionUserEvidence,
    in fixture: TaskWorkflowFixture
) async throws -> MemoryExtractionJob? {
    try await fixture.database.write { db in
        try SQLiteMemoryExtractionStore.enqueue(
            origin: origin, source: source,
            at: TaskWorkflowFixture.now, in: db)
    }
}

private func selection(for fixture: TaskWorkflowFixture) -> AgentModelRouteResolution {
    .init(
        route: fixture.route,
        binding: nil)
}

private func preparedRequest(claim: MemoryExtractionClaim) throws -> AgentPreparedModelRequest {
    .init(
        adapter: claim.route.adapter, input: try MemoryExtractionRequestBuilder.input(for: claim),
        wirePayload: .object(["schema": .string("memory.extraction.v1")]), estimatedInputTokens: 1)
}

private func withExtractionStore<T: Sendable>(
    _ fixture: TaskWorkflowFixture, _ body: (SQLiteMemoryExtractionStore) async throws -> T
) async throws -> T {
    let store = try SQLiteMemoryExtractionStore(database: fixture.database, libraryID: fixture.authority.libraryID)
    do {
        let value = try await body(store)
        await store.close()
        return value
    } catch {
        await store.close()
        throw error
    }
}

private func inspect(_ module: SQLiteArchiveModule, fixture: TaskWorkflowFixture) async throws {
    try await fixture.library.withSnapshot { snapshot in
        try fixture.database.read { db in _ = try module.inspect(db, snapshot) }
    }
}
