import Foundation
import Testing

@MainActor
@Suite("Deferred transcript following")
struct TranscriptFollowSchedulerTests {
    @Test func geometryBurstsCoalesceOutsideTheCurrentTransaction() async throws {
        let scheduler = TranscriptFollowScheduler(interval: .milliseconds(10))
        var count = 0
        for _ in 0..<20 { scheduler.schedule { count += 1 } }
        #expect(count == 0)
        try await waitForCallback { count > 0 }
        #expect(count == 1)
    }

    @Test func cancellationAndImmediateReschedulingCannotExecuteTheOldFollow() async throws {
        let scheduler = TranscriptFollowScheduler(interval: .milliseconds(10))
        var events: [String] = []
        scheduler.schedule { events.append("old") }
        scheduler.cancel()
        scheduler.schedule { events.append("new") }
        try await waitForCallback { !events.isEmpty }
        #expect(events == ["new"])
        scheduler.schedule { events.append("disappeared") }
        scheduler.cancel()
        try await Task.sleep(for: .milliseconds(40))
        #expect(events == ["new"])
    }

    @Test func pendingExplicitJumpCanBeCancelledBeforeDeferredCallback() async throws {
        let scheduler = TranscriptFollowScheduler(interval: .milliseconds(10))
        var state = TranscriptScrollState()
        var callbacks = 0
        var jumps = 0
        state.jumpToLatest()
        scheduler.schedule {
            callbacks += 1
            if state.consumePendingJumpToLatest() { jumps += 1 }
        }
        state.userScrollChanged(isScrolling: true, isNearBottom: false)
        try await waitForCallback { callbacks == 1 }
        #expect(jumps == 0)
        state.userScrollChanged(isScrolling: false, isNearBottom: false)
        state.jumpToLatest()
        scheduler.schedule {
            callbacks += 1
            if state.consumePendingJumpToLatest() { jumps += 1 }
        }
        try await waitForCallback { callbacks == 2 }
        #expect(jumps == 1)
        let consumedAgain = state.consumePendingJumpToLatest()
        #expect(!consumedAgain)
    }

    private func waitForCallback(_ completed: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !completed(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(completed(), "The deferred callback did not execute before the test deadline.")
    }
}
