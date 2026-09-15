import Foundation

/// A syntactically valid reference is only a proposal; the store must verify its execution provenance.
public struct MemoryCitationReference: Hashable, Sendable, Identifiable {
    public let memoryID: MemoryID
    public let revision: Int
    public var id: String { "memory:\(memoryID.rawValue.uuidString.lowercased())@\(revision)" }

    public init(memoryID: MemoryID, revision: Int) {
        self.memoryID = memoryID; self.revision = revision
    }

    public init?(rawValue: String) {
        guard rawValue.hasPrefix("memory:") else { return nil }
        let parts = rawValue.dropFirst(7).split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 36, let uuid = UUID(uuidString: String(parts[0])),
              let revision = Int(parts[1]), revision > 0, String(revision) == parts[1] else { return nil }
        self.init(memoryID: MemoryID(uuid), revision: revision)
    }

    public static func references(in text: String) -> [Self] {
        // Only the complete app-owned bracket format is recognized; incomplete streaming tokens wait.
        guard let pattern = try? NSRegularExpression(pattern: #"\[(memory:[A-Fa-f0-9-]{36}@[1-9][0-9]{0,9})\]"#) else { return [] }
        var result: [Self] = []
        var seen = Set<Self>()
        pattern.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            guard let match, let range = Range(match.range(at: 1), in: text), let reference = Self(rawValue: String(text[range])) else { return }
            if seen.insert(reference).inserted { result.append(reference) }
            if result.count == 32 { stop.pointee = true }
        }
        return result
    }
}

public struct MemoryCitationDetail: Sendable {
    public let memory: Memory
    public let revision: MemoryRevision
    public let evidence: [MemoryEvidence]
    public init(memory: Memory, revision: MemoryRevision, evidence: [MemoryEvidence]) {
        self.memory = memory; self.revision = revision; self.evidence = evidence
    }
}
