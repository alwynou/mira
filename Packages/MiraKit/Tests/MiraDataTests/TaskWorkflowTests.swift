import Foundation
import GRDB
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Task workflow through agent modules")
struct TaskWorkflowTests {
    @Test(arguments: [false, true])
    func dateOmittedReminderCommitsThroughTheRealToolPipeline(chinese: Bool) async throws {
        let quote = chinese ? "提醒我下午6点取快递" : "remind me at 6pm to review notes" // i18n-fixture: Synthetic Chinese reproduction with unrelated task content.
        let title = chinese ? "取快递" : "review notes" // i18n-fixture: Synthetic Chinese task title.
        let args = taskArguments(title: title, remind: true, time: "18:00", dayOffset: 0)
        try await withTaskWorkflow(outputs: taskReplies(args), permission: .denied) { f in
            let address = try await f.run(quote)
            let task = try #require(try await f.tasks.tasks(workspaceID: nil).first)
            #expect(task.draft.reminderAt?.ISO8601Format() == "2027-01-15T10:00:00Z")
            #expect(try await f.tasks.proposals(workspaceID: nil).isEmpty)
            let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
            let result = try await SessionCodec.decode(JSONValue.self, from: f.library.read(#require(state.invocations.values.first?.resolution?.result)))
            #expect(result["record_saved"] == .bool(true))
            #expect(result["task"]?["delivery_state"] == .string("pending"))
            #expect(result["requires_review"] == nil)
            try await f.reminders.reconcile()
            #expect(try await f.store.taskDetail(task.id, workspaceID: nil).deliveryState == .permissionRequired)
            #expect(await f.notifications.pending().isEmpty)
        }
    }

    @Test(arguments: [
        ("remind me at 09:00 to review notes", "09:00", "timeElapsed"),
        ("remind me at the agreed time", "25:00", "timeUnclear"),
        ("remind me later to review notes", "", "timeUnclear")
    ])
    func timeReviewReturnsActionableReasonAndRequiresExplicitCorrection(_ input: (String, String, String)) async throws {
        let args = taskArguments(remind: true, time: input.1.isEmpty ? nil : input.1, dayOffset: 0)
        try await withTaskWorkflow(outputs: taskReplies(args)) { f in
            let address = try await f.run(input.0)
            #expect(try await f.tasks.tasks(workspaceID: nil).isEmpty)
            let proposal = try #require(try await f.tasks.proposals(workspaceID: nil).first)
            #expect(proposal.requiresTimeClarification)
            let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
            let result = try await SessionCodec.decode(JSONValue.self, from: f.library.read(#require(state.invocations.values.first?.resolution?.result)))
            #expect(result["review_reason"] == .string(input.2))
            #expect(result["requires_time_clarification"] == .bool(true))
            #expect(result["message"]?.stringValue?.contains("No task change or notification has been committed.") == true)
            await #expect(throws: MiraError.self) {
                try await f.tasks.resolve(id: proposal.id, workspaceID: nil, accept: true)
            }
        }
    }

    @Test func timeReviewForDueDateDoesNotAddReminder() async throws {
        let args = taskArguments(remind: false,
                                 time: "25:00", dayOffset: 0)
        try await withTaskWorkflow(outputs: taskReplies(args)) { f in
            _ = try await f.run("create a task with a due date")
            let proposal = try #require(try await f.tasks.proposals(workspaceID: nil).first)
            #expect(!proposal.requiresTimeClarification)
            #expect(proposal.draft.reminderAt == nil)
        }
    }

    @Test(arguments: [false, true])
    func followUpClarificationUsesConversationAndHostBoundEvidence(chinese: Bool) async throws {
        let request = chinese ? "提醒我晚些时候去取包裹" : "Remind me to collect the parcel later" // i18n-fixture: Synthetic incomplete reminder.
        let clarification = chinese ? "今天下午七点半就行" : "Today at half past seven, please" // i18n-fixture: Follow-up omits the task title and action.
        let title = chinese ? "取包裹" : "Parcel pickup" // i18n-fixture: Normalized title from the earlier request.
        let replies = [modelTextStream("What date and time should I use?")]
            + (try taskReplies(taskArguments(title: title, remind: true, time: "19:30", dayOffset: 0)))
        try await withTaskWorkflow(outputs: replies) { f in
            let first = try await f.run(request)
            #expect(try await f.tasks.tasks(workspaceID: nil).isEmpty)
            let followUp = try await f.run(clarification, sessionID: first.sessionID)
            let task = try #require(try await f.tasks.tasks(workspaceID: nil).first)
            #expect(task.draft.title == title)
            #expect(task.draft.reminderAt?.ISO8601Format() == "2027-01-15T11:30:00Z")
            #expect(task.evidence == TaskEvidence(try await f.evidence(followUp)))
            #expect(task.evidence?.quote == clarification)
            #expect(try await f.tasks.proposals(workspaceID: nil).isEmpty)
            let input = try #require(await f.model.inputs.dropFirst().first)
            #expect(input.messages.contains { $0.role == .user && $0.text == request })
            #expect(input.messages.contains { $0.role == .user && $0.text == clarification })
        }
    }

    @Test func acceptsPendingProposalBeyondLegacyFirstHundredAndRejectsRepeatedReview() async throws {
        let quote = "remind me tomorrow to review notes"
        try await withTaskWorkflow(outputs: taskReplies(taskArguments(remind: true))) { f in
            let address = try await f.run(quote)
            let original = try await f.evidence(address)
            let oldest: TaskProposal = try await f.database.read { db in
                let json = try String.fetchOne(db, sql: "SELECT proposal_json FROM task_proposals ORDER BY rowid ASC LIMIT 1") ?? ""
                return try SessionCodec.decode(TaskProposal.self, from: Data(json.utf8))
            }
            try await f.database.write { db in
                for index in 0..<100 {
                    var extra = oldest
                    extra.id = UUID()
                    extra.createdAt = TaskWorkflowFixture.now.addingTimeInterval(TimeInterval(index + 1))
                    let encoded = try String(data: SessionCodec.encode(extra), encoding: .utf8) ?? ""
                    try db.execute(sql: "INSERT INTO task_proposals (id, workspace_id, state, proposal_json) VALUES (?, NULL, 'pending', ?)", arguments: [extra.id.uuidString.lowercased(), encoded])
                }
            }

            let corrected = TaskDraft(title: oldest.draft.title, dueAt: TaskWorkflowFixture.now.addingTimeInterval(3600),
                                      reminderAt: TaskWorkflowFixture.now.addingTimeInterval(3600), timeZoneID: oldest.draft.timeZoneID)
            let receipt = try await f.tasks.resolve(id: oldest.id, workspaceID: nil, accept: true, correctedDraft: corrected)
            #expect(receipt.task != nil)
            #expect(try await f.store.taskProposal(oldest.id, workspaceID: nil).state == .accepted)
            #expect(try await f.store.taskProposalPage(workspaceID: nil, offset: 0, limit: 200).items.count == 100)
            await #expect(throws: MiraError.self) {
                try await f.tasks.resolve(id: oldest.id, workspaceID: nil, accept: true, correctedDraft: corrected)
            }

            // The source came from the exact journal evidence, proving the old list truncation was bypassed safely.
            #expect(original.reference == oldest.evidence.source)
        }
    }

    @Test func englishReminderCommitsExactJournalSourceBeforeScheduling() async throws {
        let quote = "remind me tomorrow at 09:30 to review notes"
        let args = taskArguments(remind: true, time: "09:30", dayOffset: 1)
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
        let args = taskArguments(title: "整理报告", remind: true, // i18n-fixture: original Chinese task title.
                                 time: "09:30", dayOffset: 1) // i18n-fixture: Chinese relative-time expression.
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
        try await withTaskWorkflow(outputs: taskReplies(taskArguments(remind: true))) { f in
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
        try await withTaskWorkflow(outputs: taskReplies(taskArguments(), count: 2)) { f in
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
        let replies = try taskReplies(taskArguments())
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
        let replies = try taskReplies(taskArguments())
        try await withTaskWorkflow(outputs: replies + replies) { f in
            let message = MessageID()
            _ = try await f.run(quote, messageID: message)
            _ = try await f.run(quote, messageID: message)
            let tasks = try await f.tasks.tasks(workspaceID: nil)
            #expect(tasks.count == 2)
            #expect(Set(tasks.compactMap { $0.evidence?.source.sessionID }).count == 2)
        }
    }

    @Test func modelCannotOverrideHostSourceEvidence() async throws {
        guard case .object(var fields) = taskArguments() else { Issue.record("Missing command fields"); return }
        fields["quote"] = .string("a forged source")
        try await withTaskWorkflow(outputs: taskReplies(.object(fields))) { f in
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
        try await withTaskWorkflow(outputs: taskReplies(taskArguments())) { f in
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
