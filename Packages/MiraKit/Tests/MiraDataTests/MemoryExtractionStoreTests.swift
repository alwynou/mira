import Foundation
import MiraCore
import Testing
@testable import MiraData

@Suite("SQLite memory extraction store")
struct MemoryExtractionStoreTests {
    @Test func completedReplyDoesNotQueueWhileCaptureIsManualOnly() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let route = try installFixture(in: store)
        try store.saveRouteBinding(.init(scope: .global, purpose: .memoryExtraction, routeID: route.id), expectedRevision: nil)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let at = Date(timeIntervalSince1970: 50)
        let execution = try store.enqueue(conversationID: conversation.id, text: "Manual capture stays off", route: route, executionID: .init(), messageID: .init(), at: at)
        _ = try store.finish(executionID: execution.id, status: .completed, text: "Done", usage: .init(), error: nil, assistantMessageID: .init(), at: at)
        #expect(try store.memoryExtractionJobs(conversationID: conversation.id, limit: 20).isEmpty)
    }

    @Test func capturePolicyStartsManualOnlyAndUsesCAS() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let initial = try store.memoryCapturePolicy()
        #expect(initial.revision == 1)
        #expect(initial.mode == .manualOnly)
        #expect(initial.dailyTokenLimit == 10_000)
        let enabled = MemoryCapturePolicy(revision: 2, mode: .candidateOnly, dailyTokenLimit: 4_000, enabledAt: Date(timeIntervalSince1970: 10))
        try store.saveMemoryCapturePolicy(enabled, expectedRevision: 1, at: Date(timeIntervalSince1970: 10))
        #expect(try store.memoryCapturePolicy() == enabled)
        #expect(throws: MiraError.self) { try store.saveMemoryCapturePolicy(MemoryCapturePolicy(revision: 2, mode: .automaticWithUndo, dailyTokenLimit: 4_000, enabledAt: .now), expectedRevision: 1, at: .now) }
    }

    @Test func completedForegroundReplyQueuesOnlyAfterActivation() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let route = try installFixture(in: store)
        let workspace = Workspace(id: .init(), name: "Extraction")
        try store.saveWorkspace(workspace, expectedRevision: nil)
        let conversation = Conversation(id: .init(), workspaceID: workspace.id, title: "", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let at = Date(timeIntervalSince1970: 100)
        try store.saveMemoryCapturePolicy(.init(revision: 2, mode: .candidateOnly, dailyTokenLimit: 10_000, enabledAt: at), expectedRevision: 1, at: at)
        let execution = try store.enqueue(conversationID: conversation.id, text: "I prefer tea", route: route, executionID: .init(), messageID: .init(), at: at)
        let finished = try store.finish(executionID: execution.id, status: .completed, text: "Done", usage: .init(), error: nil, assistantMessageID: .init(), at: at)
        #expect(finished)
        let jobs = try store.memoryExtractionJobs(conversationID: conversation.id, limit: 20)
        #expect(jobs.count == 1)
        #expect(jobs[0].state == .queued)
    }

    @Test func preactivationSourceIsNeverBackfilledWhenItFinishesAfterOptIn() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let route = try installFixture(in: store)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let beforeActivation = Date(timeIntervalSince1970: 100)
        let execution = try store.enqueue(conversationID: conversation.id, text: "Created before opt in", route: route, executionID: .init(), messageID: .init(), at: beforeActivation)
        let activation = Date(timeIntervalSince1970: 200)
        try store.saveMemoryCapturePolicy(.init(revision: 2, mode: .candidateOnly, dailyTokenLimit: 10_000, enabledAt: activation), expectedRevision: 1, at: activation)
        _ = try store.finish(executionID: execution.id, status: .completed, text: "Finished later", usage: .init(), error: nil, assistantMessageID: .init(), at: activation.addingTimeInterval(1))
        #expect(try store.memoryExtractionJobs(conversationID: conversation.id, limit: 20).isEmpty)
    }

    @Test func claimPreparesDispatchesAndFailsWithLease() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let route = try installFixture(in: store)
        try store.saveRouteBinding(.init(scope: .global, purpose: .memoryExtraction, routeID: route.id), expectedRevision: nil)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let at = Date(timeIntervalSince1970: 200)
        try store.saveMemoryCapturePolicy(.init(revision: 2, mode: .candidateOnly, dailyTokenLimit: 10_000, enabledAt: at), expectedRevision: 1, at: at)
        let execution = try store.enqueue(conversationID: conversation.id, text: "I prefer tea", route: route, executionID: .init(), messageID: .init(), at: at)
        _ = try store.finish(executionID: execution.id, status: .completed, text: "Done", usage: .init(), error: nil, assistantMessageID: .init(), at: at)
        guard let claim = try store.claimMemoryExtraction(at: at) else { Issue.record("Expected a memory extraction claim"); return }
        let request = try MemoryExtractionRequestBuilder.request(for: claim)
        #expect(try store.prepareMemoryExtraction(claim, request: request, at: at) > 0)
        try store.markMemoryExtractionDispatched(claim, at: at)
        try store.failMemoryExtraction(claim, error: MiraError(.network, "synthetic failure"), at: at)
        #expect(try store.memoryExtractionJobs(conversationID: conversation.id, limit: 20).first?.state == .paused)
    }

    @Test func foregroundActivityBlocksBackgroundClaim() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let route = try installFixture(in: store)
        try store.saveRouteBinding(.init(scope: .global, purpose: .memoryExtraction, routeID: route.id), expectedRevision: nil)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let at = Date(timeIntervalSince1970: 300)
        try store.saveMemoryCapturePolicy(.init(revision: 2, mode: .candidateOnly, dailyTokenLimit: 10_000, enabledAt: at), expectedRevision: 1, at: at)
        _ = try store.enqueue(conversationID: conversation.id, text: "I prefer tea", route: route, executionID: .init(), messageID: .init(), at: at)
        #expect(try store.claimMemoryExtraction(at: at) == nil)
    }

    @Test func missingDedicatedRoutePausesThatJobAndClaimsLaterValidJob() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let route = try installFixture(in: store, bindConversation: false)
        let missing = Conversation(id: .init(), workspaceID: nil, title: "", createdAt: .now, updatedAt: .now)
        let valid = Conversation(id: .init(), workspaceID: nil, title: "", createdAt: .now, updatedAt: .now)
        try store.createConversation(missing)
        try store.createConversation(valid)
        try store.saveRouteBinding(.init(scope: .conversation(valid.id), purpose: .memoryExtraction, routeID: route.id), expectedRevision: nil)
        let at = Date(timeIntervalSince1970: 600)
        try store.saveMemoryCapturePolicy(.init(revision: 2, mode: .candidateOnly, dailyTokenLimit: 10_000, enabledAt: at), expectedRevision: 1, at: at)
        let firstExecution = try store.enqueue(conversationID: missing.id, text: "No extraction binding", route: route, executionID: .init(), messageID: .init(), at: at)
        _ = try store.finish(executionID: firstExecution.id, status: .completed, text: "First", usage: .init(), error: nil, assistantMessageID: .init(), at: at)
        let secondExecution = try store.enqueue(conversationID: valid.id, text: "Has extraction binding", route: route, executionID: .init(), messageID: .init(), at: at.addingTimeInterval(1))
        _ = try store.finish(executionID: secondExecution.id, status: .completed, text: "Second", usage: .init(), error: nil, assistantMessageID: .init(), at: at.addingTimeInterval(1))

        let claim = try store.claimMemoryExtraction(at: at.addingTimeInterval(2))
        #expect(claim?.job.conversationID == valid.id)
        let jobs = try store.memoryExtractionJobs(conversationID: missing.id, limit: 20)
        #expect(jobs.first?.state == .paused)
        #expect(jobs.first?.error != nil)
    }

    @Test func workspacePolicyRejectsExtractionClaim() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let route = try installFixture(in: store, bindConversation: false)
        let workspace = Workspace(id: .init(), name: "Blocked", allowsRemoteSend: false)
        try store.saveWorkspace(workspace, expectedRevision: nil)
        let conversation = Conversation(id: .init(), workspaceID: workspace.id, title: "", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        try store.saveRouteBinding(.init(scope: .workspace(workspace.id), purpose: .memoryExtraction, routeID: route.id), expectedRevision: nil)
        let at = Date(timeIntervalSince1970: 700)
        try store.saveMemoryCapturePolicy(.init(revision: 2, mode: .candidateOnly, dailyTokenLimit: 10_000, enabledAt: at), expectedRevision: 1, at: at)
        let execution = try store.enqueue(conversationID: conversation.id, text: "Workspace blocks remote", route: route, executionID: .init(), messageID: .init(), at: at)
        _ = try store.finish(executionID: execution.id, status: .completed, text: "Done", usage: .init(), error: nil, assistantMessageID: .init(), at: at)
        #expect(try store.claimMemoryExtraction(at: at.addingTimeInterval(1)) == nil)
        #expect(try store.memoryExtractionJobs(conversationID: conversation.id, limit: 20).first?.state == .paused)
    }

    @Test func workspaceConnectionAllowlistRejectsMismatchedRoute() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let route = try installFixture(in: store, bindConversation: false)
        let workspace = Workspace(id: .init(), name: "Allowlist", allowedConnectionIDs: [])
        try store.saveWorkspace(workspace, expectedRevision: nil)
        let conversation = Conversation(id: .init(), workspaceID: workspace.id, title: "", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        try store.saveRouteBinding(.init(scope: .workspace(workspace.id), purpose: .memoryExtraction, routeID: route.id), expectedRevision: nil)
        let at = Date(timeIntervalSince1970: 800)
        try store.saveMemoryCapturePolicy(.init(revision: 2, mode: .candidateOnly, dailyTokenLimit: 10_000, enabledAt: at), expectedRevision: 1, at: at)
        let execution = try store.enqueue(conversationID: conversation.id, text: "Connection is not allowed", route: route, executionID: .init(), messageID: .init(), at: at)
        _ = try store.finish(executionID: execution.id, status: .completed, text: "Done", usage: .init(), error: nil, assistantMessageID: .init(), at: at)
        #expect(try store.claimMemoryExtraction(at: at.addingTimeInterval(1)) == nil)
        #expect(try store.memoryExtractionJobs(conversationID: conversation.id, limit: 20).first?.state == .paused)
    }

    @Test func startupRecoveryRequeuesUnsentClaimImmediately() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let route = try installFixture(in: store)
        try store.saveRouteBinding(.init(scope: .global, purpose: .memoryExtraction, routeID: route.id), expectedRevision: nil)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let at = Date(timeIntervalSince1970: 400)
        try store.saveMemoryCapturePolicy(.init(revision: 2, mode: .candidateOnly, dailyTokenLimit: 10_000, enabledAt: at), expectedRevision: 1, at: at)
        let execution = try store.enqueue(conversationID: conversation.id, text: "I prefer tea", route: route, executionID: .init(), messageID: .init(), at: at)
        _ = try store.finish(executionID: execution.id, status: .completed, text: "Done", usage: .init(), error: nil, assistantMessageID: .init(), at: at)
        let first = try store.claimMemoryExtraction(at: at)
        #expect(first != nil)
        try store.recoverMemoryExtraction(at: at.addingTimeInterval(1))
        #expect(try store.memoryExtractionJobs(conversationID: conversation.id, limit: 20).first?.state == .queued)
        guard let second = try store.claimMemoryExtraction(at: at.addingTimeInterval(2)) else { Issue.record("Expected a requeued claim"); return }
        let request = try MemoryExtractionRequestBuilder.request(for: second)
        _ = try store.prepareMemoryExtraction(second, request: request, at: at.addingTimeInterval(2))
        try store.markMemoryExtractionDispatched(second, at: at.addingTimeInterval(2))
        try store.failMemoryExtraction(second, error: MiraError(.network, "synthetic failure"), at: at.addingTimeInterval(2))
        _ = try store.retryMemoryExtraction(second.job.id, at: at.addingTimeInterval(3))
        guard let third = try store.claimMemoryExtraction(at: at.addingTimeInterval(4)) else { Issue.record("Expected a retried claim"); return }
        try store.recoverMemoryExtraction(at: at.addingTimeInterval(5))
        #expect(try store.memoryExtractionJobs(conversationID: conversation.id, limit: 20).first?.state == .queued)
        _ = third
    }

    @Test func expiredUnsentLeaseReturnsToQueue() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, conversation, at) = try queuedStore(in: directory, at: 900)
        guard try store.claimMemoryExtraction(at: at) != nil else { Issue.record("Expected a claim"); return }
        try store.recoverMemoryExtraction(at: at.addingTimeInterval(121))
        #expect(try store.memoryExtractionJobs(conversationID: conversation.id, limit: 20).first?.state == .queued)
        #expect(try store.memoryExtractionBudget(at: at).reservedTokens == 0)
    }

    @Test func expiredDispatchedLeasePausesAndChargesCeilingOnlyOnce() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, conversation, at) = try queuedStore(in: directory, at: 1_000)
        guard let claim = try store.claimMemoryExtraction(at: at) else { Issue.record("Expected a claim"); return }
        let request = try MemoryExtractionRequestBuilder.request(for: claim)
        let reserved = try store.prepareMemoryExtraction(claim, request: request, at: at)
        try store.markMemoryExtractionDispatched(claim, at: at)
        try store.recoverMemoryExtraction(at: at.addingTimeInterval(121))
        #expect(try store.memoryExtractionJobs(conversationID: conversation.id, limit: 20).first?.state == .paused)
        let charged = try store.memoryExtractionBudget(at: at).chargedTokens
        #expect(charged == reserved)
        try store.recoverMemoryExtraction(at: at.addingTimeInterval(122))
        #expect(try store.memoryExtractionBudget(at: at).chargedTokens == charged)
    }

    @Test func forgedClaimSourceAndAttemptIdentityCannotPrepare() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, _, at) = try queuedStore(in: directory, at: 1_100)
        guard let claim = try store.claimMemoryExtraction(at: at) else { Issue.record("Expected a claim"); return }
        let request = try MemoryExtractionRequestBuilder.request(for: claim)
        var changedMessage = claim.source.message
        changedMessage.role = .assistant
        expectPrepareRejected(store, claim: MemoryExtractionClaim(job: claim.job, source: .init(message: changedMessage, executionID: claim.source.executionID, workspaceID: claim.source.workspaceID, sourceRevision: claim.source.sourceRevision, sourceHash: claim.source.sourceHash), policy: claim.policy, route: claim.route, leaseID: claim.leaseID, leaseExpiresAt: claim.leaseExpiresAt, attemptID: claim.attemptID), request: request, at: at)

        changedMessage = claim.source.message
        changedMessage.createdAt = at.addingTimeInterval(1)
        expectPrepareRejected(store, claim: MemoryExtractionClaim(job: claim.job, source: .init(message: changedMessage, executionID: claim.source.executionID, workspaceID: claim.source.workspaceID, sourceRevision: claim.source.sourceRevision, sourceHash: claim.source.sourceHash), policy: claim.policy, route: claim.route, leaseID: claim.leaseID, leaseExpiresAt: claim.leaseExpiresAt, attemptID: claim.attemptID), request: request, at: at)

        var changedJob = claim.job
        changedJob.conversationID = .init()
        expectPrepareRejected(store, claim: MemoryExtractionClaim(job: changedJob, source: claim.source, policy: claim.policy, route: claim.route, leaseID: claim.leaseID, leaseExpiresAt: claim.leaseExpiresAt, attemptID: claim.attemptID), request: request, at: at)

        expectPrepareRejected(store, claim: MemoryExtractionClaim(job: claim.job, source: claim.source, policy: claim.policy, route: claim.route, leaseID: claim.leaseID, leaseExpiresAt: claim.leaseExpiresAt, attemptID: UUID()), request: request, at: at)
    }

    @Test func exactExtractionRequestSchemaIsRequired() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, _, at) = try queuedStore(in: directory, at: 1_200)
        guard let claim = try store.claimMemoryExtraction(at: at) else { Issue.record("Expected a claim"); return }
        var request = try MemoryExtractionRequestBuilder.request(for: claim)
        request.system += " unexpected"
        #expect(throws: MiraError.self) { try store.prepareMemoryExtraction(claim, request: request, at: at) }
        #expect(try store.memoryExtractionBudget(at: at).reservedTokens == 0)
    }

    @Test func restoringBackupDisablesExtractionWithoutMutatingOriginal() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, conversation, _) = try queuedStore(in: directory, at: 1_300)
        let backup = directory.deletingLastPathComponent().appendingPathComponent("mira-extraction-backup-\(UUID().uuidString).sqlite")
        let restored = directory.deletingLastPathComponent().appendingPathComponent("mira-extraction-restored-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: backup); try? FileManager.default.removeItem(at: restored) }
        try store.exportBackup(to: backup)
        try store.restoreBackup(from: backup, to: restored)
        let restoredStore = try SQLiteMiraStore(directory: restored)
        #expect(try restoredStore.memoryCapturePolicy().mode == .manualOnly)
        #expect(try restoredStore.memoryExtractionJobs(conversationID: conversation.id, limit: 20).first?.state == .paused)
        #expect(try store.memoryCapturePolicy().mode == .candidateOnly)
        #expect(try store.memoryExtractionJobs(conversationID: conversation.id, limit: 20).first?.state == .queued)
    }

    @Test func exhaustedBudgetRejectsPreparationWithoutCharging() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, _, at) = try queuedStore(in: directory, at: 1_400, dailyTokenLimit: 100)
        guard let claim = try store.claimMemoryExtraction(at: at) else { Issue.record("Expected a claim"); return }
        let request = try MemoryExtractionRequestBuilder.request(for: claim)
        #expect(throws: MiraError.self) { try store.prepareMemoryExtraction(claim, request: request, at: at) }
        let budget = try store.memoryExtractionBudget(at: at)
        #expect(budget.reservedTokens == 0)
        #expect(budget.chargedTokens == 0)
    }

    @Test func preparedBeforeUTCMidnightCanDispatchAfterDayRollover() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, conversation, at) = try queuedStore(in: directory, at: 86_399)
        guard let claim = try store.claimMemoryExtraction(at: at) else { Issue.record("Expected a claim"); return }
        let request = try MemoryExtractionRequestBuilder.request(for: claim)
        _ = try store.prepareMemoryExtraction(claim, request: request, at: at)
        try store.markMemoryExtractionDispatched(claim, at: at.addingTimeInterval(1))
        #expect(try store.memoryExtractionJobs(conversationID: conversation.id, limit: 20).first?.state == .running)
    }

    @Test func retryUnderNewPolicyCreatesDistinctJobAndPreservesOldProvenance() throws {
        let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, conversation, at) = try queuedStore(in: directory, at: 1_500)
        guard let claim = try store.claimMemoryExtraction(at: at) else { Issue.record("Expected a claim"); return }
        let request = try MemoryExtractionRequestBuilder.request(for: claim)
        _ = try store.prepareMemoryExtraction(claim, request: request, at: at)
        try store.markMemoryExtractionDispatched(claim, at: at)
        try store.failMemoryExtraction(claim, error: MiraError(.network, "synthetic failure"), at: at)
        let nextPolicyDate = at.addingTimeInterval(1)
        try store.saveMemoryCapturePolicy(.init(revision: 3, mode: .candidateOnly, dailyTokenLimit: 10_000, enabledAt: nextPolicyDate), expectedRevision: 2, at: nextPolicyDate)
        let retriedID = try store.retryMemoryExtraction(claim.job.id, at: nextPolicyDate.addingTimeInterval(1))
        #expect(retriedID != claim.job.id)
        let jobs = try store.memoryExtractionJobs(conversationID: conversation.id, limit: 20)
        #expect(jobs.count == 2)
        #expect(jobs.contains { $0.id == claim.job.id && $0.state == .paused && $0.attemptCount == 1 })
        #expect(jobs.contains { $0.id == retriedID && $0.state == .queued && $0.policyRevision == 3 })
    }

    private func installFixture(in store: SQLiteMiraStore, bindConversation: Bool = true) throws -> ResolvedModelRouteSnapshot {
        let route = ResolvedModelRouteSnapshot(name: "Extraction", providerKind: .openAICompatible, baseURL: "https://example.invalid", modelID: "fixture", credentialReference: "fixture", contextWindow: 32_768)
        try store.saveConnection(.init(id: route.connectionID, revision: route.connectionRevision, name: "Fixture connection", providerKind: route.providerKind, baseURL: route.baseURL, credentialReference: route.credentialReference, credentialVersion: route.credentialVersion), expectedRevision: nil)
        try store.saveModel(.init(id: route.modelDescriptorID, revision: route.modelRevision, connectionID: route.connectionID, connectionRevision: route.connectionRevision, modelID: route.modelID, contextWindow: route.contextWindow, textCapability: route.textCapability, toolCapability: route.toolCapability, probeObservation: route.probeObservation, extractionCapability: .declared), expectedRevision: nil)
        try store.saveRoute(.init(id: route.id, revision: route.revision, name: route.name, modelDescriptorID: route.modelDescriptorID, maxOutputTokens: route.maxOutputTokens, requestsUsage: route.requestsUsage), expectedRevision: nil)
        if bindConversation {
            try store.saveRouteBinding(.init(scope: .global, purpose: .conversation, routeID: route.id), expectedRevision: nil)
        }
        return route
    }

    private func queuedStore(in directory: URL, at: TimeInterval, dailyTokenLimit: Int = 10_000) throws -> (SQLiteMiraStore, Conversation, Date) {
        let store = try SQLiteMiraStore(directory: directory)
        let route = try installFixture(in: store)
        try store.saveRouteBinding(.init(scope: .global, purpose: .memoryExtraction, routeID: route.id), expectedRevision: nil)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let date = Date(timeIntervalSince1970: at)
        try store.saveMemoryCapturePolicy(.init(revision: 2, mode: .candidateOnly, dailyTokenLimit: dailyTokenLimit, enabledAt: date), expectedRevision: 1, at: date)
        let execution = try store.enqueue(conversationID: conversation.id, text: "Lease test", route: route, executionID: .init(), messageID: .init(), at: date)
        _ = try store.finish(executionID: execution.id, status: .completed, text: "Done", usage: .init(), error: nil, assistantMessageID: .init(), at: date)
        return (store, conversation, date)
    }

    private func expectPrepareRejected(_ store: SQLiteMiraStore, claim: MemoryExtractionClaim, request: CanonicalModelRequest, at: Date) {
        #expect(throws: MiraError.self) { try store.prepareMemoryExtraction(claim, request: request, at: at) }
    }

    private func testDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-extraction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
