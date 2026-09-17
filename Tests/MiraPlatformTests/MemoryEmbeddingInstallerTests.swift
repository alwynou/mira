import Foundation
import Testing

@Suite("Local memory embedding installer")
struct MemoryEmbeddingInstallerTests {
    @Test func partialDirectoryIsRejectedBeforeModelLoad() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mira-embedding-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: Error.self) {
            try MacMemoryEmbeddingInstaller.validate(directory: directory)
        }
    }

    @Test func tamperedArtifactIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mira-embedding-tampered-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Keep the expected byte count so this exercises digest validation rather
        // than only the missing/size guard.
        try Data(repeating: 0, count: 970).write(to: directory.appendingPathComponent("README.md"))

        #expect(throws: Error.self) {
            try ModelManifest.validate(entry: ModelManifest.entries[0], file: directory.appendingPathComponent("README.md"))
        }
    }

    @Test func pinnedResolveURLContainsRevisionAndNoCredentialQuery() {
        let url = MacMemoryEmbeddingInstaller.resolveBaseURL
        #expect(url.absoluteString.contains(MacMemoryEmbeddingInstaller.revision))
        #expect(url.host == "huggingface.co")
        #expect(url.query == nil)
    }

    @Test("verified offline directory replacement", .enabled(if: ProcessInfo.processInfo.environment["MIRA_TEST_EMBEDDING_MODEL_DIRECTORY"] != nil))
    func verifiedOfflineDirectoryReplacement() async throws {
        guard let rawPath = ProcessInfo.processInfo.environment["MIRA_TEST_EMBEDDING_MODEL_DIRECTORY"],
              !rawPath.isEmpty else { return }
        let source = URL(fileURLWithPath: rawPath, isDirectory: true)
        try MacMemoryEmbeddingInstaller.validate(directory: source)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("mira-embedding-replacement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: destination.appendingPathComponent("stale.marker"))

        // This exercises replacing an existing directory with the verified staging tree.
        try await MacMemoryEmbeddingInstaller.install(from: source, to: destination)
        try MacMemoryEmbeddingInstaller.validate(directory: destination)
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("stale.marker").path))
    }
}
