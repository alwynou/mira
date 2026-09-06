import Foundation
import Testing
import MiraCore
import MiraData

@Suite("Task workflow")
struct TaskWorkflowTests {
    @Test func englishReminderCommitsExactSourceAndSchedules() async throws {
        let quote = "remind me tomorrow at 09:30 to review notes"
        let arguments = try taskArguments(operation: .create, title: "review notes", quote: quote,
                                          remind: true, timeQuote: "tomorrow at 09:30", time: "09:30", dayOffset: 1)
        let fixture = try TaskWorkflowFixture(replies: toolReplies(arguments: arguments.value))
        defer { fixture.cleanup() }
        let executionID = try await fixture.run(quote: quote)
        try await eventually { try fixture.store.execution(executionID)?.status == .completed }

        let task = try #require(try fixture.store.taskList(workspaceID: nil, includeCompleted: true, limit: 10).first)
        #expect(task.draft.title == "review notes")
        #expect(task.draft.reminderAt != nil)
        #expect(task.deliveryState == .scheduled)
        #expect(task.evidence?.quote == quote)
        #expect(task.evidence?.timeZoneID == TimeZone.current.identifier)
        #expect(await fixture.notifications.pendingCount() == 1)
        await fixture.shutdown()
    }

    @Test func chineseReminderCommitsWithoutTranslatingUserData() async throws {
        // i18n-fixture: Chinese text verifies source matching while preserving user-authored data.
        let quote = "提醒我明天 09:30 整理报告" // i18n-fixture: Chinese source quote exercises localized intent matching.
        let arguments = try taskArguments(operation: .create, title: "整理报告", quote: quote, // i18n-fixture: Chinese task title is user-authored.
                                          remind: true, timeQuote: "明天 09:30", time: "09:30", dayOffset: 1) // i18n-fixture: Chinese relative-time quote.
        let fixture = try TaskWorkflowFixture(replies: toolReplies(arguments: arguments.value))
        defer { fixture.cleanup() }
        let executionID = try await fixture.run(quote: quote)
        try await eventually { try fixture.store.execution(executionID)?.status == .completed }

        let task = try #require(try fixture.store.taskList(workspaceID: nil, includeCompleted: true, limit: 10).first)
        #expect(task.draft.title == "整理报告") // i18n-fixture: user-authored task title.
        #expect(task.evidence?.quote == quote) // i18n-fixture: exact source quote.
        #expect(task.draft.timeZoneID == TimeZone.current.identifier) // i18n-fixture: source timezone is persisted verbatim.
        #expect(task.deliveryState == .scheduled)
        await fixture.shutdown()
    }

    @Test func missingReminderTimeCreatesProposalWithoutTaskOrNotification() async throws {
        let quote = "remind me tomorrow to review notes"
        let arguments = try taskArguments(operation: .create, title: "review notes", quote: quote, remind: true)
        let fixture = try TaskWorkflowFixture(replies: toolReplies(arguments: arguments.value))
        defer { fixture.cleanup() }
        let executionID = try await fixture.run(quote: quote)
        try await eventually { try fixture.store.execution(executionID)?.status == .completed }

        #expect(try fixture.store.taskList(workspaceID: nil, includeCompleted: true, limit: 10).isEmpty)
        let proposal = try #require(try fixture.store.taskProposals(workspaceID: nil).first)
        #expect(proposal.requiresTimeClarification)
        #expect(proposal.draft.reminderAt == nil)
        #expect(await fixture.notifications.pendingCount() == 0)
        do {
            _ = try await fixture.application.resolveTaskProposal(id: proposal.id, workspaceID: nil, accept: true)
            Issue.record("A reminder proposal without a chosen time was accepted.")
        } catch let error as MiraError {
            #expect(error.code == .invalidInput)
        }
        let fireAt = Date().addingTimeInterval(3_600)
        let draft = TaskDraft(title: proposal.draft.title, dueAt: fireAt, reminderAt: fireAt,
                              timeZoneID: proposal.evidence.timeZoneID)
        let receipt = try await fixture.application.resolveTaskProposal(
            id: proposal.id, workspaceID: nil, accept: true, correctedDraft: draft)
        let task = try #require(receipt.task)
        #expect(task.evidence == proposal.evidence)
        #expect(try fixture.store.taskDetail(task.id, workspaceID: nil).deliveryState == .scheduled)
        #expect(try fixture.store.taskProposals(workspaceID: nil).isEmpty)
        #expect(await fixture.notifications.pendingCount() == 1)
        do {
            _ = try await fixture.application.resolveTaskProposal(id: proposal.id, workspaceID: nil, accept: true, correctedDraft: draft)
            Issue.record("A reviewed proposal was accepted twice.")
        } catch let error as MiraError {
            #expect(error.code == .conflict)
        }
        await fixture.shutdown()
    }

    @Test func manualTaskLifecycleUsesCASAndCanReopen() async throws {
        let fixture = try TaskWorkflowFixture()
        defer { fixture.cleanup() }
        let task = try await fixture.application.saveTask(
            id: .init(), workspaceID: nil, draft: TaskDraft(title: "Manual task"), status: .open,
            expectedRevision: nil, operationID: UUID())
        #expect(task.revision == 1)

        do {
            _ = try await fixture.application.saveTask(
                id: task.id, workspaceID: nil, draft: task.draft, status: .completed,
                expectedRevision: task.revision - 1, operationID: UUID())
            Issue.record("A stale task revision was accepted.")
        } catch let error as MiraError {
            #expect(error.code == .conflict)
        }
        let completed = try await fixture.application.saveTask(
            id: task.id, workspaceID: nil, draft: task.draft, status: .completed,
            expectedRevision: task.revision, operationID: UUID())
        let reopened = try await fixture.application.saveTask(
            id: task.id, workspaceID: nil, draft: completed.draft, status: .open,
            expectedRevision: completed.revision, operationID: UUID())
        #expect(reopened.status == .open)
        #expect(reopened.revision == 3)
        #expect(try fixture.store.taskRevisions(task.id, workspaceID: nil).map(\.task.revision) == [3, 2, 1])
        await fixture.shutdown()
    }

    @Test func sameInvocationReplayReturnsExistingReceiptWithoutNewRevision() async throws {
        let quote = "create a task to review notes"
        let arguments = try taskArguments(operation: .create, title: "review notes", quote: quote, remind: false)
        let fixture = try TaskWorkflowFixture(replies: toolReplies(arguments: arguments.value))
        defer { fixture.cleanup() }
        let executionID = try await fixture.run(quote: quote)
        try await eventually { try fixture.store.execution(executionID)?.status == .completed }
        let before = try #require(try fixture.store.taskList(workspaceID: nil, includeCompleted: true, limit: 10).first)
        let execution = try #require(try fixture.store.execution(executionID))
        let invocation = try #require(try fixture.store.toolInvocations(for: executionID).first)
        let message = try #require(try fixture.store.messages(in: execution.conversationID).first(where: { $0.id == execution.triggerMessageID }))
        let mutation = try #require(TaskTools.registered(store: fixture.store).last)
        let context = ToolContext(executionID: executionID, invocationID: invocation.id, workspaceID: nil,
                                  userMessageID: message.id, userText: quote)
        _ = try await mutation.execute(arguments: arguments.value, context: context)

        let after = try #require(try fixture.store.taskDetail(before.id, workspaceID: nil))
        #expect(after.revision == before.revision)
        #expect(try fixture.store.taskRevisions(before.id, workspaceID: nil).count == 1)
        await fixture.shutdown()
    }

    @Test func duplicateCallsForOneSourceShareReceiptEvenAfterCompletion() async throws {
        let quote = "create a task to review notes"
        let arguments = try taskArguments(operation: .create, title: "review notes", quote: quote, remind: false)
        let calls = ["first", "duplicate"].map {
            CanonicalToolCall(id: $0, name: "task.change", arguments: arguments.string)
        }
        let fixture = try TaskWorkflowFixture(replies: [
            [.toolCalls(calls), .finished(.toolCalls)],
            [.textDelta("Task processed"), .finished(.stop)]
        ])
        defer { fixture.cleanup() }
        let executionID = try await fixture.run(quote: quote)
        try await eventually { try fixture.store.execution(executionID)?.status == .completed }
        let execution = try #require(try fixture.store.execution(executionID))
        let invocations = try fixture.store.toolInvocations(for: executionID)
        #expect(invocations.count == 2)
        let tasks = try fixture.store.taskList(workspaceID: nil, includeCompleted: true, limit: 10)
        let task = try #require(tasks.first)
        #expect(tasks.count == 1)
        for invocation in invocations {
            let context = ToolContext(executionID: executionID, invocationID: invocation.id,
                                      workspaceID: nil, userMessageID: execution.triggerMessageID, userText: quote)
            let receipt = try fixture.store.performTaskTool(arguments: arguments.value, context: context, at: Date())
            #expect(receipt.task?.id == task.id)
            #expect(receipt.task?.revision == 1)
        }
        #expect(try fixture.store.taskRevisions(task.id, workspaceID: nil).count == 1)
        await fixture.shutdown()
    }

    @Test func deniedPermissionLeavesPermissionRequiredUntilExplicitRecovery() async throws {
        let fixture = try TaskWorkflowFixture(permission: .denied)
        defer { fixture.cleanup() }
        let fireAt = Date().addingTimeInterval(3_600)
        let task = try await fixture.application.saveTask(
            id: .init(), workspaceID: nil, draft: TaskDraft(title: "Permission task", reminderAt: fireAt),
            status: .open, expectedRevision: nil, operationID: UUID())
        #expect(task.deliveryState == .permissionRequired)
        #expect(await fixture.notifications.installCount() == 0)

        await fixture.notifications.setPermission(.allowed)
        await fixture.notifications.setRequestResult(true)
        #expect(try await fixture.application.requestNotificationAuthorization())
        let scheduled = try #require(try fixture.store.taskDetail(task.id, workspaceID: nil))
        #expect(scheduled.deliveryState == .scheduled)
        #expect(await fixture.notifications.installCount() == 1)
        await fixture.shutdown()
    }

    @Test func reminderUpdateInstallsNewRevisionAndCancelRemovesIt() async throws {
        let fixture = try TaskWorkflowFixture(permission: .allowed)
        defer { fixture.cleanup() }
        let firstTime = Date().addingTimeInterval(3_600)
        let first = try await fixture.application.saveTask(
            id: .init(), workspaceID: nil, draft: TaskDraft(title: "Move meeting", reminderAt: firstTime),
            status: .open, expectedRevision: nil, operationID: UUID())
        let secondTime = firstTime.addingTimeInterval(3_600)
        let updated = try await fixture.application.saveTask(
            id: first.id, workspaceID: nil, draft: TaskDraft(title: "Move meeting", reminderAt: secondTime),
            status: .open, expectedRevision: first.revision, operationID: UUID())
        #expect(updated.revision == first.revision + 1)
        let installed = try #require(await fixture.notifications.pending().first)
        #expect(installed.fireAt == updated.draft.reminderAt)
        #expect(installed.revision == updated.revision)

        let cancelled = try await fixture.application.saveTask(
            id: updated.id, workspaceID: nil, draft: updated.draft, status: .cancelled,
            expectedRevision: updated.revision, operationID: UUID())
        #expect(cancelled.deliveryState == .cancelled)
        #expect(await fixture.notifications.pendingCount() == 0)
        #expect(await fixture.notifications.removeCount() >= 1)
        await fixture.shutdown()
    }

    @Test func restoredReminderIsPausedAndCanBeResumed() async throws {
        let fixture = try TaskWorkflowFixture(permission: .allowed)
        defer { fixture.cleanup() }
        let task = try await fixture.application.saveTask(
            id: .init(), workspaceID: nil,
            draft: TaskDraft(title: "Restore reminder", reminderAt: Date().addingTimeInterval(3_600)),
            status: .open, expectedRevision: nil, operationID: UUID())
        let backup = fixture.directory.appendingPathComponent("backup")
        try fixture.store.exportBackup(to: backup)
        await fixture.shutdown()

        let restoredDirectory = fixture.directory.appendingPathComponent("restored")
        try fixture.store.restoreBackup(from: backup, to: restoredDirectory)
        let restoredStore = try SQLiteMiraStore(directory: restoredDirectory)
        let paused = try #require(try restoredStore.taskDetail(task.id, workspaceID: nil))
        #expect(paused.deliveryState == .paused)
        let restoredNotifications = FakeLocalNotificationPort(permission: .allowed)
        let restoredScheduler = ReminderScheduler(store: restoredStore, notifications: restoredNotifications, namespace: "restore")
        let restoredApp = try MiraApplication(store: restoredStore, provider: NoTaskProvider(), reminders: restoredScheduler)
        try await restoredApp.resumeReminder(task.id, workspaceID: nil, expectedRevision: paused.revision)
        let resumed = try #require(try restoredStore.taskDetail(task.id, workspaceID: nil))
        #expect(resumed.deliveryState == .scheduled)
        #expect(await restoredNotifications.pendingCount() == 1)
        await restoredApp.shutdown()
        try? FileManager.default.removeItem(at: restoredDirectory)
    }

    @Test func delayedScheduleEditCannotLeaveStaleNotificationInstalled() async throws {
        let fixture = try TaskWorkflowFixture(permission: .allowed)
        defer { fixture.cleanup() }
        let firstTime = Date().addingTimeInterval(3_600)
        let first = try fixture.store.saveTask(
            .init(), workspaceID: nil, draft: TaskDraft(title: "Race reminder", reminderAt: firstTime),
            status: .open, expectedRevision: nil, operationID: UUID(), at: Date())
        await fixture.notifications.blockNextInstall()
        let reconcile = Task { try? await fixture.scheduler.reconcile() }
        await fixture.notifications.waitUntilInstallBlocked()
        let secondTime = firstTime.addingTimeInterval(3_600)
        _ = try fixture.store.saveTask(
            first.id, workspaceID: nil, draft: TaskDraft(title: "Race reminder", reminderAt: secondTime),
            status: .open, expectedRevision: first.revision, operationID: UUID(), at: Date())
        await fixture.notifications.releaseInstall()
        await reconcile.value

        let installed = try #require(await fixture.notifications.pending().first)
        let current = try #require(try fixture.store.taskDetail(first.id, workspaceID: nil))
        #expect(installed.fireAt == current.draft.reminderAt)
        #expect(installed.revision == first.revision + 1)
        #expect(current.deliveryState == .scheduled)
        await fixture.shutdown()
    }
}

private struct TaskWorkflowFixture {
    let directory: URL
    let store: SQLiteMiraStore
    let route: ResolvedModelRouteSnapshot
    let configuration: StoredRouteFixture
    let notifications: FakeLocalNotificationPort
    let scheduler: ReminderScheduler
    let provider: ScriptedTaskProvider
    let application: MiraApplication

    init(replies: [[CanonicalStreamEvent]] = [], permission: NotificationPermission = .allowed) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiraTaskWorkflow-\(UUID())")
        store = try SQLiteMiraStore(directory: directory)
        var snapshot = ResolvedModelRouteSnapshot(name: "Task workflow", providerKind: .openAICompatible,
                                                   baseURL: "https://example.invalid/v1", modelID: "fixture",
                                                   credentialReference: "no-key", contextWindow: 262_144)
        snapshot.toolCapability = .declared
        route = snapshot
        configuration = StoredRouteFixture(snapshot)
        try configuration.install(in: store)
        notifications = FakeLocalNotificationPort(permission: permission)
        scheduler = ReminderScheduler(store: store, notifications: notifications, namespace: "workflow")
        provider = ScriptedTaskProvider(replies: replies)
        let tools = try ToolRegistry(TaskTools.registered(store: store, scheduler: scheduler))
        application = try MiraApplication(store: store, provider: provider, tools: tools, reminders: scheduler)
    }

    func run(quote: String) async throws -> ExecutionID {
        let conversationID = try await application.createConversation(workspaceID: nil)
        return try await application.send(conversationID: conversationID, text: quote, routeID: route.id)
    }

    func shutdown() async { _ = await application.shutdown() }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private func taskArguments(operation: TaskOperation, title: String, quote: String, remind: Bool,
                           timeQuote: String? = nil, time: String? = nil, date: String? = nil,
                           dayOffset: Int? = nil) throws -> (value: JSONValue, string: String) {
    var object: [String: JSONValue] = [
        "operation": .string(operation.rawValue), "title": .string(title), "quote": .string(quote), "remind": .bool(remind)
    ]
    if let timeQuote { object["time_quote"] = .string(timeQuote) }
    if let time { object["time"] = .string(time) }
    if let date { object["date"] = .string(date) }
    if let dayOffset { object["day_offset"] = .number(Double(dayOffset)) }
    let value = JSONValue.object(object)
    return (value, try value.jsonString())
}

private func toolReplies(arguments: JSONValue) -> [[CanonicalStreamEvent]] {
    [[.toolCalls([CanonicalToolCall(id: "task-call", name: "task.change", arguments: (try? arguments.jsonString()) ?? "{}")]), .finished(.toolCalls)],
     [.textDelta("Task processed"), .finished(.stop)]]
}

private final class ScriptedTaskProvider: ModelProviderPort, @unchecked Sendable {
    private let lock = NSLock()
    private let replies: [[CanonicalStreamEvent]]
    private var index = 0

    init(replies: [[CanonicalStreamEvent]]) { self.replies = replies }

    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        let response = lock.withLock {
            defer { index += 1 }
            return index < replies.count ? replies[index] : [.finished(.stop)]
        }
        return AsyncThrowingStream { continuation in
            response.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

private struct NoTaskProvider: ModelProviderPort {
    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        AsyncThrowingStream { continuation in continuation.finish(throwing: MiraError(.unsupported, "No model request expected.")) }
    }
}

private actor FakeLocalNotificationPort: LocalNotificationPort {
    private var permissionState: NotificationPermission
    private var requestResult = false
    private var installed: [String: ReminderNotification] = [:]
    private var installs = 0
    private var removes = 0
    private var blockInstall = false
    private var installBlocked = false
    private var installContinuation: CheckedContinuation<Void, Never>?

    init(permission: NotificationPermission) { permissionState = permission }

    func permission() async -> NotificationPermission { permissionState }
    func requestPermission() async throws -> Bool {
        if requestResult { permissionState = .allowed }
        return requestResult
    }
    func pending() async -> [ReminderNotification] { Array(installed.values) }
    func install(_ notification: ReminderNotification) async throws {
        installs += 1
        if blockInstall {
            blockInstall = false
            installBlocked = true
            await withCheckedContinuation { continuation in installContinuation = continuation }
            installBlocked = false
        }
        installed[notification.identifier] = notification
    }
    func remove(_ identifier: String) async { removes += 1; installed[identifier] = nil }

    func setPermission(_ permission: NotificationPermission) { permissionState = permission }
    func setRequestResult(_ result: Bool) { requestResult = result }
    func pendingCount() -> Int { installed.count }
    func installCount() -> Int { installs }
    func removeCount() -> Int { removes }
    func blockNextInstall() { blockInstall = true }
    func waitUntilInstallBlocked() async {
        while !installBlocked { try? await Task.sleep(for: .milliseconds(1)) }
    }
    func releaseInstall() {
        installContinuation?.resume()
        installContinuation = nil
    }
}

private func eventually(_ predicate: @Sendable () throws -> Bool) async throws {
    for _ in 0..<500 {
        if try predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw MiraError(.timeout, "Synthetic task workflow condition timed out.")
}
