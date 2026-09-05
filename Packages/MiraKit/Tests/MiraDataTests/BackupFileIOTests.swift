import CryptoKit
import Darwin
import Foundation
import MiraCore
import Testing
@testable import MiraData

@Suite("Backup file I/O")
struct BackupFileIOTests {
    @Test func inspectAndCopyStreamMultipleBuffers() throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin")
        let destination = directory.appendingPathComponent("destination.bin")
        let bytes = Data((0..<200_000).map { UInt8($0 & 255) })
        try bytes.write(to: source)

        let inspected = try BackupFileIO.inspect(source, limit: bytes.count)
        let expectedDigest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(inspected == .init(digest: expectedDigest, byteCount: bytes.count))
        let copied = try BackupFileIO.copy(from: source, to: destination, limit: bytes.count)
        #expect(copied == inspected)
        #expect(try Data(contentsOf: destination) == bytes)

        let emptySource = directory.appendingPathComponent("empty-source.bin")
        let emptyDestination = directory.appendingPathComponent("empty-destination.bin")
        try Data().write(to: emptySource)
        _ = try BackupFileIO.copy(from: emptySource, to: emptyDestination, limit: 0)
        let attributes = try FileManager.default.attributesOfItem(atPath: emptyDestination.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func emptyExactAndOverLimitFiles() throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = directory.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        #expect(try BackupFileIO.inspect(empty, limit: 0).byteCount == 0)

        let exact = directory.appendingPathComponent("exact.bin")
        let bytes = Data(repeating: 7, count: 65_536)
        try bytes.write(to: exact)
        #expect(try BackupFileIO.inspect(exact, limit: bytes.count).byteCount == bytes.count)
        #expect(throws: MiraError.self) { try BackupFileIO.inspect(exact, limit: bytes.count - 1) }
    }

    @Test func symlinkAndFIFOAreRejectedWithoutBlocking() throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let regular = directory.appendingPathComponent("regular.bin")
        try Data("regular".utf8).write(to: regular)
        let symlink = directory.appendingPathComponent("symlink.bin")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: regular)
        #expect(throws: MiraError.self) { try BackupFileIO.inspect(symlink, limit: 100) }

        let fifo = directory.appendingPathComponent("fifo.bin")
        #expect(Darwin.mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: MiraError.self) { try BackupFileIO.inspect(fifo, limit: 100) }
    }

    @Test func existingDestinationIsNeverOverwritten() throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin")
        let destination = directory.appendingPathComponent("destination.bin")
        try Data("source".utf8).write(to: source)
        let original = Data("original".utf8)
        try original.write(to: destination)
        #expect(throws: MiraError.self) { try BackupFileIO.copy(from: source, to: destination, limit: 100) }
        #expect(try Data(contentsOf: destination) == original)
    }

    @Test func destinationReplacementIsDetectedAndReplacementIsPreserved() throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin")
        let destination = directory.appendingPathComponent("destination.bin")
        let replacement = directory.appendingPathComponent("replacement.bin")
        try Data(repeating: 3, count: 100_000).write(to: source)
        try Data("replacement".utf8).write(to: replacement)
        #expect(throws: MiraError.self) {
            try BackupFileIO.copy(from: source, to: destination, limit: 200_000, beforeFinalValidation: {
                try FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: replacement, to: destination)
            })
        }
        #expect(try Data(contentsOf: destination) == Data("replacement".utf8))
    }

    @Test func sourceReplacementIsDetectedAndIncompleteCopyIsRemoved() throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin")
        let replacement = directory.appendingPathComponent("replacement.bin")
        let destination = directory.appendingPathComponent("destination.bin")
        try Data("before".utf8).write(to: source)
        try Data("after".utf8).write(to: replacement)

        #expect(throws: MiraError.self) {
            try BackupFileIO.inspect(source, limit: 100, beforeFinalValidation: {
                try FileManager.default.removeItem(at: source)
                try FileManager.default.moveItem(at: replacement, to: source)
            })
        }

        try Data("before".utf8).write(to: source)
        try Data("after".utf8).write(to: replacement)
        #expect(throws: MiraError.self) {
            try BackupFileIO.copy(from: source, to: destination, limit: 100, beforeFinalValidation: {
                try FileManager.default.removeItem(at: source)
                try FileManager.default.moveItem(at: replacement, to: source)
            })
        }
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)

        let unchangedSource = directory.appendingPathComponent("unchanged-source.bin")
        let failedDestination = directory.appendingPathComponent("failed-destination.bin")
        try Data("unchanged".utf8).write(to: unchangedSource)
        #expect(throws: MiraError.self) {
            try BackupFileIO.copy(from: unchangedSource, to: failedDestination, limit: 100,
                                  beforeFinalValidation: { throw MiraError(.storage, "Synthetic copy failure.") })
        }
        #expect(FileManager.default.fileExists(atPath: failedDestination.path) == false)
        #expect(try Data(contentsOf: unchangedSource) == Data("unchanged".utf8))

        let limitedDestination = directory.appendingPathComponent("limited-destination.bin")
        #expect(throws: MiraError.self) { try BackupFileIO.copy(from: unchangedSource, to: limitedDestination, limit: 1) }
        #expect(FileManager.default.fileExists(atPath: limitedDestination.path) == false)
    }

    private func testDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-backup-io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }
}
