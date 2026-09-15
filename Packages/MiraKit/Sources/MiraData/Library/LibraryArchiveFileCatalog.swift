import Foundation
import MiraCore

/// Streams the file portion of an archive manifest in bounded, verified
/// chunks.  The archive root owns the catalog directory; this helper never
/// includes its own chunk files in the catalog records.
final class LibraryArchiveFileCatalog {
    private struct ChunkBody: Codable {
        let files: [LibraryArchiveManifest.File]
        init(files: [LibraryArchiveManifest.File]) { self.files = files }
        private enum CodingKeys: CodingKey { case files }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            var container = try values.nestedUnkeyedContainer(forKey: .files)
            if let count = container.count, count > LibraryArchiveLimits.maximumChunkFiles {
                throw LibraryArchiveIO.invalid
            }
            var result: [LibraryArchiveManifest.File] = []
            while !container.isAtEnd {
                guard result.count < LibraryArchiveLimits.maximumChunkFiles else { throw LibraryArchiveIO.invalid }
                result.append(try container.decode(LibraryArchiveManifest.File.self))
            }
            files = result
        }
    }

    static let catalogDirectory = "Catalog"

    static func chunkPath(_ index: Int) -> String {
        "\(catalogDirectory)/\(String(format: "%06d", index)).json"
    }

    final class Writer {
        private let directory: URL
        private var files: [LibraryArchiveManifest.File] = []
        private var chunks: [LibraryArchiveManifest.Chunk] = []
        private var previousPath: String?
        private var totalFiles = 0
        private var totalBytes: Int64 = 0
        private var finished = false
        private var hasBusiness = false
        private let didWriteChunk: () throws -> Void

        init(directory: URL, didWriteChunk: @escaping () throws -> Void = {}) throws {
            self.directory = directory
            self.didWriteChunk = didWriteChunk
            try FileSessionIO.checkDirectory(directory)
            let catalog = directory.appendingPathComponent(catalogDirectory, isDirectory: true)
            try FileSessionIO.ensureDirectory(catalog)
            guard try FileSessionIO.directoryEntries(catalog, limit: 1).isEmpty else {
                throw LibraryArchiveIO.invalid
            }
        }

        func append(_ file: LibraryArchiveManifest.File) throws {
            guard !finished else { throw LibraryArchiveIO.invalid }
            try file.validate()
            guard previousPath.map({ $0 < file.path }) ?? true,
                  totalFiles < LibraryArchiveLimits.maximumFiles,
                  totalBytes <= LibraryArchiveLimits.maximumTotalBytes - Int64(file.byteCount)
            else { throw LibraryArchiveIO.invalid }
            files.append(file)
            if file.path == "Business.sqlite" { hasBusiness = true }
            previousPath = file.path
            totalFiles += 1
            totalBytes += Int64(file.byteCount)
            if files.count == LibraryArchiveLimits.maximumChunkFiles { try flushChunk() }
        }

        func finish() throws -> [LibraryArchiveManifest.Chunk] {
            guard !finished, hasBusiness else { throw LibraryArchiveIO.invalid }
            if !files.isEmpty { try flushChunk() }
            finished = true
            return chunks
        }

        private func flushChunk() throws {
            guard !files.isEmpty, files.count <= LibraryArchiveLimits.maximumChunkFiles else {
                throw LibraryArchiveIO.invalid
            }
            let bytes = try SessionCodec.encode(ChunkBody(files: files))
            guard bytes.count <= LibraryArchiveLimits.maximumChunkBytes else { throw LibraryArchiveIO.invalid }
            let index = chunks.count
            guard index < LibraryArchiveLimits.maximumChunks else { throw LibraryArchiveIO.invalid }
            let path = LibraryArchiveFileCatalog.chunkPath(index)
            let url = try LibraryArchiveIO.file(path, under: directory, createParents: true)
            try LibraryArchiveIO.write(bytes, to: url)
            let inspected = try BackupFileIO.inspect(url, limit: LibraryArchiveLimits.maximumChunkBytes)
            guard inspected.byteCount == bytes.count else { throw LibraryArchiveIO.invalid }
            guard let first = files.first?.path, let last = files.last?.path else {
                throw LibraryArchiveIO.invalid
            }
            chunks.append(.init(path: path, byteCount: inspected.byteCount, digest: inspected.digest,
                                fileCount: files.count, totalFileBytes: files.reduce(0) { $0 + Int64($1.byteCount) },
                                firstPath: first, lastPath: last))
            files.removeAll(keepingCapacity: true)
            try didWriteChunk()
        }
    }

    static func forEachFile(in directory: URL, manifest: LibraryArchiveManifest,
                            _ body: (LibraryArchiveManifest.File) throws -> Void) throws {
        try manifest.validate()
        let catalog = directory.appendingPathComponent(catalogDirectory, isDirectory: true)
        try FileSessionIO.checkDirectory(catalog)
        var previousPath: String?
        var count = 0
        var totalBytes: Int64 = 0
        var businessCount = 0
        for (index, chunk) in manifest.chunks.enumerated() {
            guard chunk.path == chunkPath(index), chunk.fileCount > 0,
                  chunk.fileCount <= LibraryArchiveLimits.maximumChunkFiles,
                  chunk.totalFileBytes >= 0 else { throw LibraryArchiveIO.invalid }
            let url = try LibraryArchiveIO.file(chunk.path, under: directory)
            let bytes = try BackupFileIO.read(url, limit: LibraryArchiveLimits.maximumChunkBytes)
            guard bytes.count == chunk.byteCount, FileSessionIO.digest(bytes) == chunk.digest else {
                throw LibraryArchiveIO.invalid
            }
            let decoded = try SessionCodec.decode(ChunkBody.self, from: bytes)
            guard decoded.files.count == chunk.fileCount,
                  decoded.files.first?.path == chunk.firstPath,
                  decoded.files.last?.path == chunk.lastPath else { throw LibraryArchiveIO.invalid }
            var chunkTotal: Int64 = 0
            var lastPath = previousPath
            for file in decoded.files {
                try file.validate()
                guard lastPath.map({ $0 < file.path }) ?? true,
                      Int64(file.byteCount) <= LibraryArchiveLimits.maximumTotalBytes - chunkTotal else {
                    throw LibraryArchiveIO.invalid
                }
                chunkTotal += Int64(file.byteCount); lastPath = file.path
            }
            guard chunkTotal == chunk.totalFileBytes,
                  chunkTotal <= LibraryArchiveLimits.maximumTotalBytes - totalBytes else {
                throw LibraryArchiveIO.invalid
            }
            for file in decoded.files {
                try file.validate()
                guard previousPath.map({ $0 < file.path }) ?? true else { throw LibraryArchiveIO.invalid }
                previousPath = file.path
                count += 1
                totalBytes += Int64(file.byteCount)
                if file.path == "Business.sqlite" { businessCount += 1 }
                try body(file)
            }
        }
        guard count == manifest.fileCount, businessCount == 1,
              totalBytes <= LibraryArchiveLimits.maximumTotalBytes else { throw LibraryArchiveIO.invalid }
        let expected = Set(manifest.chunks.map(\.path))
        let actual = Set(try FileSessionIO.directoryEntries(catalog, limit: LibraryArchiveLimits.maximumChunks)
            .map { catalogDirectory + "/" + $0.lastPathComponent })
        guard expected == actual else { throw LibraryArchiveIO.invalid }
    }
}
