import Foundation
import GRDB
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Session activity query", .timeLimit(.minutes(1)))
struct SessionActivityTests {
    @Test func mapsToolLifecycleStates() {
        let sessionID = ConversationID()
        let call = SessionPayloadReference(
            id: UUID(), sessionID: sessionID, batchID: UUID(), retentionGroup: UUID(),
            kind: .toolCall, byteCount: 2, digest: String(repeating: "0", count: 64))
        let invocation = SessionInvocation(
            id: UUID(), attemptID: UUID(), modelOrder: 0, toolName: "fixture.tool",
            effect: .read, call: call)
        var queued = SessionInvocationState(invocation: invocation)
        #expect(SessionActivityReader.status(of: queued) == .queued)

        queued.approval = .init(expiresAt: Date(timeIntervalSince1970: 10_000))
        #expect(SessionActivityReader.status(of: queued) == .waitingForApproval)
        queued.approval?.approved = true
        queued.dispatchedAt = Date(timeIntervalSince1970: 10_001)
        #expect(SessionActivityReader.status(of: queued) == .running)
        queued.resolution = .init(invocationID: invocation.id, status: .succeeded)
        #expect(SessionActivityReader.status(of: queued) == .succeeded)

        queued.resolution = .init(invocationID: invocation.id, status: .failed)
        #expect(SessionActivityReader.status(of: queued) == .failed)
        queued.resolution = .init(invocationID: invocation.id, status: .interrupted)
        #expect(SessionActivityReader.status(of: queued) == .stopped)
    }

    @Test func returnsOrderedModelRoundsAndFullToolPayloads() async throws {
        let arguments = try taskArguments(quote: "Question").jsonString()
        let rounds: [[AgentModelStreamEvent]] = (0..<9).map { index in
            let call = CanonicalToolCall(id: "task-\(index)", name: "task.change", arguments: arguments)
            return [.blockStarted(.init(id: "thinking-\(index)", content: .thinking("Plan \(index)"))),
                    .blockFinished(id: "thinking-\(index)"),
                    .blockStarted(.init(id: "text-\(index)", content: .text("Round \(index)"))),
                    .blockFinished(id: "text-\(index)")] + modelToolStream([call])
        } + [[.blockStarted(.init(id: "final", content: .text("Done"))),
               .blockFinished(id: "final"), .finished(.stop)]]
        try await withTaskWorkflow(outputs: rounds) { fixture in
            let address = try await fixture.run("Question")
            try await withActivity(fixture) { query in
                let values = try await query.executionActivities(
                    sessionID: address.sessionID, executionIDs: [address.executionID])
                let steps = try #require(values[address.executionID])
                #expect(steps.count == 10)
                #expect(steps.dropLast().allSatisfy { $0.blocks.map(\.id).count == 3 })
                #expect(steps.dropLast().allSatisfy { $0.blocks.map(\.id).dropLast() == ["thinking-\($0.stepIndex - 1)", "text-\($0.stepIndex - 1)"] })
                #expect(steps.last?.blocks.map(\.id) == ["final"])
                let tools = steps.flatMap(\.blocks).compactMap { block -> SessionToolActivity? in
                    guard case .tool(let value) = block.content else { return nil }
                    return value
                }
                #expect(tools.count == 9)
                #expect(tools.allSatisfy { $0.status == .succeeded })
                guard case .available(let arguments) = try #require(tools.first).arguments,
                      case .available(let result) = try #require(tools.first).result else {
                    Issue.record("Tool arguments or result was not available."); return
                }
                #expect(arguments == (try taskArguments(quote: "Question").jsonString()))
                let state = try await fixture.runtime.sessionSnapshot(id: address.sessionID)
                let reference = try #require(state.invocations[tools[0].id]?.resolution?.result)
                let original = try SessionCodec.decode(JSONValue.self, from: await fixture.library.read(reference))
                #expect(result == (try original.jsonString()))
                #expect(tools.allSatisfy { $0.arguments.text == arguments && $0.result.text != nil })
            }
        }
    }

    @Test func invalidatedExecutionReturnsNoContent() async throws {
        try await withTaskWorkflow(outputs: try taskReplies(taskArguments(quote: "Question"))) { fixture in
            let address = try await fixture.run("Question")
            let runtime = try await SessionRuntime.open(id: address.sessionID, journal: fixture.library, payloads: fixture.library)
            let state = await runtime.snapshot()
            let groups = state.privacyGroups(for: [address.executionID], retention: .purgeGeneratedHistory)
            try taskRequireCommitted(await runtime.commit(id: UUID()) { _ in
                [.invalidated(.init(operationID: UUID(), executionIDs: [address.executionID],
                                     retentionGroups: groups, authorizationEpoch: 1, reason: .forgotten))]
            })
            try await fixture.library.purge(sessionID: address.sessionID, retentionGroups: groups)
            await runtime.close()
            try await withActivity(fixture) { query in
                let values = try await query.executionActivities(
                    sessionID: address.sessionID, executionIDs: [address.executionID])
                #expect(values[address.executionID]?.isEmpty == true)
            }
        }
    }

    @Test func retainedDraftKeepsOrderedPartialBlocksAndStableIDs() async throws {
        let call = CanonicalToolCall(id: "pending", name: "task.change", arguments: "{\"operation\":\"create\"}")
        try await withTaskWorkflow(outputs: [[
            .blockStarted(.init(id: "thought", content: .thinking("Plan"))),
            .blockStarted(.init(id: "answer", content: .text("Partial"))),
            .blockStarted(.init(id: "tool", content: .toolCall(call))),
            .blockFinished(id: "thought"), .blockFinished(id: "answer"),
            .blockFinished(id: "tool"), .finished(.toolCalls)
        ]], thinkingEnabled: true) { fixture in
            await fixture.model.holdStream(number: 1, afterEvents: 4)
            let sessionID = ConversationID(), executionID = ExecutionID()
            let command = AgentSubmitCommand(id: UUID(), sessionID: sessionID, executionID: executionID,
                input: .message(id: MessageID(), text: "Question", timeZoneIdentifier: "Asia/Shanghai"),
                options: .init(instructions: "Use the available task tools.", route: fixture.route),
                opening: .init(title: "Synthetic task workflow", workspaceID: nil))
            try taskRequireCommitted(await fixture.runtime.submit(command))
            let address = AgentExecutionAddress(sessionID: sessionID, executionID: executionID)
            do {
                try await taskEventually { await fixture.model.streamHeld }
                try await taskEventually {
                    let state = try await fixture.runtime.sessionSnapshot(id: sessionID)
                    return try await fixture.library.activeDraft(sessionID: sessionID) != nil
                }
                try await withActivity(fixture) { query in
                    let first = try await query.executionActivities(sessionID: address.sessionID, executionIDs: [address.executionID])
                    let second = try await query.executionActivities(sessionID: address.sessionID, executionIDs: [address.executionID])
                    let firstIDs = first[address.executionID]?.flatMap(\.blocks).map(\.id)
                    #expect(firstIDs == second[address.executionID]?.flatMap(\.blocks).map(\.id))
                    #expect(firstIDs == ["thought", "answer", "tool"])
                    let blocks = try #require(first[address.executionID]?.first?.blocks)
                    #expect(blocks[0].content == .thinking(.available("Plan")))
                    #expect(blocks[1].content == .text(.available("Partial")))
                    guard case .tool(let pending) = blocks[2].content else { Issue.record("Missing pending tool"); return }
                    #expect(pending.arguments == .available(call.arguments))
                    #expect(pending.status == .queued && pending.result == .absent)
                }
            } catch {
                await fixture.model.releaseStream()
                throw error
            }
            await fixture.model.releaseStream()
            try taskRequireCommitted(await fixture.runtime.waitForExecution(id: address.executionID, sessionID: address.sessionID))
        }
    }

    @Test func byteBudgetReturnsAbsentWithoutReadingOversizedPreview() async throws {
        try await withTaskWorkflow(outputs: try taskReplies(taskArguments(quote: "Question"))) { fixture in
            let address = try await fixture.run("Question")
            let probe = ActivityPayloadProbe(base: fixture.library)
            try await withActivity(fixture, reader: probe, maximumPageBytes: 1) { query in
                let values = try await query.executionActivities(
                    sessionID: address.sessionID, executionIDs: [address.executionID])
                let blocks = values[address.executionID]?.flatMap(\.blocks) ?? []
                #expect(blocks.contains { block in
                    if case .tool(let tool) = block.content {
                        return tool.arguments == .absent || tool.result == .absent
                    }
                    return false
                })
                #expect(await probe.references.isEmpty)
            }
        }
    }

    private func withActivity(
        _ fixture: TaskWorkflowFixture,
        reader: (any SessionPayloadReader)? = nil,
        maximumPageBytes: Int = 64 * 1_024 * 1_024,
        _ body: (SessionQueryService) async throws -> Void
    ) async throws {
        let projection = try SQLiteSessionProjection(
            path: fixture.directory.appendingPathComponent("activity-\(UUID()).sqlite").path)
        let query = try SessionQueryService(
            journal: fixture.library, payloads: reader ?? fixture.library, projection: projection,
            access: fixture.access, scope: fixture.scope, maximumPageBytes: maximumPageBytes)
        do {
            try await body(query)
            await query.close()
            try await projection.close()
        } catch {
            await query.close()
            try? await projection.close()
            throw error
        }
    }
}

private actor ActivityPayloadProbe: SessionPayloadReader {
    let base: any SessionPayloadReader
    private(set) var references: [SessionPayloadReference] = []

    init(base: any SessionPayloadReader) { self.base = base }

    func read(_ reference: SessionPayloadReference) async throws -> Data {
        references.append(reference)
        return try await base.read(reference)
    }
}
