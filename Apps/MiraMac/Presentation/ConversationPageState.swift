import Foundation
import Observation
import MiraCore

/// One logical page survives activation changes; evicted pages retain only user drafts and geometry.
@MainActor @Observable
final class ConversationPageState: Identifiable {
    let id = UUID()
    var conversationID: ConversationID?
    var workspaceID: WorkspaceID?
    var messages: [Message] = []
    var executions: [Execution] = []
    var memoryNotices: [ExecutionID: [MemoryContextNotice]] = [:]
    var pendingSaveIDs: Set<ExecutionID> = []
    let streamBuffer = ConversationStreamBuffer()
    let readingState = ConversationReadingState()
    var composer = ""
    var selectedRouteID: RouteID?
    var inspectedExecutionID: ExecutionID?
    var error: MiraError?
    var isSending = false
    var isLoading = false
    var isLoaded: Bool
    var isActive = false
    var inspectionRevision = 0
    var contentGeneration = 0
    @ObservationIgnored var loadGeneration = 0
    @ObservationIgnored var needsReload = false
    @ObservationIgnored var loadTask: Task<Void, Never>?

    init(conversationID: ConversationID? = nil, workspaceID: WorkspaceID? = nil) {
        self.conversationID = conversationID
        self.workspaceID = workspaceID
        isLoaded = conversationID == nil
    }

    var activeExecution: Execution? { executions.last { !$0.status.isTerminal } }
    var needsPersistenceRetry: Bool { activeExecution.map { pendingSaveIDs.contains($0.id) } ?? false }
    var retryableExecution: Execution? {
        guard let last = executions.last, last.status.isTerminal, last.status != .completed,
              messages.last(where: { $0.role == .user })?.id == last.triggerMessageID else { return nil }
        return last
    }

    func apply(_ snapshot: ConversationSnapshot) {
        streamBuffer.replace(drafts: Dictionary(uniqueKeysWithValues: snapshot.drafts.map { ($0.executionID, $0.text) }),
                             thinkingTraces: Dictionary(uniqueKeysWithValues: snapshot.drafts.map { ($0.executionID, $0.trace) }))
        if messages != snapshot.messages || executions != snapshot.executions || memoryNotices != snapshot.memoryNotices || pendingSaveIDs != snapshot.pendingSaveIDs {
            messages = snapshot.messages
            executions = snapshot.executions
            memoryNotices = snapshot.memoryNotices
            pendingSaveIDs = snapshot.pendingSaveIDs
            inspectionRevision &+= 1
        }
        isLoaded = true
        isLoading = false
    }

    func releaseContent() {
        loadGeneration &+= 1
        loadTask?.cancel(); loadTask = nil
        needsReload = false
        messages = []; executions = []; memoryNotices = [:]; pendingSaveIDs = []
        streamBuffer.replace(drafts: [:], thinkingTraces: [:])
        isLoaded = conversationID == nil
        isLoading = false
        contentGeneration &+= 1
        inspectionRevision &+= 1
    }
}
