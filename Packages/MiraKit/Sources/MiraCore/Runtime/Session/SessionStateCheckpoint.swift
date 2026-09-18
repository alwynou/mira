import Foundation

/// Version of the persisted authoritative state representation. Changing the
/// reducer or this representation invalidates existing sidecars.
public enum SessionStateCheckpointFormat {
    public static let version = 2
}

/// Identifies recovery work at one validated journal boundary. This value does
/// not authorize effects or replace the full state required to settle work.
public struct SessionRecoverySummary: Codable, Sendable, Equatable {
    public let head: SessionJournalHead
    public let activeExecutionID: ExecutionID?

    public init(head: SessionJournalHead, activeExecutionID: ExecutionID?) {
        self.head = head; self.activeExecutionID = activeExecutionID
    }
}

/// Optional acceleration port for the authoritative journal reader. An
/// implementation must return only a snapshot whose complete-prefix source
/// binding and extension schema validation have already succeeded. A returned
/// snapshot is never permission to skip the reader's structural checks.
public protocol SessionCheckpointJournal: SessionJournal {
    /// Only an exact, fully validated prefix may be summarized. Cache absence
    /// or failed authentication returns nil and requires ordinary reduction.
    func recoverySummary(through head: SessionJournalHead,
                         extensionSchemas: [String: Set<Int>]) async throws -> SessionRecoverySummary?
    func checkpoint(through head: SessionJournalHead,
                    extensionSchemas: [String: Set<Int>]) async throws -> SessionJournalSnapshot?
    /// Best effort cache publication. The journal remains the authority.
    func cache(_ snapshot: SessionJournalSnapshot,
               extensionSchemas: [String: Set<Int>]) async
}
