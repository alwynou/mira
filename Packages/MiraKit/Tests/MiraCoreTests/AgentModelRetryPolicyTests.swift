import Foundation
import Testing
@testable import MiraCore

@Suite("Agent model retry policy")
struct AgentModelRetryPolicyTests {
    @Test func invalidPolicyBoundsAreRejected() {
        let policies = [
            AgentModelRetryPolicy(maximumAttempts: 0),
            AgentModelRetryPolicy(maximumAttempts: 6),
            AgentModelRetryPolicy(maximumAttempts: Int.min),
            AgentModelRetryPolicy(maximumAttempts: Int.max),
            AgentModelRetryPolicy(initialDelayMilliseconds: -1),
            AgentModelRetryPolicy(initialDelayMilliseconds: 60_001),
            AgentModelRetryPolicy(initialDelayMilliseconds: Int.min),
            AgentModelRetryPolicy(initialDelayMilliseconds: Int.max),
            AgentModelRetryPolicy(initialDelayMilliseconds: 500, maximumDelayMilliseconds: 499),
            AgentModelRetryPolicy(maximumDelayMilliseconds: 60_001),
            AgentModelRetryPolicy(maximumDelayMilliseconds: Int.min),
            AgentModelRetryPolicy(maximumDelayMilliseconds: Int.max)
        ]
        for policy in policies {
            #expect(throws: MiraError.self) { try policy.validate() }
        }
    }

    @Test func invalidAttemptsAndAdviceBoundsNeverTrap() {
        let policy = AgentModelRetryPolicy(maximumAttempts: 3, initialDelayMilliseconds: 100, maximumDelayMilliseconds: 500)
        for attempt in [Int.min, -1, 0, 6, Int.max] {
            #expect(throws: MiraError.self) {
                try policy.delayMilliseconds(afterAttempt: attempt, advice: .transient(minimumDelayMilliseconds: 0))
            }
        }
        for minimumDelay in [Int.min, -1, 86_400_001, Int.max] {
            #expect(throws: MiraError.self) {
                try policy.delayMilliseconds(afterAttempt: 1, advice: .transient(minimumDelayMilliseconds: minimumDelay))
            }
        }
    }

    @Test func retryArithmeticHonorsDisabledPolicyCeilingAndServerMinimum() throws {
        let policy = AgentModelRetryPolicy(maximumAttempts: 5, initialDelayMilliseconds: 100, maximumDelayMilliseconds: 250)
        let advice = AgentModelRetryAdvice.transient(minimumDelayMilliseconds: 0)
        #expect(try policy.delayMilliseconds(afterAttempt: 1, advice: advice) == 100)
        #expect(try policy.delayMilliseconds(afterAttempt: 2, advice: advice) == 200)
        #expect(try policy.delayMilliseconds(afterAttempt: 3, advice: advice) == 250)
        #expect(try policy.delayMilliseconds(afterAttempt: 4, advice: .transient(minimumDelayMilliseconds: 175)) == 250)
        #expect(try policy.delayMilliseconds(afterAttempt: 1, advice: .transient(minimumDelayMilliseconds: 175)) == 175)
        #expect(try policy.delayMilliseconds(afterAttempt: 1, advice: .transient(minimumDelayMilliseconds: 251)) == nil)
        let exhausted = AgentModelRetryPolicy(maximumAttempts: 3, initialDelayMilliseconds: 100, maximumDelayMilliseconds: 250)
        #expect(try exhausted.delayMilliseconds(afterAttempt: 3, advice: advice) == nil)

        let disabled = AgentModelRetryPolicy(maximumAttempts: 1, initialDelayMilliseconds: 100, maximumDelayMilliseconds: 250)
        #expect(try disabled.delayMilliseconds(afterAttempt: 1, advice: advice) == nil)
    }

    @Test func failureAdviceIsRestrictedToTransientErrorCodesAndSafeDiagnostics() throws {
        for code in [MiraError.Code.network, .rateLimited, .timeout] {
            try AgentModelFailure(error: .init(code, "temporary"), retryAdvice: .transient(minimumDelayMilliseconds: 0)).validate()
        }
        for code in [MiraError.Code.configuration, .unauthorized, .providerRejected, .interrupted] {
            #expect(throws: MiraError.self) {
                try AgentModelFailure(error: .init(code, "not retryable"), retryAdvice: .transient(minimumDelayMilliseconds: 0)).validate()
            }
        }
        #expect(throws: MiraError.self) {
            try AgentModelFailure(error: .init(.network, String(repeating: "x", count: 4_097))).validate()
        }
        try AgentModelFailure(error: .init(.configuration, "safe diagnostic")).validate()
    }

    @Test func limitsWithoutRequiredModelRetryPolicyAreRejected() throws {
        let incompleteLimits = Data(#"{"maximumSteps":20,"maximumToolCalls":32,"maximumParallelTools":4,"maximumReservedOutputTokens":32768,"modelTimeoutMilliseconds":300000,"executionTimeoutMilliseconds":1200000}"#.utf8)
        do {
            _ = try JSONDecoder().decode(AgentExecutionLimits.self, from: incompleteLimits)
            Issue.record("Execution limits without modelRetryPolicy must be rejected.")
        } catch is DecodingError {
            // The current format requires the frozen retry policy.
        } catch {
            Issue.record("Expected a decoding failure for missing modelRetryPolicy.")
        }
    }
}
