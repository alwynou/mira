import Foundation
import MiraCore
import MiraData
import Testing

@Suite("Natural memory recall")
struct NaturalMemoryRecallTests {
    @Test(arguments: [
        "What should I eat before a long morning?",
        "I'm picking a morning meal before work.",
        "早餐吃什么比较适合我？" // i18n-fixture: bilingual recall planner coverage.
    ])
    func breakfastParaphrasesExpandToBilingualTopicTerms(_ query: String) {
        let expansion = MemoryRecallPlanner.expand(query: query)
        #expect(expansion.matchedTopics.contains("breakfast"))
        #expect(expansion.aliasTerms.contains("breakfast"))
        #expect(expansion.aliasTerms.contains("早餐")) // i18n-fixture: bilingual recall planner coverage.
    }

    @Test func genericMorningCueDoesNotExpandByItself() {
        let expansion = MemoryRecallPlanner.expand(query: "Where should I put a writing task this morning?")
        #expect(!expansion.matchedTopics.contains("breakfast"))
        #expect(!expansion.aliasTerms.contains("breakfast"))
    }

    @Test(arguments: [
        "The noteworthy summary has no reading topic here.",
        "I am bookkeeping the budget for the team.",
        "Help me use my reading notes",
        "帮我整理读书笔记" // i18n-fixture: bilingual recall planner coverage.
    ])
    func nonBreakfastTopicsUseOnlyTheirOwnAliases(_ query: String) {
        let expansion = MemoryRecallPlanner.expand(query: query)
        if query.contains("noteworthy") || query.contains("bookkeeping") {
            #expect(expansion.matchedTopics.isEmpty)
        } else {
            #expect(expansion.matchedTopics.contains("reading-notes"))
            #expect(!expansion.matchedTopics.contains("breakfast"))
            #expect(!expansion.aliasTerms.contains("breakfast"))
        }
    }

    @Test(arguments: [
        ("Can you help shape this status note for my team?", "work-updates"),
        ("周六怎么安排杂事比较顺？", "errands"), // i18n-fixture: bilingual topic coverage.
        ("What exercise sessions fit my week?", "exercise"),
        ("下次出行选住宿时优先看什么？", "travel-lodging") // i18n-fixture: bilingual topic coverage.
    ])
    func boundedTopicAliasesCoverOtherEverydayParaphrases(_ value: (String, String)) {
        let expansion = MemoryRecallPlanner.expand(query: value.0)
        #expect(expansion.matchedTopics.contains(value.1))
        #expect(expansion.aliasTerms.count <= 8)
    }

    @Test func sourcePrefetchGateRequiresBothCues() {
        #expect(KnowledgePrefetchPlan.shouldPrefetch(query: "According to my Markdown notes, what does this say?"))
        #expect(KnowledgePrefetchPlan.shouldPrefetch(query: "根据我的笔记，里面提到了什么？")) // i18n-fixture: source cue coverage.
        #expect(!KnowledgePrefetchPlan.shouldPrefetch(query: "Please write a breakfast suggestion."))
        #expect(!KnowledgePrefetchPlan.shouldPrefetch(query: "My notes are important."))
    }

    @Test func ordinaryRelevantTaskReceivesPrefetchedMemoryWithoutMemorySearchRequest() async throws {
        let fixture = try NaturalMemoryRecallFixture()
        defer { fixture.cleanup() }
        let preference = try fixture.store.createMemory(
            draft: .init(content: "I prefer concise reading notes", scope: .global, kind: .preference, allowsRemoteUse: true),
            source: .manualEntry(id: UUID(), statement: "I prefer concise reading notes"),
            operationID: UUID(), replacing: nil, expectedRevision: nil, at: Date()
        ).memory
        #expect(preference.draft?.allowsRemoteUse == true)

        let provider = NaturalMemoryRecallProvider()
        let app = try MiraApplication(store: fixture.store, provider: provider)
        let conversationID = try await app.createConversation(workspaceID: nil)
        let executionID = try await app.send(
            conversationID: conversationID,
            text: "Help organize my reading notes",
            routeID: fixture.route.id
        )
        try await eventually { try fixture.store.execution(executionID)?.status.isTerminal == true }

        let request = try #require(provider.requests.first)
        #expect(request.messages.last?.text == "Help organize my reading notes")
        #expect(request.contextInfo?.references.contains {
            $0.kind == "memory" && $0.id == preference.id.rawValue.uuidString && $0.revision == preference.revision
        } == true)
        #expect((request.system + request.messages.map(\.text).joined()).contains(preference.citation))
        #expect((request.system + request.messages.map(\.text).joined()).contains("I prefer concise reading notes"))
        #expect(request.messages.contains { $0.text.localizedCaseInsensitiveContains("search memory") } == false)
        await app.shutdown()
    }

    @Test func bilingualBreakfastParaphraseReceivesActiveMemory() async throws {
        let fixture = try NaturalMemoryRecallFixture()
        defer { fixture.cleanup() }
        let preference = try fixture.store.createMemory(
            draft: .init(content: "I usually go for a savory breakfast", scope: .global, allowsRemoteUse: true),
            source: .manualEntry(id: UUID(), statement: "I usually go for a savory breakfast"),
            operationID: UUID(), replacing: nil, expectedRevision: nil, at: Date()
        ).memory
        let provider = NaturalMemoryRecallProvider()
        let app = try MiraApplication(store: fixture.store, provider: provider)
        let conversationID = try await app.createConversation(workspaceID: nil)
        let executionID = try await app.send(
            conversationID: conversationID,
            text: "早餐吃什么比较适合我？", // i18n-fixture: cross-language memory recall.
            routeID: fixture.route.id
        )
        try await eventually { try fixture.store.execution(executionID)?.status.isTerminal == true }
        let request = try #require(provider.requests.first)
        #expect(request.contextInfo?.references.contains {
            $0.kind == "memory" && $0.id == preference.id.rawValue.uuidString && $0.revision == preference.revision
        } == true)
        await app.shutdown()
    }

    @Test func ordinaryUnrelatedTaskReceivesNoPrefetchedMemory() async throws {
        let fixture = try NaturalMemoryRecallFixture()
        defer { fixture.cleanup() }
        let preference = try fixture.store.createMemory(
            draft: .init(content: "I prefer concise reading notes", scope: .global, kind: .preference, allowsRemoteUse: true),
            source: .manualEntry(id: UUID(), statement: "I prefer concise reading notes"),
            operationID: UUID(), replacing: nil, expectedRevision: nil, at: Date()
        ).memory
        let provider = NaturalMemoryRecallProvider()
        let app = try MiraApplication(store: fixture.store, provider: provider)
        let conversationID = try await app.createConversation(workspaceID: nil)
        let executionID = try await app.send(
            conversationID: conversationID,
            text: "Help plan my weekly meals",
            routeID: fixture.route.id
        )
        try await eventually { try fixture.store.execution(executionID)?.status.isTerminal == true }

        let request = try #require(provider.requests.first)
        #expect(request.messages.last?.text == "Help plan my weekly meals")
        #expect(request.contextInfo?.references.contains { $0.kind == "memory" } != true)
        #expect((request.system + request.messages.map(\.text).joined()).contains(preference.citation) == false)
        #expect((request.system + request.messages.map(\.text).joined()).contains(preference.draft?.content ?? "") == false)
        await app.shutdown()
    }
}

private struct NaturalMemoryRecallFixture {
    let directory: URL
    let store: SQLiteMiraStore
    let route: ModelRoute

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-natural-memory-" + UUID().uuidString)
        store = try SQLiteMiraStore(directory: directory)
        let connection = ProviderConnection(
            name: "Synthetic connection",
            providerKind: .openAICompatible,
            baseURL: "https://example.invalid/v1",
            credentialReference: "synthetic"
        )
        let model = ModelDescriptor(
            id: .init(), connectionID: connection.id, connectionRevision: connection.revision,
            modelID: "synthetic", contextWindow: 65_536, textCapability: .declared, toolCapability: .declared
        )
        route = ModelRoute(name: "Synthetic route", modelDescriptorID: model.id, maxOutputTokens: 1_024)
        try store.saveConnection(connection, expectedRevision: nil)
        try store.saveModel(model, expectedRevision: nil)
        try store.saveRoute(route, expectedRevision: nil)
        try store.saveRouteBinding(.init(scope: .global, purpose: .conversation, routeID: route.id), expectedRevision: nil)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private final class NaturalMemoryRecallProvider: ModelProviderPort, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [CanonicalModelRequest] = []

    var requests: [CanonicalModelRequest] { lock.withLock { captured } }

    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        lock.withLock { captured.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("Synthetic response"))
            continuation.yield(.finished(.stop))
            continuation.finish()
        }
    }
}

private func eventually(_ predicate: @Sendable () async throws -> Bool) async throws {
    for _ in 0..<400 {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw MiraError(.timeout, "Synthetic natural memory condition was not reached.")
}
