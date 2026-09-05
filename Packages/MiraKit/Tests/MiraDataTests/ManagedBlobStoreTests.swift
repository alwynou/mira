import CryptoKit
import Darwin
import Foundation
import MiraCore
import Testing
@testable import MiraData

@Suite("Managed blob store")
struct ManagedBlobStoreTests {
    @Test func installsReadsAndReusesContentAddressedBlob() throws {
        let directory = try testDirectory(); defer { remove(directory) }
        let store = try ManagedBlobStore(directory: directory)
        let data = Data("# Notes\n\nHello Mira\n".utf8)
        let digest = try store.install(data)
        #expect(digest == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        #expect(try store.read(digest) == data)
        #expect(try store.install(data) == digest)
        #expect(try store.digests() == [digest])
        #expect(try store.digests() == [digest])

        let first = String(digest.prefix(2))
        let second = String(digest.dropFirst(2).prefix(2))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Blobs/\(first)/\(second)/\(digest)").path))
    }

    @Test func corruptExistingBlobIsRejectedAndOriginalBytesRemainObservable() throws {
        let directory = try testDirectory(); defer { remove(directory) }
        let store = try ManagedBlobStore(directory: directory)
        let data = Data("stable bytes".utf8)
        let digest = try store.install(data)
        let path = blobPath(digest, in: directory)
        try Data("corrupted".utf8).write(to: path)
        #expect(throws: MiraError.self) { try store.install(data) }
        #expect(throws: MiraError.self) { try store.read(digest) }
    }

    @Test func removeIsExactAndMissingRemovalIsIdempotent() throws {
        let directory = try testDirectory(); defer { remove(directory) }
        let store = try ManagedBlobStore(directory: directory)
        let digest = try store.install(Data("remove me".utf8))
        try store.remove(digest)
        #expect(try store.digests().isEmpty)
        try store.remove(digest)
        #expect(throws: MiraError.self) { try store.remove("../\(digest)") }
    }

    @Test func rejectsInvalidDigestAndOwnedHierarchySymlinks() throws {
        let directory = try testDirectory(); defer { remove(directory) }
        let store = try ManagedBlobStore(directory: directory)
        #expect(throws: MiraError.self) { try store.read("../../etc/passwd") }
        #expect(throws: MiraError.self) { try store.remove(String(repeating: "A", count: 64)) }

        let shard = directory.appendingPathComponent("Blobs/aa")
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
        let escaped = directory.appendingPathComponent("escaped")
        try FileManager.default.createDirectory(at: escaped, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: shard.appendingPathComponent("bb"), withDestinationURL: escaped)
        let digest = "aa" + "bb" + String(repeating: "0", count: 60)
        #expect(throws: MiraError.self) { try store.read(digest) }
    }

    @Test func selectedMarkdownReadAcceptsMarkdownAndRejectsUnsafeSelections() throws {
        let directory = try testDirectory(); defer { remove(directory) }
        let markdown = directory.appendingPathComponent("readme.MARKDOWN")
        let data = Data("# Selected\n".utf8)
        try data.write(to: markdown)
        #expect(try ManagedBlobStore.readSelectedMarkdownFile(markdown) == data)

        let unsupported = directory.appendingPathComponent("notes.txt")
        try data.write(to: unsupported)
        #expect(throws: MiraError.self) { try ManagedBlobStore.readSelectedMarkdownFile(unsupported) }

        let symlink = directory.appendingPathComponent("selected.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: markdown)
        #expect(throws: MiraError.self) { try ManagedBlobStore.readSelectedMarkdownFile(symlink) }

        let parent = directory.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: directory)
        let escaped = parent.appendingPathComponent("escaped.md")
        #expect(throws: MiraError.self) { try ManagedBlobStore.readSelectedMarkdownFile(escaped) }

        let folder = directory.appendingPathComponent("folder.md", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(throws: MiraError.self) { try ManagedBlobStore.readSelectedMarkdownFile(folder) }
    }

    @Test func selectedMarkdownReadRejectsFilesOverLimit() throws {
        let directory = try testDirectory(); defer { remove(directory) }
        let file = directory.appendingPathComponent("large.md")
        try Data(repeating: 0x61, count: 10 * 1024 * 1024 + 1).write(to: file)
        #expect(throws: MiraError.self) { try ManagedBlobStore.readSelectedMarkdownFile(file) }
    }

    @Test func selectedReadFaultPointsRunAfterParentOpenAndBeforeFileOpen() throws {
        let directory = try testDirectory(); defer { remove(directory) }
        let file = directory.appendingPathComponent("fault.md")
        try Data("# fault points\n".utf8).write(to: file)
        #expect(throws: MiraError.self) {
            try ManagedBlobStore.readSelectedMarkdownFile(file) { stage in
                if stage == .afterSelectedParentOpen { throw MiraError(.storage, "synthetic filesystem failure") }
            }
        }
        #expect(throws: MiraError.self) {
            try ManagedBlobStore.readSelectedMarkdownFile(file) { stage in
                if stage == .beforeSelectedOpen { throw MiraError(.storage, "synthetic filesystem failure") }
            }
        }
    }

    @Test func failedInstallOrRemoveLeavesExistingBlobsUntouched() throws {
        let directory = try testDirectory(); defer { remove(directory) }
        let data = Data("fault boundary".utf8)
        let afterWrite = try ManagedBlobStore(directory: directory) { stage in
            if stage == .afterTemporaryWrite { throw MiraError(.storage, "synthetic filesystem failure") }
        }
        #expect(throws: MiraError.self) { try afterWrite.install(data) }
        #expect(try afterWrite.digests().isEmpty)

        let beforeInstall = try ManagedBlobStore(directory: directory) { stage in
            if stage == .beforeInstall { throw MiraError(.storage, "synthetic filesystem failure") }
        }
        #expect(throws: MiraError.self) { try beforeInstall.install(data) }
        #expect(try beforeInstall.digests().isEmpty)

        let normal = try ManagedBlobStore(directory: directory)
        let digest = try normal.install(data)
        let beforeRemove = try ManagedBlobStore(directory: directory) { stage in
            if stage == .beforeRemove { throw MiraError(.storage, "synthetic filesystem failure") }
        }
        #expect(throws: MiraError.self) { try beforeRemove.remove(digest) }
        #expect(try beforeRemove.read(digest) == data)
    }

    @Test func removalValidatesContentAndSurfacesFilesystemErrors() throws {
        let directory = try testDirectory(); defer { remove(directory) }
        let store = try ManagedBlobStore(directory: directory)
        let data = Data("remove integrity".utf8)
        let digest = try store.install(data)
        let path = blobPath(digest, in: directory)
        try Data("changed bytes".utf8).write(to: path)
        #expect(throws: MiraError.self) { try store.remove(digest) }
        #expect(FileManager.default.fileExists(atPath: path.path))

        let malformedShard = directory.appendingPathComponent("Blobs/cc/dd")
        try FileManager.default.createDirectory(at: malformedShard.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: malformedShard)
        // A malformed hierarchy is surfaced instead of being treated as a missing entry.
        #expect(throws: MiraError.self) { try store.digests() }
    }

    @Test func fifoReplacementIsRejectedWithoutBlocking() throws {
        let directory = try testDirectory(); defer { remove(directory) }
        let store = try ManagedBlobStore(directory: directory)
        let digest = String(repeating: "a", count: 64)
        let shard = directory.appendingPathComponent("Blobs/aa/aa")
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
        let fifo = shard.appendingPathComponent(digest)
        #expect(Darwin.mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: MiraError.self) { try store.read(digest) }
    }

    @Test func shardSymlinkAndDanglingLinkCannotEscapeBlobRoot() throws {
        let directory = try testDirectory(); defer { remove(directory) }
        let outside = try testDirectory(); defer { remove(outside) }
        let outsideFile = outside.appendingPathComponent("must-remain.txt")
        try Data("outside".utf8).write(to: outsideFile)
        let store = try ManagedBlobStore(directory: directory)
        let first = directory.appendingPathComponent("Blobs/aa")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let digest = "aa" + "bb" + String(repeating: "0", count: 60)
        try FileManager.default.createSymbolicLink(at: first.appendingPathComponent("bb"), withDestinationURL: outside)
        #expect(throws: MiraError.self) { try store.read(digest) }
        #expect(try Data(contentsOf: outsideFile) == Data("outside".utf8))

        try FileManager.default.removeItem(at: first.appendingPathComponent("bb"))
        let missing = outside.appendingPathComponent("missing")
        try FileManager.default.createSymbolicLink(at: first.appendingPathComponent("bb"), withDestinationURL: missing)
        #expect(throws: MiraError.self) { try store.read(digest) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func canonicalTemporaryAliasIsAccepted() throws {
        let directory = URL(fileURLWithPath: "/tmp/mira-managed-alias-(UUID().uuidString)", isDirectory: true)
        defer { remove(directory) }
        let store = try ManagedBlobStore(directory: directory)
        let data = Data("canonical alias".utf8)
        let digest = try store.install(data)
        #expect(try store.read(digest) == data)
    }

    @Test func maintenanceLockCoordinatesStoreInstances() throws {
        let directory = try testDirectory(); defer { remove(directory) }
        let first = try ManagedBlobStore(directory: directory)
        let second = try ManagedBlobStore(directory: directory)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try first.withMaintenanceLock {
                    entered.signal()
                    release.wait()
                }
            } catch {
                Issue.record("The first maintenance lock unexpectedly failed: \(error)")
            }
            finished.signal()
        }
        #expect(entered.wait(timeout: .now() + 2) == .success)
        #expect(throws: MiraError.self) { try second.withMaintenanceLock {} }
        release.signal()
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(try second.withMaintenanceLock { true })
    }

    @Test func installRejectsShardReplacementBeforePublication() throws {
        let directory = try testDirectory(); defer { remove(directory) }
        let outside = try testDirectory(); defer { remove(outside) }
        let marker = outside.appendingPathComponent("must-remain.txt")
        try Data("outside".utf8).write(to: marker)
        let data = Data("shard replacement".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let shard = directory.appendingPathComponent("Blobs/\(digest.prefix(2))/\(digest.dropFirst(2).prefix(2))")
        let retained = directory.appendingPathComponent("retained-shard")
        let store = try ManagedBlobStore(directory: directory) { stage in
            guard stage == .beforeInstall else { return }
            try FileManager.default.moveItem(at: shard, to: retained)
            try FileManager.default.createSymbolicLink(at: shard, withDestinationURL: outside)
        }
        #expect(throws: MiraError.self) { try store.install(data) }
        #expect(try Data(contentsOf: marker) == Data("outside".utf8))
        #expect(!FileManager.default.fileExists(atPath: blobPath(digest, in: directory).path))
    }

    @Test func readRejectsManagedRootReplacement() throws {
        let directory = try testDirectory()
        let saved = directory.deletingLastPathComponent().appendingPathComponent("\(directory.lastPathComponent)-saved")
        defer {
            remove(directory)
            remove(saved)
        }
        let outside = try testDirectory(); defer { remove(outside) }
        let marker = outside.appendingPathComponent("must-remain.txt")
        try Data("outside".utf8).write(to: marker)
        let store = try ManagedBlobStore(directory: directory)
        let data = Data("root replacement".utf8)
        let digest = try store.install(data)
        try FileManager.default.moveItem(at: directory, to: saved)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        #expect(throws: MiraError.self) { try store.read(digest) }
        #expect(try Data(contentsOf: marker) == Data("outside".utf8))
    }

    @Test func maintenanceCleanupRemovesOnlyValidStaleTemporaryFiles() throws {
        let directory = try testDirectory(); defer { remove(directory) }
        let outside = try testDirectory(); defer { remove(outside) }
        let marker = outside.appendingPathComponent("must-remain.txt")
        try Data("outside".utf8).write(to: marker)
        let store = try ManagedBlobStore(directory: directory)
        let data = Data("retained canonical bytes".utf8)
        let digest = try store.install(data)
        let shard = directory.appendingPathComponent("Blobs/\(digest.prefix(2))/\(digest.dropFirst(2).prefix(2))")
        let stale = shard.appendingPathComponent(".tmp-12345678-1234-1234-1234-123456789abc")
        try Data("stale".utf8).write(to: stale, options: .atomic)
        let unrelated = shard.appendingPathComponent("keep-me")
        try Data("unrelated".utf8).write(to: unrelated)

        let reopened = try ManagedBlobStore(directory: directory)
        #expect(try reopened.withMaintenanceLock { try reopened.cleanTemporaryFiles() } == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(try Data(contentsOf: unrelated) == Data("unrelated".utf8))
        #expect(try reopened.read(digest) == data)
        #expect(try reopened.digests() == [digest])
        #expect(try reopened.digests() == [digest])

        let symlinkTemp = shard.appendingPathComponent(".tmp-abcdefab-cdef-abcd-efab-cdefabcdefab")
        try FileManager.default.createSymbolicLink(at: symlinkTemp, withDestinationURL: outside)
        #expect(throws: MiraError.self) {
            try reopened.withMaintenanceLock { try reopened.cleanTemporaryFiles() }
        }
        #expect(try Data(contentsOf: marker) == Data("outside".utf8))
    }

    private func blobPath(_ digest: String, in directory: URL) -> URL {
        directory.appendingPathComponent("Blobs/\(digest.prefix(2))/\(digest.dropFirst(2).prefix(2))/\(digest)")
    }

    private func testDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-blobs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
