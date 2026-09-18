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
    /// Commit metadata is outside the DSH semantic event sequence. The digest
    /// covers every preceding line in this physical transaction, including LF.
    struct Commit: Codable {
        let type: String
        let version: Int
        let batchId: UUID
        let expectedSequence: Int64
        let sequence: Int64
        let firstSeq: Int
        let nextSeq: Int
        let recordCount: Int
        let checksum: String
    }

    static func frame(_ batch: SessionBatch, previous: SessionLogState) throws
        -> (bytes: Data, state: SessionLogState) {
        let encoded = try SessionLogCodec.encode(batch, previous: previous)
        var body = Data()
        for record in encoded.records {
            body.append(try SessionCodec.encode(record)); body.append(10)
            guard body.count <= SessionFormatLimits.maximumBatchBytes else { throw failure() }
        }
        let commit = Commit(type: "mira/commit", version: 1, batchId: batch.id,
            expectedSequence: batch.expectedSequence, sequence: batch.cursor.sequence,
            firstSeq: previous.nextSeq, nextSeq: encoded.state.nextSeq,
            recordCount: encoded.records.count, checksum: digest(body))
        body.append(try SessionCodec.encode(commit))
        guard body.count <= SessionFormatLimits.maximumBatchBytes else { throw failure() }
        return (body, encoded.state)
    }

    static func decodeFrame(_ bytes: Data, sessionID: ConversationID, previous: SessionLogState) throws
        -> (batch: SessionBatch, state: SessionLogState) {
        guard bytes.count <= SessionFormatLimits.maximumBatchBytes,
              let delimiter = bytes.lastIndex(of: 10) else { throw failure() }
        let body = Data(bytes[...delimiter])
        let commit = try SessionCodec.decode(Commit.self, from: Data(bytes[bytes.index(after: delimiter)...]))
        let lines = body.split(separator: 10, omittingEmptySubsequences: false).dropLast()
        guard commit.type == "mira/commit", commit.version == 1,
              commit.expectedSequence == previous.nextInternalSequence,
              commit.firstSeq == previous.nextSeq, commit.nextSeq > commit.firstSeq,
              commit.recordCount == lines.count, digest(body) == commit.checksum else { throw failure() }
        let records = try lines.map { try SessionCodec.decode(SessionLogRecord.self, from: Data($0)) }
        let decoded = try SessionLogCodec.decode(records, batchID: commit.batchId, sessionID: sessionID, previous: previous)
        guard decoded.batch.cursor.sequence == commit.sequence, decoded.state.nextSeq == commit.nextSeq else { throw failure() }
        try decoded.batch.validate()
        return decoded
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
              (0...SessionFormatLimits.maximumContentBytes).contains(expectedCount) else { throw failure() }
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
        try scanRecords(url, sessionID: sessionID) { batch, _, _, _ in result.append(batch) }
        return result
    }

    /// Only complete checksummed transactions are published. A tail without a
    /// commit is discarded on recovery; a malformed committed frame is rejected.
    static func scanRecords(_ url: URL, sessionID: ConversationID,
                            consume: (SessionBatch, Int64, Data, SessionLogState) throws -> Void) throws {
        try scanFrames(url, sessionID: sessionID, repair: true, maximumRecords: Int.max, consume: consume)
    }

    private static func scanFrames(_ url: URL, sessionID: ConversationID, repair: Bool,
                                   maximumRecords: Int,
                                   consume: (SessionBatch, Int64, Data, SessionLogState) throws -> Void) throws {
        let fd = Darwin.open(url.path, (repair ? O_RDWR : O_RDONLY) | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT && repair { return }
        guard fd >= 0 else { throw failure() }; defer { Darwin.close(fd) }
        try requireRegular(fd)
        var before = stat(); guard fstat(fd, &before) == 0 else { throw failure() }
        guard repair || (0...Int64(LibraryArchiveLimits.maximumFileBytes)).contains(before.st_size) else { throw failure() }
        var state = SessionLogState.initial
        var identities: Set<UUID> = []
        var line = Data(), frame = Data(), validOffset: Int64 = 0, count = 0
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        func acceptLine(_ bytes: Data) throws -> Bool {
            guard !bytes.isEmpty, frame.count <= SessionFormatLimits.maximumBatchBytes - bytes.count else { throw failure() }
            // Decode just the discriminator while buffering. Full type checking
            // happens at the commit boundary, so incomplete transactions never leak.
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            guard let type = object?["type"] as? String else { throw failure() }
            frame.append(bytes)
            if type == "mira/commit" {
                guard count < maximumRecords else { throw failure() }
                let decoded = try decodeFrame(frame, sessionID: sessionID, previous: state)
                guard identities.insert(decoded.batch.id).inserted else { throw failure() }
                try consume(decoded.batch, validOffset, frame, decoded.state)
                state = decoded.state; count += 1
                validOffset += Int64(frame.count + 1); frame.removeAll(keepingCapacity: true)
                return true
            }
            frame.append(10)
            return false
        }
        while true {
            let size = Darwin.read(fd, &chunk, chunk.count)
            if size < 0 && errno == EINTR { continue }
            guard size >= 0 else { throw failure() }
            if size == 0 { break }
            var start = 0
            for index in 0..<size where chunk[index] == 10 {
                guard line.count <= SessionFormatLimits.maximumBatchBytes - (index - start) else { throw failure() }
                line.append(contentsOf: chunk[start..<index])
                _ = try acceptLine(line)
                line.removeAll(keepingCapacity: true); start = index + 1
            }
            guard line.count <= SessionFormatLimits.maximumBatchBytes - (size - start) else { throw failure() }
            line.append(contentsOf: chunk[start..<size])
        }
        if !line.isEmpty || !frame.isEmpty {
            guard repair else { throw failure() }
            // A complete commit with only its delimiter missing is durable input.
            if !line.isEmpty,
               let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
               object["type"] as? String == "mira/commit" {
                guard try acceptLine(line) else { throw failure() }
                guard lseek(fd, 0, SEEK_END) >= 0 else { throw failure() }
                try write(Data([10]), fd: fd)
            } else {
                guard ftruncate(fd, off_t(validOffset)) == 0 else { throw failure() }
            }
            try sync(fd)
        }
        if !repair {
            var after = stat(), pathAfter = stat()
            guard fstat(fd, &after) == 0, lstat(url.path, &pathAfter) == 0,
                  validOffset == before.st_size, sameFile(before, after), sameFile(before, pathAfter) else { throw failure() }
        }
    }

    /// Reads one physical transaction and verifies its authenticated index digest.
    static func readRecord(_ url: URL, sessionID: ConversationID,
                           record: FileSessionIndex.Record, state: SessionLogState) throws -> SessionBatch {
        guard record.offset >= 0, (1...(SessionFormatLimits.maximumBatchBytes + 1)).contains(record.byteCount),
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
                guard count > 0 else { throw failure() }; total += count
            }
        }
        var after = stat(), pathAfter = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &pathAfter) == 0,
              sameFile(before, after), sameFile(before, pathAfter), bytes.last == 10 else { throw failure() }
        bytes.removeLast()
        guard digest(bytes) == record.digest else { throw failure() }
        let previous = try state.forBatch(nextSeq: record.firstSeq, nextInternalSequence: record.expectedSequence)
        let decoded = try decodeFrame(bytes, sessionID: sessionID, previous: previous)
        let batch = decoded.batch
        guard batch.id == record.id, batch.expectedSequence == record.expectedSequence,
              batch.cursor.sequence == record.sequence else { throw failure() }
        return batch
    }

    static func scanStrict(_ url: URL, sessionID: ConversationID, maximumRecords: Int) throws -> [SessionBatch] {
        guard maximumRecords > 0 else { throw failure() }
        var result: [SessionBatch] = []
        try scanFrames(url, sessionID: sessionID, repair: false, maximumRecords: maximumRecords) { batch, _, _, _ in
            result.append(batch)
        }
        return result
    }

    static func validateFile(_ url: URL, expectedCount: Int, expectedDigest: String) throws {
        guard (0...SessionFormatLimits.maximumContentBytes).contains(expectedCount) else { throw failure() }
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
