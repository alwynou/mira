import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

/// Acceptance coverage for the journal-triggered extraction queue.  The fixture
/// deliberately uses the same caller-owned business database as the memory,
/// settings, workspace, and library-authority stores.
@Suite("Journal memory extraction store", .timeLimit(.minutes(2)))
struct JournalMemoryExtractionStoreTests {
    @Test func repeatedLargeRequestsHaveNoDailyQuotaButStillRespectModelContext() async throws {
        let reply: [AgentModelStreamEvent] = [.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]
        try await withTaskWorkflow(outputs: Array(repeating: reply, count: 3), memoryEnabled: true) { fixture in
            try await withExtractionStore(fixture) { store in
                let auth = try await fixture.authority.authorization()
                var settled = 0
                for index in 0..<3 {
                    let source = try await completedSource(in: fixture, text: "Synthetic stable preference \(index)")
                    let job = try #require(await enqueue(origin: origin(for: source), source: source, in: fixture))
                    let claim = try #require(try await store.claimMemoryExtraction(job.id, expectedAttemptCount: 0,
                        source: source, selection: .init(route: fixture.route, binding: nil), authorization: auth, at: TaskWorkflowFixture.now))
                    let input = try MemoryExtractionRequestBuilder.input(for: claim)
                    let oversized = AgentPreparedModelRequest(adapter: fixture.route.adapter, input: input,
                        wirePayload: .object([:]), estimatedInputTokens: fixture.route.contextWindow)
                    await #expect(throws: MiraError.self) {
                        _ = try await store.prepareMemoryExtraction(claim, request: oversized, source: source,
                            authorization: auth, at: TaskWorkflowFixture.now)
                    }
                    #expect(try await attemptUsage(store: store, claim: claim).state == .claimed)
                    let request = AgentPreparedModelRequest(adapter: fixture.route.adapter, input: input,
                        wirePayload: .object(["synthetic": .string(String(repeating: "x", count: 12_000))]), estimatedInputTokens: 12_000)
                    let estimate = try await store.prepareMemoryExtraction(claim, request: request, source: source,
                        authorization: auth, at: TaskWorkflowFixture.now)
                    #expect(estimate > 10_000)
                    try await store.markMemoryExtractionDispatched(claim, source: source, authorization: auth, at: TaskWorkflowFixture.now)
                    let output = AgentModelOutput(blocks: [.init(id: "text", content: .text("{\"version\":3,\"items\":[]}"))],
                        continuation: nil, usage: .init(), finishReason: .stop)
                    let completed = try await store.completeMemoryExtraction(claim, source: source, output: output,
                        authorization: auth, at: TaskWorkflowFixture.now)
                    #expect(completed.state == .completed)
                    settled += try await attemptUsage(store: store, claim: claim).chargedTokens
                }
                #expect(settled > 30_000)
            }
        }
    }

    @Test func extractionClaimFindsRelevantManualMemoryBeyondLegacyFirstThirtyTwo() async throws {
        try await withTaskWorkflow(
            outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))),
                       .blockFinished(id: "text"), .finished(.stop)]],
            memoryEnabled: true
        ) { fixture in
            let memory = try #require(fixture.memory)
            let auth = try await fixture.authority.authorization()
            let now = TaskWorkflowFixture.now
            try await fixture.database.write { db in
                for index in 0..<40 {
                    _ = try SQLiteMemoryStore.createMemoryInTransaction(
                        draft: .init(content: "Unrelated preference \(index)", scope: .global),
                        source: .manualEntry(id: UUID(), statement: "Unrelated preference \(index)"),
                        operationID: UUID(), replacing: nil, expectedRevision: nil, at: now, in: db)
                }
            }
            let target = try await memory.createMemory(
                draft: .init(content: "I prefer green tea", scope: .global),
                source: .manualEntry(id: UUID(), statement: "I prefer green tea"),
                operationID: UUID(), replacing: nil, expectedRevision: nil,
                authorization: auth, at: now).memory

            let source = try await completedSource(in: fixture, text: "I prefer black tea now instead of green tea")
            let job = try #require(await enqueue(origin: origin(for: source), source: source, in: fixture))
            try await withExtractionStore(fixture) { store in
                let claim = try #require(try await store.claimMemoryExtraction(
                    job.id, expectedAttemptCount: 0, source: source,
                    selection: .init(route: fixture.route, binding: nil),
                    authorization: auth, at: now))
                #expect(claim.existingMemories.contains { $0.id == target.id })
                #expect(claim.existingMemories.count <= 32)
            }
        }
    }

    @Test func sameOriginIsEnqueuedAtMostOnce() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            let source = try await completedSource(in: fixture, text: "I prefer green tea")
            let origin = origin(for: source)


            let first = try await enqueue(origin: origin, source: source, in: fixture)
            let second = try await enqueue(origin: origin, source: source, in: fixture)
            try await withExtractionStore(fixture) { store in
                let jobs = try await store.memoryExtractionJobs(
                    sessionID: source.reference.sessionID, state: nil, limit: 8)
                #expect(first != nil)
                #expect(second == nil || second?.id == first?.id)
                #expect(jobs.count == 1)
            }
        }
    }

    @Test func onlyOneLiveClaimCanOwnAQueuedJob() async throws {
        try await withTaskWorkflow(
            outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)], [.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]],
            memoryEnabled: true
        ) { fixture in
            let source = try await completedSource(in: fixture, text: "I work from Shanghai")
            let secondSource = try await completedSource(in: fixture, text: "I work from Hangzhou")

            let job = try #require(await enqueue(origin: origin(for: source), source: source, in: fixture))
            let secondJob = try #require(
                await enqueue(origin: origin(for: secondSource), source: secondSource, in: fixture))
            try await withExtractionStore(fixture) { store in
                let auth = try await fixture.authority.authorization()
                let selection = AgentModelRouteResolution(
                    route: fixture.route,
                    binding: nil)
                let claim = try await store.claimMemoryExtraction(
                    job.id, expectedAttemptCount: 0,
                    source: source, selection: selection, authorization: auth, at: TaskWorkflowFixture.now)
                #expect(claim != nil)
                let second = try await store.claimMemoryExtraction(
                    secondJob.id, expectedAttemptCount: 0,
                    source: secondSource, selection: selection, authorization: auth, at: TaskWorkflowFixture.now)
                #expect(second == nil)
            }
        }
    }

    @Test func preparedRequestIsFrozenAndSubstitutionIsRejected() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            let source = try await completedSource(in: fixture, text: "I prefer jasmine tea")

            let job = try #require(await enqueue(origin: origin(for: source), source: source, in: fixture))
            try await withExtractionStore(fixture) { store in
                let auth = try await fixture.authority.authorization()
                let selection = AgentModelRouteResolution(
                    route: fixture.route,
                    binding: nil)
                let claim = try #require(
                    try await store.claimMemoryExtraction(
                        job.id, expectedAttemptCount: 0,
                        source: source, selection: selection, authorization: auth, at: TaskWorkflowFixture.now))
                let request = try preparedRequest(claim: claim)
                let substituted = AgentPreparedModelRequest(
                    adapter: request.adapter, input: request.input,
                    wirePayload: .object(["substituted": .bool(true)]),
                    estimatedInputTokens: request.estimatedInputTokens)
                let reserved = try await store.prepareMemoryExtraction(
                    claim, request: request, source: source,
                    authorization: auth, at: TaskWorkflowFixture.now)
                await #expect(throws: MiraError.self) {
                    _ = try await store.prepareMemoryExtraction(
                        claim, request: substituted, source: source,
                        authorization: auth, at: TaskWorkflowFixture.now)
                }
                #expect(try await attemptUsage(store: store, claim: claim).reservedTokens == reserved)
            }
        }
    }

    @Test func unsentRecoveryRequeuesButDispatchedFailurePauses() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            let source = try await completedSource(in: fixture, text: "I like quiet mornings")

            try await withExtractionStore(fixture) { store in
                let first = try #require(await enqueue(origin: origin(for: source), source: source, in: fixture))
                let auth = try await fixture.authority.authorization()
                let selection = AgentModelRouteResolution(
                    route: fixture.route,
                    binding: nil)
                let claim = try #require(
                    try await store.claimMemoryExtraction(
                        first.id, expectedAttemptCount: 0,
                        source: source, selection: selection, authorization: auth, at: TaskWorkflowFixture.now))
                let request = try preparedRequest(claim: claim)
                _ = try await store.prepareMemoryExtraction(
                    claim, request: request, source: source,
                    authorization: auth, at: TaskWorkflowFixture.now)
                try await store.recoverMemoryExtraction(
                    authorization: auth, at: TaskWorkflowFixture.now.addingTimeInterval(301))
                #expect(
                    try await store.memoryExtractionJobs(
                        sessionID: source.reference.sessionID, state: .queued, limit: 8
                    ).contains { $0.id == first.id })
                let reclaimed = try #require(
                    try await store.claimMemoryExtraction(
                        first.id, expectedAttemptCount: 1,
                        source: source, selection: selection, authorization: auth,
                        at: TaskWorkflowFixture.now.addingTimeInterval(302)))
                let reclaimedRequest = try preparedRequest(claim: reclaimed)
                _ = try await store.prepareMemoryExtraction(
                    reclaimed, request: reclaimedRequest, source: source,
                    authorization: auth, at: TaskWorkflowFixture.now.addingTimeInterval(302))
                try await store.markMemoryExtractionDispatched(
                    reclaimed, source: source, authorization: auth, at: TaskWorkflowFixture.now.addingTimeInterval(302))
                try await store.failMemoryExtraction(
                    reclaimed,
                    error: MiraError(.network, "Synthetic extraction failure."), authorization: auth,
                    at: TaskWorkflowFixture.now.addingTimeInterval(302))
                #expect(
                    try await store.memoryExtractionJobs(
                        sessionID: source.reference.sessionID, state: .paused, limit: 8
                    ).contains { $0.id == first.id })
            }
        }
    }

    @Test func reservationChargesFullCeilingWhenUsageIsUnknown() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            let source = try await completedSource(in: fixture, text: "I prefer short walks")

            try await withExtractionStore(fixture) { store in
                let job = try #require(await enqueue(origin: origin(for: source), source: source, in: fixture))
                let auth = try await fixture.authority.authorization()
                let selection = AgentModelRouteResolution(
                    route: fixture.route,
                    binding: nil)
                let claim = try #require(
                    try await store.claimMemoryExtraction(
                        job.id, expectedAttemptCount: 0,
                        source: source, selection: selection, authorization: auth, at: TaskWorkflowFixture.now))
                let request = try preparedRequest(claim: claim)
                let reserved = try await store.prepareMemoryExtraction(
                    claim, request: request, source: source,
                    authorization: auth, at: TaskWorkflowFixture.now)
                #expect(reserved > 0)
                try await store.markMemoryExtractionDispatched(
                    claim, source: source, authorization: auth, at: TaskWorkflowFixture.now)
                let output = AgentModelOutput(
                    blocks: [.init(id: "text", content: .text("{\"version\":3,\"items\":[]}"))],
                    continuation: nil, usage: .init(), finishReason: .stop)
                _ = try await store.completeMemoryExtraction(
                    claim, source: source, output: output,
                    authorization: auth, at: TaskWorkflowFixture.now)
                let usage = try await attemptUsage(store: store, claim: claim)
                #expect(usage.state == .completed && usage.chargedTokens == reserved)
                #expect(usage.usage?.inputTokens == nil)
            }
        }
    }

    @Test func dispatchWriteFailureRollsBackWithoutLosingReservation() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            let source = try await completedSource(in: fixture, text: "I prefer a paper notebook")

            try await withExtractionStore(fixture) { store in
                let job = try #require(await enqueue(origin: origin(for: source), source: source, in: fixture))
                let auth = try await fixture.authority.authorization()
                let selection = AgentModelRouteResolution(
                    route: fixture.route,
                    binding: nil)
                let claim = try #require(
                    try await store.claimMemoryExtraction(
                        job.id, expectedAttemptCount: 0,
                        source: source, selection: selection, authorization: auth, at: TaskWorkflowFixture.now))
                let request = try preparedRequest(claim: claim)
                let reserved = try await store.prepareMemoryExtraction(
                    claim, request: request, source: source,
                    authorization: auth, at: TaskWorkflowFixture.now)
                try await fixture.database.write { db in
                    try db.execute(
                        sql:
                            "CREATE TRIGGER extraction_dispatch_failure BEFORE UPDATE OF status ON memory_extraction_attempts WHEN NEW.status = 'dispatched' BEGIN SELECT RAISE(ABORT, 'synthetic'); END"
                    )
                }
                await #expect(throws: MiraError.self) {
                    try await store.markMemoryExtractionDispatched(
                        claim, source: source, authorization: auth, at: TaskWorkflowFixture.now)
                }
                #expect(
                    try await store.memoryExtractionJobs(
                        sessionID: source.reference.sessionID, state: .running, limit: 8
                    ).count == 1)
                let usage = try await attemptUsage(store: store, claim: claim)
                #expect(usage.state == .prepared && usage.dispatchedAt == nil)
                #expect(usage.reservedTokens == reserved && usage.chargedTokens == 0)
            }
        }
    }

    @Test func suppressedSourceIsNotEnqueued() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            let source = try await completedSource(in: fixture, text: "I prefer decaf")

            let memory = try #require(fixture.memory)
            let authorization = try await fixture.authority.authorization()
            _ = try await memory.createMemory(
                draft: .init(content: source.text, scope: .global),
                source: .userMessage(evidence: source, excerpt: source.text), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: authorization,
                at: TaskWorkflowFixture.now)
            try await fixture.database.write { db in
                try SQLiteMemoryStore.suppress(.userMessage(source.reference), strength: 3, in: db)
            }
            #expect(try await enqueue(origin: origin(for: source), source: source, in: fixture) == nil)
        }
    }

    @Test func connectionChangeInvalidatesClaimBeforeDispatch() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            let source = try await completedSource(in: fixture, text: "I prefer a standing desk")

            let job = try #require(await enqueue(origin: origin(for: source), source: source, in: fixture))
            try await withExtractionStore(fixture) { store in
                let auth = try await fixture.authority.authorization()
                let selection = AgentModelRouteResolution(
                    route: fixture.route,
                    binding: nil)
                let claim = try #require(
                    try await store.claimMemoryExtraction(
                        job.id, expectedAttemptCount: 0,
                        source: source, selection: selection, authorization: auth, at: TaskWorkflowFixture.now))
                let request = try preparedRequest(claim: claim)
                _ = try await store.prepareMemoryExtraction(
                    claim, request: request, source: source, authorization: auth, at: TaskWorkflowFixture.now)
                let connection = try #require(try await fixture.settings.connection(id: fixture.route.connectionID))
                try await fixture.settings.saveConnection(.init(id: connection.id, revision: connection.revision + 1,
                    configurationRevision: connection.configurationRevision + 1, name: connection.name,
                    isEnabled: false, definitionID: connection.definitionID, endpoints: connection.endpoints,
                    discovery: connection.discovery, defaultInvocation: connection.defaultInvocation),
                    expectedRevision: connection.revision, authorization: auth)
                await #expect(throws: MiraError.self) {
                    try await store.markMemoryExtractionDispatched(
                        claim, source: source, authorization: auth, at: TaskWorkflowFixture.now)
                }
                #expect(try await attemptUsage(store: store, claim: claim).state == .prepared)
            }
        }
    }

    @Test func forgettingPurgesExtractionBodiesAndPreservesSettledCost() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { f in
            let source = try await completedSource(in: f, text: "I prefer green tea")

            let memories = try #require(f.memory)
            let auth = try await f.authority.authorization()
            let memory = try await memories.createMemory(
                draft: .init(content: source.text, scope: .global),
                source: .userMessage(evidence: source, excerpt: source.text), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: auth, at: TaskWorkflowFixture.now
            ).memory
            try await withExtractionStore(f) { store in
                let job = try #require(try await enqueue(origin: origin(for: source), source: source, in: f))
                let selection = AgentModelRouteResolution(
                    route: f.route,
                    binding: nil
                )
                let claim = try #require(
                    try await store.claimMemoryExtraction(
                        job.id, expectedAttemptCount: 0,
                        source: source, selection: selection, authorization: auth, at: TaskWorkflowFixture.now))
                _ = try await store.prepareMemoryExtraction(
                    claim, request: preparedRequest(claim: claim), source: source,
                    authorization: auth, at: TaskWorkflowFixture.now)
                try await store.markMemoryExtractionDispatched(
                    claim, source: source, authorization: auth, at: TaskWorkflowFixture.now)
                let output = try directOutput(source.text)
                _ = try await store.completeMemoryExtraction(
                    claim, source: source, output: output,
                    authorization: auth, at: TaskWorkflowFixture.now)
                let before = try #require(
                    await store.memoryExtractionDecisionReport(job.id, ordinal: 1, workspaceID: nil))
                #expect(before.decisions?.count == 2)
                let maintenance = try await f.access.begin(
                    .init(
                        id: UUID(), namespace: "memory.forget", revision: 1,
                        scope: .sources([
                            .domain(namespace: "memories", id: memory.id.rawValue, revision: memory.revision)
                        ]),
                        requestedAt: TaskWorkflowFixture.now), expected: auth)
                #expect(await f.runtime.shutdown().isSettled)
                await f.tasks.close()
                await f.reminders.close()
                try await f.access.waitForQuiescence()
                _ = try await memories.purgeMemory(
                    memory.id, workspaceID: nil, expectedRevision: memory.revision,
                    maintenance: maintenance, at: TaskWorkflowFixture.now)
                try await f.database.read { db in
                    let attempt = try SQLiteMemoryExtractionStore.attempt(claim.attemptID, in: db)
                    #expect(attempt.bodyPurgedAt != nil)
                    #expect(
                        attempt.request == nil && attempt.output == nil && attempt.error == nil
                            && attempt.decisions == nil)
                    #expect(attempt.chargedTokens == 12)
                    #expect(attempt.reportedUsage == output.usage)
                    #expect(attempt.accounting.route == nil && attempt.accounting.usage == output.usage)
                    #expect(try SQLiteMemoryExtractionStore.job(job.id, in: db).state == .suppressed)
                    let bytes = try #require(
                        try Data.fetchOne(
                            db, sql: "SELECT json FROM memory_extraction_attempts WHERE id = ?",
                            arguments: [claim.attemptID.uuidString.lowercased()]))
                    #expect(String(decoding: bytes, as: UTF8.self).contains(source.text) == false)
                }
                await #expect(throws: MiraError.self) {
                    try await store.completeMemoryExtraction(
                        claim, source: source, output: output,
                        authorization: auth, at: TaskWorkflowFixture.now)
                }
                // This verifies the domain operation under pending maintenance, not a full journal privacy closure.
            }
        }
    }

    @Test(arguments: [false, true])
    func proposalDecisionsAreAtomicDurableAndScoped(failCommit: Bool) async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { f in
            let source = try await completedSource(in: f, text: "I prefer quiet mornings")

            try await withExtractionStore(f) { store in
                let job = try #require(await enqueue(origin: origin(for: source), source: source, in: f))
                let auth = try await f.authority.authorization()
                let selection = AgentModelRouteResolution(
                    route: f.route,
                    binding: nil
                )
                let claim = try #require(
                    await store.claimMemoryExtraction(
                        job.id, expectedAttemptCount: 0,
                        source: source, selection: selection, authorization: auth, at: TaskWorkflowFixture.now))
                #expect(try await store.memoryExtractionDecisionReport(job.id, ordinal: 1, workspaceID: nil) == nil)
                let reserved = try await store.prepareMemoryExtraction(
                    claim, request: preparedRequest(claim: claim),
                    source: source, authorization: auth, at: TaskWorkflowFixture.now)
                try await store.markMemoryExtractionDispatched(
                    claim, source: source,
                    authorization: auth, at: TaskWorkflowFixture.now)
                let output = try directOutput(source.text)
                if failCommit {
                    try await f.database.write { db in
                        try db.execute(
                            sql:
                                "CREATE TRIGGER extraction_completion_failure BEFORE UPDATE OF state ON memory_extraction_jobs WHEN NEW.state = 'completed' BEGIN SELECT RAISE(ABORT, 'synthetic'); END"
                        )
                    }
                    await #expect(throws: MiraError.self) {
                        _ = try await store.completeMemoryExtraction(
                            claim, source: source, output: output,
                            authorization: auth, at: TaskWorkflowFixture.now)
                    }
                    #expect(try await store.memoryExtractionDecisionReport(job.id, ordinal: 1, workspaceID: nil) == nil)
                    let accounting = try await store.memoryExtractionReport(job.id, sessionID: source.reference.sessionID,
                        executionID: job.origin.completedExecutionID, workspaceID: nil)
                    #expect(accounting.attempts.last?.state == .dispatched && accounting.attempts.last?.usage == nil)
                    #expect(accounting.attempts.last?.chargedTokens == 0)
                    #expect(accounting.attempts.last?.reservedTokens == reserved)
                    try await f.database.write { db in
                        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_records") == 0)
                        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_assertions") == 0)
                        try db.execute(sql: "DROP TRIGGER extraction_completion_failure")
                    }
                }
                let completed = try await store.completeMemoryExtraction(
                    claim, source: source, output: output,
                    authorization: auth, at: TaskWorkflowFixture.now)
                let replay = try await store.completeMemoryExtraction(
                    claim, source: source, output: output,
                    authorization: auth, at: TaskWorkflowFixture.now)
                #expect(replay == completed)
                #expect(completed.memoryIDs.count == 1)
                await store.close()
                try await withExtractionStore(f) { reopened in
                    let report = try #require(
                        await reopened.memoryExtractionDecisionReport(job.id, ordinal: 1, workspaceID: nil))
                    let decisions = try #require(report.decisions)
                    #expect(report.attemptID == claim.attemptID && report.ordinal == 1 && report.bodyPurgedAt == nil)
                    #expect(decisions.map(\.proposalIndex) == [0, 1])
                    #expect(decisions.map(\.disposition) == [.created, .reused])
                    #expect(
                        decisions.allSatisfy {
                            $0.validationReviewReason == nil
                        })
                    #expect(
                        decisions.allSatisfy { $0.memoryID == completed.memoryIDs[0] && $0.memoryState == .active })
                    await #expect(throws: MiraError.self) {
                        _ = try await reopened.memoryExtractionDecisionReport(job.id, ordinal: 1, workspaceID: .init())
                    }
                    await #expect(throws: MiraError.self) {
                        _ = try await reopened.memoryExtractionDecisionReport(job.id, ordinal: 2, workspaceID: nil)
                    }
                    try await f.database.write { db in
                        var attempt = try SQLiteMemoryExtractionStore.attempt(claim.attemptID, in: db)
                        attempt.decisions = Array(try #require(attempt.decisions).reversed())
                        // Bypass the writer to simulate corrupted on-disk facts.
                        try db.execute(
                            sql: "UPDATE memory_extraction_attempts SET json = ? WHERE id = ?",
                            arguments: [
                                try SQLiteMemoryExtractionStore.encode(attempt, maximum: 16_777_216),
                                claim.attemptID.uuidString.lowercased(),
                            ])
                    }
                    await #expect(throws: MiraError.self) {
                        _ = try await reopened.memoryExtractionDecisionReport(job.id, ordinal: 1, workspaceID: nil)
                    }
                }
            }
        }
    }

    @Test func queuedJobsRotateSessionsAndSelectTheOldestJobInEachSession() async throws {
        try await withTaskWorkflow(
            outputs: Array(repeating: [.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)], count: 3),
            memoryEnabled: true
        ) { f in
            let hot = ConversationID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
            let cold = ConversationID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
            var sources: [SessionUserEvidence] = []
            for (text, sessionID) in [
                ("I prefer green tea", hot), ("I prefer white tea", hot), ("I prefer coffee", cold),
            ] {
                let address = try await f.run(text, sessionID: sessionID)
                sources.append(try await f.evidence(address))
            }

            var jobs: [MemoryExtractionJob] = []
            for (index, source) in sources.enumerated() {
                let origin = origin(for: source)
                let job = try await f.database.write { db in
                    try SQLiteMemoryExtractionStore.enqueue(
                        origin: origin, source: source,
                        at: TaskWorkflowFixture.now.addingTimeInterval(Double(index)), in: db)
                }
                jobs.append(try #require(job))
            }
            try await withExtractionStore(f) { store in
                #expect(try await store.nextQueuedMemoryExtraction(after: nil)?.id == jobs[0].id)
                #expect(try await store.nextQueuedMemoryExtraction(after: hot)?.id == jobs[2].id)
                #expect(try await store.nextQueuedMemoryExtraction(after: cold)?.id == jobs[0].id)
                let auth = try await f.authority.authorization()
                try await store.pauseMemoryExtraction(
                    jobs[0].id, expectedAttemptCount: 0,
                    error: .init(.configuration, "Synthetic queue pause."), authorization: auth,
                    at: TaskWorkflowFixture.now)
                #expect(try await store.nextQueuedMemoryExtraction(after: cold)?.id == jobs[1].id)
                try await f.database.read { db in
                    for afterSession in [false, true] {
                        let arguments: StatementArguments = afterSession ? [hot.rawValue.uuidString.lowercased()] : []
                        let plan = try Row.fetchAll(
                            db,
                            sql: "EXPLAIN QUERY PLAN "
                                + SQLiteMemoryExtractionStore.queuedJobSQL(afterSession: afterSession),
                            arguments: arguments
                        ).map { $0["detail"] as String }.joined(separator: " ")
                        #expect(plan.contains("INDEX"))
                        #expect(!plan.contains("TEMP B-TREE"))
                    }
                }
                for job in jobs.dropFirst() {
                    try await store.pauseMemoryExtraction(
                        job.id, expectedAttemptCount: 0,
                        error: .init(.configuration, "Synthetic queue pause."), authorization: auth,
                        at: TaskWorkflowFixture.now)
                }
                #expect(try await store.nextQueuedMemoryExtraction(after: cold) == nil)
            }
        }
    }

    private func directOutput(_ text: String) throws -> AgentModelOutput {
        let item: [String: Any] = [
            "content": text, "inputIndex": 0, "kind": "preference", "subject": "user", "sensitivity": "standard",
            "inferred": false, "stable": true, "confidence": "high", "validFrom": NSNull(), "validUntil": NSNull(),
            "assertion": ["mode": "directStable", "aspectKey": "daily.preference", "changeIntent": "independent"],
        ]
        let bytes = try JSONSerialization.data(
            withJSONObject: ["version": 3, "items": [item, item]], options: [.sortedKeys])
        return .init(
            blocks: [.init(id: "text", content: .text(String(decoding: bytes, as: UTF8.self)))], continuation: nil,
            usage: .init(inputTokens: 10, outputTokens: 2), finishReason: .stop)
    }

    private func attemptUsage(store: SQLiteMemoryExtractionStore, claim: MemoryExtractionClaim) async throws -> MemoryExtractionAttemptUsage {
        let report = try await store.memoryExtractionReport(claim.job.id,
            sessionID: claim.source.reference.sessionID,
            executionID: claim.job.origin.completedExecutionID, workspaceID: claim.job.workspaceID)
        return try #require(report.attempts.last)
    }

    private func completedSource(in fixture: TaskWorkflowFixture, text: String) async throws -> SessionUserEvidence {
        let address = try await fixture.run(text)
        return try await fixture.evidence(address)
    }

    private func origin(for source: SessionUserEvidence) -> MemoryExtractionOrigin {
        .init(
            source: source.reference, completedExecutionID: source.reference.originalExecutionID,
            completionEventID: UUID(),
            completionHead: source.observedHead)
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

    private func preparedRequest(claim: MemoryExtractionClaim) throws -> AgentPreparedModelRequest {
        let input = try MemoryExtractionRequestBuilder.input(for: claim)
        return .init(
            adapter: claim.route.adapter, input: input,
            wirePayload: .object(["schema": .string("memory.extraction.v1")]), estimatedInputTokens: 1)
    }

    private func withExtractionStore<T: Sendable>(
        _ fixture: TaskWorkflowFixture,
        _ body: (SQLiteMemoryExtractionStore) async throws -> T
    ) async throws -> T {
        let store = try SQLiteMemoryExtractionStore(database: fixture.database, libraryID: fixture.authority.libraryID)
        do {
            let result = try await body(store)
            await store.close()
            return result
        } catch {
            await store.close()
            throw error
        }
    }
}
