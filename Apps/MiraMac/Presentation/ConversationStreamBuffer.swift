import Foundation
import MiraCore
import Observation

/// Coalesces high-frequency live output snapshots before publishing them to the UI.
/// The buffer is scoped to one session/page and never owns the execution.
@MainActor @Observable
final class ConversationStreamBuffer {
    private(set) var observation: SessionOutputObservation?

    @ObservationIgnored private var pending: SessionOutputObservation?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var acceptedSessionID: ConversationID?
    @ObservationIgnored private var acceptedCursorSequence: Int64 = 0
    @ObservationIgnored private var acceptedRevision: UInt64 = 0
    @ObservationIgnored private var acceptedIsClosing = false
    @ObservationIgnored private let interval: Duration

    init(interval: Duration = .milliseconds(100)) {
        self.interval = interval
    }

    func receive(_ value: SessionOutputObservation) {
        guard accepts(value) else { return }
        acceptedSessionID = value.cursor.sessionID
        acceptedCursorSequence = value.cursor.sequence
        acceptedRevision = value.revision
        acceptedIsClosing = value.isClosing
        if value.value == nil, !value.isClosing, let executionID = value.handoffExecutionID {
            let latest = pending?.value ?? observation?.value
            cancelPending()
            observation = .init(cursor: value.cursor, revision: value.revision,
                                value: latest?.executionID == executionID ? latest : nil,
                                isClosing: false, handoffExecutionID: executionID)
            return
        }
        if value.value == nil || value.isClosing {
            cancelPending()
            observation = .init(cursor: value.cursor, revision: value.revision, value: nil, isClosing: value.isClosing)
            return
        }
        pending = value
        scheduleFlushIfNeeded()
    }

    func clear() {
        cancelPending()
        observation = nil
        acceptedSessionID = nil
        acceptedCursorSequence = 0
        acceptedRevision = 0
        acceptedIsClosing = false
    }

    func flush() {
        cancelPending(clearPending: false)
        publishPending()
    }

    func completeHandoff(executionID: ExecutionID, through sequence: Int64) {
        guard let current = observation, current.handoffExecutionID == executionID,
              current.cursor.sequence <= sequence else { return }
        observation = .init(cursor: current.cursor, revision: current.revision, value: nil, isClosing: false)
    }

    private func accepts(_ value: SessionOutputObservation) -> Bool {
        guard value.cursor.sequence >= 0, !acceptedIsClosing else { return false }
        guard let sessionID = acceptedSessionID else { return true }
        guard sessionID == value.cursor.sessionID,
            value.cursor.sequence >= acceptedCursorSequence,
            value.revision > acceptedRevision
        else { return false }
        return true
    }

    private func scheduleFlushIfNeeded() {
        guard flushTask == nil else { return }
        generation &+= 1
        let expectedGeneration = generation
        let interval = interval
        flushTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            guard !Task.isCancelled else { return }
            self?.publishPending(generation: expectedGeneration)
        }
    }

    private func cancelPending(clearPending: Bool = true) {
        generation &+= 1
        flushTask?.cancel()
        flushTask = nil
        if clearPending { pending = nil }
    }

    private func publishPending(generation expectedGeneration: Int? = nil) {
        if let expectedGeneration, expectedGeneration != generation { return }
        flushTask = nil
        guard let value = pending else { return }
        pending = nil
        observation = value
    }
}
