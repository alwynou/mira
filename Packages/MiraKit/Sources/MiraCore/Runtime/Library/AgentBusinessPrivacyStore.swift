import Foundation

/// Library-scoped result cleanup, independent of the application effect executor's lifetime.
/// Committed receipt identities and outbox publication facts survive removal of result bodies.
public protocol AgentBusinessPrivacyStore: Sendable {
    func purgeSessionResults(plan: SessionPrivacyPlan) async throws
    func verifySessionResultsPurged(plan: SessionPrivacyPlan) async throws
}
