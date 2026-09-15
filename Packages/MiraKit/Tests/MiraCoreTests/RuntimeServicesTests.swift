import Foundation
import Testing
@testable import MiraCore

struct RuntimeServicesTests {
    @Test func schedulerRejectsDuplicateAndReleasesIdempotently() async throws {
        let scheduler = RuntimeScheduler(modelCapacity: 1, backgroundCapacity: 1)
        let id = ExecutionID()
        let lease = try await scheduler.acquire(executionID: id, priority: .foreground)
        do {
            _ = try await scheduler.acquire(executionID: id, priority: .foreground)
            Issue.record("duplicate acquisition unexpectedly succeeded")
        } catch let error as MiraError {
            #expect(error.code == .conflict)
        }
        await lease.release()
        await lease.release()
        let replacement = try await scheduler.acquire(executionID: id, priority: .foreground)
        await replacement.release()
    }

    @Test func schedulerShutdownRejectsQueuedRequests() async throws {
        let scheduler = RuntimeScheduler(modelCapacity: 1, backgroundCapacity: 1)
        let first = try await scheduler.acquire(executionID: ExecutionID(), priority: .foreground)
        let queued = Task { try await scheduler.acquire(executionID: ExecutionID(), priority: .foreground) }
        await Task.yield()
        await scheduler.shutdown()
        do {
            _ = try await queued.value
            Issue.record("queued acquisition unexpectedly succeeded")
        } catch { }
        await first.release()
        do {
            _ = try await scheduler.acquire(executionID: ExecutionID(), priority: .foreground)
            Issue.record("acquisition after shutdown unexpectedly succeeded")
        } catch { }
    }

    @Test func approvalRequiresMatchingOneShotDecision() async throws {
        let service = RuntimeApprovalService()
        let snapshots = await service.snapshots()
        let invocation = UUID()
        let request = RuntimeApprovalRequest(invocationID: invocation, executionID: ExecutionID(), proposalHash: "hash", authorizationEpoch: 4, expiresAt: Date().addingTimeInterval(30), prompt: "Approve")
        let waiting = Task { try await service.request(request) }
        await Task.yield()
        do {
            try await service.resolve(id: invocation, proposalHash: "wrong", authorizationEpoch: 4, decision: .approved)
            Issue.record("stale proposal unexpectedly resolved")
        } catch let error as MiraError {
            #expect(error.code == .unauthorized)
        }
        try await service.resolve(id: invocation, proposalHash: "hash", authorizationEpoch: 4, decision: .approved)
        #expect(try await waiting.value == .approved)
        _ = snapshots
        do {
            try await service.resolve(id: invocation, proposalHash: "hash", authorizationEpoch: 4, decision: .approved)
            Issue.record("duplicate resolution unexpectedly succeeded")
        } catch let error as MiraError {
            #expect(error.code == .notFound)
        }
    }

    @Test func approvalCancellationIsExplicitAndScopedToExecution() async throws {
        let service = RuntimeApprovalService()
        let snapshots = await service.snapshots()
        let first = RuntimeApprovalRequest(executionID: ExecutionID(), proposalHash: "a", authorizationEpoch: 1, expiresAt: Date().addingTimeInterval(30), prompt: "A")
        let second = RuntimeApprovalRequest(executionID: ExecutionID(), proposalHash: "b", authorizationEpoch: 1, expiresAt: Date().addingTimeInterval(30), prompt: "B")
        let firstWait = Task { try await service.request(first) }
        let secondWait = Task { try await service.request(second) }
        await Task.yield()
        await service.cancel(executionID: first.executionID)
        do { _ = try await firstWait.value; Issue.record("cancelled approval unexpectedly succeeded") } catch { }
        try await service.resolve(id: second.id, proposalHash: "b", authorizationEpoch: 1, decision: .denied)
        #expect(try await secondWait.value == .denied)
        _ = snapshots
    }

    @Test func approvalWithoutObserverFailsClosed() async throws {
        let service = RuntimeApprovalService()
        let request = makeApproval()
        do {
            _ = try await service.request(request)
            Issue.record("approval without an observer unexpectedly succeeded")
        } catch let error as MiraError {
            #expect(error.code == .unauthorized)
        }
    }

    @Test func approvalLastObserverDisconnectCancelsPendingRequest() async throws {
        let service = RuntimeApprovalService()
        var snapshots: AsyncStream<[RuntimeApprovalRequest]>? = await service.snapshots()
        let waiting = Task { try await service.request(makeApproval()) }
        await Task.yield()
        snapshots = nil
        for _ in 0..<20 { await Task.yield() }
        do { _ = try await waiting.value; Issue.record("disconnected approval unexpectedly succeeded") } catch { }
        _ = snapshots
    }

    @Test func approvalResolveChecksCurrentExpiryWithoutWaitingForTimer() async throws {
        let time = ManualTime()
        let environment = RuntimeEnvironment(now: { time.value }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let service = RuntimeApprovalService(environment: environment)
        let snapshots = await service.snapshots()
        let request = makeApproval(expiresAt: time.value.addingTimeInterval(10))
        let waiting = Task { try await service.request(request) }
        await Task.yield()
        time.value = time.value.addingTimeInterval(11)
        do {
            try await service.resolve(id: request.id, proposalHash: request.proposalHash, authorizationEpoch: request.authorizationEpoch, decision: RuntimeApprovalDecision.approved)
            Issue.record("expired approval unexpectedly resolved")
        } catch let error as MiraError { #expect(error.code == .timeout) }
        do { _ = try await waiting.value; Issue.record("expired waiter unexpectedly succeeded") } catch { }
        _ = snapshots
    }

    @Test func approvalRejectsInvalidBoundsAndReusedInvocation() async throws {
        let service = RuntimeApprovalService()
        let snapshots = await service.snapshots()
        let now = Date()
        let invalid = [
            RuntimeApprovalRequest(executionID: ExecutionID(), proposalHash: "", authorizationEpoch: 1, expiresAt: now.addingTimeInterval(10), prompt: "x"),
            RuntimeApprovalRequest(executionID: ExecutionID(), proposalHash: String(repeating: "h", count: 4097), authorizationEpoch: 1, expiresAt: now.addingTimeInterval(10), prompt: "x"),
            RuntimeApprovalRequest(executionID: ExecutionID(), proposalHash: "h", authorizationEpoch: 1, expiresAt: now.addingTimeInterval(10), prompt: String(repeating: "p", count: 4097)),
            RuntimeApprovalRequest(executionID: ExecutionID(), proposalHash: "h", authorizationEpoch: 1, expiresAt: Date.distantFuture, prompt: "x")
        ]
        for request in invalid {
            do { _ = try await service.request(request); Issue.record("invalid approval unexpectedly accepted") } catch { }
        }
        let request = makeApproval()
        let waiting = Task { try await service.request(request) }
        await Task.yield()
        try await service.resolve(id: request.id, proposalHash: request.proposalHash, authorizationEpoch: request.authorizationEpoch, decision: .denied)
        #expect(try await waiting.value == .denied)
        do { _ = try await service.request(request); Issue.record("reused invocation unexpectedly accepted") } catch let error as MiraError { #expect(error.code == .conflict) }
        _ = snapshots
    }

    @Test func approvalRejectsStaleEpochAndClockFailure() async throws {
        let service = RuntimeApprovalService()
        let snapshots = await service.snapshots()
        let request = makeApproval()
        let waiting = Task { try await service.request(request) }
        await Task.yield()
        do { try await service.resolve(id: request.id, proposalHash: request.proposalHash, authorizationEpoch: 99, decision: .approved); Issue.record("stale epoch unexpectedly resolved") } catch let error as MiraError { #expect(error.code == .unauthorized) }
        try await service.resolve(id: request.id, proposalHash: request.proposalHash, authorizationEpoch: request.authorizationEpoch, decision: .approved)
        #expect(try await waiting.value == .approved)
        let failing = RuntimeEnvironment(sleep: { _ in throw TestFailure.clock })
        let failedService = RuntimeApprovalService(environment: failing)
        let failedSnapshots = await failedService.snapshots()
        let failedWaiting = Task { try await failedService.request(makeApproval(expiresAt: Date().addingTimeInterval(1))) }
        for _ in 0..<20 { await Task.yield() }
        do { _ = try await failedWaiting.value; Issue.record("clock failure unexpectedly succeeded") } catch { }
        _ = snapshots
        _ = failedSnapshots
    }

    @Test func approvalShutdownClosesStreamsAndAdmission() async throws {
        let service = RuntimeApprovalService()
        var snapshots: AsyncStream<[RuntimeApprovalRequest]>? = await service.snapshots()
        await service.shutdown()
        snapshots = nil
        do { _ = try await service.request(makeApproval()); Issue.record("request after shutdown unexpectedly succeeded") } catch let error as MiraError { #expect(error.code == .cancelled) }
        let closed = await service.snapshots()
        var iterator = closed.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        _ = snapshots
    }

    @Test func approvalTerminalCancellationConsumesInvocationID() async throws {
        let service = RuntimeApprovalService()
        let snapshots = await service.snapshots()
        let request = makeApproval()
        let waiting = Task { try await service.request(request) }
        await Task.yield()
        await service.cancel(executionID: request.executionID)
        do { _ = try await waiting.value } catch { }
        do { _ = try await service.request(request); Issue.record("cancelled invocation was reusable") } catch let error as MiraError { #expect(error.code == .conflict) }
        _ = snapshots
    }

    @Test func approvalNonFiniteClockFailsClosedWithoutDurationTrap() async throws {
        let environment = RuntimeEnvironment(now: { Date(timeIntervalSinceReferenceDate: .infinity) })
        let service = RuntimeApprovalService(environment: environment)
        let snapshots = await service.snapshots()
        do { _ = try await service.request(makeApproval()); Issue.record("non-finite clock unexpectedly accepted request") } catch let error as MiraError { #expect(error.code == .invalidInput) }
        _ = snapshots
    }

    @Test func schedulerBackgroundZeroAndQueuedCancellation() async throws {
        let disabled = RuntimeScheduler(modelCapacity: 1, backgroundCapacity: 0)
        do { _ = try await disabled.acquire(executionID: ExecutionID(), priority: .background); Issue.record("disabled background unexpectedly acquired") } catch let error as MiraError { #expect(error.code == .unsupported) }
        let scheduler = RuntimeScheduler(modelCapacity: 1, backgroundCapacity: 1)
        let lease = try await scheduler.acquire(executionID: ExecutionID(), priority: .foreground)
        let queued = Task { try await scheduler.acquire(executionID: ExecutionID(), priority: .foreground) }
        await Task.yield(); queued.cancel(); await lease.release()
        do { _ = try await queued.value; Issue.record("cancelled queued acquisition unexpectedly succeeded") } catch { }
    }

    @Test func schedulerForegroundBurstEventuallyAdmitsBackground() async throws {
        let scheduler = RuntimeScheduler(modelCapacity: 1, backgroundCapacity: 1)
        let first = try await scheduler.acquire(executionID: ExecutionID(), priority: .foreground)
        let backgroundID = ExecutionID()
        let background = Task { try await scheduler.acquire(executionID: backgroundID, priority: .background) }
        var foregroundTasks: [Task<Void, Never>] = []
        for _ in 0..<4 {
            foregroundTasks.append(Task {
                do {
                    let lease = try await scheduler.acquire(executionID: ExecutionID(), priority: .foreground)
                    await lease.release()
                } catch { }
            })
        }
        for _ in 0..<10 { await Task.yield() }
        await first.release()
        let grantedBackground = try await background.value
        await grantedBackground.release()
        for task in foregroundTasks { _ = await task.result }
    }

    @Test func schedulerShutdownDeniesQueuedAndDrainsLeases() async throws {
        let scheduler = RuntimeScheduler(modelCapacity: 1, backgroundCapacity: 1)
        let lease = try await scheduler.acquire(executionID: ExecutionID(), priority: .foreground)
        let queued = Task { try await scheduler.acquire(executionID: ExecutionID(), priority: .background) }
        await Task.yield(); await scheduler.shutdown(); await lease.release()
        do { _ = try await queued.value; Issue.record("shutdown queue unexpectedly acquired") } catch { }
        do { _ = try await scheduler.acquire(executionID: ExecutionID(), priority: .foreground); Issue.record("post-shutdown acquisition unexpectedly succeeded") } catch { }
    }

    private func makeApproval(expiresAt: Date = Date().addingTimeInterval(60)) -> RuntimeApprovalRequest {
        RuntimeApprovalRequest(executionID: ExecutionID(), proposalHash: "proposal", authorizationEpoch: 1, expiresAt: expiresAt, prompt: "Approve")
    }
}

private final class ManualTime: @unchecked Sendable {
    var value = Date()
}

private enum TestFailure: Error { case clock }
