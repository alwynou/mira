import Foundation
import MiraCore
import Observation

/// A window retains drafts and reading geometry independently of disposable session content.
@MainActor @Observable
final class ConversationPageState: Identifiable {
    let id = UUID()
    var conversationID: ConversationID?
    var workspaceID: WorkspaceID?
    private(set) var session: SessionQueryItem?
    private(set) var messages: [SessionQueryMessage] = []
    private(set) var executions: [SessionExecutionSummary] = []
    private(set) var hasMoreMessages = false
    var memoryNotices: [ExecutionID: [MemoryContextNotice]] = [:]
    var activities: [ExecutionID: [SessionActivityStep]] = [:]
    @ObservationIgnored var noticeGeneration = 0
    @ObservationIgnored var noticeTask: Task<Void, Never>?
    var persistedDraft: SessionQueryDraft?
    var pendingAdmission: AgentSubmitCommand?
    var pendingAdmissionRuntimeID: UUID?
    var pendingSaveIDs: Set<ExecutionID> = []
    var cancellationRequested: Set<ExecutionID> = []
    let streamBuffer = ConversationStreamBuffer()
    let readingState = ConversationReadingState()
    var composer = ""
    var selectedRouteID: RouteID?
    var isSelectingModel = false
    @ObservationIgnored var modelChoiceGeneration = 0
    var modelSelection: AgentSessionModelSelection = .inherit
    var modelSelectionRevision: Int = 0
    var inspectedExecutionID: ExecutionID?
    var error: MiraError?
    var isSending = false
    @ObservationIgnored var submissionCancelled = false
    var isLoading = false
    var isLoaded: Bool
    var isActive = false
    var inspectionRevision = 0
    var contentGeneration = 0
    @ObservationIgnored var loadGeneration = 0
    @ObservationIgnored var loadTask: Task<Void, Never>?
    @ObservationIgnored var observers: [Task<Void, Never>] = []
    @ObservationIgnored var observationID: UUID?
    @ObservationIgnored var lastObservedSequence: Int64?

    init(conversationID: ConversationID? = nil, workspaceID: WorkspaceID? = nil) {
        self.conversationID = conversationID
        self.workspaceID = workspaceID
        isLoaded = conversationID == nil
    }

    var activeExecution: SessionExecutionSummary? {
        guard let id = session?.summary.activeExecutionID else { return nil }
        return executions.first { $0.id == id && $0.completion == nil }
    }
    var needsPersistenceRetry: Bool { !pendingSaveIDs.isEmpty || pendingAdmission != nil }
    var retryableExecution: SessionExecutionSummary? {
        guard let latestID = session?.summary.latestExecutionID,
            let last = executions.first(where: { $0.id == latestID }), let completion = last.completion,
            completion.status != .completed, !last.isExcludedFromContext
        else { return nil }
        return last
    }

    func apply(_ snapshot: SessionQueryMessagePage, appendingOlder: Bool = false) {
        let previousHasMore = hasMoreMessages
        session = snapshot.session
        workspaceID = snapshot.session?.summary.workspaceID ?? workspaceID
        if appendingOlder {
            let newIDs = Set(snapshot.messages.map(\.id))
            messages = (messages.filter { !newIDs.contains($0.id) } + snapshot.messages)
                .sorted { $0.summary.sequence < $1.summary.sequence }
            let newExecutionIDs = Set(snapshot.executions.map(\.id))
            executions = (executions.filter { !newExecutionIDs.contains($0.id) } + snapshot.executions)
                .sorted { $0.sequence < $1.sequence }
        } else {
            let oldest = snapshot.messages.map(\.summary.sequence).min()
            let retained = oldest.map { boundary in messages.filter { $0.summary.sequence < boundary } } ?? []
            let currentIDs = Set(snapshot.executions.map(\.id))
            messages = (retained + snapshot.messages).sorted { $0.summary.sequence < $1.summary.sequence }
            let retainedIDs = Set(retained.map(\.summary.executionID))
            executions =
                (executions.filter { retainedIDs.contains($0.id) && !currentIDs.contains($0.id) }
                + snapshot.executions).sorted { $0.sequence < $1.sequence }
            if !retained.isEmpty { hasMoreMessages = previousHasMore }
        }
        if appendingOlder || messages.count == snapshot.messages.count { hasMoreMessages = snapshot.hasMore }
        if let persistedDraft,
            !executions.contains(where: { $0.id == persistedDraft.executionID && $0.completion == nil })
        {
            self.persistedDraft = nil
        }
        isLoaded = true
        isLoading = false
        inspectionRevision &+= 1
    }

    var transcriptItems: [TranscriptItem] {
        let statuses = Dictionary(uniqueKeysWithValues: executions.map { ($0.id, $0.completion?.status) })
        let executionsByID = Dictionary(uniqueKeysWithValues: executions.map { ($0.id, $0) })

        // A retry replaces the answer to the original user message. Execution
        // metadata retains command identity; retired answer payloads are purged.
        func turnID(for executionID: ExecutionID) -> MessageID? {
            executionsByID[executionID]?.admission.userMessageID
        }
        var latestExecutionByTurn: [MessageID: SessionExecutionSummary] = [:]
        for execution in executions {
            let turn = execution.admission.userMessageID
            if let current = latestExecutionByTurn[turn], current.sequence > execution.sequence { continue }
            latestExecutionByTurn[turn] = execution
        }

        var latestAssistantByTurn: [MessageID: SessionQueryMessage] = [:]
        for message in messages where message.summary.role == .assistant {
            guard let turn = turnID(for: message.summary.executionID) else { continue }
            guard let execution = executionsByID[message.summary.executionID],
                  latestExecutionByTurn[turn]?.id == execution.id else { continue }
            if let current = latestAssistantByTurn[turn], current.summary.sequence > message.summary.sequence { continue }
            latestAssistantByTurn[turn] = message
        }

        var entries: [(sequence: Int64, order: Int, item: TranscriptItem)] = []
        var order = 0
        for message in messages {
            let summary = message.summary
            let id: String
            if summary.role == .assistant {
                guard let turn = turnID(for: summary.executionID),
                      latestAssistantByTurn[turn]?.id == message.id else { continue }
                id = Self.answerTranscriptID(for: turn)
            } else {
                id = "message:\(message.id.rawValue.uuidString)"
            }
            entries.append((
                summary.sequence, order,
                TranscriptItem(
                    id: id, role: summary.role, text: message.body.text ?? "",
                    status: summary.role == .user ? .completed : statuses[summary.executionID] ?? nil,
                    isStreaming: false, message: message, isBodyPurged: message.body == .purged,
                    executionID: summary.executionID, thinking: message.thinking.text ?? "",
                    memoryNotices: summary.role == .assistant ? memoryNotices[summary.executionID, default: []] : [],
                    steps: summary.role == .assistant ? activitySteps(for: summary.executionID, live: nil,
                        recoveredAnswer: message.body.text, recoveredThinking: message.thinking.text) : [])))
            order += 1
        }

        // A terminal execution without visible output still occupies the same
        // answer slot. This also covers a newly reopened page where only the
        // user message and execution summaries are available on the first page.
        for execution in latestExecutionByTurn.values {
            let turn = execution.admission.userMessageID
            guard latestAssistantByTurn[turn] == nil else { continue }
            let identity = Self.answerTranscriptID(for: turn)
            if let completion = execution.completion {
                // A persisted answer outside the loaded page is not an empty
                // answer. Its row appears when its message page is loaded.
                guard completion.answer == nil, completion.visibleThinking == nil else { continue }
                entries.append((execution.sequence, order, .init(
                    id: identity, role: .assistant, text: "", status: completion.status,
                    isStreaming: false, executionID: execution.id,
                    steps: activitySteps(for: execution.id, live: nil))))
                order += 1
                continue
            }
            guard !execution.isExcludedFromContext,
                  !cancellationRequested.contains(execution.id) else { continue }
            let observedOutput = streamBuffer.observation?.value
            let live = observedOutput?.executionID == execution.id ? observedOutput : nil
            let answer: String
            let thinking: String
            if let live, live.executionID == execution.id {
                answer = live.answer
                thinking = live.thinking
            } else if let persistedDraft, persistedDraft.executionID == execution.id {
                answer = persistedDraft.answer
                thinking = persistedDraft.thinking
            } else {
                answer = ""
                thinking = ""
            }
            entries.append((execution.sequence, order, .init(
                id: identity, role: .assistant, text: answer, status: nil,
                isStreaming: true, executionID: execution.id, thinking: thinking,
                executionPhase: execution.phase,
                outputPhase: live?.phase ?? .waiting,
                pendingToolCall: live?.toolCall,
                steps: activitySteps(for: execution.id, live: live),
                liveAttemptID: live?.attemptID)))
            order += 1
        }
        return entries.sorted {
            $0.sequence == $1.sequence ? $0.order < $1.order : $0.sequence < $1.sequence
        }.map(\.item)
    }

    /// Overlay only the current attempt; earlier durable steps remain in their original order.
    private func activitySteps(for executionID: ExecutionID, live: SessionVisibleOutput?,
                               recoveredAnswer: String? = nil, recoveredThinking: String? = nil) -> [SessionActivityStep] {
        var steps = activities[executionID, default: []]
        if live == nil, let last = steps.last, last.blocks.isEmpty,
           recoveredAnswer != nil || recoveredThinking != nil {
            let prefix = steps.dropLast().flatMap(\.blocks).compactMap { block -> String? in
                if case .thinking(let content) = block.content { return content.text }; return nil
            }.joined()
            var blocks: [SessionActivityBlock] = []
            if let thinking = recoveredThinking, thinking.hasPrefix(prefix) {
                let remainder = String(thinking.dropFirst(prefix.count))
                if !remainder.isEmpty { blocks.append(.init(id: "recovered-thinking", content: .thinking(.available(remainder)))) }
            }
            if let answer = recoveredAnswer, !answer.isEmpty {
                blocks.append(.init(id: "recovered-answer", content: .text(.available(answer))))
            }
            steps[steps.count - 1] = .init(id: last.id, stepIndex: last.stepIndex, blocks: blocks)
        }
        guard let live, !live.blocks.isEmpty else { return steps }
        let durable = steps.first { $0.id == live.attemptID }
        let blocks = live.blocks.compactMap { block -> SessionActivityBlock? in
            let content: SessionActivityBlock.Content
            switch block.content {
            case .text(let value): content = .text(.available(value))
            case .thinking(let value): content = .thinking(.available(value))
            case .toolCall(let call):
                if let saved = durable?.blocks.first(where: { $0.id == block.id }), case .tool = saved.content {
                    return saved
                }
                content = .tool(.init(id: live.attemptID, toolName: call.name, status: .queued,
                                     arguments: .available(call.arguments), result: .absent))
            case .toolResult: return nil
            }
            return .init(id: block.id, content: content)
        }
        let step = SessionActivityStep(id: live.attemptID,
            stepIndex: durable?.stepIndex ?? ((steps.last?.stepIndex ?? -1) + 1), blocks: blocks)
        if let index = steps.firstIndex(where: { $0.id == live.attemptID }) { steps[index] = step }
        else { steps.append(step) }
        return steps
    }

    /// Stable for the lifetime of a user turn, including across retry executions.
    static func answerTranscriptID(for userMessageID: MessageID) -> String {
        "answer:\(userMessageID.rawValue.uuidString)"
    }

    /// The caller cancels and drains returned presentation tasks; executions remain application-owned.
    @discardableResult
    func releaseContent() -> [Task<Void, Never>] {
        loadGeneration &+= 1
        noticeGeneration &+= 1
        observationID = nil
        lastObservedSequence = nil
        let tasks = observers + [loadTask, noticeTask].compactMap { $0 }
        tasks.forEach { $0.cancel() }
        observers = []
        loadTask = nil
        noticeTask = nil
        memoryNotices = [:]
        activities = [:]
        session = nil
        messages = []
        executions = []
        pendingSaveIDs = []
        cancellationRequested = []
        error = nil
        persistedDraft = nil
        streamBuffer.clear()
        hasMoreMessages = false
        isLoaded = conversationID == nil
        isLoading = false
        contentGeneration &+= 1
        inspectionRevision &+= 1
        readingState.expandedActivityIDs = []
        readingState.expandedProcessBlockIDs = []
        readingState.rowMeasurements = [:]
        return tasks
    }
}
