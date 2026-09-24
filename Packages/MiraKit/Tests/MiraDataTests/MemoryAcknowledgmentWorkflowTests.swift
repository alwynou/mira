import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

/// Scripted replies verify instruction delivery, receipt evidence and verbatim output.
/// They do not measure a model's semantic compliance with the instructions.
@Suite("Memory save acknowledgment workflow", .timeLimit(.minutes(1)))
struct MemoryAcknowledgmentWorkflowTests {
    @Test(arguments: [
        "I like quiet mornings.",
        "我喜欢安静的早晨。" // i18n-fixture: Chinese ordinary statement exercises the same no-save path.
    ])
    func ordinaryStatementsPersistNoMemoryAndVerbatimReply(text: String) async throws {
        let reply = text.hasPrefix("我") ? "明白了，我会在当前对话中记住这一点。" : "Understood; I’ll use that in this conversation." // i18n-fixture: Chinese reply preserves verbatim model output coverage.
        try await withTaskWorkflow(outputs: [replyStream(reply)], memoryEnabled: true) { fixture in
            let address = try await fixture.run(text, instructions: ConversationInstructions.default)
            let state = try await fixture.runtime.sessionSnapshot(id: address.sessionID)
            let execution = try #require(state.executions[address.executionID])
            #expect(execution.completion?.status == .completed)
            #expect(try answerText(execution.completion?.answer) == reply)
            #expect(await fixture.model.inputs.count == 1)
            let input = try #require(await fixture.model.inputs.first)
            expectDefaultInstructionAnchors(input.instructions)
            #expect(input.instructions == ConversationInstructions.default)
            #expect(input.messages.flatMap(\.toolCalls).isEmpty)
            #expect(try await fixture.memory?.memoryList(workspaceID: nil, states: [.active], query: "", limit: 10).memories.isEmpty == true)
            #expect(try await fixture.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM business_receipts") } == 0)
        }
    }

    @Test(arguments: [false, true])
    func explicitStandardAndSensitiveSavesCommitReceiptBeforeReply(isSensitive: Bool) async throws {
        let content = isSensitive ? "My passport is kept in the blue folder." : "I prefer jasmine tea."
        let text = "Remember this: \(content)"
        let scope = isSensitive ? "global" : "current"
        let call = try rememberCall(id: isSensitive ? "sensitive-save" : "standard-save", content: content,
                                    quote: content, scope: scope, sensitive: isSensitive)
        let reply = isSensitive ? "Saved locally only." : "Saved for this workspace."
        try await withTaskWorkflow(outputs: [modelToolStream([call]), replyStream(reply)], memoryEnabled: true) { fixture in
            var workspaceID: WorkspaceID?
            if !isSensitive {
                let workspace = Workspace(id: .init(), name: "Acknowledgment workspace")
                let lease = try await fixture.access.acquire(in: fixture.scope)
                try await fixture.workspaces.saveWorkspace(workspace, expectedRevision: nil, authorization: lease.authorization)
                await lease.release()
                workspaceID = workspace.id
            }
            let address = try await fixture.run(text, workspaceID: workspaceID, instructions: ConversationInstructions.default)
            let state = try await fixture.runtime.sessionSnapshot(id: address.sessionID)
            let invocation = try #require(state.invocations.values.first(where: { $0.invocation.toolName == "memory.remember" }))
            let resolution = try #require(invocation.resolution)
            #expect(resolution.status == .succeeded)
            let receipt = try #require(resolution.businessReceipt)
            #expect(receipt.invocationID == invocation.invocation.id)
            let resultReference = try #require(resolution.result)
            let result = try SessionCodec.decode(JSONValue.self, from: resultReference.bytes)
            #expect(result["state"] == .string("active"))
            #expect(result["allows_remote_use"] == .bool(!isSensitive))
            #expect(result["policy"] == .string(isSensitive ? "local_only" : "remote_allowed"))
            #expect(try answerText(state.executions[address.executionID]?.completion?.answer) == reply)

            let inputs = await fixture.model.inputs
            #expect(inputs.count == 2)
            let continuation = try #require(inputs[1].messages.flatMap(\.toolResults).first(where: { $0.callID == call.id }))
            let observation = try #require(try? SessionCodec.decode(JSONValue.self, from: Data(continuation.text.utf8)))
            #expect(observation["status"] == .string("succeeded"))
            #expect(observation["content"] == result)
            #expect(inputs[1].instructions == ConversationInstructions.default)

            let memoryID = MemoryID(try #require(result["memory_id"]?.stringValue.flatMap(UUID.init(uuidString:))))
            let store = try #require(fixture.memory)
            let memory = try await store.memoryDetail(memoryID, workspaceID: workspaceID).memory
            #expect(memory.draft?.content == content)
            #expect(memory.draft?.sensitivity == (isSensitive ? .sensitive : .standard))
            #expect(memory.draft?.allowsRemoteUse == !isSensitive)
            #expect(memory.scope == (isSensitive ? .global : .workspace(try #require(workspaceID))))
        }
    }

    @Test func failedDatabaseWriteProducesFailedObservationWithoutMemory() async throws {
        let content = "I prefer oolong tea."
        let call = try rememberCall(id: "failed-save", content: content, quote: content)
        try await withTaskWorkflow(outputs: [modelToolStream([call]), replyStream("It was not saved.")], memoryEnabled: true) { fixture in
            try await fixture.database.write {
                try $0.execute(sql: "CREATE TRIGGER reject_memory_receipt BEFORE INSERT ON business_receipts BEGIN SELECT RAISE(ABORT, 'Synthetic failure'); END")
            }
            let address = try await fixture.run("Remember: \(content)", instructions: ConversationInstructions.default)
            let state = try await fixture.runtime.sessionSnapshot(id: address.sessionID)
            let invocation = try #require(state.invocations.values.first)
            let resolution = try #require(invocation.resolution)
            #expect(resolution.status != .succeeded)
            #expect(resolution.businessReceipt == nil)
            #expect(resolution.result == nil)
            let inputs = await fixture.model.inputs
            let observation = try toolObservation(inputs, callID: call.id)
            #expect(observation["status"] == .string(resolution.status.rawValue))
            #expect(observation["content"] == .null)
            #expect(observation["error"] != nil)
            #expect(inputs[1].instructions == ConversationInstructions.default)
            #expect(try answerText(state.executions[address.executionID]?.completion?.answer) == "It was not saved.")
            #expect(try await fixture.memory?.memoryList(workspaceID: nil, states: [.active], query: "", limit: 10).memories.isEmpty == true)
            #expect(try await fixture.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM business_receipts") } == 0)
            #expect(try await fixture.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_operations") } == 0)
        }
    }

    @Test func suppressedSourceProducesDeniedObservationWithoutReceipt() async throws {
        let content = "I prefer rooibos tea."
        let call = try rememberCall(id: "refused-save", content: content, quote: content)
        try await withTaskWorkflow(outputs: [modelToolStream([call]), replyStream("I could not save that.")], memoryEnabled: true) { fixture in
            await fixture.model.holdStream(number: 1, afterEvents: 2)
            do {
                let sessionID = ConversationID(), executionID = ExecutionID()
                let command = AgentSubmitCommand(id: UUID(), sessionID: sessionID, executionID: executionID,
                    input: .message(id: .init(), text: "Remember: \(content)", timeZoneIdentifier: "Asia/Shanghai"),
                    options: .init(instructions: ConversationInstructions.default, route: fixture.route),
                    opening: .init(title: "Synthetic acknowledgment", workspaceID: nil))
                try taskRequireCommitted(await fixture.runtime.submit(command))
                let address = AgentExecutionAddress(sessionID: sessionID, executionID: executionID)
                try await taskEventually { await fixture.model.streamHeld }
                let evidence = try await fixture.evidence(address)
                try await fixture.database.write { db in
                    let source = try SQLiteMemoryStore.resolve(
                        .userMessage(evidence: evidence, excerpt: content),
                        draft: .init(content: "Synthetic suppressed source", scope: .global), in: db)
                    try SQLiteMemoryStore.bindSource(source, in: db)
                    try SQLiteMemoryStore.suppress(.userMessage(evidence.reference), strength: 3, in: db)
                }
                await fixture.model.releaseStream()
                try taskRequireCommitted(await fixture.runtime.waitForExecution(id: executionID, sessionID: sessionID))
                let state = try await fixture.runtime.sessionSnapshot(id: sessionID)
                let invocation = try #require(state.invocations.values.first)
                let resolution = try #require(invocation.resolution)
                #expect(resolution.status == .denied)
                #expect(resolution.businessReceipt == nil)
                #expect(resolution.result == nil)
                let inputs = await fixture.model.inputs
                let observation = try toolObservation(inputs, callID: call.id)
                #expect(observation["status"] == .string("denied"))
                #expect(observation["content"] == .null)
                #expect(observation["error"] != nil)
                #expect(inputs[1].instructions == ConversationInstructions.default)
                #expect(try await fixture.memory?.memoryList(workspaceID: nil, states: [.active], query: "", limit: 10).memories.isEmpty == true)
                #expect(try await fixture.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM business_receipts") } == 0)
            } catch {
                await fixture.model.releaseStream()
                throw error
            }
        }
    }

    @Test func pendingCallHasNoReceiptOrMemoryBeforeSettlement() async throws {
        // Hold an unsettled model call, not an indeterminate business transaction.
        let content = "I prefer mint tea."
        let call = try rememberCall(id: "pending-save", content: content, quote: content)
        try await withTaskWorkflow(outputs: [modelToolStream([call]), replyStream("Saved after commit.")], memoryEnabled: true) { fixture in
            await fixture.model.holdStream(number: 1, afterEvents: 2)
            let run = Task { try await fixture.run("Remember: \(content)", instructions: ConversationInstructions.default) }
            do {
                try await taskEventually { await fixture.model.streamHeld }
                #expect(try await fixture.memory?.memoryList(workspaceID: nil, states: [.active], query: "", limit: 10).memories.isEmpty == true)
                #expect(try await fixture.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM business_receipts") } == 0)
                await fixture.model.releaseStream()
                let address = try await run.value
                let state = try await fixture.runtime.sessionSnapshot(id: address.sessionID)
                let invocation = try #require(state.invocations.values.first)
                #expect(invocation.resolution?.status == .succeeded)
                #expect(invocation.resolution?.businessReceipt != nil)
            } catch {
                await fixture.model.releaseStream()
                _ = try? await run.value
                throw error
            }
        }
    }

    @Test func priorReceiptIsNotBoundToLaterExecution() async throws {
        let first = "I prefer green tea."
        let call = try rememberCall(id: "old-save", content: first, quote: first)
        try await withTaskWorkflow(outputs: [modelToolStream([call]), replyStream("Saved."), replyStream("I understand; I have not saved this new statement.")], memoryEnabled: true) { fixture in
            let firstAddress = try await fixture.run("Remember: \(first)", instructions: ConversationInstructions.default)
            let second = "I also enjoy rainy walks."
            let secondAddress = try await fixture.run(second, sessionID: firstAddress.sessionID, instructions: ConversationInstructions.default)
            let state = try await fixture.runtime.sessionSnapshot(id: secondAddress.sessionID)
            #expect(state.invocations.values.count == 1)
            #expect(state.invocations.values.first?.resolution?.status == .succeeded)
            #expect(state.executions[secondAddress.executionID]?.completion?.status == .completed)
            #expect(try answerText(state.executions[secondAddress.executionID]?.completion?.answer) == "I understand; I have not saved this new statement.")
            #expect(try await fixture.memory?.memoryList(workspaceID: nil, states: [.active], query: "", limit: 10).memories.count == 1)
            let inputs = await fixture.model.inputs
            #expect(inputs.count == 3)
            #expect(inputs[2].messages.last?.role == .user)
            #expect(inputs[2].messages.last?.text == second)
            #expect(inputs[2].instructions == ConversationInstructions.default)
        }
    }
}

private func rememberCall(id: String, content: String, quote: String, scope: String = "global", sensitive: Bool = false) throws -> CanonicalToolCall {
    let arguments: JSONValue = .object([
        "content": .string(content), "quote": .string(quote), "kind": .string("preference"),
        "scope": .string(scope), "sensitive": .bool(sensitive), "enriches": .array([])
    ])
    return try CanonicalToolCall(id: id, name: "memory.remember", arguments: arguments.jsonString())
}

private func replyStream(_ text: String) -> [AgentModelStreamEvent] {
    [.blockStarted(.init(id: "text", content: .text(text))), .blockFinished(id: "text"), .finished(.stop)]
}

private func answerText(_ content: SessionContent?) throws -> String {
    let content = try #require(content)
    return try #require(String(data: content.bytes, encoding: .utf8))
}

private func toolObservation(_ inputs: [AgentModelInput], callID: String) throws -> JSONValue {
    let continuation = try #require(inputs.dropFirst().flatMap { $0.messages.flatMap(\.toolResults) }
        .first(where: { $0.callID == callID }))
    return try SessionCodec.decode(JSONValue.self, from: Data(continuation.text.utf8))
}

private func expectDefaultInstructionAnchors(_ instructions: String) {
    #expect(instructions.contains("Background memory extraction may run later"))
    #expect(instructions.contains("matching memory.remember call returns status succeeded"))
    #expect(instructions.contains("failed or refused result"))
    #expect(instructions.contains("local-only memory"))
    #expect(instructions.contains("Any offer to apply an unsaved preference must be explicitly limited to the current conversation"))
    #expect(instructions.contains(MemoryTools.saveConsolidationGuidance))
}
