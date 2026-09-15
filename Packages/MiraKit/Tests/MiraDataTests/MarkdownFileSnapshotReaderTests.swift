import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Selected Markdown snapshot", .timeLimit(.minutes(1)))
struct MarkdownFileSnapshotReaderTests {
    @Test func snapshotPreservesSelectedBytesWithoutRetainingOriginalPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-selected-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = MarkdownFileSnapshotReader(), file = directory.appendingPathComponent("selected.md")
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("# Local\r\nText\r\n".utf8)
        try bytes.write(to: file)
        do {
            let snapshot = try await reader.read(file)
            try FileManager.default.removeItem(at: file)
            #expect(snapshot.title == "selected.md" && snapshot.bytes == bytes)
            await reader.close()
            await #expect(throws: MiraError.self) { _ = try await reader.read(file) }
        } catch { await reader.close(); throw error }
    }
    @Test func rejectsExtensionAndSymbolicLink() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-selected-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = MarkdownFileSnapshotReader(), file = directory.appendingPathComponent("selected.txt")
        try Data("body".utf8).write(to: file)
        let link = directory.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        await #expect(throws: MiraError.self) { _ = try await reader.read(file) }
        await #expect(throws: MiraError.self) { _ = try await reader.read(link) }
        await reader.close()
    }
}
