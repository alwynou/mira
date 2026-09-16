import Foundation
import MiraCore

/// One hot authoritative reduction plus one replaceable sidecar per session.
/// Owned exclusively by the file library's serial queue.
final class FileSessionCheckpoints {
    private struct Stored: Codable {
        let version: Int
        let prefixDigest: String
        let extensionSchemas: [String: Set<Int>]
        let snapshot: SessionJournalSnapshot
    }
    private struct RecoveryStored: Codable {
        let version: Int
        let prefixDigest: String
        let extensionSchemas: [String: Set<Int>]
        let summary: SessionRecoverySummary
    }
    private let directory: URL
    private let fault: SessionStorageFaultInjector
    private let authentication: FileSessionCacheAuthentication
    private var hot: Stored?
    private var dirty = false
    private var hotMaySummarize = false
    private var savedSequences: [ConversationID: Int64] = [:]
    private(set) var restoredCount = 0
    private(set) var savedCount = 0
    private(set) var restoredSummaryCount = 0

    init(directory: URL, authentication: FileSessionCacheAuthentication, fault: @escaping SessionStorageFaultInjector) {
        self.directory = directory; self.authentication = authentication; self.fault = fault
    }

    func recoverySummary(through head: SessionJournalHead, schemas: [String: Set<Int>],
                         index: FileSessionIndex) throws -> SessionRecoverySummary? {
        try FileSessionIO.checkDirectory(directory)
        if let stored = try FileSessionCacheIO.load(RecoveryStored.self, at: recoveryURL(head.cursor.sessionID),
            format: "MIRA-SESSION-RECOVERY-4", authentication: authentication),
           stored.version == SessionStateCheckpointFormat.version, stored.extensionSchemas == schemas,
           stored.summary.head == head, let digest = Self.prefix(head, index: index),
           digest == stored.prefixDigest {
            restoredSummaryCount += 1
            return stored.summary
        }
        // A missing summary can be rebuilt from an authenticated exact full
        // checkpoint. Earlier checkpoints still require ordinary suffix reduction.
        guard let snapshot = try load(through: head, schemas: schemas, index: index),
              snapshot.head == head else { return nil }
        let result = SessionRecoverySummary(head: head, activeExecutionID: snapshot.state.activeExecutionID)
        if head == index.head, let digest = Self.prefix(head, index: index) {
            publishSummary(.init(version: SessionStateCheckpointFormat.version, prefixDigest: digest,
                                 extensionSchemas: schemas, summary: result))
        }
        return result
    }

    func load(through head: SessionJournalHead, schemas: [String: Set<Int>],
              index: FileSessionIndex) throws -> SessionJournalSnapshot? {
        let stored: Stored
        if let hot, hot.snapshot.head.cursor.sessionID == head.cursor.sessionID,
           hot.extensionSchemas == schemas, hot.snapshot.head.cursor.sequence <= head.cursor.sequence {
            stored = hot
        } else {
            try FileSessionIO.checkDirectory(directory)
            guard let disk = try FileSessionCacheIO.load(Stored.self, at: url(head.cursor.sessionID),
                format: "MIRA-SESSION-STATE-4", authentication: authentication) else { return nil }
            stored = disk
        }
        guard stored.version == SessionStateCheckpointFormat.version,
              stored.extensionSchemas == schemas,
              stored.snapshot.state.id == head.cursor.sessionID,
              stored.snapshot.state.sequence == stored.snapshot.head.cursor.sequence,
              stored.snapshot.head.cursor.sessionID == head.cursor.sessionID,
              stored.snapshot.head.cursor.sequence <= head.cursor.sequence,
              let digest = Self.prefix(stored.snapshot.head, index: index), digest == stored.prefixDigest else { return nil }
        if let hot, hot.snapshot.head.cursor.sessionID == stored.snapshot.head.cursor.sessionID,
           hot.snapshot.head.cursor.sequence > stored.snapshot.head.cursor.sequence {
            // A historical read may use the older disk prefix without retiring the newer hot state.
            restoredCount += 1
            return stored.snapshot
        }
        if hot?.snapshot.head != stored.snapshot.head || hot?.extensionSchemas != schemas {
            flush()
            hot = stored; dirty = false
            hotMaySummarize = stored.snapshot.head == index.head
            savedSequences[head.cursor.sessionID] = stored.snapshot.head.cursor.sequence
        }
        restoredCount += 1
        return stored.snapshot
    }

    func cache(_ snapshot: SessionJournalSnapshot, schemas: [String: Set<Int>], index: FileSessionIndex) {
        guard snapshot.state.id == index.sessionID, snapshot.state.sequence == snapshot.head.cursor.sequence,
              let digest = Self.prefix(snapshot.head, index: index) else { return }
        if let hot {
            if hot.snapshot.head.cursor.sessionID != snapshot.head.cursor.sessionID { flush() }
            else if hot.snapshot.head.cursor.sequence > snapshot.head.cursor.sequence { return }
        }
        hot = Stored(version: SessionStateCheckpointFormat.version, prefixDigest: digest,
                     extensionSchemas: schemas, snapshot: snapshot)
        hotMaySummarize = snapshot.head == index.head
        dirty = true
        // Geometric checkpoints keep total rewrite growth linear between explicit flushes.
        let previous = savedSequences[snapshot.head.cursor.sessionID, default: 0]
        if snapshot.head.cursor.sequence >= max(64, previous > Int64.max / 2 ? Int64.max : previous * 2) { flush() }
    }

    func flush() {
        guard dirty, let hot else { return }
        do {
            try FileSessionIO.checkDirectory(directory)
            if try FileSessionCacheIO.save(hot, at: url(hot.snapshot.head.cursor.sessionID), format: "MIRA-SESSION-STATE-4",
                authentication: authentication,
                beforeWrite: { try fault(.beforeCheckpointWrite) }, afterWrite: { try fault(.afterCheckpointWrite) },
                beforePublication: { try fault(.beforeCheckpointPublication) }, afterPublication: { try fault(.afterCheckpointPublication) }) {
                savedSequences[hot.snapshot.head.cursor.sessionID] = hot.snapshot.head.cursor.sequence
                dirty = false; savedCount += 1
                if hotMaySummarize {
                    publishSummary(.init(version: hot.version, prefixDigest: hot.prefixDigest,
                        extensionSchemas: hot.extensionSchemas,
                        summary: .init(head: hot.snapshot.head, activeExecutionID: hot.snapshot.state.activeExecutionID)))
                }
            }
        } catch {
            // No user-visible transaction depends on sidecar publication. Replay remains available.
        }
    }

    private func publishSummary(_ stored: RecoveryStored) {
        do {
            try FileSessionIO.checkDirectory(directory)
            try FileSessionCacheIO.save(stored, at: recoveryURL(stored.summary.head.cursor.sessionID),
                format: "MIRA-SESSION-RECOVERY-4", authentication: authentication,
                beforeWrite: { try fault(.beforeRecoverySummaryWrite) },
                afterWrite: { try fault(.afterRecoverySummaryWrite) },
                beforePublication: { try fault(.beforeRecoverySummaryPublication) },
                afterPublication: { try fault(.afterRecoverySummaryPublication) })
        } catch {
            // Cache failure never changes an acknowledged journal result.
        }
    }

    private func recoveryURL(_ id: ConversationID) -> URL { directory.appendingPathComponent(id.rawValue.uuidString + ".recovery") }
    private func url(_ id: ConversationID) -> URL { directory.appendingPathComponent(id.rawValue.uuidString + ".state") }

    private static func prefix(_ head: SessionJournalHead, index: FileSessionIndex) -> String? {
        guard head.cursor.sessionID == index.sessionID, head.cursor.sequence > 0 else { return nil }
        let position = index.firstRecord(after: head.cursor.sequence - 1)
        guard position < index.records.count else { return nil }
        let record = index.records[position]
        guard record.sequence == head.cursor.sequence, record.id == head.batchID else { return nil }
        return record.prefixDigest
    }
}
