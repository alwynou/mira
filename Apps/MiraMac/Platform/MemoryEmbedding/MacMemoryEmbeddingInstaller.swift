import Foundation
import CryptoKit
import MiraCore

/// Installs the pinned community model and owns its credential-free public download.
public enum MacMemoryEmbeddingInstaller {
    public static let repository = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"
    public static let revision = "6c3ae70858513f1a78e9cdca3cae330d9075cd2a"

    public static var resolveBaseURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/")!
    }

    public static func validate(directory: URL) throws {
        try ModelManifest.validate(directory: directory)
    }

    /// Copies a verified model into `destination` through a sibling temporary directory,
    /// then publishes it after the complete new tree passes all checks.
    public static func install(from source: URL, to destination: URL) async throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            try validate(directory: destination)
            return
        }
        try ModelManifest.validate(directory: source)
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".qwen3-embedding-\(UUID().uuidString).partial")
        defer { try? fm.removeItem(at: temporary) }
        for attempt in 0..<2 {
            do {
                try Task.checkCancellation()
                try fm.copyItem(at: source, to: temporary)
                try ModelManifest.validate(directory: temporary)
                try Task.checkCancellation()
                try publish(staging: temporary, destination: destination, fileManager: fm)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                try? fm.removeItem(at: temporary)
                if attempt == 1 { throw MiraError(.storage, "The local embedding model could not be installed.") }
            }
        }
    }

    /// Ensures the pinned model is present. Downloads are explicit, bounded and
    /// credential-free. The caller should invoke this only from prepare(), never from
    /// an interactive recall path.
    public static func ensureInstalled(at destination: URL, session: URLSession = .shared) async throws {
        if (try? validate(directory: destination)) != nil { return }
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".qwen3-embedding-\(UUID().uuidString).partial")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for entry in ModelManifest.entries {
            try Task.checkCancellation()
            let source = resolveBaseURL.appendingPathComponent(entry.name)
            let target = staging.appendingPathComponent(entry.name)
            var lastError: Error?
            for attempt in 0..<2 {
                do {
                    let request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData,
                                             timeoutInterval: 120)
                    let (temporary, response) = try await session.download(for: request)
                    defer { try? fm.removeItem(at: temporary) }
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw MiraError(.network, "The embedding model download was rejected.")
                    }
                    try Task.checkCancellation()
                    try ModelManifest.validate(entry: entry, file: temporary)
                    try fm.moveItem(at: temporary, to: target)
                    lastError = nil
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw CancellationError()
                } catch {
                    lastError = error
                    try? fm.removeItem(at: target)
                    if attempt == 1 { break }
                }
            }
            if lastError != nil {
                throw MiraError(.network, "The local embedding model could not be downloaded.")
            }
        }
        try validate(directory: staging)
        try Task.checkCancellation()
        try publish(staging: staging, destination: destination, fileManager: fm)
    }

    private static func publish(staging: URL, destination: URL, fileManager fm: FileManager) throws {
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.replaceItemAt(destination, withItemAt: staging, backupItemName: nil,
                                     options: .usingNewMetadataOnly)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
        } catch {
            throw MiraError(.storage, "The local embedding model could not be published.")
        }
    }
}

struct ModelManifest {
    struct Entry {
        let name: String
        let bytes: Int
        let hash: String
        let algorithm: String
    }

    static let entries: [Entry] = [
        Entry(name: "README.md", bytes: 970, hash: "c2f9e3162273a2020338c05c2b86487105b04b4c", algorithm: "git-blob-sha1"),
        Entry(name: "config.json", bytes: 937, hash: "1c1d64f33a74b3c2c480c5221d5384391695708b", algorithm: "git-blob-sha1"),
        Entry(name: "merges.txt", bytes: 1_671_853, hash: "31349551d90c7606f325fe0f11bbb8bd5fa0d7c7", algorithm: "git-blob-sha1"),
        Entry(name: "model.safetensors", bytes: 335_296_756, hash: "3d773d5ee582eda445daeee23f7a2b76124011796df244ddb45e22638fdb7cde", algorithm: "sha256"),
        Entry(name: "special_tokens_map.json", bytes: 613, hash: "ac23c0aaa2434523c494330aeb79c58395378103", algorithm: "git-blob-sha1"),
        Entry(name: "tokenizer.json", bytes: 11_423_705, hash: "def76fb086971c7867b829c23a26261e38d9d74e02139253b38aeb9df8b4b50a", algorithm: "sha256"),
        Entry(name: "tokenizer_config.json", bytes: 5_404, hash: "ddaf69808214a44fdd26d3785b66c1367c78277a", algorithm: "git-blob-sha1"),
        Entry(name: "vocab.json", bytes: 2_776_833, hash: "4783fe10ac3adce15ac8f358ef5462739852c569", algorithm: "git-blob-sha1")
    ]

    static func validate(directory: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { throw MiraError(.notFound, "The local embedding model is not installed.") }
        for entry in entries {
            let url = directory.appendingPathComponent(entry.name)
            try validate(entry: entry, file: url)
        }
    }

    static func validate(entry: Entry, file: URL) throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, values.fileSize == entry.bytes else {
            throw MiraError(.configuration, "The local embedding model has an invalid file set.")
        }
        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
        let digest: String
        if entry.algorithm == "sha256" {
            digest = SHA256.hash(data: data).hexString
        } else {
            var prefixed = Data("blob \(data.count)\0".utf8)
            prefixed.append(data)
            digest = Insecure.SHA1.hash(data: prefixed).hexString
        }
        guard digest == entry.hash else {
            throw MiraError(.configuration, "The local embedding model failed integrity validation.")
        }
    }
}

private extension Sequence where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
