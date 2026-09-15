import Foundation

/// An adapter reports a transient failure; only the kernel can authorize another attempt.
public enum AgentModelRetryAdvice: Codable, Sendable, Equatable {
    case transient(minimumDelayMilliseconds: Int)

    public var minimumDelayMilliseconds: Int {
        switch self { case .transient(let value): value }
    }
}

/// Safe diagnostics and retry classification are separate from private provider response bodies.
public struct AgentModelFailure: Error, Codable, Sendable, Equatable {
    public let error: MiraError
    public let retryAdvice: AgentModelRetryAdvice?
    public init(error: MiraError, retryAdvice: AgentModelRetryAdvice? = nil) {
        self.error = error; self.retryAdvice = retryAdvice
    }
    public func validate() throws {
        guard error.message.utf8.count <= 4_096,
              retryAdvice.map({ (0...86_400_000).contains($0.minimumDelayMilliseconds) &&
                  [.network, .rateLimited, .timeout].contains(error.code) }) ?? true else {
            throw MiraError(.configuration, "The model failure classification is invalid.")
        }
    }
}

/// Stored in the failed attempt's error payload. Partial streams cannot become automatic retry input.
public struct AgentModelAttemptFailureRecord: Codable, Sendable, Equatable {
    public let failure: AgentModelFailure
    public let receivedStreamEvents: Bool
    public init(failure: AgentModelFailure, receivedStreamEvents: Bool) {
        self.failure = failure; self.receivedStreamEvents = receivedStreamEvents
    }
}

/// Captured in the execution plan. Every attempt also consumes the execution's output reservation.
public struct AgentModelRetryPolicy: Codable, Sendable, Equatable {
    public let maximumAttempts: Int
    public let initialDelayMilliseconds: Int
    public let maximumDelayMilliseconds: Int

    public init(maximumAttempts: Int = 3, initialDelayMilliseconds: Int = 500, maximumDelayMilliseconds: Int = 5_000) {
        self.maximumAttempts = maximumAttempts; self.initialDelayMilliseconds = initialDelayMilliseconds
        self.maximumDelayMilliseconds = maximumDelayMilliseconds
    }
    public func validate() throws {
        guard (1...5).contains(maximumAttempts), (0...60_000).contains(initialDelayMilliseconds),
              (initialDelayMilliseconds...60_000).contains(maximumDelayMilliseconds) else {
            throw MiraError(.configuration, "The model retry policy is invalid.")
        }
    }

    /// A provider delay above the frozen ceiling stops automatic retry; it is never shortened.
    public func delayMilliseconds(afterAttempt attempt: Int, advice: AgentModelRetryAdvice) throws -> Int? {
        try validate()
        guard (1...5).contains(attempt), (0...86_400_000).contains(advice.minimumDelayMilliseconds) else {
            throw MiraError(.configuration, "The model failure classification is invalid.")
        }
        guard attempt < maximumAttempts else { return nil }
        let backoff = min(maximumDelayMilliseconds, initialDelayMilliseconds * (1 << (attempt - 1)))
        let delay = max(backoff, advice.minimumDelayMilliseconds)
        return delay <= maximumDelayMilliseconds ? delay : nil
    }
}

/// This private result is emitted only after the failed attempt has been durably resolved and drained.
struct AgentModelAttemptFailure: Error, Sendable {
    let attemptID: UUID
    let failure: AgentModelFailure
    let receivedStreamEvents: Bool
}
