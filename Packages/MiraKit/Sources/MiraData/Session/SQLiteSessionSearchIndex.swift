import Darwin
import Foundation
import GRDB
import MiraCore
import SQLite3

/// A bounded, disposable full-text cache. The journal remains the authority for all facts.
public final class SQLiteSessionSearchIndex: SessionSearchIndex, @unchecked Sendable {
    private let path: String
    private let io = DispatchQueue(label: "mira.session-search-index", qos: .utility)
    private var database: DatabaseQueue?
    private let substringIndexEnabled: Bool
    private let maximumCandidates: Int
    private let maximumDuration: Duration
    private var detectedCapabilities: SessionSearchCapabilities
    private var closed = false
    private var identity: UUID

    public convenience init(path: String) throws {
        try self.init(path: path, substringIndexEnabled: true)
    }

    /// Internal bounds allow deterministic fallback/deadline tests without changing public limits.
    init(
        path: String, substringIndexEnabled: Bool, maximumCandidates: Int = 20_000,
        maximumDuration: Duration = .milliseconds(200)
    ) throws {
        guard path.hasPrefix("/"), (1...20_000).contains(maximumCandidates),
            maximumDuration >= .zero, maximumDuration <= .milliseconds(200)
        else { throw Self.invalidData }
        self.path = path
        self.substringIndexEnabled = substringIndexEnabled
        self.maximumCandidates = maximumCandidates
        self.maximumDuration = maximumDuration
        do {
            let opened = try Self.open(path: path)
            database = opened.database
            identity = opened.identity
            detectedCapabilities = opened.capabilities
        } catch { throw Self.safe(error) }
    }

    public func head(sessionID: ConversationID) async throws -> SessionJournalHead? {
        try await read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT head_sequence, head_batch_id FROM search_sessions WHERE session_id = ?",
                    arguments: [Self.id(sessionID)])
            else { return nil }
            guard let batch: String = row["head_batch_id"], let uuid = UUID(uuidString: batch) else {
                throw Self.invalidData
            }
            return SessionJournalHead(
                cursor: .init(sessionID: sessionID, sequence: row["head_sequence"]), batchID: uuid)
        }
    }

    public func apply(_ update: SessionSearchUpdate) async throws {
        try update.batch.validate()
        let encoded = try SessionCodec.encode(update.batch)
        guard encoded.count <= SessionFormatLimits.maximumBatchBytes else { throw Self.invalidData }
        let documents = try Self.validateDocuments(update)
        // Text digests were validated against source references. Hash only bounded metadata;
        // encoding the complete update would allocate a second escaped copy of every body.
        let digest = FileSessionIO.digest(
            try SessionCodec.encode(
                [FileSessionIO.digest(encoded)] + documents.keys.map(\.uuidString).sorted()))
        try await write { db in
            let sid = Self.id(update.batch.sessionID)
            if let old = try Row.fetchOne(
                db, sql: "SELECT digest FROM search_batches WHERE session_id = ? AND batch_id = ?",
                arguments: [sid, update.batch.id.uuidString])
            {
                guard old["digest"] as String == digest else {
                    throw MiraError(.conflict, "The search batch identity conflicts.")
                }
                return
            }
            let current =
                try Int64.fetchOne(
                    db, sql: "SELECT head_sequence FROM search_sessions WHERE session_id = ?", arguments: [sid]) ?? 0
            guard update.batch.expectedSequence == current else {
                throw MiraError(.conflict, "The search batch sequence is stale.")
            }
            if current == 0 { guard case .opened = update.batch.events.first?.fact else { throw Self.invalidData } }
            try db.execute(
                sql: "INSERT INTO search_batches(session_id,batch_id,sequence,digest) VALUES (?,?,?,?)",
                arguments: [sid, update.batch.id.uuidString, update.batch.cursor.sequence, digest])
            for event in update.batch.events {
                try Self.reduce(event, sessionID: update.batch.sessionID, documents: documents, in: db)
            }
            try db.execute(
                sql: "UPDATE search_sessions SET head_sequence = ?, head_batch_id = ? WHERE session_id = ?",
                arguments: [update.batch.cursor.sequence, update.batch.id.uuidString, sid])
            try Self.requireChangedRow(db)
        }
    }

    public func search(_ selection: SessionSearchSelection, after: SessionSearchCursor?, limit: Int) async throws
        -> SessionSearchIndexPage
    {
        try selection.validate()
        guard (1...128).contains(limit) else { throw MiraError(.invalidInput, "The search page size is invalid.") }
        let normalizedQuery = SessionSearchText.normalize(selection.text)
        let digest = Self.queryDigest(selection, normalized: normalizedQuery)
        if let after, after.beforeRowID <= 0 || after.queryDigest != digest {
            throw MiraError(.invalidInput, "The search cursor is stale.")
        }
        let token = CancellationBox()
        return try await withTaskCancellationHandler(
            operation: {
                try await read { db in
                    try token.check()
                    let deadline = SearchDeadline(token: token, duration: self.maximumDuration)
                    let pointer = Unmanaged.passUnretained(deadline).toOpaque()
                    sqlite3_progress_handler(
                        db.sqliteConnection, 1_000,
                        { context in
                            guard let context else { return 0 }
                            return Unmanaged<SearchDeadline>.fromOpaque(context).takeUnretainedValue().expired ? 1 : 0
                        }, pointer)
                    defer { sqlite3_progress_handler(db.sqliteConnection, 0, nil, nil) }
                    if let after, after.indexID != self.identity {
                        throw MiraError(.invalidInput, "The search cursor is stale.")
                    }
                    let terms = SessionSearchText.terms(selection.text)
                    let useFTS = terms.allSatisfy { $0.unicodeScalars.count >= 3 }
                    let caps = self.detectedCapabilities
                    let indexed = useFTS && caps.substringIndex && self.substringIndexEnabled
                    var args: StatementArguments = []
                    var sql =
                        "SELECT d.* FROM search_documents d JOIN search_sessions s ON s.session_id = d.session_id WHERE 1=1"
                    Self.scope(selection.scope, sql: &sql, args: &args)
                    if !selection.includeArchived { sql += " AND s.archived = 0" }
                    if let since = selection.since {
                        sql += " AND d.occurred_at >= ?"
                        args += [since.timeIntervalSinceReferenceDate]
                    }
                    if let until = selection.until {
                        sql += " AND d.occurred_at < ?"
                        args += [until.timeIntervalSinceReferenceDate]
                    }
                    if let after {
                        sql += " AND d.rowid < ?"
                        args += [after.beforeRowID]
                    }
                    if indexed {
                        let expression = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                            .joined(separator: " AND ")
                        var sources: [String] = []
                        if caps.wordIndex {
                            sources.append("d.rowid IN (SELECT rowid FROM search_word WHERE search_word MATCH ?)")
                            args += [expression]
                        }
                        if caps.substringIndex {
                            sources.append("d.rowid IN (SELECT rowid FROM search_trigram WHERE search_trigram MATCH ?)")
                            args += [expression]
                        }
                        sql += " AND (" + sources.joined(separator: " OR ") + ")"
                    }
                    sql += " ORDER BY d.rowid DESC LIMIT ?"
                    args += [self.maximumCandidates + 1]
                    var matches: [SessionSearchLocation] = []
                    var scanned = 0
                    var truncated = false
                    var lastRow: Int64?
                    do {
                        let cursor = try Row.fetchCursor(db, sql: sql, arguments: args)
                        while let row = try cursor.next() {
                            if deadline.expired || scanned >= self.maximumCandidates {
                                truncated = true
                                break
                            }
                            scanned += 1
                            lastRow = row["rowid"]
                            let normalized: String = row["normalized_text"]
                            guard terms.allSatisfy({ normalized.contains($0) }) else { continue }
                            matches.append(try Self.location(row))
                            if matches.count == limit { break }
                        }
                    } catch let error as DatabaseError where error.resultCode == .SQLITE_INTERRUPT {
                        if !deadline.expired { throw error }
                        truncated = true
                    }
                    try token.check()
                    if deadline.expired { truncated = true }
                    // A deadline/candidate cap can stop before filling the requested page;
                    // preserve the scan position so callers can explicitly continue.
                    let next = lastRow.flatMap { rowID in
                        (matches.count == limit || truncated)
                            ? SessionSearchCursor(indexID: self.identity, beforeRowID: rowID, queryDigest: digest) : nil
                    }
                    return SessionSearchIndexPage(
                        matches: matches, nextCursor: next, isTruncated: truncated, scannedCandidates: scanned,
                        capabilities: caps)
                }
            }, onCancel: { token.cancel() })
    }

    public func clear() async throws {
        try await perform {
            guard !self.closed else { throw Self.invalidData }
            if let database = self.database {
                try database.close()
                self.database = nil
            }
            // Keep the adapter fenced after any failure. Retrying clear repeats every
            // unlink and durability barrier, even when an earlier unlink already succeeded.
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try FileSessionIO.unlinkIfPresent(URL(fileURLWithPath: self.path + suffix))
            }
            try FileSessionIO.syncDirectory(URL(fileURLWithPath: self.path).deletingLastPathComponent())
            let opened = try Self.open(path: self.path)
            self.database = opened.database
            self.identity = opened.identity
            self.detectedCapabilities = opened.capabilities
        }
    }

    public func verifyEmpty() async throws {
        try await read { db in
            for table in ["search_documents", "search_batches", "search_sessions"] {
                guard try Int.fetchOne(db, sql: "SELECT 1 FROM \(table) LIMIT 1") == nil else { throw Self.invalidData }
            }
            // External-content FTS COUNT reads the content table, so also inspect its
            // vocabulary to detect residual postings after a malformed cache clear.
            for name in ["search_word", "search_trigram"] where try db.tableExists(name) {
                guard try Int.fetchOne(db, sql: "SELECT 1 FROM \(name)_terms LIMIT 1") == nil else {
                    throw Self.invalidData
                }
            }
        }
    }

    public func close() async throws {
        try await perform {
            guard !self.closed else { return }
            try self.database?.close()
            self.database = nil
            self.closed = true
        }
    }

    private func read<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await perform { try self.requireDatabase().read(body) }
    }
    private func write<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await perform { try self.requireDatabase().write(body) }
    }
    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            io.async {
                do { continuation.resume(returning: try body()) } catch {
                    continuation.resume(throwing: error is CancellationError ? error : Self.safe(error))
                }
            }
        }
    }
    private func requireDatabase() throws -> DatabaseQueue {
        guard !closed, let database else { throw MiraError(.cancelled, "The session search index is closed.") }
        return database
    }

    private static func open(path: String) throws -> (
        database: DatabaseQueue, identity: UUID, capabilities: SessionSearchCapabilities
    ) {
        let url = URL(fileURLWithPath: path)
        try FileSessionIO.checkDirectory(url.deletingLastPathComponent())
        for suffix in ["", "-wal", "-shm", "-journal"] {
            var info = stat()
            let candidate = path + suffix
            if lstat(candidate, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw invalidData }
            } else if errno != ENOENT {
                throw invalidData
            }
        }
        // Precreate at owner-only permissions before SQLite can write text or journal pages.
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw invalidData }
        do {
            try FileSessionIO.requireRegular(fd)
            guard fchmod(fd, 0o600) == 0 else { throw invalidData }
            Darwin.close(fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
        let database = try DatabaseQueue(path: path)
        do {
            let result = try database.write { db in
                let capabilities = try probe(db)
                let identity = try initialize(db, capabilities: capabilities)
                return (identity, capabilities)
            }
            try FileSessionIO.syncFile(url)
            try FileSessionIO.syncDirectory(url.deletingLastPathComponent())
            return (database, result.0, result.1)
        } catch {
            try? database.close()
            throw error
        }
    }

    private static func probe(_ db: Database) throws -> SessionSearchCapabilities {
        func supports(_ tokenizer: String) throws -> Bool {
            let name = "session_probe_" + tokenizer
            do {
                try db.execute(sql: "CREATE VIRTUAL TABLE temp.\(name) USING fts5(text,tokenize='\(tokenizer)')")
            } catch let error as DatabaseError {
                // Only absence of the module/tokenizer means unavailable. Corruption,
                // locking, disk and allocation failures must not masquerade as fallback.
                let message = error.message ?? ""
                if message.contains("no such module: fts5") || message.contains("no such tokenizer:") { return false }
                throw error
            }
            do {
                try db.execute(sql: "INSERT INTO temp.\(name)(text) VALUES ('synthetic')")
                let term = tokenizer == "trigram" ? "nth" : "synthetic"
                let count = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM temp.\(name) WHERE \(name) MATCH ?", arguments: [term])
                try db.execute(sql: "DROP TABLE temp.\(name)")
                guard count == 1 else { throw invalidData }
                return true
            } catch {
                try? db.execute(sql: "DROP TABLE temp.\(name)")
                throw error
            }
        }
        return try .init(wordIndex: supports("unicode61"), substringIndex: supports("trigram"))
    }

    private static func initialize(_ db: Database, capabilities: SessionSearchCapabilities) throws -> UUID {
        let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        if version == 1 {
            guard let value = try String.fetchOne(db, sql: "SELECT value FROM search_meta WHERE key='identity'"),
                let uuid = UUID(uuidString: value)
            else { throw invalidData }
            return uuid
        }
        guard version == 0 else { throw MiraError(.unsupported, "The session search index schema is unsupported.") }
        let uuid = UUID()
        try db.execute(
            sql:
                "CREATE TABLE search_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL); CREATE TABLE search_sessions(session_id TEXT PRIMARY KEY,workspace_id TEXT,archived INTEGER NOT NULL DEFAULT 0,head_sequence INTEGER NOT NULL,head_batch_id TEXT NOT NULL); CREATE TABLE search_batches(session_id TEXT NOT NULL,batch_id TEXT NOT NULL,sequence INTEGER NOT NULL,digest TEXT NOT NULL,PRIMARY KEY(session_id,batch_id),UNIQUE(session_id,sequence)); CREATE TABLE search_documents(rowid INTEGER PRIMARY KEY AUTOINCREMENT,session_id TEXT NOT NULL,message_id TEXT,execution_id TEXT,part TEXT NOT NULL,sequence INTEGER NOT NULL,occurred_at REAL NOT NULL,location_json BLOB NOT NULL,normalized_text TEXT NOT NULL,byte_count INTEGER NOT NULL);",
            arguments: [])
        try db.execute(
            sql:
                "CREATE INDEX search_session_scope ON search_sessions(workspace_id,archived); CREATE INDEX search_document_session ON search_documents(session_id,rowid); CREATE INDEX search_document_time ON search_documents(occurred_at)"
        )
        for (name, tokenizer, available) in [
            ("search_word", "unicode61", capabilities.wordIndex),
            ("search_trigram", "trigram", capabilities.substringIndex),
        ] where available {
            try db.execute(
                sql:
                    "CREATE VIRTUAL TABLE \(name) USING fts5(normalized_text,content='search_documents',content_rowid='rowid',tokenize='\(tokenizer)')"
            )
            try db.execute(sql: "CREATE VIRTUAL TABLE \(name)_terms USING fts5vocab(\(name),'row')")
        }
        try db.execute(
            sql: "INSERT INTO search_meta(key,value) VALUES ('identity',?); PRAGMA user_version = 1",
            arguments: [uuid.uuidString])
        return uuid
    }

    private static func reduce(
        _ event: SessionEvent, sessionID: ConversationID, documents: [UUID: SessionSearchDocument], in db: Database
    ) throws {
        let sid = id(sessionID)
        switch event.fact {
        case .opened(let value):
            try db.execute(
                sql:
                    "INSERT INTO search_sessions(session_id,workspace_id,head_sequence,head_batch_id) VALUES (?,?,0,?)",
                arguments: [sid, value.workspaceID.map(id), ""])
            try replaceTitle(value.title, event: event, sessionID: sessionID, documents: documents, db: db)
        case .renamed(let title, _):
            try deleteRows("session_id=? AND part='title'", arguments: [sid], db: db)
            try replaceTitle(title, event: event, sessionID: sessionID, documents: documents, db: db)
        case .archived:
            try db.execute(sql: "UPDATE search_sessions SET archived=1 WHERE session_id=?", arguments: [sid])
        case .admitted(let value):
            if let reference = value.userBody {
                try insert(
                    reference, part: .user, messageID: value.userMessageID, executionID: value.executionID,
                    event: event, sessionID: sessionID, documents: documents, db: db)
            }
        case .finished(let value):
            if let reference = value.answer {
                try insert(
                    reference, part: .assistant, messageID: value.assistantMessageID, executionID: value.executionID,
                    event: event, sessionID: sessionID, documents: documents, db: db)
            }
            if let reference = value.visibleThinking {
                try insert(
                    reference, part: .thinking, messageID: value.assistantMessageID, executionID: value.executionID,
                    event: event, sessionID: sessionID, documents: documents, db: db)
            }
        default: break
        }
    }

    private static func replaceTitle(
        _ ref: SessionContent, event: SessionEvent, sessionID: ConversationID,
        documents: [UUID: SessionSearchDocument], db: Database
    ) throws {
        try insert(
            ref, part: .title, messageID: nil, executionID: nil, event: event, sessionID: sessionID,
            documents: documents, db: db)
    }
    private static func insert(
        _ ref: SessionContent, part: SessionSearchPart, messageID: MessageID?, executionID: ExecutionID?,
        event: SessionEvent, sessionID: ConversationID, documents: [UUID: SessionSearchDocument], db: Database
    ) throws {
        guard let document = documents[ref.id] else { return }
        try db.execute(
            sql:
                "INSERT INTO search_documents(session_id,message_id,execution_id,part,sequence,occurred_at,location_json,normalized_text,byte_count) VALUES (?,?,?,?,?,?,?,?,?)",
            arguments: [
                id(sessionID), messageID.map(id), executionID.map(id), part.rawValue, event.sequence,
                event.occurredAt.timeIntervalSinceReferenceDate, try SessionCodec.encode(document.location),
                SessionSearchText.normalize(document.text), ref.byteCount,
            ])
        let rowid = db.lastInsertedRowID
        if try db.tableExists("search_word") {
            try db.execute(
                sql: "INSERT INTO search_word(rowid,normalized_text) VALUES (?,?)",
                arguments: [rowid, SessionSearchText.normalize(document.text)])
        }
        if try db.tableExists("search_trigram") {
            try db.execute(
                sql: "INSERT INTO search_trigram(rowid,normalized_text) VALUES (?,?)",
                arguments: [rowid, SessionSearchText.normalize(document.text)])
        }
    }

    private static func deleteRows(_ predicate: String, arguments: StatementArguments, db: Database) throws {
        let rows = try Row.fetchAll(
            db, sql: "SELECT rowid,normalized_text FROM search_documents WHERE \(predicate)", arguments: arguments)
        for row in rows {
            let rowid: Int64 = row["rowid"]
            let normalized: String = row["normalized_text"]
            if try db.tableExists("search_word") {
                try db.execute(
                    sql: "INSERT INTO search_word(search_word,rowid,normalized_text) VALUES ('delete',?,?)",
                    arguments: [rowid, normalized])
            }
            if try db.tableExists("search_trigram") {
                try db.execute(
                    sql: "INSERT INTO search_trigram(search_trigram,rowid,normalized_text) VALUES ('delete',?,?)",
                    arguments: [rowid, normalized])
            }
            try db.execute(sql: "DELETE FROM search_documents WHERE rowid=?", arguments: [rowid])
        }
    }
    private static func validateDocuments(_ update: SessionSearchUpdate) throws -> [UUID: SessionSearchDocument] {
        var allowed: [UUID: (SessionContent, SessionSearchPart, SessionEvent, UUID?, UUID?)] = [:]
        for event in update.batch.events {
            switch event.fact {
            case .opened(let h): allowed[h.title.id] = (h.title, .title, event, nil, nil)
            case .renamed(let r, _): allowed[r.id] = (r, .title, event, nil, nil)
            case .admitted(let a):
                if let r = a.userBody {
                    allowed[r.id] = (r, .user, event, a.userMessageID.rawValue, a.executionID.rawValue)
                }
            case .finished(let c):
                if let r = c.answer {
                    allowed[r.id] = (r, .assistant, event, c.assistantMessageID?.rawValue, c.executionID.rawValue)
                }
                if let r = c.visibleThinking {
                    allowed[r.id] = (r, .thinking, event, c.assistantMessageID?.rawValue, c.executionID.rawValue)
                }
            default: break
            }
        }
        var total = 0
        var seen = Set<UUID>()
        for document in update.documents {
            try document.location.validate()
            guard let expected = allowed[document.location.reference.id], expected.0 == document.location.reference,
                expected.1 == document.location.part, expected.2.sequence == document.location.sequence,
                expected.2.occurredAt == document.location.occurredAt,
                document.location.sessionID == update.batch.sessionID,
                expected.3 == document.location.messageID?.rawValue,
                expected.4 == document.location.executionID?.rawValue
            else { throw invalidData }
            guard seen.insert(document.location.reference.id).inserted,
                document.location.reference.byteCount == document.text.utf8.count,
                document.location.reference.digest == FileSessionIO.digest(Data(document.text.utf8))
            else { throw invalidData }
            total += document.text.utf8.count
            guard total <= 64 * 1024 * 1024 else {
                throw MiraError(.outputLimit, "The session search update exceeds its supported size.")
            }
        }
        return Dictionary(uniqueKeysWithValues: update.documents.map { ($0.location.reference.id, $0) })
    }

    private static func location(_ row: Row) throws -> SessionSearchLocation {
        let location = try SessionCodec.decode(SessionSearchLocation.self, from: row["location_json"])
        try location.validate()
        guard id(location.sessionID) == row["session_id"] as String,
            location.messageID.map(id) == row["message_id"] as String?,
            location.executionID.map(id) == row["execution_id"] as String?,
            location.part.rawValue == row["part"] as String,
            location.sequence == row["sequence"] as Int64,
            location.occurredAt.timeIntervalSinceReferenceDate == row["occurred_at"] as Double,
            location.reference.byteCount == row["byte_count"] as Int
        else { throw invalidData }
        return location
    }
    private static func scope(_ scope: SessionQueryScope, sql: inout String, args: inout StatementArguments) {
        switch scope {
        case .all: break
        case .inbox: sql += " AND s.workspace_id IS NULL"
        case .workspace(let id):
            sql += " AND s.workspace_id = ?"
            args += [self.id(id)]
        }
    }
    private static func queryDigest(_ selection: SessionSearchSelection, normalized: String) -> String {
        FileSessionIO.digest(
            Data(
                (normalized + "|" + String(describing: selection.scope) + "|" + String(selection.includeArchived) + "|"
                    + String(selection.since?.timeIntervalSinceReferenceDate ?? .nan) + "|"
                    + String(selection.until?.timeIntervalSinceReferenceDate ?? .nan)).utf8))
    }
    private static func requireChangedRow(_ db: Database) throws {
        guard db.changesCount > 0 else { throw invalidData }
    }
    private static func id<Tag>(_ value: EntityID<Tag>) -> String { value.rawValue.uuidString }
    private static func safe(_ error: any Error) -> MiraError { (error as? MiraError) ?? invalidData }
    private static var invalidData: MiraError {
        .init(.storage, "The session search index data is invalid or unavailable.")
    }
}

private final class CancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
    func check() throws { if cancelled { throw CancellationError() } }
}
private final class SearchDeadline: @unchecked Sendable {
    let box: CancellationBox
    let end: ContinuousClock.Instant
    init(token: CancellationBox, duration: Duration) {
        box = token
        end = .now.advanced(by: duration)
    }
    var expired: Bool { box.cancelled || ContinuousClock.now >= end }
}
