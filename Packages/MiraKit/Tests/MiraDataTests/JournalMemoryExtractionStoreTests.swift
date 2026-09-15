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
    @Test func sameOriginIsEnqueuedAtMostOnce() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            let source = try await completedSource(in: fixture, text: "I prefer green tea")
            let origin = origin(for: source)
            try await enableCapture(in: fixture)

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
            try await enableCapture(in: fixture)
            let job = try #require(await enqueue(origin: origin(for: source), source: source, in: fixture))
            let secondJob = try #require(
                await enqueue(origin: origin(for: secondSource), source: secondSource, in: fixture))
            try await withExtractionStore(fixture) { store in
                let auth = try await fixture.authority.authorization()
                let selection = AgentModelRouteResolution(
                    route: fixture.route,
                    binding: .init(
                        scope: .global, purpose: AgentModelPurposeID.memoryExtraction,
                        routeID: fixture.route.id, revision: fixture.route.revision))
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
            try await enableCapture(in: fixture)
            let job = try #require(await enqueue(origin: origin(for: source), source: source, in: fixture))
            try await withExtractionStore(fixture) { store in
                let auth = try await fixture.authority.authorization()
                let selection = AgentModelRouteResolution(
                    route: fixture.route,
                    binding: .init(
                        scope: .global, purpose: AgentModelPurposeID.memoryExtraction,
                        routeID: fixture.route.id, revision: fixture.route.revision))
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
                let budget = try await store.memoryExtractionBudget(at: TaskWorkflowFixture.now)
                #expect(budget.reservedTokens == reserved)
            }
        }
    }

    @Test func unsentRecoveryRequeuesButDispatchedFailurePauses() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            let source = try await completedSource(in: fixture, text: "I like quiet mornings")
            try await enableCapture(in: fixture)
            try await withExtractionStore(fixture) { store in
                let first = try #require(await enqueue(origin: origin(for: source), source: source, in: fixture))
                let auth = try await fixture.authority.authorization()
                let selection = AgentModelRouteResolution(
                    route: fixture.route,
                    binding: .init(
                        scope: .global, purpose: AgentModelPurposeID.memoryExtraction,
                        routeID: fixture.route.id, revision: fixture.route.revision))
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
            try await enableCapture(in: fixture)
            try await withExtractionStore(fixture) { store in
                let job = try #require(await enqueue(origin: origin(for: source), source: source, in: fixture))
                let auth = try await fixture.authority.authorization()
                let selection = AgentModelRouteResolution(
                    route: fixture.route,
                    binding: .init(
                        scope: .global, purpose: AgentModelPurposeID.memoryExtraction,
                        routeID: fixture.route.id, revision: 1))
                let claim = try #require(
                    try await store.claimMemoryExtraction(
                        job.id, expectedAttemptCount: 0,
                        source: source, selection: selection, authorization: auth, at: TaskWorkflowFixture.now))
                let request = try preparedRequest(claim: claim)
                let reserved = try await store.prepareMemoryExtraction(
                    claim, request: request, source: source,
                    authorization: auth, at: TaskWorkflowFixture.now)
                #expect(reserved > 0)
                #expect(try await store.memoryExtractionBudget(at: TaskWorkflowFixture.now).reservedTokens == reserved)
                try await store.markMemoryExtractionDispatched(
                    claim, source: source, authorization: auth, at: TaskWorkflowFixture.now)
                let output = AgentModelOutput(
                    blocks: [.init(id: "text", content: .text("{\"version\":2,\"items\":[]}"))],
                    continuation: nil, usage: .init(), finishReason: .stop)
                _ = try await store.completeMemoryExtraction(
                    claim, source: source, output: output,
                    authorization: auth, at: TaskWorkflowFixture.now)
                let budget = try await store.memoryExtractionBudget(at: TaskWorkflowFixture.now)
                #expect(budget.reservedTokens == 0)
                #expect(budget.chargedTokens == reserved)
            }
        }
    }

    @Test func dispatchWriteFailureRollsBackWithoutLosingReservation() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            let source = try await completedSource(in: fixture, text: "I prefer a paper notebook")
            try await enableCapture(in: fixture)
            try await withExtractionStore(fixture) { store in
                let job = try #require(await enqueue(origin: origin(for: source), source: source, in: fixture))
                let auth = try await fixture.authority.authorization()
                let selection = AgentModelRouteResolution(
                    route: fixture.route,
                    binding: .init(
                        scope: .global, purpose: AgentModelPurposeID.memoryExtraction,
                        routeID: fixture.route.id, revision: 1))
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
                let budget = try await store.memoryExtractionBudget(at: TaskWorkflowFixture.now)
                #expect(budget.reservedTokens == reserved)
                #expect(
                    try await store.memoryExtractionJobs(
                        sessionID: source.reference.sessionID, state: .running, limit: 8
                    ).count == 1)
            }
        }
    }

    @Test func suppressedSourceIsNotEnqueuedAndPolicyDisablesFutureJobs() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            let source = try await completedSource(in: fixture, text: "I prefer decaf")
            try await enableCapture(in: fixture)
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
            let policy = MemoryCapturePolicy(revision: 3, mode: .manualOnly, dailyTokenLimit: 10_000)
            try await memory.saveMemoryCapturePolicy(
                policy, expectedRevision: 2, authorization: authorization, at: TaskWorkflowFixture.now)
            #expect(try await enqueue(origin: origin(for: source), source: source, in: fixture) == nil)
        }
    }

    @Test func routeBindingRevisionChangeInvalidatesClaimBeforeDispatch() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            let source = try await completedSource(in: fixture, text: "I prefer a standing desk")
            try await enableCapture(in: fixture)
            let job = try #require(await enqueue(origin: origin(for: source), source: source, in: fixture))
            try await withExtractionStore(fixture) { store in
                let auth = try await fixture.authority.authorization()
                let selection = AgentModelRouteResolution(
                    route: fixture.route,
                    binding: .init(
                        scope: .global, purpose: AgentModelPurposeID.memoryExtraction,
                        routeID: fixture.route.id, revision: fixture.route.revision))
                let claim = try #require(
                    try await store.claimMemoryExtraction(
                        job.id, expectedAttemptCount: 0,
                        source: source, selection: selection, authorization: auth, at: TaskWorkflowFixture.now))
                let request = try preparedRequest(claim: claim)
                _ = try await store.prepareMemoryExtraction(
                    claim, request: request, source: source, authorization: auth, at: TaskWorkflowFixture.now)
                let changed = AgentRouteBinding(
                    scope: .global, purpose: AgentModelPurposeID.memoryExtraction,
                    routeID: fixture.route.id, revision: 2)
                try await fixture.settings.saveBinding(changed, expectedRevision: 1, authorization: fixture.authority.authorization())
                await #expect(throws: MiraError.self) {
                    try await store.markMemoryExtractionDispatched(
                        claim, source: source, authorization: auth, at: TaskWorkflowFixture.now)
                }
            }
        }
    }

    @Test func forgettingPurgesExtractionBodiesAndPreservesSettledCost() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { f in
            let source = try await completedSource(in: f, text: "I prefer green tea")
            try await enableCapture(in: f)
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
                    binding: .init(
                        scope: .global, purpose: AgentModelPurposeID.memoryExtraction, routeID: f.route.id, revision: 1)
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
                let output = try inferredOutput(source.text)
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
            try await enableCapture(in: f)
            try await withExtractionStore(f) { store in
                let job = try #require(await enqueue(origin: origin(for: source), source: source, in: f))
                let auth = try await f.authority.authorization()
                let selection = AgentModelRouteResolution(
                    route: f.route,
                    binding: .init(
                        scope: .global, purpose: AgentModelPurposeID.memoryExtraction, routeID: f.route.id, revision: 1)
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
                let output = try inferredOutput(source.text)
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
                    #expect(
                        try await store.memoryExtractionBudget(at: TaskWorkflowFixture.now).reservedTokens == reserved)
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
                            $0.validationReviewReason == "Memory review required: inferred content."
                        })
                    #expect(
                        decisions.allSatisfy { $0.memoryID == completed.memoryIDs[0] && $0.memoryState == .candidate })
                    #expect(try await reopened.memoryExtractionBudget(at: TaskWorkflowFixture.now).chargedTokens == 12)
                    await #expect(throws: MiraError.self) {
                        _ = try await reopened.memoryExtractionDecisionReport(job.id, ordinal: 1, workspaceID: .init())
                    }
                    await #expect(throws: MiraError.self) {
                        _ = try await reopened.memoryExtractionDecisionReport(job.id, ordinal: 2, workspaceID: nil)
                    }
                    try await f.database.write { db in
                        var attempt = try SQLiteMemoryExtractionStore.attempt(claim.attemptID, in: db)
                        attempt.decisions = failCommit ? [] : Array(try #require(attempt.decisions).reversed())
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
            try await enableCapture(in: f)
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

    private func inferredOutput(_ text: String) throws -> AgentModelOutput {
        let item: [String: Any] = [
            "content": text, "quote": text, "kind": "preference", "subject": "user", "sensitivity": "standard",
            "inferred": true, "stable": false, "confidence": "medium", "validFrom": NSNull(), "validUntil": NSNull(),
            "assertion": ["mode": "inferred", "aspectKey": "daily.preference", "changeIntent": "independent"],
        ]
        let bytes = try JSONSerialization.data(
            withJSONObject: ["version": 2, "items": [item, item]], options: [.sortedKeys])
        return .init(
            blocks: [.init(id: "text", content: .text(String(decoding: bytes, as: UTF8.self)))], continuation: nil,
            usage: .init(inputTokens: 10, outputTokens: 2), finishReason: .stop)
    }

    private func enableCapture(in fixture: TaskWorkflowFixture) async throws {
        let auth = try await fixture.authority.authorization()
        try await fixture.memory?.saveMemoryCapturePolicy(
            .init(
                revision: 2, mode: .automaticWithUndo, dailyTokenLimit: 100_000,
                enabledAt: TaskWorkflowFixture.now), expectedRevision: 1, authorization: auth,
            at: TaskWorkflowFixture.now)
        try await fixture.settings.saveBinding(
            .init(
                scope: .global, purpose: AgentModelPurposeID.memoryExtraction,
                routeID: fixture.route.id, revision: 1), expectedRevision: nil, authorization: fixture.authority.authorization())
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
