import Foundation
import MiraCore

/// Content-free cross-store provenance from the captured journal prefix. The archive
/// coordinator performs full reduction with the installed extension schemas first.
struct SQLiteArchiveSessions {
    struct User {
        let reference: SessionEvidenceReference
        let admittedAt: Date
        let timeZoneIdentifier: String
        let authorizationEpoch: UInt64
    }
    struct Completion {
        let value: SessionCompletion
        let occurredAt: Date
        let head: SessionJournalHead
    }
    struct Session {
        var workspaceID: WorkspaceID?
        var authorizationEpoch: UInt64 = 0
        var heads: [Int64: UUID] = [:]
        var users: [UUID: User] = [:]
        var executions: [ExecutionID: SessionEvidenceReference] = [:]
        var executionSequences: [ExecutionID: Int64] = [:]
        var completions: [UUID: Completion] = [:]
        var invalidations: [UUID: SessionBatch] = [:]
    }
    private(set) var sessions: [ConversationID: Session] = [:]

    init(_ snapshot: FileSessionSnapshot) throws {
        var eventCount = 0
        for captured in snapshot.sessions {
            var session = Session()
            for batch in try snapshot.readBatches(sessionID: captured.id) {
                session.heads[batch.cursor.sequence] = batch.id
                for event in batch.events {
                    eventCount += 1
                    guard eventCount <= 1_000_000 else { throw LibraryArchiveIO.invalid }
                    switch event.fact {
                    case .opened(let header): session.workspaceID = header.workspaceID
                    case .admitted(let admission):
                        session.executionSequences[admission.executionID] = event.sequence
                        session.authorizationEpoch = max(session.authorizationEpoch, admission.authorizationEpoch)
                        if let body = admission.userBody {
                            let reference = SessionEvidenceReference(
                                sessionID: captured.id, originalExecutionID: admission.executionID,
                                userMessageID: admission.userMessageID, admissionEventID: event.id,
                                admissionSequence: event.sequence, body: body)
                            session.users[event.id] = User(
                                reference: reference, admittedAt: event.occurredAt,
                                timeZoneIdentifier: admission.timeZoneIdentifier,
                                authorizationEpoch: admission.authorizationEpoch)
                            session.executions[admission.executionID] = reference
                        } else if let previous = admission.retryOfExecutionID,
                            let reference = session.executions[previous]
                        {
                            session.executions[admission.executionID] = reference
                        } else {
                            throw LibraryArchiveIO.invalid
                        }
                    case .finished(let value):
                        session.completions[event.id] = Completion(
                            value: value, occurredAt: event.occurredAt,
                            head: .init(cursor: batch.cursor, batchID: batch.id))
                    case .invalidated(let value):
                        session.authorizationEpoch = max(session.authorizationEpoch, value.authorizationEpoch)
                        guard session.invalidations.updateValue(batch, forKey: value.operationID) == nil else {
                            throw LibraryArchiveIO.invalid
                        }
                    default: break
                    }
                }
            }
            sessions[captured.id] = session
        }
    }

    func validate(_ head: SessionJournalHead) throws {
        try head.validate()
        guard let session = sessions[head.cursor.sessionID],
            head.cursor.sequence == 0 || session.heads[head.cursor.sequence] == head.batchID
        else {
            throw LibraryArchiveIO.invalid
        }
    }

    @discardableResult
    func validate(_ source: SessionEvidenceReference, workspaceID: WorkspaceID?) throws -> User {
        try source.validate()
        guard let session = sessions[source.sessionID], session.workspaceID == workspaceID,
            let user = session.users[source.admissionEventID], user.reference == source
        else {
            throw LibraryArchiveIO.invalid
        }
        return user
    }

    func validate(_ origin: MemoryExtractionOrigin, workspaceID: WorkspaceID?) throws {
        try origin.validate()
        try validate(origin.source, workspaceID: workspaceID)
        try validate(origin.completionHead)
        guard let session = sessions[origin.source.sessionID],
            let completion = session.completions[origin.completionEventID],
            completion.value.executionID == origin.completedExecutionID,
            completion.value.status == .completed,
            completion.head == origin.completionHead,
            session.executions[origin.completedExecutionID] == origin.source
        else { throw LibraryArchiveIO.invalid }
    }
}
