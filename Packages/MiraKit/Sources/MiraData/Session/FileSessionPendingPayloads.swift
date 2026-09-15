import Darwin
import Foundation
import MiraCore

/// Durable work identities for unpublished payloads. Only the library's I/O queue may use this object.
/// A mark is synced before creating body files and removed only after their directory is synced.
final class FileSessionPendingPayloads {
    struct Address: Hashable {
        let sessionID: ConversationID
        let batchID: UUID
        var name: String { sessionID.rawValue.uuidString + "." + batchID.uuidString }
    }

    private let directory: URL
    private let fault: SessionStorageFaultInjector
    private var known: Set<Address> = []

    init(directory: URL, fault: @escaping SessionStorageFaultInjector) {
        self.directory = directory
        self.fault = fault
    }

    func isInitialized() throws -> Bool {
        try FileSessionIO.checkDirectory(directory, allowMissing: true)
        var info = stat()
        if lstat(directory.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw FileSessionIO.failure() }
        return false
    }

    /// Called only after an exhaustive orphan sweep when this recoverable inventory is absent.
    func initialize() throws { try FileSessionIO.ensureDirectory(directory) }

    func addresses() throws -> [Address] {
        try FileSessionIO.checkDirectory(directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let result = try files.map { file -> Address in
            let parts = file.lastPathComponent.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, let session = UUID(uuidString: String(parts[0])),
                  let batch = UUID(uuidString: String(parts[1])) else { throw FileSessionIO.failure() }
            let address = Address(sessionID: .init(session), batchID: batch)
            guard address.name == file.lastPathComponent else { throw FileSessionIO.failure() }
            _ = try FileSessionIO.readBounded(file, expectedCount: 0)
            return address
        }
        known = Set(result)
        return result.sorted { $0.name < $1.name }
    }

    func contains(_ address: Address) -> Bool { known.contains(address) }

    func begin(_ address: Address) throws {
        try FileSessionIO.checkDirectory(directory)
        try fault(.beforePendingPayloadMark)
        let file = url(address)
        let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd >= 0 {
            defer { Darwin.close(fd) }
            try FileSessionIO.requireRegular(fd)
            try FileSessionIO.sync(fd)
        } else {
            guard errno == EEXIST else { throw FileSessionIO.failure() }
            _ = try FileSessionIO.readBounded(file, expectedCount: 0)
            try FileSessionIO.syncFile(file)
        }
        try FileSessionIO.syncDirectory(directory)
        known.insert(address)
        try fault(.afterPendingPayloadMark)
    }

    func clear(_ address: Address) throws {
        try FileSessionIO.checkDirectory(directory)
        try fault(.beforePendingPayloadClear)
        try FileSessionIO.unlinkIfPresent(url(address))
        try fault(.afterPendingPayloadClear)
        // A previous attempt may have unlinked the mark without completing this barrier.
        try FileSessionIO.syncDirectory(directory)
        known.remove(address)
    }

    private func url(_ address: Address) -> URL { directory.appendingPathComponent(address.name) }
}
