import Foundation

/// A content-free signal that a library transaction committed a business change.
public struct AgentBusinessChangeObservation: Sendable, Equatable {
    public let revision: UInt64
    public let isClosed: Bool

    public init(revision: UInt64, isClosed: Bool = false) {
        self.revision = revision
        self.isClosed = isClosed
    }
}

/// Publishes committed business-change wakeups for host consumers.
public protocol AgentBusinessChangeSource: Sendable {
    func observe() async throws -> AsyncStream<AgentBusinessChangeObservation>
}
