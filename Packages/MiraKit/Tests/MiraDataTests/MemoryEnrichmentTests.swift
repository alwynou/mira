import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Automatic memory enrichment", .timeLimit(.minutes(1)))
struct MemoryEnrichmentTests {
    @Test(arguments: ["transport.bicycle", "identity.nickname", "__null__"])
    func enrichmentCarriesForwardFactsEvidenceHistoryAndRecall(aspect: String) async throws {
        try await withTaskWorkflow(outputs: Array(repeating: completion(), count: 2), memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let firstAddress = try await fixture.run("My bicycle is red.")
            let firstSource = try await fixture.evidence(firstAddress)
            let originalID = try await createExtractedMemory(
                content: "My bicycle is red.", aspect: "transport.bicycle", source: firstSource,
                fixture: fixture)
            let original = try await store.memoryDetail(originalID, workspaceID: nil).memory

            let updateAddress = try await fixture.run(
                "I call my bicycle Comet.", sessionID: firstAddress.sessionID)
            let updateSource = try await fixture.evidence(updateAddress)
            let claim = try makeClaim(sources: [updateSource], existingMemories: [original], fixture: fixture)
            let aspectKey = aspect == "__null__" ? nil : aspect
            let output = extractionOutput([item(
                content: "My bicycle is red and its nickname is Comet.", inputIndex: 0,
                aspect: aspectKey, changeIntent: "enrichment", replacesIndex: 0)])

            let first = try await commit(output, sources: [updateSource], claim: claim, fixture: fixture)
            let currentID = try #require(first.memoryIDs.first)
            #expect(first.decisions.map(\.disposition) == [.created])
            #expect(first.decisions.first?.replacedMemoryID == originalID)

            // Retrying identical model output reuses the committed memory and source identity.
            let retry = try await commit(output, sources: [updateSource], claim: claim, fixture: fixture)
            #expect(retry.memoryIDs == [currentID])
            #expect(retry.decisions.map(\.disposition) == [.reused])

            let current = try await store.memoryDetail(currentID, workspaceID: nil)
            #expect(current.memory.draft?.content == "My bicycle is red and its nickname is Comet.")
            #expect(current.evidence.count == 2)
            #expect(current.evidence.contains { $0.source == .userMessage(firstSource.reference) })
            #expect(current.evidence.contains { $0.source == .userMessage(updateSource.reference) })

            let old = try await store.memoryDetail(originalID, workspaceID: nil)
            #expect(old.memory.supersededBy == currentID)
            #expect(old.revisions.contains { $0.draft?.content == "My bicycle is red." })
            let history = try await store.memoryManagementPage(.init(section: .history), at: TaskWorkflowFixture.now)
            #expect(history.memories.contains { $0.id == originalID })

            let currentMemories = try await store.memoryManagementPage(
                .init(section: .current), at: TaskWorkflowFixture.now).memories
            #expect(currentMemories.count == 1)
            #expect(currentMemories.first?.id == currentID)
            let recalled = try await store.recallMemories(
                query: "bicycle Comet",
                request: .init(
                    sessionID: updateSource.reference.sessionID,
                    executionID: updateSource.reference.originalExecutionID,
                    workspaceID: nil, userText: "bicycle Comet",
                    authorizationEpoch: updateSource.sessionAuthorizationEpoch, destination: .local),
                limit: 6, at: TaskWorkflowFixture.now)
            #expect(recalled.memories.map(\.id) == [currentID])
        }
    }

    @Test func outputCanEnrichAnEarlierOutputItemByItsRawIndex() async throws {
        try await withTaskWorkflow(outputs: Array(repeating: completion(), count: 2), memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let firstAddress = try await fixture.run("My bicycle is red.")
            let secondAddress = try await fixture.run(
                "I call my bicycle Comet.", sessionID: firstAddress.sessionID)
            let sources = [try await fixture.evidence(firstAddress), try await fixture.evidence(secondAddress)]
            let claim = try makeClaim(sources: sources, fixture: fixture)
            let output = extractionOutput([
                item(content: "My bicycle is red.", inputIndex: 0, aspect: "transport.bicycle"),
                item(content: "My bicycle is red and its nickname is Comet.", inputIndex: 1,
                     aspect: "identity.nickname", changeIntent: "enrichment", replacesProposalIndex: 0),
            ])

            let result = try await commit(output, sources: sources, claim: claim, fixture: fixture)
            #expect(result.decisions.map(\.proposalIndex) == [0, 1])
            let originalID = try #require(result.decisions.first?.memoryID)
            let currentID = try #require(result.decisions.last?.memoryID)
            #expect(originalID != currentID)
            #expect(try await store.memoryDetail(originalID, workspaceID: nil).memory.supersededBy == currentID)
            let current = try await store.memoryDetail(currentID, workspaceID: nil)
            #expect(current.memory.draft?.content == "My bicycle is red and its nickname is Comet.")
            #expect(current.evidence.count == 2)
            #expect(try await store.memoryManagementPage(
                .init(section: .current), at: TaskWorkflowFixture.now).memories.count == 1)
            let retry = try await commit(output, sources: sources, claim: claim, fixture: fixture)
            #expect(retry.memoryIDs == result.memoryIDs)
            #expect(retry.decisions.map(\.disposition) == [.reused, .reused])
            #expect(try await store.memoryManagementPage(.init(section: .current), at: TaskWorkflowFixture.now).memories.map(\.id) == [currentID])
        }
    }

    @Test(arguments: [false, true])
    func inheritedSuppressionAndRelationFailureRollBackEnrichment(suppressSource: Bool) async throws {
        try await withTaskWorkflow(outputs: Array(repeating: completion(), count: 2), memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let address = try await fixture.run("My bicycle is red.")
            let first = try await fixture.evidence(address)
            let oldID = try await createExtractedMemory(content: "My bicycle is red.", aspect: "transport.bicycle", source: first, fixture: fixture)
            let old = try await store.memoryDetail(oldID, workspaceID: nil).memory
            let update = try await fixture.evidence(fixture.run("I call the same bicycle Comet.", sessionID: address.sessionID))
            let claim = try makeClaim(sources: [update], existingMemories: [old], fixture: fixture)
            try await fixture.database.write { db in
                if suppressSource {
                    try SQLiteMemoryStore.suppress(.userMessage(first.reference), strength: 3, in: db)
                } else {
                    try db.execute(sql: "CREATE TRIGGER reject_evolution BEFORE INSERT ON memory_replacements BEGIN SELECT RAISE(ABORT, 'Synthetic relation failure'); END")
                }
            }
            let output = extractionOutput([item(content: "My bicycle is red and its nickname is Comet.", inputIndex: 0,
                aspect: nil, changeIntent: "enrichment", replacesIndex: 0)])
            await #expect(throws: (any Error).self) {
                _ = try await commit(output, sources: [update], claim: claim, fixture: fixture)
            }
            #expect(try await store.memoryDetail(oldID, workspaceID: nil).memory == old)
            try await fixture.database.read { db throws -> Void in
                for table in ["memory_records", "memory_evidence", "memory_sources", "memory_assertions", "memory_extraction_aspects"] {
                    #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") == 1)
                }
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_replacements") == 0)
            }
        }
    }

    @Test func forgettingEnrichedMemorySuppressesBothSourcesWithoutRevivingHistory() async throws {
        try await withTaskWorkflow(outputs: Array(repeating: completion(), count: 2), memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let address = try await fixture.run("My bicycle is red.")
            let first = try await fixture.evidence(address)
            let oldID = try await createExtractedMemory(content: "My bicycle is red.", aspect: "transport.bicycle", source: first, fixture: fixture)
            let old = try await store.memoryDetail(oldID, workspaceID: nil).memory
            let update = try await fixture.evidence(fixture.run("I call the same bicycle Comet.", sessionID: address.sessionID))
            let claim = try makeClaim(sources: [update], existingMemories: [old], fixture: fixture)
            let output = extractionOutput([item(content: "My bicycle is red and its nickname is Comet.", inputIndex: 0,
                aspect: nil, changeIntent: "enrichment", replacesIndex: 0)])
            let result = try await commit(output, sources: [update], claim: claim, fixture: fixture)
            let current = try await store.memoryDetail(#require(result.memoryIDs.first), workspaceID: nil).memory
            let operation = try await fixture.access.begin(.init(id: UUID(), namespace: "memory.forget", revision: 1,
                scope: .sources([.domain(namespace: "memories", id: current.id.rawValue, revision: current.revision)]),
                requestedAt: TaskWorkflowFixture.now), expected: fixture.authority.authorization())
            #expect(await fixture.runtime.shutdown().isSettled)
            await fixture.tasks.close()
            await fixture.reminders.close()
            try await fixture.access.waitForQuiescence()
            let scope = try await store.memoryForgetScope(operation: operation)
            #expect(scope.roots.contains(.sessionExecution(sessionID: first.reference.sessionID, executionID: first.reference.originalExecutionID)))
            #expect(scope.roots.contains(.sessionExecution(sessionID: update.reference.sessionID, executionID: update.reference.originalExecutionID)))
            try await store.purgeMemoryForget(scope, operation: operation)
            try await store.verifyMemoryForgotten(scope, operation: operation)
            // Inspect the domain primitive while maintenance still owns the library.
            // This test does not claim that journal-wide maintenance has completed.
            try await fixture.database.read { db throws -> Void in
                let forgotten = try SQLiteMemoryStore.read(current.id, workspaceID: nil, in: db)
                let predecessor = try SQLiteMemoryStore.read(oldID, workspaceID: nil, in: db)
                #expect(forgotten.draft == nil && forgotten.forgottenAt != nil)
                #expect(!forgotten.isCurrent && !predecessor.isCurrent)
                #expect(try SQLiteMemoryStore.suppressedMemorySource(.userMessage(first.reference), in: db))
                #expect(try SQLiteMemoryStore.suppressedMemorySource(.userMessage(update.reference), in: db))
                // Forgetting is scoped to the selected ID; its predecessor remains superseded history.
                #expect(predecessor.supersededBy == current.id)
            }
            await #expect(throws: MiraError.self) {
                _ = try await commit(output, sources: [update], claim: claim, fixture: fixture)
            }
        }
    }

    @Test func exactDuplicateAcrossInputIndexesReusesOneCurrentMemory() async throws {
        try await withTaskWorkflow(outputs: Array(repeating: completion(), count: 2), memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let firstAddress = try await fixture.run("I ride my bicycle to work.")
            let secondAddress = try await fixture.run(
                "I ride my bicycle to work.", sessionID: firstAddress.sessionID)
            let sources = [try await fixture.evidence(firstAddress), try await fixture.evidence(secondAddress)]
            let claim = try makeClaim(sources: sources, fixture: fixture)
            let output = extractionOutput([
                item(content: "I ride my bicycle to work.", inputIndex: 0, aspect: "transport.bicycle"),
                item(content: "I ride my bicycle to work.", inputIndex: 1, aspect: "transport.bicycle"),
            ])

            let result = try await commit(output, sources: sources, claim: claim, fixture: fixture)
            #expect(result.memoryIDs.count == 1)
            #expect(result.decisions.map(\.disposition) == [.created, .reused])
            #expect(result.decisions[0].memoryID == result.decisions[1].memoryID)
            let detail = try await store.memoryDetail(result.memoryIDs[0], workspaceID: nil)
            #expect(detail.evidence.count == 2)
            #expect(detail.evidence.contains { $0.source == .userMessage(sources[0].reference) })
            #expect(detail.evidence.contains { $0.source == .userMessage(sources[1].reference) })
        }
    }

    @Test func skippedEarlierProposalCannotBecomeAnOrphanEnrichmentTarget() async throws {
        try await withTaskWorkflow(outputs: Array(repeating: completion(), count: 3), memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let firstAddress = try await fixture.run("My bicycle is red.")
            let firstSource = try await fixture.evidence(firstAddress)
            let originalID = try await createExtractedMemory(
                content: "My bicycle is red.", aspect: "transport.bicycle", source: firstSource,
                fixture: fixture)
            let ignoredAddress = try await fixture.run(
                "I commute by bicycle.", sessionID: firstAddress.sessionID)
            let enrichedAddress = try await fixture.run(
                "My bicycle is also called Comet.", sessionID: firstAddress.sessionID)
            let sources = [try await fixture.evidence(ignoredAddress), try await fixture.evidence(enrichedAddress)]
            let claim = try makeClaim(sources: sources, existingMemories: [
                try await store.memoryDetail(originalID, workspaceID: nil).memory,
            ], fixture: fixture)
            let output = extractionOutput([
                // Same aspect, but an independent assertion: the existing memory makes this item ambiguous.
                item(content: "I commute by bicycle.", inputIndex: 0, aspect: "transport.bicycle"),
                item(content: "My bicycle is red and is also called Comet.", inputIndex: 1,
                     aspect: "identity.nickname", changeIntent: "enrichment", replacesProposalIndex: 0),
            ])

            let result = try await commit(output, sources: sources, claim: claim, fixture: fixture)
            #expect(result.memoryIDs.isEmpty)
            #expect(result.decisions.isEmpty)
            let active = try await store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 20).memories
            #expect(active.map(\.id) == [originalID])
        }
    }

    @Test func lowConfidenceIsSkippedAndSimilarIndependentEntityStaysSeparate() async throws {
        try await withTaskWorkflow(outputs: Array(repeating: completion(), count: 3), memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let bicycleAddress = try await fixture.run("My bicycle is red.")
            let bicycleSource = try await fixture.evidence(bicycleAddress)
            let bicycleID = try await createExtractedMemory(
                content: "My bicycle is red.", aspect: "transport.bicycle", source: bicycleSource,
                fixture: fixture)
            let uncertainAddress = try await fixture.run(
                "I sometimes borrow a scooter.", sessionID: bicycleAddress.sessionID)
            let stableAddress = try await fixture.run(
                "I own a blue scooter.", sessionID: bicycleAddress.sessionID)
            let sources = [try await fixture.evidence(uncertainAddress), try await fixture.evidence(stableAddress)]
            let claim = try makeClaim(sources: sources, fixture: fixture)
            let output = extractionOutput([
                item(content: "I sometimes borrow a scooter.", inputIndex: 0,
                     aspect: "transport.scooter", confidence: "low"),
                item(content: "I own a blue scooter.", inputIndex: 1, aspect: "transport.scooter"),
            ])

            let result = try await commit(output, sources: sources, claim: claim, fixture: fixture)
            #expect(result.decisions.map(\.proposalIndex) == [1])
            let active = try await store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 20).memories
            #expect(active.count == 2)
            #expect(active.contains { $0.id == bicycleID && $0.supersededBy == nil })
            #expect(active.contains { $0.draft?.content == "I own a blue scooter." })
            #expect(result.candidateMemoryIDs.isEmpty)
        }
    }

    @Test(arguments: ["scope", "privacy"])
    func incompatibleScopeOrDisclosureCannotBeInherited(mismatch: String) async throws {
        try await withTaskWorkflow(outputs: [completion()], memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let authorization = try await fixture.authority.authorization()
            let workspaceID = mismatch == "scope" ? WorkspaceID() : nil
            if let workspaceID {
                try await fixture.workspaces.saveWorkspace(
                    .init(id: workspaceID, name: "Enrichment fixture"), expectedRevision: nil,
                    authorization: authorization)
            }
            let target = try await store.createMemory(
                draft: .init(content: "My bicycle is red.", scope: .global,
                             kind: .fact, allowsRemoteUse: mismatch != "privacy"),
                source: .manualEntry(id: UUID(), statement: "My bicycle is red."),
                operationID: UUID(), replacing: nil, expectedRevision: nil,
                authorization: authorization, at: TaskWorkflowFixture.now).memory
            let address = try await fixture.run("I call my bicycle Comet.", workspaceID: workspaceID)
            let source = try await fixture.evidence(address)
            let claim = try makeClaim(sources: [source], existingMemories: [target], fixture: fixture)
            let output = extractionOutput([item(
                content: "My bicycle is red and its nickname is Comet.", inputIndex: 0,
                aspect: "identity.nickname", changeIntent: "enrichment", replacesIndex: 0)])

            let result = try await commit(output, sources: [source], claim: claim, fixture: fixture)
            #expect(result.memoryIDs.isEmpty)
            #expect(result.decisions.isEmpty)
            #expect(try await store.memoryDetail(target.id, workspaceID: workspaceID).memory == target)
            #expect(try await store.memoryList(
                workspaceID: workspaceID, states: [.active], query: "", limit: 20).memories.map(\.id) == [target.id])
        }
    }

    @Test func staleTargetRevisionRejectsTheWholeEnrichment() async throws {
        try await withTaskWorkflow(outputs: [completion()], memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let authorization = try await fixture.authority.authorization()
            let target = try await store.createMemory(
                draft: .init(content: "My bicycle is red.", scope: .global),
                source: .manualEntry(id: UUID(), statement: "My bicycle is red."),
                operationID: UUID(), replacing: nil, expectedRevision: nil,
                authorization: authorization, at: TaskWorkflowFixture.now).memory
            let address = try await fixture.run("I call my bicycle Comet.")
            let source = try await fixture.evidence(address)
            let claim = try makeClaim(sources: [source], existingMemories: [target], fixture: fixture)
            _ = try await store.reviseMemory(
                target.id, workspaceID: nil, draft: .init(content: "My bicycle is dark red.", scope: .global),
                expectedRevision: 1, operationID: UUID(), authorization: authorization,
                at: TaskWorkflowFixture.now)
            let output = extractionOutput([item(
                content: "My bicycle is red and its nickname is Comet.", inputIndex: 0,
                aspect: "identity.nickname", changeIntent: "enrichment", replacesIndex: 0)])

            await #expect(throws: MiraError.self) {
                _ = try await commit(output, sources: [source], claim: claim, fixture: fixture)
            }
            let active = try await store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 20).memories
            #expect(active.map(\.id) == [target.id])
            #expect(active.first?.draft?.content == "My bicycle is dark red.")
        }
    }

    @Test func missingOrOutOfBatchEnrichmentTargetIsRejected() async throws {
        try await withTaskWorkflow(outputs: [completion()], memoryEnabled: true) { fixture in
            let store = try #require(fixture.memory)
            let authorization = try await fixture.authority.authorization()
            let target = try await store.createMemory(
                draft: .init(content: "My bicycle is red.", scope: .global),
                source: .manualEntry(id: UUID(), statement: "My bicycle is red."),
                operationID: UUID(), replacing: nil, expectedRevision: nil,
                authorization: authorization, at: TaskWorkflowFixture.now).memory
            let address = try await fixture.run("I call my bicycle Comet.")
            let source = try await fixture.evidence(address)

            let missing = extractionOutput([item(
                content: "My bicycle is red and its nickname is Comet.", inputIndex: 0,
                aspect: "identity.nickname", changeIntent: "enrichment", includeTargetFields: false)])
            #expect(throws: MiraError.self) {
                try MemoryExtractionValidator.validate(output: missing, sources: [source])
            }

            // The JSON shape is valid, but index 1 is outside this claim's one-item existing-memory bound.
            let outsideBatch = extractionOutput([item(
                content: "My bicycle is red and its nickname is Comet.", inputIndex: 0,
                aspect: "identity.nickname", changeIntent: "enrichment", replacesIndex: 1)])
            let claim = try makeClaim(sources: [source], existingMemories: [target], fixture: fixture)
            await #expect(throws: MiraError.self) {
                _ = try await commit(outsideBatch, sources: [source], claim: claim, fixture: fixture)
            }
            #expect(try await store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 20).memories.map(\.id) == [target.id])
        }
    }

    private func createExtractedMemory(
        content: String, aspect: String, source: SessionUserEvidence, fixture: TaskWorkflowFixture
    ) async throws -> MemoryID {
        let claim = try makeClaim(sources: [source], fixture: fixture)
        let output = extractionOutput([item(content: content, inputIndex: 0, aspect: aspect)])
        let result = try await commit(output, sources: [source], claim: claim, fixture: fixture)
        return try #require(result.memoryIDs.first)
    }

    private func makeClaim(
        sources: [SessionUserEvidence], existingMemories: [Memory] = [], fixture: TaskWorkflowFixture
    ) throws -> MemoryExtractionClaim {
        let first = try #require(sources.first)
        let now = TaskWorkflowFixture.now
        let origin = MemoryExtractionOrigin(
            source: first.reference, completedExecutionID: first.reference.originalExecutionID,
            completionEventID: first.reference.admissionEventID, completionHead: first.observedHead)
        let turns = sources.map { source in
            MemoryExtractionTurn(
                source: source.reference, completedExecutionID: source.reference.originalExecutionID,
                completionEventID: source.reference.admissionEventID, completionHead: source.observedHead,
                admittedAt: source.admittedAt, completedAt: now, inputTokenEstimate: 24)
        }
        let job = MemoryExtractionJob(
            id: .init(), origin: origin, workspaceID: first.workspaceID, state: .running,
            attemptCount: 1, createdAt: now, updatedAt: now, turns: turns)
        var claim = MemoryExtractionClaim(
            job: job, source: first, selection: .init(route: fixture.route, binding: nil),
            leaseID: UUID(), leaseExpiresAt: now.addingTimeInterval(300), attemptID: UUID(),
            batchSources: sources)
        claim.existingMemories = existingMemories
        return claim
    }

    private func commit(
        _ output: String, sources: [SessionUserEvidence], claim: MemoryExtractionClaim,
        fixture: TaskWorkflowFixture
    ) async throws -> (memoryIDs: [MemoryID], candidateMemoryIDs: [MemoryID], decisions: [MemoryExtractionDecision]) {
        let proposals = try MemoryExtractionValidator.validate(output: output, sources: sources)
        return try await fixture.database.write { db in
            try SQLiteMemoryStore.commitExtractionBatchProposals(
                proposals, claim: claim, sources: sources, at: TaskWorkflowFixture.now, in: db)
        }
    }

    private func extractionOutput(_ items: [JSONValue]) -> String {
        try! JSONValue.object(["version": .number(3), "items": .array(items)]).jsonString()
    }

    private func item(
        content: String, inputIndex: Int, aspect: String?, changeIntent: String = "independent",
        confidence: String = "high", replacesIndex: Int? = nil, replacesProposalIndex: Int? = nil,
        includeTargetFields: Bool = true
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "content": .string(content), "inputIndex": .number(Double(inputIndex)),
            "kind": .string("fact"), "subject": .string("user"), "sensitivity": .string("standard"),
            "inferred": .bool(false), "stable": .bool(true), "confidence": .string(confidence),
            "validFrom": .null, "validUntil": .null,
            "assertion": .object([
                "mode": .string("directStable"), "aspectKey": aspect.map(JSONValue.string) ?? .null,
                "changeIntent": .string(changeIntent),
            ]),
        ]
        if includeTargetFields {
            fields["replacesIndex"] = replacesIndex.map { .number(Double($0)) } ?? .null
            fields["replacesProposalIndex"] = replacesProposalIndex.map { .number(Double($0)) } ?? .null
        }
        return .object(fields)
    }

    private func completion() -> [AgentModelStreamEvent] {
        [.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]
    }
}
