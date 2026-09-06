import Foundation
import MiraCore
import MiraData
import Testing

struct MemoryDerivedHistoryTests {
    @Test func forgottenFailedAttemptDoesNotBlockHistoryFromASuccessfulRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiraMemoryRetry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let route = ResolvedModelRouteSnapshot(name: "Synthetic", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", modelID: "synthetic", credentialReference: "no-key", contextWindow: 65_536)
        try StoredRouteFixture(route).install(in: store)
        let memory = try store.createMemory(draft: .init(content: "The editor is Aurora.", scope: .global),
            source: .manualEntry(id: UUID(), statement: "The editor is Aurora."), operationID: UUID(),
            replacing: nil, expectedRevision: nil, at: .now).memory
        let provider = MemoryHistoryProvider(failFirst: true)
        let app = try MiraApplication(store: store, provider: provider)
        let conversation = try await app.createConversation(workspaceID: nil)
        let failed = try await app.send(conversationID: conversation, text: "Help choose an editor.", routeID: route.id)
        try await waitForCompletion(failed, store: store, expected: .failed)
        _ = try await app.forgetMemory(memory.id, workspaceID: nil, expectedRevision: memory.revision)
        let retry = try await app.retry(failed, routeID: route.id)
        try await waitForCompletion(retry, store: store)
        let next = try await app.send(conversationID: conversation, text: "Give me a short checklist.", routeID: route.id)
        try await waitForCompletion(next, store: store)
        #expect(provider.requests.count == 3)
        #expect(provider.requests.last?.contextInfo?.references.contains { $0.kind == "historyMessage" } == true)
        #expect(try store.memoryContextNotices(in: conversation, at: .now)[retry] == nil)
        #expect(await app.shutdown())
    }

    @Test func forgettingMemoryRetainsCommittedHistoryAndExcludesItFromFutureRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiraMemoryHistory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let route = ResolvedModelRouteSnapshot(name: "Synthetic", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", modelID: "synthetic", credentialReference: "no-key", contextWindow: 65_536)
        try StoredRouteFixture(route).install(in: store)
        let provider = MemoryHistoryProvider()
        let app = try MiraApplication(store: store, provider: provider)
        let conversation = try await app.createConversation(workspaceID: nil)
        let first = try await app.send(conversationID: conversation, text: "My editor is Aurora.", routeID: route.id)
        try await waitForCompletion(first, store: store)

        var executions: [ExecutionID] = [first]
        for text in ["Continue, please.", "Continue again."] {
            let id = try await app.send(conversationID: conversation, text: text, routeID: route.id)
            executions.append(id)
            try await waitForCompletion(id, store: store)
        }
        #expect(provider.requests.count == 3)
        #expect(provider.requests[2].messages.contains { $0.role == .assistant && $0.text.contains("Aurora") })
        #expect(provider.requests[1].contextInfo?.references.contains { $0.kind == "historyMessage" } == true)
        #expect(provider.requests[2].contextInfo?.references.contains { $0.kind == "historyMessage" } == true)

        // Capture after every reply exists: descendants have no copied usage rows.
        let source = try #require(try store.messages(in: conversation).first { $0.role == .user })
        let memory = try await app.createMemory(draft: .init(content: "My editor is Aurora.", scope: .global), source: .message(id: source.id, excerpt: source.text), operationID: UUID()).memory

        let receipt = try await app.forgetMemory(memory.id, workspaceID: nil, expectedRevision: memory.revision)
        #expect(receipt.redactedExecutionIDs == Set(executions))
        let notices = try store.memoryContextNotices(in: conversation, at: Date(timeIntervalSince1970: 2_000))
        #expect(Set(notices.keys) == Set(executions))
        #expect(notices.values.flatMap { $0 }.allSatisfy { $0.memoryID == memory.id && $0.reason == .forgotten })
        for id in executions {
            #expect(try store.execution(id)?.bodyPurgedAt != nil)
            let attempts = try store.attempts(for: id)
            #expect(attempts.count == 1)
            #expect(attempts.allSatisfy { $0.request == nil && $0.output == nil && $0.bodyPurgedAt != nil })
        }
        let messages = try store.messages(in: conversation)
        #expect(messages.filter { $0.role == .user }.count == 3)
        #expect(messages.filter { $0.role == .assistant }.count == 3)
        #expect(messages.filter { $0.role == .assistant }.map(\.text) == ["Your editor is Aurora.", "Your editor is Aurora.", "Your editor is Aurora."])
        #expect(messages.filter { $0.role == .assistant }.allSatisfy { $0.bodyPurgedAt == nil })

        let future = try await app.send(conversationID: conversation, text: "What should I use now?", routeID: route.id)
        try await waitForCompletion(future, store: store)
        #expect(provider.requests.count == 4)
        let futureRequest = try #require(provider.requests.last)
        #expect(futureRequest.messages.map(\.text) == ["What should I use now?"])
        #expect(futureRequest.messages.contains { $0.text.contains("Aurora") } == false)
        #expect(futureRequest.contextInfo?.references.contains { $0.kind == "historyMessage" } == false)
        _ = await app.shutdown()

        let backup = directory.appendingPathComponent("forgotten.sqlite")
        try store.exportBackup(to: backup)
        let restoredDirectory = directory.appendingPathComponent("restored")
        try store.restoreBackup(from: backup, to: restoredDirectory)
        let restored = try SQLiteMiraStore(directory: restoredDirectory)
        let restoredMessages = try restored.messages(in: conversation)
        #expect(restoredMessages.filter { $0.role == .assistant }.map(\.text) == ["Your editor is Aurora.", "Your editor is Aurora.", "Your editor is Aurora.", "Your editor is Aurora."])
        #expect(restoredMessages.filter { $0.role == .assistant }.allSatisfy { $0.bodyPurgedAt == nil })
        #expect(try restored.executions(in: conversation).allSatisfy { $0.status == .completed })
        #expect(try restored.memoryDetail(memory.id, workspaceID: nil).memory.lifecycleStatus(at: Date(timeIntervalSince1970: 2_000)) == .forgotten)
        let restoredNotices = try restored.memoryContextNotices(in: conversation, at: Date(timeIntervalSince1970: 2_000))
        #expect(Set(restoredNotices.keys) == Set(executions))
        #expect(restoredNotices.values.flatMap { $0 }.allSatisfy { $0.reason == .forgotten })
    }
}

private func waitForCompletion(_ executionID: ExecutionID, store: SQLiteMiraStore, expected: ExecutionStatus = .completed) async throws {
    for _ in 0..<300 {
        if try store.execution(executionID)?.status.isTerminal == true {
            #expect(try store.execution(executionID)?.status == expected)
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw MiraError(.timeout, "Synthetic memory history execution did not complete.")
}

private final class MemoryHistoryProvider: ModelProviderPort, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [CanonicalModelRequest] = []
    private let failFirst: Bool
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    var requests: [CanonicalModelRequest] { lock.withLock { captured } }
    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        let index = lock.withLock { captured.append(request); return captured.count }
        return AsyncThrowingStream { continuation in
            if failFirst && index == 1 {
                continuation.finish(throwing: URLError(.networkConnectionLost))
                return
            }
            continuation.yield(.textDelta("Your editor is Aurora."))
            continuation.yield(.finished(.stop))
            continuation.finish()
        }
    }
}
