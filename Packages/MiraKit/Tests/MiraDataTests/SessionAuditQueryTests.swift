import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Session audit query", .timeLimit(.minutes(1)))
struct SessionAuditQueryTests {
    @Test func completedAttemptReturnsFrozenPlanRequestOutputAndThinking() async throws {
        try await withTaskWorkflow(outputs: [[
            .blockStarted(.init(id: "text", content: .text("Answer"))),
            .blockFinished(id: "text"),
            .blockStarted(.init(id: "thinking", content: .thinking("Private plan"))),
            .blockFinished(id: "thinking"),
            .finished(.stop)
        ]], thinkingEnabled: true) { fixture in
            let address = try await fixture.run("Question")
            let expectedSnapshot = try await JournalSessionReader(
                journal: fixture.library, payloads: fixture.library
            ).snapshot(sessionID: address.sessionID)
            let expectedAttempt = try #require(expectedSnapshot.state.attempts.values.first {
                $0.attempt.executionID == address.executionID
            })
            try await withAudit(fixture) { query in
                let page = try await query.executionAudit(sessionID: address.sessionID, executionID: address.executionID)
                #expect(page.head == expectedSnapshot.head)
                #expect(page.execution.id == address.executionID)
                #expect(page.workspaceID == nil)
                guard case .available(let plan) = page.plan else { Issue.record("The execution plan was not available."); return }
                #expect(plan.route == fixture.route)
                #expect(page.attempts.count == 1)
                #expect(page.modelUsage.count == 1)
                #expect(page.modelUsage.first?.id == expectedAttempt.attempt.id)
                #expect(page.modelUsage.first?.isComplete == true)
                let attempt = try #require(page.attempts.first)
                #expect(attempt.sequence == expectedAttempt.sequence)
                #expect(attempt.startedAt == expectedAttempt.startedAt)
                guard case .available(let build) = attempt.request,
                      case .available(let output) = attempt.output else {
                    Issue.record("The request or model output was not available."); return
                }
                #expect(build.request.executionID == address.executionID)
                #expect(output.text == "Answer")
                #expect(output.thinkingText == "Private plan")
                #expect(attempt.invocations.isEmpty)
            }
        }
    }

    @Test func toolAttemptReturnsOrderedInvocationCallProposalAndResult() async throws {
        let arguments = taskArguments(quote: "Question")
        try await withTaskWorkflow(outputs: try taskReplies(arguments)) { fixture in
            let address = try await fixture.run("Question")
            try await withAudit(fixture) { query in
                let page = try await query.executionAudit(sessionID: address.sessionID, executionID: address.executionID)
                let attempt = try #require(page.attempts.first(where: { !$0.invocations.isEmpty }))
                #expect(attempt.invocations.count == 1)
                let invocation = try #require(attempt.invocations.first)
                #expect(invocation.id == invocation.state.invocation.id)
                guard case .available(let call) = invocation.call,
                      case .available(let proposal) = invocation.proposal,
                      case .available(let result) = invocation.result else {
                    Issue.record("The tool audit payloads were not available."); return
                }
                #expect(call.name == "task.change")
                #expect(proposal.effect == .localWrite)
                #expect(proposal.callDigest == invocation.state.invocation.call.digest)
                #expect(result != .null)
            }
        }
    }

    @Test func toolAuditPaginatesAttemptsAtCommittedStartSequence() async throws {
        let arguments = taskArguments(quote: "Question")
        try await withTaskWorkflow(outputs: try taskReplies(arguments)) { fixture in
            let address = try await fixture.run("Question")
            try await withAudit(fixture) { query in
                let firstPage = try await query.executionAudit(
                    sessionID: address.sessionID, executionID: address.executionID, limit: 1)
                let first = try #require(firstPage.attempts.first)
                #expect(firstPage.hasMore)
                #expect(first.invocations.isEmpty)
                let secondPage = try await query.executionAudit(
                    sessionID: address.sessionID, executionID: address.executionID,
                    beforeSequence: first.sequence, limit: 1)
                let second = try #require(secondPage.attempts.first)
                #expect(second.sequence < first.sequence)
                #expect(!secondPage.hasMore)
                #expect(second.invocations.count == 1)
                #expect(firstPage.modelUsage.count == 2)
                #expect(secondPage.modelUsage == firstPage.modelUsage)
                #expect(Set(firstPage.modelUsage.map(\.id)) == [first.id, second.id])
                #expect(firstPage.modelUsage.allSatisfy { $0.isComplete })
            }
        }
    }

    @Test func failedAttemptExposesTypedFailureAfterRetry() async throws {
        try await withTaskWorkflow(outputs: [[], [.blockStarted(.init(id: "text", content: .text("Recovered"))), .blockFinished(id: "text"), .finished(.stop)]]) { fixture in
            let original = try await fixture.run("Question", expectedStatus: .failed)
            try await withAudit(fixture) { query in
                let page = try await query.executionAudit(sessionID: original.sessionID, executionID: original.executionID)
                let failed = try #require(page.attempts.first)
                guard case .available(let record) = failed.failure else {
                    Issue.record("The failed attempt did not expose its typed failure record."); return
                }
                #expect(record.receivedStreamEvents == false)
                #expect(record.failure.error.code == .malformedStream)
            }
            let retryID = ExecutionID()
            let command = AgentSubmitCommand(
                id: UUID(), sessionID: original.sessionID, executionID: retryID,
                input: .retry(executionID: original.executionID),
                options: .init(instructions: "Retry", route: fixture.route))
            try taskRequireCommitted(await fixture.runtime.submit(command))
            try taskRequireCommitted(await fixture.runtime.waitForExecution(id: retryID, sessionID: original.sessionID))
            try await withAudit(fixture) { query in
                let newest = try await query.executionAudit(sessionID: original.sessionID, executionID: retryID, limit: 1)
                let retry = try #require(newest.attempts.first)
                #expect(retry.attempt.attemptIndex == 1)
                #expect(newest.hasMore == false)

                let originalPage = try await query.executionAudit(
                    sessionID: original.sessionID, executionID: original.executionID)
                let failed = try #require(originalPage.attempts.first)
                #expect(failed.failure != .absent)
                #expect(failed.request != .absent)
                #expect(originalPage.modelUsage.count == 1)
                #expect(originalPage.modelUsage.first?.isComplete == false)
                #expect(newest.modelUsage.count == 1)
                #expect(newest.modelUsage.first?.isComplete == true)
                #expect(newest.modelUsage.first?.id != originalPage.modelUsage.first?.id)
            }
        }
    }

    @Test func auditBudgetRejectsBeforeReadingPayloadBytes() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Answer"))), .blockFinished(id: "text"), .finished(.stop)]]) { fixture in
            let address = try await fixture.run("Question")
            let probe = AuditPayloadProbe(base: fixture.library)
            try await withAudit(fixture, reader: probe, maximumPageBytes: 1) { query in
                await #expect(throws: MiraError(.outputLimit, "The session audit exceeds its content limit.")) {
                    try await query.executionAudit(sessionID: address.sessionID, executionID: address.executionID)
                }
                #expect(await probe.references.isEmpty)
            }
        }
    }

    @Test func localExecutionHasPlanButNoModelAttempts() async throws {
        try await withTaskWorkflow { fixture in
            let sessionID = ConversationID()
            let executionID = ExecutionID()
            let local = try await SessionRuntime.open(id: sessionID, journal: fixture.library, payloads: fixture.library)
            do {
                let plan = AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 1, driverID: "local",
                    driverRevision: 1, instructions: "", limits: .init(), priority: .foreground, route: nil)
                try taskRequireCommitted(await local.commit(id: UUID()) { context in
                    let title = try await context.stageBytes(Data("Local".utf8), kind: .title)
                    let user = try await context.stageBytes(Data("Local command".utf8), kind: .userText)
                    let planReference = try await context.stageBytes(try SessionCodec.encode(plan), kind: .executionPlan)
                    return [.opened(.init(workspaceID: nil, title: title)),
                            .admitted(.init(executionID: executionID, userMessageID: MessageID(), userBody: user,
                                plan: planReference, hasModelRoute: false, authorizationEpoch: 0,
                                timeZoneIdentifier: "UTC"))]
                })
                try await withAudit(fixture) { query in
                    let page = try await query.executionAudit(sessionID: sessionID, executionID: executionID)
                    #expect(page.execution.id == executionID)
                    #expect(page.attempts.isEmpty)
                    #expect(page.modelUsage.isEmpty)
                    guard case .available(let decoded) = page.plan else { Issue.record("Local plan was not readable."); return }
                    #expect(decoded.route == nil)
                }
                await local.close()
            } catch {
                await local.close()
                throw error
            }
        }
    }

    private func withAudit(
        _ fixture: TaskWorkflowFixture, reader: (any SessionContentReader)? = nil,
        maximumPageBytes: Int = 64 * 1_024 * 1_024,
        _ body: (SessionQueryService) async throws -> Void
    ) async throws {
        let projection = try SQLiteSessionProjection(
            path: fixture.directory.appendingPathComponent("audit-\(UUID()).sqlite").path)
        let query: SessionQueryService
        do {
            query = try SessionQueryService(
                journal: fixture.library, payloads: reader ?? fixture.library,
                projection: projection, access: fixture.access, scope: fixture.scope,
                maximumPageBytes: maximumPageBytes)
        } catch {
            try? await projection.close()
            throw error
        }
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

private actor AuditPayloadProbe: SessionContentReader {
    let base: any SessionContentReader
    private(set) var references: [SessionContent] = []
    private var corruptOutput = false

    init(base: any SessionContentReader) { self.base = base }

    func corruptModelOutput() { corruptOutput = true }

    func read(_ reference: SessionContent) async throws -> Data {
        references.append(reference)
        if corruptOutput, reference.kind == .modelOutput {
            return Data(repeating: 0xFF, count: reference.byteCount)
        }
        return try await base.read(reference)
    }
}
