import Foundation
import Testing
@testable import MiraCore

struct MemoryApprovalTests {
    @Test func directAuthorizationRequiresAnAnchoredCompletePrefix() {
        #expect(MemoryRememberTool.directIntentMatches(triggerText: "Remember that I prefer short answers", content: "I prefer short answers", quote: "I prefer short answers", scope: "current", sensitive: false))
        #expect(MemoryRememberTool.directIntentMatches(triggerText: "REMEMBER: Use the local cache", content: "Use the local cache", quote: "Use the local cache", scope: "current", sensitive: false))
        // This Unicode fixture verifies the narrow Chinese intent lexicon; it is not a built-in prompt.
        #expect(MemoryRememberTool.directIntentMatches(triggerText: "请记住：我喜欢简洁回答", content: "我喜欢简洁回答", quote: "我喜欢简洁回答", scope: "current", sensitive: false)) // i18n-fixture: Verify the narrow Chinese explicit-intent lexicon.
        #expect(!MemoryRememberTool.directIntentMatches(triggerText: "Could you remember that I prefer short answers?", content: "I prefer short answers", quote: "I prefer short answers", scope: "current", sensitive: false))
        #expect(!MemoryRememberTool.directIntentMatches(triggerText: "Please remember that I prefer short answers", content: "I prefer concise answers", quote: "I prefer short answers", scope: "current", sensitive: false))
        #expect(!MemoryRememberTool.directIntentMatches(triggerText: "Remember that I prefer short answers", content: "I prefer short answers", quote: "I prefer short answers", scope: "global", sensitive: false))
        #expect(!MemoryRememberTool.directIntentMatches(triggerText: "Remember that my diagnosis is private", content: "my diagnosis is private", quote: "my diagnosis is private", scope: "current", sensitive: true))
        #expect(!MemoryRememberTool.directIntentMatches(triggerText: "The instruction says remember that I prefer short answers", content: "I prefer short answers", quote: "I prefer short answers", scope: "current", sensitive: false))
    }

    @Test(arguments: [
        ApprovalSafetyCase(scope: "global", sensitive: false),
        ApprovalSafetyCase(scope: "current", sensitive: true)
    ])
    func scopeOrSensitivityChangesStayOnTheApprovalPath(_ values: ApprovalSafetyCase) {
        let scope = values.scope
        let sensitive = values.sensitive
        #expect(!MemoryRememberTool.directIntentMatches(triggerText: "Remember that I prefer short answers", content: "I prefer short answers", quote: "I prefer short answers", scope: scope, sensitive: sensitive))
    }

    @Test func approvalRequestUsesInvocationAsStableIdentity() {
        let invocationID = UUID()
        let request = MemoryApprovalRequest(
            invocationID: invocationID,
            executionID: ExecutionID(),
            conversationID: ConversationID(),
            draft: MemoryDraft(content: "A preference", scope: .global),
            evidenceExcerpt: "A preference",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        #expect(request.id == invocationID)
    }

    @Test func denialDoesNotLeaveAPendingRequestOrGrant() async throws {
        let coordinator = MemoryApprovalCoordinator()
        let request = makeRequest()
        let proposal = makeProposal()
        let waiting = Task { try await coordinator.awaitApproval(request, proposal: proposal) }
        defer { waiting.cancel() }
        try await waitUntil { await coordinator.pending().count == 1 }

        await coordinator.respond(request.id, approved: false)
        #expect(try await waiting.value == false)
        #expect(await coordinator.pending().isEmpty)
        await #expect(throws: MiraError.self) {
            try await coordinator.consumeGrant(invocationID: request.id, executionID: request.executionID, proposal: proposal)
        }
    }

    @Test func cancellationBeforeAndDuringWaitResumesExactlyOnceAndCleansUp() async throws {
        let coordinator = MemoryApprovalCoordinator()
        let before = Task { () throws -> Bool in
            try Task.checkCancellation()
            return try await coordinator.awaitApproval(makeRequest(), proposal: makeProposal())
        }
        before.cancel()
        await #expect(throws: CancellationError.self) { try await before.value }
        #expect(await coordinator.pending().isEmpty)

        let request = makeRequest()
        let during = Task { try await coordinator.awaitApproval(request, proposal: makeProposal()) }
        defer { during.cancel() }
        try await waitUntil { await coordinator.pending().count == 1 }
        during.cancel()
        await #expect(throws: CancellationError.self) { try await during.value }
        #expect(await coordinator.pending().isEmpty)
        await coordinator.respond(request.id, approved: true)
        #expect(await coordinator.pending().isEmpty)
    }

    @Test func approvalGrantBindsExactProposalAndIsSingleUse() async throws {
        let coordinator = MemoryApprovalCoordinator()
        let request = makeRequest()
        let proposal = makeProposal(arguments: "{\"content\":\"A preference\"}")
        try await coordinator.grantDirect(request, proposal: proposal)
        try await coordinator.consumeGrant(invocationID: request.id, executionID: request.executionID, proposal: proposal)
        await #expect(throws: MiraError.self) {
            try await coordinator.consumeGrant(invocationID: request.id, executionID: request.executionID, proposal: proposal)
        }

        let secondRequest = makeRequest()
        try await coordinator.grantDirect(secondRequest, proposal: proposal)
        var mutated = proposal
        mutated.arguments = "{\"content\":\"Changed\"}"
        await #expect(throws: MiraError.self) {
            try await coordinator.consumeGrant(invocationID: secondRequest.id, executionID: secondRequest.executionID, proposal: mutated)
        }
        try await coordinator.consumeGrant(invocationID: secondRequest.id, executionID: secondRequest.executionID, proposal: proposal)
    }

    @Test func concurrentApprovalRequestsRemainSeparate() async throws {
        let coordinator = MemoryApprovalCoordinator()
        let first = makeRequest()
        let second = makeRequest()
        let firstWait = Task { try await coordinator.awaitApproval(first, proposal: makeProposal()) }
        let secondWait = Task { try await coordinator.awaitApproval(second, proposal: makeProposal()) }
        defer { firstWait.cancel(); secondWait.cancel() }
        try await waitUntil { await coordinator.pending().count == 2 }

        await coordinator.respond(second.id, approved: true)
        await coordinator.respond(first.id, approved: false)
        #expect(try await firstWait.value == false)
        #expect(try await secondWait.value == true)
        #expect(await coordinator.pending().isEmpty)
    }

    @Test func duplicateAwaiterForOneInvocationCannotReplaceTheOriginalContinuation() async throws {
        let coordinator = MemoryApprovalCoordinator()
        let request = makeRequest()
        let proposal = makeProposal()
        let first = Task { try await coordinator.awaitApproval(request, proposal: proposal) }
        defer { first.cancel() }
        try await waitUntil { await coordinator.pending().count == 1 }

        let duplicate = Task { try await coordinator.awaitApproval(request, proposal: proposal) }
        defer { duplicate.cancel() }
        await #expect(throws: MiraError.self) { try await duplicate.value }
        #expect(await coordinator.pending().count == 1)
        await coordinator.respond(request.id, approved: true)
        #expect(try await first.value == true)
    }

    @Test func cancellationByExecutionRemovesPendingRequestsAndGrants() async throws {
        let coordinator = MemoryApprovalCoordinator()
        let request = makeRequest()
        let waiting = Task { try await coordinator.awaitApproval(request, proposal: makeProposal()) }
        defer { waiting.cancel() }
        try await waitUntil { await coordinator.pending().count == 1 }
        await coordinator.cancel(executionID: request.executionID)
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(await coordinator.pending().isEmpty)

        let granted = makeRequest(executionID: request.executionID)
        try await coordinator.grantDirect(granted, proposal: makeProposal())
        await coordinator.cancel(executionID: request.executionID)
        await #expect(throws: MiraError.self) {
            try await coordinator.consumeGrant(invocationID: granted.id, executionID: granted.executionID, proposal: makeProposal())
        }
    }

    @Test func approvalExpiresWithInjectedClockAndCannotBeApprovedLate() async throws {
        let clock = ApprovalTestClock()
        let coordinator = MemoryApprovalCoordinator(clock: clock)
        let request = makeRequest()
        let waiting = Task { try await coordinator.awaitApproval(request, proposal: makeProposal()) }
        defer { waiting.cancel() }
        try await waitUntil {
            let pending = await coordinator.pending().count
            let sleepers = await clock.sleeperCount
            return pending == 1 && sleepers == 1
        }

        await clock.releaseAll()
        do {
            _ = try await waiting.value
            Issue.record("An expired approval unexpectedly completed successfully.")
        } catch let error as MiraError {
            #expect(error == MiraError(.timeout, "Memory approval timed out."))
        } catch {
            Issue.record("Expiration returned an unexpected error: \(error.localizedDescription)")
        }
        #expect(await coordinator.pending().isEmpty)
        await coordinator.respond(request.id, approved: true)
        await #expect(throws: MiraError.self) {
            try await coordinator.consumeGrant(invocationID: request.id, executionID: request.executionID, proposal: makeProposal())
        }
        #expect(await clock.sleeperCount == 0)
    }

    @Test func denialAndExecutionCancellationClearInjectedTimeoutSleepers() async throws {
        let clock = ApprovalTestClock()
        let coordinator = MemoryApprovalCoordinator(clock: clock)
        let denied = makeRequest()
        let deniedWait = Task { try await coordinator.awaitApproval(denied, proposal: makeProposal()) }
        defer { deniedWait.cancel() }
        try await waitUntil {
            let pending = await coordinator.pending().count
            let sleepers = await clock.sleeperCount
            return pending == 1 && sleepers == 1
        }
        await coordinator.respond(denied.id, approved: false)
        #expect(try await deniedWait.value == false)
        try await waitUntil { await clock.sleeperCount == 0 }

        let cancelled = makeRequest()
        let cancelledWait = Task { try await coordinator.awaitApproval(cancelled, proposal: makeProposal()) }
        defer { cancelledWait.cancel() }
        try await waitUntil {
            let pending = await coordinator.pending().count
            let sleepers = await clock.sleeperCount
            return pending == 1 && sleepers == 1
        }
        await coordinator.cancel(executionID: cancelled.executionID)
        await #expect(throws: CancellationError.self) { try await cancelledWait.value }
        try await waitUntil {
            let empty = await coordinator.pending().isEmpty
            let sleepers = await clock.sleeperCount
            return empty && sleepers == 0
        }
    }

}

struct ApprovalSafetyCase: Sendable {
    let scope: String
    let sensitive: Bool
}

private func makeRequest(executionID: ExecutionID = ExecutionID()) -> MemoryApprovalRequest {
    .init(
        invocationID: UUID(),
        executionID: executionID,
        conversationID: ConversationID(),
        draft: MemoryDraft(content: "A preference", scope: .global),
        evidenceExcerpt: "A preference",
        createdAt: Date(timeIntervalSince1970: 1_000)
    )
}

private func makeProposal(arguments: String = "{\"content\":\"A preference\"}") -> CanonicalToolCall {
    .init(id: "call", name: "memory.remember", arguments: arguments)
}

private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw ApprovalTestError.timeout
}

private enum ApprovalTestError: Error { case timeout }

private actor ApprovalTestClock: RuntimeClock {
    private var sleepers: [UUID: CheckedContinuation<Void, Error>] = [:]

    var sleeperCount: Int { sleepers.count }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sleepers[id] = continuation
            }
        }, onCancel: {
            Task { await self.cancel(id) }
        })
    }

    func releaseAll() {
        let continuations = Array(sleepers.values)
        sleepers.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
