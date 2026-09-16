import Foundation
import MiraCore

/// Disposable metadata derived by the journal writer, never a query projection.
/// Loading verifies both the sidecar and every byte of its source journal.
final class FileSessionIndex {
    struct Record: Codable, Sendable, Equatable {
        let id: UUID
        let expectedSequence: Int64
        let sequence: Int64
        let offset: Int64
        let byteCount: Int
        let digest: String
        let prefixDigest: String

        init(batch: SessionBatch, offset: Int64, line: Data, previousDigest: String) {
            id = batch.id; expectedSequence = batch.expectedSequence; sequence = batch.cursor.sequence
            self.offset = offset; byteCount = line.count + 1; digest = FileSessionIO.digest(line)
            prefixDigest = FileSessionIO.digest(Data((previousDigest + digest).utf8))
        }
    }

    private struct Snapshot: Codable {
        let version: Int
        let sessionID: ConversationID
        let journalByteCount: Int
        let journalDigest: String
        let records: [Record]
        let references: [SessionPayloadReference]
        let invalidated: Set<UUID>
        let erased: Set<UUID>
    }

    static let initialDigest = FileSessionIO.digest(Data("MIRA-SESSION-PREFIX-4".utf8))
    let sessionID: ConversationID
    var records: [Record] = []
    var references: [SessionPayloadReference] = []
    var invalidated: Set<UUID> = []
    var erased: Set<UUID> = []
    var savedRecordCount = 0
    var sourceIdentity: FileSessionIO.Identity?
    var byteCount: Int64 { records.last.map { $0.offset + Int64($0.byteCount) } ?? 0 }
    var head: SessionJournalHead {
        .init(cursor: .init(sessionID: sessionID, sequence: records.last?.sequence ?? 0), batchID: records.last?.id)
    }

    init(sessionID: ConversationID) { self.sessionID = sessionID }

    func firstRecord(after sequence: Int64) -> Int {
        var low = 0, high = records.count
        while low < high {
            let middle = low + (high - low) / 2
            if records[middle].sequence <= sequence { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Missing, stale, unsupported or damaged caches cause a strict source scan.
    /// Unsafe filesystem objects are rejected before the recoverable cache decode.
    static func load(at url: URL, journal: URL, sessionID: ConversationID,
                     authentication: FileSessionCacheAuthentication) throws -> FileSessionIndex? {
        guard let snapshot = try FileSessionCacheIO.load(Snapshot.self, at: url, format: "MIRA-SESSION-INDEX-4", authentication: authentication),
              snapshot.version == 4, snapshot.sessionID == sessionID,
              snapshot.journalByteCount >= 0 else { return nil }
        let index = FileSessionIndex(sessionID: sessionID)
        index.records = snapshot.records; index.references = snapshot.references
        index.invalidated = snapshot.invalidated; index.erased = snapshot.erased
        guard (try? index.validate()) != nil, index.byteCount == Int64(snapshot.journalByteCount) else { return nil }
        // Stat timestamps alone cannot establish that the source bytes are unchanged.
        let before = try FileSessionIO.identity(journal)
        let source = try BackupFileIO.inspect(journal, limit: Int.max)
        guard before == (try FileSessionIO.identity(journal)) else { throw FileSessionIO.failure() }
        guard source.byteCount == snapshot.journalByteCount, source.digest == snapshot.journalDigest else { return nil }
        index.sourceIdentity = before
        index.savedRecordCount = index.records.count
        return index
    }

    func save(at url: URL, journal: URL, authentication: FileSessionCacheAuthentication, fault: SessionStorageFaultInjector) throws {
        try validate()
        guard let sourceIdentity, sourceIdentity == (try FileSessionIO.identity(journal)) else { throw FileSessionIO.failure() }
        let source = try BackupFileIO.inspect(journal, limit: Int.max)
        guard source.byteCount == byteCount, sourceIdentity == (try FileSessionIO.identity(journal)) else { throw FileSessionIO.failure() }
        let snapshot = Snapshot(version: 4, sessionID: sessionID,
            journalByteCount: source.byteCount, journalDigest: source.digest,
            records: records, references: references, invalidated: invalidated, erased: erased)
        if try FileSessionCacheIO.save(snapshot, at: url, format: "MIRA-SESSION-INDEX-4",
            authentication: authentication,
            beforeWrite: { try fault(.beforeIndexWrite) }, afterWrite: { try fault(.afterIndexWrite) },
            beforePublication: { try fault(.beforeIndexPublication) }, afterPublication: { try fault(.afterIndexPublication) }) {
            savedRecordCount = records.count
        }
    }

    private func validate() throws {
        guard erased.isSubset(of: invalidated) else { throw FileSessionIO.failure() }
        var end: Int64 = 0, sequence: Int64 = 0
        var ids: Set<UUID> = []
        var prefix = Self.initialDigest
        for record in records {
            guard record.offset == end, record.expectedSequence == sequence,
                  record.sequence > sequence, record.sequence - sequence <= SessionFormatLimits.maximumEventsPerBatch,
                  (1...(FileSessionRecord.maximumBytes + 257)).contains(record.byteCount),
                  end <= Int64.max - Int64(record.byteCount), ids.insert(record.id).inserted,
                  record.digest.count == 64, record.digest.utf8.allSatisfy(Self.isHex) else { throw FileSessionIO.failure() }
            guard record.prefixDigest == FileSessionIO.digest(Data((prefix + record.digest).utf8)) else { throw FileSessionIO.failure() }
            prefix = record.prefixDigest
            end += Int64(record.byteCount); sequence = record.sequence
        }
        var referenceIDs: Set<UUID> = []
        for reference in references {
            try reference.validate()
            guard reference.sessionID == sessionID, ids.contains(reference.batchID),
                  referenceIDs.insert(reference.id).inserted else { throw FileSessionIO.failure() }
        }
    }

    private static func isHex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (97...102).contains(byte) }

}
