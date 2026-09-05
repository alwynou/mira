import CryptoKit
import Darwin
import Foundation
import MiraCore

/// Fault points are intentionally limited to filesystem publication boundaries.
enum ManagedBlobFaultStage: Sendable, Equatable {
    case afterTemporaryWrite
    case beforeInstall
    case beforeRemove
    case afterSelectedParentOpen
    case beforeSelectedOpen
}

/// A content-addressed store for user-selected Markdown attachments.
///
/// Directory descriptors are retained for the lifetime of the store.  The
/// class is unchecked Sendable because those descriptors are owned and closed
/// by this instance; every operation remains descriptor-relative.
final class ManagedBlobStore: @unchecked Sendable {
    private static let maximumBytes = 10 * 1024 * 1024
    private let libraryDirectory: URL
    private let libraryDirectoryDescriptor: Int32
    private let blobsDirectoryDescriptor: Int32
    private let faultInjector: (ManagedBlobFaultStage) throws -> Void
    private let maintenanceLock = NSLock()

    init(directory: URL, faultInjector: @escaping (ManagedBlobFaultStage) throws -> Void = { _ in }) throws {
        guard directory.isFileURL || directory.scheme == nil else {
            throw Self.error(.invalidInput, "The blob storage directory is invalid.")
        }
        let path = try Self.canonicalStoragePath(directory.standardizedFileURL.path)
        let library = try Self.openDirectoryTree(path, createMissing: true)
        do {
            let blobs = try Self.openChildDirectory(library, name: "Blobs", createMissing: true)
            self.libraryDirectory = URL(fileURLWithPath: path, isDirectory: true)
            self.libraryDirectoryDescriptor = library
            self.blobsDirectoryDescriptor = blobs
            self.faultInjector = faultInjector
        } catch {
            close(library)
            throw error
        }
    }

    deinit {
        close(blobsDirectoryDescriptor)
        close(libraryDirectoryDescriptor)
    }

    /// Serializes maintenance operations across store instances and processes.
    /// The lock file is kept in the library root and is not part of a backup.
    func withMaintenanceLock<T>(_ operation: () throws -> T) throws -> T {
        try validateAnchors()
        guard maintenanceLock.try() else {
            throw Self.error(.busy, "The library is busy.")
        }
        defer { maintenanceLock.unlock() }
        try validateAnchors()
        let descriptor = ".maintenance.lock".withCString {
            openat(libraryDirectoryDescriptor, $0, O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            throw Self.error(.storage, "The library maintenance lock could not be opened.")
        }
        defer { close(descriptor) }
        guard try Self.fstatIdentity(descriptor).isRegular else {
            throw Self.error(.storage, "The library maintenance lock is invalid.")
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw Self.error(.storage, "The library maintenance lock could not be secured.")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw Self.error(.busy, "The library is busy.")
            }
            throw Self.error(.storage, "The library maintenance lock could not be acquired.")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    static func readSelectedMarkdownFile(_ url: URL) throws -> Data {
        try readSelectedMarkdownFile(url, faultInjector: { _ in })
    }

    static func readSelectedMarkdownFile(
        _ url: URL,
        faultInjector: @escaping (ManagedBlobFaultStage) throws -> Void
    ) throws -> Data {
        guard url.isFileURL || url.scheme == nil,
              ["md", "markdown"].contains(url.pathExtension.lowercased()) else {
            throw error(.invalidInput, "Select a Markdown file.")
        }
        let path = try canonicalStoragePath(url.standardizedFileURL.path)
        let (parentPath, name) = try splitParent(path)
        let parent = try openDirectoryTree(parentPath, createMissing: false)
        defer { close(parent) }
        let parentIdentity = try fstatIdentity(parent)
        try faultInjector(.afterSelectedParentOpen)
        try faultInjector(.beforeSelectedOpen)
        let descriptor = try openExisting(parent, name: name)
        defer { close(descriptor) }
        let before = try fstatIdentity(descriptor)
        guard before.isRegular, before.size >= 0, before.size <= maximumBytes else {
            throw error(.invalidInput, "The selected Markdown file is invalid or too large.")
        }
        let data = try readDescriptor(descriptor, limit: maximumBytes)
        let afterDescriptor = try fstatIdentity(descriptor)
        guard afterDescriptor == before, Int64(data.count) == before.size else {
            throw error(.storage, "The selected Markdown file changed while it was read.")
        }

        // Re-traverse and reopen the selected entry. This detects replacement
        // of the parent directory while the picker-owned file was read.
        let reopenedParent = try openDirectoryTree(parentPath, createMissing: false)
        defer { close(reopenedParent) }
        let reopenedIdentity = try fstatIdentity(reopenedParent)
        guard reopenedIdentity == parentIdentity else {
            throw error(.storage, "The selected Markdown file changed while it was opened.")
        }
        let reopened = try openExisting(reopenedParent, name: name)
        defer { close(reopened) }
        guard try fstatIdentity(reopened) == before else {
            throw error(.storage, "The selected Markdown file changed while it was opened.")
        }
        return data
    }

    func install(_ data: Data) throws -> String {
        try validateAnchors()
        guard data.count <= Self.maximumBytes else {
            throw Self.error(.invalidInput, "The blob is too large.")
        }
        let digest = Self.digest(data)
        let first = String(digest.prefix(2))
        let second = String(digest.dropFirst(2).prefix(2))
        let firstDescriptor = try Self.openChildDirectory(blobsDirectoryDescriptor, name: first, createMissing: true)
        defer { close(firstDescriptor) }
        let secondDescriptor = try Self.openChildDirectory(firstDescriptor, name: second, createMissing: true)
        defer { close(secondDescriptor) }
        try validateShardAnchors(first: first, firstDescriptor: firstDescriptor, second: second, secondDescriptor: secondDescriptor)

        if let existing = try Self.openExistingIfPresent(secondDescriptor, name: digest) {
            defer { close(existing) }
            let existingData = try Self.readAndValidate(existing, expectedDigest: digest)
            guard existingData == data else {
                throw Self.error(.storage, "The existing blob does not match its digest.")
            }
            try validateAnchors()
            try validateShardAnchors(first: first, firstDescriptor: firstDescriptor, second: second, secondDescriptor: secondDescriptor)
            return digest
        }

        let temporaryName = ".tmp-\(UUID().uuidString.lowercased())"
        var descriptor: Int32 = -1
        do {
            descriptor = try Self.openExclusive(secondDescriptor, name: temporaryName)
            try Self.write(data, to: descriptor)
            guard fsync(descriptor) == 0 else {
                throw Self.error(.storage, "The blob could not be synchronized.")
            }
            close(descriptor)
            descriptor = -1
            try faultInjector(.afterTemporaryWrite)
            try faultInjector(.beforeInstall)
            try validateAnchors()
            try validateShardAnchors(first: first, firstDescriptor: firstDescriptor, second: second, secondDescriptor: secondDescriptor)
            let result = temporaryName.withCString { temp in
                digest.withCString { destination in
                    renameatx_np(secondDescriptor, temp, secondDescriptor, destination, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 {
                guard fsync(secondDescriptor) == 0 else {
                    throw Self.error(.storage, "The blob directory could not be synchronized.")
                }
            } else if errno == EEXIST {
                guard let existing = try Self.openExistingIfPresent(secondDescriptor, name: digest) else {
                    throw Self.error(.storage, "The existing blob could not be opened.")
                }
                defer { close(existing) }
                let existingData = try Self.readAndValidate(existing, expectedDigest: digest)
                guard existingData == data else {
                    throw Self.error(.storage, "The existing blob does not match its digest.")
                }
            } else {
                throw Self.error(.storage, "The blob could not be installed.")
            }
            try Self.removeTemporary(secondDescriptor, name: temporaryName)
            guard fsync(secondDescriptor) == 0 else {
                throw Self.error(.storage, "The blob directory could not be synchronized.")
            }
            try validateAnchors()
            try validateShardAnchors(first: first, firstDescriptor: firstDescriptor, second: second, secondDescriptor: secondDescriptor)
            return digest
        } catch {
            if descriptor >= 0 { close(descriptor) }
            do { try Self.removeTemporary(secondDescriptor, name: temporaryName) }
            catch { throw error is MiraError ? error : Self.error(.storage, "The temporary blob could not be removed.") }
            if error is MiraError { throw error }
            throw Self.error(.storage, "The blob could not be installed.")
        }
    }

    func read(_ digest: String) throws -> Data {
        try validateAnchors()
        guard Self.isDigest(digest) else { throw Self.error(.invalidInput, "The blob digest is invalid.") }
        let first = String(digest.prefix(2)); let second = String(digest.dropFirst(2).prefix(2))
        guard let firstDescriptor = try Self.openExistingIfPresent(blobsDirectoryDescriptor, name: first) else {
            throw Self.error(.notFound, "The blob does not exist.")
        }
        defer { close(firstDescriptor) }
        guard let shard = try Self.openExistingIfPresent(firstDescriptor, name: second) else {
            throw Self.error(.notFound, "The blob does not exist.")
        }
        defer { close(shard) }
        try validateShardAnchors(first: first, firstDescriptor: firstDescriptor, second: second, secondDescriptor: shard)
        let descriptor = try Self.openExisting(shard, name: digest)
        defer { close(descriptor) }
        let data = try Self.readAndValidate(descriptor, expectedDigest: digest)
        try validateAnchors()
        try validateShardAnchors(first: first, firstDescriptor: firstDescriptor, second: second, secondDescriptor: shard)
        return data
    }

    func remove(_ digest: String) throws {
        try validateAnchors()
        guard Self.isDigest(digest) else { throw Self.error(.invalidInput, "The blob digest is invalid.") }
        let first = String(digest.prefix(2)); let second = String(digest.dropFirst(2).prefix(2))
        guard let firstDescriptor = try Self.openExistingIfPresent(blobsDirectoryDescriptor, name: first) else { return }
        defer { close(firstDescriptor) }
        guard try Self.fstatIdentity(firstDescriptor).isDirectory else {
            throw Self.error(.storage, "The blob storage hierarchy is invalid.")
        }
        guard let shard = try Self.openExistingIfPresent(firstDescriptor, name: second) else { return }
        defer { close(shard) }
        guard try Self.fstatIdentity(shard).isDirectory else {
            throw Self.error(.storage, "The blob storage hierarchy is invalid.")
        }
        try validateShardAnchors(first: first, firstDescriptor: firstDescriptor, second: second, secondDescriptor: shard)
        guard let descriptor = try Self.openExistingIfPresent(shard, name: digest) else { return }
        defer { close(descriptor) }
        _ = try Self.readAndValidate(descriptor, expectedDigest: digest)
        try faultInjector(.beforeRemove)
        try validateAnchors()
        try validateShardAnchors(first: first, firstDescriptor: firstDescriptor, second: second, secondDescriptor: shard)
        let result = digest.withCString { unlinkat(shard, $0, 0) }
        guard result == 0 || errno == ENOENT else {
            throw Self.error(.storage, "The stored blob could not be removed.")
        }
        guard fsync(shard) == 0 else {
            throw Self.error(.storage, "The blob directory could not be synchronized.")
        }
    }

    func digests() throws -> [String] {
        try validateAnchors()
        var result: [String] = []
        for first in try Self.directoryEntries(blobsDirectoryDescriptor) where Self.isShard(first) {
            guard let firstDescriptor = try Self.openExistingIfPresent(blobsDirectoryDescriptor, name: first) else { continue }
            defer { close(firstDescriptor) }
            guard try Self.fstatIdentity(firstDescriptor).isDirectory else {
                throw Self.error(.storage, "The blob storage hierarchy is invalid.")
            }
            for second in try Self.directoryEntries(firstDescriptor) where Self.isShard(second) {
                guard let secondDescriptor = try Self.openExistingIfPresent(firstDescriptor, name: second) else { continue }
                defer { close(secondDescriptor) }
                guard try Self.fstatIdentity(secondDescriptor).isDirectory else {
                    throw Self.error(.storage, "The blob storage hierarchy is invalid.")
                }
                for entry in try Self.directoryEntries(secondDescriptor) {
                    guard Self.isDigest(entry), String(entry.prefix(2)) == first,
                          String(entry.dropFirst(2).prefix(2)) == second else { continue }
                    let descriptor = try Self.openExisting(secondDescriptor, name: entry)
                    defer { close(descriptor) }
                    guard try Self.fstatIdentity(descriptor).isRegular else {
                        throw Self.error(.storage, "The blob storage hierarchy contains an invalid entry.")
                    }
                    _ = try Self.readAndValidate(descriptor, expectedDigest: entry)
                    result.append(entry)
                }
            }
        }
        return result.sorted()
    }

    /// Removes stale publication temps. Callers must hold the maintenance lock.
    /// Only the store's exact lowercase UUID temp naming convention is eligible.
    func cleanTemporaryFiles() throws -> Int {
        try validateAnchors()
        var removed = 0
        for first in try Self.directoryEntries(blobsDirectoryDescriptor) where Self.isShard(first) {
            guard let firstDescriptor = try Self.openExistingIfPresent(blobsDirectoryDescriptor, name: first) else { continue }
            defer { close(firstDescriptor) }
            guard try Self.fstatIdentity(firstDescriptor).isDirectory else {
                throw Self.error(.storage, "The blob storage hierarchy is invalid.")
            }
            for second in try Self.directoryEntries(firstDescriptor) where Self.isShard(second) {
                guard let secondDescriptor = try Self.openExistingIfPresent(firstDescriptor, name: second) else { continue }
                defer { close(secondDescriptor) }
                guard try Self.fstatIdentity(secondDescriptor).isDirectory else {
                    throw Self.error(.storage, "The blob storage hierarchy is invalid.")
                }
                try validateShardAnchors(first: first, firstDescriptor: firstDescriptor, second: second, secondDescriptor: secondDescriptor)
                for entry in try Self.directoryEntries(secondDescriptor) where Self.isTemporaryName(entry) {
                    guard let descriptor = try Self.openExistingIfPresent(secondDescriptor, name: entry) else { continue }
                    defer { close(descriptor) }
                    let identity = try Self.fstatIdentity(descriptor)
                    guard identity.isRegular, identity.size >= 0, identity.size <= Self.maximumBytes else {
                        throw Self.error(.storage, "The temporary blob is invalid.")
                    }
                    let result = entry.withCString { unlinkat(secondDescriptor, $0, 0) }
                    guard result == 0 || errno == ENOENT else {
                        throw Self.error(.storage, "The temporary blob could not be removed.")
                    }
                    if result == 0 {
                        guard fsync(secondDescriptor) == 0 else {
                            throw Self.error(.storage, "The blob directory could not be synchronized.")
                        }
                        removed += 1
                    }
                }
                try validateShardAnchors(first: first, firstDescriptor: firstDescriptor, second: second, secondDescriptor: secondDescriptor)
            }
        }
        try validateAnchors()
        return removed
    }

    private func validateAnchors() throws {
        let reopenedLibrary = try Self.openDirectoryTree(libraryDirectory.path, createMissing: false)
        defer { close(reopenedLibrary) }
        guard Self.sameDirectoryIdentity(
            try Self.fstatIdentity(libraryDirectoryDescriptor),
            try Self.fstatIdentity(reopenedLibrary)
        ) else {
            throw Self.error(.storage, "The blob storage directory changed while it was in use.")
        }
        let reopenedBlobs = try Self.openChildDirectory(reopenedLibrary, name: "Blobs", createMissing: false)
        defer { close(reopenedBlobs) }
        guard Self.sameDirectoryIdentity(
            try Self.fstatIdentity(blobsDirectoryDescriptor),
            try Self.fstatIdentity(reopenedBlobs)
        ) else {
            throw Self.error(.storage, "The blob storage directory changed while it was in use.")
        }
    }

    private func validateShardAnchors(
        first: String,
        firstDescriptor: Int32,
        second: String,
        secondDescriptor: Int32
    ) throws {
        let currentFirst = try Self.openChildDirectory(blobsDirectoryDescriptor, name: first, createMissing: false)
        defer { close(currentFirst) }
        guard Self.sameDirectoryIdentity(try Self.fstatIdentity(firstDescriptor), try Self.fstatIdentity(currentFirst)) else {
            throw Self.error(.storage, "The blob storage hierarchy changed while it was in use.")
        }
        let currentSecond = try Self.openChildDirectory(currentFirst, name: second, createMissing: false)
        defer { close(currentSecond) }
        guard Self.sameDirectoryIdentity(try Self.fstatIdentity(secondDescriptor), try Self.fstatIdentity(currentSecond)) else {
            throw Self.error(.storage, "The blob storage hierarchy changed while it was in use.")
        }
    }

    private static func withShard<T>(_ blobs: Int32, digest: String, operation: (Int32) throws -> T) throws -> T {
        guard isDigest(digest) else { throw error(.invalidInput, "The blob digest is invalid.") }
        let first = String(digest.prefix(2)); let second = String(digest.dropFirst(2).prefix(2))
        guard let firstDescriptor = try openExistingIfPresent(blobs, name: first) else { throw error(.notFound, "The blob does not exist.") }
        defer { close(firstDescriptor) }
        guard let secondDescriptor = try openExistingIfPresent(firstDescriptor, name: second) else { throw error(.notFound, "The blob does not exist.") }
        defer { close(secondDescriptor) }
        guard try fstatIdentity(firstDescriptor).isDirectory, try fstatIdentity(secondDescriptor).isDirectory else {
            throw error(.storage, "The blob storage hierarchy is invalid.")
        }
        return try operation(secondDescriptor)
    }

    private static func readAndValidate(_ descriptor: Int32, expectedDigest: String) throws -> Data {
        let before = try fstatIdentity(descriptor)
        guard before.isRegular, before.size >= 0, before.size <= maximumBytes else {
            throw error(.storage, "The stored blob is invalid.")
        }
        let data = try readDescriptor(descriptor, limit: maximumBytes)
        let after = try fstatIdentity(descriptor)
        guard after == before, digest(data) == expectedDigest else {
            throw error(.storage, "The stored blob does not match its digest.")
        }
        return data
    }

    private static func sameDirectoryIdentity(_ lhs: FileIdentity, _ rhs: FileIdentity) -> Bool {
        lhs.isDirectory && rhs.isDirectory && lhs.device == rhs.device && lhs.inode == rhs.inode
    }

    private static func canonicalStoragePath(_ path: String) throws -> String {
        guard path.hasPrefix("/") else { throw error(.invalidInput, "The storage path is invalid.") }
        for (alias, target) in [("/tmp", "/private/tmp"), ("/var", "/private/var")] {
            if path == alias || path.hasPrefix(alias + "/") {
                if try verifyAlias(alias, target: target) {
                    return target + String(path.dropFirst(alias.count))
                }
                return path
            }
        }
        return path
    }

    private static func verifyAlias(_ alias: String, target: String) throws -> Bool {
        var info = stat()
        guard alias.withCString({ lstat($0, &info) }) == 0 else {
            throw error(.storage, "The storage path is unavailable.")
        }
        guard info.st_mode & UInt16(S_IFMT) == UInt16(S_IFLNK) else { return false }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let count = alias.withCString { aliasPointer in
            buffer.withUnsafeMutableBufferPointer { output in
                readlink(aliasPointer, output.baseAddress!, output.count - 1)
            }
        }
        guard count > 0 else { throw error(.storage, "The storage path is unavailable.") }
        buffer[Int(count)] = 0
        let link = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let relativeTarget = String(target.dropFirst())
        guard link == target || link == relativeTarget else {
            throw error(.invalidInput, "The storage path is outside the approved system directory.")
        }
        return true
    }

    private static func splitParent(_ path: String) throws -> (String, String) {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent().path
        guard !name.isEmpty, name != ".", name != "..", parent.hasPrefix("/") else {
            throw error(.invalidInput, "The selected Markdown file is invalid.")
        }
        return (parent, name)
    }

    private static func openDirectoryTree(_ path: String, createMissing: Bool) throws -> Int32 {
        let canonical = try canonicalStoragePath(path)
        var current = "/".withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard current >= 0 else { throw error(.storage, "The storage directory could not be opened.") }
        let components = canonical.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for component in components {
            let next = component.withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
            if next < 0, createMissing, errno == ENOENT {
                let made = component.withCString { mkdirat(current, $0, 0o700) }
                guard made == 0 || errno == EEXIST else {
                    close(current); throw error(.storage, "The storage directory could not be created.")
                }
                if made == 0, fsync(current) != 0 {
                    close(current); throw error(.storage, "The storage directory could not be synchronized.")
                }
                let reopened = component.withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
                guard reopened >= 0 else { close(current); throw error(.storage, "The storage directory could not be opened.") }
                close(current); current = reopened
            } else {
                guard next >= 0 else { close(current); throw error(errno == ENOENT ? .notFound : .storage, "The storage directory could not be opened.") }
                close(current); current = next
            }
        }
        return current
    }

    private static func openChildDirectory(_ parent: Int32, name: String, createMissing: Bool) throws -> Int32 {
        let descriptor = name.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        if descriptor >= 0 { return descriptor }
        guard createMissing, errno == ENOENT else {
            throw error(errno == ENOENT ? .notFound : .storage, "The blob storage directory could not be opened.")
        }
        let made = name.withCString { mkdirat(parent, $0, 0o700) }
        guard made == 0 || errno == EEXIST else { throw error(.storage, "The blob storage directory could not be created.") }
        guard fsync(parent) == 0 else { throw error(.storage, "The blob storage directory could not be synchronized.") }
        let reopened = name.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard reopened >= 0 else { throw error(.storage, "The blob storage directory could not be opened.") }
        return reopened
    }

    private static func openExisting(_ parent: Int32, name: String) throws -> Int32 {
        guard let descriptor = try openExistingIfPresent(parent, name: name) else {
            throw error(.notFound, "The blob does not exist.")
        }
        return descriptor
    }

    private static func openExistingIfPresent(_ parent: Int32, name: String) throws -> Int32? {
        let descriptor = name.withCString { openat(parent, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW) }
        if descriptor >= 0 { return descriptor }
        if errno == ENOENT { return nil }
        throw error(.storage, "The blob could not be opened.")
    }

    private static func openExclusive(_ parent: Int32, name: String) throws -> Int32 {
        let descriptor = name.withCString { openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw error(.storage, "The temporary blob could not be created.") }
        return descriptor
    }

    private static func removeTemporary(_ parent: Int32, name: String) throws {
        let result = name.withCString { unlinkat(parent, $0, 0) }
        guard result == 0 || errno == ENOENT else { throw error(.storage, "The temporary blob could not be removed.") }
    }

    private static func directoryEntries(_ directory: Int32) throws -> [String] {
        // `dup` shares the directory offset with the retained descriptor.
        // Open `.` again to give each enumeration an independent offset.
        let duplicate = ".".withCString { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw error(.storage, "The blob storage hierarchy could not be read.")
        }
        defer { closedir(stream) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        guard errno == 0 else { throw error(.storage, "The blob storage hierarchy could not be read.") }
        return names
    }

    private static func isShard(_ value: String) -> Bool {
        value.count == 2 && value.unicodeScalars.allSatisfy { ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102) }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102) }
    }

    private static func isTemporaryName(_ value: String) -> Bool {
        guard value.hasPrefix(".tmp-"), value.count == 41 else { return false }
        let suffix = String(value.dropFirst(5))
        guard suffix == suffix.lowercased(), UUID(uuidString: suffix) != nil else { return false }
        return true
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                guard written > 0 else { throw error(.storage, "The temporary blob could not be written.") }
                offset += written
            }
        }
    }

    private static func readDescriptor(_ descriptor: Int32, limit: Int) throws -> Data {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
            guard count >= 0 else { throw error(.storage, "The blob could not be read.") }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= limit else { throw error(.storage, "The stored blob is too large.") }
        }
        return data
    }

    private static func fstatIdentity(_ descriptor: Int32) throws -> FileIdentity {
        var info = stat(); guard fstat(descriptor, &info) == 0 else { throw error(.storage, "The blob could not be inspected.") }
        return FileIdentity(info)
    }

    private static func error(_ code: MiraError.Code, _ message: String) -> MiraError { MiraError(code, message) }

    private struct FileIdentity: Equatable {
        let device: UInt64; let inode: UInt64; let size: Int64; let mode: UInt16
        let modifiedSeconds: Int64; let modifiedNanoseconds: Int64; let changedSeconds: Int64; let changedNanoseconds: Int64
        init(_ info: stat) {
            device = UInt64(info.st_dev); inode = UInt64(info.st_ino); size = Int64(info.st_size); mode = UInt16(info.st_mode)
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec); changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }
        var isRegular: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }
        var isDirectory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    }
}
