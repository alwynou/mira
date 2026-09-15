import Foundation
import MiraCore

/// Current archive metadata. File records are read from bounded, verified chunks.
public struct LibraryArchiveManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let byteCount: Int
        public let digest: String

        func validate() throws {
            try LibraryArchiveIO.validatePath(path)
            let root = path.split(separator: "/").first.map(String.init)
            guard root != "manifest.json", root != "Catalog", root != "Projections",
                  !path.hasPrefix("Business.sqlite") || path == "Business.sqlite",
                  (0...LibraryArchiveLimits.maximumFileBytes).contains(byteCount) else {
                throw LibraryArchiveIO.invalid
            }
            try SQLiteArchiveValidation.digest(digest)
        }
    }
    public struct Chunk: Codable, Equatable, Sendable {
        public let path: String
        public let byteCount: Int
        public let digest: String
        public let fileCount: Int
        public let totalFileBytes: Int64
        public let firstPath: String
        public let lastPath: String
    }
    public let formatVersion: Int
    public let authorization: AgentLibraryAuthorization
    public let modules: [SQLiteArchiveModule.Identity]
    public let sessions: [SessionJournalHead]
    public let chunks: [Chunk]

    public var fileCount: Int {
        chunks.reduce(0) { total, chunk in
            let sum = total.addingReportingOverflow(chunk.fileCount)
            return sum.overflow ? Int.max : sum.partialValue
        }
    }
    public var totalFileBytes: Int64 {
        chunks.reduce(0) { total, chunk in
            let sum = total.addingReportingOverflow(chunk.totalFileBytes)
            return sum.overflow ? Int64.max : sum.partialValue
        }
    }

    init(formatVersion: Int, authorization: AgentLibraryAuthorization,
         modules: [SQLiteArchiveModule.Identity], sessions: [SessionJournalHead], chunks: [Chunk]) {
        self.formatVersion = formatVersion; self.authorization = authorization
        self.modules = modules; self.sessions = sessions; self.chunks = chunks
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, authorization, modules, sessions, chunks }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        guard formatVersion == 2 else { throw LibraryArchiveIO.invalid }
        authorization = try values.decode(AgentLibraryAuthorization.self, forKey: .authorization)
        func array<T: Decodable>(_ type: T.Type, key: CodingKeys, limit: Int) throws -> [T] {
            var container = try values.nestedUnkeyedContainer(forKey: key)
            if let count = container.count, count > limit { throw LibraryArchiveIO.invalid }
            var result: [T] = []
            while !container.isAtEnd {
                guard result.count < limit else { throw LibraryArchiveIO.invalid }
                result.append(try container.decode(type))
            }
            return result
        }
        modules = try array(SQLiteArchiveModule.Identity.self, key: .modules, limit: 128)
        sessions = try array(SessionJournalHead.self, key: .sessions, limit: FileSessionArchive.maximumSessions)
        chunks = try array(Chunk.self, key: .chunks, limit: LibraryArchiveLimits.maximumChunks)
        try validate()
    }

    func validate() throws {
        guard formatVersion == 2, modules.count <= 128,
              modules == modules.sorted(by: { $0.name < $1.name }),
              Set(modules.map(\.name)).count == modules.count,
              modules.allSatisfy({ SQLiteArchiveModule.validName($0.name) && $0.revision > 0 }),
              sessions.count <= FileSessionArchive.maximumSessions,
              sessions == sessions.sorted(by: { $0.cursor.sessionID.rawValue.uuidString < $1.cursor.sessionID.rawValue.uuidString }),
              Set(sessions.map(\.cursor.sessionID)).count == sessions.count,
              !chunks.isEmpty, chunks.count <= LibraryArchiveLimits.maximumChunks else {
            throw LibraryArchiveIO.invalid
        }
        for head in sessions {
            try head.validate()
            guard head.cursor.sequence > 0 else { throw LibraryArchiveIO.invalid }
        }
        var count = 0, total: Int64 = 0
        var previousPath: String?
        for (index, chunk) in chunks.enumerated() {
            guard chunk.path == LibraryArchiveFileCatalog.chunkPath(index),
                  (1...LibraryArchiveLimits.maximumChunkBytes).contains(chunk.byteCount),
                  (1...LibraryArchiveLimits.maximumChunkFiles).contains(chunk.fileCount),
                  index == chunks.count - 1 || chunk.fileCount == LibraryArchiveLimits.maximumChunkFiles,
                  chunk.fileCount <= LibraryArchiveLimits.maximumFiles - count,
                  chunk.totalFileBytes >= 0, chunk.totalFileBytes <= LibraryArchiveLimits.maximumTotalBytes - total else {
                throw LibraryArchiveIO.invalid
            }
            try SQLiteArchiveValidation.digest(chunk.digest)
            try LibraryArchiveIO.validatePath(chunk.firstPath); try LibraryArchiveIO.validatePath(chunk.lastPath)
            guard chunk.firstPath <= chunk.lastPath,
                  previousPath.map({ $0 < chunk.firstPath }) ?? true else { throw LibraryArchiveIO.invalid }
            count += chunk.fileCount; total += chunk.totalFileBytes; previousPath = chunk.lastPath
        }
    }
}

enum LibraryArchiveLimits {
    static let maximumFiles = 262_144
    static let maximumChunkFiles = 1_024
    static let maximumChunks = maximumFiles / maximumChunkFiles
    static let maximumChunkBytes = 1 * 1_024 * 1_024
    static let maximumManifestBytes = 2 * 1_024 * 1_024
    static let maximumDomainRows = 100_000
    static let maximumFileBytes = 2 * 1_024 * 1_024 * 1_024
    static let maximumAttachmentBytes = SessionFormatLimits.maximumPayloadBytes
    static let maximumTotalBytes: Int64 = 64 * 1_024 * 1_024 * 1_024
    // Source files, catalog chunks and the root manifest, plus all path components.
    static let maximumPhysicalFiles = maximumFiles + maximumChunks + 1
    static let maximumDirectoryEntries = maximumPhysicalFiles * 8 + 3
}
