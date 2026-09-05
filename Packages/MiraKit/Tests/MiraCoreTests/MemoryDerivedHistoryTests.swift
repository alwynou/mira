import Foundation
import MiraCore
import MiraData
import Testing

struct MemoryDerivedHistoryTests {
    @Test func savingAMemoryAfterEarlierRepliesStillPurgesTheirHistoryDescendants() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiraMemoryHistory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let route = ResolvedModelRouteSnapshot(name: "Synthetic", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", modelID: "synthetic", credentialReference: "no-key", contextWindow: 65_536)
        try StoredRouteFixture(route).install(in: store)
        let provider = MemoryHistoryProvider()
        let app = try MiraApplication(store: store, provider: provider)
        let conversation = try await app.createConversation(workspaceID: nil)
        var executions: [ExecutionID] = []
        for text in ["My editor is Aurora.", "Continue, please.", "Continue again."] {
            let id = try await app.send(conversationID: conversation, text: text, routeID: route.id)
            executions.append(id)
            for _ in 0..<300 {
                if try store.execution(id)?.status.isTerminal == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try store.execution(id)?.status == .completed)
        }
        #expect(provider.requests.count == 3)
        #expect(provider.requests[2].messages.contains { $0.role == .assistant && $0.text.contains("Aurora") })
        #expect(provider.requests.allSatisfy { $0.contextInfo?.references.contains { $0.kind == "memory" } == false })

        let source = try #require(try store.messages(in: conversation).first { $0.role == .user })
        let memory = try await app.createMemory(draft: .init(content: "My editor is Aurora.", scope: .global), source: .message(id: source.id, excerpt: source.text), operationID: UUID()).memory
        let receipt = try await app.forgetMemory(memory.id, workspaceID: nil, expectedRevision: memory.revision)
        #expect(receipt.redactedExecutionIDs == Set(executions))
        for id in executions {
            #expect(try store.execution(id)?.bodyPurgedAt != nil)
            let attempts = try store.attempts(for: id)
            #expect(attempts.count == 1)
            #expect(attempts.allSatisfy { $0.request == nil && $0.output == nil && $0.bodyPurgedAt != nil })
        }
        let messages = try store.messages(in: conversation)
        #expect(messages.filter { $0.role == .user }.count == 3)
        #expect(messages.filter { $0.role == .assistant }.count == 3)
        #expect(messages.filter { $0.role == .assistant }.allSatisfy { $0.text.isEmpty && $0.bodyPurgedAt != nil })
        _ = await app.shutdown()

        let backup = directory.appendingPathComponent("forgotten.sqlite")
        try store.exportBackup(to: backup)
        let restoredDirectory = directory.appendingPathComponent("restored")
        try store.restoreBackup(from: backup, to: restoredDirectory)
        let restored = try SQLiteMiraStore(directory: restoredDirectory)
        #expect(try restored.executions(in: conversation).allSatisfy { $0.bodyPurgedAt != nil })
    }
}

private final class MemoryHistoryProvider: ModelProviderPort, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [CanonicalModelRequest] = []
    var requests: [CanonicalModelRequest] { lock.withLock { captured } }
    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        lock.withLock { captured.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("Your editor is Aurora."))
            continuation.yield(.finished(.stop))
            continuation.finish()
        }
    }
}
