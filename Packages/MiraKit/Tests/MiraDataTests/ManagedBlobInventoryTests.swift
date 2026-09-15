import Foundation
import MiraCore
import Testing

@testable import MiraData

@Suite("Managed blob inventory")
struct ManagedBlobInventoryTests {
    @Test func inventoryReadsMetadataWithoutReadingBody() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ManagedBlobStore(directory: directory)
        let data = Data("inventory body".utf8)
        let digest = try store.install(data)
        let path = directory.appendingPathComponent(
            "Blobs/\(digest.prefix(2))/\(digest.dropFirst(2).prefix(2))/\(digest)")
        try Data(repeating: 0x41, count: data.count).write(to: path)
        let inventory = try store.withMaintenanceLock { try store.inventory() }
        #expect(inventory.blobs[digest] == data.count)
        #expect(inventory.temporaryCount == 0)
    }

    @Test func verifyAbsentRequiresActualAbsence() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ManagedBlobStore(directory: directory)
        let digest = try store.install(Data("present".utf8))
        #expect(throws: MiraError.self) { try store.verifyAbsent(digest) }
        try store.remove(digest)
        try store.verifyAbsent(digest)
        _ = try store.install(Data("present".utf8))
        #expect(throws: MiraError.self) { try store.verifyAbsent(digest) }
        try store.remove(digest)
        let path = directory.appendingPathComponent(
            "Blobs/\(digest.prefix(2))/\(digest.dropFirst(2).prefix(2))/\(digest)")
        try FileManager.default.createSymbolicLink(
            at: path, withDestinationURL: directory.appendingPathComponent("missing"))
        #expect(throws: MiraError.self) { try store.verifyAbsent(digest) }
    }

    @Test func inventoryCountsTemporaryFilesAndRejectsUnknownEntries() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ManagedBlobStore(directory: directory)
        let digest = try store.install(Data("temporary".utf8))
        let shard = directory.appendingPathComponent("Blobs/\(digest.prefix(2))/\(digest.dropFirst(2).prefix(2))")
        let temporary = shard.appendingPathComponent(".tmp-\(UUID().uuidString.lowercased())")
        try Data("pending".utf8).write(to: temporary)
        let inventory = try store.withMaintenanceLock { try store.inventory() }
        #expect(inventory.temporaryCount == 1)
        try Data("unknown".utf8).write(to: shard.appendingPathComponent("unexpected"))
        #expect(throws: MiraError.self) { try store.inventory() }
    }

    @Test func inventoryRejectsMisplacedDigestSymlinkAndEntryBounds() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ManagedBlobStore(directory: directory)
        let digest = try store.install(Data("strict".utf8))
        let first = directory.appendingPathComponent("Blobs/\(digest.prefix(2))")
        try Data("misplaced".utf8).write(to: first.appendingPathComponent("misplaced"))
        #expect(throws: MiraError.self) { try store.inventory() }

        let other = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: other) }
        let secondStore = try ManagedBlobStore(directory: other)
        let secondDigest = try secondStore.install(Data("symlink".utf8))
        let secondShard = other.appendingPathComponent(
            "Blobs/\(secondDigest.prefix(2))/\(secondDigest.dropFirst(2).prefix(2))")
        try FileManager.default.removeItem(at: secondShard.appendingPathComponent(secondDigest))
        try FileManager.default.createSymbolicLink(
            at: secondShard.appendingPathComponent(secondDigest),
            withDestinationURL: URL(fileURLWithPath: "/tmp/no-such-blob"))
        #expect(throws: MiraError.self) { try secondStore.inventory() }

    }

    @Test func inventoryBoundCountsDirectoriesAndFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ManagedBlobStore(directory: directory)
        let digest = try store.install(Data("bounded".utf8))
        #expect(throws: MiraError.self) { try store.inventory(maximumEntries: 2) }
        #expect(try store.inventory(maximumEntries: 3).blobs == [digest: 7])
        #expect(try store.inventory(maximumEntries: 3).blobs == [digest: 7])
    }

    private func makeDirectory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mira-managed-blobs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
}
