import Foundation
import Observation
import MiraCore

/// Coalesces high-frequency runtime snapshots before publishing them to the UI.
@MainActor @Observable
final class ConversationStreamBuffer {
    private(set) var drafts: [ExecutionID: String] = [:]
    private(set) var thinkingTraces: [ExecutionID: [CanonicalMessage]] = [:]

    @ObservationIgnored private var pendingDrafts: [ExecutionID: String] = [:]
    @ObservationIgnored private var pendingThinkingTraces: [ExecutionID: [CanonicalMessage]] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var batchGeneration = 0
    @ObservationIgnored private let interval: Duration

    init(interval: Duration = .milliseconds(100)) {
        self.interval = interval
    }

    func receiveDraft(_ text: String, for id: ExecutionID) {
        pendingDrafts[id] = text
        scheduleFlushIfNeeded()
    }

    func receiveThinking(_ trace: [CanonicalMessage], for id: ExecutionID) {
        pendingThinkingTraces[id] = trace
        if drafts[id] == nil, pendingDrafts[id] == nil {
            pendingDrafts[id] = ""
        }
        scheduleFlushIfNeeded()
    }

    func replace(drafts: [ExecutionID: String], thinkingTraces: [ExecutionID: [CanonicalMessage]]) {
        cancelPendingFlush(clearPending: true)
        self.drafts = drafts
        self.thinkingTraces = thinkingTraces
    }

    func flush() {
        cancelPendingFlush(clearPending: false)
        publishPending()
    }

    private func scheduleFlushIfNeeded() {
        guard flushTask == nil else { return }
        batchGeneration += 1
        let generation = batchGeneration
        let interval = self.interval
        flushTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: interval) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.publishPending(generation: generation)
        }
    }

    private func cancelPendingFlush(clearPending: Bool) {
        batchGeneration += 1
        flushTask?.cancel()
        flushTask = nil
        if clearPending {
            pendingDrafts.removeAll(keepingCapacity: true)
            pendingThinkingTraces.removeAll(keepingCapacity: true)
        }
    }

    private func publishPending(generation: Int? = nil) {
        if let generation, generation != batchGeneration { return }
        flushTask = nil
        for (id, text) in pendingDrafts {
            drafts[id] = text
        }
        for (id, trace) in pendingThinkingTraces {
            thinkingTraces[id] = trace
        }
        pendingDrafts.removeAll(keepingCapacity: true)
        pendingThinkingTraces.removeAll(keepingCapacity: true)
    }
}
