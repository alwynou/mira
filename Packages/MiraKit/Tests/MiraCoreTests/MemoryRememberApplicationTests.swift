import Foundation
import MiraCore
import MiraData
import Testing

@Suite("Memory remember application pipeline")
struct MemoryRememberApplicationTests {
    @Test func directRememberCommitsLocalMemoryAndPairedReceiptBeforeFinalReply() async throws {
        let fixture = try RememberApplicationFixture()
        defer { fixture.cleanup() }
        let approvals = MemoryApprovalCoordinator()
        let content = "I prefer short answers"
        let call = try rememberCall(content: content, quote: content)
        let provider = ScriptedRememberProvider(store: fixture.store, replies: [
            [.toolCalls([call]), .finished(.toolCalls)],
            [.textDelta("Saved your preference."), .finished(.stop)],
            [.textDelta("There is no saved preference available."), .finished(.stop)]
        ])
        let app = try MiraApplication(
            store: fixture.store,
            provider: provider,
            tools: ToolRegistry([MemoryRememberTool(store: fixture.store, approvals: approvals)]),
            memoryApprovals: approvals
        )

        let conversationID = try await app.createConversation(workspaceID: nil)
        let executionID = try await app.send(conversationID: conversationID, text: "Remember that \(content)", routeID: fixture.route.id)
        try await eventually { try fixture.store.execution(executionID)?.status.isTerminal == true }

        #expect(provider.requests.count == 2)
        let memories = try fixture.store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 20).memories
        #expect(memories.count == 1)
        let memory = try #require(memories.first)
        #expect(memory.draft?.content == content)
        #expect(memory.draft?.allowsRemoteUse == false)

        let audit = try await app.audit(for: executionID)
        let invocation = try #require(audit.invocations.first)
        #expect(invocation.call.id == call.id)
        #expect(invocation.result?.status == .succeeded)
        #expect(invocation.result?.text.contains("\"allows_remote_use\":false") == true)
        #expect(invocation.result?.text.contains(memory.id.rawValue.uuidString.lowercased()) == true)

        let receipt = try #require(provider.requests.last?.messages.last)
        #expect(receipt.role == .tool)
        #expect(receipt.toolCallID == call.id)
        #expect(receipt.text.contains(memory.citation))
        #expect(receipt.text.contains("allows_remote_use"))
        #expect(provider.durableSnapshots)
        #expect(try fixture.store.messages(in: conversationID).contains { $0.role == .assistant && $0.status == .committed && $0.text == "Saved your preference." })

        let forget = try await app.forgetMemory(memory.id, workspaceID: nil, expectedRevision: memory.revision)
        #expect(forget.redactedExecutionIDs.contains(executionID))
        let afterForget = try await app.conversation(conversationID)
        #expect(afterForget.messages.contains { $0.role == .user && $0.text == "Remember that \(content)" })
        #expect(afterForget.messages.filter { $0.role == .assistant }.allSatisfy { $0.bodyPurgedAt != nil && $0.text.isEmpty })
        #expect(afterForget.drafts.isEmpty)
        let forgottenAudit = try await app.audit(for: executionID)
        #expect(forgottenAudit.attempts.allSatisfy { $0.bodyPurgedAt != nil && $0.request == nil && $0.output == nil })
        #expect(forgottenAudit.invocations.allSatisfy { $0.bodyPurgedAt != nil && $0.call.arguments.isEmpty && $0.result == nil })
        #expect(try fixture.store.execution(executionID)?.bodyPurgedAt != nil)

        let secondConversationID = try await app.createConversation(workspaceID: nil)
        let secondExecutionID = try await app.send(conversationID: secondConversationID, text: "What do you remember about my preferences?", routeID: fixture.route.id)
        try await eventually { try fixture.store.execution(secondExecutionID)?.status.isTerminal == true }
        #expect(provider.requests.count == 3)
        #expect(!(provider.requests[2].contextInfo?.references ?? []).contains { $0.id == memory.id.rawValue.uuidString })
        #expect(!provider.requests[2].system.contains(content))
        await app.shutdown()
    }

    @Test func paraphrasedRememberRequiresHostDecisionAndDenialHasNoSuccessReceipt() async throws {
        let fixture = try RememberApplicationFixture()
        defer { fixture.cleanup() }
        let approvals = MemoryApprovalCoordinator()
        let call = try rememberCall(content: "I prefer concise answers", quote: "I prefer short answers")
        let provider = ScriptedRememberProvider(store: fixture.store, replies: [
            [.toolCalls([call]), .finished(.toolCalls)],
            [.textDelta("No preference saved."), .finished(.stop)]
        ])
        let app = try MiraApplication(
            store: fixture.store,
            provider: provider,
            tools: ToolRegistry([MemoryRememberTool(store: fixture.store, approvals: approvals)]),
            memoryApprovals: approvals
        )
        let conversationID = try await app.createConversation(workspaceID: nil)
        let executionID = try await app.send(conversationID: conversationID, text: "Please remember that I prefer short answers", routeID: fixture.route.id)
        try await eventually { await approvals.pending().count == 1 }
        #expect(try fixture.store.memoryList(workspaceID: nil, states: Set(MemoryState.allCases), query: "", limit: 20).memories.isEmpty)

        let request = try #require(await approvals.pending().first)
        #expect(request.evidenceExcerpt == "I prefer short answers")
        #expect(request.draft.content == "I prefer concise answers")
        await approvals.respond(request.id, approved: false)
        try await eventually { try fixture.store.execution(executionID)?.status.isTerminal == true }
        #expect(try fixture.store.memoryList(workspaceID: nil, states: Set(MemoryState.allCases), query: "", limit: 20).memories.isEmpty)
        let invocation = try #require(try await app.audit(for: executionID).invocations.first)
        #expect(invocation.result?.status == .denied)
        #expect(invocation.result?.text.contains("memory_id") == false)
        await app.shutdown()
    }
}

private func rememberCall(content: String, quote: String) throws -> CanonicalToolCall {
    let arguments = try JSONValue.object([
        "content": .string(content),
        "quote": .string(quote),
        "kind": .string(MemoryKind.preference.rawValue),
        "scope": .string("current"),
        "sensitive": .bool(false)
    ]).jsonString()
    return CanonicalToolCall(id: "remember-call", name: "memory.remember", arguments: arguments)
}

private struct RememberApplicationFixture {
    let directory: URL
    let store: SQLiteMiraStore
    let route: ModelRoute

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-memory-application-\(UUID().uuidString)")
        store = try SQLiteMiraStore(directory: directory)
        let connection = ProviderConnection(name: "Synthetic connection", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", credentialReference: "synthetic")
        let model = ModelDescriptor(id: .init(), connectionID: connection.id, connectionRevision: connection.revision, modelID: "synthetic", contextWindow: 65_536, textCapability: .declared, toolCapability: .declared)
        route = ModelRoute(name: "Synthetic route", modelDescriptorID: model.id, maxOutputTokens: 1_024)
        try store.saveConnection(connection, expectedRevision: nil)
        try store.saveModel(model, expectedRevision: nil)
        try store.saveRoute(route, expectedRevision: nil)
        try store.saveRouteBinding(.init(scope: .global, purpose: .conversation, routeID: route.id), expectedRevision: nil)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private final class ScriptedRememberProvider: ModelProviderPort, @unchecked Sendable {
    private let lock = NSLock()
    private let store: SQLiteMiraStore
    private let replies: [[CanonicalStreamEvent]]
    private var captured: [CanonicalModelRequest] = []
    private var durableChecks: [Bool] = []

    init(store: SQLiteMiraStore, replies: [[CanonicalStreamEvent]]) {
        self.store = store
        self.replies = replies
    }

    var requests: [CanonicalModelRequest] { lock.withLock { captured } }
    var durableSnapshots: Bool { lock.withLock { !durableChecks.isEmpty && durableChecks.allSatisfy { $0 } } }

    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        let response: [CanonicalStreamEvent] = lock.withLock {
            let index = captured.count
            captured.append(request)
            durableChecks.append((try? store.request(for: request.executionID)) == request)
            return index < replies.count ? replies[index] : []
        }
        return AsyncThrowingStream { continuation in
            response.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

private func eventually(_ predicate: @Sendable () async throws -> Bool) async throws {
    for _ in 0..<400 {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw MiraError(.timeout, "Synthetic application condition was not reached.")
}
