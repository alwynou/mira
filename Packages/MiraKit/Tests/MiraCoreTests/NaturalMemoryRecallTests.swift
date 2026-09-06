import Foundation
import MiraCore
import MiraData
import Testing

@Suite("Natural memory recall")
struct NaturalMemoryRecallTests {
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
