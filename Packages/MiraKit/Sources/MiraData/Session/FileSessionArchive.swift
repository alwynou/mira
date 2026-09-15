import Foundation
import MiraCore

/// Metadata and URLs are valid only while the owning snapshot callback is running.
public struct FileSessionSnapshot: Sendable {
    public struct Session: Sendable {
        public let id: ConversationID
        public let head: SessionJournalHead
        public let journalURL: URL
        public let payloads: [SessionPayloadReference: URL]
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
        let roots = try FileSessionIO.directoryEntries(root, limit: 2)
        guard Set(roots.map(\.lastPathComponent)) == ["sessions", "payloads"] else { throw FileSessionIO.failure() }
        let sessionsURL = root.appendingPathComponent("sessions", isDirectory: true)
        let payloadsURL = root.appendingPathComponent("payloads", isDirectory: true)
        try FileSessionIO.checkDirectory(payloadsURL)
        let entries = try FileSessionIO.directoryEntries(sessionsURL, limit: maximumSessions)
        var sessions: [FileSessionSnapshot.Session] = []
        var expectedFiles: Set<String> = []
        var expectedDirectories: Set<String> = []
        var referenceCount = 0
        for journal in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let stem = journal.deletingPathExtension().lastPathComponent
            guard journal.pathExtension == "jsonl", let uuid = UUID(uuidString: stem), uuid.uuidString == stem else {
                throw FileSessionIO.failure()
            }
            let id = ConversationID(uuid)
            let batches = try FileSessionIO.scanStrict(journal, sessionID: id, maximumRecords: maximumRecords)
            guard let last = batches.last else { throw FileSessionIO.failure() }
            let retained = try references(in: batches)
            referenceCount += retained.references.count
            guard referenceCount <= maximumReferences else { throw FileSessionIO.failure() }
            var live: [SessionPayloadReference: URL] = [:]
            for reference in retained.references.values where !retained.invalidated.contains(reference.retentionGroup) {
                let sessionPath = id.rawValue.uuidString
                let batchPath = sessionPath + "/" + reference.batchID.uuidString
                let path = batchPath + "/" + reference.id.uuidString + ".bin"
                let url = try LibraryArchiveIO.file(path, under: payloadsURL)
                try FileSessionIO.validateFile(
                    url, expectedCount: reference.byteCount, expectedDigest: reference.digest)
                live[reference] = url
                expectedFiles.insert(path)
                expectedDirectories.formUnion([sessionPath, batchPath])
            }
            sessions.append(
                .init(id: id, head: .init(cursor: last.cursor, batchID: last.id), journalURL: journal, payloads: live))
        }
        var seenFiles: Set<String> = []
        var seenDirectories: Set<String> = []
        var visited = 0
        func walk(_ current: URL, prefix: String, depth: Int) throws {
            guard depth <= 2 else { throw FileSessionIO.failure() }
            let names = try FileSessionIO.directoryEntries(current, limit: maximumReferences * 3 - visited)
            visited += names.count
            for url in names {
                let path = prefix + url.lastPathComponent
                if expectedDirectories.contains(path) {
                    seenDirectories.insert(path)
                    try walk(url, prefix: path + "/", depth: depth + 1)
                } else {
                    guard expectedFiles.contains(path), seenFiles.insert(path).inserted else {
                        throw FileSessionIO.failure()
                    }
                    try LibraryArchiveIO.requireSingleFile(url)
                }
            }
        }
        try walk(payloadsURL, prefix: "", depth: 0)
        guard seenFiles == expectedFiles, seenDirectories == expectedDirectories else { throw FileSessionIO.failure() }
        return .init(sessions: sessions)
    }

    static func references(in batches: [SessionBatch]) throws -> (
        references: [UUID: SessionPayloadReference], invalidated: Set<UUID>
    ) {
        var references: [UUID: SessionPayloadReference] = [:]
        var invalidated: Set<UUID> = []
        for batch in batches {
            for event in batch.events {
                for reference in event.fact.payloadReferences {
                    if let previous = references[reference.id] {
                        guard previous == reference else { throw FileSessionIO.failure() }
                    } else {
                        guard references.count < maximumReferences, reference.batchID == batch.id else {
                            throw FileSessionIO.failure()
                        }
                        references[reference.id] = reference
                    }
                }
                switch event.fact {
                case .invalidated(let fact): invalidated.formUnion(fact.retentionGroups)
                case .retryCleared(let fact): invalidated.formUnion(fact.retentionGroups)
                default: break
                }
            }
        }
        return (references, invalidated)
    }
}
