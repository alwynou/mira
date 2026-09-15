import CryptoKit
import Darwin
import Foundation
import MiraCore

/// A bounded, crash-safe ledger for credentials that became unreachable from
/// the current library configuration. The caller owns the library writer lock.
struct CredentialCleanup: Sendable {
    struct Item: Codable, Hashable, Sendable {
        let reference: String
        let version: Int
    }

    private struct Ledger: Codable {
        let version: Int
        let libraryID: UUID
        let namespace: String
        var items: [Item]
    }

    private static let ledgerVersion = 1
    private static let maximumItems = 1_024
    private static let maximumBytes = 1_048_576
    private static let prefix = "mira.credential."

    let directory: URL
    let libraryID: UUID
    private let namespace: String

    init(directory: URL, libraryID: UUID) {
        self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
        self.libraryID = libraryID
        self.namespace = Self.namespace(directory: directory, libraryID: libraryID)
    }

    func makeReference(version: Int) -> AgentCredentialReference {
        AgentCredentialReference(
            reference: "\(Self.prefix)\(namespace).\(UUID().uuidString.lowercased())", version: version)
    }

    func enqueue(_ refs: [AgentCredentialReference]) throws {
        var ledger = try load()
        let additions = refs.compactMap { ref -> Item? in
            guard owns(ref), ref.version > 0 else { return nil }
            return Item(reference: ref.reference, version: ref.version)
        }
        ledger.items = Array(Set(ledger.items + additions)).sorted {
            ($0.reference, $0.version) < ($1.reference, $1.version)
        }
        try validate(ledger)
        try store(ledger.items)
    }

    /// Returns true when failed deletions remain in the durable ledger.
    @discardableResult
    func reconcile(retaining refs: [AgentCredentialReference], credentials: any MacCredentialStore) throws -> Bool {
        var ledger = try load()
        let retained = Set(refs.filter(owns).map { Item(reference: $0.reference, version: $0.version) })
        var remaining: [Item] = []
        for item in ledger.items where !retained.contains(item) {
            do { try credentials.delete(reference: item.reference, version: item.version) } catch {
                remaining.append(item)
            }
        }
        ledger.items = remaining
        try store(remaining)
        return !remaining.isEmpty
    }

    private var ledgerURL: URL { directory.appendingPathComponent("credential-cleanup.json", isDirectory: false) }
    private var nextURL: URL { directory.appendingPathComponent("credential-cleanup.json.next", isDirectory: false) }

    private static func namespace(directory: URL, libraryID: UUID) -> String {
        let input =
            "\(directory.resolvingSymlinksInPath().standardizedFileURL.path)\n\(libraryID.uuidString.lowercased())"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func owns(_ ref: AgentCredentialReference) -> Bool {
        let marker = "\(Self.prefix)\(namespace)."
        guard ref.reference.hasPrefix(marker), ref.reference.utf8.count <= 512, ref.version > 0 else { return false }
        let suffix = String(ref.reference.dropFirst(marker.count))
        return UUID(uuidString: suffix) != nil && suffix == suffix.lowercased()
    }

    private func load() throws -> Ledger {
        try ensureDirectory()
        try recoverNext()
        guard let data = try readFileIfPresent(ledgerURL) else {
            return Ledger(version: Self.ledgerVersion, libraryID: libraryID, namespace: namespace, items: [])
        }
        guard data.count <= Self.maximumBytes else { throw Self.storageError }
        do {
            let ledger = try JSONDecoder().decode(Ledger.self, from: data)
            try validate(ledger)
            return ledger
        } catch let error as MiraError { throw error } catch { throw Self.storageError }
    }

    private func validate(_ ledger: Ledger) throws {
        guard ledger.version == Self.ledgerVersion,
            ledger.libraryID == libraryID, ledger.namespace == namespace,
            ledger.items.count <= Self.maximumItems,
            Set(ledger.items).count == ledger.items.count
        else { throw Self.storageError }
        for item in ledger.items {
            guard owns(.init(reference: item.reference, version: item.version)) else { throw Self.storageError }
        }
        let bytes = try JSONEncoder().encode(ledger)
        guard bytes.count <= Self.maximumBytes else { throw Self.storageError }
    }

    private func store(_ items: [Item]) throws {
        guard items.count <= Self.maximumItems else { throw Self.storageError }
        if items.isEmpty {
            guard try fileExists(ledgerURL) else { return }
            try unlinkRegular(ledgerURL)
            try syncDirectory()
            return
        }
        let ledger = Ledger(version: Self.ledgerVersion, libraryID: libraryID, namespace: namespace, items: items)
        try validate(ledger)
        let data = try JSONEncoder().encode(ledger)
        try writeAtomically(data)
    }

    private func writeAtomically(_ data: Data) throws {
        try ensureDirectory()
        try removeNextIfPresent()
        let fd = nextURL.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { throw Self.storageError }
        var closed = false
        do {
            try writeAll(data, to: fd)
            guard fsync(fd) == 0 else { throw Self.storageError }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                throw Self.storageError
            }
            close(fd)
            closed = true
            let result = nextURL.path.withCString { source in
                ledgerURL.path.withCString { destination in rename(source, destination) }
            }
            guard result == 0 else { throw Self.storageError }
            try syncDirectory()
        } catch {
            if !closed { close(fd) }
            try? unlinkRegular(nextURL)
            throw error is MiraError ? error : Self.storageError
        }
    }

    private func readFileIfPresent(_ url: URL) throws -> Data? {
        let fd = url.path.withCString { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
        if fd < 0 {
            guard errno == ENOENT else { throw Self.storageError }
            return nil
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
            info.st_size >= 0, info.st_size <= off_t(Self.maximumBytes)
        else { throw Self.storageError }
        let byteCount = Int(info.st_size)
        var data = Data(count: byteCount)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < byteCount {
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), byteCount - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.storageError }
                offset += count
            }
        }
        var trailing: UInt8 = 0
        guard Darwin.read(fd, &trailing, 1) == 0 else { throw Self.storageError }
        return data
    }

    private func recoverNext() throws {
        guard try fileExists(nextURL) else { return }
        try validateRegular(nextURL)
        try unlinkRegular(nextURL)
        try syncDirectory()
    }

    private func ensureDirectory() throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Self.storageError }
        let fd = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw Self.storageError }
        close(fd)
    }

    private func syncDirectory() throws {
        let fd = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw Self.storageError }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw Self.storageError }
    }

    private func validateRegular(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw Self.storageError
        }
    }

    private func unlinkRegular(_ url: URL) throws {
        try validateRegular(url)
        guard unlink(url.path) == 0 || errno == ENOENT else { throw Self.storageError }
    }

    private func removeNextIfPresent() throws {
        guard try fileExists(nextURL) else { return }
        try validateRegular(nextURL)
        try unlinkRegular(nextURL)
        try syncDirectory()
    }

    private func fileExists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw Self.storageError }
        return false
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.storageError }
                offset += count
            }
        }
    }

    private static let storageError = MiraError(.storage, "Unable to read or persist credential cleanup state.")
}
