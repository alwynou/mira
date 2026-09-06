import Foundation
import Testing
import MiraCore
import MiraData

struct MemoryToolTests {
    @Test func reusedMemoryReceiptReportsCommittedRemoteUsePolicyWithoutChangingIt() async throws {
        let fixture = try MemoryToolFixture()
        defer { fixture.cleanup() }
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "Receipt fixture", createdAt: .now, updatedAt: .now)
        try fixture.store.createConversation(conversation)
        let resolved = try fixture.store.modelConfiguration().resolve(purpose: .conversation, explicitRouteID: fixture.route.id, conversation: conversation)
        let execution = try fixture.store.enqueue(conversationID: conversation.id, text: "Remember that I prefer short answers",
                                                  route: resolved, executionID: .init(), messageID: .init(), at: .now)
        let message = try #require(try fixture.store.messages(in: conversation.id).first)
        let content = "I prefer short answers"
        let existing = try fixture.store.createMemory(
            draft: .init(content: content, scope: .global, kind: .preference, allowsRemoteUse: true),
            source: .message(id: message.id, excerpt: content), operationID: .init(), replacing: nil,
            expectedRevision: nil, at: .now).memory
        let call = try rememberCall(content: content, quote: content)
        let attemptID = UUID()
        let request = CanonicalModelRequest(executionID: execution.id, system: "", messages: [], requestID: attemptID)
        try fixture.store.prepareAttempt(.init(id: attemptID, executionID: execution.id, stepID: UUID(), stepIndex: 1,
                                               request: request, createdAt: .now))
        let invocation = ToolInvocation(id: UUID(), attemptID: attemptID, modelOrder: 0, call: call)
        try fixture.store.finishAttempt(attemptID, output: .init(text: "", toolCalls: [call], finishReason: .toolCalls),
                                        invocations: [invocation], usage: .init(), error: nil, at: .now)
        try fixture.store.markToolDispatched(invocation.id, at: .now)

        let tool = MemoryRememberTool(store: fixture.store, approvals: MemoryApprovalCoordinator())
        let arguments = try JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8))
        let context = ToolContext(executionID: execution.id, invocationID: invocation.id, workspaceID: nil,
                                  userMessageID: message.id, userText: message.text)
        try await tool.authorize(arguments: arguments, context: context)
        let receiptJSON = try await tool.execute(arguments: arguments, context: context)
        let receipt = try JSONDecoder().decode(JSONValue.self, from: Data(receiptJSON.utf8))

        #expect(receipt["memory_id"]?.stringValue == existing.id.rawValue.uuidString.lowercased())
        #expect(receipt["allows_remote_use"]?.boolValue == true)
        let committed = try #require(try fixture.store.memoryDetail(existing.id, workspaceID: nil).memory.draft)
        #expect(committed.allowsRemoteUse)
        #expect(try fixture.store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 20).memories.count == 1)
    }

    @Test func directAnchoredRememberSavesOnceAfterDurableDispatchAndStaysLocal() async throws {
        let fixture = try MemoryToolFixture()
        defer { fixture.cleanup() }
        let approvals = MemoryApprovalCoordinator()
        let content = "I prefer short answers"
        let call = try rememberCall(content: content, quote: content)
        let provider = MemoryScriptedProvider(store: fixture.store, replies: [
            [.toolCalls([call]), .finished(.toolCalls)],
            [.textDelta("Saved"), .finished(.stop)]
        ])
        let app = try fixture.application(provider: provider, approvals: approvals, tools: [MemoryRememberTool(store: fixture.store, approvals: approvals)])
        let conversationID = try await app.createConversation(workspaceID: nil)
        let executionID = try await app.send(conversationID: conversationID, text: "Remember that " + content, routeID: fixture.route.id)
        try await memoryEventually { try fixture.store.executions(in: conversationID).last?.status.isTerminal == true }

        let memories = try fixture.store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 100).memories
        #expect(memories.count == 1)
        #expect(memories.first?.draft?.content == content)
        #expect(memories.first?.draft?.allowsRemoteUse == false)
        let detail = try fixture.store.memoryDetail(memories[0].id, workspaceID: nil)
        #expect(detail.evidence.first?.excerpt == content)
        let invocation = try #require(try await app.audit(for: executionID).invocations.first)
        #expect(invocation.result?.status == .succeeded)
        #expect(invocation.result?.text.contains(memories[0].id.rawValue.uuidString.lowercased()) == true)
        #expect(provider.requests.last?.messages.last?.text.contains("memory_id") == true)
        #expect(provider.snapshotsWereDurable)
        #expect(await approvals.pending().isEmpty)
        await app.shutdown()
    }

    @Test func paraphrasedContentRequiresApprovalAndDoesNotWriteBeforeApproval() async throws {
        let fixture = try MemoryToolFixture()
        defer { fixture.cleanup() }
        let approvals = MemoryApprovalCoordinator()
        let call = try rememberCall(content: "I prefer concise answers", quote: "I prefer short answers")
        let provider = MemoryScriptedProvider(store: fixture.store, replies: [
            [.toolCalls([call]), .finished(.toolCalls)],
            [.textDelta("Approved"), .finished(.stop)]
        ])
        let app = try fixture.application(provider: provider, approvals: approvals, tools: [MemoryRememberTool(store: fixture.store, approvals: approvals)])
        let conversationID = try await app.createConversation(workspaceID: nil)
        let executionID = try await app.send(conversationID: conversationID, text: "Please remember that I prefer short answers", routeID: fixture.route.id)
        try await memoryEventually { await approvals.pending().count == 1 }
        #expect(try fixture.store.memoryList(workspaceID: nil, states: Set(MemoryState.allCases), query: "", limit: 100).memories.isEmpty)

        let request = try #require(await approvals.pending().first)
        #expect(request.evidenceExcerpt == "I prefer short answers")
        #expect(request.draft.content == "I prefer concise answers")
        await approvals.respond(request.id, approved: true)
        try await memoryEventually { try fixture.store.executions(in: conversationID).last?.status.isTerminal == true }
        #expect(try fixture.store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 100).memories.count == 1)
        #expect(try await app.audit(for: executionID).invocations.first?.result?.status == .succeeded)
        await app.shutdown()
    }

    @Test func globalScopeFromWorkspaceRequiresApprovalAndUsesGlobalScopeAfterApproval() async throws {
        let fixture = try MemoryToolFixture()
        defer { fixture.cleanup() }
        let approvals = MemoryApprovalCoordinator()
        let content = "Keep this preference globally"
        let call = try rememberCall(content: content, quote: content, scope: "global")
        let provider = MemoryScriptedProvider(store: fixture.store, replies: [
            [.toolCalls([call]), .finished(.toolCalls)],
            [.textDelta("Approved"), .finished(.stop)]
        ])
        let app = try fixture.application(provider: provider, approvals: approvals, tools: [MemoryRememberTool(store: fixture.store, approvals: approvals)])
        let workspaceID = try await app.createWorkspace(name: "Approval workspace", background: "Synthetic context", allowsRemoteSend: true)
        let conversationID = try await app.createConversation(workspaceID: workspaceID)
        _ = try await app.send(conversationID: conversationID, text: "Remember globally that " + content, routeID: fixture.route.id)
        try await memoryEventually { await approvals.pending().count == 1 }
        #expect(try fixture.store.memoryList(workspaceID: nil, states: Set(MemoryState.allCases), query: "", limit: 100).memories.isEmpty)
        await approvals.respond((try #require(await approvals.pending().first)).id, approved: true)
        try await memoryEventually { try fixture.store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 100).memories.count == 1 }
        let memory = try #require(try fixture.store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 100).memories.first)
        #expect(memory.scope == .global)
        await app.shutdown()
    }

    @Test func denialProducesNoMemoryAndNoFalseSuccessReceipt() async throws {
        let fixture = try MemoryToolFixture()
        defer { fixture.cleanup() }
        let approvals = MemoryApprovalCoordinator()
        let content = "I prefer a quiet interface"
        let call = try rememberCall(content: content, quote: content)
        let provider = MemoryScriptedProvider(store: fixture.store, replies: [
            [.toolCalls([call]), .finished(.toolCalls)],
            [.textDelta("Denied"), .finished(.stop)]
        ])
        let app = try fixture.application(provider: provider, approvals: approvals, tools: [MemoryRememberTool(store: fixture.store, approvals: approvals)])
        let conversationID = try await app.createConversation(workspaceID: nil)
        let executionID = try await app.send(conversationID: conversationID, text: "Please remember " + content, routeID: fixture.route.id)
        try await memoryEventually { await approvals.pending().count == 1 }
        await approvals.respond((try #require(await approvals.pending().first)).id, approved: false)
        try await memoryEventually { try fixture.store.executions(in: conversationID).last?.status.isTerminal == true }

        #expect(try fixture.store.memoryList(workspaceID: nil, states: Set(MemoryState.allCases), query: "", limit: 100).memories.isEmpty)
        let invocation = try #require(try await app.audit(for: executionID).invocations.first)
        #expect(invocation.result?.status == .denied)
        #expect(invocation.result?.text.contains("memory_id") == false)
        await app.shutdown()
    }

    @Test func cancellationWhileApprovalIsPendingClearsApprovalAndDoesNotWrite() async throws {
        let fixture = try MemoryToolFixture()
        defer { fixture.cleanup() }
        let approvals = MemoryApprovalCoordinator()
        let content = "I prefer keyboard shortcuts"
        let call = try rememberCall(content: content, quote: content)
        let provider = MemoryScriptedProvider(store: fixture.store, replies: [[.toolCalls([call]), .finished(.toolCalls)]])
        let app = try fixture.application(provider: provider, approvals: approvals, tools: [MemoryRememberTool(store: fixture.store, approvals: approvals)])
        let conversationID = try await app.createConversation(workspaceID: nil)
        let executionID = try await app.send(conversationID: conversationID, text: "Please remember " + content, routeID: fixture.route.id)
        try await memoryEventually { await approvals.pending().count == 1 }
        await app.cancel(executionID)
        try await memoryEventually { try fixture.store.executions(in: conversationID).last?.status.isTerminal == true }
        #expect(await approvals.pending().isEmpty)
        #expect(try fixture.store.memoryList(workspaceID: nil, states: Set(MemoryState.allCases), query: "", limit: 100).memories.isEmpty)
        #expect(try await app.audit(for: executionID).invocations.first?.result?.status == .cancelledBeforeDispatch)
        await app.shutdown()
    }

    @Test func suppressedSourceRetryRequiresASeparateApproval() async throws {
        let fixture = try MemoryToolFixture()
        defer { fixture.cleanup() }
        let approvals = MemoryApprovalCoordinator()
        let content = "I prefer compact windows"
        let call = try rememberCall(content: content, quote: content)
        let provider = MemoryScriptedProvider(store: fixture.store, replies: [
            [.toolCalls([call]), .finished(.toolCalls)],
            [],
            [.toolCalls([call]), .finished(.toolCalls)],
            [.textDelta("Retry denied"), .finished(.stop)]
        ])
        let app = try fixture.application(provider: provider, approvals: approvals, tools: [MemoryRememberTool(store: fixture.store, approvals: approvals)])
        let conversationID = try await app.createConversation(workspaceID: nil)
        let firstID = try await app.send(conversationID: conversationID, text: "Remember that " + content, routeID: fixture.route.id)
        try await memoryEventually { try fixture.store.executions(in: conversationID).last?.status.isTerminal == true }
        let saved = try #require(try fixture.store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 100).memories.first)
        _ = try await app.changeMemoryState(saved.id, workspaceID: nil, state: .removed, expectedRevision: saved.revision)

        let retryID = try await app.retry(firstID, routeID: fixture.route.id)
        try await memoryEventually { await approvals.pending().count == 1 }
        #expect(try fixture.store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 100).memories.isEmpty)
        await approvals.respond((try #require(await approvals.pending().first)).id, approved: false)
        try await memoryEventually { try fixture.store.executions(in: conversationID).last?.status.isTerminal == true }
        #expect(try await app.audit(for: retryID).invocations.first?.result?.status == .denied)
        await app.shutdown()
    }

    @Test func readOnlySearchAndGetRespectScopeAndRecordUsagesForForget() async throws {
        let fixture = try MemoryToolFixture()
        defer { fixture.cleanup() }
        let workspaceID = try await fixture.makeWorkspace()
        let otherWorkspaceID = try await fixture.makeWorkspace()
        let global = try fixture.insertMemory(content: "Global visible memory", scope: .global)
        let workspace = try fixture.insertMemory(content: "Workspace visible memory", scope: .workspace(workspaceID), subject: .workspace)
        _ = try fixture.insertMemory(content: "Local only memory", scope: .global, allowsRemoteUse: false)
        let other = try fixture.insertMemory(content: "Other workspace memory", scope: .workspace(otherWorkspaceID), subject: .workspace)
        let search = CanonicalToolCall(id: "search", name: "memory.search", arguments: "{\"query\":\"memory\"}")
        let get = CanonicalToolCall(id: "get", name: "memory.get", arguments: "{\"memory_id\":\"\(global.id.rawValue.uuidString.lowercased())\"}")
        let crossWorkspace = CanonicalToolCall(id: "cross", name: "memory.get", arguments: "{\"memory_id\":\"\(other.id.rawValue.uuidString.lowercased())\"}")
        let approvals = MemoryApprovalCoordinator()
        let provider = MemoryScriptedProvider(store: fixture.store, replies: [
            [.toolCalls([search, get, crossWorkspace]), .finished(.toolCalls)],
            [.textDelta("Read complete"), .finished(.stop)]
        ])
        let app = try fixture.application(provider: provider, approvals: approvals, tools: MemoryTools.readOnly(store: fixture.store))
        let conversationID = try await app.createConversation(workspaceID: workspaceID)
        let executionID = try await app.send(conversationID: conversationID, text: "Search my memories", routeID: fixture.route.id)
        try await memoryEventually { try fixture.store.executions(in: conversationID).last?.status.isTerminal == true }
        #expect(provider.requests.count == 2)
        let observations = provider.requests[1].messages.filter { $0.role == .tool }.map(\.text).joined(separator: "\n")
        #expect(observations.contains("Global visible memory"))
        #expect(observations.contains("Workspace visible memory"))
        #expect(observations.contains(global.citation))
        #expect(observations.contains(workspace.citation))
        #expect(!observations.contains("Local only memory"))
        #expect(!observations.contains("Other workspace memory"))
        #expect(try await app.audit(for: executionID).invocations.map(\.result?.status) == [.succeeded, .succeeded, .failed])
        let forgetReceipt = try await app.forgetMemory(global.id, workspaceID: workspaceID, expectedRevision: global.revision)
        #expect(forgetReceipt.redactedExecutionIDs.contains(executionID))
        #expect(try await app.audit(for: executionID).invocations.count == 3)
        await app.shutdown()
    }
}

private extension JSONValue {
    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
}

private func rememberCall(content: String, quote: String, scope: String = "current", sensitive: Bool = false) throws -> CanonicalToolCall {
    let arguments = try JSONValue.object([
        "content": .string(content), "quote": .string(quote), "kind": .string(MemoryKind.preference.rawValue),
        "scope": .string(scope), "sensitive": .bool(sensitive)
    ]).jsonString()
    return CanonicalToolCall(id: UUID().uuidString, name: "memory.remember", arguments: arguments)
}

private struct MemoryToolFixture {
    let directory: URL
    let store: SQLiteMiraStore
    let route: ModelRoute
    let connection: ProviderConnection
    let model: ModelDescriptor

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiraMemoryTool-\(UUID())")
        store = try SQLiteMiraStore(directory: directory)
        let connectionID = ConnectionID()
        let modelID = ModelDescriptorID()
        connection = ProviderConnection(id: connectionID, name: "Synthetic connection", providerKind: .openAICompatible,
                                        baseURL: "https://example.invalid/v1", credentialReference: "synthetic")
        model = ModelDescriptor(id: modelID, connectionID: connectionID, connectionRevision: connection.revision,
                                modelID: "synthetic", contextWindow: 262_144, textCapability: .declared, toolCapability: .declared)
        route = ModelRoute(name: "Synthetic route", modelDescriptorID: modelID, maxOutputTokens: 1_024)
        try store.saveConnection(connection, expectedRevision: nil)
        try store.saveModel(model, expectedRevision: nil)
        try store.saveRoute(route, expectedRevision: nil)
        try store.saveRouteBinding(RouteBinding(scope: .global, purpose: .conversation, routeID: route.id), expectedRevision: nil)
    }

    func application(provider: MemoryScriptedProvider, approvals: MemoryApprovalCoordinator, tools: [any ToolPort]) throws -> MiraApplication {
        try MiraApplication(store: store, provider: provider, tools: ToolRegistry(tools), memoryApprovals: approvals)
    }

    func makeWorkspace() async throws -> WorkspaceID {
        let app = try application(provider: MemoryScriptedProvider(store: store, replies: []), approvals: MemoryApprovalCoordinator(), tools: [])
        let id = try await app.createWorkspace(name: "Synthetic workspace", background: "Synthetic context", allowsRemoteSend: true)
        await app.shutdown()
        return id
    }

    func insertMemory(content: String, scope: MemoryScope, subject: MemorySubject = .user, allowsRemoteUse: Bool = true) throws -> Memory {
        let draft = MemoryDraft(content: content, scope: scope, subject: subject, allowsRemoteUse: allowsRemoteUse)
        return try store.createMemory(draft: draft, source: .manualEntry(id: UUID(), statement: content), operationID: UUID(), replacing: nil, expectedRevision: nil, at: Date()).memory
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private final class MemoryScriptedProvider: ModelProviderPort, @unchecked Sendable {
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
    var snapshotsWereDurable: Bool { lock.withLock { !durableChecks.isEmpty && durableChecks.allSatisfy { $0 } } }

    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        let response: [CanonicalStreamEvent] = lock.withLock {
            let index = captured.count
            captured.append(request)
            durableChecks.append((try? store.attempts(for: request.executionID).last?.request) == request)
            return index < replies.count ? replies[index] : []
        }
        return AsyncThrowingStream { continuation in
            response.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

private func memoryEventually(_ predicate: @Sendable () async throws -> Bool) async throws {
    for _ in 0..<400 {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw MemoryToolTestError.timeout
}

private enum MemoryToolTestError: Error { case timeout }
