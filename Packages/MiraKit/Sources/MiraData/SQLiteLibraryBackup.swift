import CryptoKit
import Darwin
import Foundation
import GRDB
import MiraCore

enum LibraryBackupFaultStage: Sendable, Equatable {
    case afterDatabaseSnapshot
    case beforeExportInstall
    case afterRestoreValidation
    case beforeRestoreInstall
}

private enum LibraryBackupFaultControl {
    static let lock = NSLock()
    nonisolated(unsafe) static var handlers: [String: ((LibraryBackupFaultStage) throws -> Void)] = [:]

    static func set(_ handler: ((LibraryBackupFaultStage) throws -> Void)?, for path: String) {
        lock.withLock {
            if let handler { handlers[path] = handler }
            else { handlers.removeValue(forKey: path) }
        }
    }

    static func invoke(_ stage: LibraryBackupFaultStage, for path: String) throws {
        let handler = lock.withLock { handlers[path] }
        try handler?(stage)
    }
}

private struct LibraryBackupDatabase: Codable, Equatable {
    let digest: String
    let byteCount: Int
}

private struct LibraryBackupBlob: Codable, Equatable {
    let digest: String
    let byteCount: Int
}

private struct LibraryBackupManifest: Codable, Equatable {
    let formatVersion: Int
    let schemaVersion: Int
    let appVersion: String
    let database: LibraryBackupDatabase
    let blobs: [LibraryBackupBlob]
}

private struct BackupBlobReference: Equatable {
    let digest: String
    let byteCount: Int
}

extension SQLiteMiraStore {
    func installLibraryBackupFaultInjector(_ handler: ((LibraryBackupFaultStage) throws -> Void)?) {
        LibraryBackupFaultControl.set(handler, for: libraryDirectory.standardizedFileURL.path)
    }

    func exportLibraryBackup(to destination: URL) throws {
        try blobs.withMaintenanceLock {
            try safely {
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw MiraError(.conflict, "The backup destination already exists.")
                }
                let parent = destination.deletingLastPathComponent()
                try Self.createDirectoryIfNeeded(parent)
                let stage = parent.appendingPathComponent(".mira-backup-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: stage) }
                try Self.createDirectoryIfNeeded(stage)

                let databaseStage = stage.appendingPathComponent("Mira.sqlite")
                try Self.snapshotDatabase(pool, to: databaseStage)
                try Self.normalizeSQLiteJournal(at: databaseStage)
                try Self.removeClosedSQLiteSharedMemory(for: databaseStage)
                try Self.requireNoSQLiteSidecars(for: databaseStage)
                try LibraryBackupFaultControl.invoke(.afterDatabaseSnapshot, for: libraryDirectory.standardizedFileURL.path)
                try Self.setPrivateFile(databaseStage)
                let databaseData = try Self.readBoundedRegularFile(databaseStage, limit: 512 * 1024 * 1024)
                let sourceBlobs = blobs
                let references: [BackupBlobReference]
                references = try Self.readAndValidateDatabase(at: databaseStage, blobs: sourceBlobs)
                let sourceBlobDigests = try sourceBlobs.digests()
                let referencedDigests = Set(references.map(\.digest))
                guard referencedDigests.isSubset(of: Set(sourceBlobDigests)) else {
                    throw MiraError(.storage, "The library references a missing managed blob.")
                }

                let stagedBlobStore = try ManagedBlobStore(directory: stage)
                for reference in references {
                    let bytes = try blobs.read(reference.digest)
                    guard bytes.count == reference.byteCount else {
                        throw MiraError(.storage, "A managed blob size does not match its database record.")
                    }
                    _ = try stagedBlobStore.install(bytes)
                }
                let manifest = LibraryBackupManifest(
                    formatVersion: 1,
                    schemaVersion: Self.currentSchemaVersion,
                    appVersion: "0.1.0",
                    database: .init(digest: Self.backupDigest(databaseData), byteCount: databaseData.count),
                    blobs: references.sorted { $0.digest < $1.digest }.map { .init(digest: $0.digest, byteCount: $0.byteCount) }
                )
                try Self.writeManifest(manifest, to: stage.appendingPathComponent("manifest.json"))
                try Self.validateBackupBundle(stage, manifest: manifest)
                try LibraryBackupFaultControl.invoke(.beforeExportInstall, for: libraryDirectory.standardizedFileURL.path)
                try FileManager.default.moveItem(at: stage, to: destination)
            }
        }
    }

    func restoreLibraryBackup(from source: URL, to directory: URL) throws {
        try blobs.withMaintenanceLock {
            try safely {
                let manifest = try Self.readManifest(from: source)
                let sourceDatabase = source.appendingPathComponent("Mira.sqlite")
                let sourceData = try Self.readBoundedRegularFile(sourceDatabase, limit: 512 * 1024 * 1024)
                guard Self.backupDigest(sourceData) == manifest.database.digest,
                      sourceData.count == manifest.database.byteCount else {
                    throw MiraError(.storage, "The backup database does not match its manifest.")
                }
                let sourceBlobs = try ManagedBlobStore(directory: source)
                let digests = try sourceBlobs.digests()
                guard Set(digests) == Set(manifest.blobs.map(\.digest)) else {
                    throw MiraError(.storage, "The backup blob set does not match its manifest.")
                }
                guard !FileManager.default.fileExists(atPath: directory.path) else {
                    throw MiraError(.conflict, "The restore destination already exists.")
                }
                let parent = directory.deletingLastPathComponent()
                try Self.createDirectoryIfNeeded(parent)
                let stage = parent.appendingPathComponent(".mira-restore-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: stage) }
                try Self.createDirectoryIfNeeded(stage)
                let stagedDatabase = stage.appendingPathComponent("Mira.sqlite")
                try sourceData.write(to: stagedDatabase, options: .atomic)
                try Self.setPrivateFile(stagedDatabase)
                let stagedBlobs = try ManagedBlobStore(directory: stage)
                for blob in manifest.blobs {
                    // Keep at most one managed blob in memory while copying;
                    // each read is descriptor-bound and hash-verified by the
                    // source store before it is installed in the owned stage.
                    let bytes = try sourceBlobs.read(blob.digest)
                    guard bytes.count == blob.byteCount else {
                        throw MiraError(.storage, "A backup blob size does not match its manifest.")
                    }
                    _ = try stagedBlobs.install(bytes)
                }
                try self.validateAndPrepareRestoredStore(at: stage, blobs: stagedBlobs, manifest: manifest)
                try Self.normalizeSQLiteJournal(at: stagedDatabase)
                try Self.removeClosedSQLiteSharedMemory(for: stagedDatabase)
                try Self.requireNoSQLiteSidecars(for: stagedDatabase)
                try LibraryBackupFaultControl.invoke(.afterRestoreValidation, for: libraryDirectory.standardizedFileURL.path)
                try LibraryBackupFaultControl.invoke(.beforeRestoreInstall, for: libraryDirectory.standardizedFileURL.path)
                try FileManager.default.moveItem(at: stage, to: directory)
            }
        }
    }
}

private extension SQLiteMiraStore {
    static func snapshotDatabase(_ pool: DatabasePool, to destination: URL) throws {
        let database = try DatabaseQueue(path: destination.path)
        try pool.backup(to: database)
        try database.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    static func readAndValidateDatabase(at url: URL, blobs: ManagedBlobStore) throws -> [BackupBlobReference] {
        let database = try DatabaseQueue(path: url.path)
        return try database.read { db in
            try validateBackupDatabase(in: db, blobs: blobs)
            return try backupBlobReferences(in: db)
        }
    }

    func validateAndPrepareRestoredStore(at directory: URL, blobs: ManagedBlobStore, manifest: LibraryBackupManifest) throws {
        // Validate the raw, owned snapshot before constructing a store. The
        // initializer performs migrations for a fresh database, so opening it
        // first would allow a forged current-version file to be changed before
        // exact schema validation completed.
        let rawDatabase = try DatabaseQueue(path: directory.appendingPathComponent("Mira.sqlite").path)
        try rawDatabase.write { db in
            try Self.validateBackupDatabase(in: db, blobs: blobs)
            let references = try Self.backupBlobReferences(in: db)
            let manifestReferences = manifest.blobs.map { BackupBlobReference(digest: $0.digest, byteCount: $0.byteCount) }.sorted { $0.digest < $1.digest }
            guard references.sorted(by: { $0.digest < $1.digest }) == manifestReferences else {
                throw MiraError(.storage, "The backup database blob references do not match its manifest.")
            }
            try prepareRestoredMemoryExtractionState(in: db, at: Date())
            try Self.validateContents(in: db)
        }
    }

    static func backupBlobReferences(in db: Database) throws -> [BackupBlobReference] {
        guard try db.tableExists("source_versions") else { return [] }
        let rows = try Row.fetchAll(db, sql: "SELECT content_hash, byte_count FROM source_versions ORDER BY content_hash, id")
        var references: [BackupBlobReference] = []
        var seen = Set<String>()
        var byteCounts: [String: Int] = [:]
        for row in rows {
            let digest = row["content_hash"] as String
            let byteCount = row["byte_count"] as Int
            if let previous = byteCounts[digest] {
                guard previous == byteCount else { throw MiraError(.storage, "The database managed blob reference is inconsistent.") }
                continue
            }
            byteCounts[digest] = byteCount
            _ = seen.insert(digest)
            guard digest.count == 64, byteCount >= 0, byteCount <= 10 * 1024 * 1024,
                  try Int.fetchOne(db, sql: "SELECT 1 FROM managed_blobs WHERE digest = ? AND byte_count = ?", arguments: [digest, byteCount]) != nil else {
                throw MiraError(.storage, "The database managed blob reference is invalid.")
            }
            references.append(.init(digest: digest, byteCount: byteCount))
        }
        return references
    }

    static func validateBackupDatabase(in db: Database, blobs: ManagedBlobStore) throws {
        guard (try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0) == currentSchemaVersion else {
            throw MiraError(.unsupported, "This backup uses an unsupported database version. Create a fresh library to continue; the backup was left untouched.")
        }
        let reference = try DatabaseQueue()
        try makeMigrator().migrate(reference)
        let expectedSchema = try reference.read { try schemaSignature(in: $0) }
        guard try schemaSignature(in: db) == expectedSchema else {
            throw MiraError(.unsupported, "The backup schema or constraints do not match the current version.")
        }
        try validateBackupMetadata(in: db)
        guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok" else {
            throw MiraError(.storage, "Backup integrity validation failed.")
        }
        guard (try String.fetchOne(db, sql: "PRAGMA foreign_key_check") ?? "").isEmpty else {
            throw MiraError(.storage, "Backup foreign-key validation failed.")
        }
        try validateContents(in: db)
        try validateKnowledgeBlobChunks(in: db, blobs: blobs)
    }

    static func validateKnowledgeBlobChunks(in db: Database, blobs: ManagedBlobStore) throws {
        func fail() -> MiraError { .init(.storage, "The knowledge backup chunks do not match their source blobs.") }
        let versions = try Row.fetchAll(db, sql: "SELECT id, source_id, content_hash, byte_count, parse_state FROM source_versions ORDER BY id")
        for version in versions {
            let versionID: String = version["id"]
            let sourceID: String = version["source_id"]
            let digest: String = version["content_hash"]
            let byteCount: Int = version["byte_count"]
            guard let bytes = try? blobs.read(digest), bytes.count == byteCount else { throw fail() }
            let state: String = version["parse_state"]
            if state == "failed" {
                guard (try? MarkdownChunker.chunk(bytes)) == nil,
                      try Int.fetchOne(db, sql: "SELECT 1 FROM source_chunks WHERE version_id = ? LIMIT 1", arguments: [versionID]) == nil else { throw fail() }
                continue
            }
            guard state == "ready", let slices = try? MarkdownChunker.chunk(bytes) else { throw fail() }
            let rows = try Row.fetchAll(db, sql: "SELECT sequence, text, summary_json FROM source_chunks WHERE version_id = ? ORDER BY sequence", arguments: [versionID])
            guard rows.count == slices.count else { throw fail() }
            for (row, slice) in zip(rows, slices) {
                let summary: SourceChunkSummary
                do { summary = try decode(row["summary_json"]) }
                catch { throw fail() }
                guard row["sequence"] as Int == slice.sequence,
                      row["text"] as String == slice.text,
                      summary.sourceID.rawValue.uuidString.lowercased() == sourceID,
                      summary.sourceVersionID.rawValue.uuidString.lowercased() == versionID,
                      summary.sequence == slice.sequence,
                      summary.startLine == slice.startLine,
                      summary.endLine == slice.endLine,
                      summary.startUTF8Offset == slice.startUTF8Offset,
                      summary.endUTF8Offset == slice.endUTF8Offset,
                      summary.headingPath == slice.headingPath,
                      summary.contentHash == knowledgeHash(Data(slice.text.utf8)) else { throw fail() }
            }
        }
    }

    static func readManifest(from directory: URL) throws -> LibraryBackupManifest {
        try validateBundleFilesystem(directory)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try readBoundedRegularFile(manifestURL, limit: 8 * 1024 * 1024)
        let manifest: LibraryBackupManifest
        do { manifest = try JSONDecoder().decode(LibraryBackupManifest.self, from: data) }
        catch { throw MiraError(.storage, "The backup manifest is invalid.") }
        guard manifest.formatVersion == 1, manifest.schemaVersion == currentSchemaVersion,
              manifest.appVersion == "0.1.0", manifest.blobs.count <= 100_000,
              manifest.database.byteCount >= 0, manifest.database.byteCount <= 512 * 1024 * 1024,
              manifest.database.digest.count == 64 else {
            throw MiraError(.unsupported, "The backup manifest is unsupported.")
        }
        var total = 0
        var seen = Set<String>()
        for blob in manifest.blobs {
            guard blob.digest.count == 64, blob.byteCount >= 0, blob.byteCount <= 10 * 1024 * 1024,
                  seen.insert(blob.digest).inserted,
                  total.addingReportingOverflow(blob.byteCount).overflow == false else {
                throw MiraError(.storage, "The backup manifest blob list is invalid.")
            }
            total += blob.byteCount
        }
        guard total <= 2 * 1024 * 1024 * 1024 else { throw MiraError(.storage, "The backup manifest is too large.") }
        return manifest
    }

    static func writeManifest(_ manifest: LibraryBackupManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
        try setPrivateFile(url)
    }

    static func validateBackupBundle(_ directory: URL, manifest: LibraryBackupManifest) throws {
        try validateBundleFilesystem(directory)
        let loaded = try readManifest(from: directory)
        guard loaded == manifest else { throw MiraError(.storage, "The backup manifest changed during creation.") }
        let data = try readBoundedRegularFile(directory.appendingPathComponent("Mira.sqlite"), limit: 512 * 1024 * 1024)
        guard backupDigest(data) == manifest.database.digest, data.count == manifest.database.byteCount else {
            throw MiraError(.storage, "The backup database does not match its manifest.")
        }
        let store = try ManagedBlobStore(directory: directory)
        let actual = try store.digests()
        guard Set(actual) == Set(manifest.blobs.map(\.digest)) else { throw MiraError(.storage, "The backup blob set does not match its manifest.") }
        for blob in manifest.blobs { guard try store.read(blob.digest).count == blob.byteCount else { throw MiraError(.storage, "A managed blob size does not match its manifest.") } }
    }

    static func readBoundedRegularFile(_ url: URL, limit: Int) throws -> Data {
        let path = url.standardizedFileURL.path
        let descriptor = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else {
            throw MiraError(.storage, "The backup file is invalid or too large.")
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
              before.st_size >= 0, before.st_size <= off_t(limit) else {
            throw MiraError(.storage, "The backup file is invalid or too large.")
        }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        while data.count < Int(before.st_size) {
            var buffer = [UInt8](repeating: 0, count: min(64 * 1024, Int(before.st_size) - data.count))
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw MiraError(.storage, "The backup file could not be read.") }
            data.append(contentsOf: buffer[0..<count])
        }
        var after = stat()
        var pathAfter = stat()
        guard fstat(descriptor, &after) == 0,
              path.withCString({ lstat($0, &pathAfter) }) == 0,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
              pathAfter.st_dev == before.st_dev, pathAfter.st_ino == before.st_ino,
              pathAfter.st_size == before.st_size,
              pathAfter.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              pathAfter.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              pathAfter.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              pathAfter.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
            throw MiraError(.storage, "The backup file changed while it was read.")
        }
        return data
    }

    static func backupDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func setPrivateFile(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func requireNoSQLiteSidecars(for database: URL) throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: database.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                throw MiraError(.storage, "The staged database left an unexpected journal file.")
            }
        }
    }

    /// SQLite leaves a named shared-memory companion after WAL use even after
    /// checkpointing. It is safe to remove this known transient file only after
    /// every owned database handle has closed; journal and WAL files are never
    /// removed implicitly and remain hard failures below.
    static func removeClosedSQLiteSharedMemory(for database: URL) throws {
        let sidecar = URL(fileURLWithPath: database.path + "-shm")
        if FileManager.default.fileExists(atPath: sidecar.path) {
            try FileManager.default.removeItem(at: sidecar)
        }
    }

    static func normalizeSQLiteJournal(at database: URL) throws {
        let queue = try DatabaseQueue(path: database.path)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    static func validateBundleFilesystem(_ directory: URL) throws {
        let root = directory.standardizedFileURL.path
        var rootInfo = stat()
        guard root.withCString({ lstat($0, &rootInfo) }) == 0,
              rootInfo.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR) else {
            throw MiraError(.storage, "The backup bundle directory is invalid.")
        }
        let rootNames = try FileManager.default.contentsOfDirectory(atPath: root)
        guard Set(rootNames) == ["Mira.sqlite", "manifest.json", "Blobs"] else {
            throw MiraError(.storage, "The backup bundle contains unexpected files.")
        }
        for name in ["Mira.sqlite", "manifest.json"] {
            let path = (root as NSString).appendingPathComponent(name)
            var info = stat()
            guard path.withCString({ lstat($0, &info) }) == 0,
                  info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG) else {
                throw MiraError(.storage, "The backup bundle file is invalid.")
            }
        }
        let blobs = (root as NSString).appendingPathComponent("Blobs")
        var blobsInfo = stat()
        guard blobs.withCString({ lstat($0, &blobsInfo) }) == 0,
              blobsInfo.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR) else {
            throw MiraError(.storage, "The backup blob directory is invalid.")
        }
        for first in try FileManager.default.contentsOfDirectory(atPath: blobs) {
            guard isShard(first) else { throw MiraError(.storage, "The backup blob hierarchy is invalid.") }
            let firstPath = (blobs as NSString).appendingPathComponent(first)
            try validateDirectory(firstPath, error: "The backup blob hierarchy is invalid.")
            for second in try FileManager.default.contentsOfDirectory(atPath: firstPath) {
                guard isShard(second) else { throw MiraError(.storage, "The backup blob hierarchy is invalid.") }
                let secondPath = (firstPath as NSString).appendingPathComponent(second)
                try validateDirectory(secondPath, error: "The backup blob hierarchy is invalid.")
                for digest in try FileManager.default.contentsOfDirectory(atPath: secondPath) {
                    guard isDigest(digest), String(digest.prefix(2)) == first, String(digest.dropFirst(2).prefix(2)) == second else {
                        throw MiraError(.storage, "The backup blob hierarchy is invalid.")
                    }
                    let path = (secondPath as NSString).appendingPathComponent(digest)
                    var info = stat()
                    guard path.withCString({ lstat($0, &info) }) == 0,
                          info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG) else {
                        throw MiraError(.storage, "The backup blob hierarchy is invalid.")
                    }
                }
            }
        }
    }

    static func validateDirectory(_ path: String, error message: String) throws {
        var info = stat()
        guard path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR) else {
            throw MiraError(.storage, message)
        }
    }

    static func isShard(_ value: String) -> Bool {
        value.count == 2 && value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }
}
