import Foundation
import GRDB
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Task workflow through agent modules")
struct TaskWorkflowTests {
    @Test func englishReminderCommitsExactJournalSourceBeforeScheduling() async throws {
        let quote = "remind me tomorrow at 09:30 to review notes"
        let args = taskArguments(quote: quote, remind: true, timeQuote: "tomorrow at 09:30", time: "09:30", dayOffset: 1)
        try await withTaskWorkflow(outputs: taskReplies(args)) { f in
            let address = try await f.run(quote)
            let original = try await f.evidence(address)
            let task = try #require(try await f.tasks.tasks(workspaceID: nil).first)
            #expect(task.evidence == TaskEvidence(original))
            #expect(task.evidence?.source.sessionID == address.sessionID)
            #expect(task.evidence?.source.originalExecutionID == address.executionID)
            #expect(task.draft.title == "review notes")
            #expect(task.draft.reminderAt != nil)
            #expect(task.deliveryState == .pending)
            #expect(await f.notifications.installs == 0)
            try await f.reminders.reconcile()
            #expect(try await f.store.taskDetail(task.id, workspaceID: nil).deliveryState == .scheduled)
            #expect(await f.notifications.pending().count == 1)
            #expect(try await f.database.read { db in
                try ["messages", "conversations", "executions", "message_time_context"].allSatisfy { try !db.tableExists($0) }
            })
        }
    }

    @Test func chineseReminderPreservesOriginalUserDataAndTimeZone() async throws {
        let quote = "提醒我明天 09:30 整理报告" // i18n-fixture: original Chinese user request.
        let args = taskArguments(title: "整理报告", quote: quote, remind: true, // i18n-fixture: original Chinese task title.
                                 timeQuote: "明天 09:30", time: "09:30", dayOffset: 1) // i18n-fixture: Chinese relative-time expression.
        try await withTaskWorkflow(outputs: taskReplies(args)) { f in
            _ = try await f.run(quote, timeZone: "Asia/Shanghai")
            let task = try #require(try await f.tasks.tasks(workspaceID: nil).first)
            #expect(task.draft.title == "整理报告") // i18n-fixture: user-authored title remains verbatim.
            #expect(task.evidence?.quote == quote)
            #expect(task.evidence?.sentAt == TaskWorkflowFixture.now)
            #expect(task.draft.timeZoneID == "Asia/Shanghai")
            try await f.reminders.reconcile()
            #expect(try await f.store.taskDetail(task.id, workspaceID: nil).deliveryState == .scheduled)
        }
    }

    @Test func unknownTimeRequiresFreshJournalEvidenceAndExplicitCorrection() async throws {
        let quote = "remind me tomorrow to review notes"
        try await withTaskWorkflow(outputs: taskReplies(taskArguments(quote: quote, remind: true))) { f in
            _ = try await f.run(quote)
            #expect(try await f.tasks.tasks(workspaceID: nil).isEmpty)
            let proposal = try #require(try await f.tasks.proposals(workspaceID: nil).first)
            #expect(proposal.requiresTimeClarification)
            #expect(proposal.draft.reminderAt == nil)
            #expect(await f.notifications.pending().isEmpty)
            await #expect(throws: MiraError.self) { try await f.tasks.resolve(id: proposal.id, workspaceID: nil, accept: true) }
            let time = TaskWorkflowFixture.now.addingTimeInterval(3600)
            let corrected = TaskDraft(title: proposal.draft.title, dueAt: time, reminderAt: time, timeZoneID: proposal.evidence.timeZoneID)
            let receipt = try await f.tasks.resolve(id: proposal.id, workspaceID: nil, accept: true, correctedDraft: corrected)
            let task = try #require(receipt.task)
            #expect(task.evidence == proposal.evidence)
            #expect(task.deliveryState == .pending)
            #expect(try await f.tasks.proposals(workspaceID: nil).isEmpty)
            await #expect(throws: MiraError.self) {
                try await f.tasks.resolve(id: proposal.id, workspaceID: nil, accept: true, correctedDraft: corrected)
            }
            try await f.reminders.reconcile()
            #expect(try await f.store.taskDetail(task.id, workspaceID: nil).deliveryState == .scheduled)
        }
    }

    @Test func manualOperationsUseCASAndStableOperationIdentity() async throws {
        try await withTaskWorkflow { f in
            let id = MiraTaskID(), operation = UUID(), draft = TaskDraft(title: "Manual task")
            let first = try await f.save(id: id, draft: draft, operationID: operation)
            #expect(try await f.save(id: id, draft: draft, operationID: operation) == first)
            await #expect(throws: MiraError.self) {
                try await f.save(id: id, draft: .init(title: "Changed"), operationID: operation)
            }
            await #expect(throws: MiraError.self) {
                try await f.save(id: id, draft: draft, status: .completed, expectedRevision: 0)
            }
            let completed = try await f.save(id: id, draft: draft, status: .completed, expectedRevision: 1)
            let reopened = try await f.save(id: id, draft: draft, expectedRevision: completed.revision)
            #expect(reopened.status == .open && reopened.revision == 3)
            #expect(try await f.store.taskRevisions(id, workspaceID: nil).map(\.task.revision) == [3, 2, 1])
        }
    }

    @Test func duplicateToolCallsShareOneBusinessOperationAndReplayAfterCompletion() async throws {
        let quote = "create a task to review notes"
        try await withTaskWorkflow(outputs: taskReplies(taskArguments(quote: quote), count: 2)) { f in
            let address = try await f.run(quote)
            let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
            #expect(state.invocations.count == 2)
            let tasks = try await f.tasks.tasks(workspaceID: nil)
            #expect(tasks.count == 1)
            let task = try #require(tasks.first)
            for invocation in state.invocations.values {
                let intent = try #require(invocation.intent)
                let proof = AgentEffectProof(sessionID: address.sessionID, executionID: address.executionID,
                    invocationID: invocation.invocation.id, intentBatchID: intent.batchID, intentSequence: intent.sequence,
                    authorization: intent.intent.authorization, proposal: intent.intent.proposal)
                guard case .committed(let receipt) = await f.business.commit(proof) else {
                    Issue.record("Completed invocation lost its durable receipt"); continue
                }
                let result = try SessionCodec.decode(JSONValue.self, from: #require(receipt.result))
                #expect(result["task"]?["id"]?.stringValue == task.id.rawValue.uuidString.lowercased())
            }
            #expect(try await f.store.taskRevisions(task.id, workspaceID: nil).count == 1)
            #expect(try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM business_operations") } == 1)
            #expect(try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM business_receipts") } == 2)
        }
    }

    @Test func receiptFailureRollsBackTaskRevisionAndBusinessResultTogether() async throws {
        let quote = "create a task to review notes"
        let replies = try taskReplies(taskArguments(quote: quote))
        try await withTaskWorkflow(outputs: replies + replies) { f in
            try await f.database.write {
                try $0.execute(sql: "CREATE TRIGGER reject_task_receipt BEFORE INSERT ON business_receipts BEGIN SELECT RAISE(ABORT, 'Synthetic receipt failure'); END")
            }
            let failed = try await f.run(quote)
            let state = try await f.runtime.sessionSnapshot(id: failed.sessionID)
            #expect(state.invocations.values.first?.resolution?.status == .failed)
            #expect(try await f.tasks.tasks(workspaceID: nil).isEmpty)
            for table in ["mira_tasks", "task_revisions", "business_operations", "business_receipts"] {
                #expect(try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(table)") } == 0)
            }
            try await f.database.write { try $0.execute(sql: "DROP TRIGGER reject_task_receipt") }
            _ = try await f.run(quote)
            #expect(try await f.tasks.tasks(workspaceID: nil).count == 1)
        }
    }

    @Test func sameMessageUUIDInDistinctSessionsDoesNotDeduplicateSources() async throws {
        let quote = "create a task to review notes"
        let replies = try taskReplies(taskArguments(quote: quote))
        try await withTaskWorkflow(outputs: replies + replies) { f in
            let message = MessageID()
            _ = try await f.run(quote, messageID: message)
            _ = try await f.run(quote, messageID: message)
            let tasks = try await f.tasks.tasks(workspaceID: nil)
            #expect(tasks.count == 2)
            #expect(Set(tasks.compactMap { $0.evidence?.source.sessionID }).count == 2)
        }
    }

    @Test func forgedWholeQuoteCannotCreateTaskOrProposal() async throws {
        try await withTaskWorkflow(outputs: taskReplies(taskArguments(quote: "create a task to review notes"))) { f in
            _ = try await f.run("Tell me how task lists work")
            #expect(try await f.tasks.tasks(workspaceID: nil).isEmpty)
            #expect(try await f.tasks.proposals(workspaceID: nil).isEmpty)
            #expect(try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM business_receipts") } == 0)
        }
    }

    @Test func listDisclosesOnlyItsWorkspaceAndRecordsExactSources() async throws {
        let replies: [[AgentModelStreamEvent]] = [modelToolStream([.init(id: "list", name: "task.list", arguments: "{}")]),
                                                   [.blockStarted(.init(id: "text", content: .text("Listed tasks"))), .blockFinished(id: "text"), .finished(.stop)]]
        try await withTaskWorkflow(outputs: replies) { f in
            let workspace = Workspace(id: .init(), name: "Private scope")
            let lease = try await f.access.acquire(in: f.scope)
            do { try await f.workspaces.saveWorkspace(workspace, expectedRevision: nil, authorization: lease.authorization) }
            catch { await lease.release(); throw error }
            await lease.release()
            _ = try await f.save(draft: .init(title: "Inbox only"))
            let scoped = try await f.save(workspaceID: workspace.id, draft: .init(title: "Workspace only"))
            let address = try await f.run("List tasks", workspaceID: workspace.id)
            let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
            let invocation = try #require(state.invocations.values.first)
            #expect(invocation.resolution?.status == .succeeded)
            let result = try await SessionCodec.decode(JSONValue.self, from: f.library.read(#require(invocation.resolution?.result)))
            guard case .array(let listed) = result["tasks"] else { Issue.record("Task list result is absent"); return }
            #expect(listed.count == 1)
            #expect(listed.first?["id"]?.stringValue == scoped.id.rawValue.uuidString.lowercased())
            #expect(result["reference_time"]?.stringValue == TaskWorkflowFixture.now.ISO8601Format())
            let proposal = try await SessionCodec.decode(AgentToolProposal.self, from: f.library.read(#require(invocation.intent?.intent.proposal)))
            #expect(proposal.plan.sources == [.domain(namespace: "tasks", id: scoped.id.rawValue, revision: 1)])
        }
    }

    @Test(arguments: ["workspace", "connection"])
    func currentPolicyAndFrozenRouteAreRecheckedBeforeModelPreparation(revoked: String) async throws {
        let quote = "create a task to review notes"
        try await withTaskWorkflow(outputs: taskReplies(taskArguments(quote: quote))) { f in
            var workspaceID: WorkspaceID?
            if revoked == "workspace" {
                let workspace = Workspace(id: .init(), name: "Local scope", allowsRemoteSend: false)
                workspaceID = workspace.id
                let lease = try await f.access.acquire(in: f.scope)
                do { try await f.workspaces.saveWorkspace(workspace, expectedRevision: nil, authorization: lease.authorization) }
                catch { await lease.release(); throw error }
                await lease.release()
            } else {
                let old = try #require(try await f.settings.connection(id: f.route.connectionID))
                try await f.settings.saveConnection(.init(id: old.id, revision: old.revision + 1,
                    configurationRevision: old.configurationRevision + 1, name: old.name, isEnabled: false,
                    definitionID: old.definitionID, endpoints: old.endpoints, discovery: old.discovery,
                    defaultInvocation: old.defaultInvocation), expectedRevision: old.revision,
                    authorization: f.authority.authorization())
            }
            let address = try await f.run(quote, workspaceID: workspaceID, expectedStatus: .failed)
            let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
            #expect(state.invocations.isEmpty)
            #expect(await f.model.inputs.isEmpty)
            #expect(try await f.tasks.tasks(workspaceID: workspaceID).isEmpty)
            #expect(try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM business_receipts") } == 0)
        }
    }

    @Test func proposalCannotBeAcceptedAfterOriginalJournalEvidenceIsInvalidated() async throws {
        let quote = "remind me tomorrow to review notes"
        try await withTaskWorkflow(outputs: taskReplies(taskArguments(quote: quote, remind: true))) { f in
            let address = try await f.run(quote)
            let proposal = try #require(try await f.tasks.proposals(workspaceID: nil).first)
            #expect(await f.runtime.shutdown().isSettled)
            let session = try await SessionRuntime.open(id: address.sessionID, journal: f.library, payloads: f.library)
            do {
                let state = await session.snapshot()
                let groups = Set(state.references.values.filter { $0.kind != .title }.map(\.retentionGroup))
                try taskRequireCommitted(await session.commit(id: UUID()) { _ in
                    [.invalidated(.init(operationID: UUID(), executionIDs: [address.executionID], retentionGroups: groups,
                                        authorizationEpoch: state.authorizationEpoch + 1, reason: .forgotten))]
                })
                await session.close()
            } catch { await session.close(); throw error }
            await #expect(throws: MiraError.self) {
                try await f.tasks.resolve(id: proposal.id, workspaceID: nil, accept: true,
                    correctedDraft: .init(title: proposal.draft.title, reminderAt: TaskWorkflowFixture.now.addingTimeInterval(3600)))
            }
            #expect(try await f.tasks.tasks(workspaceID: nil).isEmpty)
            #expect(try await f.tasks.proposals(workspaceID: nil).count == 1)
            _ = try await f.tasks.resolve(id: proposal.id, workspaceID: nil, accept: false)
            #expect(try await f.tasks.proposals(workspaceID: nil).isEmpty)
        }
    }

    @Test func deniedPermissionPreservesSavedRecordUntilExplicitPermissionRequest() async throws {
        try await withTaskWorkflow(permission: .denied) { f in
            let task = try await f.save(draft: .init(title: "Permission task", reminderAt: TaskWorkflowFixture.now.addingTimeInterval(3600)))
            try await f.reminders.reconcile()
            #expect(try await f.store.taskDetail(task.id, workspaceID: nil).deliveryState == .permissionRequired)
            #expect(await f.notifications.installs == 0)
            #expect(try await f.reminders.requestPermission())
            try await f.reminders.reconcile()
            #expect(try await f.store.taskDetail(task.id, workspaceID: nil).deliveryState == .scheduled)
        }
    }

    @Test func editInstallsNewRevisionAndCancellationRemovesNotification() async throws {
        try await withTaskWorkflow { f in
            let time = TaskWorkflowFixture.now.addingTimeInterval(3600)
            let first = try await f.save(draft: .init(title: "Move meeting", reminderAt: time))
            try await f.reminders.reconcile()
            let updated = try await f.save(id: first.id, draft: .init(title: "Move meeting", reminderAt: time.addingTimeInterval(3600)), expectedRevision: 1)
            try await f.reminders.reconcile()
            let installed = try #require(await f.notifications.pending().first)
            #expect(installed.revision == updated.revision && installed.fireAt == updated.draft.reminderAt)
            _ = try await f.save(id: first.id, draft: updated.draft, status: .cancelled, expectedRevision: 2)
            try await f.reminders.reconcile()
            #expect(await f.notifications.pending().isEmpty)
            #expect(try await f.store.taskDetail(first.id, workspaceID: nil).deliveryState == .cancelled)
        }
    }

    @Test func restoredDesiredStateRemainsPausedUntilExplicitResume() async throws {
        // This exercises the restore-domain operation, not the still-pending whole-library backup protocol.
        try await withTaskWorkflow { f in
            let task = try await f.save(draft: .init(title: "Restored reminder", reminderAt: TaskWorkflowFixture.now.addingTimeInterval(3600)))
            try await f.database.write { try SQLiteTaskStore.pauseRestoredReminders(in: $0) }
            try await f.reminders.reconcile()
            #expect(try await f.store.taskDetail(task.id, workspaceID: nil).deliveryState == .paused)
            #expect(await f.notifications.pending().isEmpty)
            try await f.tasks.resumeReminder(id: task.id, workspaceID: nil, expectedRevision: task.revision)
            try await f.reminders.reconcile()
            #expect(try await f.store.taskDetail(task.id, workspaceID: nil).deliveryState == .scheduled)
        }
    }

    @Test func editDuringNoncooperatingInstallConvergesToCurrentRevision() async throws {
        try await withTaskWorkflow { f in
            let time = TaskWorkflowFixture.now.addingTimeInterval(3600)
            let first = try await f.save(draft: .init(title: "Race reminder", reminderAt: time))
            await f.notifications.blockNextInstall()
            let reconcile = Task { try await f.reminders.reconcile() }
            do {
                try await taskEventually { await f.notifications.blocked }
                let second = try await f.save(id: first.id, draft: .init(title: "Race reminder", reminderAt: time.addingTimeInterval(3600)), expectedRevision: 1)
                await f.notifications.releaseInstall()
                try await reconcile.value
                let installed = try #require(await f.notifications.pending().first)
                #expect(installed.revision == second.revision && installed.fireAt == second.draft.reminderAt)
                #expect(try await f.store.taskDetail(first.id, workspaceID: nil).deliveryState == .scheduled)
            } catch { await f.notifications.releaseInstall(); _ = await reconcile.result; throw error }
        }
    }

    @Test func maintenanceWaitsForRealNotificationExitAndRejectsStaleTaskWrites() async throws {
        try await withTaskWorkflow { f in
            let task = try await f.save(draft: .init(title: "Held reminder", reminderAt: TaskWorkflowFixture.now.addingTimeInterval(3600)))
            let authorization = await f.access.snapshot().authorization
            await f.notifications.blockNextInstall()
            let reconciling = Task { try await f.reminders.reconcile() }
            let probe = TaskCloseProbe()
            var closing: Task<Void, Never>?
            do {
                try await taskEventually { await f.notifications.blocked }
                let operation = try await f.access.begin(.init(id: UUID(), namespace: "tasks.test", revision: 1,
                    scope: .library, requestedAt: TaskWorkflowFixture.now), expected: authorization)
                closing = Task { await f.reminders.close(); await probe.mark() }
                #expect(await f.access.snapshot().activeLeases >= 1)
                #expect(await probe.finished == false)
                await #expect(throws: MiraError.self) {
                    try await f.store.saveTask(task.id, workspaceID: nil, draft: task.draft, status: .completed,
                        expectedRevision: task.revision, operationID: UUID(), authorization: authorization, at: TaskWorkflowFixture.now)
                }
                await f.notifications.releaseInstall()
                _ = await reconciling.result; await closing?.value
                #expect(await probe.finished)
                #expect(await f.runtime.shutdown().isSettled)
                try await f.access.waitForQuiescence()
                _ = try await f.access.complete(operation, at: TaskWorkflowFixture.now)
                let loaded = try await f.store.taskDetail(task.id, workspaceID: nil)
                #expect(loaded.status == .open && loaded.deliveryState == .pending)
                // A late external installation exists until a maintenance handler removes it.
                #expect(await f.notifications.pending().count == 1)
                await #expect(throws: MiraError.self) {
                    try await f.store.saveTask(task.id, workspaceID: nil, draft: task.draft, status: .completed,
                        expectedRevision: task.revision, operationID: UUID(), authorization: authorization, at: TaskWorkflowFixture.now)
                }
            } catch { await f.notifications.releaseInstall(); _ = await reconciling.result; await closing?.value; throw error }
        }
    }
}

private actor TaskCloseProbe {
    private(set) var finished = false
    func mark() { finished = true }
}
