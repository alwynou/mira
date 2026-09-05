import Foundation
import Testing
@testable import MiraCore

struct ContextBuilderTests {
    private func route(window: Int? = 32_768) -> ModelRoute {
        .init(name: "Fixture", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", modelID: "synthetic", credentialReference: "test-reference", contextWindow: window)
    }

    @Test func rejectsUnknownCapabilitiesAndUnsafeEndpoints() throws {
        #expect(throws: MiraError.self) { try route(window: nil).validateForSending() }
        var invalid = route(); invalid.baseURL = "https://secret@example.invalid/v1"
        #expect(throws: MiraError.self) { try invalid.validateForSending() }
        invalid.baseURL = "http://example.invalid/v1"; invalid.allowsLoopbackHTTP = true
        #expect(throws: MiraError.self) { try invalid.validateForSending() }
        invalid.baseURL = "http://127.0.0.1:1234/v1"
        #expect(try invalid.validatedEndpoint().absoluteString == "http://127.0.0.1:1234/v1/chat/completions")
        invalid.textCapability = .unknown
        #expect(throws: MiraError.self) { try invalid.validateForSending() }
    }

    @Test func retryHistoryUsesSuccessfulReplacementAndCurrentInputOnce() throws {
        let now = Date(timeIntervalSince1970: 100), id = ConversationID(), user1 = MessageID(), user2 = MessageID()
        let failedID = ExecutionID(), successID = ExecutionID(), currentID = ExecutionID()
        let conversation = Conversation(id: id, workspaceID: nil, title: "test", createdAt: now, updatedAt: now)
        let failed = Execution(id: failedID, conversationID: id, triggerMessageID: user1, status: .interrupted, route: route(), createdAt: now, updatedAt: now)
        let success = Execution(id: successID, conversationID: id, triggerMessageID: user1, retryOfExecutionID: failedID, status: .completed, route: route(), createdAt: now, updatedAt: now)
        let current = Execution(id: currentID, conversationID: id, triggerMessageID: user2, route: route(), createdAt: now, updatedAt: now)
        let messages = [
            Message(id: user1, conversationID: id, executionID: failedID, sequence: 1, role: .user, status: .committed, text: "first", createdAt: now),
            Message(id: .init(), conversationID: id, executionID: failedID, sequence: 2, role: .assistant, status: .interrupted, text: "BAD partial", createdAt: now),
            Message(id: .init(), conversationID: id, executionID: successID, sequence: 3, role: .assistant, status: .committed, text: "GOOD answer", createdAt: now),
            Message(id: user2, conversationID: id, executionID: currentID, sequence: 4, role: .user, status: .committed, text: "current", createdAt: now)
        ]
        let request = try ContextBuilder.build(execution: current, conversations: [conversation], workspaces: [], messages: messages, executions: [failed, success, current])
        #expect(request.messages.map(\.text) == ["first", "GOOD answer", "current"])
        #expect(request.messages.filter { $0.text == "current" }.count == 1)
    }

    @Test func isolatesWorkspaceAndBlocksOversizedInputBeforeSending() throws {
        let now = Date(), workspaceID = WorkspaceID(), conversationID = ConversationID(), messageID = MessageID()
        var workspace = Workspace(id: workspaceID, name: "Private", background: "ONLY THIS BACKGROUND", allowsRemoteSend: false)
        let other = Workspace(id: .init(), name: "Other", background: "MUST NOT LEAK")
        let conversation = Conversation(id: conversationID, workspaceID: workspaceID, title: "Fixture", createdAt: now, updatedAt: now)
        let execution = Execution(id: .init(), conversationID: conversationID, triggerMessageID: messageID, route: route(), createdAt: now, updatedAt: now)
        var message = Message(id: messageID, conversationID: conversationID, executionID: execution.id, sequence: 1, role: .user, status: .committed, text: "hello", createdAt: now)
        #expect(throws: MiraError.self) { try ContextBuilder.build(execution: execution, conversations: [conversation], workspaces: [workspace, other], messages: [message], executions: [execution]) }
        workspace.allowsRemoteSend = true
        let request = try ContextBuilder.build(execution: execution, conversations: [conversation], workspaces: [workspace, other], messages: [message], executions: [execution])
        #expect(request.system.contains("ONLY THIS BACKGROUND"))
        #expect(!request.system.contains("MUST NOT LEAK"))
        message.text = String(repeating: "中", count: 20_000)
        #expect(throws: MiraError.self) { try ContextBuilder.build(execution: execution, conversations: [conversation], workspaces: [workspace], messages: [message], executions: [execution]) }
    }
}
