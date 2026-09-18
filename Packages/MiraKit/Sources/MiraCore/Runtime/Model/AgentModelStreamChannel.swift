import Foundation

/// One model producer, one consumer, and an independent coalescing live-output signal.
/// The owner closes the channel and drains both producers before releasing the scheduler lease.
actor AgentModelStreamChannel {
    enum Input: Sendable {
        case event(AgentModelStreamEvent)
        case output
    }

    private enum End {
        case completed
        case failed(any Error)
    }

    private var pendingEvent: (AgentModelStreamEvent, CheckedContinuation<Void, any Error>)?
    private var reader: CheckedContinuation<Input?, any Error>?
    private var outputPending = false
    private var end: End?
    private var closed = false

    // Internal observation for bounded lifecycle diagnostics, without exposing buffered content.
    var bufferedEventCount: Int { pendingEvent == nil ? 0 : 1 }
    var isWaitingForInput: Bool { reader != nil }

    /// Backpressure admits at most one event ahead of the consumer.
    func send(_ event: AgentModelStreamEvent) async throws {
        try Task.checkCancellation()
        guard !closed, end == nil else { throw CancellationError() }
        guard pendingEvent == nil else { throw Self.conflictingOwners }
        if let reader {
            self.reader = nil
            reader.resume(returning: .event(event))
            return
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { pendingEvent = (event, $0) }
        } onCancel: {
            Task { await self.close() }
        }
        try Task.checkCancellation()
    }

    /// Live presentation does not create a durable record or queue per-token copies.
    func output() -> Bool {
        guard !closed, end == nil else { return false }
        if let reader {
            self.reader = nil
            reader.resume(returning: .output)
        } else {
            outputPending = true
        }
        return true
    }

    func finish(error: (any Error)? = nil) {
        guard !closed, end == nil else { return }
        end = error.map { .failed($0) } ?? .completed
        outputPending = false
        if let reader {
            self.reader = nil
            if let error { reader.resume(throwing: error) } else { reader.resume(returning: nil) }
        }
    }

    func next() async throws -> Input? {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard reader == nil else { throw Self.conflictingOwners }
        if outputPending {
            outputPending = false
            return .output
        }
        if let pendingEvent {
            self.pendingEvent = nil
            pendingEvent.1.resume()
            return .event(pendingEvent.0)
        }
        if let end {
            switch end {
            case .completed: return nil
            case .failed(let error): throw error
            }
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { reader = $0 }
        } onCancel: {
            Task { await self.close() }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        outputPending = false
        pendingEvent?.1.resume(throwing: CancellationError())
        pendingEvent = nil
        reader?.resume(throwing: CancellationError())
        reader = nil
    }

    private static var conflictingOwners: MiraError {
        .init(.conflict, "The model stream channel has conflicting owners.")
    }
}
