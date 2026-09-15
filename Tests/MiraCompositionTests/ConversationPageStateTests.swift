import Foundation
import MiraCore
import Testing

@Suite("Conversation page state", .timeLimit(.minutes(1)))
@MainActor
struct ConversationPageStateTests {
    @Test func latestRefreshPreservesLoadedOlderMessagesAndHasMore() {
        let session = ConversationID()
        let page = ConversationPageState(conversationID: session)
        let first = message(session: session, sequence: 1, role: .user, text: "older")
        let latest = message(session: session, sequence: 3, role: .assistant, text: "latest")

        page.apply(snapshot(session: session, messages: [latest], executions: [], hasMore: true))
        page.apply(snapshot(session: session, messages: [first], executions: [], hasMore: true), appendingOlder: true)
        page.apply(snapshot(session: session, messages: [latest], executions: [], hasMore: false))

        #expect(page.messages.map(\.summary.sequence) == [1, 3])
        #expect(page.messages.first?.body.text == "older")
        #expect(page.messages.last?.body.text == "latest")
        #expect(page.hasMoreMessages)
    }

    @Test func olderPageAppendDeduplicatesMessagesAndExecutions() {
        let session = ConversationID()
        let page = ConversationPageState(conversationID: session)
        let latestMessage = message(session: session, sequence: 4, role: .assistant, text: "latest")
        let olderMessage = message(session: session, sequence: 1, role: .user, text: "older")
        let duplicateMessage = message(
            session: session, sequence: 4, role: .assistant, text: "latest refreshed", id: latestMessage.id)
        let firstExecution = execution(session: session, sequence: 1)
        let secondExecution = execution(session: session, sequence: 4)

        page.apply(snapshot(session: session, messages: [latestMessage], executions: [secondExecution], hasMore: true))
        page.apply(
            snapshot(
                session: session, messages: [olderMessage, duplicateMessage],
                executions: [firstExecution, secondExecution], hasMore: false), appendingOlder: true)

        #expect(page.messages.map(\.summary.id) == [olderMessage.id, duplicateMessage.id])
        #expect(page.messages.last?.body.text == "latest refreshed")
        #expect(page.executions.map(\.id) == [firstExecution.id, secondExecution.id])
        #expect(!page.hasMoreMessages)
    }

    @Test func releaseContentClearsQueryDraftAndLiveCachesButRetainsWindowIntent() async {
        let session = ConversationID()
        let page = ConversationPageState(conversationID: session)
        let executionID = ExecutionID()
        let admission = AgentSubmitCommand(
            id: UUID(), sessionID: session, executionID: executionID,
            input: .message(id: MessageID(), text: "pending", timeZoneIdentifier: "UTC"),
            options: .init(instructions: "demo", route: nil))
        page.apply(
            snapshot(
                session: session, messages: [message(session: session, sequence: 1, role: .user, text: "pending")],
                executions: [execution(session: session, sequence: 1)], hasMore: true))
        page.persistedDraft = .init(
            head: .init(cursor: .init(sessionID: session, sequence: 1), batchID: UUID()), executionID: executionID,
            answer: "draft", thinking: "thinking")
        page.pendingAdmission = admission
        page.activities[executionID] = [.init(id: UUID(), stepIndex: 0, blocks: [
            .init(id: "call", content: .tool(.init(id: UUID(), toolName: "knowledge.search", status: .running,
                  arguments: .available("Private tool input"), result: .absent)))])]
        page.pendingAdmissionRuntimeID = UUID()
        page.pendingSaveIDs = [executionID]
        page.cancellationRequested = [executionID]
        page.composer = "keep this draft"
        page.selectedRouteID = RouteID()
        page.inspectedExecutionID = executionID
        page.error = .init(.storage, "test")
        page.isSending = true
        page.readingState.recordOffset(321)
        page.streamBuffer.receive(
            .init(
                cursor: .init(sessionID: session, sequence: 1), revision: 1,
                value: .init(
                    executionID: executionID, attemptID: UUID(), stepID: UUID(), answer: "live",
                    thinking: "live thinking"),
                isClosing: false))
        page.streamBuffer.flush()
        let observer = Task<Void, Never> {
            do { try await Task.sleep(for: .seconds(60)) } catch {}
        }
        page.observers = [observer]

        let tasks = page.releaseContent()
        for task in tasks { await task.value }

        #expect(page.session == nil)
        #expect(page.messages.isEmpty)
        #expect(page.executions.isEmpty)
        #expect(page.persistedDraft == nil)
        #expect(page.pendingSaveIDs.isEmpty)
        #expect(page.cancellationRequested.isEmpty)
        #expect(page.streamBuffer.observation == nil)
        #expect(page.activities.isEmpty)
        #expect(page.hasMoreMessages == false)
        #expect(page.observers.isEmpty)
        #expect(page.composer == "keep this draft")
        #expect(page.selectedRouteID != nil)
        #expect(page.pendingAdmission?.id == admission.id)
        #expect(page.pendingAdmissionRuntimeID != nil)
        #expect(page.readingState.visibleOffset == 321)
        #expect(observer.isCancelled)
    }

    @Test func transcriptUsesStableAnswerSlotAndNeverShowsLiveTextAfterCompletionOrCancellation() {
        let session = ConversationID()
        let page = ConversationPageState(conversationID: session)
        let executionID = ExecutionID()
        let active = execution(session: session, sequence: 1, executionID: executionID)
        let user = message(session: session, sequence: 1, role: .user, text: "question", executionID: executionID)
        page.apply(snapshot(session: session, messages: [user], executions: [active], hasMore: false))
        page.streamBuffer.receive(
            .init(
                cursor: .init(sessionID: session, sequence: 1), revision: 1,
                value: .init(
                    executionID: executionID, attemptID: UUID(), stepID: UUID(), answer: "live answer",
                    thinking: "live thinking", phase: .answering),
                isClosing: false))
        page.streamBuffer.flush()

        let live = page.transcriptItems.last
        #expect(live?.id == ConversationPageState.answerTranscriptID(for: active.admission.userMessageID))
        #expect(live?.isStreaming == true)
        #expect(live?.text == "live answer")
        #expect(live?.activityTitle == "Answering…")
        #expect(live?.isThinking == false)
        #expect(live?.thinking == "live thinking")

        // The journal resolves the model attempt before the asynchronous query
        // supplies its completed assistant row. That gap must keep the body.
        page.streamBuffer.receive(.init(cursor: .init(sessionID: session, sequence: 2), revision: 2,
                                        value: nil, isClosing: false, handoffExecutionID: executionID))
        #expect(page.transcriptItems.last?.text == "live answer")
        #expect(page.transcriptItems.last?.id == live?.id)

        let completed = execution(
            session: session, sequence: 1, executionID: executionID,
            userMessageID: active.admission.userMessageID,
            completion: .init(executionID: executionID, status: .completed))
        let assistant = message(
            session: session, sequence: 2, role: .assistant, text: "durable answer", executionID: executionID)
        page.apply(snapshot(session: session, messages: [user, assistant], executions: [completed], hasMore: false))
        let durable = page.transcriptItems.last
        #expect(durable?.id == live?.id)
        #expect(durable?.isStreaming == false)
        #expect(durable?.text == "durable answer")

        page.cancellationRequested.insert(executionID)
        let cancelled = execution(
            session: session, sequence: 1, executionID: executionID,
            userMessageID: active.admission.userMessageID,
            completion: .init(executionID: executionID, status: .cancelled))
        page.apply(snapshot(session: session, messages: [user], executions: [cancelled], hasMore: false))
        #expect(page.transcriptItems.allSatisfy { $0.text != "live answer" })

        page.cancellationRequested.remove(executionID)
        let purged = message(
            session: session, sequence: 2, role: .assistant, text: "ignored", executionID: executionID, body: .purged)
        page.apply(snapshot(session: session, messages: [user, purged], executions: [completed], hasMore: false))
        let purgedItem = page.transcriptItems.last
        #expect(purgedItem?.id == live?.id)
        #expect(purgedItem?.isBodyPurged == true)
        #expect(purgedItem?.text != "live answer")
    }

    @Test func latestFailedRetryRemainsActionableWithoutTheOriginalUserOnTheLoadedPage() {
        let session = ConversationID()
        let originalID = ExecutionID()
        let retryID = ExecutionID()
        let userMessageID = MessageID()
        let page = ConversationPageState(conversationID: session)
        let historical = message(
            session: session, sequence: 2, role: .assistant,
            text: "Earlier incomplete answer", executionID: originalID)
        let original = execution(
            session: session, sequence: 1, executionID: originalID,
            userMessageID: userMessageID,
            completion: .init(executionID: originalID, status: .failed))
        let retry = execution(
            session: session, sequence: 3, executionID: retryID,
            userMessageID: userMessageID, retryOfExecutionID: originalID,
            completion: .init(executionID: retryID, status: .failed))
        page.apply(snapshot(session: session, messages: [historical], executions: [original, retry], hasMore: true))
        #expect(page.retryableExecution?.id == retryID)
        #expect(page.activeExecution == nil)
        #expect(page.transcriptItems.last?.id == ConversationPageState.answerTranscriptID(for: userMessageID))
        #expect(page.transcriptItems.last?.status == .failed)
        #expect(page.transcriptItems.last?.isStreaming == false)
        #expect(page.transcriptItems.last?.text == "")
    }

    @Test func retryReplacesOneAnswerSlotAcrossRunningSuccessFailureReopenAndSeparateTurns() {
        let session = ConversationID()
        let firstUserID = MessageID()
        let originalID = ExecutionID()
        let retryID = ExecutionID()
        let original = execution(
            session: session, sequence: 1, executionID: originalID, userMessageID: firstUserID,
            completion: .init(executionID: originalID, status: .failed))
        let originalAnswer = message(
            session: session, sequence: 2, role: .assistant, text: "first attempt", executionID: originalID)
        let retry = execution(
            session: session, sequence: 3, executionID: retryID, userMessageID: firstUserID,
            retryOfExecutionID: originalID)
        let firstUser = message(
            session: session, sequence: 1, role: .user, text: "first question",
            executionID: originalID, id: firstUserID)
        let page = ConversationPageState(conversationID: session)

        page.apply(snapshot(
            session: session, messages: [firstUser, originalAnswer], executions: [original, retry], hasMore: false))
        let running = page.transcriptItems.filter { $0.role == .assistant }
        #expect(running.count == 1)
        #expect(running[0].id == ConversationPageState.answerTranscriptID(for: firstUserID))
        #expect(running[0].isStreaming)
        #expect(running[0].executionID == retryID)

        let retryAnswer = message(
            session: session, sequence: 4, role: .assistant, text: "retried answer", executionID: retryID)
        let completedRetry = execution(
            session: session, sequence: 3, executionID: retryID, userMessageID: firstUserID,
            retryOfExecutionID: originalID, completion: .init(executionID: retryID, status: .completed))
        page.apply(snapshot(
            session: session, messages: [firstUser, originalAnswer, retryAnswer],
            executions: [original, completedRetry], hasMore: false))
        let success = page.transcriptItems.filter { $0.role == .assistant }
        #expect(success.count == 1)
        #expect(success[0].id == running[0].id)
        #expect(success[0].text == "retried answer")
        #expect(success[0].executionID == retryID)
        #expect(!success[0].isStreaming)

        let failedRetry = execution(
            session: session, sequence: 3, executionID: retryID, userMessageID: firstUserID,
            retryOfExecutionID: originalID, completion: .init(executionID: retryID, status: .failed))
        page.apply(snapshot(
            session: session, messages: [firstUser, originalAnswer], executions: [original, failedRetry], hasMore: true))
        let failed = page.transcriptItems.filter { $0.role == .assistant }
        #expect(failed.count == 1)
        #expect(failed[0].id == running[0].id)
        #expect(failed[0].status == .failed)
        #expect(failed[0].text.isEmpty)

        let reopened = ConversationPageState(conversationID: session)
        reopened.apply(snapshot(
            session: session, messages: [firstUser, originalAnswer], executions: [original, failedRetry], hasMore: true))
        #expect(reopened.transcriptItems.filter { $0.role == .assistant }.map(\.id) == [failed[0].id])

        let secondUserID = MessageID()
        let secondExecutionID = ExecutionID()
        let secondExecution = execution(
            session: session, sequence: 5, executionID: secondExecutionID, userMessageID: secondUserID,
            completion: .init(executionID: secondExecutionID, status: .completed))
        let secondUser = message(
            session: session, sequence: 5, role: .user, text: "second question",
            executionID: secondExecutionID, id: secondUserID)
        let secondAnswer = message(
            session: session, sequence: 6, role: .assistant, text: "second answer", executionID: secondExecutionID)
        page.apply(snapshot(
            session: session, messages: [firstUser, originalAnswer, secondUser, secondAnswer],
            executions: [original, failedRetry, secondExecution], hasMore: false))
        let separate = page.transcriptItems.filter { $0.role == .assistant }
        #expect(separate.count == 2)
        #expect(Set(separate.map(\.id)) == Set([
            ConversationPageState.answerTranscriptID(for: firstUserID),
            ConversationPageState.answerTranscriptID(for: secondUserID)
        ]))
    }

    @Test func paginatedRetryRowsKeepLatestAnswerIdentityWhenOlderAttemptLoadsLater() {
        let session = ConversationID()
        let userMessageID = MessageID()
        let originalID = ExecutionID()
        let retryID = ExecutionID()
        let original = execution(
            session: session, sequence: 1, executionID: originalID, userMessageID: userMessageID,
            completion: .init(executionID: originalID, status: .failed))
        let retry = execution(
            session: session, sequence: 3, executionID: retryID, userMessageID: userMessageID,
            retryOfExecutionID: originalID,
            completion: .init(executionID: retryID, status: .completed))
        let oldAnswer = message(
            session: session, sequence: 2, role: .assistant, text: "purged attempt", executionID: originalID,
            body: .purged)
        let latestAnswer = message(
            session: session, sequence: 4, role: .assistant, text: "latest attempt", executionID: retryID)
        let user = message(
            session: session, sequence: 1, role: .user, text: "same question", executionID: originalID,
            id: userMessageID)
        let page = ConversationPageState(conversationID: session)

        page.apply(snapshot(session: session, messages: [latestAnswer], executions: [retry], hasMore: true))
        let answerID = ConversationPageState.answerTranscriptID(for: userMessageID)
        #expect(page.transcriptItems.filter { $0.role == .assistant }.map(\.id) == [answerID])
        #expect(page.transcriptItems.last?.text == "latest attempt")

        page.apply(
            snapshot(session: session, messages: [user, oldAnswer], executions: [original, retry], hasMore: false),
            appendingOlder: true)
        let answers = page.transcriptItems.filter { $0.role == .assistant }
        #expect(answers.map(\.id) == [answerID])
        #expect(answers.first?.text == "latest attempt")
        #expect(answers.first?.executionID == retryID)
        #expect(page.messages.contains { $0.summary.id == oldAnswer.summary.id })
        #expect(page.hasMoreMessages == false)
    }

    @Test func liveAttemptOverlaysOnlyItsOwnBlocksAndKeepsEarlierToolResult() throws {
        let session = ConversationID(), executionID = ExecutionID()
        let page = ConversationPageState(conversationID: session)
        let active = execution(session: session, sequence: 1, executionID: executionID)
        page.apply(snapshot(session: session, messages: [], executions: [active], hasMore: false))
        let first = UUID(), next = UUID(), invocation = UUID()
        let previous = SessionActivityStep(id: first, stepIndex: 0, blocks: [
            .init(id: "thinking", content: .thinking(.available("Earlier reasoning"))),
            .init(id: "text", content: .text(.available("Intermediate text"))),
            .init(id: "tool", content: .tool(.init(id: invocation, toolName: "fixture.read", status: .succeeded,
                arguments: .available("arguments"), result: .available("Full tool result"))))
        ])
        page.activities[executionID] = [previous, .init(id: next, stepIndex: 1, blocks: [])]
        page.streamBuffer.receive(.init(cursor: .init(sessionID: session, sequence: 2), revision: 1,
            value: .init(executionID: executionID, attemptID: next, stepID: UUID(), answer: "Latest answer",
                         thinking: "Earlier reasoningLatest reasoning", phase: .answering, blocks: [
                             .init(id: "thinking", content: .thinking("Latest reasoning")),
                             .init(id: "answer", content: .text("Latest answer"))
                         ]), isClosing: false))
        page.streamBuffer.flush()
        let item = try #require(page.transcriptItems.first)
        #expect(item.steps.first == previous)
        #expect(item.steps.count == 2)
        #expect(item.steps.last?.blocks.first?.content == .thinking(.available("Latest reasoning")))
        #expect(item.processEntries.map(\.block.id) == ["thinking", "text", "tool", "thinking"])
        #expect(item.finalEntries.map(\.block.id) == ["answer"])
        #expect(Set(item.orderedBlocks.map(\.id)).count == 5)
    }

    private func snapshot(
        session: ConversationID, messages: [SessionQueryMessage], executions: [SessionExecutionSummary], hasMore: Bool
    ) -> SessionQueryMessagePage {
        let title = reference(session: session, kind: .title)
        let summary = SessionSummary(
            id: session, workspaceID: nil, title: title, titleInvalidated: false, revision: 1,
            isArchived: false, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
            activeExecutionID: executions.last(where: { $0.completion == nil })?.id,
            latestExecutionID: executions.max(by: { $0.sequence < $1.sequence })?.id,
            head: .init(
                cursor: .init(
                    sessionID: session,
                    sequence: (messages.map(\.summary.sequence) + executions.map(\.sequence) + [1]).max()!),
                batchID: UUID()))
        return .init(
            session: .init(summary: summary, title: .available("Test")), messages: messages, executions: executions,
            hasMore: hasMore)
    }

    private func message(
        session: ConversationID, sequence: Int64, role: SessionMessageRole, text: String,
        executionID: ExecutionID = .init(), id: MessageID = .init(), body: SessionTextContent? = nil
    ) -> SessionQueryMessage {
        let body = body ?? .available(text)
        let bodyReference: SessionPayloadReference? = {
            switch body {
            case .absent: return nil
            case .available(_), .purged:
                return reference(session: session, kind: role == .assistant ? .visibleAnswer : .userText)
            }
        }()
        return .init(
            summary: .init(
                id: id, sessionID: session, executionID: executionID, role: role,
                sequence: sequence, occurredAt: Date(timeIntervalSince1970: Double(sequence)), body: bodyReference,
                thinking: nil,
                bodyInvalidated: body == .purged, thinkingInvalidated: false, isExcludedFromContext: false),
            body: body, thinking: .absent)
    }

    private func execution(
        session: ConversationID, sequence: Int64, executionID: ExecutionID = .init(),
        userMessageID: MessageID = .init(), retryOfExecutionID: ExecutionID? = nil,
        completion: SessionCompletion? = nil
    ) -> SessionExecutionSummary {
        let plan = reference(session: session, kind: .executionPlan)
        let user = reference(session: session, kind: .userText)
        let admission = SessionAdmission(
            executionID: executionID, userMessageID: userMessageID, retryOfExecutionID: retryOfExecutionID,
            userBody: retryOfExecutionID == nil ? user : nil,
            plan: plan, hasModelRoute: false, authorizationEpoch: 0, timeZoneIdentifier: "UTC")
        return .init(
            sessionID: session, admission: admission, sequence: sequence,
            admittedAt: Date(timeIntervalSince1970: Double(sequence)), phase: .waitingForModel,
            completion: completion, isExcludedFromContext: false)
    }

    private func reference(session: ConversationID, kind: SessionPayloadKind) -> SessionPayloadReference {
        .init(
            id: UUID(), sessionID: session, batchID: UUID(), retentionGroup: UUID(), kind: kind,
            byteCount: 1, digest: String(repeating: "0", count: 64))
    }
}
