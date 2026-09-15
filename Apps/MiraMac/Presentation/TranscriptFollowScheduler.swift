import Foundation

/// Keep scroll mutations out of the transaction that reports Markdown geometry.
/// Multiple asynchronous height changes need at most one follow on the next frame.
@MainActor
final class TranscriptFollowScheduler {
    private var pending: Task<Void, Never>?
    private var generation = 0
    private let interval: Duration

    init(interval: Duration = .milliseconds(16)) { self.interval = interval }

    func schedule(_ follow: @escaping @MainActor () -> Void) {
        guard pending == nil else { return }
        generation += 1
        let token = generation
        let interval = interval
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.pending = nil
            follow()
        }
    }

    func cancel() {
        generation += 1
        pending?.cancel()
        pending = nil
    }

    deinit { pending?.cancel() }
}
