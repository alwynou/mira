import Foundation
import Darwin
import MiraCore

/// Authenticated, replaceable sidecars. Their loss never loses an acknowledged journal batch.
enum FileSessionCacheIO {
    static let maximumBytes = 64 * 1_024 * 1_024

    static func removeInterruptedWrites(in directory: URL) throws {
        try FileSessionIO.checkDirectory(directory)
        var removed = false
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix(".stage-") {
            guard UUID(uuidString: String(file.lastPathComponent.dropFirst(7))) != nil else { throw FileSessionIO.failure() }
            try FileSessionIO.unlinkIfPresent(file); removed = true
        }
        if removed { try FileSessionIO.syncDirectory(directory) }
    }

    static func load<T: Decodable>(_ type: T.Type, at url: URL, format: String,
                                   authentication: FileSessionCacheAuthentication) throws -> T? {
        guard let count = try size(url), count <= maximumBytes else { return nil }
        let prefix = Data((format + "\n").utf8)
        guard let bytes = try? FileSessionIO.readBounded(url, expectedCount: count),
              bytes.starts(with: prefix), bytes.count > prefix.count + 65,
              bytes[prefix.count + 64] == 10 else { return nil }
        let checksum = bytes.subdata(in: prefix.count..<(prefix.count + 64))
        let body = bytes.subdata(in: (prefix.count + 65)..<bytes.count)
        guard checksum == authentication.signature(body: body, format: format) else { return nil }
        return try? SessionCodec.decode(type, from: body)
    }

    @discardableResult
    static func save<T: Encodable>(_ value: T, at url: URL, format: String,
                                   authentication: FileSessionCacheAuthentication,
                                   beforeWrite: () throws -> Void, afterWrite: () throws -> Void,
                                   beforePublication: () throws -> Void, afterPublication: () throws -> Void) throws -> Bool {
        let prefix = Data((format + "\n").utf8)
        let body = try SessionCodec.encode(value)
        guard body.count <= maximumBytes - prefix.count - 65 else { return false }
        _ = try size(url)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".stage-\(UUID().uuidString)")
        try beforeWrite()
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileSessionIO.failure() }
        do {
            try FileSessionIO.write(prefix + authentication.signature(body: body, format: format) + Data([10]) + body, fd: fd)
            try afterWrite(); try FileSessionIO.sync(fd)
            Darwin.close(fd)
        } catch {
            Darwin.close(fd); try? FileSessionIO.unlinkIfPresent(temporary); throw error
        }
        do {
            try beforePublication()
            guard Darwin.rename(temporary.path, url.path) == 0 else { throw FileSessionIO.failure() }
            try afterPublication()
            try FileSessionIO.syncDirectory(url.deletingLastPathComponent())
            return true
        } catch { try? FileSessionIO.unlinkIfPresent(temporary); throw error }
    }

    private static func size(_ url: URL) throws -> Int? {
        var info = stat()
        if lstat(url.path, &info) < 0 {
            guard errno == ENOENT else { throw FileSessionIO.failure() }
            return nil
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= Int.max else { throw FileSessionIO.failure() }
        return Int(info.st_size)
    }
}
