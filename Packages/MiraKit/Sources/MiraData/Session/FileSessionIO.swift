import Foundation
import CryptoKit
import Darwin
import MiraCore

/// Blocking primitives are called only by the library's serial I/O owner.
enum FileSessionIO {
    struct Identity: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
    }
    static func identity(_ url: URL) throws -> Identity {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw failure() }
        return .init(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                     modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
                     changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec)
    }
    static func failure() -> MiraError { .init(.storage, "The session library could not validate or persist its data.") }
    static func digest(_ data: Data) -> String { DigestEncoding.hexadecimal(SHA256.hash(data: data)) }
    static func encodeRecord(_ record: FileSessionRecord) throws -> Data {
        try FileSessionEventCodec.encode(record)
    }
    static func decodeRecord(_ data: Data) throws -> FileSessionRecord {
        do { return try FileSessionEventCodec.decode(data) }
        catch { throw failure() }
    }

    static func checkDirectory(_ url: URL, allowMissing: Bool = false) throws {
        var info = stat()
        if lstat(url.path, &info) < 0 {
            if allowMissing && errno == ENOENT { return }
            throw failure()
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw failure() }
    }
    static func ensureDirectory(_ url: URL) throws {
        try checkDirectory(url, allowMissing: true)
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw failure() }
        try checkDirectory(url)
        guard chmod(url.path, 0o700) == 0 else { throw failure() }
        try syncDirectory(url.deletingLastPathComponent())
    }
    static func requireRegular(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw failure() }
    }
    static func write(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure() }
                offset += count
            }
        }
    }
    static func publishExclusive(_ source: URL, to destination: URL) throws {
        guard Darwin.renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw failure() }
    }
    static func sync(_ fd: Int32) throws {
        while fsync(fd) != 0 { if errno != EINTR { throw failure() } }
    }
    static func syncFile(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }; defer { Darwin.close(fd) }
        try requireRegular(fd); try sync(fd)
    }
    static func syncDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }; defer { Darwin.close(fd) }
        try sync(fd)
    }
    static func readBounded(_ url: URL, expectedCount: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }; defer { Darwin.close(fd) }
        try requireRegular(fd)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size == expectedCount,
              (0...SessionFormatLimits.maximumPayloadBytes).contains(expectedCount) else { throw failure() }
        var data = Data(count: expectedCount)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < expectedCount {
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), expectedCount - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure() }; offset += count
            }
        }
        var trailing: UInt8 = 0
        guard Darwin.read(fd, &trailing, 1) == 0 else { throw failure() }
        return data
    }
    static func unlinkIfPresent(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) < 0 { guard errno == ENOENT else { throw failure() }; return }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              Darwin.unlink(url.path) == 0 else { throw failure() }
    }

    /// The allocation bound applies to a record, never the total journal length.
    static func scan(_ url: URL, sessionID: ConversationID) throws -> [SessionBatch] {
        var result: [SessionBatch] = []
        try scanRecords(url, sessionID: sessionID) { record, _, _ in result.append(record.batch) }
        return result
    }

    /// Recovery publishes only complete transactions. A torn final transaction is
    /// removed as a unit; corruption in a complete record is never repaired away.
    static func scanRecords(_ url: URL, sessionID: ConversationID,
                            consume: (FileSessionRecord, Int64, Data) throws -> Void) throws {
        let fd = Darwin.open(url.path, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return }
        guard fd >= 0 else { throw failure() }; defer { Darwin.close(fd) }
        try requireRegular(fd)
        let end = try scanTransactions(fd, sessionID: sessionID, maximumRecords: Int.max, consume: consume)
        switch end.tail {
        case .empty: break
        case .uncommitted:
            guard ftruncate(fd, off_t(end.committedBytes)) == 0 else { throw failure() }
            try sync(fd)
        case .missingDelimiter:
            guard lseek(fd, 0, SEEK_END) >= 0 else { throw failure() }
            try write(Data([10]), fd: fd)
            try sync(fd)
        }
    }

    private enum Tail { case empty, uncommitted, missingDelimiter }
    private struct ScanEnd { let committedBytes: Int64; let readBytes: Int64; let tail: Tail }

    /// Bounded line assembly is shared by recovery and the strict archive reader.
    private static func scanTransactions(_ fd: Int32, sessionID: ConversationID, maximumRecords: Int,
        consume: (FileSessionRecord, Int64, Data) throws -> Void) throws -> ScanEnd {
        var line = Data(), transaction = Data(), sequence: Int64 = 0, offset: Int64 = 0, readBytes: Int64 = 0
        var identities: Set<UUID> = [], pendingEvents = 0
        var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
        func appendSegment(_ bytes: ArraySlice<UInt8>) throws {
            guard transaction.count + line.count <= FileSessionEventCodec.maximumBytes - bytes.count else { throw failure() }
            line.append(contentsOf: bytes)
        }
        func acceptLine() throws -> Bool {
            guard !line.isEmpty else { throw failure() }
            let isCommit: Bool
            do { isCommit = try FileSessionEventCodec.isCommit(line) } catch { throw failure() }
            transaction.append(line)
            line.removeAll(keepingCapacity: true)
            if isCommit {
                guard identities.count < maximumRecords else { throw failure() }
                let value = try decodeRecord(transaction), batch = value.batch
                guard batch.sessionID == sessionID, batch.expectedSequence == sequence,
                      identities.insert(batch.id).inserted else { throw failure() }
                try consume(value, offset, transaction)
                sequence = batch.cursor.sequence
                offset += Int64(transaction.count + 1)
                transaction.removeAll(keepingCapacity: true)
                pendingEvents = 0
                return true
            }
            pendingEvents += 1
            guard pendingEvents <= SessionFormatLimits.maximumEventsPerBatch,
                  transaction.count < FileSessionEventCodec.maximumBytes else { throw failure() }
            transaction.append(10)
            return false
        }
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw failure() }
            if count == 0 { break }
            guard readBytes <= Int64.max - Int64(count) else { throw failure() }
            readBytes += Int64(count)
            var start = 0
            for index in 0..<count where chunk[index] == 10 {
                try appendSegment(chunk[start..<index])
                _ = try acceptLine()
                start = index + 1
            }
            try appendSegment(chunk[start..<count])
        }
        if !line.isEmpty {
            if (try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])) != nil {
                if try acceptLine() {
                    return .init(committedBytes: offset, readBytes: readBytes, tail: .missingDelimiter)
                }
            }
            // Incomplete JSON at EOF is an interrupted write. Complete but invalid
            // JSON has already failed through acceptLine, including bad commits.
            return .init(committedBytes: offset, readBytes: readBytes, tail: .uncommitted)
        }
        return .init(committedBytes: offset, readBytes: readBytes, tail: transaction.isEmpty ? .empty : .uncommitted)
    }

    /// Reads exactly one indexed record and validates bytes again at the point of use.
    static func readRecord(_ url: URL, sessionID: ConversationID,
                           record: FileSessionIndex.Record) throws -> FileSessionRecord {
        guard record.offset >= 0, (1...(FileSessionRecord.maximumBytes + 257)).contains(record.byteCount),
              record.offset <= Int64.max - Int64(record.byteCount) else { throw failure() }
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }; defer { Darwin.close(fd) }
        try requireRegular(fd)
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_size >= record.offset + Int64(record.byteCount) else { throw failure() }
        var bytes = Data(count: record.byteCount)
        try bytes.withUnsafeMutableBytes { buffer in
            var total = 0
            while total < record.byteCount {
                let count = pread(fd, buffer.baseAddress!.advanced(by: total), record.byteCount - total, record.offset + Int64(total))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure() }
                total += count
            }
        }
        var after = stat(), pathAfter = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &pathAfter) == 0,
              sameFile(before, after), sameFile(before, pathAfter), bytes.last == 10 else { throw failure() }
        bytes.removeLast()
        guard digest(bytes) == record.digest else { throw failure() }
        let value = try decodeRecord(bytes)
        let batch = value.batch
        guard batch.sessionID == sessionID, batch.id == record.id,
              batch.expectedSequence == record.expectedSequence, batch.cursor.sequence == record.sequence else { throw failure() }
        return value
    }

    /// Strict read-only journal scan for archive validation. Unlike recovery
    /// scanning, this never truncates or appends a delimiter to the source.
    static func scanStrict(_ url: URL, sessionID: ConversationID, maximumRecords: Int,
                           consume observer: ((FileSessionRecord) throws -> Void)? = nil) throws -> [SessionBatch] {
        guard maximumRecords > 0 else { throw failure() }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw failure() }; defer { Darwin.close(fd) }
        try requireRegular(fd)
        var before = stat(); guard fstat(fd, &before) == 0 else { throw failure() }
        let perRecord = FileSessionEventCodec.maximumBytes + 1
        guard maximumRecords <= Int.max / perRecord else { throw failure() }
        let maximumTotal = min(maximumRecords * perRecord, LibraryArchiveLimits.maximumFileBytes)
        guard before.st_size >= 0, before.st_size <= maximumTotal else { throw failure() }
        var result: [SessionBatch] = []
        let end = try scanTransactions(fd, sessionID: sessionID, maximumRecords: maximumRecords) { value, _, _ in
            try observer?(value)
            result.append(value.batch)
        }
        guard end.tail == .empty else { throw failure() }
        var after = stat(), pathAfter = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &pathAfter) == 0,
              end.readBytes == before.st_size, sameFile(before, after), sameFile(before, pathAfter) else { throw failure() }
        return result
    }

    static func validateFile(_ url: URL, expectedCount: Int, expectedDigest: String) throws {
        guard (0...SessionFormatLimits.maximumPayloadBytes).contains(expectedCount) else { throw failure() }
        let result = try BackupFileIO.inspect(url, limit: expectedCount)
        guard result.byteCount == expectedCount, result.digest == expectedDigest else { throw failure() }
    }

    private static func sameFile(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev && before.st_ino == after.st_ino && before.st_size == after.st_size
            && before.st_mode == after.st_mode && before.st_nlink == after.st_nlink
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    static func directoryEntries(_ url: URL, limit: Int) throws -> [URL] {
        guard limit > 0 else { throw failure() }
        var info = stat(); guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw failure() }
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        let directory = fdopendir(fd); guard let directory else { Darwin.close(fd); throw failure() }
        defer { closedir(directory) }
        var result: [URL] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw failure() }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard result.count < limit else { throw failure() }
            result.append(url.appendingPathComponent(name, isDirectory: false))
        }
        return result
    }
}
