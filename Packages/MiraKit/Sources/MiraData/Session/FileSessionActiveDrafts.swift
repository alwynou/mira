import Foundation
import Darwin
import MiraCore

/// Authenticated, replaceable active-draft snapshots. The library owns serialization and
/// validates the referenced committed request before calling these primitives.
struct FileSessionActiveDrafts {
    private let directory: URL
    private let authentication: FileSessionCacheAuthentication
    private let fault: SessionStorageFaultInjector

    private struct Stored: Codable {
        let version: Int
        let draft: SessionActiveDraft
        init(_ draft: SessionActiveDraft) { version = 1; self.draft = draft }
    }

    init(directory: URL, authentication: FileSessionCacheAuthentication,
         fault: @escaping SessionStorageFaultInjector) throws {
        self.directory = directory; self.authentication = authentication; self.fault = fault
        try FileSessionIO.ensureDirectory(directory)
        try removeInterruptedWrites()
        try validateInventory()
    }

    func load(sessionID: ConversationID) throws -> SessionActiveDraft? {
        let url = fileURL(sessionID)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            guard errno == ENOENT else { throw FileSessionIO.failure() }
            return nil
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= Int64(SessionActiveDraft.maximumBytes + 512) else {
            throw FileSessionIO.failure()
        }
        let bytes = try FileSessionIO.readBounded(url, expectedCount: Int(info.st_size))
        let format = "MIRA-ACTIVE-DRAFT-1"
        let prefix = Data((format + "\n").utf8)
        guard bytes.starts(with: prefix), bytes.count > prefix.count + 65,
              bytes[prefix.count + 64] == 10 else { throw FileSessionIO.failure() }
        let checksum = bytes.subdata(in: prefix.count..<(prefix.count + 64))
        let body = bytes.subdata(in: (prefix.count + 65)..<bytes.count)
        guard checksum == authentication.signature(body: body, format: format) else { throw FileSessionIO.failure() }
        let stored = try SessionCodec.decode(Stored.self, from: body)
        guard stored.version == 1, stored.draft.request.sessionID == sessionID else { throw FileSessionIO.failure() }
        try stored.draft.validate()
        return stored.draft
    }

    func save(_ draft: SessionActiveDraft) throws {
        let format = "MIRA-ACTIVE-DRAFT-1"
        let body = try SessionCodec.encode(Stored(draft))
        let prefix = Data((format + "\n").utf8)
        let bytes = prefix + authentication.signature(body: body, format: format) + Data([10]) + body
        guard bytes.count <= SessionActiveDraft.maximumBytes + 512 else { throw MiraError(.outputLimit, "The active session draft exceeds its supported bounds.") }
        let destination = fileURL(draft.request.sessionID)
        let temporary = directory.appendingPathComponent(".stage-\(UUID().uuidString)")
        try fault(.beforeActiveDraftWrite)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileSessionIO.failure() }
        do {
            try FileSessionIO.write(bytes, fd: fd)
            try fault(.afterActiveDraftWrite); try fault(.beforeActiveDraftSync)
            try FileSessionIO.sync(fd); try fault(.afterActiveDraftSync)
            Darwin.close(fd)
        } catch { Darwin.close(fd); try? FileSessionIO.unlinkIfPresent(temporary); throw error }
        do {
            try fault(.beforeActiveDraftPublication)
            guard Darwin.rename(temporary.path, destination.path) == 0 else { throw FileSessionIO.failure() }
            try fault(.afterActiveDraftPublication)
            try fault(.beforeDirectorySync); try FileSessionIO.syncDirectory(directory); try fault(.afterDirectorySync)
        } catch { try? FileSessionIO.unlinkIfPresent(temporary); throw error }
    }

    func remove(sessionID: ConversationID, attemptID: UUID) throws {
        guard let draft = try load(sessionID: sessionID), draft.attemptID == attemptID else { return }
        let url = fileURL(sessionID)
        try fault(.beforeActiveDraftDelete); try FileSessionIO.unlinkIfPresent(url); try fault(.afterActiveDraftDelete)
        try fault(.beforeDirectorySync); try FileSessionIO.syncDirectory(directory); try fault(.afterDirectorySync)
    }

    func synchronize(sessionID: ConversationID) throws {
        let url = fileURL(sessionID)
        _ = try load(sessionID: sessionID)
        try FileSessionIO.syncFile(url)
        try fault(.beforeDirectorySync); try FileSessionIO.syncDirectory(directory); try fault(.afterDirectorySync)
    }

    func remove(sessionID: ConversationID) throws {
        let url = fileURL(sessionID)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { guard errno == ENOENT else { throw FileSessionIO.failure() }; return }
        try fault(.beforeActiveDraftDelete); try FileSessionIO.unlinkIfPresent(url); try fault(.afterActiveDraftDelete)
        try fault(.beforeDirectorySync); try FileSessionIO.syncDirectory(directory); try fault(.afterDirectorySync)
    }

    func removeAll() throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard url.pathExtension == "json", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else {
                if url.lastPathComponent.hasPrefix(".stage-") { try FileSessionIO.unlinkIfPresent(url); continue }
                throw FileSessionIO.failure()
            }
            try FileSessionIO.unlinkIfPresent(url)
        }
        try fault(.beforeDirectorySync); try FileSessionIO.syncDirectory(directory); try fault(.afterDirectorySync)
    }

    func removeInterruptedWrites() throws {
        var removed = false
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix(".stage-") {
            guard UUID(uuidString: String(url.lastPathComponent.dropFirst(7))) != nil else { throw FileSessionIO.failure() }
            try FileSessionIO.unlinkIfPresent(url); removed = true
        }
        if removed { try FileSessionIO.syncDirectory(directory) }
    }

    private func validateInventory() throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard url.pathExtension == "json",
                  let uuid = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  uuid.uuidString == url.deletingPathExtension().lastPathComponent else { throw FileSessionIO.failure() }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                throw FileSessionIO.failure()
            }
        }
    }

    private func fileURL(_ sessionID: ConversationID) -> URL {
        directory.appendingPathComponent(sessionID.rawValue.uuidString + ".json")
    }
}
