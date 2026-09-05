import Foundation

public enum KnowledgeSourceTag: Sendable {}
public enum SourceVersionTag: Sendable {}
public enum SourceChunkTag: Sendable {}
public typealias KnowledgeSourceID = EntityID<KnowledgeSourceTag>
public typealias SourceVersionID = EntityID<SourceVersionTag>
public typealias SourceChunkID = EntityID<SourceChunkTag>

public struct KnowledgeSource: Codable, Sendable, Equatable, Identifiable {
    public var id: KnowledgeSourceID
    public var workspaceID: WorkspaceID?
    public var title: String
    public var currentVersionID: SourceVersionID?
    public var allowsRemoteUse: Bool
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public init(id: KnowledgeSourceID, workspaceID: WorkspaceID?, title: String, currentVersionID: SourceVersionID? = nil, allowsRemoteUse: Bool = false, revision: Int = 1, createdAt: Date, updatedAt: Date, deletedAt: Date? = nil) {
        self.id = id; self.workspaceID = workspaceID; self.title = title; self.currentVersionID = currentVersionID
        self.allowsRemoteUse = allowsRemoteUse; self.revision = revision; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

public struct KnowledgeSourceVersion: Codable, Sendable, Equatable, Identifiable {
    public enum ParseState: String, Codable, Sendable { case ready, failed }
    public var id: SourceVersionID
    public var sourceID: KnowledgeSourceID
    public var contentHash: String
    public var byteCount: Int
    public var parserVersion: String
    public var parseState: ParseState
    public var parseError: MiraError?
    public var createdAt: Date
    public init(id: SourceVersionID, sourceID: KnowledgeSourceID, contentHash: String, byteCount: Int, parserVersion: String, parseState: ParseState, parseError: MiraError?, createdAt: Date) {
        self.id = id; self.sourceID = sourceID; self.contentHash = contentHash; self.byteCount = byteCount
        self.parserVersion = parserVersion; self.parseState = parseState; self.parseError = parseError; self.createdAt = createdAt
    }
}

public struct SourceChunkSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: SourceChunkID
    public var sourceID: KnowledgeSourceID
    public var sourceVersionID: SourceVersionID
    public var sequence: Int
    public var startLine: Int
    public var endLine: Int
    public var startUTF8Offset: Int
    public var endUTF8Offset: Int
    public var headingPath: [String]
    public var contentHash: String
    public var citation: String { "[source:\(sourceVersionID.rawValue.uuidString.lowercased())#\(id.rawValue.uuidString.lowercased())]" }
    public init(id: SourceChunkID, sourceID: KnowledgeSourceID, sourceVersionID: SourceVersionID, sequence: Int, startLine: Int, endLine: Int, startUTF8Offset: Int, endUTF8Offset: Int, headingPath: [String], contentHash: String) {
        self.id = id; self.sourceID = sourceID; self.sourceVersionID = sourceVersionID; self.sequence = sequence
        self.startLine = startLine; self.endLine = endLine; self.startUTF8Offset = startUTF8Offset
        self.endUTF8Offset = endUTF8Offset; self.headingPath = headingPath; self.contentHash = contentHash
    }
}

public struct SourceChunk: Codable, Sendable, Equatable, Identifiable {
    public var summary: SourceChunkSummary
    public var text: String
    public var id: SourceChunkID { summary.id }
    public init(summary: SourceChunkSummary, text: String) { self.summary = summary; self.text = text }
}

public struct KnowledgeSourceDetail: Sendable {
    public var source: KnowledgeSource
    public var versions: [KnowledgeSourceVersion]
    public var selectedVersion: KnowledgeSourceVersion?
    public var chunks: [SourceChunkSummary]
    public var hasMoreChunks: Bool
    public init(source: KnowledgeSource, versions: [KnowledgeSourceVersion], selectedVersion: KnowledgeSourceVersion?, chunks: [SourceChunkSummary], hasMoreChunks: Bool = false) {
        self.source = source; self.versions = versions; self.selectedVersion = selectedVersion
        self.chunks = chunks; self.hasMoreChunks = hasMoreChunks
    }
}

public struct KnowledgeImportReceipt: Sendable {
    public var source: KnowledgeSource
    public var version: KnowledgeSourceVersion
    public var reused: Bool
    public init(source: KnowledgeSource, version: KnowledgeSourceVersion, reused: Bool) {
        self.source = source; self.version = version; self.reused = reused
    }
}

public struct KnowledgeSearchHit: Sendable, Identifiable {
    public var source: KnowledgeSource
    public var chunk: SourceChunkSummary
    public var snippet: String
    public var id: SourceChunkID { chunk.id }
    public init(source: KnowledgeSource, chunk: SourceChunkSummary, snippet: String) {
        self.source = source; self.chunk = chunk; self.snippet = snippet
    }
}

public struct KnowledgeSearchResult: Sendable {
    public var hits: [KnowledgeSearchHit]
    public var isTruncated: Bool
    public var scannedCandidates: Int
    public init(hits: [KnowledgeSearchHit], isTruncated: Bool = false, scannedCandidates: Int = 0) {
        self.hits = hits; self.isTruncated = isTruncated; self.scannedCandidates = scannedCandidates
    }
}

public struct SourceUsage: Codable, Sendable, Equatable, Hashable {
    public var sourceID: KnowledgeSourceID
    public var sourceVersionID: SourceVersionID
    public var chunkID: SourceChunkID?
    public init(sourceID: KnowledgeSourceID, sourceVersionID: SourceVersionID, chunkID: SourceChunkID? = nil) {
        self.sourceID = sourceID; self.sourceVersionID = sourceVersionID; self.chunkID = chunkID
    }
}

public struct SourceCitationReference: Hashable, Sendable, Identifiable {
    public let versionID: SourceVersionID
    public let chunkID: SourceChunkID
    public var id: String { "source:\(versionID.rawValue.uuidString.lowercased())#\(chunkID.rawValue.uuidString.lowercased())" }
    public init(versionID: SourceVersionID, chunkID: SourceChunkID) { self.versionID = versionID; self.chunkID = chunkID }
    public init?(rawValue: String) {
        guard rawValue.hasPrefix("source:") else { return nil }
        let parts = rawValue.dropFirst(7).split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 36 }),
              let version = UUID(uuidString: String(parts[0])), let chunk = UUID(uuidString: String(parts[1])) else { return nil }
        self.init(versionID: .init(version), chunkID: .init(chunk))
    }
    public static func references(in text: String) -> [Self] {
        guard let expression = try? NSRegularExpression(pattern: #"\[(source:[A-Fa-f0-9-]{36}#[A-Fa-f0-9-]{36})\]"#) else { return [] }
        var values: [Self] = [], seen: Set<Self> = []
        expression.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            guard let match, let range = Range(match.range(at: 1), in: text), let value = Self(rawValue: String(text[range])) else { return }
            if seen.insert(value).inserted { values.append(value) }
            if values.count == 32 { stop.pointee = true }
        }
        return values
    }
}

public struct SourceCitationDetail: Sendable {
    public var source: KnowledgeSource
    public var version: KnowledgeSourceVersion
    public var chunk: SourceChunk
    public init(source: KnowledgeSource, version: KnowledgeSourceVersion, chunk: SourceChunk) {
        self.source = source; self.version = version; self.chunk = chunk
    }
}

public struct BlobCollectionReport: Sendable {
    public var removedCount: Int
    public var retainedCount: Int
    public init(removedCount: Int, retainedCount: Int) { self.removedCount = removedCount; self.retainedCount = retainedCount }
}
