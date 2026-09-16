import Foundation
import GRDB
import MiraCore

public enum LibraryArchiveFaultStage: Sendable {
    case afterDatabaseSnapshot, afterCatalogChunk, beforePublication
}

/// The library coordinator quiesces producers before calling this adapter.
/// Lock order is session queue, shared database queue, then synchronous file I/O.
public final class SQLiteLibraryArchiveExporter: @unchecked Sendable {
    private let database: DatabaseQueue
    private let sessions: FileSessionLibrary
    private let libraryID: UUID
    private let attachmentDirectory: URL
    private let modules: [SQLiteArchiveModule]
    private let fault: @Sendable (LibraryArchiveFaultStage) throws -> Void
    private let lock = NSLock()
    private var accepting = true
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        database: DatabaseQueue, sessions: FileSessionLibrary, libraryID: UUID,
        attachmentDirectory: URL, modules: [SQLiteArchiveModule],
        faultInjector: (@Sendable (LibraryArchiveFaultStage) throws -> Void)? = nil
    ) throws {
        self.database = database
        self.sessions = sessions
        self.libraryID = libraryID
        self.attachmentDirectory = attachmentDirectory
        self.modules = try Self.catalog(modules)
        fault = faultInjector ?? { _ in }
        try database.read { try SQLiteLibraryAuthority.validateInitialized(in: $0, libraryID: libraryID) }
    }

    public func export(to destination: URL, authorization: AgentLibraryAuthorization) async throws
        -> LibraryArchiveManifest
    {
        try Task.checkCancellation()
        guard
            lock.withLock({
                if !accepting { return false }
                active += 1
                return true
            })
        else {
            throw MiraError(.storage, "The library archive exporter is closed.")
        }
        defer { finish() }
        do {
            return try await sessions.withSnapshot { snapshot in
                // DatabaseQueue.read owns a read transaction and excludes all other users
                // of this shared queue until copying, verification and publication finish.
                try self.database.read { db in
                    try SQLiteDomainDatabase.requireDurability(db)
                    guard authorization.libraryID == self.libraryID,
                        try SQLiteLibraryAuthority.availableAuthorization(in: db, libraryID: self.libraryID)
                            == authorization
                    else {
                        throw MiraError(.unauthorized, "Business authorization is stale.")
                    }
                    let attachments = try Self.inspectDatabase(db, snapshot: snapshot, modules: self.modules)
                    let fileCount =
                        1 + snapshot.sessions.count + snapshot.sessions.reduce(0, { $0 + $1.payloads.count })
                        + attachments.count
                    guard fileCount <= LibraryArchiveLimits.maximumFiles else { throw LibraryArchiveIO.invalid }
                    try Self.checkCaptureSize(
                        db, snapshot: snapshot, attachments: attachments, root: self.attachmentDirectory)
                    let stage = try LibraryArchiveIO.createStage(for: destination)
                    var published = false
                    defer { if !published { try? FileManager.default.removeItem(at: stage.stage) } }
                    let catalog = try LibraryArchiveFileCatalog.Writer(directory: stage.stage) {
                        try self.fault(.afterCatalogChunk)
                    }
                    var attachmentIndex = 0
                    func appendAttachment(_ attachment: LibraryArchiveAttachment) throws {
                        let source = try LibraryArchiveIO.file(attachment.path, under: self.attachmentDirectory)
                        let file = try Self.copy(source, path: attachment.path, to: stage.stage, limit: attachment.byteCount)
                        guard file.byteCount == attachment.byteCount, file.digest == attachment.digest else {
                            throw LibraryArchiveIO.invalid
                        }
                        try catalog.append(file)
                    }
                    func append(_ file: LibraryArchiveManifest.File) throws {
                        while attachmentIndex < attachments.count, attachments[attachmentIndex].path < file.path {
                            try appendAttachment(attachments[attachmentIndex]); attachmentIndex += 1
                        }
                        try catalog.append(file)
                    }
                    let sqlURL = stage.stage.appendingPathComponent("Business.sqlite")
                    try Self.snapshot(db, to: sqlURL)
                    // Strip rebuildable domain indexes from the isolated snapshot, never the live library.
                    let exportDatabase = try DatabaseQueue(path: sqlURL.path)
                    do {
                        try exportDatabase.write { exported in
                            for module in self.modules { try module.prepareExport(exported) }
                        }
                        try exportDatabase.writeWithoutTransaction { try $0.execute(sql: "VACUUM") }
                        try exportDatabase.close()
                    } catch {
                        try? exportDatabase.close()
                        throw error
                    }
                    try self.fault(.afterDatabaseSnapshot)
                    try append(Self.inspectFile(sqlURL, path: "Business.sqlite"))
                    try FileSessionIO.ensureDirectory(stage.stage.appendingPathComponent("Sessions"))
                    try FileSessionIO.ensureDirectory(stage.stage.appendingPathComponent("Sessions/sessions"))
                    try FileSessionIO.ensureDirectory(stage.stage.appendingPathComponent("Sessions/payloads"))
                    // Full-path order: payloads precede sessions. Only one session's
                    // reference ordering is materialized; the catalog buffers one chunk.
                    for session in snapshot.sessions {
                        for reference in session.payloads.keys.sorted(by: { Self.payloadPath($0) < Self.payloadPath($1) }) {
                            guard let source = session.payloads[reference] else { throw LibraryArchiveIO.invalid }
                            let file = try Self.copy(source, path: Self.payloadPath(reference), to: stage.stage, limit: reference.byteCount)
                            guard file.byteCount == reference.byteCount, file.digest == reference.digest else {
                                throw LibraryArchiveIO.invalid
                            }
                            try append(file)
                        }
                    }
                    for session in snapshot.sessions {
                        try append(Self.copy(session.journalURL, path: Self.journalPath(session.id), to: stage.stage,
                                             limit: LibraryArchiveLimits.maximumFileBytes))
                    }
                    while attachmentIndex < attachments.count {
                        try appendAttachment(attachments[attachmentIndex]); attachmentIndex += 1
                    }
                    let manifest = LibraryArchiveManifest(
                        formatVersion: 2, authorization: authorization,
                        modules: self.modules.map(\.identity), sessions: snapshot.sessions.map(\.head),
                        chunks: try catalog.finish())
                    try manifest.validate()
                    let bytes = try SessionCodec.encode(manifest)
                    guard bytes.count <= LibraryArchiveLimits.maximumManifestBytes else {
                        throw LibraryArchiveIO.invalid
                    }
                    try LibraryArchiveIO.write(bytes, to: stage.stage.appendingPathComponent("manifest.json"))
                    guard try Self.validateSync(at: stage.stage, modules: self.modules) == manifest else {
                        throw LibraryArchiveIO.invalid
                    }
                    try LibraryArchiveIO.syncTree(stage.stage)
                    try self.fault(.beforePublication)
                    try FileSessionIO.publishExclusive(stage.stage, to: stage.destination)
                    published = true
                    try FileSessionIO.syncDirectory(stage.destination.deletingLastPathComponent())
                    return manifest
                }
            }
        } catch { throw Self.safe(error) }
    }

    public func close() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            accepting = false
            if active == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Validation never repairs the supplied archive or opens a session writer.
    public static func validate(at directory: URL, modules: [SQLiteArchiveModule]) async throws
        -> LibraryArchiveManifest
    {
        try Task.checkCancellation()
        let catalog = try catalog(modules)
        return try await Task.detached(priority: .utility) {
            do { return try validateSync(at: directory, modules: catalog) } catch { throw safe(error) }
        }.value
    }

    static func validateSync(at directory: URL, modules: [SQLiteArchiveModule]) throws -> LibraryArchiveManifest {
        guard directory.isFileURL else { throw LibraryArchiveIO.invalid }
        try FileSessionIO.checkDirectory(directory)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try LibraryArchiveIO.requireSingleFile(manifestURL)
        let manifest = try SessionCodec.decode(
            LibraryArchiveManifest.self,
            from: BackupFileIO.read(manifestURL, limit: LibraryArchiveLimits.maximumManifestBytes))
        try manifest.validate()
        guard manifest.modules == modules.map(\.identity) else { throw LibraryArchiveIO.invalid }
        let catalogPaths = Set(manifest.chunks.map(\.path))
        let inventory = try LibraryArchiveIO.FileIterator(directory: directory)
        var catalogCount = 0
        var sawManifest = false
        func nextSourcePath() throws -> String? {
            while let path = try inventory.next() {
                if path == "manifest.json" { sawManifest = true }
                else if path.hasPrefix("Catalog/") {
                    guard catalogPaths.contains(path) else { throw LibraryArchiveIO.invalid }
                    catalogCount += 1
                } else { return path }
            }
            return nil
        }
        // Compare actual entry names, not only counts: case aliases may identify
        // the same physical file on a case-insensitive volume.
        try LibraryArchiveFileCatalog.forEachFile(in: directory, manifest: manifest) { file in
            guard try nextSourcePath() == file.path else { throw LibraryArchiveIO.invalid }
            let url = try LibraryArchiveIO.file(file.path, under: directory)
            guard try inspectFile(url, path: file.path) == file else { throw LibraryArchiveIO.invalid }
        }
        guard try nextSourcePath() == nil, sawManifest, catalogCount == manifest.chunks.count else {
            throw LibraryArchiveIO.invalid
        }
        let sessionSnapshot = try FileSessionArchive.inspect(directory: directory.appendingPathComponent("Sessions"))
        guard sessionSnapshot.sessions.map(\.head) == manifest.sessions else { throw LibraryArchiveIO.invalid }
        let dbURL = directory.appendingPathComponent("Business.sqlite")
        var configuration = Configuration()
        configuration.readonly = true
        let database = try DatabaseQueue(path: dbURL.path, configuration: configuration)
        defer { try? database.close() }
        let attachments = try database.read { db in
            guard
                try SQLiteLibraryAuthority.availableAuthorization(in: db, libraryID: manifest.authorization.libraryID)
                    == manifest.authorization
            else {
                throw LibraryArchiveIO.invalid
            }
            return try inspectDatabase(db, snapshot: sessionSnapshot, modules: modules)
        }
        let attachmentsByPath = Dictionary(uniqueKeysWithValues: attachments.map { ($0.path, $0) })
        var attachmentCount = 0
        try LibraryArchiveFileCatalog.forEachFile(in: directory, manifest: manifest) { file in
            if file.path == "Business.sqlite" || file.path.hasPrefix("Sessions/") { return }
            guard let attachment = attachmentsByPath[file.path],
                  file.byteCount == attachment.byteCount, file.digest == attachment.digest else {
                throw LibraryArchiveIO.invalid
            }
            attachmentCount += 1
        }
        guard attachmentCount == attachments.count else { throw LibraryArchiveIO.invalid }
        return manifest
    }

    static func catalog(_ requested: [SQLiteArchiveModule]) throws -> [SQLiteArchiveModule] {
        guard requested.count < 128 else { throw LibraryArchiveIO.invalid }
        let modules = ([try SQLiteLibraryAuthority.archiveModule()] + requested).sorted {
            $0.identity.name < $1.identity.name
        }
        guard Set(modules.map(\.identity.name)).count == modules.count,
            Set(modules.flatMap(\.schema).map(\.name)).count == modules.flatMap(\.schema).count,
            Set(modules.flatMap({ $0.sessionExtensions.keys })).count
                == modules.reduce(0, { $0 + $1.sessionExtensions.count })
        else { throw LibraryArchiveIO.invalid }
        return modules
    }

    static func inspectDatabase(
        _ db: Database, snapshot: FileSessionSnapshot,
        modules: [SQLiteArchiveModule]
    ) throws -> [LibraryArchiveAttachment] {
        guard try SQLiteArchiveSchemaObject.read(in: db) == modules.flatMap(\.schema).sorted(by: { $0.name < $1.name }),
            try String.fetchAll(db, sql: "PRAGMA integrity_check(1)") == ["ok"],
            try Row.fetchOne(db, sql: "PRAGMA foreign_key_check") == nil,
            let pages = try Int64.fetchOne(db, sql: "PRAGMA page_count"),
            let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size"), pages >= 0, pageSize > 0,
            pages <= Int64(LibraryArchiveLimits.maximumFileBytes) / pageSize
        else { throw LibraryArchiveIO.invalid }
        var attachments: [LibraryArchiveAttachment] = []
        var paths: Set<String> = []
        let extensionSchemas = Dictionary(
            uniqueKeysWithValues: modules.flatMap { $0.sessionExtensions.map { ($0.key, $0.value) } })
        for session in snapshot.sessions {
            var state = SessionState(id: session.id)
            for batch in try snapshot.readBatches(sessionID: session.id) {
                try state.apply(batch, extensionSchemas: extensionSchemas)
            }
            guard state.sequence == session.head.cursor.sequence else { throw LibraryArchiveIO.invalid }
        }
        for module in modules {
            let additions = try module.inspect(db, snapshot)
            guard additions.count <= LibraryArchiveLimits.maximumFiles - attachments.count else {
                throw LibraryArchiveIO.invalid
            }
            for attachment in additions {
                try LibraryArchiveIO.validatePath(attachment.path)
                guard
                    !["Business.sqlite", "Sessions", "Projections", "Catalog", "manifest.json"].contains(
                        String(attachment.path.split(separator: "/")[0])),
                    !attachment.path.hasPrefix("Business.sqlite"),
                    paths.insert(attachment.path).inserted,
                    (0...LibraryArchiveLimits.maximumAttachmentBytes).contains(attachment.byteCount),
                    attachment.digest.count == 64,
                    attachment.digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
                else { throw LibraryArchiveIO.invalid }
            }
            attachments += additions
        }
        return attachments.sorted { $0.path < $1.path }
    }

    private static func snapshot(_ source: Database, to url: URL) throws {
        try LibraryArchiveIO.write(Data(), to: url)
        let destination = try DatabaseQueue(path: url.path)
        do {
            try destination.writeWithoutTransaction { db in
                try source.backup(to: db)
                try db.execute(sql: "PRAGMA journal_mode = DELETE")
            }
            try destination.close()
            try FileSessionIO.syncFile(url)
        } catch {
            try? destination.close()
            throw error
        }
    }

    private static func checkCaptureSize(
        _ db: Database, snapshot: FileSessionSnapshot,
        attachments: [LibraryArchiveAttachment], root: URL
    ) throws {
        guard let pages = try Int64.fetchOne(db, sql: "PRAGMA page_count"),
            let size = try Int64.fetchOne(db, sql: "PRAGMA page_size"), pages >= 0, size > 0,
            pages <= Int64(LibraryArchiveLimits.maximumFileBytes) / size
        else { throw LibraryArchiveIO.invalid }
        var total = pages * size
        for session in snapshot.sessions {
            total += try LibraryArchiveIO.byteCount(session.journalURL, limit: LibraryArchiveLimits.maximumFileBytes)
            total += session.payloads.keys.reduce(Int64(0), { $0 + Int64($1.byteCount) })
            guard total <= LibraryArchiveLimits.maximumTotalBytes else { throw LibraryArchiveIO.invalid }
        }
        for attachment in attachments {
            let source = try LibraryArchiveIO.file(attachment.path, under: root)
            guard try LibraryArchiveIO.byteCount(source, limit: attachment.byteCount) == attachment.byteCount else {
                throw LibraryArchiveIO.invalid
            }
            total += Int64(attachment.byteCount)
            guard total <= LibraryArchiveLimits.maximumTotalBytes else { throw LibraryArchiveIO.invalid }
        }
    }

    static func inspectFile(_ url: URL, path: String) throws -> LibraryArchiveManifest.File {
        try LibraryArchiveIO.requireSingleFile(url)
        let result = try BackupFileIO.inspect(url, limit: LibraryArchiveLimits.maximumFileBytes)
        return .init(path: path, byteCount: result.byteCount, digest: result.digest)
    }

    static func copy(_ source: URL, path: String, to root: URL, limit: Int) throws
        -> LibraryArchiveManifest.File
    {
        try LibraryArchiveIO.requireSingleFile(source)
        let destination = try LibraryArchiveIO.file(path, under: root, createParents: true)
        let result = try BackupFileIO.copy(from: source, to: destination, limit: limit)
        return .init(path: path, byteCount: result.byteCount, digest: result.digest)
    }

    static func journalPath(_ id: ConversationID) -> String {
        "Sessions/sessions/\(id.rawValue.uuidString).jsonl"
    }
    static func payloadPath(_ reference: SessionPayloadReference) -> String {
        "Sessions/payloads/\(reference.sessionID.rawValue.uuidString)/\(reference.batchID.uuidString)/\(reference.id.uuidString).bin"
    }
    private static func safe(_ error: any Error) -> MiraError {
        if error is CancellationError { return .init(.cancelled, "The library archive operation was cancelled.") }
        return error as? MiraError ?? LibraryArchiveIO.invalid
    }
    private func finish() {
        lock.lock()
        active -= 1
        let pending = active == 0 && !accepting ? waiters : []
        if !pending.isEmpty { waiters.removeAll() }
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}
