import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Journal memory extraction commit", .timeLimit(.minutes(1)))
struct JournalMemoryExtractionCommitTests {
    @Test func sameJournalSourceRetryIsIdempotent() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            try await enableAutomaticCapture(store, fixture: fixture)
            let address = try await fixture.run("I prefer green tea")
            let source = try await fixture.evidence(address)
            let claim = try makeClaim(source: source, route: fixture.route)
            let proposal = proposal(content: source.text, quote: source.text, aspect: "drink.preference")
            let first = try await commit([proposal], claim: claim, source: source, fixture: fixture)
            let second = try await commit([proposal], claim: claim, source: source, fixture: fixture)
            #expect(first.memoryIDs.count == 1)
            #expect(second.memoryIDs == first.memoryIDs)
            #expect(second.candidateMemoryIDs.isEmpty)
            #expect(first.decisions.map(\.disposition) == [.created])
            #expect(second.decisions.map(\.disposition) == [.reused])
            #expect(try await store.memoryDetail(first.memoryIDs[0], workspaceID: nil).evidence.count == 1)
        }
    }

    @Test func sameAspectWithoutExplicitReplacementCreatesCandidate() async throws {
        try await withTaskWorkflow(
            outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)], [.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]],
            memoryEnabled: true
        ) { fixture in
            let store = try #require(fixture.memory)
            try await enableAutomaticCapture(store, fixture: fixture)
            let firstAddress = try await fixture.run("I prefer green tea")
            let firstSource = try await fixture.evidence(firstAddress)
            let firstClaim = try makeClaim(source: firstSource, route: fixture.route)
            _ = try await commit(
                [proposal(content: firstSource.text, quote: firstSource.text, aspect: "drink.preference")],
                claim: firstClaim, source: firstSource, fixture: fixture)

            let secondAddress = try await fixture.run("I prefer black tea")
            let secondSource = try await fixture.evidence(secondAddress)
            let secondClaim = try makeClaim(source: secondSource, route: fixture.route)
            let result = try await commit(
                [proposal(content: secondSource.text, quote: secondSource.text, aspect: "drink.preference")],
                claim: secondClaim, source: secondSource, fixture: fixture)
            #expect(result.memoryIDs.count == 1)
            #expect(result.candidateMemoryIDs == result.memoryIDs)
            let detail = try await store.memoryDetail(result.memoryIDs[0], workspaceID: nil)
            #expect(detail.memory.state == .candidate)
        }
    }

    @Test func explicitReplacementRequiresCurrentAspectRevision() async throws {
        try await withTaskWorkflow(
            outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)], [.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]],
            memoryEnabled: true
        ) { fixture in
            let store = try #require(fixture.memory)
            try await enableAutomaticCapture(store, fixture: fixture)
            let firstAddress = try await fixture.run("I prefer green tea")
            let firstSource = try await fixture.evidence(firstAddress)
            let firstClaim = try makeClaim(source: firstSource, route: fixture.route)
            let first = try await commit(
                [proposal(content: firstSource.text, quote: firstSource.text, aspect: "drink.preference")],
                claim: firstClaim, source: firstSource, fixture: fixture)

            let secondAddress = try await fixture.run("I now prefer black tea instead of green tea")
            let secondSource = try await fixture.evidence(secondAddress)
            let secondClaim = try makeClaim(source: secondSource, route: fixture.route)
            let result = try await commit(
                [
                    proposal(
                        content: secondSource.text, quote: secondSource.text, aspect: "drink.preference",
                        changeIntent: .explicitReplacement)
                ], claim: secondClaim, source: secondSource, fixture: fixture)
            #expect(result.candidateMemoryIDs.isEmpty)
            let replacement = try #require(result.memoryIDs.first)
            #expect(try await store.memoryDetail(replacement, workspaceID: nil).memory.state == .active)
            #expect(
                try await store.memoryDetail(first.memoryIDs[0], workspaceID: nil).memory.supersededBy == replacement)
        }
    }

    @Test func staleAspectRevisionPreventsAutomaticReplacement() async throws {
        try await withTaskWorkflow(
            outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)], [.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]],
            memoryEnabled: true
        ) { fixture in
            let store = try #require(fixture.memory)
            try await enableAutomaticCapture(store, fixture: fixture)
            let firstAddress = try await fixture.run("I prefer green tea")
            let firstSource = try await fixture.evidence(firstAddress)
            let firstClaim = try makeClaim(source: firstSource, route: fixture.route)
            let first = try await commit(
                [proposal(content: firstSource.text, quote: firstSource.text, aspect: "drink.preference")],
                claim: firstClaim, source: firstSource, fixture: fixture)
            let authorization = try await fixture.authority.authorization()
            _ = try await store.reviseMemory(
                first.memoryIDs[0], workspaceID: nil,
                draft: .init(
                    content: firstSource.text, scope: .global, subject: .user, kind: .preference,
                    sensitivity: .standard, allowsRemoteUse: true),
                expectedRevision: 1, operationID: UUID(), authorization: authorization, at: TaskWorkflowFixture.now)

            let secondAddress = try await fixture.run("I now prefer black tea instead of green tea")
            let secondSource = try await fixture.evidence(secondAddress)
            let secondClaim = try makeClaim(source: secondSource, route: fixture.route)
            let result = try await commit(
                [
                    proposal(
                        content: secondSource.text, quote: secondSource.text, aspect: "drink.preference",
                        changeIntent: .explicitReplacement)
                ], claim: secondClaim, source: secondSource, fixture: fixture)
            #expect(result.candidateMemoryIDs.count == 1)
            #expect(try await store.memoryDetail(result.memoryIDs[0], workspaceID: nil).memory.state == .candidate)
        }
    }

    @Test func indexedAspectMetadataMismatchIsStorageCorruption() async throws {
        try await withTaskWorkflow(
            outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)], [.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]],
            memoryEnabled: true
        ) { fixture in
            let store = try #require(fixture.memory)
            try await enableAutomaticCapture(store, fixture: fixture)
            let firstAddress = try await fixture.run("I prefer green tea")
            let firstSource = try await fixture.evidence(firstAddress)
            let firstClaim = try makeClaim(source: firstSource, route: fixture.route)
            _ = try await commit(
                [proposal(content: firstSource.text, quote: firstSource.text, aspect: "drink.preference")],
                claim: firstClaim, source: firstSource, fixture: fixture)
            let forged = try SQLiteMemoryStore.encode(
                MemoryAssertionMetadata(mode: .directStable, aspectKey: "other.aspect", changeIntent: .independent))
            try await fixture.database.write { db in
                try db.execute(sql: "UPDATE memory_extraction_aspects SET metadata_json = ?", arguments: [forged])
            }

            let secondAddress = try await fixture.run("I prefer black tea")
            let secondSource = try await fixture.evidence(secondAddress)
            let secondClaim = try makeClaim(source: secondSource, route: fixture.route)
            await #expect(throws: MiraError.self) {
                _ = try await commit(
                    [proposal(content: secondSource.text, quote: secondSource.text, aspect: "drink.preference")],
                    claim: secondClaim, source: secondSource, fixture: fixture)
            }
        }
    }

    @Test func newerObservedJournalHeadRemainsValidEvidence() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            try await enableAutomaticCapture(store, fixture: fixture)
            let address = try await fixture.run("I prefer green tea")
            let source = try await fixture.evidence(address)
            let claim = try makeClaim(source: source, route: fixture.route)
            let advanced = SessionUserEvidence(
                reference: source.reference, workspaceID: source.workspaceID,
                admittedAt: source.admittedAt, timeZoneIdentifier: source.timeZoneIdentifier, text: source.text,
                observedHead: .init(
                    cursor: .init(
                        sessionID: source.observedHead.cursor.sessionID,
                        sequence: source.observedHead.cursor.sequence + 1), batchID: UUID()),
                sessionAuthorizationEpoch: source.sessionAuthorizationEpoch)
            let result = try await commit(
                [proposal(content: source.text, quote: source.text, aspect: "drink.preference")], claim: claim,
                source: advanced, fixture: fixture)
            #expect(result.memoryIDs.count == 1)
        }
    }

    @Test func suppressedSourceCannotCommitAnotherProposal() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            try await enableAutomaticCapture(store, fixture: fixture)
            let address = try await fixture.run("I prefer green tea")
            let source = try await fixture.evidence(address)
            let claim = try makeClaim(source: source, route: fixture.route)
            try await fixture.database.write { db in
                let draft = proposal(content: source.text, quote: source.text, aspect: "drink.preference").draft
                let resolved = try SQLiteMemoryStore.resolve(
                    .userMessage(evidence: source, excerpt: source.text), draft: draft, in: db)
                try SQLiteMemoryStore.bindSource(resolved, in: db)
                try SQLiteMemoryStore.suppress(.userMessage(source.reference), strength: 1, in: db)
            }
            await #expect(throws: MiraError.self) {
                _ = try await commit(
                    [proposal(content: source.text, quote: source.text, aspect: "drink.preference")], claim: claim,
                    source: source, fixture: fixture)
            }
        }
    }

    @Test(arguments: [false, true])
    func competingTargetsRequireAnExplicitCurrentSelection(advanceSelected: Bool) async throws {
        try await withTaskWorkflow(
            outputs: Array(repeating: [.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)], count: 3),
            memoryEnabled: true
        ) { fixture in
            let store = try #require(fixture.memory)
            let auth = try await fixture.authority.authorization()
            let now = TaskWorkflowFixture.now
            try await enableAutomaticCapture(store, fixture: fixture)
            var originals: [Memory] = []
            for text in ["I prefer green tea", "I prefer black tea"] {
                let address = try await fixture.run(text)
                let source = try await fixture.evidence(address)
                let result = try await commit(
                    [proposal(content: text, quote: text, aspect: "drink.preference")],
                    claim: makeClaim(source: source, route: fixture.route), source: source, fixture: fixture)
                let id = try #require(result.memoryIDs.first)
                originals.append(
                    try await store.changeMemoryState(
                        id, workspaceID: nil, state: .archived,
                        expectedRevision: 1, operationID: UUID(), authorization: auth, at: now))
            }
            // Archiving and restoring are legitimate user operations that can expose competing current facts.
            for i in originals.indices {
                originals[i] = try await store.changeMemoryState(
                    originals[i].id, workspaceID: nil, state: .active,
                    expectedRevision: originals[i].revision, operationID: UUID(), authorization: auth, at: now)
            }
            let address = try await fixture.run("I now prefer white tea instead")
            let source = try await fixture.evidence(address)
            let result = try await commit(
                [
                    proposal(
                        content: source.text, quote: source.text, aspect: "drink.preference",
                        changeIntent: .explicitReplacement)
                ], claim: makeClaim(source: source, route: fixture.route), source: source, fixture: fixture)
            let candidateID = try #require(result.candidateMemoryIDs.first)
            let decision = try #require(result.decisions.first)
            #expect(decision.conflictReason == .multipleCurrentMemories)
            #expect(Set(decision.conflictingMemoryIDs) == Set(originals.map(\.id)))
            let detail = try await store.memoryDetail(candidateID, workspaceID: nil)
            #expect(detail.replacements.count == 2)
            #expect(detail.replacements.allSatisfy { $0.state == .proposed })
            await #expect(throws: MiraError.self) {
                _ = try await store.changeMemoryState(
                    candidateID, workspaceID: nil, state: .active,
                    expectedRevision: 1, operationID: UUID(), authorization: auth, at: now)
            }
            // Deliberately choose the last proposal to catch implementations that read only the first row.
            var selected = try await store.memoryDetail(
                try #require(detail.replacements.last).previousID,
                workspaceID: nil
            ).memory
            let untouched = try #require(originals.first { $0.id != selected.id })
            let unrelated = try await store.createMemory(
                draft: .init(content: "I prefer water", scope: .global, kind: .preference),
                source: .manualEntry(id: UUID(), statement: "I prefer water"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: auth, at: now
            ).memory
            await #expect(throws: MiraError.self) {
                _ = try await store.confirmMemoryReplacement(
                    candidateID, workspaceID: nil,
                    replacingCurrent: unrelated.id, expectedCandidateRevision: 1,
                    expectedCurrentRevision: unrelated.revision,
                    operationID: UUID(), authorization: auth, at: now)
            }
            if advanceSelected {
                var draft = try #require(selected.draft)
                draft.content = "I prefer jasmine tea"
                selected = try await store.createMemory(
                    draft: draft,
                    source: .manualEntry(id: UUID(), statement: draft.content), operationID: UUID(),
                    replacing: selected.id, expectedRevision: selected.revision, authorization: auth, at: now
                ).memory
            }
            let target = selected
            await #expect(throws: MiraError.self) {
                _ = try await store.confirmMemoryReplacement(
                    candidateID, workspaceID: nil,
                    replacingCurrent: target.id, expectedCandidateRevision: 2, expectedCurrentRevision: target.revision,
                    operationID: UUID(), authorization: auth, at: now)
            }
            if advanceSelected {
                try await fixture.database.write { db in
                    try db.execute(
                        sql:
                            "CREATE TRIGGER memory_confirmation_failure BEFORE INSERT ON memory_operations BEGIN SELECT RAISE(ABORT, 'synthetic'); END"
                    )
                }
                await #expect(throws: MiraError.self) {
                    _ = try await store.confirmMemoryReplacement(
                        candidateID, workspaceID: nil,
                        replacingCurrent: target.id, expectedCandidateRevision: 1,
                        expectedCurrentRevision: target.revision,
                        operationID: UUID(), authorization: auth, at: now)
                }
                #expect(
                    try await store.memoryDetail(candidateID, workspaceID: nil).replacements.allSatisfy {
                        $0.state == .proposed
                    })
                #expect(try await store.memoryDetail(target.id, workspaceID: nil).memory == target)
                try await fixture.database.write { db in try db.execute(sql: "DROP TRIGGER memory_confirmation_failure")
                }
            }
            let operation = UUID()
            let confirmed = try await store.confirmMemoryReplacement(
                candidateID, workspaceID: nil,
                replacingCurrent: target.id, expectedCandidateRevision: 1, expectedCurrentRevision: target.revision,
                operationID: operation, authorization: auth, at: now)
            let replay = try await store.confirmMemoryReplacement(
                candidateID, workspaceID: nil,
                replacingCurrent: target.id, expectedCandidateRevision: 1, expectedCurrentRevision: target.revision,
                operationID: operation, authorization: auth, at: now)
            #expect(replay == confirmed)
            #expect(confirmed.isCurrent)
            let reviewed = try await store.memoryDetail(candidateID, workspaceID: nil)
            #expect(!reviewed.replacements.contains { $0.state == .proposed })
            #expect(reviewed.replacements.filter { $0.state == .confirmed }.map(\.previousID) == [target.id])
            #expect(try await store.memoryDetail(target.id, workspaceID: nil).memory.supersededBy == candidateID)
            #expect(try await store.memoryDetail(untouched.id, workspaceID: nil).memory == untouched)
            #expect(try await store.memoryDetail(unrelated.id, workspaceID: nil).memory == unrelated)
        }
    }

    private func enableAutomaticCapture(_ store: SQLiteMemoryStore, fixture: TaskWorkflowFixture) async throws {
        let authorization = try await fixture.authority.authorization()
        try await store.saveMemoryCapturePolicy(
            .init(
                revision: 2, mode: .automaticWithUndo,
                dailyTokenLimit: 100_000, enabledAt: TaskWorkflowFixture.now), expectedRevision: 1,
            authorization: authorization, at: TaskWorkflowFixture.now)
    }

    private func makeClaim(source: SessionUserEvidence, route: AgentModelRoute) throws -> MemoryExtractionClaim {
        let now = TaskWorkflowFixture.now
        let binding = AgentRouteBinding(
            scope: .global, purpose: AgentModelPurposeID.memoryExtraction, routeID: route.id, revision: 1)
        let selection = AgentModelRouteResolution(route: route, binding: binding)
        let origin = MemoryExtractionOrigin(
            source: source.reference, completedExecutionID: source.reference.originalExecutionID,
            completionEventID: source.reference.admissionEventID, completionHead: source.observedHead)
        let job = MemoryExtractionJob(
            id: .init(), origin: origin, workspaceID: source.workspaceID,
            policyRevision: 2, state: .running, attemptCount: 1, createdAt: now, updatedAt: now)
        let policy = MemoryCapturePolicy(
            revision: 2, mode: .automaticWithUndo, dailyTokenLimit: 100_000, enabledAt: now)
        return .init(
            job: job, source: source, policy: policy, selection: selection, leaseID: UUID(),
            leaseExpiresAt: now.addingTimeInterval(300), attemptID: UUID())
    }

    private func commit(
        _ proposals: [MemoryExtractionProposal], claim: MemoryExtractionClaim,
        source: SessionUserEvidence, fixture: TaskWorkflowFixture
    ) async throws -> (memoryIDs: [MemoryID], candidateMemoryIDs: [MemoryID], decisions: [MemoryExtractionDecision]) {
        try await fixture.database.write { db in
            try SQLiteMemoryStore.commitExtractionProposals(
                proposals, claim: claim, source: source,
                at: TaskWorkflowFixture.now, in: db)
        }
    }

    private func proposal(
        content: String, quote: String, aspect: String,
        changeIntent: MemoryChangeIntent = .independent
    ) -> MemoryExtractionProposal {
        .init(
            draft: .init(
                content: content, scope: .global, subject: .user, kind: .preference,
                sensitivity: .standard, allowsRemoteUse: true), quote: quote,
            origin: .observedUserStatement, authority: .observedUser, triage: .active,
            assertion: .init(mode: .directStable, aspectKey: aspect, changeIntent: changeIntent))
    }
}
