import Foundation
import MiraCore

/// Metadata and URLs are valid only while the owning snapshot callback is running.
public struct FileSessionSnapshot: Sendable {
    public struct Session: Sendable {
        public let id: ConversationID
        public let head: SessionJournalHead
        public let journalURL: URL
        public let payloads: [SessionPayloadReference: URL]
        public let activeDraft: SessionActiveDraft?
        let invalidated: Set<UUID>
        let erased: Set<UUID>
        init(id: ConversationID, head: SessionJournalHead, journalURL: URL,
             payloads: [SessionPayloadReference: URL], invalidated: Set<UUID> = [], erased: Set<UUID> = [],
             activeDraft: SessionActiveDraft? = nil) {
            self.id = id; self.head = head; self.journalURL = journalURL
            self.payloads = payloads; self.invalidated = invalidated; self.erased = erased
            self.activeDraft = activeDraft
        }
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

    /// Archive validation reads retained physical history, including retired tool
    /// proofs. This is not a conversation read authorization API. Only an explicit
    /// erasure can explain a missing body. Inline text is loaded on demand.
    func readRetainedPayload(_ reference: SessionPayloadReference) throws -> Data? {
        guard let session = session(reference.sessionID) else { throw FileSessionIO.failure() }
        var verified = false
        var result: Data?
        let batches = try FileSessionIO.scanStrict(session.journalURL, sessionID: session.id,
            maximumRecords: FileSessionArchive.maximumRecords) { record in
            guard record.batch.events.flatMap(\.fact.payloadReferences).contains(reference) else { return }
            verified = true
            if reference.storage == .inline {
                guard let text = record.payloads[reference.id.uuidString] else {
                    // A missing body is valid only when the exact reference was purged.
                    return
                }
                let bytes = Data(text.utf8)
                guard bytes.count == reference.byteCount, FileSessionIO.digest(bytes) == reference.digest else {
                    throw FileSessionIO.failure()
                }
                result = bytes
            }
        }
        guard let last = batches.last, last.id == session.head.batchID, last.cursor == session.head.cursor,
            verified else { throw FileSessionIO.failure() }
        if session.erased.contains(reference.retentionGroup) { return nil }
        if let result { return result }
        guard reference.storage == .external, let url = session.payloads[reference] else {
            throw FileSessionIO.failure()
        }
        let bytes = try FileSessionIO.readBounded(url, expectedCount: reference.byteCount)
        guard FileSessionIO.digest(bytes) == reference.digest else { throw FileSessionIO.failure() }
        return bytes
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
        let roots = try FileSessionIO.directoryEntries(root, limit: 3)
        let rootNames = Set(roots.map(\.lastPathComponent))
        guard rootNames == ["sessions", "payloads"] || rootNames == ["sessions", "payloads", "drafts"] else {
            throw FileSessionIO.failure()
        }
        let sessionsURL = root.appendingPathComponent("sessions", isDirectory: true)
        let payloadsURL = root.appendingPathComponent("payloads", isDirectory: true)
        let draftsURL = root.appendingPathComponent("drafts", isDirectory: true)
        try FileSessionIO.checkDirectory(payloadsURL)
        if rootNames.contains("drafts") { try FileSessionIO.checkDirectory(draftsURL) }
        let entries = try FileSessionIO.directoryEntries(sessionsURL, limit: maximumSessions)
        var sessions: [FileSessionSnapshot.Session] = []
        var expectedFiles: Set<String> = []
        var expectedDirectories: Set<String> = []
        var attemptEligibility: [ConversationID: [UUID: (attempt: SessionAttempt, epoch: UInt64)]] = [:]
        var resolvedAttempts: [ConversationID: Set<UUID>] = [:]
        var finishedExecutions: [ConversationID: Set<ExecutionID>] = [:]
        var referenceCount = 0
        for journal in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let stem = journal.deletingPathExtension().lastPathComponent
            guard journal.pathExtension == "jsonl", let uuid = UUID(uuidString: stem), uuid.uuidString == stem else {
                throw FileSessionIO.failure()
            }
            let id = ConversationID(uuid)
            let batches = try FileSessionIO.scanStrict(journal, sessionID: id, maximumRecords: maximumRecords)
            guard let last = batches.last else { throw FileSessionIO.failure() }
            var epochs: [ExecutionID: UInt64] = [:]
            var attempts: [UUID: (attempt: SessionAttempt, epoch: UInt64)] = [:]
            var resolved: Set<UUID> = []
            var finished: Set<ExecutionID> = []
            for batch in batches {
                for event in batch.events {
                    switch event.fact {
                    case .admitted(let admission): epochs[admission.executionID] = admission.authorizationEpoch
                    case .attemptStarted(let attempt):
                        guard let epoch = epochs[attempt.executionID] else { throw FileSessionIO.failure() }
                        attempts[attempt.id] = (attempt, epoch)
                    case .attemptResolved(let resolution): resolved.insert(resolution.attemptID)
                    case .finished(let completion): finished.insert(completion.executionID)
                    default: break
                    }
                }
            }
            attemptEligibility[id] = attempts
            resolvedAttempts[id] = resolved
            finishedExecutions[id] = finished
            let retained = try references(in: batches)
            _ = try FileSessionIO.scanStrict(journal, sessionID: id, maximumRecords: maximumRecords) { record in
                try validateInline(record, erased: retained.erased)
            }
            referenceCount += retained.references.count
            guard referenceCount <= maximumReferences else { throw FileSessionIO.failure() }
            var live: [SessionPayloadReference: URL] = [:]
            for reference in retained.references.values
                where reference.storage == .external && !retained.erased.contains(reference.retentionGroup) {
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
                .init(id: id, head: .init(cursor: last.cursor, batchID: last.id), journalURL: journal,
                    payloads: live, invalidated: retained.invalidated, erased: retained.erased))
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
        if rootNames.contains("drafts") {
            let entries = try FileSessionIO.directoryEntries(draftsURL, limit: maximumSessions)
            var drafts: [ConversationID: SessionActiveDraft] = [:]
            for file in entries {
                let stem = file.deletingPathExtension().lastPathComponent
                guard file.pathExtension == "json", let uuid = UUID(uuidString: stem), uuid.uuidString == stem else {
                    throw FileSessionIO.failure()
                }
                try LibraryArchiveIO.requireSingleFile(file)
                var info = stat()
                guard lstat(file.path, &info) == 0, info.st_size >= 0,
                    info.st_size <= off_t(SessionActiveDraft.maximumBytes) else { throw FileSessionIO.failure() }
                let bytes = try FileSessionIO.readBounded(file, expectedCount: Int(info.st_size))
                let draft = try SessionCodec.decode(SessionActiveDraft.self, from: bytes)
                guard try SessionCodec.encode(draft) == bytes, drafts[ConversationID(uuid)] == nil else {
                    throw FileSessionIO.failure()
                }
                try draft.validate()
                guard let sessionIndex = sessions.firstIndex(where: { $0.id == ConversationID(uuid) }) else {
                    throw FileSessionIO.failure()
                }
                guard let eligibility = attemptEligibility[ConversationID(uuid)]?[draft.attemptID],
                    draft.request.sessionID == ConversationID(uuid),
                    eligibility.attempt.request == draft.request,
                    eligibility.attempt.executionID == draft.executionID,
                    eligibility.epoch == draft.authorizationEpoch,
                    !resolvedAttempts[ConversationID(uuid), default: []].contains(draft.attemptID),
                    !finishedExecutions[ConversationID(uuid), default: []].contains(draft.executionID),
                    sessions[sessionIndex].payloads[draft.request] != nil || draft.request.storage == .inline,
                    draft.request.kind == .request,
                    !sessions[sessionIndex].invalidated.contains(draft.request.retentionGroup) else {
                    throw FileSessionIO.failure()
                }
                drafts[ConversationID(uuid)] = draft
            }
            for index in sessions.indices {
                sessions[index] = .init(id: sessions[index].id, head: sessions[index].head,
                    journalURL: sessions[index].journalURL, payloads: sessions[index].payloads,
                    invalidated: sessions[index].invalidated, erased: sessions[index].erased,
                    activeDraft: drafts[sessions[index].id])
            }
        }
        return .init(sessions: sessions)
    }

    static func references(in batches: [SessionBatch]) throws -> (
        references: [UUID: SessionPayloadReference], invalidated: Set<UUID>, erased: Set<UUID>
    ) {
        var references: [UUID: SessionPayloadReference] = [:]
        var invalidated: Set<UUID> = []
        var erased: Set<UUID> = []
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
                    erased.formUnion(fact.retentionGroups)
                case .retryCleared(let fact): invalidated.formUnion(fact.retentionGroups)
                default: break
                }
            }
        }
        return (references, invalidated, erased)
    }

    /// Validates the record-local inline map against physically erased groups.
    /// Retired-but-retained content remains present; erased content must be absent.
    static func validateInline(_ record: FileSessionRecord, erased: Set<UUID>) throws {
        var owned: [String: SessionPayloadReference] = [:]
        for reference in record.batch.events.flatMap(\.fact.payloadReferences)
            where reference.batchID == record.batch.id && reference.storage == .inline {
            owned[reference.id.uuidString] = reference
        }
        for (id, text) in record.payloads {
            guard UUID(uuidString: id)?.uuidString == id, let reference = owned[id],
                !erased.contains(reference.retentionGroup) else { throw FileSessionIO.failure() }
            let bytes = Data(text.utf8)
            guard bytes.count == reference.byteCount, FileSessionIO.digest(bytes) == reference.digest else {
                throw FileSessionIO.failure()
            }
        }
        for (id, reference) in owned where !erased.contains(reference.retentionGroup) {
            guard record.payloads[id] != nil else { throw FileSessionIO.failure() }
        }
    }
}
