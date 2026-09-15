import Foundation
import MiraCore

struct TranscriptItem: Identifiable, Equatable {
    let id: String
    let role: SessionMessageRole
    let text: String
    let status: ExecutionStatus?
    let isStreaming: Bool
    var message: SessionQueryMessage? = nil
    var isBodyPurged: Bool = false
    var executionID: ExecutionID? = nil
    var thinking: String = ""
    var memoryNotices: [MemoryContextNotice] = []
    var executionPhase: ExecutionPhase? = nil
    var outputPhase: SessionOutputPhase = .waiting
    var pendingToolCall: CanonicalToolCall? = nil
    var steps: [SessionActivityStep] = []
    var liveAttemptID: UUID? = nil

    var orderedBlocks: [TranscriptProcessEntry] {
        steps.flatMap { step in
            step.blocks.map { block in
                TranscriptProcessEntry(id: step.id.uuidString + ":" + block.id, block: block,
                                       isLive: isStreaming && step.id == liveAttemptID)
            }
        }
    }

    var finalStepID: UUID? {
        guard let step = steps.last, !step.blocks.contains(where: {
            if case .tool = $0.content { return true }; return false
        }) else { return nil }
        return step.id
    }

    var processEntries: [TranscriptProcessEntry] {
        let answerIDs = Set(finalEntries.map(\.id))
        return orderedBlocks.filter { !answerIDs.contains($0.id) }
    }

    var finalEntries: [TranscriptProcessEntry] {
        guard let finalStepID else { return [] }
        let finalStep = orderedBlocks.filter { $0.id.hasPrefix(finalStepID.uuidString + ":") }
        // Only the trailing answer belongs outside the process, including when
        // the final model round interleaves text with additional reasoning.
        return Array(finalStep.reversed().prefix { entry in
            if case .text = entry.block.content { return true }
            return false
        }.reversed())
    }

    var isThinking: Bool { isStreaming && outputPhase == .thinking }

    var activityTitle: String {
        if !isStreaming {
            switch status {
            case .completed: return "Completed"
            case .cancelled: return "Stopped"
            case .interrupted: return "Interrupted"
            case .failed: return "Failed"
            default: return "Incomplete"
            }
        }
        switch executionPhase {
        case .waitingForUser: return "Waiting for approval"
        case .waitingForTools: return "Running tools…"
        case .cancelling: return "Stopping…"
        case .settling: return "Finishing…"
        case .queued: return "Queued"
        default: break
        }
        switch outputPhase {
        case .thinking: return "Thinking…"
        case .answering: return "Answering…"
        case .callingTool: return "Calling tool…"
        case .waiting: return "Working…"
        }
    }

    var activityPreview: String {
        if let latest = orderedBlocks.last {
            switch latest.block.content {
            case .text(let content), .thinking(let content): return Self.latestLine(content.text ?? "")
            case .tool(let tool): return Self.singleLine(tool.toolName + " · " + (tool.result.text ?? tool.arguments.text ?? ""))
            }
        }
        if isThinking { return Self.latestLine(thinking) }
        if outputPhase == .callingTool, let call = pendingToolCall {
            return Self.singleLine(call.name + " · " + call.arguments)
        }
        if executionPhase != .waitingForTools && executionPhase != .waitingForUser && !thinking.isEmpty {
            return Self.latestLine(thinking)
        }
        // Keep reasoning discoverable after the model starts answering.
        return Self.latestLine(thinking)
    }

    static func singleLine(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(240))
    }

    static func latestLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return singleLine(String(line.suffix(240)))
    }

    /// A process-local measurement key avoids retaining historical plaintext in geometry caches.
    func measurementSignature(expanded: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(role.rawValue)
        hasher.combine(text)
        hasher.combine(status?.rawValue)
        hasher.combine(isStreaming)
        hasher.combine(isBodyPurged)
        hasher.combine(!thinking.isEmpty)
        for entry in orderedBlocks {
            hasher.combine(entry.id)
            switch entry.block.content {
            case .text(let content), .thinking(let content): hasher.combine(content.text)
            case .tool(let tool):
                hasher.combine(tool.status.rawValue)
                hasher.combine(tool.arguments.text)
                hasher.combine(tool.result.text)
            }
        }
        hasher.combine(expanded)
        if expanded { hasher.combine(thinking) }
        hasher.combine(memoryNotices)
        return hasher.finalize()
    }
}

struct TranscriptProcessEntry: Identifiable, Equatable {
    let id: String
    let block: SessionActivityBlock
    let isLive: Bool
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
    private(set) var expandedActivity: Set<String> = []
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
        expandedActivity.formIntersection(ids)
        for item in snapshot where item.isBodyPurged { expandedActivity.remove(item.id) }
        return Change(structureChanged: structureChanged, updated: updated, removed: removed)
    }

    mutating func toggleActivity(_ id: String) {
        guard let item = items[id], !item.isBodyPurged else { return }
        if !expandedActivity.insert(id).inserted { expandedActivity.remove(id) }
    }
}
