import Foundation
import MiraCore

/// Metadata and URLs are valid only while the owning snapshot callback is running.
public struct FileSessionSnapshot: Sendable {
    public struct Session: Sendable {
        public let id: ConversationID
        public let head: SessionJournalHead
        public let journalURL: URL
    }
    public let sessions: [Session]
    private let sessionOffsets: [ConversationID: Int]

    init(sessions: [Session]) {
        self.sessions = sessions
        var offsets: [ConversationID: Int] = [:]
        for (index, session) in sessions.enumerated() { offsets[session.id] = index }
        sessionOffsets = offsets
    }

    public func session(_ id: ConversationID) -> Session? { sessionOffsets[id].map { sessions[$0] } }

    public func readBatches(sessionID: ConversationID) throws -> [SessionBatch] {
        guard let session = session(sessionID) else { throw FileSessionIO.failure() }
        let batches = try FileSessionIO.scanStrict(
            session.journalURL, sessionID: sessionID,
            maximumRecords: FileSessionArchive.maximumRecords)
        guard let last = batches.last, last.id == session.head.batchID, last.cursor == session.head.cursor else {
            throw FileSessionIO.failure()
        }
        return batches
    }
}

/// Strict archive inspection never opens a session writer or repairs the supplied bytes.
public enum FileSessionArchive {
    static let maximumSessions = 4096
    static let maximumRecords = 100_000
    static let maximumReferences = LibraryArchiveLimits.maximumFiles

    public static func inspect(directory: URL) throws -> FileSessionSnapshot {
        guard directory.isFileURL else { throw FileSessionIO.failure() }
        let root = directory.standardizedFileURL
        let roots = try FileSessionIO.directoryEntries(root, limit: 1)
        guard Set(roots.map(\.lastPathComponent)) == ["sessions"] else { throw FileSessionIO.failure() }
        let sessionsURL = root.appendingPathComponent("sessions", isDirectory: true)
        let entries = try FileSessionIO.directoryEntries(sessionsURL, limit: maximumSessions)
        var sessions: [FileSessionSnapshot.Session] = []
        for journal in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let stem = journal.deletingPathExtension().lastPathComponent
            guard journal.pathExtension == "jsonl", let uuid = UUID(uuidString: stem), uuid.uuidString == stem else {
                throw FileSessionIO.failure()
            }
            let id = ConversationID(uuid)
            let batches = try FileSessionIO.scanStrict(journal, sessionID: id, maximumRecords: maximumRecords)
            guard let last = batches.last else { throw FileSessionIO.failure() }
            sessions.append(
                .init(id: id, head: .init(cursor: last.cursor, batchID: last.id), journalURL: journal))
        }
        return .init(sessions: sessions)
    }

}
