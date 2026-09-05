import Foundation
import GRDB
import MiraCore
import Testing
@testable import MiraData

@Suite("Atomic memory extraction commit")
struct MemoryExtractionCommitTests {
    @Test(arguments: [1_800_000_000.123456, 1_788_616_032.27312, 1_000.0000001])
    func fractionalActivationAndReviewedMemorySurviveBackup(_ seconds: Double) throws {
        let fixture = try ExtractionCommitFixture(mode: .candidateOnly, at: Date(timeIntervalSince1970: seconds)); defer { fixture.cleanup() }
        let claim = try fixture.dispatch("I prefer compact interfaces")
        let job = try fixture.store.completeMemoryExtraction(claim, output: fixture.output(claim.source.message.text), usage: .init(inputTokens: 11, outputTokens: 7), at: fixture.at)
        let memoryID = try #require(job.memoryIDs.first)
        let reviewed = try fixture.store.changeMemoryState(memoryID, workspaceID: nil, state: .active, expectedRevision: 1, at: fixture.at)
        #expect(reviewed.authority == .explicitUser)
        let backup = fixture.directory.appendingPathComponent("reviewed.sqlite")
        let restoredDirectory = fixture.directory.appendingPathComponent("restored")
        try fixture.store.exportBackup(to: backup)
        try fixture.store.restoreBackup(from: backup, to: restoredDirectory)
        let restored = try SQLiteMiraStore(directory: restoredDirectory)
        #expect(try restored.memoryDetail(memoryID, workspaceID: nil).memory == reviewed)
    }

    @Test func successfulCommitHasEvidenceRevisionCaptureAndSingleSettlement() throws {
        let fixture = try ExtractionCommitFixture(); defer { fixture.cleanup() }
        let claim = try fixture.dispatch("I prefer compact interfaces")
        let output = try fixture.output(claim.source.message.text)
        let job = try fixture.store.completeMemoryExtraction(claim, output: output, usage: .init(inputTokens: 200, outputTokens: 40), at: fixture.at)
        #expect(job.state == .completed)
        let memoryID = try #require(job.memoryIDs.first)
        let detail = try fixture.store.memoryDetail(memoryID, workspaceID: nil)
        #expect(detail.memory.state == .active)
        #expect(detail.memory.authority == .observedUser)
        #expect(detail.evidence.first?.sourceID == claim.source.message.id.rawValue)
        #expect(detail.evidence.first?.excerpt == claim.source.message.text)
        #expect(detail.revisions.first?.actor == "memoryExtraction")
        _ = try fixture.store.completeMemoryExtraction(claim, output: output, usage: .init(inputTokens: 200, outputTokens: 40), at: fixture.at)
        #expect(try fixture.store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 100).memories.count == 1)
        #expect(try fixture.store.memoryExtractionBudget(at: fixture.at).chargedTokens == 240)
        let forgotten = try fixture.store.forgetMemory(memoryID, workspaceID: nil, expectedRevision: 1, at: fixture.at)
        #expect(forgotten.redactedExecutionIDs.contains(claim.source.executionID))
    }

    @Test func malformedJSONSettlesUsageWithoutPartialMemories() throws {
        let fixture = try ExtractionCommitFixture(); defer { fixture.cleanup() }
        let claim = try fixture.dispatch("I prefer compact interfaces")
        #expect(throws: MiraError.self) {
            _ = try fixture.store.completeMemoryExtraction(claim, output: .init(text: "not JSON", toolCalls: [], finishReason: .stop), usage: .init(inputTokens: 123, outputTokens: 9), at: fixture.at)
        }
        #expect(try fixture.store.memoryExtractionBudget(at: fixture.at).chargedTokens == 132)
        #expect(try fixture.store.memoryExtractionBudget(at: fixture.at).reservedTokens == 0)
        #expect(try fixture.store.memoryExtractionJobs(conversationID: nil, limit: 10).first?.state == .failed)
        #expect(try fixture.store.memoryList(workspaceID: nil, states: Set(MemoryState.allCases), query: "", limit: 100).memories.isEmpty)
        try fixture.store.failMemoryExtraction(claim, error: .init(.network, "Synthetic late failure"), at: fixture.at)
        #expect(try fixture.store.memoryExtractionBudget(at: fixture.at).chargedTokens == 132)
    }

    @Test func reportedUsageAboveReservationIsNeverClampedDown() throws {
        let fixture = try ExtractionCommitFixture(); defer { fixture.cleanup() }
        let claim = try fixture.dispatch("I prefer compact interfaces")
        let reserved = try fixture.store.memoryExtractionBudget(at: fixture.at).reservedTokens
        _ = try fixture.store.completeMemoryExtraction(claim, output: fixture.output(claim.source.message.text), usage: .init(inputTokens: reserved + 101, outputTokens: 23), at: fixture.at)
        let budget = try fixture.store.memoryExtractionBudget(at: fixture.at)
        #expect(budget.chargedTokens == reserved + 124)
        #expect(budget.reservedTokens == 0)
        #expect(budget.remainingTokens == 100_000 - reserved - 124)
    }

    @Test func databaseFailureRollsBackEveryMemoryAndDecision() throws {
        let fixture = try ExtractionCommitFixture(); defer { fixture.cleanup() }
        let claim = try fixture.dispatch("I prefer compact interfaces")
        try fixture.store.pool.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_extraction_decision BEFORE INSERT ON memory_extraction_decisions BEGIN SELECT RAISE(ABORT, 'Synthetic decision failure'); END")
        }
        #expect(throws: MiraError.self) {
            _ = try fixture.store.completeMemoryExtraction(claim, output: fixture.output(claim.source.message.text), usage: .init(inputTokens: 10, outputTokens: 10), at: fixture.at)
        }
        #expect(try fixture.store.memoryList(workspaceID: nil, states: Set(MemoryState.allCases), query: "", limit: 100).memories.isEmpty)
        let rows = try fixture.store.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_extraction_decisions") }
        #expect(rows == 0)
        #expect(try fixture.store.memoryExtractionBudget(at: fixture.at).chargedTokens == 0)
        #expect(try fixture.store.memoryExtractionBudget(at: fixture.at).reservedTokens > 0)
    }

    @Test func explicitFactIsNeverAutomaticallyReplaced() throws {
        let fixture = try ExtractionCommitFixture(); defer { fixture.cleanup() }
        let prior = try fixture.store.createMemory(draft: .init(content: "I prefer spacious interfaces", scope: .global, kind: .preference), source: .manualEntry(id: UUID(), statement: "I prefer spacious interfaces"), operationID: UUID(), replacing: nil, expectedRevision: nil, at: fixture.at).memory
        let claim = try fixture.dispatch("I prefer compact interfaces")
        let result = try fixture.store.completeMemoryExtraction(claim, output: fixture.output(claim.source.message.text), usage: .init(), at: fixture.at)
        #expect(result.candidateMemoryIDs.count == 1)
        let unchanged = try fixture.store.memoryDetail(prior.id, workspaceID: nil).memory
        #expect(unchanged == prior)
        let candidate = try fixture.store.memoryDetail(try #require(result.memoryIDs.first), workspaceID: nil)
        #expect(candidate.memory.state == .candidate)
        #expect(candidate.replacements.isEmpty)
    }

    @Test func candidatePolicyAndSensitiveClassificationCannotAutoActivate() throws {
        let fixture = try ExtractionCommitFixture(mode: .candidateOnly); defer { fixture.cleanup() }
        let claim = try fixture.dispatch("I prefer private consultations")
        let result = try fixture.store.completeMemoryExtraction(claim, output: fixture.output(claim.source.message.text, sensitivity: "sensitive"), usage: .init(), at: fixture.at)
        let memory = try fixture.store.memoryDetail(try #require(result.memoryIDs.first), workspaceID: nil).memory
        #expect(memory.state == .candidate)
        #expect(memory.draft?.allowsRemoteUse == false)
        #expect(try fixture.store.recallMemories(query: "private consultations", workspaceID: nil, connectionID: fixture.route.connectionID, limit: 6, at: fixture.at).memories.isEmpty)
    }

    @Test func disablingPolicyRejectsLateCommitAndChargesOnlyOnce() throws {
        let fixture = try ExtractionCommitFixture(); defer { fixture.cleanup() }
        let claim = try fixture.dispatch("I prefer compact interfaces")
        let reserved = try fixture.store.memoryExtractionBudget(at: fixture.at).reservedTokens
        try fixture.store.saveMemoryCapturePolicy(.init(revision: 3, mode: .manualOnly, dailyTokenLimit: 100_000), expectedRevision: 2, at: fixture.at)
        #expect(throws: MiraError.self) {
            _ = try fixture.store.completeMemoryExtraction(claim, output: fixture.output(claim.source.message.text), usage: .init(inputTokens: 10, outputTokens: 10), at: fixture.at)
        }
        try fixture.store.failMemoryExtraction(claim, error: .init(.cancelled, "Synthetic cancellation"), at: fixture.at)
        #expect(try fixture.store.memoryExtractionBudget(at: fixture.at).chargedTokens == reserved)
        #expect(try fixture.store.memoryList(workspaceID: nil, states: Set(MemoryState.allCases), query: "", limit: 100).memories.isEmpty)
    }

    @Test func rejectingFirstCaptureSuppressesLaterJobsForTheSameSource() throws {
        let fixture = try ExtractionCommitFixture(mode: .candidateOnly); defer { fixture.cleanup() }
        let claim = try fixture.dispatch("I prefer compact interfaces")
        let result = try fixture.store.completeMemoryExtraction(claim, output: fixture.output(claim.source.message.text), usage: .init(), at: fixture.at)
        let memoryID = try #require(result.memoryIDs.first)
        _ = try fixture.store.changeMemoryState(memoryID, workspaceID: nil, state: .rejected, expectedRevision: 1, at: fixture.at)
        #expect(throws: MiraError.self) { _ = try fixture.store.retryMemoryExtraction(result.id, at: fixture.at) }
        #expect(try fixture.store.claimMemoryExtraction(at: fixture.at) == nil)
    }
}

private struct ExtractionCommitFixture {
    let directory: URL
    let store: SQLiteMiraStore
    let route: ResolvedModelRouteSnapshot
    let conversationID: ConversationID
    let at: Date
    init(mode: MemoryCaptureMode = .automaticWithUndo, at: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws {
        self.at = at
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-extraction-commit-\(UUID())")
        store = try SQLiteMiraStore(directory: directory)
        let connection = ProviderConnection(name: "Synthetic", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", credentialReference: "synthetic")
        let model = ModelDescriptor(connectionID: connection.id, modelID: "synthetic", contextWindow: 32_768, textCapability: .declared)
        let preset = ModelRoute(name: "Synthetic", modelDescriptorID: model.id, maxOutputTokens: 2048)
        try store.saveConnection(connection, expectedRevision: nil)
        try store.saveModel(model, expectedRevision: nil)
        try store.saveRoute(preset, expectedRevision: nil)
        try store.saveRouteBinding(.init(scope: .global, purpose: .conversation, routeID: preset.id), expectedRevision: nil)
        try store.saveRouteBinding(.init(scope: .global, purpose: .memoryExtraction, routeID: preset.id), expectedRevision: nil)
        route = try store.modelConfiguration().resolve(purpose: .conversation)
        conversationID = .init()
        try store.createConversation(.init(id: conversationID, workspaceID: nil, title: "Synthetic", createdAt: at, updatedAt: at))
        try store.saveMemoryCapturePolicy(.init(revision: 2, mode: mode, dailyTokenLimit: 100_000, enabledAt: at), expectedRevision: 1, at: at)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func dispatch(_ text: String) throws -> MemoryExtractionClaim {
        let execution = try store.enqueue(conversationID: conversationID, text: text, route: route, executionID: .init(), messageID: .init(), at: at)
        _ = try store.finish(executionID: execution.id, status: .completed, text: "Synthetic response", usage: .init(), error: nil, assistantMessageID: .init(), at: at)
        let claim = try #require(try store.claimMemoryExtraction(at: at))
        _ = try store.prepareMemoryExtraction(claim, request: MemoryExtractionRequestBuilder.request(for: claim), at: at)
        try store.markMemoryExtractionDispatched(claim, at: at)
        return claim
    }
    func output(_ text: String, sensitivity: String = "standard") throws -> ModelOutput {
        let body: [String: Any] = ["version": 1, "items": [["content": text, "quote": text, "kind": "preference", "subject": "user", "sensitivity": sensitivity, "inferred": false, "stable": true, "confidence": "high", "validFrom": NSNull(), "validUntil": NSNull()]]]
        return .init(text: String(decoding: try JSONSerialization.data(withJSONObject: body, options: .sortedKeys), as: UTF8.self), toolCalls: [], finishReason: .stop)
    }
}
