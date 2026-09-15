import Foundation
import Testing
import MiraCore

struct RuntimeClockTests {
    @Test func cancellingAnInjectedSleeperCompletesItsTask() async throws {
        let clock = RuntimeEnvironment().clock
        let task = Task { try await clock.sleep(for: .seconds(1_200)) }
        task.cancel()
        do { try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
    }
}
