import Foundation
import Darwin
import MiraCore

public enum SessionStorageFaultStage: Sendable, Equatable {
    case beforeJournalWrite, afterJournalWrite, beforeJournalSync, afterJournalSync
    case beforeDirectorySync, afterDirectorySync
    case beforeIndexWrite, afterIndexWrite, beforeIndexPublication, afterIndexPublication
    case beforeCheckpointWrite, afterCheckpointWrite, beforeCheckpointPublication, afterCheckpointPublication
    case beforeRecoverySummaryWrite, afterRecoverySummaryWrite, beforeRecoverySummaryPublication, afterRecoverySummaryPublication
}
public typealias SessionStorageFaultInjector = @Sendable (SessionStorageFaultStage) throws -> Void

/// A single serial queue owns mutable indexes and all blocking filesystem operations.
public final class FileSessionLibrary: SessionCheckpointJournal, SessionContentStore, @unchecked Sendable {
    private typealias IO = FileSessionIO
    private let root: URL
    private let sessionsURL: URL
    private let indexesURL: URL
    private let checkpointsURL: URL
    private let checkpoints: FileSessionCheckpoints
    private let cacheAuthentication: FileSessionCacheAuthentication
    private var lockFD: Int32
    private let queue = DispatchQueue(label: "mira.session-library", qos: .utility)
    private let fault: SessionStorageFaultInjector
    private var closed = false
    private var fencedBatch: SessionBatch?
    private var indexes: [ConversationID: FileSessionIndex] = [:]
    private struct Location { let sessionID: ConversationID; let record: FileSessionIndex.Record }
    private var sessionIDs: [ConversationID] = []
    private var byID: [UUID: Location] = [:]
    private var references: [UUID: SessionContent] = [:]
    private var staged: [UUID: SessionContent] = [:]
    private var dirtyIndexes: Set<ConversationID> = []
    private var metrics = FileSessionReadMetrics()

    // Internal diagnostics contain counts only, and allow acceptance tests to prove bounded reads.
    func readMetrics() async -> FileSessionReadMetrics {
        await perform {
            var result = self.metrics
            result.restoredCheckpoints = self.checkpoints.restoredCount
            result.savedCheckpoints = self.checkpoints.savedCount
            result.restoredRecoverySummaries = self.checkpoints.restoredSummaryCount
            return result
        }
    }

    public init(directory: URL, faultInjector: SessionStorageFaultInjector? = nil) throws {
        guard directory.isFileURL else { throw IO.failure() }
        // Resolve OS directory aliases above the managed root, never links within it.
        root = directory.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(directory.lastPathComponent, isDirectory: true).standardizedFileURL
        sessionsURL = root.appendingPathComponent("sessions", isDirectory: true)
        indexesURL = root.appendingPathComponent("indexes", isDirectory: true)
        checkpointsURL = root.appendingPathComponent("checkpoints", isDirectory: true)
        fault = faultInjector ?? { _ in }
        try IO.ensureDirectory(root)
        try IO.checkDirectory(sessionsURL, allowMissing: true)
        try IO.checkDirectory(indexesURL, allowMissing: true)
        try IO.checkDirectory(checkpointsURL, allowMissing: true)
        let fd = Darwin.open(root.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw IO.failure() }
        do { try IO.requireRegular(fd) } catch { Darwin.close(fd); throw error }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); throw MiraError(.busy, "The session library already has a writer.")
        }
        lockFD = fd
        do {
            cacheAuthentication = try FileSessionCacheAuthentication(directory: root)
            checkpoints = FileSessionCheckpoints(directory: checkpointsURL, authentication: cacheAuthentication, fault: fault)
            try IO.ensureDirectory(sessionsURL)
            try IO.ensureDirectory(indexesURL); try IO.ensureDirectory(checkpointsURL)
            try FileSessionCacheIO.removeInterruptedWrites(in: indexesURL)
            try FileSessionCacheIO.removeInterruptedWrites(in: checkpointsURL)
            try IO.syncDirectory(root)
            try load()
        } catch {
            // A failure after all stored properties are initialized also runs
            // deinit. Relinquish ownership before closing: another thread may
            // reuse this descriptor number before destruction begins.
            lockFD = -1
            flock(fd, LOCK_UN); Darwin.close(fd)
            throw MiraError.safe(error)
        }
    }
    deinit {
        if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD) }
    }

    public func append(_ batch: SessionBatch) async -> SessionAppendOutcome {
        await perform { self.appendSync(batch) }
    }
    public func reconcile(_ batch: SessionBatch) async -> SessionAppendOutcome {
        await perform {
            guard !self.closed else { return .notCommitted(Self.closedError()) }
            guard let pending = self.fencedBatch else {
                if let location = self.byID[batch.id] {
                    do {
                        let existing = try self.read(location)
                        if existing == batch {
                            self.finishPayloadPublication(existing)
                            return .committed(existing.cursor)
                        }
                    } catch { return .notCommitted(MiraError.safe(error)) }
                }
                return .notCommitted(.init(.conflict, "There is no matching uncertain session batch."))
            }
            guard pending == batch else {
                return .notCommitted(.init(.conflict, "Only the original uncertain batch can be reconciled."))
            }
            do {
                try IO.checkDirectory(self.root); try IO.checkDirectory(self.sessionsURL)
                let known = self.indexes[batch.sessionID]?.records ?? []
                var count = 0
                var found: (SessionBatch, FileSessionIndex.Record, SessionLogState)?
                var logState = SessionLogState.initial
                var prefix = FileSessionIndex.initialDigest
                try IO.scanRecords(self.journalURL(batch.sessionID), sessionID: batch.sessionID) { value, offset, line, nextState in
                    let record = FileSessionIndex.Record(batch: value, offset: offset, line: line, previousDigest: prefix, firstSeq: logState.nextSeq)
                    logState = nextState
                    prefix = record.prefixDigest
                    if count < known.count {
                        guard record == known[count] else { throw IO.failure() }
                    } else {
                        guard count == known.count, value == batch else { throw IO.failure() }
                        found = (value, record, nextState)
                    }
                    count += 1
                }
                guard count >= known.count else { throw IO.failure() }
                if let (value, record, nextState) = found {
                    try self.validateReferences(value)
                    try self.synchronizePublication(value)
                    self.ingest(value, record: record, logState: nextState); self.fencedBatch = nil
                    self.finishPayloadPublication(value)
                    self.saveIndexIfDue(value.sessionID)
                    return .committed(value.cursor)
                }
                // Any partial tail has been durably removed. Retry the original immutable record.
                self.fencedBatch = nil
                return self.appendSync(batch)
            } catch { return .indeterminate(MiraError.safe(error)) }
        }
    }
    public func batch(id: UUID, sessionID: ConversationID) async throws -> SessionBatch? {
        try await performThrowing {
            try self.requireOpen()
            guard let location = self.byID[id], location.sessionID == sessionID else { return nil }
            return try self.read(location)
        }
    }
    public func head(sessionID: ConversationID) async throws -> SessionJournalHead {
        try await performThrowing {
            try self.requireOpen()
            return self.indexes[sessionID]?.head ?? SessionJournalHead(cursor: .init(sessionID: sessionID, sequence: 0), batchID: nil)
        }
    }
    public func read(sessionID: ConversationID, after sequence: Int64, limit: Int) async throws -> [SessionBatch] {
        try await performThrowing {
            try self.requireOpen(); try Self.validatePage(limit)
            guard sequence >= 0 else { throw MiraError(.invalidInput, "The session cursor is invalid.") }
            guard let index = self.indexes[sessionID] else { return [] }
            let start = index.firstRecord(after: sequence)
            return try index.records[start..<min(start + limit, index.records.count)].map {
                try self.read(Location(sessionID: sessionID, record: $0))
            }
        }
    }
    public func recoverySummary(through head: SessionJournalHead, extensionSchemas: [String: Set<Int>]) async throws -> SessionRecoverySummary? {
        try await performThrowing {
            try self.requireOpen(); try head.validate()
            guard self.fencedBatch == nil, let index = self.indexes[head.cursor.sessionID] else { return nil }
            try self.validateCheckpointSource(index)
            return try self.checkpoints.recoverySummary(through: head, schemas: extensionSchemas, index: index)
        }
    }
    public func checkpoint(through head: SessionJournalHead, extensionSchemas: [String: Set<Int>]) async throws -> SessionJournalSnapshot? {
        try await performThrowing {
            try self.requireOpen(); try head.validate()
            guard self.fencedBatch == nil else { return nil }
            guard let index = self.indexes[head.cursor.sessionID] else { return nil }
            try self.validateCheckpointSource(index)
            return try self.checkpoints.load(through: head, schemas: extensionSchemas, index: index)
        }
    }
    public func cache(_ snapshot: SessionJournalSnapshot, extensionSchemas: [String: Set<Int>]) async {
        await perform {
            guard !self.closed, self.fencedBatch == nil, let index = self.indexes[snapshot.head.cursor.sessionID],
                  (try? self.validateCheckpointSource(index)) != nil else { return }
            self.checkpoints.cache(snapshot, schemas: extensionSchemas, index: index)
        }
    }
    private func validateCheckpointSource(_ index: FileSessionIndex) throws {
        try IO.checkDirectory(root); try IO.checkDirectory(sessionsURL)
        guard let identity = index.sourceIdentity, identity == (try IO.identity(journalURL(index.sessionID))) else { throw IO.failure() }
    }

    public func sessions(after: ConversationID?, limit: Int) async throws -> [ConversationID] {
        try await performThrowing {
            try self.requireOpen(); try Self.validatePage(limit)
            let start: Int
            if let after {
                var low = 0, high = self.sessionIDs.count
                while low < high {
                    let middle = low + (high - low) / 2
                    if self.sessionIDs[middle].rawValue.uuidString <= after.rawValue.uuidString { low = middle + 1 } else { high = middle }
                }
                start = low
            } else { start = 0 }
            return Array(self.sessionIDs[start..<min(start + limit, self.sessionIDs.count)])
        }
    }
    public func flush() async throws {
        try await performThrowing {
            try self.requireOpen()
            guard self.fencedBatch == nil else { throw MiraError(.busy, "An uncertain session batch requires reconciliation.") }
            for id in self.indexes.keys { try IO.syncFile(self.journalURL(id)) }
            try IO.syncDirectory(self.sessionsURL)
            self.saveDirtyIndexes(); self.checkpoints.flush()
        }
    }
    public func close() async throws {
        try await performThrowing {
            guard !self.closed else { return }
            if self.fencedBatch == nil { self.saveDirtyIndexes(); self.checkpoints.flush() }
            // Earlier operations have drained the queue. An uncertain record remains recoverable on disk.
            self.closed = true
            flock(self.lockFD, LOCK_UN)
        }
    }

    public func withSnapshot<T: Sendable>(_ operation: @escaping @Sendable (FileSessionSnapshot) throws -> T) async throws -> T {
        try await performThrowing {
            try self.requireOpen()
            guard self.fencedBatch == nil else { throw MiraError(.busy, "An uncertain session batch requires reconciliation.") }
            guard self.sessionIDs.count <= FileSessionArchive.maximumSessions else { throw IO.failure() }
            try IO.checkDirectory(self.root); try IO.checkDirectory(self.sessionsURL)
            var sessions: [FileSessionSnapshot.Session] = []
            for id in self.sessionIDs {
                guard let index = self.indexes[id], index.records.count <= FileSessionArchive.maximumRecords else { throw IO.failure() }
                let values = try index.records.map { try self.read(Location(sessionID: id, record: $0)) }
                guard let last = values.last,
                      try IO.scanStrict(self.journalURL(id), sessionID: id, maximumRecords: FileSessionArchive.maximumRecords) == values else { throw IO.failure() }
                sessions.append(.init(id: id, head: .init(cursor: last.cursor, batchID: last.id),
                    journalURL: self.journalURL(id)))
            }
            let snapshot = FileSessionSnapshot(sessions: sessions)
            return try operation(snapshot)
        }
    }

    public func stage(_ data: Data, sessionID: ConversationID, batchID: UUID,
                      kind: SessionContentKind) async throws -> SessionContent {
        try await performThrowing {
            try self.requireOpen()
            guard self.fencedBatch == nil, self.byID[batchID] == nil,
                  data.count <= SessionFormatLimits.maximumContentBytes else {
                throw MiraError(.invalidInput, "The session content cannot be prepared for this batch.")
            }
            let content = SessionContent(kind: kind, bytes: data)
            self.staged[content.id] = content
            return content
        }
    }
    public func read(_ reference: SessionContent) async throws -> Data {
        try await performThrowing {
            try self.requireOpen()
            guard self.references[reference.id] == reference else {
                throw MiraError(.notFound, "The session payload is unavailable.")
            }
            return try self.payloadBytes(reference)
        }
    }
    private func appendSync(_ batch: SessionBatch) -> SessionAppendOutcome {
        var writeStarted = false
        do {
            try requireOpen()
            guard fencedBatch == nil else { return .notCommitted(.init(.busy, "An uncertain session batch requires reconciliation.")) }
            try batch.validate()
            if let location = byID[batch.id] {
                let previous = try read(location)
                guard previous == batch else { throw MiraError(.conflict, "The session batch identity is already used.") }
                finishPayloadPublication(previous)
                return .committed(previous.cursor)
            }
            guard (indexes[batch.sessionID]?.head.cursor.sequence ?? 0) == batch.expectedSequence else {
                throw MiraError(.conflict, "The session sequence is stale.")
            }
            try validateReferences(batch)
            let previous = indexes[batch.sessionID]?.logState ?? .initial
            let encoded = try IO.frame(batch, previous: previous)
            let line = encoded.bytes
            let offset = indexes[batch.sessionID]?.byteCount ?? 0
            try IO.checkDirectory(root); try IO.checkDirectory(sessionsURL)
            if let index = indexes[batch.sessionID] { try validateCheckpointSource(index) }
            try fault(.beforeJournalWrite)
            // An open/write attempt may leave a new file or partial record even when it reports failure.
            writeStarted = true
            let fd = Darwin.open(journalURL(batch.sessionID).path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw IO.failure() }
            do {
                try IO.requireRegular(fd)
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_size == offset else { throw IO.failure() }
                try IO.write(line + Data([10]), fd: fd)
                try fault(.afterJournalWrite); try fault(.beforeJournalSync)
                try IO.sync(fd); try fault(.afterJournalSync)
                Darwin.close(fd)
            } catch { Darwin.close(fd); throw error }
            try syncDirectory(sessionsURL)
            ingest(batch, record: .init(batch: batch, offset: offset, line: line, previousDigest: indexes[batch.sessionID]?.records.last?.prefixDigest ?? FileSessionIndex.initialDigest, firstSeq: previous.nextSeq), logState: encoded.state)
            finishPayloadPublication(batch)
            saveIndexIfDue(batch.sessionID)
            return .committed(batch.cursor)
        } catch {
            if writeStarted { fencedBatch = batch; return .indeterminate(MiraError.safe(error)) }
            return .notCommitted(MiraError.safe(error))
        }
    }
    private func validateReferences(_ batch: SessionBatch) throws {
        var additions: [UUID: SessionContent] = [:]
        for reference in batch.events.flatMap(\.fact.payloadReferences) {
            if let previous = references[reference.id] ?? additions[reference.id] {
                guard previous == reference else { throw IO.failure() }
            } else {
                guard staged[reference.id] == reference else { throw IO.failure() }
                additions[reference.id] = reference
            }
            _ = try payloadBytes(reference)
        }
    }
    private func ingest(_ batch: SessionBatch, record: FileSessionIndex.Record, logState: SessionLogState) {
        if indexes[batch.sessionID] == nil {
            var low = 0, high = sessionIDs.count
            let key = batch.sessionID.rawValue.uuidString
            while low < high {
                let middle = low + (high - low) / 2
                if sessionIDs[middle].rawValue.uuidString < key { low = middle + 1 } else { high = middle }
            }
            sessionIDs.insert(batch.sessionID, at: low)
        }
        let index = indexes[batch.sessionID] ?? FileSessionIndex(sessionID: batch.sessionID)
        index.records.append(record); index.logState = logState; indexes[batch.sessionID] = index
        index.sourceIdentity = try? IO.identity(journalURL(batch.sessionID))
        byID[batch.id] = Location(sessionID: batch.sessionID, record: record)
        dirtyIndexes.insert(batch.sessionID)
        for event in batch.events {
            for reference in event.fact.payloadReferences {
                if references[reference.id] == nil { index.references.append(reference) }
                references[reference.id] = reference; staged[reference.id] = nil
            }

        }
    }
    private func load() throws {
        let journals = try FileManager.default.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in journals {
            guard url.pathExtension == "jsonl", let uuid = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  url.deletingPathExtension().lastPathComponent == uuid.uuidString else { throw IO.failure() }
            let sessionID = ConversationID(uuid)
            if let index = try FileSessionIndex.load(at: indexURL(sessionID), journal: url, sessionID: sessionID,
                                                     authentication: cacheAuthentication) {
                for record in index.records {
                    guard byID[record.id] == nil else { throw IO.failure() }
                    byID[record.id] = Location(sessionID: sessionID, record: record)
                }
                for reference in index.references {
                    guard references[reference.id] == nil else { throw IO.failure() }
                    references[reference.id] = reference
                }
                if !index.records.isEmpty { indexes[sessionID] = index; sessionIDs.append(sessionID) }
                metrics.indexedSessions += 1
                metrics.verifiedJournalBytes += index.byteCount
            } else {
                try IO.scanRecords(url, sessionID: sessionID) { batch, offset, line, logState in
                    metrics.scannedBatches += 1
                    guard byID[batch.id] == nil else { throw IO.failure() }
                    var currentReferences: [UUID: SessionContent] = [:]
                    for reference in batch.events.flatMap(\.fact.payloadReferences) {
                        if let previous = references[reference.id] ?? currentReferences[reference.id] {
                            guard previous == reference else { throw IO.failure() }
                        }
                        currentReferences[reference.id] = reference
                    }
                    ingest(batch, record: .init(batch: batch, offset: offset, line: line, previousDigest: indexes[batch.sessionID]?.records.last?.prefixDigest ?? FileSessionIndex.initialDigest, firstSeq: indexes[batch.sessionID]?.logState.nextSeq ?? 0), logState: logState)
                }
            }
            try IO.syncFile(url)
            indexes[sessionID]?.sourceIdentity = try IO.identity(url)
        }
        try IO.syncDirectory(sessionsURL)
        saveDirtyIndexes()
    }

    private func finishPayloadPublication(_ batch: SessionBatch) {
        for reference in batch.events.flatMap(\.fact.payloadReferences) { staged[reference.id] = nil }
    }

    private func read(_ location: Location) throws -> SessionBatch {
        try IO.checkDirectory(root); try IO.checkDirectory(sessionsURL)
        guard let index = indexes[location.sessionID] else { throw IO.failure() }
        let batch = try IO.readRecord(journalURL(location.sessionID), sessionID: location.sessionID, record: location.record, state: index.logState)
        metrics.pageDecodedBatches += 1
        return batch
    }
    private func indexURL(_ id: ConversationID) -> URL { indexesURL.appendingPathComponent(id.rawValue.uuidString + ".index") }
    private func saveIndexIfDue(_ id: ConversationID) {
        guard let index = indexes[id], index.records.count >= max(64, index.savedRecordCount * 2) else { return }
        saveIndex(id)
    }
    private func saveDirtyIndexes() {
        for id in dirtyIndexes { saveIndex(id) }
    }
    private func saveIndex(_ id: ConversationID) {
        guard fencedBatch == nil, let index = indexes[id] else { return }
        do {
            try IO.checkDirectory(root); try IO.checkDirectory(indexesURL)
            try index.save(at: indexURL(id), journal: journalURL(id), authentication: cacheAuthentication, fault: fault)
            if index.savedRecordCount == index.records.count { dirtyIndexes.remove(id) }
        } catch {
            // The acknowledged journal is unaffected. A later save or strict scan rebuilds this cache.
        }
    }

    private func synchronizePublication(_ batch: SessionBatch) throws {
        try fault(.beforeJournalSync); try IO.syncFile(journalURL(batch.sessionID)); try fault(.afterJournalSync)
        try syncDirectory(sessionsURL)
    }
    private func payloadBytes(_ reference: SessionContent) throws -> Data {
        try reference.validate()
        return reference.bytes
    }
    private func syncDirectory(_ url: URL) throws {
        try fault(.beforeDirectorySync); try IO.syncDirectory(url); try fault(.afterDirectorySync)
    }
    private func journalURL(_ id: ConversationID) -> URL { sessionsURL.appendingPathComponent(id.rawValue.uuidString + ".jsonl") }
    private func requireOpen() throws { if closed { throw Self.closedError() } }
    private static func closedError() -> MiraError { .init(.busy, "The session library is closed.") }
    private static func validatePage(_ limit: Int) throws {
        guard (1...SessionFormatLimits.maximumReadBatches).contains(limit) else { throw MiraError(.invalidInput, "The session page size is invalid.") }
    }
    private func perform<T: Sendable>(_ operation: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: operation()) } }
    }
    private func performThrowing<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { do { continuation.resume(returning: try operation()) } catch { continuation.resume(throwing: MiraError.safe(error)) } }
        }
    }
}

struct FileSessionReadMetrics: Sendable, Equatable {
    var restoredRecoverySummaries = 0
    var restoredCheckpoints = 0
    var savedCheckpoints = 0
    var indexedSessions = 0
    var scannedBatches = 0
    var pageDecodedBatches = 0
    var verifiedJournalBytes: Int64 = 0
}
