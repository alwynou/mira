import Foundation
import GRDB
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Session activity query", .timeLimit(.minutes(1)))
struct SessionActivityTests {
    @Test func mapsToolLifecycleStates() {
        let sessionID = ConversationID()
        let call = SessionContent(id: UUID(), kind: .toolCall, bytes: Data("{}".utf8))
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
        reader: (any SessionContentReader)? = nil,
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

private actor ActivityPayloadProbe: SessionContentReader {
    let base: any SessionContentReader
    private(set) var references: [SessionContent] = []

    init(base: any SessionContentReader) { self.base = base }

    func read(_ reference: SessionContent) async throws -> Data {
        references.append(reference)
        return try await base.read(reference)
    }
}
