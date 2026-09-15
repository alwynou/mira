import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Library archive file catalog")
struct LibraryArchiveFileCatalogTests {
    @Test func writesAndReadsMultipleBoundedChunksInGlobalOrder() throws {
        try withDirectory { directory in
            let writer = try LibraryArchiveFileCatalog.Writer(directory: directory)
            var expected = [file("Business.sqlite", 7)]
            expected += (0..<1_024).map { file(String(format: "Sessions/s-%04d.jsonl", $0), $0 + 1) }
            expected += [file("Sessions/payload.bin", 9)]
            for value in expected.sorted(by: { $0.path < $1.path }) { try writer.append(value) }
            let chunks = try writer.finish()
            #expect(chunks.count == 2)
            let manifest = makeManifest(chunks)
            var actual: [LibraryArchiveManifest.File] = []
            try LibraryArchiveFileCatalog.forEachFile(in: directory, manifest: manifest) { actual.append($0) }
            #expect(actual == expected.sorted(by: { $0.path < $1.path }))
        }
    }

    @Test(arguments: ["mutated", "missing", "wrongPath", "extraPath"])
    func damagedCatalogIsRejected(_ damage: String) throws {
        try withDirectory { directory in
            let writer = try LibraryArchiveFileCatalog.Writer(directory: directory)
            try writer.append(file("Business.sqlite", 4))
            let chunks = try writer.finish()
            var manifest = makeManifest(chunks)
            let chunk = directory.appendingPathComponent(chunks[0].path)
            if damage == "missing" { try FileManager.default.removeItem(at: chunk) }
            else if damage == "wrongPath" {
                manifest = makeManifest([.init(path: "Catalog/000001.json", byteCount: chunks[0].byteCount,
                    digest: chunks[0].digest, fileCount: chunks[0].fileCount,
                    totalFileBytes: chunks[0].totalFileBytes, firstPath: chunks[0].firstPath,
                    lastPath: chunks[0].lastPath)])
            } else if damage == "extraPath" {
                let extra = directory.appendingPathComponent("Catalog/000001.json")
                try LibraryArchiveIO.write(Data("extra".utf8), to: extra)
            } else {
                var bytes = try Data(contentsOf: chunk); bytes[bytes.count - 1] ^= 1
                let inspected = try BackupFileIO.inspect(chunk, limit: LibraryArchiveLimits.maximumChunkBytes)
                try bytes.write(to: chunk)
                manifest = makeManifest([.init(path: chunks[0].path, byteCount: bytes.count,
                    digest: FileSessionIO.digest(bytes), fileCount: chunks[0].fileCount,
                    totalFileBytes: chunks[0].totalFileBytes, firstPath: chunks[0].firstPath,
                    lastPath: chunks[0].lastPath)])
                #expect(inspected.byteCount == chunks[0].byteCount)
            }
            #expect(throws: Error.self) {
                try LibraryArchiveFileCatalog.forEachFile(in: directory, manifest: manifest) { _ in }
            }
        }
    }

    @Test func duplicateAndOutOfOrderSourceRecordsAreRejected() throws {
        try withDirectory { directory in
            let duplicate = try LibraryArchiveFileCatalog.Writer(directory: directory)
            try duplicate.append(file("Business.sqlite", 1))
            #expect(throws: MiraError.self) { try duplicate.append(file("Business.sqlite", 1)) }

            let other = directory.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
            let order = try LibraryArchiveFileCatalog.Writer(directory: other)
            try order.append(file("z", 1))
            #expect(throws: MiraError.self) { try order.append(file("a", 1)) }
        }
    }

    @Test func businessFileIsRequiredExactlyOnce() throws {
        try withDirectory { directory in
            let writer = try LibraryArchiveFileCatalog.Writer(directory: directory)
            try writer.append(file("Sessions/only.jsonl", 1))
            #expect(throws: MiraError.self) { _ = try writer.finish() }
        }
    }

    @Test(arguments: ["tooManyRecords", "intMax", "negative"])
    func malformedChunkIsRejectedBeforeAnyCallback(_ kind: String) throws {
        try withDirectory { directory in
            let writer = try LibraryArchiveFileCatalog.Writer(directory: directory)
            try writer.append(file("Business.sqlite", 1))
            let chunks = try writer.finish()
            let chunk = directory.appendingPathComponent(chunks[0].path)
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: chunk)) as! [String: Any]
            var records = object["files"] as! [[String: Any]]
            if kind == "tooManyRecords" { records = Array(repeating: records[0], count: 1_025) }
            else {
                records[0]["byteCount"] = kind == "intMax" ? Int.max : -1
                records[0]["digest"] = String(repeating: "0", count: 64)
            }
            object["files"] = records
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try bytes.write(to: chunk)
            let updated = makeChunk(chunks[0], bytes: bytes,
                fileCount: 1,
                totalFileBytes: 1)
            let manifest = makeManifest([updated])
            var callbacks = 0
            #expect(throws: MiraError.self) {
                try LibraryArchiveFileCatalog.forEachFile(in: directory, manifest: manifest) { _ in callbacks += 1 }
            }
            #expect(callbacks == 0)
        }
    }

    @Test func oversizedChunkAndUnsupportedRootAreRejected() throws {
        try withDirectory { directory in
            let writer = try LibraryArchiveFileCatalog.Writer(directory: directory)
            try writer.append(file("Business.sqlite", 1))
            let chunks = try writer.finish()
            let url = directory.appendingPathComponent(chunks[0].path)
            let oversized = Data(repeating: 1, count: LibraryArchiveLimits.maximumChunkBytes + 1)
            try oversized.write(to: url)
            let claimed = makeChunk(chunks[0], bytes: oversized, fileCount: 1, totalFileBytes: 1,
                digest: chunks[0].digest)
            #expect(throws: MiraError.self) {
                try LibraryArchiveFileCatalog.forEachFile(in: directory, manifest: makeManifest([claimed])) { _ in }
            }
            #expect(throws: MiraError.self) {
                try LibraryArchiveFileCatalog.forEachFile(in: directory, manifest: makeManifest(chunks, version: 1)) { _ in }
            }
        }
    }

    @Test func writerRejectsMissingBusinessAndTotalByteBudgetOverflow() throws {
        try withDirectory { directory in
            let writer = try LibraryArchiveFileCatalog.Writer(directory: directory)
            try writer.append(file("Sessions/only.jsonl", 1))
            #expect(throws: MiraError.self) { _ = try writer.finish() }

            let second = directory.appendingPathComponent("second")
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
            let capped = try LibraryArchiveFileCatalog.Writer(directory: second)
            try capped.append(file("Business.sqlite", 1))
            for index in 0..<31 {
                try capped.append(LibraryArchiveManifest.File(path: String(format: "Sessions/huge-%02d.bin", index),
                    byteCount: LibraryArchiveLimits.maximumFileBytes, digest: String(repeating: "f", count: 64)))
            }
            #expect(throws: MiraError.self) {
                try capped.append(LibraryArchiveManifest.File(path: "Sessions/huge-31.bin", byteCount: LibraryArchiveLimits.maximumFileBytes,
                    digest: String(repeating: "e", count: 64)))
            }
        }
    }

    @Test func longestLegalPathsFitOneMaximumChunk() throws {
        try withDirectory { directory in
            let writer = try LibraryArchiveFileCatalog.Writer(directory: directory)
            try writer.append(file("Business.sqlite", 0))
            for index in 0..<1_023 {
                let path = maximumPath(index)
                #expect(path.utf8.count == 512)
                try writer.append(file(path, 0))
            }
            let chunks = try writer.finish()
            #expect(chunks.count == 1)
            #expect(chunks[0].fileCount == LibraryArchiveLimits.maximumChunkFiles)
            #expect(chunks[0].byteCount <= LibraryArchiveLimits.maximumChunkBytes)
        }
    }

    @Test func maximumManifestMetadataFitsTheBoundedRoot() throws {
        let chunks = makeChunks(count: LibraryArchiveLimits.maximumChunks)
        let sessions = (0..<FileSessionArchive.maximumSessions).map { _ in
            SessionJournalHead(cursor: .init(sessionID: ConversationID(), sequence: Int64.max), batchID: UUID())
        }
        let modules = (0..<128).map { SQLiteArchiveModule.Identity(name: String(format: "fixture.%03d", $0) + String(repeating: "x", count: 117), revision: Int.max) }
        let manifest = LibraryArchiveManifest(formatVersion: 2, authorization: .init(libraryID: UUID(), epoch: 1),
            modules: modules, sessions: sessions.sorted { $0.cursor.sessionID.rawValue.uuidString < $1.cursor.sessionID.rawValue.uuidString }, chunks: chunks)
        try manifest.validate()
        #expect(try SessionCodec.encode(manifest).count <= LibraryArchiveLimits.maximumManifestBytes)
    }

    @Test(arguments: ["modules", "sessions", "chunks"])
    func manifestCountLimitsRejectOverflows(_ kind: String) throws {
        var modules = (0..<128).map { SQLiteArchiveModule.Identity(name: String(format: "fixture.%03d", $0) + String(repeating: "x", count: 117), revision: Int.max) }
        var sessions = (0..<FileSessionArchive.maximumSessions).map { _ in
            SessionJournalHead(cursor: .init(sessionID: ConversationID(), sequence: Int64.max), batchID: UUID())
        }
        var chunks = makeChunks(count: LibraryArchiveLimits.maximumChunks)
        switch kind {
        case "modules": modules.append(.init(name: "fixture.999", revision: 1))
        case "sessions": sessions.append(.init(cursor: .init(sessionID: ConversationID(), sequence: Int64.max), batchID: UUID()))
        default: chunks.append(contentsOf: makeChunks(count: 1, offset: chunks.count))
        }
        let manifest = LibraryArchiveManifest(formatVersion: 2, authorization: .init(libraryID: UUID(), epoch: 1),
            modules: modules, sessions: sessions.sorted { $0.cursor.sessionID.rawValue.uuidString < $1.cursor.sessionID.rawValue.uuidString }, chunks: chunks)
        #expect(throws: MiraError.self) {
            let decoded = try SessionCodec.decode(LibraryArchiveManifest.self, from: SessionCodec.encode(manifest))
            try decoded.validate()
        }
    }

    @Test func overlappingChunkPathRangesAreRejected() throws {
        let chunks = [
            LibraryArchiveManifest.Chunk(path: LibraryArchiveFileCatalog.chunkPath(0), byteCount: 1,
                digest: String(repeating: "0", count: 64), fileCount: LibraryArchiveLimits.maximumChunkFiles, totalFileBytes: 1,
                firstPath: "Business.sqlite", lastPath: "Business.sqlite"),
            LibraryArchiveManifest.Chunk(path: LibraryArchiveFileCatalog.chunkPath(1), byteCount: 1,
                digest: String(repeating: "1", count: 64), fileCount: 1, totalFileBytes: 1,
                firstPath: "Business.sqlite", lastPath: "Business.sqlite")
        ]
        let manifest = LibraryArchiveManifest(formatVersion: 2, authorization: .init(libraryID: UUID(), epoch: 1),
            modules: [], sessions: [], chunks: chunks)
        #expect(throws: MiraError.self) { try manifest.validate() }
    }

    @Test func inventoryOrdersDirectoryPrefixesAndRejectsUndeclaredEmptyDirectories() throws {
        try withDirectory { directory in
            for path in ["Sessions/sessions", "Sessions/payloads"] {
                try FileManager.default.createDirectory(at: directory.appendingPathComponent(path),
                                                        withIntermediateDirectories: true)
            }
            let paths = ["A-", "A/a", "A0", "Business.sqlite", "Sessions/sessions/example.jsonl"]
            for path in paths {
                let url = try LibraryArchiveIO.file(path, under: directory, createParents: true)
                try LibraryArchiveIO.write(Data([7]), to: url)
            }
            var actual: [String] = []
            try LibraryArchiveIO.forEachFile(directory) { actual.append($0) }
            #expect(actual == paths.sorted())
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("Unused"),
                                                    withIntermediateDirectories: false)
            #expect(throws: MiraError.self) { try LibraryArchiveIO.forEachFile(directory) { _ in } }
        }
    }

    @Test func inventoryDoesNotMaterializeUnvisitedSubtrees() throws {
        try withDirectory { directory in
            try LibraryArchiveIO.write(Data([7]), to: directory.appendingPathComponent("A"))
            let later = directory.appendingPathComponent("Z")
            try FileManager.default.createDirectory(at: later, withIntermediateDirectories: false)
            try Data([7]).write(to: later.appendingPathComponent(".invalid"))
            let iterator = try LibraryArchiveIO.FileIterator(directory: directory)
            #expect(try iterator.next() == "A")
            #expect(throws: MiraError.self) { _ = try iterator.next() }
        }
    }

    private func file(_ path: String, _ count: Int) -> LibraryArchiveManifest.File {
        .init(path: path, byteCount: count, digest: FileSessionIO.digest(Data(repeating: 7, count: count)))
    }

    private func makeManifest(_ chunks: [LibraryArchiveManifest.Chunk]) -> LibraryArchiveManifest {
        makeManifest(chunks, version: 2)
    }

    private func makeManifest(_ chunks: [LibraryArchiveManifest.Chunk], version: Int) -> LibraryArchiveManifest {
        .init(formatVersion: version, authorization: .init(libraryID: UUID(), epoch: 1), modules: [], sessions: [], chunks: chunks)
    }

    private func makeChunk(_ original: LibraryArchiveManifest.Chunk, bytes: Data,
                           fileCount: Int, totalFileBytes: Int64, digest: String? = nil) -> LibraryArchiveManifest.Chunk {
        .init(path: original.path, byteCount: bytes.count, digest: digest ?? FileSessionIO.digest(bytes),
              fileCount: fileCount, totalFileBytes: totalFileBytes,
              firstPath: original.firstPath, lastPath: original.lastPath)
    }

    private func makeChunks(count: Int, offset: Int = 0) -> [LibraryArchiveManifest.Chunk] {
        (0..<count).map { index in
            let number = index + offset
            let path = maximumPath(number)
            return LibraryArchiveManifest.Chunk(path: LibraryArchiveFileCatalog.chunkPath(number), byteCount: LibraryArchiveLimits.maximumChunkBytes,
                digest: String(format: "%064d", number), fileCount: LibraryArchiveLimits.maximumChunkFiles, totalFileBytes: 1,
                firstPath: path, lastPath: path)
        }
    }

    private func maximumPath(_ index: Int) -> String {
        [String(repeating: "s", count: 128), String(repeating: "b", count: 128),
         String(repeating: "c", count: 128), String(format: "%06d", index) + String(repeating: "x", count: 119)]
            .joined(separator: "/")
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-file-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
