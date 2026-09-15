import Foundation
import CryptoKit
import Darwin
import MiraCore

/// Writer-issued provenance for disposable caches. The key is local rebuildable
/// storage metadata, never a provider credential, and is excluded from archives.
/// This does not defend against a principal who can also read/replace this key.
struct FileSessionCacheAuthentication {
    private let key: SymmetricKey

    init(directory: URL) throws {
        let url = directory.appendingPathComponent(".cache-authentication")
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  info.st_uid == geteuid() else { throw FileSessionIO.failure() }
            if info.st_size == 32, info.st_mode & 0o7777 == 0o600 {
                key = SymmetricKey(data: try FileSessionIO.readBounded(url, expectedCount: 32))
                return
            }
            // An interrupted or overexposed key invalidates caches; the journal needs no key.
            try FileSessionIO.unlinkIfPresent(url)
        } else if errno != ENOENT { throw FileSessionIO.failure() }
        let generated = SymmetricKey(size: .bits256)
        let bytes = generated.withUnsafeBytes { Data($0) }
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileSessionIO.failure() }
        do {
            try FileSessionIO.write(bytes, fd: fd); try FileSessionIO.sync(fd)
            Darwin.close(fd)
        } catch { Darwin.close(fd); throw error }
        try FileSessionIO.syncDirectory(directory)
        key = generated
    }

    func signature(body: Data, format: String) -> Data {
        var authentication = HMAC<SHA256>(key: key)
        authentication.update(data: Data((format + "\n").utf8))
        authentication.update(data: body)
        return Data(DigestEncoding.hexadecimal(authentication.finalize()).utf8)
    }
}
