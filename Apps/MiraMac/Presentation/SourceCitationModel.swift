import Foundation
import Observation
import MiraCore

/// A visible citation owns a fresh, revocable read of one reply's exact source.
@MainActor @Observable
final class SourceCitationModel {
    private(set) var detail: SourceCitationDetail?
    private(set) var error: MiraError?
    private var generation = 0

    func observe(application: MiraApplication, reference: SourceCitationReference,
                 executionID: ExecutionID, conversationID: ConversationID) async {
        generation += 1
        let current = generation
        detail = nil
        error = nil
        defer {
            if current == generation {
                detail = nil
                error = nil
            }
        }
        // Subscribe before reading so a concurrent deletion cannot be missed.
        // The event stream includes an initial change notification.
        let events = await application.events()
        for await event in events {
            guard current == generation, !Task.isCancelled else { return }
            guard case .changed = event else { continue }
            detail = nil
            error = nil
            do {
                let value = try await application.sourceCitation(reference, executionID: executionID,
                                                                 conversationID: conversationID)
                guard current == generation, !Task.isCancelled else { return }
                detail = value
            } catch {
                guard current == generation, !Task.isCancelled else { return }
                self.error = MiraError.safe(error)
            }
        }
    }
}
