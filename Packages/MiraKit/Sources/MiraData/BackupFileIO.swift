import CryptoKit
import Darwin
import Foundation
import MiraCore

/// Descriptor-bound, bounded file I/O for backup bundles.
enum BackupFileIO {
    struct Snapshot: Equatable, Sendable {
        let digest: String
        let byteCount: Int
    }

    static func inspect(_ url: URL, limit: Int, beforeFinalValidation: (() throws -> Void)? = nil) throws -> Snapshot {
        try stream(url, limit: limit, beforeFinalValidation: beforeFinalValidation) { _ in }
    }

    static func read(_ url: URL, limit: Int) throws -> Data {
        var data = Data()
        _ = try stream(url, limit: limit) { bytes in
            data.append(bytes.bindMemory(to: UInt8.self))
        }
        return data
    }

    static func copy(from source: URL, to destination: URL, limit: Int,
                     beforeFinalValidation: (() throws -> Void)? = nil) throws -> Snapshot {
        let destinationPath = destination.standardizedFileURL.path
        let destinationDescriptor = destinationPath.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard destinationDescriptor >= 0 else {
            throw MiraError(.storage, "The backup file could not be written.")
        }
        var createdIdentity = stat()
        guard fstat(destinationDescriptor, &createdIdentity) == 0 else {
            close(destinationDescriptor)
            throw MiraError(.storage, "The backup file could not be written.")
        }
        guard createdIdentity.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG) else {
            close(destinationDescriptor)
            removeCreatedDestinationIfUnchanged(destinationPath, identity: createdIdentity)
            throw MiraError(.storage, "The backup file could not be written.")
        }
        var descriptor = destinationDescriptor
        do {
            let snapshot = try stream(source, limit: limit, beforeFinalValidation: beforeFinalValidation) { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw MiraError(.storage, "The backup file could not be written.") }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0 else {
                throw MiraError(.storage, "The backup file could not be written.")
            }
            var after = stat()
            var pathAfter = stat()
            guard fstat(descriptor, &after) == 0,
                  destinationPath.withCString({ lstat($0, &pathAfter) }) == 0,
                  after.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
                  pathAfter.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
                  after.st_dev == createdIdentity.st_dev,
                  after.st_ino == createdIdentity.st_ino,
                  pathAfter.st_dev == createdIdentity.st_dev,
                  pathAfter.st_ino == createdIdentity.st_ino,
                  sameIdentity(after, pathAfter),
                  after.st_size == off_t(snapshot.byteCount) else {
                throw MiraError(.storage, "The backup file changed while it was read.")
            }
            close(descriptor)
            descriptor = -1
            return snapshot
        } catch {
            close(descriptor)
            descriptor = -1
            removeCreatedDestinationIfUnchanged(destinationPath, identity: createdIdentity)
            throw error
        }
    }

    private static func stream(
        _ url: URL,
        limit: Int,
        beforeFinalValidation: (() throws -> Void)? = nil,
        consume: (UnsafeRawBufferPointer) throws -> Void
    ) throws -> Snapshot {
        let path = url.standardizedFileURL.path
        let descriptor = path.withCString { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else {
            throw MiraError(.storage, "The backup file is invalid or too large.")
        }
        defer { close(descriptor) }

        var before = stat()
        guard limit >= 0,
              fstat(descriptor, &before) == 0,
              before.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
              before.st_size >= 0,
              before.st_size <= off_t(limit),
              before.st_size <= off_t(Int.max) else {
            throw MiraError(.storage, "The backup file is invalid or too large.")
        }
        let expected = Int(before.st_size)
        var count = 0
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while count < expected {
            let requested = min(buffer.count, expected - count)
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress!, requested)
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount > 0 else {
                throw MiraError(.storage, "The backup file could not be read.")
            }
            try buffer.withUnsafeBytes { bytes in
                let chunk = UnsafeRawBufferPointer(start: bytes.baseAddress, count: readCount)
                hasher.update(data: Data(bytes: chunk.baseAddress!, count: chunk.count))
                try consume(chunk)
            }
            count += readCount
        }

        try beforeFinalValidation?()
        var after = stat()
        var pathAfter = stat()
        guard fstat(descriptor, &after) == 0,
              path.withCString({ lstat($0, &pathAfter) }) == 0,
              sameIdentity(before, after),
              pathAfter.st_dev == before.st_dev, pathAfter.st_ino == before.st_ino,
              pathAfter.st_size == before.st_size,
              pathAfter.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              pathAfter.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              pathAfter.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              pathAfter.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
            throw MiraError(.storage, "The backup file changed while it was read.")
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Snapshot(digest: digest, byteCount: count)
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino &&
        lhs.st_size == rhs.st_size &&
        lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
        lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
        lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
        lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func removeCreatedDestinationIfUnchanged(_ path: String, identity: stat) {
        var current = stat()
        guard path.withCString({ lstat($0, &current) }) == 0,
              current.st_dev == identity.st_dev,
              current.st_ino == identity.st_ino else { return }
        _ = path.withCString { unlink($0) }
    }
}
