import Foundation
import MiraCore

struct TranscriptItem: Identifiable, Equatable {
    let id: String
    let role: MessageRole
    let text: String
    let status: MessageStatus?
    let isStreaming: Bool
    var message: Message? = nil
    var bodyPurgedAt: Date? = nil
    var executionID: ExecutionID? = nil
    var trace: [CanonicalMessage] = []
    var memoryNotices: [MemoryContextNotice] = []

    /// A process-local measurement key avoids retaining historical plaintext in geometry caches.
    func measurementSignature(expanded: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(role.rawValue)
        hasher.combine(text)
        hasher.combine(status?.rawValue)
        hasher.combine(isStreaming)
        hasher.combine(bodyPurgedAt)
        hasher.combine(expanded)
        hasher.combine(memoryNotices)
        for entry in trace {
            hasher.combine(entry.reasoning != nil)
            if expanded { hasher.combine(entry.reasoning?.text) }
        }
        return hasher.finalize()
    }
}

/// Lightweight list identity. A draft and its committed reply share the execution ID.
struct NativeTranscriptToken: Identifiable, Hashable, Sendable {
    let id: String
    let revision: Int
}

/// Diff snapshots before touching AppKit: unchanged historical rows are never configured.
struct NativeTranscriptState {
    private(set) var items: [String: TranscriptItem] = [:]
    private(set) var tokens: [NativeTranscriptToken] = []
    private(set) var expandedThinking: Set<String> = []
    private var revision = 0

    struct Change {
        let structureChanged: Bool
        let updated: [NativeTranscriptToken]
        let removed: Set<String>
    }

    mutating func apply(_ snapshot: [TranscriptItem]) -> Change {
        let ids = snapshot.map(\.id)
        let structureChanged = ids != tokens.map(\.id)
        let removed = Set(items.keys).subtracting(ids)
        let previousTokens = Dictionary(uniqueKeysWithValues: tokens.map { ($0.id, $0) })
        var updated: [NativeTranscriptToken] = []
        tokens = snapshot.map { item in
            if items[item.id] == item, let token = previousTokens[item.id] { return token }
            revision += 1
            let token = NativeTranscriptToken(id: item.id, revision: revision)
            updated.append(token)
            return token
        }
        items = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        expandedThinking.formIntersection(ids)
        for item in snapshot where item.bodyPurgedAt != nil { expandedThinking.remove(item.id) }
        return Change(structureChanged: structureChanged, updated: updated, removed: removed)
    }

    mutating func toggleThinking(_ id: String) {
        guard let item = items[id], item.bodyPurgedAt == nil else { return }
        if !expandedThinking.insert(id).inserted { expandedThinking.remove(id) }
    }
}
