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
        try await Task.sleep(for: .milliseconds(40))
        #expect(count == 1)
    }

    @Test func cancellationAndImmediateReschedulingCannotExecuteTheOldFollow() async throws {
        let scheduler = TranscriptFollowScheduler(interval: .milliseconds(10))
        var events: [String] = []
        scheduler.schedule { events.append("old") }
        scheduler.cancel()
        scheduler.schedule { events.append("new") }
        try await Task.sleep(for: .milliseconds(40))
        #expect(events == ["new"])
        scheduler.schedule { events.append("disappeared") }
        scheduler.cancel()
        try await Task.sleep(for: .milliseconds(40))
        #expect(events == ["new"])
    }

    @Test func followIntentIsCheckedWhenTheDeferredCallbackExecutes() async throws {
        let scheduler = TranscriptFollowScheduler(interval: .milliseconds(10))
        var state = TranscriptScrollState()
        var count = 0
        scheduler.schedule { if state.shouldFollowContentChange() { count += 1 } }
        state.revealHistory()
        try await Task.sleep(for: .milliseconds(40))
        #expect(count == 0)
        state.jumpToLatest()
        scheduler.schedule { if state.shouldFollowContentChange() { count += 1 } }
        try await Task.sleep(for: .milliseconds(40))
        #expect(count == 1)
    }
}
