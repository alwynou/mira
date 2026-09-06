import Foundation
import MiraData
import MiraCore
import Testing

@Suite("Memory extraction application integration")
struct MemoryExtractionApplicationTests {
    @Test func defaultManualOnlyReplyDoesNotStartExtraction() async throws {
        let fixture = try ExtractionApplicationFixture()
        defer { fixture.cleanup() }
        let provider = ExtractionApplicationProvider()
        let app = try MiraApplication(store: fixture.store, provider: provider)
        await app.startBackgroundWork()
        await app.startBackgroundWork()

        let conversationID = try await app.createConversation(workspaceID: nil)
        let executionID = try await app.send(conversationID: conversationID, text: "I prefer tea", routeID: fixture.route.id)
        try await eventually(named: "manual foreground reply") { try fixture.store.execution(executionID)?.status == .completed }

        #expect(provider.requests.count == 1)
        #expect(provider.routePurposes[0] == .conversation)
        #expect(try fixture.store.memoryExtractionJobs(conversationID: conversationID, limit: 20).isEmpty)
        #expect(try fixture.store.executions(in: conversationID).count == 1)
        #expect(try fixture.store.messages(in: conversationID).filter { $0.role == .assistant }.count == 1)
        #expect(await app.shutdown())
    }

    @Test func enablingExtractionUsesDedicatedRouteAndCommitsSeparateAudit() async throws {
        let fixture = try ExtractionApplicationFixture()
        defer { fixture.cleanup() }
        let provider = ExtractionApplicationProvider()
        let app = try MiraApplication(store: fixture.store, provider: provider)
        await app.startBackgroundWork()
        try await app.saveMemoryCapturePolicy(mode: .candidateOnly, dailyTokenLimit: 100_000, expectedRevision: 1)

        let conversationID = try await app.createConversation(workspaceID: nil)
        let executionID = try await app.send(conversationID: conversationID, text: "I prefer tea", routeID: fixture.route.id)
        try await eventually(named: "enabled foreground reply", diagnostics: {
            "execution=\(String(describing: try? fixture.store.execution(executionID)?.status)); jobs=\(String(describing: try? fixture.store.memoryExtractionJobs(conversationID: conversationID, limit: 20).map(\.state))); requests=\(provider.requests.count)"
        }) { try fixture.store.execution(executionID)?.status == .completed }
        try await eventually(named: "enabled extraction completion", diagnostics: {
            "execution=\(String(describing: try? fixture.store.execution(executionID)?.status)); jobs=\(String(describing: try? fixture.store.memoryExtractionJobs(conversationID: conversationID, limit: 20).map(\.state))); requests=\(provider.requests.count); purposes=\(provider.routePurposes)"
        }) {
            try fixture.store.memoryExtractionJobs(conversationID: conversationID, limit: 20).first?.state == .completed
        }

        #expect(provider.requests.count == 2)
        let extractionRequest = try #require(provider.requests.last)
        #expect(provider.routePurposes == [.conversation, .memoryExtraction])
        #expect(extractionRequest.executionID == executionID)
        #expect(extractionRequest.requestID != executionID.rawValue)
        #expect(extractionRequest.tools == nil)
        #expect(extractionRequest.messages.count == 1)
        #expect(extractionRequest.system.contains(MemoryExtractionValidator.instructions))
        #expect(extractionRequest.system.contains(try MemoryExtractionValidator.outputSchema.jsonString()))
        #expect(extractionRequest.system.contains("required"))

        let executions = try fixture.store.executions(in: conversationID)
        #expect(executions.count == 1)
        #expect(try fixture.store.messages(in: conversationID).filter { $0.role == .assistant }.count == 1)
        let job = try #require(try fixture.store.memoryExtractionJobs(conversationID: conversationID, limit: 20).first)
        let memoryID = try #require(job.memoryIDs.first)
        #expect(job.candidateMemoryIDs == [memoryID])
        #expect(try fixture.store.memoryDetail(memoryID, workspaceID: nil).memory.state == .candidate)

        let reviewed = try await app.changeMemoryState(memoryID, workspaceID: nil, state: .active, expectedRevision: 1)
        #expect(reviewed.state == .active)
        #expect(reviewed.origin == .observedUserStatement)
        #expect(reviewed.authority == .explicitUser)
        let laterConversationID = try await app.createConversation(workspaceID: nil)
        let laterExecutionID = try await app.send(conversationID: laterConversationID, text: "What do you know about tea?", routeID: fixture.route.id)
        try await eventually(named: "later foreground reply", diagnostics: {
            "execution=\(String(describing: try? fixture.store.execution(laterExecutionID)?.status)); error=\(String(describing: try? fixture.store.execution(laterExecutionID)?.error)); requests=\(provider.requests.count); purposes=\(provider.routePurposes)"
        }) { try fixture.store.execution(laterExecutionID)?.status == .completed }
        #expect(provider.requests.count == 3)
        let laterRequest = try #require(provider.requests.last)
        #expect(laterRequest.contextInfo?.references.contains { $0.id == memoryID.rawValue.uuidString } == true)
        #expect(laterRequest.system.contains("I prefer tea"))
        #expect(await app.shutdown())
    }

    @Test func disablingDuringSuspendedExtractionCancelsLateCommitAndPreservesForegroundWork() async throws {
        let fixture = try ExtractionApplicationFixture()
        defer { fixture.cleanup() }
        let provider = ExtractionApplicationProvider(suspendAfterFirstExtraction: false, suspendExtraction: true)
        let app = try MiraApplication(store: fixture.store, provider: provider)
        await app.startBackgroundWork()
        try await app.saveMemoryCapturePolicy(mode: .candidateOnly, dailyTokenLimit: 100_000, expectedRevision: 1)

        let firstConversation = try await app.createConversation(workspaceID: nil)
        let firstExecution = try await app.send(conversationID: firstConversation, text: "I prefer tea", routeID: fixture.route.id)
        try await eventually(named: "suspended extraction dispatch") { provider.extractionRequestCount == 1 }
        try await eventually(named: "suspended foreground reply") { try fixture.store.execution(firstExecution)?.status == .completed }

        let independentConversation = try await app.createConversation(workspaceID: nil)
        let independentExecution = try await app.send(conversationID: independentConversation, text: "Answer while memory waits", routeID: fixture.route.id)
        try await eventually(named: "independent foreground reply") { try fixture.store.execution(independentExecution)?.status == .completed }
        #expect(provider.normalRequestCount == 2)

        try await app.saveMemoryCapturePolicy(mode: .manualOnly, dailyTokenLimit: 100_000, expectedRevision: 2)
        try await eventually(named: "disabled extraction pause") {
            try fixture.store.memoryExtractionJobs(conversationID: firstConversation, limit: 20).first?.state == .paused
        }
        provider.releaseSuspendedExtraction()
        try await Task.sleep(for: .milliseconds(20))
        #expect(try fixture.store.memoryList(workspaceID: nil, states: Set(MemoryState.allCases), query: "", limit: 20).memories.isEmpty)
        let settled = try await app.memoryExtractionBudget()
        #expect(settled.reservedTokens == 0)
        #expect(settled.chargedTokens > 0)

        try await app.saveMemoryCapturePolicy(mode: .manualOnly, dailyTokenLimit: 100_000, expectedRevision: 3)
        let settledAgain = try await app.memoryExtractionBudget()
        #expect(settledAgain.dayStart == settled.dayStart)
        #expect(settledAgain.tokenLimit == settled.tokenLimit)
        #expect(settledAgain.reservedTokens == settled.reservedTokens)
        #expect(settledAgain.chargedTokens == settled.chargedTokens)
        #expect(await app.shutdown())
    }

    @Test func forgettingWhileExtractionSuspendedBlocksLateCommitAndKeepsForegroundIndependent() async throws {
        let fixture = try ExtractionApplicationFixture()
        defer { fixture.cleanup() }
        let provider = ExtractionApplicationProvider(suspendAfterFirstExtraction: true)
        let app = try MiraApplication(store: fixture.store, provider: provider)
        await app.startBackgroundWork()
        try await app.saveMemoryCapturePolicy(mode: .candidateOnly, dailyTokenLimit: 100_000, expectedRevision: 1)

        let firstConversation = try await app.createConversation(workspaceID: nil)
        let firstExecution = try await app.send(conversationID: firstConversation, text: "I prefer tea", routeID: fixture.route.id)
        try await eventually(named: "first foreground reply") { try fixture.store.execution(firstExecution)?.status == .completed }
        try await eventually(named: "first extraction completion") { provider.extractionRequestCount == 1 && (try? fixture.store.memoryExtractionJobs(conversationID: firstConversation, limit: 20).first?.state) == .completed }
        let firstJob = try #require(try fixture.store.memoryExtractionJobs(conversationID: firstConversation, limit: 20).first)
        let memoryID = try #require(firstJob.memoryIDs.first)
        _ = try await app.changeMemoryState(memoryID, workspaceID: nil, state: .active, expectedRevision: 1)

        let secondConversation = try await app.createConversation(workspaceID: nil)
        let secondExecution = try await app.send(conversationID: secondConversation, text: "I prefer coffee", routeID: fixture.route.id)
        try await eventually(named: "second extraction dispatch", diagnostics: {
            "execution=\(String(describing: try? fixture.store.execution(secondExecution)?.status)); error=\(String(describing: try? fixture.store.execution(secondExecution)?.error)); jobs=\(String(describing: try? fixture.store.memoryExtractionJobs(conversationID: secondConversation, limit: 20).map(\.state))); requests=\(provider.requests.count); purposes=\(provider.routePurposes)"
        }) { provider.extractionRequestCount == 2 }
        try await eventually(named: "second foreground reply") { try fixture.store.execution(secondExecution)?.status == .completed }

        _ = try await app.forgetMemory(memoryID, workspaceID: nil, expectedRevision: 2)
        let independentConversation = try await app.createConversation(workspaceID: nil)
        let independentExecution = try await app.send(conversationID: independentConversation, text: "Answer independently", routeID: fixture.route.id)
        try await eventually(named: "post-forget foreground reply") { try fixture.store.execution(independentExecution)?.status == .completed }
        #expect(provider.normalRequestCount == 3)
        try await app.saveMemoryCapturePolicy(mode: .manualOnly, dailyTokenLimit: 100_000, expectedRevision: 2)
        try await eventually(named: "forgotten extraction suppression") {
            try fixture.store.memoryExtractionJobs(conversationID: secondConversation, limit: 20).first?.state == .suppressed
        }
        provider.releaseSuspendedExtraction()
        try await Task.sleep(for: .milliseconds(20))

        let memories = try fixture.store.memoryList(workspaceID: nil, states: Set(MemoryState.allCases), query: "", limit: 20).memories
        #expect(memories.count == 1)
        #expect(memories.first?.forgottenAt != nil)
        let budget = try await app.memoryExtractionBudget()
        #expect(budget.reservedTokens == 0)
        #expect(budget.chargedTokens > 0)
        #expect(try fixture.store.memoryExtractionJobs(conversationID: secondConversation, limit: 20).first?.state == .suppressed)
        #expect(await app.shutdown())
    }
}

private struct ExtractionApplicationFixture {
    let directory: URL
    let store: SQLiteMiraStore
    let route: ModelRoute

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiraExtractionApplication-\(UUID())")
        let store = try SQLiteMiraStore(directory: directory)
        let snapshot = ResolvedModelRouteSnapshot(name: "Extraction application fixture", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", modelID: "synthetic", credentialReference: "no-key", contextWindow: 32_768, extractionCapability: .declared)
        let fixture = StoredRouteFixture(snapshot)
        try fixture.install(in: store, binding: .init(scope: .global, purpose: .conversation, routeID: fixture.route.id))
        try store.saveRouteBinding(.init(scope: .global, purpose: .memoryExtraction, routeID: fixture.route.id), expectedRevision: nil)
        self.store = store
        route = fixture.route
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private final class ExtractionApplicationProvider: ModelProviderPort, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [CanonicalModelRequest] = []
    private var suspended: [(AsyncThrowingStream<CanonicalStreamEvent, any Error>.Continuation, String)] = []
    private let suspendAfterFirstExtraction: Bool
    private let suspendExtraction: Bool

    init(suspendAfterFirstExtraction: Bool = false, suspendExtraction: Bool = false) {
        self.suspendAfterFirstExtraction = suspendAfterFirstExtraction
        self.suspendExtraction = suspendExtraction
    }

    var requests: [CanonicalModelRequest] { lock.withLock { captured } }
    private var purposes: [ModelPurpose] = []
    var routePurposes: [ModelPurpose] { lock.withLock { purposes } }
    var normalRequestCount: Int { lock.withLock { purposes.filter { $0 == .conversation }.count } }
    var extractionRequestCount: Int { lock.withLock { purposes.filter { $0 == .memoryExtraction }.count } }

    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        let extractionIndex = lock.withLock { purposes.filter { $0 == .memoryExtraction }.count }
        lock.withLock { captured.append(request); purposes.append(route.purpose) }
        let shouldSuspend = route.purpose == .memoryExtraction && (suspendExtraction || (suspendAfterFirstExtraction && extractionIndex > 0))
        if shouldSuspend {
            let pair = AsyncThrowingStream<CanonicalStreamEvent, any Error>.makeStream()
            lock.withLock { suspended.append((pair.continuation, Self.sourceContent(from: request))) }
            return pair.stream
        }
        return AsyncThrowingStream { continuation in
            if route.purpose == .memoryExtraction {
                continuation.yield(.textDelta(Self.extractionJSON(content: Self.sourceContent(from: request))))
                continuation.yield(.usage(.init(inputTokens: 7, outputTokens: 5)))
            } else {
                continuation.yield(.textDelta("Synthetic foreground answer."))
                continuation.yield(.usage(.init(inputTokens: 4, outputTokens: 3)))
            }
            continuation.yield(.finished(.stop))
            continuation.finish()
        }
    }

    func releaseSuspendedExtraction() {
        let continuations = lock.withLock { let values = suspended; suspended.removeAll(); return values }
        for (continuation, content) in continuations {
            continuation.yield(.textDelta(Self.extractionJSON(content: content)))
            continuation.yield(.usage(.init(inputTokens: 7, outputTokens: 5)))
            continuation.yield(.finished(.stop))
            continuation.finish()
        }
    }

    private static func sourceContent(from request: CanonicalModelRequest) -> String {
        guard let message = request.messages.first,
              let data = message.text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? String else { return "I prefer tea" }
        return content
    }

    private static func extractionJSON(content: String) -> String {
        "{\"version\":1,\"items\":[{\"content\":\"\(content)\",\"quote\":\"\(content)\",\"kind\":\"preference\",\"subject\":\"user\",\"sensitivity\":\"standard\",\"inferred\":false,\"stable\":true,\"confidence\":\"high\",\"validFrom\":null,\"validUntil\":null}]}"
    }
}

private func eventually(named label: String = "condition", diagnostics: @escaping @Sendable () -> String = { "" }, _ predicate: @escaping @Sendable () throws -> Bool) async throws {
    for _ in 0..<400 {
        if try predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    let detail = diagnostics()
    let suffix = detail.isEmpty ? "" : " Details: \(detail)"
    throw MiraError(.timeout, "Synthetic memory extraction application condition was not reached: \(label).\(suffix)")
}
