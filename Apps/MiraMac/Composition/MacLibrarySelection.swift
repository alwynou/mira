import Darwin
import Foundation
import MiraCore

struct MacSelectedLibrary: Codable, Sendable, Equatable {
    let directory: URL
    let libraryID: UUID
}

enum MacLibrarySelectionState: Codable, Sendable, Equatable {
    case active(MacSelectedLibrary)
    case switching(from: MacSelectedLibrary, to: MacSelectedLibrary)
}

/// Crash-safe, single-owner selection state for the host's current library.
actor MacLibrarySelectionStore {
    private static let version = 1
    private static let maximumBytes = 64 * 1024

    private struct Envelope: Codable {
        let version: Int
        let state: MacLibrarySelectionState
    }

    private let fileURL: URL
    private var lockFD: Int32
    private var closed = false

    init(fileURL: URL) throws {
        guard fileURL.isFileURL, fileURL.path.hasPrefix("/"), !fileURL.path.isEmpty else {
            throw Self.storageError
        }
        let normalized = fileURL.standardizedFileURL
        let directory = normalized.deletingLastPathComponent()
        try Self.ensureDirectory(directory)
        self.fileURL = normalized
        self.lockFD = try Self.openLock(normalized.appendingPathExtension("lock"))
    }

    deinit {
        if lockFD >= 0 {
            _ = flock(lockFD, LOCK_UN)
            Darwin.close(lockFD)
        }
    }

    func state() throws -> MacLibrarySelectionState? {
        try checkOpen()
        return try load()
    }

    @discardableResult
    func begin(
        from: MacSelectedLibrary, to: MacSelectedLibrary
    ) throws -> MacLibrarySelectionState {
        try checkOpen()
        try Self.validate(from)
        try Self.validate(to)
        let current = try load()
        switch current {
        case nil:
            break
        case .active(let selected):
            guard selected == from else { throw Self.conflictError }
        case .switching:
            throw Self.busyError
        }
        let next = MacLibrarySelectionState.switching(from: from, to: to)
        try store(next)
        return next
    }

    func complete(
        expected: MacLibrarySelectionState, state: MacLibrarySelectionState
    ) throws {
        try checkOpen()
        guard case .switching(let from, let to) = expected,
            case .active(let selected) = state,
            selected == to,
            try load() == expected
        else { throw Self.conflictError }
        try Self.validate(from)
        try Self.validate(to)
        try store(state)
    }

    func close() {
        guard !closed else { return }
        closed = true
        _ = flock(lockFD, LOCK_UN)
        Darwin.close(lockFD)
        lockFD = -1
    }

    private func checkOpen() throws {
        guard !closed else { throw Self.closedError }
    }

    private func load() throws -> MacLibrarySelectionState? {
        guard let data = try Self.readFileIfPresent(fileURL) else { return nil }
        guard data.count <= Self.maximumBytes else { throw Self.storageError }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = object as? [String: Any],
                Set(dictionary.keys) == Set(["version", "state"])
            else { throw Self.storageError }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope))
            guard envelope.version == Self.version,
                let canonical = encoded as? [String: Any],
                NSDictionary(dictionary: dictionary).isEqual(to: canonical)
            else { throw Self.storageError }
            try Self.validate(envelope.state)
            return envelope.state
        } catch let error as MiraError {
            throw error
        } catch {
            throw Self.storageError
        }
    }

    private func store(_ state: MacLibrarySelectionState) throws {
        try Self.validate(state)
        let data: Data
        do {
            data = try JSONEncoder().encode(Envelope(version: Self.version, state: state))
        } catch {
            throw Self.storageError
        }
        guard data.count <= Self.maximumBytes else { throw Self.storageError }
        try Self.writeAtomically(data, to: fileURL)
    }

    private static func validate(_ state: MacLibrarySelectionState) throws {
        switch state {
        case .active(let selected): try validate(selected)
        case .switching(let from, let to):
            try validate(from)
            try validate(to)
        }
    }

    private static func validate(_ selected: MacSelectedLibrary) throws {
        let directory = selected.directory
        guard directory.isFileURL, directory.path.hasPrefix("/"),
            directory.path != "/", directory.path.utf8.count <= 4_096,
            directory.path == directory.standardizedFileURL.path,
            directory.host == nil || directory.host == "",
            directory.query == nil, directory.fragment == nil,
            directory.user == nil, directory.password == nil
        else { throw storageError }
    }

    private static func ensureDirectory(_ directory: URL) throws {
        guard directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path else {
            throw storageError
        }
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw storageError }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            guard lstat(directory.path, &info) == 0 else { throw storageError }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_nlink >= 2 else { throw storageError }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private static func openLock(_ url: URL) throws -> Int32 {
        let fd = url.path.withCString {
            open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else { throw busyOrStorageError() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            Darwin.close(fd)
            throw storageError
        }
        _ = fchmod(fd, 0o600)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw busyError
        }
        return fd
    }

    private static func readFileIfPresent(_ url: URL) throws -> Data? {
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            guard errno == ENOENT else { throw storageError }
            return nil
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_nlink == 1, info.st_size >= 0,
            info.st_size <= off_t(maximumBytes), info.st_mode & 0o777 == 0o600
        else { throw storageError }
        let count = Int(info.st_size)
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let readCount = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                if readCount < 0, errno == EINTR { continue }
                guard readCount > 0 else { throw storageError }
                offset += readCount
            }
        }
        var trailing: UInt8 = 0
        guard Darwin.read(fd, &trailing, 1) == 0 else { throw storageError }
        return data
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if try fileExists(url) {
            try validateRegular(url, mode: 0o600)
        }
        let next = url.appendingPathExtension("next")
        if try fileExists(next) {
            try validateRegular(next, mode: 0o600)
            guard unlink(next.path) == 0 else { throw storageError }
        }
        let fd = next.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { throw storageError }
        var closed = false
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < data.count {
                    let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw storageError }
                    offset += written
                }
            }
            guard fsync(fd) == 0 else { throw storageError }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                throw storageError
            }
            Darwin.close(fd)
            closed = true
            guard rename(next.path, url.path) == 0 else { throw storageError }
            let directoryFD = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard directoryFD >= 0 else { throw storageError }
            defer { Darwin.close(directoryFD) }
            guard fsync(directoryFD) == 0 else { throw storageError }
        } catch {
            if !closed { Darwin.close(fd) }
            _ = unlink(next.path)
            throw error is MiraError ? error : storageError
        }
    }

    private static func fileExists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw storageError }
        return false
    }

    private static func validateRegular(_ url: URL, mode: mode_t) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_nlink == 1, info.st_mode & 0o777 == mode
        else { throw storageError }
    }

    private static func busyOrStorageError() -> MiraError {
        errno == EWOULDBLOCK || errno == EAGAIN ? busyError : storageError
    }

    private static let storageError = MiraError(.storage, "The library selection state is invalid or unavailable.")
    private static let busyError = MiraError(.busy, "The library selection state is owned by another process.")
    private static let conflictError = MiraError(.conflict, "The library selection state changed. Retry the switch.")
    private static let closedError = MiraError(.busy, "The library selection store is closed.")
}
