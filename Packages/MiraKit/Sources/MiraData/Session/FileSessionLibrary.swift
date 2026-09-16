import Foundation
import Darwin
import MiraCore

public enum SessionStorageFaultStage: Sendable, Equatable {
    case beforePayloadWrite, afterPayloadWrite, beforePayloadSync, afterPayloadSync
    case beforeJournalWrite, afterJournalWrite, beforeJournalSync, afterJournalSync
    case beforePayloadPublication, afterPayloadPublication
    case beforePayloadDelete, afterPayloadDelete
    case beforeDirectorySync, afterDirectorySync
    case beforeIndexWrite, afterIndexWrite, beforeIndexPublication, afterIndexPublication
    case beforeCheckpointWrite, afterCheckpointWrite, beforeCheckpointPublication, afterCheckpointPublication
    case beforeRecoverySummaryWrite, afterRecoverySummaryWrite, beforeRecoverySummaryPublication, afterRecoverySummaryPublication
    case beforeInlinePurgeWrite, afterInlinePurgeWrite, beforeInlinePurgePublication, afterInlinePurgePublication
    case beforePendingPayloadMark, afterPendingPayloadMark, beforePendingPayloadClear, afterPendingPayloadClear
    case beforeActiveDraftWrite, afterActiveDraftWrite, beforeActiveDraftSync, afterActiveDraftSync
    case beforeActiveDraftPublication, afterActiveDraftPublication
    case beforeActiveDraftDelete, afterActiveDraftDelete
}
public typealias SessionStorageFaultInjector = @Sendable (SessionStorageFaultStage) throws -> Void

/// A single serial queue owns mutable indexes and all blocking filesystem operations.
public final class FileSessionLibrary: SessionCheckpointJournal, SessionPayloadMaintenance, SessionActiveDraftStore, @unchecked Sendable {
    private typealias IO = FileSessionIO
    private let root: URL
    private let sessionsURL: URL
    private let payloadsURL: URL
    private let indexesURL: URL
    private let checkpointsURL: URL
    private let activeDraftsURL: URL
    private let checkpoints: FileSessionCheckpoints
    private let pendingPayloads: FileSessionPendingPayloads
    private let activeDrafts: FileSessionActiveDrafts
    private let cacheAuthentication: FileSessionCacheAuthentication
    private let lockFD: Int32
    private let queue = DispatchQueue(label: "mira.session-library", qos: .utility)
    private let fault: SessionStorageFaultInjector
    private var closed = false
    private var fencedBatch: SessionBatch?
    private var indexes: [ConversationID: FileSessionIndex] = [:]
    private struct Location { let sessionID: ConversationID; let record: FileSessionIndex.Record }
    private var sessionIDs: [ConversationID] = []
    private var byID: [UUID: Location] = [:]
    private var references: [UUID: SessionPayloadReference] = [:]
    private var invalidated: [ConversationID: Set<UUID>] = [:]
    private var erased: [ConversationID: Set<UUID>] = [:]
    private var staged: [UUID: SessionPayloadReference] = [:]
    private var stagedInline: [UUID: String] = [:]
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
        payloadsURL = root.appendingPathComponent("payloads", isDirectory: true)
        indexesURL = root.appendingPathComponent("indexes", isDirectory: true)
        checkpointsURL = root.appendingPathComponent("checkpoints", isDirectory: true)
        activeDraftsURL = root.appendingPathComponent("active-drafts", isDirectory: true)
        fault = faultInjector ?? { _ in }
        pendingPayloads = FileSessionPendingPayloads(
            directory: root.appendingPathComponent("pending-payloads", isDirectory: true), fault: fault)
        try IO.ensureDirectory(root)
        try IO.checkDirectory(sessionsURL, allowMissing: true)
        try IO.checkDirectory(payloadsURL, allowMissing: true)
        try IO.checkDirectory(indexesURL, allowMissing: true)
        try IO.checkDirectory(checkpointsURL, allowMissing: true)
        try IO.checkDirectory(activeDraftsURL, allowMissing: true)
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
            activeDrafts = try FileSessionActiveDrafts(directory: activeDraftsURL, authentication: cacheAuthentication, fault: fault)
            try IO.ensureDirectory(sessionsURL); try IO.ensureDirectory(payloadsURL)
            try IO.ensureDirectory(indexesURL); try IO.ensureDirectory(checkpointsURL); try IO.ensureDirectory(activeDraftsURL)
            try FileSessionCacheIO.removeInterruptedWrites(in: indexesURL)
            try FileSessionCacheIO.removeInterruptedWrites(in: checkpointsURL)
            try IO.syncDirectory(root)
            try load()
        } catch {
            flock(fd, LOCK_UN); Darwin.close(fd)
            throw MiraError.safe(error)
        }
    }
    deinit { flock(lockFD, LOCK_UN); Darwin.close(lockFD) }

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
                var found: (SessionBatch, FileSessionIndex.Record)?
                var prefix = FileSessionIndex.initialDigest
                try IO.scanRecords(self.journalURL(batch.sessionID), sessionID: batch.sessionID) { physical, offset, line in
                    let value = physical.batch
                    let record = FileSessionIndex.Record(batch: value, offset: offset, line: line, previousDigest: prefix)
                    prefix = record.prefixDigest
                    if count < known.count {
                        guard record == known[count] else { throw IO.failure() }
                    } else {
                        guard count == known.count, value == batch else { throw IO.failure() }
                        found = (value, record)
                    }
                    count += 1
                }
                guard count >= known.count else { throw IO.failure() }
                if let (value, record) = found {
                    try self.validateReferences(value)
                    try self.synchronizePublication(value)
                    self.ingest(value, record: record); self.fencedBatch = nil
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
            try IO.checkDirectory(self.payloadsURL)
            var sessions: [FileSessionSnapshot.Session] = []
            var referenceCount = 0
            for id in self.sessionIDs {
                guard let index = self.indexes[id], index.records.count <= FileSessionArchive.maximumRecords else { throw IO.failure() }
                let values = try index.records.map { try self.read(Location(sessionID: id, record: $0)) }
                guard let last = values.last else { throw IO.failure() }
                guard try IO.scanStrict(self.journalURL(id), sessionID: id,
                    maximumRecords: FileSessionArchive.maximumRecords,
                    consume: { try FileSessionArchive.validateInline($0, erased: self.erased[id, default: []]) }) == values else { throw IO.failure() }
                let retained = try FileSessionArchive.references(in: values)
                guard retained.invalidated == self.invalidated[id, default: []], retained.erased == self.erased[id, default: []] else { throw IO.failure() }
                referenceCount += retained.references.count
                guard referenceCount <= FileSessionArchive.maximumReferences else { throw IO.failure() }
                var live: [SessionPayloadReference: URL] = [:]
                for reference in retained.references.values {
                    guard self.references[reference.id] == reference else { throw IO.failure() }
                    if reference.storage == .inline { continue }
                    let url = self.payloadURL(reference)
                    if retained.erased.contains(reference.retentionGroup) {
                        try self.checkPayloadAncestors(url, allowMissing: true)
                        var info = stat()
                        guard lstat(url.path, &info) == -1, errno == ENOENT else { throw IO.failure() }
                    } else {
                        try self.checkPayloadAncestors(url)
                        try IO.validateFile(url, expectedCount: reference.byteCount, expectedDigest: reference.digest)
                        live[reference] = url
                    }
                }
                var activeDraft = try self.activeDrafts.load(sessionID: id)
                if let draft = activeDraft {
                    try draft.validate()
                    guard draft.request.sessionID == id,
                        draft.request.kind == .request,
                        retained.references[draft.request.id] == draft.request,
                        !retained.invalidated.contains(draft.request.retentionGroup) else {
                        throw IO.failure()
                    }
                    var epoch: UInt64?
                    var started: SessionAttempt?
                    var resolved = false
                    var finished = false
                    for value in values {
                        for event in value.events {
                            switch event.fact {
                            case .admitted(let admission) where admission.executionID == draft.executionID:
                                epoch = admission.authorizationEpoch
                            case .attemptStarted(let attempt) where attempt.id == draft.attemptID:
                                started = attempt
                            case .attemptResolved(let resolution) where resolution.attemptID == draft.attemptID:
                                resolved = true
                            case .finished(let completion) where completion.executionID == draft.executionID:
                                finished = true
                            default: break
                            }
                        }
                    }
                    if started?.request != draft.request || started?.executionID != draft.executionID ||
                        epoch != draft.authorizationEpoch || resolved || finished {
                        activeDraft = nil
                    }
                }
                sessions.append(.init(id: id, head: .init(cursor: last.cursor, batchID: last.id),
                    journalURL: self.journalURL(id), payloads: live, invalidated: retained.invalidated,
                    erased: retained.erased, activeDraft: activeDraft))
            }
            let snapshot = FileSessionSnapshot(sessions: sessions)
            return try operation(snapshot)
        }
    }

    public func stage(_ data: Data, sessionID: ConversationID, batchID: UUID, retentionGroup: UUID,
                      kind: SessionPayloadKind) async throws -> SessionPayloadReference {
        try await performThrowing {
            try self.requireOpen()
            guard self.fencedBatch == nil else { throw MiraError(.busy, "An uncertain session batch requires reconciliation.") }
            guard data.count <= SessionFormatLimits.maximumPayloadBytes, self.byID[batchID] == nil,
                  !self.invalidated[sessionID, default: []].contains(retentionGroup) else {
                throw MiraError(.invalidInput, "The payload cannot be staged for this batch.")
            }
            let text = data.count <= FileSessionRecord.maximumInlineBytes ? String(data: data, encoding: .utf8) : nil
            let used = try self.stagedInline.reduce(0) { sum, item in
                guard self.staged[item.key]?.batchID == batchID else { return sum }
                return sum + (try SessionCodec.encode(item.value).count)
            }
            let useInline = try text.map {
                guard Data($0.utf8) == data else { return false }
                return try SessionCodec.encode($0).count <= FileSessionRecord.maximumInlineBatchBytes - used
            } ?? false
            let reference = SessionPayloadReference(id: UUID(), sessionID: sessionID, batchID: batchID,
                retentionGroup: retentionGroup, kind: kind, byteCount: data.count, digest: IO.digest(data), storage: useInline ? .inline : .external)
            if useInline, let text {
                self.staged[reference.id] = reference
                self.stagedInline[reference.id] = text
                return reference
            }
            let sessionDirectory = self.payloadsURL.appendingPathComponent(sessionID.rawValue.uuidString)
            let batchDirectory = sessionDirectory.appendingPathComponent(batchID.uuidString)
            try IO.checkDirectory(self.root); try IO.checkDirectory(self.payloadsURL)
            try self.pendingPayloads.begin(.init(sessionID: sessionID, batchID: batchID))
            try IO.ensureDirectory(sessionDirectory); try IO.ensureDirectory(batchDirectory)
            let temporary = batchDirectory.appendingPathComponent(".stage-\(UUID().uuidString)")
            let destination = self.payloadURL(reference)
            var ownsTemporary = false
            var ownsDestination = false
            do {
                try self.fault(.beforePayloadWrite)
                let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw IO.failure() }
                ownsTemporary = true
                do {
                    try IO.write(data, fd: fd)
                    try self.fault(.afterPayloadWrite); try self.fault(.beforePayloadSync)
                    try IO.sync(fd); try self.fault(.afterPayloadSync)
                    Darwin.close(fd)
                } catch { Darwin.close(fd); throw error }
                try self.fault(.beforePayloadPublication)
                try IO.publishExclusive(temporary, to: destination)
                ownsTemporary = false; ownsDestination = true
                try self.fault(.afterPayloadPublication)
                try self.syncDirectory(batchDirectory); try self.syncDirectory(sessionDirectory)
                try self.syncDirectory(self.payloadsURL)
                self.staged[reference.id] = reference
                return reference
            } catch {
                let original = error
                do {
                    if ownsTemporary { try IO.unlinkIfPresent(temporary) }
                    if ownsDestination { try IO.unlinkIfPresent(destination) }
                    try IO.syncDirectory(batchDirectory)
                } catch { throw IO.failure() }
                throw original
            }
        }
    }
    public func read(_ reference: SessionPayloadReference) async throws -> Data {
        try await performThrowing {
            try self.requireOpen()
            guard self.references[reference.id] == reference,
                  !self.invalidated[reference.sessionID, default: []].contains(reference.retentionGroup) else {
                throw MiraError(.notFound, "The session payload is unavailable.")
            }
            return try self.payloadBytes(reference)
        }
    }

    public func saveActiveDraft(_ draft: SessionActiveDraft) async throws {
        try await performThrowing {
            try self.requireOpen()
            guard self.fencedBatch == nil else { throw MiraError(.busy, "An uncertain session batch requires reconciliation.") }
            try draft.validate()
            guard let committed = self.references[draft.request.id], committed == draft.request,
                  draft.request.kind == .request,
                  !self.invalidated[draft.request.sessionID, default: []].contains(draft.request.retentionGroup) else {
                throw MiraError(.unauthorized, "The active draft request is not a live committed request.")
            }
            if let existing = try self.activeDrafts.load(sessionID: draft.request.sessionID) {
                if existing == draft {
                    try self.activeDrafts.synchronize(sessionID: draft.request.sessionID)
                    return
                }
                guard existing.attemptID != draft.attemptID || draft.revision > existing.revision else {
                    throw MiraError(.conflict, "The active draft revision is stale or belongs to an older owner.")
                }
            }
            try self.activeDrafts.save(draft)
        }
    }

    public func activeDraft(sessionID: ConversationID) async throws -> SessionActiveDraft? {
        try await performThrowing {
            try self.requireOpen()
            guard let draft = try self.activeDrafts.load(sessionID: sessionID) else { return nil }
            guard draft.request.sessionID == sessionID,
                  self.references[draft.request.id] == draft.request,
                  !self.invalidated[sessionID, default: []].contains(draft.request.retentionGroup) else {
                try self.activeDrafts.remove(sessionID: sessionID)
                return nil
            }
            return draft
        }
    }

    public func removeActiveDraft(sessionID: ConversationID, attemptID: UUID) async throws {
        try await performThrowing {
            try self.requireOpen()
            guard self.fencedBatch == nil else { throw MiraError(.busy, "An uncertain session batch requires reconciliation.") }
            try self.activeDrafts.remove(sessionID: sessionID, attemptID: attemptID)
        }
    }
    public func purge(sessionID: ConversationID, retentionGroups: Set<UUID>) async throws {
        try await performThrowing {
            try self.requireOpen()
            guard self.fencedBatch == nil else { throw MiraError(.busy, "An uncertain session batch requires reconciliation.") }
            guard self.erased[sessionID, default: []].isSuperset(of: retentionGroups) else {
                throw MiraError(.unauthorized, "The retention groups have not been invalidated.")
            }
            try self.purgeInline(sessionID: sessionID, retentionGroups: retentionGroups)
            for reference in self.references.values where reference.sessionID == sessionID && retentionGroups.contains(reference.retentionGroup) && reference.storage == .external {
                try self.deletePayload(reference)
            }
            if let draft = try self.activeDrafts.load(sessionID: sessionID), retentionGroups.contains(draft.request.retentionGroup) {
                try self.activeDrafts.remove(sessionID: sessionID)
            }
        }
    }

    public func verifyPurged(sessionID: ConversationID, retentionGroups: Set<UUID>) async throws {
        try await performThrowing {
            try self.requireOpen()
            guard self.fencedBatch == nil,
                  self.erased[sessionID, default: []].isSuperset(of: retentionGroups) else { throw IO.failure() }
            for reference in self.references.values where reference.sessionID == sessionID && retentionGroups.contains(reference.retentionGroup) {
                if reference.storage == .inline {
                    guard let location = self.byID[reference.batchID],
                          try self.readPhysical(location).payloads[reference.id.uuidString] == nil else { throw IO.failure() }
                    continue
                }
                let url = self.payloadURL(reference)
                try self.checkPayloadAncestors(url)
                var info = stat()
                guard lstat(url.path, &info) == -1, errno == ENOENT else { throw IO.failure() }
            }
            if let draft = try self.activeDrafts.load(sessionID: sessionID), retentionGroups.contains(draft.request.retentionGroup) {
                throw IO.failure()
            }
        }
    }

    public func purgeUnpublished() async throws {
        try await performThrowing {
            try self.requireOpen()
            guard self.fencedBatch == nil else { throw IO.failure() }
            try self.removeInterruptedPurges()
            try self.sweepOrphans()
            try self.activeDrafts.removeAll()
            for address in try self.pendingPayloads.addresses() { try self.pendingPayloads.clear(address) }
            self.staged.removeAll(); self.stagedInline.removeAll()
        }
    }

    public func verifyNoUnpublished() async throws {
        try await performThrowing {
            try self.requireOpen()
            guard self.fencedBatch == nil, self.staged.isEmpty else { throw IO.failure() }
            let entries = try FileManager.default.contentsOfDirectory(at: self.sessionsURL, includingPropertiesForKeys: nil)
            guard !entries.contains(where: { $0.lastPathComponent.hasPrefix(".purge-") }) else { throw IO.failure() }
            try self.sweepOrphans(delete: false)
            guard try self.pendingPayloads.addresses().isEmpty else { throw IO.failure() }
            let activeDrafts = try FileManager.default.contentsOfDirectory(at: self.activeDraftsURL, includingPropertiesForKeys: nil)
            guard !activeDrafts.contains(where: { $0.pathExtension == "json" }) else { throw IO.failure() }
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
            let bytes = try SessionCodec.encode(batch)
            guard bytes.count <= SessionFormatLimits.maximumBatchBytes else {
                throw MiraError(.invalidInput, "The session batch exceeds its record limit.")
            }
            var inline: [String: String] = [:]
            for reference in batch.events.flatMap(\.fact.payloadReferences)
                where reference.batchID == batch.id && reference.storage == .inline {
                guard let text = stagedInline[reference.id] else { throw IO.failure() }
                inline[reference.id.uuidString] = text
            }
            let physical = FileSessionRecord(batch: batch, payloads: inline)
            try FileSessionArchive.validateInline(physical, erased: [])
            let line = try IO.encodeRecord(physical)
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
            ingest(batch, record: .init(batch: batch, offset: offset, line: line, previousDigest: indexes[batch.sessionID]?.records.last?.prefixDigest ?? FileSessionIndex.initialDigest))
            finishPayloadPublication(batch)
            saveIndexIfDue(batch.sessionID)
            return .committed(batch.cursor)
        } catch {
            if writeStarted { fencedBatch = batch; return .indeterminate(MiraError.safe(error)) }
            return .notCommitted(MiraError.safe(error))
        }
    }
    private func validateReferences(_ batch: SessionBatch) throws {
        var additions: [UUID: SessionPayloadReference] = [:]
        for reference in batch.events.flatMap(\.fact.payloadReferences) {
            guard !invalidated[batch.sessionID, default: []].contains(reference.retentionGroup) else { throw IO.failure() }
            if let previous = references[reference.id] ?? additions[reference.id] {
                guard previous == reference else { throw IO.failure() }
            } else {
                guard reference.batchID == batch.id, staged[reference.id] == reference else { throw IO.failure() }
                additions[reference.id] = reference
            }
            _ = try payloadBytes(reference)
        }
    }
    private func ingest(_ batch: SessionBatch, record: FileSessionIndex.Record) {
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
        index.records.append(record); indexes[batch.sessionID] = index
        index.sourceIdentity = try? IO.identity(journalURL(batch.sessionID))
        byID[batch.id] = Location(sessionID: batch.sessionID, record: record)
        dirtyIndexes.insert(batch.sessionID)
        for event in batch.events {
            for reference in event.fact.payloadReferences {
                if references[reference.id] == nil { index.references.append(reference) }
                references[reference.id] = reference; staged[reference.id] = nil; stagedInline[reference.id] = nil
            }
            if case .invalidated(let value) = event.fact {
                invalidated[batch.sessionID, default: []].formUnion(value.retentionGroups)
                index.invalidated.formUnion(value.retentionGroups)
                erased[batch.sessionID, default: []].formUnion(value.retentionGroups)
                index.erased.formUnion(value.retentionGroups)
            } else if case .retryCleared(let value) = event.fact {
                invalidated[batch.sessionID, default: []].formUnion(value.retentionGroups)
                index.invalidated.formUnion(value.retentionGroups)
            }
        }
    }
    private func load() throws {
        try removeInterruptedPurges()
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
                invalidated[sessionID] = index.invalidated; erased[sessionID] = index.erased
                metrics.indexedSessions += 1
                metrics.verifiedJournalBytes += index.byteCount
            } else {
                var presentInline: Set<UUID> = []
                try IO.scanRecords(url, sessionID: sessionID) { physical, offset, line in
                    let batch = physical.batch
                    presentInline.formUnion(physical.payloads.keys.compactMap(UUID.init(uuidString:)))
                    metrics.scannedBatches += 1
                    guard byID[batch.id] == nil else { throw IO.failure() }
                    var currentReferences: [UUID: SessionPayloadReference] = [:]
                    for reference in batch.events.flatMap(\.fact.payloadReferences) {
                        if let previous = references[reference.id] ?? currentReferences[reference.id] {
                            guard previous == reference else { throw IO.failure() }
                        } else if reference.batchID != batch.id { throw IO.failure() }
                        currentReferences[reference.id] = reference
                    }
                    ingest(batch, record: .init(batch: batch, offset: offset, line: line, previousDigest: indexes[batch.sessionID]?.records.last?.prefixDigest ?? FileSessionIndex.initialDigest))
                }
                for reference in indexes[sessionID]?.references ?? [] where reference.storage == .inline {
                    guard presentInline.contains(reference.id) || erased[sessionID, default: []].contains(reference.retentionGroup) else { throw IO.failure() }
                }
            }
            try IO.syncFile(url)
            indexes[sessionID]?.sourceIdentity = try IO.identity(url)
        }
        try IO.syncDirectory(sessionsURL)
        for (sessionID, groups) in erased where !groups.isEmpty {
            try purgeInline(sessionID: sessionID, retentionGroups: groups)
        }
        for reference in references.values where reference.storage == .external {
            if erased[reference.sessionID, default: []].contains(reference.retentionGroup) {
                // Durable invalidations are the restartable deletion work list.
                try deletePayload(reference)
            }
        }
        if try pendingPayloads.isInitialized() {
            for address in try pendingPayloads.addresses() {
                let retained = Set((indexes[address.sessionID]?.references ?? []).lazy
                    .filter { $0.batchID == address.batchID && $0.storage == .external }.map(\.id))
                try cleanPendingPayloads(address, retaining: retained)
                metrics.recoveredPayloadBatches += 1
            }
        } else {
            // Missing recovery metadata never means that no unpublished files exist.
            // Reconstruct it from the verified journal inventory and actual managed directories.
            try sweepOrphans()
            try pendingPayloads.initialize()
        }
        saveDirtyIndexes()
    }

    private func finishPayloadPublication(_ batch: SessionBatch) {
        let address = FileSessionPendingPayloads.Address(sessionID: batch.sessionID, batchID: batch.id)
        let inlineIDs = staged.values.filter { $0.sessionID == batch.sessionID && $0.batchID == batch.id && $0.storage == .inline }.map(\.id)
        for id in inlineIDs { stagedInline[id] = nil; staged[id] = nil }
        guard pendingPayloads.contains(address) else { return }
        let retained = Set(batch.events.flatMap(\.fact.payloadReferences)
            .filter { $0.batchID == batch.id && $0.storage == .external }.map(\.id))
        do { try cleanPendingPayloads(address, retaining: retained) }
        catch {
            // The batch is already durable. Keep its mark so recovery can finish orphan cleanup.
        }
    }

    private func cleanPendingPayloads(_ address: FileSessionPendingPayloads.Address, retaining ids: Set<UUID>) throws {
        try IO.checkDirectory(root); try IO.checkDirectory(payloadsURL)
        let session = payloadsURL.appendingPathComponent(address.sessionID.rawValue.uuidString)
        let directory = session.appendingPathComponent(address.batchID.uuidString)
        try IO.checkDirectory(session, allowMissing: true)
        try IO.checkDirectory(directory, allowMissing: true)
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            let retained = Set(ids.map { $0.uuidString + ".bin" })
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard file.lastPathComponent.hasPrefix(".stage-") || file.pathExtension == "bin" else { throw IO.failure() }
                if !retained.contains(file.lastPathComponent) { try IO.unlinkIfPresent(file) }
            }
            // Always retry the directory barrier, even when a previous attempt already removed the files.
            try IO.syncDirectory(directory)
        } else {
            guard errno == ENOENT, ids.isEmpty else { throw IO.failure() }
        }
        try pendingPayloads.clear(address)
        staged = staged.filter { $0.value.sessionID != address.sessionID || $0.value.batchID != address.batchID }
    }
    private func read(_ location: Location) throws -> SessionBatch {
        try IO.checkDirectory(root); try IO.checkDirectory(sessionsURL)
        let physical = try readPhysical(location)
        metrics.pageDecodedBatches += 1
        return physical.batch
    }
    private func readPhysical(_ location: Location) throws -> FileSessionRecord {
        try IO.checkDirectory(root); try IO.checkDirectory(sessionsURL)
        return try IO.readRecord(journalURL(location.sessionID), sessionID: location.sessionID, record: location.record)
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
        for reference in batch.events.flatMap(\.fact.payloadReferences) where reference.storage == .external {
            try IO.syncFile(payloadURL(reference))
            let directory = payloadURL(reference).deletingLastPathComponent()
            try syncDirectory(directory); try syncDirectory(directory.deletingLastPathComponent())
        }
        try syncDirectory(payloadsURL)
        try fault(.beforeJournalSync); try IO.syncFile(journalURL(batch.sessionID)); try fault(.afterJournalSync)
        try syncDirectory(sessionsURL)
    }
    private func sweepOrphans(delete: Bool = true) throws {
        // Compare managed relative identities; Foundation may spell the same OS parent as /var or /private/var.
        let retained = Set(references.values.filter { $0.storage == .external }.map {
            "\($0.sessionID.rawValue.uuidString)/\($0.batchID.uuidString)/\($0.id.uuidString).bin"
        })
        for session in try FileManager.default.contentsOfDirectory(at: payloadsURL, includingPropertiesForKeys: nil) {
            try IO.checkDirectory(session)
            guard UUID(uuidString: session.lastPathComponent) != nil else { throw IO.failure() }
            for batch in try FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil) {
                try IO.checkDirectory(batch)
                metrics.sweptPayloadBatches += 1
                guard UUID(uuidString: batch.lastPathComponent) != nil else { throw IO.failure() }
                for file in try FileManager.default.contentsOfDirectory(at: batch, includingPropertiesForKeys: nil) {
                    guard file.lastPathComponent.hasPrefix(".stage-") || file.pathExtension == "bin" else { throw IO.failure() }
                    let identity = "\(session.lastPathComponent)/\(batch.lastPathComponent)/\(file.lastPathComponent)"
                    if !retained.contains(identity) {
                        guard delete else { throw IO.failure() }
                        try IO.unlinkIfPresent(file)
                    }
                }
                if delete { try IO.syncDirectory(batch) }
            }
        }
    }
    private func payloadBytes(_ reference: SessionPayloadReference) throws -> Data {
        try reference.validate()
        if reference.storage == .inline {
            let text: String
            if let pending = stagedInline[reference.id], staged[reference.id] == reference { text = pending }
            else {
                guard let location = byID[reference.batchID], location.sessionID == reference.sessionID,
                      let retained = try readPhysical(location).payloads[reference.id.uuidString] else { throw IO.failure() }
                text = retained
            }
            let bytes = Data(text.utf8)
            guard bytes.count == reference.byteCount, IO.digest(bytes) == reference.digest else { throw IO.failure() }
            return bytes
        }
        let url = payloadURL(reference)
        try checkPayloadAncestors(url)
        let bytes = try IO.readBounded(url, expectedCount: reference.byteCount)
        guard IO.digest(bytes) == reference.digest else { throw IO.failure() }
        return bytes
    }

    /// Normal writes only append. Explicit privacy erasure replaces the physical
    /// journal while retaining every event identity and its logical sequence.
    private func purgeInline(sessionID: ConversationID, retentionGroups: Set<UUID>) throws {
        guard let index = indexes[sessionID],
              index.references.contains(where: { $0.storage == .inline && retentionGroups.contains($0.retentionGroup) }) else { return }
        try validateCheckpointSource(index)
        try removeInterruptedPurges()
        let destination = journalURL(sessionID)
        let temporary = sessionsURL.appendingPathComponent(".purge-\(UUID().uuidString)")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw IO.failure() }
        var descriptorOpen = true
        var published = false
        defer {
            if descriptorOpen { Darwin.close(fd) }
            if !published { try? IO.unlinkIfPresent(temporary) }
        }
        let replacement = FileSessionIndex(sessionID: sessionID)
        replacement.references = index.references
        replacement.invalidated = index.invalidated
        replacement.erased = index.erased
        var changed = false
        try fault(.beforeInlinePurgeWrite)
        for record in index.records {
            var physical = try readPhysical(Location(sessionID: sessionID, record: record))
            for reference in physical.batch.events.flatMap(\.fact.payloadReferences)
                where reference.batchID == physical.batch.id && reference.storage == .inline
                    && retentionGroups.contains(reference.retentionGroup) {
                if physical.payloads.removeValue(forKey: reference.id.uuidString) != nil { changed = true }
            }
            // All previously authorized erasures must remain physically absent.
            // Other invalidations may still be waiting for their own purge call.
            let line = try IO.encodeRecord(physical)
            let location = FileSessionIndex.Record(batch: physical.batch, offset: replacement.byteCount,
                line: line, previousDigest: replacement.records.last?.prefixDigest ?? FileSessionIndex.initialDigest)
            try IO.write(line + Data([10]), fd: fd)
            replacement.records.append(location)
        }
        try fault(.afterInlinePurgeWrite)
        try IO.sync(fd)
        Darwin.close(fd); descriptorOpen = false
        try validateCheckpointSource(index)
        if changed {
            try fault(.beforeInlinePurgePublication)
            guard Darwin.rename(temporary.path, destination.path) == 0 else { throw IO.failure() }
            published = true
            // Install the new offsets before any fallible publication barrier.
            // A retry can synchronize the already-replaced journal safely.
            indexes[sessionID] = replacement
            for record in replacement.records { byID[record.id] = Location(sessionID: sessionID, record: record) }
            dirtyIndexes.insert(sessionID)
            replacement.sourceIdentity = try IO.identity(destination)
            try fault(.afterInlinePurgePublication)
        } else {
            try IO.unlinkIfPresent(temporary)
        }
        try syncDirectory(sessionsURL)
    }

    private func removeInterruptedPurges() throws {
        try IO.checkDirectory(sessionsURL)
        for url in try FileManager.default.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix(".purge-") {
            let suffix = String(url.lastPathComponent.dropFirst(".purge-".count))
            guard let id = UUID(uuidString: suffix), id.uuidString == suffix else { throw IO.failure() }
            try IO.unlinkIfPresent(url)
        }
        try IO.syncDirectory(sessionsURL)
    }

    private func deletePayload(_ reference: SessionPayloadReference) throws {
        let url = payloadURL(reference)
        try checkPayloadAncestors(url)
        try fault(.beforePayloadDelete)
        try IO.unlinkIfPresent(url)
        try fault(.afterPayloadDelete)
        // A prior attempt may have unlinked the file but failed before directory fsync.
        // Absence alone is not a completed deletion durability barrier.
        try syncDirectory(url.deletingLastPathComponent())
    }
    private func checkPayloadAncestors(_ url: URL, allowMissing: Bool = false) throws {
        try IO.checkDirectory(root); try IO.checkDirectory(payloadsURL)
        try IO.checkDirectory(url.deletingLastPathComponent().deletingLastPathComponent(), allowMissing: allowMissing)
        try IO.checkDirectory(url.deletingLastPathComponent(), allowMissing: allowMissing)
    }
    private func syncDirectory(_ url: URL) throws {
        try fault(.beforeDirectorySync); try IO.syncDirectory(url); try fault(.afterDirectorySync)
    }
    private func journalURL(_ id: ConversationID) -> URL { sessionsURL.appendingPathComponent(id.rawValue.uuidString + ".jsonl") }
    private func payloadURL(_ reference: SessionPayloadReference) -> URL {
        payloadsURL.appendingPathComponent(reference.sessionID.rawValue.uuidString)
            .appendingPathComponent(reference.batchID.uuidString).appendingPathComponent(reference.id.uuidString + ".bin")
    }
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
    var recoveredPayloadBatches = 0
    var sweptPayloadBatches = 0
    var verifiedJournalBytes: Int64 = 0
}
