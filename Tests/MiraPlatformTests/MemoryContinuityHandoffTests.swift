import Foundation
import MiraCore
import XCTest

final class MemoryContinuityHandoffTests: XCTestCase {
    func testSettledHandoffWithFreshProcessAndExactSourcePasses() {
        let identity = makeIdentity()
        let report = settledReport(identity: identity)

        XCTAssertTrue(handoffFailures(report: report, identity: identity).isEmpty)
    }

    func testHandoffRequiresAChangedProcessIDAndInstanceToken() {
        let identity = makeIdentity()
        let report = settledReport(identity: identity)

        XCTAssertTrue(handoffFailures(report: report, identity: identity, processID: 101).contains("handoff_requires_new_process"))
        XCTAssertTrue(handoffFailures(report: report, identity: identity, processInstanceID: "prior-instance").contains("handoff_requires_new_process"))
    }

    func testHandoffRejectsIdentityOrMarkerMismatch() {
        let identity = makeIdentity()
        let report = settledReport(identity: identity)
        let changedIdentity = makeIdentity(caseID: "different-case")
        let changedSourceRequest = makeIdentity(asksForSource: true)

        XCTAssertTrue(handoffFailures(report: report, identity: changedIdentity).contains("handoff_identity_mismatch"))
        XCTAssertTrue(handoffFailures(report: report, identity: identity, marker: changedIdentity).contains("handoff_identity_mismatch"))
        XCTAssertTrue(handoffFailures(report: report, identity: changedSourceRequest).contains("handoff_identity_mismatch"))
    }

    func testHandoffRejectsFailedUnfinishedOrUnsettledReports() {
        let identity = makeIdentity()
        let variants: [(String, (inout MemoryContinuityReport) -> Void)] = [
            ("failed status", { $0.status = "failed" }),
            ("unfinished status", { $0.status = "running" }),
            ("missing finish", { $0.finishedAt = nil }),
            ("close not settled", { $0.closeSettled = false }),
            ("missing execution", { $0.execution = nil }),
            ("missing route", { $0.route = nil }),
            ("failed extraction", {
                $0.extraction = .init(jobID: "job-1", sourceExecutionID: $0.execution?.executionID,
                                      status: "failed", errorCode: "synthetic_failure",
                                      memoryCount: 0, candidateCount: 0, attempts: [])
            }),
            ("approval denied", { $0.approvalDenialCount = 1 }),
            ("error recorded", { $0.errorCode = "synthetic_failure" })
        ]

        for (label, change) in variants {
            var report = settledReport(identity: identity)
            change(&report)
            let failures = handoffFailures(report: report, identity: identity)
            XCTAssertTrue(failures.contains("handoff_not_settled"), "Expected \(label) to reject: \(failures)")
        }
    }

    func testHandoffRejectsMissingOrInvalidMemorySource() {
        let identity = makeIdentity()
        let report = settledReport(identity: identity)

        var missing = report
        missing.after = nil
        XCTAssertTrue(handoffFailures(report: missing, identity: identity).contains("establishment_memory_count_mismatch"))

        var invalid = report
        invalid.after = [memory(sourceExecutionID: "other-execution", sourceReference: report.execution!.sourceReference)]
        XCTAssertTrue(handoffFailures(report: invalid, identity: identity).contains("establishment_source_evidence_mismatch"))

        invalid.after = [memory(sourceExecutionID: report.execution!.executionID,
                                sourceReference: report.execution!.sourceReference, body: nil)]
        XCTAssertTrue(handoffFailures(report: invalid, identity: identity).contains("establishment_memory_body_unavailable"))
    }

    func testHandoffBudgetRejectsOutOfRangeAndCumulativeAuthorizationUse() {
        let identity = makeIdentity()

        let cases: [(String, MemoryContinuityReport, Int)] = [
            ("recall cap too high", settledReport(identity: identity), 9),
            ("prior cap too high", settledReport(identity: identity, requestAuthorizationCap: 7), 1),
            ("prior count too high", settledReport(identity: identity, requestAuthorizationCount: 7), 1),
            ("cumulative cap exceeded", settledReport(identity: identity, requestAuthorizationCap: 6,
                                                       requestAuthorizationCount: 6), 3)
        ]

        for (label, report, recallCap) in cases {
            let failures = handoffFailures(report: report, identity: identity, recallAuthorizationCap: recallCap)
            XCTAssertTrue(failures.contains("handoff_budget_exceeded"), "Expected \(label) to reject: \(failures)")
        }
    }

    func testValidExplicitReceiptRequiresCommittedWriteAndContinuation() {
        let fixture = receiptFixture()

        XCTAssertTrue(MemoryContinuityReceipt.failures(execution: fixture.execution, memory: fixture.memory).isEmpty)
    }

    func testExplicitReceiptRejectsMissingForeignOrWrongRevisionReceipt() {
        let base = receiptFixture()
        let invalid: [(String, MemoryContinuityExecution)] = [
            ("missing receipt", replacingTool(in: base.execution, clearReceipt: true)),
            ("foreign receipt", replacingTool(in: base.execution,
                                               receipt: receipt(invocationID: UUID(uuidString: "00000000-0000-0000-0000-0000000000ff")!))),
            ("wrong revision", replacingTool(in: base.execution,
                                              result: .object(["memory_id": .string(base.memory.id),
                                                               "revision": .number(2),
                                                               "state": .string("active"),
                                                               "allows_remote_use": .bool(true),
                                                               "policy": .string("remote_allowed")])))
        ]

        for (label, execution) in invalid {
            let failures = MemoryContinuityReceipt.failures(execution: execution, memory: base.memory)
            XCTAssertFalse(failures.isEmpty, "Expected \(label) to reject")
        }
    }

    func testExplicitReceiptRejectsRefusedWriteAndPreToolOnlyAnswer() {
        let base = receiptFixture()

        let refused = replacingTool(in: base.execution, status: "denied", clearReceipt: true)
        XCTAssertFalse(MemoryContinuityReceipt.failures(execution: refused, memory: base.memory).isEmpty)

        let preToolOnly = replacingRounds(in: base.execution, rounds: [
            .init(attemptID: base.attemptID, sequence: 1, visibleText: "I will remember that.")
        ])
        XCTAssertFalse(MemoryContinuityReceipt.failures(execution: preToolOnly, memory: base.memory).isEmpty)
    }

    func testExplicitReceiptRejectsInvalidReceiptDigest() {
        let fixture = receiptFixture()
        let invalid = replacingTool(in: fixture.execution,
                                    receipt: receipt(invocationID: fixture.toolID, intentDigest: "not-a-digest"))

        XCTAssertEqual(MemoryContinuityReceipt.failures(execution: invalid, memory: fixture.memory),
                       ["explicit_save_invalid_receipt_digest"])
    }

    private func handoffFailures(
        report: MemoryContinuityReport,
        identity: MemoryContinuityIdentity,
        marker: MemoryContinuityIdentity? = nil,
        processID: Int32 = 202,
        processInstanceID: String = "current-instance",
        recallAuthorizationCap: Int = 3
    ) -> [String] {
        MemoryContinuityHandoff.failures(
            prior: report, identity: identity, marker: marker ?? identity,
            currentProcessID: processID, currentProcessInstanceID: processInstanceID,
            recallAuthorizationCap: recallAuthorizationCap)
    }

    private func settledReport(
        identity: MemoryContinuityIdentity,
        requestAuthorizationCap: Int = 3,
        requestAuthorizationCount: Int = 0
    ) -> MemoryContinuityReport {
        let execution = handoffExecution()
        var report = MemoryContinuityReport(identity: identity, phase: .establish,
                                             processID: 101, processInstanceID: "prior-instance",
                                             requestAuthorizationCap: requestAuthorizationCap)
        report.status = "completed"
        report.requestAuthorizationCount = requestAuthorizationCount
        report.closeSettled = true
        report.finishedAt = Date(timeIntervalSince1970: 1_000)
        report.route = route()
        report.execution = execution
        report.extraction = .init(jobID: "job-1", sourceExecutionID: execution.executionID,
                                  status: "completed", errorCode: nil, memoryCount: 1,
                                  candidateCount: 1, attempts: [])
        report.after = [memory(sourceExecutionID: execution.executionID,
                               sourceReference: execution.sourceReference)]
        report.afterMaterial = .object(["fixture": .bool(true)])
        return report
    }

    private func handoffExecution() -> MemoryContinuityExecution {
        .init(sessionID: "session-1", executionID: "execution-1", input: "I prefer tea.",
              answer: "Understood.", sourceReference: sourceReference,
              memoryReferences: [], rounds: [], tools: [], usage: [])
    }

    private func makeIdentity(caseID: String = "ordinary-en", asksForSource: Bool = false) -> MemoryContinuityIdentity {
        let object: [String: Any] = [
            "runID": "00000000-0000-0000-0000-000000000001", "caseID": caseID,
            "language": "en", "mode": "automatic", "input": "I prefer tea.",
            "followUp": "What do I prefer?", "root": "/tmp/Mira-Continuity-fixture",
            "asksForSource": asksForSource,
            "providerID": "synthetic", "modelID": "synthetic-model", "endpoint": "http://127.0.0.1:1",
            "protocolID": "openai.responses", "contextWindow": 4096, "outputTokens": 128,
            "embeddings": "offline", "instructions": ConversationInstructions.default
        ]
        return try! JSONDecoder().decode(MemoryContinuityIdentity.self,
                                         from: JSONSerialization.data(withJSONObject: object))
    }

    private let sourceReference = "session:session-1/execution:execution-1/message:message-1/admission:admission-1@1"

    private func memory(sourceExecutionID: String, sourceReference: String, body: String? = "I prefer tea.") -> StateEvolutionMemorySnapshot {
        .init(id: "memory-1", revision: 1, state: "active", lifecycle: "active", isCurrent: true,
              body: body, origin: "observedUserStatement", authority: "observedUser", forgottenAt: nil,
              supersededByID: nil, evidenceSourceReferences: [sourceReference],
              evidenceExecutionIDs: [sourceExecutionID], revisionNumbers: [1], previousMemoryIDs: [],
              evidenceCount: 1, evidenceExcerptCount: 1, evidenceHashCount: 1, revisionBodyCount: 1,
              detailAvailable: true, detailErrorCode: nil, retraction: nil)
    }

    private func route() -> AgentModelRoute {
        .init(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
              modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1,
              adapter: .init(id: "synthetic.model", revision: 1), invocationID: "synthetic-invocation",
              invocationRevision: 1, endpointID: "synthetic-endpoint", modelID: "synthetic-model",
              credential: nil, contextWindow: 4096, maximumOutputTokens: 128,
              capabilities: .init(streamsText: true, callsTools: true, producesThinking: false),
              configuration: .object([:]))
    }

    private struct ReceiptFixture {
        let execution: MemoryContinuityExecution
        let memory: StateEvolutionMemorySnapshot
        let attemptID: UUID
        let toolID: UUID
    }

    private func receiptFixture() -> ReceiptFixture {
        let attemptID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let toolID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let memory = memory(sourceExecutionID: "execution-explicit", sourceReference: sourceReference)
        let result = JSONValue.object(["memory_id": .string(memory.id), "revision": .number(1),
                                       "state": .string("active"), "allows_remote_use": .bool(true),
                                       "policy": .string("remote_allowed")])
        let tool = MemoryContinuityTool(id: toolID, attemptID: attemptID, name: "memory.remember",
                                        status: "succeeded", receipt: receipt(invocationID: toolID), result: result)
        let execution = MemoryContinuityExecution(
            sessionID: "session-explicit", executionID: "execution-explicit", input: "Remember that I prefer tea.",
            answer: "I will remember that.", sourceReference: sourceReference, memoryReferences: [],
            rounds: [.init(attemptID: attemptID, sequence: 1, visibleText: nil),
                     .init(attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!, sequence: 2,
                           visibleText: "I will remember that.")],
            tools: [tool], usage: [])
        return .init(execution: execution, memory: memory, attemptID: attemptID, toolID: toolID)
    }

    private func receipt(
        invocationID: UUID,
        intentDigest: String = String(repeating: "a", count: 64),
        resultDigest: String = String(repeating: "b", count: 64)
    ) -> AgentBusinessReceiptReference {
        .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!, invocationID: invocationID,
              authorization: .init(libraryID: UUID(uuidString: "00000000-0000-0000-0000-000000000015")!, epoch: 1),
              intentDigest: intentDigest, resultDigest: resultDigest)
    }

    private func replacingTool(
        in execution: MemoryContinuityExecution,
        status: String? = nil,
        receipt: AgentBusinessReceiptReference? = nil,
        result: JSONValue? = nil,
        clearReceipt: Bool = false
    ) -> MemoryContinuityExecution {
        var tools = execution.tools
        let current = tools[0]
        tools[0] = .init(id: current.id, attemptID: current.attemptID, name: current.name,
                          status: status ?? current.status,
                          receipt: clearReceipt ? nil : (receipt ?? current.receipt), result: result ?? current.result)
        return .init(sessionID: execution.sessionID, executionID: execution.executionID, input: execution.input,
                     answer: execution.answer, sourceReference: execution.sourceReference,
                     memoryReferences: execution.memoryReferences, rounds: execution.rounds,
                     tools: tools, usage: execution.usage)
    }

    private func replacingRounds(in execution: MemoryContinuityExecution, rounds: [MemoryContinuityRound]) -> MemoryContinuityExecution {
        .init(sessionID: execution.sessionID, executionID: execution.executionID, input: execution.input,
              answer: execution.answer, sourceReference: execution.sourceReference,
              memoryReferences: execution.memoryReferences, rounds: rounds,
              tools: execution.tools, usage: execution.usage)
    }
}
