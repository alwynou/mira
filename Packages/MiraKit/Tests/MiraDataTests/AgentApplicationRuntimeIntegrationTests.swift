import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Agent application runtime integration")
struct AgentApplicationRuntimeIntegrationTests {
    @Test func sessionSelectionIsJournalAuthoritativeAndAdmissionUsesItsRevision() async throws {
        try await withApplication { fixture in
            let opening = fixture.command()
            try await fixture.open(opening)
            let selected = AgentSessionModelSelection.selected(.init(
                routeID: RouteID(),
                model: .init(connectionID: ConnectionID(), modelID: "remote-model"),
                modelConfigurationID: ModelDescriptorID()))
            try requireCommitted(await fixture.application.selectModel(sessionID: opening.sessionID,
                commandID: UUID(), expectedRevision: 0, selection: selected))
            #expect(try await fixture.application.modelSelection(sessionID: opening.sessionID) == selected)

            let stale = fixture.command(sessionID: opening.sessionID)
            try requireFailure(await fixture.application.submit(stale), .conflict)

            let firstMessage = fixture.command(sessionID: opening.sessionID)
            let withReset = AgentSubmitCommand(id: firstMessage.id, sessionID: firstMessage.sessionID,
                executionID: firstMessage.executionID, input: firstMessage.input, options: firstMessage.options,
                expectedSelectionRevision: 1,
                selectionChange: .init(selection: .inherit, expectedRevision: 1))
            try requireCommitted(await fixture.application.submit(withReset))
            await fixture.driver.waitUntilEntered()
            await fixture.driver.release()
            try requireCommitted(await fixture.application.waitForExecution(id: withReset.executionID,
                sessionID: withReset.sessionID))
            let batch = try #require(try await fixture.library.batch(id: withReset.id, sessionID: withReset.sessionID))
            #expect(batch.events.count == 2)
            #expect(batch.events[0].fact == .modelSelectionChanged(selection: .inherit, expectedRevision: 1))
            #expect((try await fixture.application.sessionSnapshot(id: opening.sessionID)).modelSelection == .inherit)
        }
    }

    @Test func startupAndLaterSessionLoadsUseTheHostsRequiredExtensionSchemas() async throws {
        try await withApplication { fixture in
            #expect(await fixture.application.shutdown().isSettled)
            let schemas: [String: Set<Int>] = ["application.fixture": [1]]
            let session = try await SessionRuntime.open(id: ConversationID(), journal: fixture.library,
                payloads: fixture.library, extensionSchemas: schemas)
            try requireCommitted(await session.commit(id: UUID()) { context in
                let title = try await context.stageBytes(Data("Synthetic extension".utf8), kind: .title, retentionGroup: UUID())
                let body = try await context.stageBytes(Data("Synthetic module data".utf8), kind: .module, retentionGroup: UUID())
                return [.opened(.init(workspaceID: nil, title: title)),
                        .extensionRecorded(namespace: "application.fixture", schemaVersion: 1, required: true, body: body)]
            })
            let expected = await session.snapshot()
            await session.close(); try await fixture.library.flush()
            let before = await fixture.library.readMetrics()
            let root = try await fixture.openAnotherRoot(library: fixture.library, schemas: schemas)
            do {
                #expect(await root.snapshot().phase == .ready)
                let afterStartup = await fixture.library.readMetrics()
                #expect(afterStartup.restoredRecoverySummaries - before.restoredRecoverySummaries == 1)
                #expect(afterStartup.restoredCheckpoints == before.restoredCheckpoints)
                #expect(try await root.sessionSnapshot(id: session.id) == expected)
                try await root.releaseSession(id: session.id)
                #expect(try await root.sessionSnapshot(id: session.id) == expected)
                #expect(await root.shutdown().isSettled)
            } catch { _ = await root.shutdown(); throw error }
            for unsupported: [String: Set<Int>] in [[:], ["application.fixture": [2]]] {
                await #expect(throws: MiraError(.unsupported, "A required session extension is unavailable.")) {
                    let unexpected = try await fixture.openAnotherRoot(library: fixture.library, schemas: unsupported)
                    _ = await unexpected.shutdown()
                }
            }
            #expect(await fixture.driver.runCount == 0)
        }
    }

    @Test func staleSettledSummaryCannotHideAnUnfinishedAdmissionFromStartup() async throws {
        try await withApplication { fixture in
            let command = fixture.command()
            try await fixture.open(command)
            #expect(await fixture.application.shutdown().isSettled)
            let head = try await fixture.library.head(sessionID: command.sessionID)
            try await fixture.library.flush()
            let user = try await fixture.library.stage(Data("Question".utf8), sessionID: command.sessionID,
                batchID: command.id, retentionGroup: UUID(), kind: .userText)
            let plan = try await fixture.library.stage(SessionCodec.encode(command.options.plan(runtimeID: UUID(), generation: 1)),
                sessionID: command.sessionID, batchID: command.id, retentionGroup: UUID(), kind: .executionPlan)
            let admission = SessionBatch(id: command.id, sessionID: command.sessionID, expectedSequence: head.cursor.sequence,
                events: [.init(sequence: head.cursor.sequence + 1, occurredAt: Date(), fact: .admitted(.init(
                    executionID: command.executionID, userMessageID: MessageID(), userBody: user, plan: plan,
                    hasModelRoute: false, authorizationEpoch: 0, timeZoneIdentifier: "UTC")))])
            #expect(await fixture.library.append(admission) == .committed(admission.cursor))
            let root = try await fixture.openAnotherRoot(library: fixture.library)
            do {
                #expect(await root.snapshot().phase == .ready)
                let state = try await root.sessionSnapshot(id: command.sessionID)
                #expect(state.executions[command.executionID]?.completion?.status == .interrupted)
                #expect(state.activeExecutionID == nil)
                #expect(await fixture.driver.runCount == 0)
                #expect(await root.shutdown().isSettled)
            } catch { _ = await root.shutdown(); throw error }
        }
    }

    @Test func maintenanceCoordinatorWaitsForDriverAndApplicationModuleCleanup() async throws {
        try await withApplication { fixture in
            let access = fixture.libraryAccess
            let initial = await access.snapshot().authorization
            let scope = RuntimeScope(kind: .library(initial.libraryID))
            let registry = RuntimeRegistry<any AgentLibraryMaintenanceHandler>()
            let handler = ApplicationMaintenanceHandler(application: fixture.application, probe: fixture.moduleProbe)
            try await registry.register(id: "maintenance", value: handler, scope: scope)
            let coordinator = try AgentLibraryMaintenanceCoordinator(access: access, handlers: registry,
                workOwners: [.application(id: "application", runtime: fixture.application)])
            let command = fixture.command()
            var maintaining: Task<AgentLibraryMaintenanceOperation, any Error>?
            do {
                try await fixture.open(command)
                try requireCommitted(await fixture.application.submit(command))
                await fixture.driver.waitUntilEntered()
                maintaining = Task {
                    try await coordinator.perform(.init(id: UUID(), namespace: "test.application", revision: 1,
                        scope: .library, requestedAt: Date()), expected: initial)
                }
                let deadline = ContinuousClock.now + .seconds(5)
                while await fixture.application.snapshot().phase != .closing {
                    guard ContinuousClock.now < deadline else { throw MiraError(.timeout, "Maintenance did not stop the application.") }
                    try await Task.sleep(for: .milliseconds(1))
                }
                #expect(await fixture.moduleProbe.cleaned == false)
                #expect(await handler.applyCount == 0)
                await fixture.driver.release()
                #expect(try await maintaining!.value.completedAt != nil)
                #expect(await handler.applyCount == 1)
                #expect(await handler.verifyCount == 1)
                #expect(await fixture.moduleProbe.driverWasExitedAtCleanup)
                #expect((await access.snapshot()).activeLeases == 0)
                let root = try await fixture.openAnotherRoot(library: fixture.library)
                do {
                    let state = try await root.sessionSnapshot(id: command.sessionID)
                    #expect(state.executions[command.executionID]?.completion?.status == .cancelled)
                    #expect(await root.shutdown().isSettled)
                } catch { _ = await root.shutdown(); throw error }
            } catch {
                await fixture.driver.release(); _ = await maintaining?.result
                await coordinator.close(); await scope.dispose(); throw error
            }
            await coordinator.close(); await scope.dispose()
        }
    }

    @Test func maintenanceCoordinatorRejectsUnsettledApplicationShutdownWithoutApplyingCleanup() async throws {
        try await withApplication { fixture in
            let access = fixture.libraryAccess
            let initial = await access.snapshot().authorization
            let scope = RuntimeScope(kind: .library(initial.libraryID))
            let registry = RuntimeRegistry<any AgentLibraryMaintenanceHandler>()
            let handler = ApplicationMaintenanceHandler(application: fixture.application, probe: fixture.moduleProbe)
            try await registry.register(id: "maintenance", value: handler, scope: scope)
            let coordinator = try AgentLibraryMaintenanceCoordinator(access: access, handlers: registry,
                workOwners: [.application(id: "application", runtime: fixture.application)])
            do {
                let command = fixture.command()
                try await fixture.open(command)
                await fixture.journal.arm(.admitted, mode: .committedUncertain)
                guard case .indeterminate = await fixture.application.submit(command) else {
                    throw MiraError(.storage, "Synthetic admission did not lose confirmation.")
                }
                let request = AgentLibraryMaintenanceRequest(id: UUID(), namespace: "test.application", revision: 1,
                    scope: .library, requestedAt: Date())
                for _ in 0..<2 {
                    await #expect(throws: AgentLibraryMaintenanceError.unsettledWork(["application"])) {
                        try await coordinator.perform(request, expected: initial)
                    }
                }
                #expect(await handler.applyCount == 0)
                #expect(await handler.verifyCount == 0)
                #expect(await fixture.moduleProbe.cleaned)
                #expect((await access.snapshot()).pending?.request == request)
                #expect((await access.snapshot()).authorization.epoch == initial.epoch + 1)
                await #expect(throws: MiraError.self) { try await access.checkReady() }
            } catch { await coordinator.close(); await scope.dispose(); throw error }
            await coordinator.close(); await scope.dispose()
        }
    }

    @Test func atomicAdmissionOutlivesCancelledCallerAndFreezesTheWholePlan() async throws {
        try await withApplication { fixture in
            let command = fixture.command(opening: .init(title: "Synthetic", workspaceID: nil))
            await fixture.journal.arm(.admitted, mode: .gate)
            let task = Task { await fixture.application.submit(command) }
            await fixture.journal.waitUntilEntered()
            task.cancel()
            let before = try await fixture.application.sessionSnapshot(id: command.sessionID)
            #expect(before.header == nil)
            #expect(before.executions.isEmpty)
            #expect(await fixture.driver.runCount == 0)
            #expect(await fixture.application.snapshot().pendingAdmissions == [address(command)])
            await fixture.journal.releaseAppend()
            try requireCommitted(await task.value)
            await fixture.driver.waitUntilEntered()
            await fixture.driver.release()
            try requireCommitted(await fixture.application.waitForExecution(id: command.executionID, sessionID: command.sessionID))
            let state = try await fixture.application.sessionSnapshot(id: command.sessionID)
            let admission = try #require(state.executions[command.executionID]?.admission)
            let plan = try await AgentExecutionPlan.read(for: admission, from: fixture.library)
            #expect(plan == AgentExecutionPlan(runtimeID: fixture.application.id, catalogGeneration: plan.catalogGeneration,
                driverID: "tests.driver", driverRevision: 3, instructions: "Answer", limits: .init(), priority: .background, route: nil))
            #expect(state.executions[command.executionID]?.completion?.status == .completed)
            let batch = try #require(try await fixture.library.batch(id: command.id, sessionID: command.sessionID))
            #expect(batch.events.count == 2)
            #expect(batch.events[0].fact == .opened(try #require(state.header)))
            #expect(batch.events[1].fact == .admitted(admission))
            #expect(try await fixture.library.read(try #require(admission.userBody)) == Data("Question".utf8))
            #expect(await fixture.driver.runCount == 1)
            #expect(await fixture.application.submit(command) == task.value)
        }
    }

    @Test func maintenancePinsPendingAdmissionUntilApplicationShutdown() async throws {
        try await withApplication { fixture in
            let command = fixture.command(opening: .init(title: "Synthetic", workspaceID: nil))
            await fixture.journal.arm(.admitted, mode: .gate)
            let admission = Task { await fixture.application.submit(command) }
            await fixture.journal.waitUntilEntered()
            var closing: Task<AgentApplicationShutdownReport, Never>?
            do {
                let initial = await fixture.libraryAccess.snapshot()
                #expect(initial.activeLeases == 1)
                let operation = try await fixture.libraryAccess.begin(.init(id: UUID(), namespace: "test.purge", revision: 1,
                    scope: .library, requestedAt: Date()), expected: initial.authorization)
                try requireFailure(await fixture.application.submit(fixture.command()), .unauthorized)
                closing = Task { await fixture.application.shutdown() }
                let deadline = ContinuousClock.now + .seconds(5)
                while await fixture.application.snapshot().phase != .closing {
                    guard ContinuousClock.now < deadline else { throw MiraError(.timeout, "Application shutdown did not begin.") }
                    try await Task.sleep(for: .milliseconds(1))
                }
                #expect((await fixture.libraryAccess.snapshot()).activeLeases == 1)
                #expect(await fixture.moduleProbe.cleaned == false)
                do {
                    _ = try await fixture.libraryAccess.complete(operation, at: Date())
                    Issue.record("Maintenance completed before the application admission drained.")
                } catch let error as MiraError { #expect(error.code == .busy) }
                await fixture.journal.releaseAppend()
                try requireCommitted(await admission.value)
                let report = await closing!.value
                #expect(report.isSettled)
                #expect(await fixture.driver.runCount == 0)
                #expect((await fixture.libraryAccess.snapshot()).activeLeases == 0)
                try await fixture.libraryAccess.waitForQuiescence()
                _ = try await fixture.libraryAccess.complete(operation, at: Date())
                let root = try await fixture.openAnotherRoot(library: fixture.library)
                do {
                    let state = try await root.sessionSnapshot(id: command.sessionID)
                    #expect(state.executions[command.executionID]?.completion != nil)
                    #expect(state.executions[command.executionID]?.attemptIDs.isEmpty == true)
                    #expect(await root.shutdown().isSettled)
                } catch { _ = await root.shutdown(); throw error }
            } catch {
                await fixture.journal.releaseAppend(); await fixture.driver.release()
                _ = await admission.value; _ = await closing?.value
                throw error
            }
        }
    }

    @Test func rejectedFirstMessageDoesNotLeaveACommittedEmptySession() async throws {
        try await withApplication { fixture in
            let draft = fixture.command(opening: .init(title: "Synthetic", workspaceID: nil))
            let command = AgentSubmitCommand(id: draft.id, sessionID: draft.sessionID, executionID: draft.executionID,
                input: .message(id: MessageID(), text: "", timeZoneIdentifier: "UTC"), options: draft.options, opening: draft.opening)
            try requireFailure(await fixture.application.submit(command), .invalidInput)
            let state = try await fixture.application.sessionSnapshot(id: command.sessionID)
            #expect(state.header == nil && state.executions.isEmpty && state.sequence == 0)
            #expect(try await fixture.library.batch(id: command.id, sessionID: command.sessionID) == nil)
            #expect(await fixture.driver.runCount == 0)
        }
    }

    @Test func duplicateCommandCoalescesAndChangedTextOrOptionsCannotReuseItsIdentity() async throws {
        try await withApplication { fixture in
            let command = fixture.command()
            try await fixture.open(command)
            await fixture.journal.arm(.admitted, mode: .gate)
            let first = Task { await fixture.application.submit(command) }
            await fixture.journal.waitUntilEntered()
            let second = Task { await fixture.application.submit(command) }
            let changedText = AgentSubmitCommand(id: command.id, sessionID: command.sessionID,
                executionID: command.executionID, input: .message(id: MessageID(), text: "Changed", timeZoneIdentifier: "UTC"), options: command.options)
            try requireFailure(await fixture.application.submit(changedText), .conflict)
            await fixture.journal.releaseAppend()
            #expect(await first.value == second.value)
            await fixture.driver.waitUntilEntered(); await fixture.driver.release()
            try requireCommitted(await fixture.application.waitForExecution(id: command.executionID, sessionID: command.sessionID))
            try requireFailure(await fixture.application.submit(changedText), .conflict)
            let changedOptions = AgentSubmitCommand(id: command.id, sessionID: command.sessionID, executionID: command.executionID,
                input: command.input, options: .init(driverID: "tests.driver", driverRevision: 3, instructions: "Changed", route: nil))
            try requireFailure(await fixture.application.submit(changedOptions), .conflict)
            #expect(await fixture.application.submit(command) == first.value)
            #expect(await fixture.driver.runCount == 1)
            #expect(await fixture.journal.appendCount(id: command.id) == 1)
        }
    }

    @Test func pendingAdmissionReservesSessionAndCancellationPreventsDriverDispatch() async throws {
        try await withApplication { fixture in
            let command = fixture.command()
            try await fixture.open(command)
            await fixture.journal.arm(.admitted, mode: .gate)
            let pending = Task { await fixture.application.submit(command) }
            await fixture.journal.waitUntilEntered()
            let competing = fixture.command(sessionID: command.sessionID)
            try requireFailure(await fixture.application.submit(competing), .busy)
            await fixture.application.cancel(sessionID: command.sessionID)
            await fixture.journal.releaseAppend()
            try requireCommitted(await pending.value)
            try requireCommitted(await fixture.application.waitForExecution(id: command.executionID, sessionID: command.sessionID))
            #expect(try await fixture.application.sessionSnapshot(id: command.sessionID).executions[command.executionID]?.completion?.status == .cancelled)
            #expect(await fixture.driver.runCount == 0)
        }
    }

    @Test func shutdownWaitsForNoncooperatingDriverBeforeCleaningItsModule() async throws {
        try await withApplication { fixture in
            let command = fixture.command()
            try await fixture.open(command)
            let events = try await fixture.application.observeSession(id: command.sessionID)
            let applicationEvents = try await fixture.application.observe()
            try requireCommitted(await fixture.application.submit(command))
            await fixture.driver.waitUntilEntered()
            var iterator = events.makeAsyncIterator()
            #expect(await iterator.next()?.activeExecutionID == command.executionID)
            await #expect(throws: MiraError.self) { try await fixture.application.releaseSession(id: command.sessionID) }
            let shutdown = Task { await fixture.application.shutdown() }
            await fixture.driver.waitUntilCancelled()
            #expect(await fixture.application.snapshot().phase == .closing)
            #expect(await fixture.moduleProbe.cleaned == false)
            await fixture.driver.release()
            let report = await shutdown.value
            #expect(report.isSettled)
            #expect(await fixture.moduleProbe.cleaned)
            #expect(await fixture.moduleProbe.driverWasExitedAtCleanup)
            var appIterator = applicationEvents.makeAsyncIterator()
            #expect(await appIterator.next()?.phase == .closed)
            #expect(await appIterator.next() == nil)
            #expect(await fixture.application.shutdown() == report)
            let reopened = try await SessionRuntime.open(id: command.sessionID, journal: fixture.library, payloads: fixture.library)
            #expect(await reopened.snapshot().executions[command.executionID]?.completion?.status == .cancelled)
            await reopened.close()
        }
    }

    @Test func startupInterruptsPersistedAdmissionWithoutRunningAnyDriver() async throws {
        try await withApplication(preloaded: true) { fixture in
            let command = try #require(fixture.preloadedCommand)
            let state = try await fixture.application.sessionSnapshot(id: command.sessionID)
            #expect(state.executions[command.executionID]?.completion?.status == .interrupted)
            #expect(state.executions[command.executionID]?.attemptIDs.isEmpty == true)
            #expect(await fixture.application.snapshot().phase == .ready)
            #expect(await fixture.driver.runCount == 0)
            try requireCommitted(await fixture.application.submit(command))
            #expect(await fixture.driver.runCount == 0)
        }
    }

    @Test func startupRecoveryFailureBlocksAdmissionsUntilOriginalSettlementSucceeds() async throws {
        try await withApplication(preloaded: true, startupFault: true) { fixture in
            let command = try #require(fixture.preloadedCommand)
            let initial = await fixture.application.snapshot()
            #expect(initial.phase == .recovering)
            #expect(initial.recoveryResults[address(command)] != nil)
            try requireFailure(await fixture.application.submit(fixture.command()), .busy)
            await fixture.journal.allowReconciliation()
            try requireCommitted(await fixture.application.retrySettlement(executionID: command.executionID, sessionID: command.sessionID))
            #expect(await fixture.application.snapshot().phase == .ready)
            #expect(await fixture.driver.runCount == 0)
            #expect(try await fixture.application.sessionSnapshot(id: command.sessionID).executions[command.executionID]?.completion?.status == .interrupted)
        }
    }

    @Test func uncertainAdmissionRetainsModuleLeaseUntilOriginalCommitIsResolved() async throws {
        try await withApplication { fixture in
            let command = fixture.command()
            try await fixture.open(command)
            await fixture.journal.arm(.admitted, mode: .committedUncertain)
            let result = await fixture.application.submit(command)
            guard case .indeterminate(let batchID, _) = result else { Issue.record("Admission should be uncertain"); return }
            #expect(batchID == command.id)
            #expect(await fixture.driver.runCount == 0)
            let scope = try #require(await fixture.moduleProbe.scope)
            let disposal = Task { await scope.dispose() }
            await fixture.moduleProbe.waitUntilClosing()
            #expect(await fixture.moduleProbe.cleaned == false)
            await fixture.application.cancel(sessionID: command.sessionID)
            await fixture.journal.allowReconciliation()
            try requireCommitted(await fixture.application.reconcileAdmission(commandID: command.id))
            try requireCommitted(await fixture.application.waitForExecution(id: command.executionID, sessionID: command.sessionID))
            await disposal.value
            #expect(await fixture.moduleProbe.cleaned)
            #expect(await fixture.driver.runCount == 0)
            #expect(await fixture.journal.appendCount(id: command.id) == 1)
        }
    }

    @Test func definiteAdmissionAbsenceReleasesReservationAndAllowsOneNewAttempt() async throws {
        try await withApplication { fixture in
            let command = fixture.command()
            try await fixture.open(command)
            await fixture.journal.arm(.admitted, mode: .absentUncertain)
            guard case .indeterminate = await fixture.application.submit(command) else { Issue.record("Admission should be uncertain"); return }
            await fixture.journal.allowReconciliation()
            guard case .notCommitted = await fixture.application.reconcileAdmission(commandID: command.id) else { Issue.record("Original batch should be absent"); return }
            #expect(await fixture.application.snapshot().pendingAdmissions.isEmpty)
            #expect(try await fixture.application.sessionSnapshot(id: command.sessionID).executions.isEmpty)
            try requireCommitted(await fixture.application.submit(command))
            await fixture.driver.waitUntilEntered(); await fixture.driver.release()
            try requireCommitted(await fixture.application.waitForExecution(id: command.executionID, sessionID: command.sessionID))
            #expect(await fixture.driver.runCount == 1)
            #expect(await fixture.journal.appendCount(id: command.id) == 2)
        }
    }

    @Test func terminalUncertaintyIsOwnedByExecutionAndCannotBeClaimedByAnotherCommand() async throws {
        try await withApplication { fixture in
            let command = fixture.command()
            try await fixture.open(command)
            try requireCommitted(await fixture.application.submit(command))
            await fixture.driver.waitUntilEntered()
            await fixture.journal.arm(.finished, mode: .committedUncertain)
            await fixture.driver.release()
            let result = await fixture.application.waitForExecution(id: command.executionID, sessionID: command.sessionID)
            guard case .indeterminate(let batchID, _) = result else { Issue.record("Terminal result should be uncertain"); return }
            #expect(await fixture.application.snapshot().settlementFailures[address(command)] == result)
            let renameID = UUID()
            try requireFailure(await fixture.application.changeSession(id: command.sessionID, commandID: renameID,
                change: .rename(title: "Changed", expectedRevision: 1)), .busy)
            #expect(await fixture.application.snapshot().pendingSessionCommands.isEmpty)
            await fixture.journal.allowReconciliation()
            async let a = fixture.application.retrySettlement(executionID: command.executionID, sessionID: command.sessionID)
            async let b = fixture.application.retrySettlement(executionID: command.executionID, sessionID: command.sessionID)
            let results = await [a, b]
            for result in results { try requireCommitted(result) }
            let batch = try #require(try await fixture.library.batch(id: batchID, sessionID: command.sessionID))
            #expect(batch.events.contains { if case .finished = $0.fact { true } else { false } })
            #expect(await fixture.driver.runCount == 1)
            #expect(await fixture.application.snapshot().ownedExecutions.isEmpty)
        }
    }

    @Test func shutdownReportsUnresolvedAdmissionAndNextOpenOnlyInterruptsIt() async throws {
        try await withApplication { fixture in
            let command = fixture.command()
            try await fixture.open(command)
            await fixture.journal.arm(.admitted, mode: .committedUncertain)
            guard case .indeterminate = await fixture.application.submit(command) else { Issue.record("Admission should be uncertain"); return }
            let report = await fixture.application.shutdown()
            #expect(!report.isSettled)
            #expect(report.unresolvedCommands[command.id] != nil)
            #expect(report.unresolvedSessions[command.sessionID]?.requiresReconciliation == true)
            #expect(await fixture.moduleProbe.cleaned)
            #expect(await fixture.driver.runCount == 0)
            try await fixture.library.close()
            let reopenedLibrary = try FileSessionLibrary(directory: fixture.directory)
            do {
                let root = try await fixture.openAnotherRoot(library: reopenedLibrary)
                let state = try await root.sessionSnapshot(id: command.sessionID)
                #expect(state.executions[command.executionID]?.completion?.status == .interrupted)
                #expect(await fixture.driver.runCount == 0)
                #expect(await root.shutdown().isSettled)
                try await reopenedLibrary.close()
            } catch { try? await reopenedLibrary.close(); throw error }
        }
    }

    @Test func sessionChangesUseRevisionChecksAndVerifyCommittedCommandIdentity() async throws {
        try await withApplication { fixture in
            let id = ConversationID(), openID = UUID(), renameID = UUID(), archiveID = UUID()
            let open = await fixture.application.createSession(id: id, commandID: openID, title: "Original", workspaceID: nil)
            try requireCommitted(open)
            #expect(await fixture.application.createSession(id: id, commandID: openID, title: "Original", workspaceID: nil) == open)
            try requireFailure(await fixture.application.createSession(id: id, commandID: openID, title: "Changed", workspaceID: nil), .conflict)
            await fixture.journal.arm(.renamed, mode: .committedUncertain)
            guard case .indeterminate = await fixture.application.changeSession(id: id, commandID: renameID,
                change: .rename(title: "Renamed", expectedRevision: 1)) else { Issue.record("Rename should be uncertain"); return }
            #expect(await fixture.application.snapshot().pendingSessionCommands == [renameID])
            await fixture.journal.allowReconciliation()
            let renamed = await fixture.application.reconcileSessionCommand(commandID: renameID)
            try requireCommitted(renamed)
            #expect(await fixture.application.changeSession(id: id, commandID: renameID, change: .rename(title: "Renamed", expectedRevision: 1)) == renamed)
            try requireFailure(await fixture.application.changeSession(id: id, commandID: UUID(), change: .archive(expectedRevision: 1)), .conflict)
            try requireCommitted(await fixture.application.changeSession(id: id, commandID: archiveID, change: .archive(expectedRevision: 2)))
            let state = try await fixture.application.sessionSnapshot(id: id)
            #expect(state.isArchived && state.revision == 3)
            try requireFailure(await fixture.application.submit(fixture.command(sessionID: id)), .busy)
        }
    }

    @Test func equalExecutionIDsInDifferentSessionsDoNotShareTaskOwnership() async throws {
        try await withApplication { fixture in
            let executionID = ExecutionID()
            let first = fixture.command(executionID: executionID), second = fixture.command(executionID: executionID)
            try await fixture.open(first); try await fixture.open(second)
            try requireCommitted(await fixture.application.submit(first)); try requireCommitted(await fixture.application.submit(second))
            #expect(await fixture.application.snapshot().ownedExecutions == [address(first), address(second)])
            await fixture.application.cancel(sessionID: first.sessionID)
            await fixture.driver.release()
            try requireCommitted(await fixture.application.waitForExecution(id: executionID, sessionID: first.sessionID))
            try requireCommitted(await fixture.application.waitForExecution(id: executionID, sessionID: second.sessionID))
            #expect(try await fixture.application.sessionSnapshot(id: first.sessionID).executions[executionID]?.completion?.status == .cancelled)
            #expect(try await fixture.application.sessionSnapshot(id: second.sessionID).executions[executionID]?.completion?.status == .completed)
        }
    }
}

private func address(_ command: AgentSubmitCommand) -> AgentExecutionAddress { .init(sessionID: command.sessionID, executionID: command.executionID) }
private func requireCommitted(_ result: SessionCommitResult) throws {
    guard case .committed = result else { Issue.record("Expected committed result: \(result)"); throw MiraError(.storage, "Synthetic operation did not commit.") }
}
private func requireFailure(_ result: SessionCommitResult, _ code: MiraError.Code) throws {
    guard case .notCommitted(let error) = result else { Issue.record("Expected rejected result: \(result)"); throw MiraError(.storage, "Synthetic operation was not rejected.") }
    #expect(error.code == code)
}
private func withApplication(preloaded: Bool = false, startupFault: Bool = false,
                             _ body: (ApplicationFixture) async throws -> Void) async throws {
    let fixture = try await ApplicationFixture.make(preloaded: preloaded, startupFault: startupFault)
    do { try await body(fixture); await fixture.shutdown() }
    catch { await fixture.shutdown(); throw error }
}

private actor DriverProbe {
    private(set) var runCount = 0
    private(set) var exitedCount = 0
    private var released = false
    private var cancelled = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    func enter() { runCount += 1; let values = enteredWaiters; enteredWaiters.removeAll(); values.forEach { $0.resume() } }
    func exited() { exitedCount += 1 }
    func waitUntilEntered() async { if runCount == 0 { await withCheckedContinuation { enteredWaiters.append($0) } } }
    func waitUntilCancelled() async { if !cancelled { await withCheckedContinuation { cancelWaiters.append($0) } } }
    func release() { released = true; let values = releaseWaiters; releaseWaiters.removeAll(); values.forEach { $0.resume() } }
    func recordCancellation() { cancelled = true; let values = cancelWaiters; cancelWaiters.removeAll(); values.forEach { $0.resume() } }
    func wait() async {
        await withTaskCancellationHandler {
            if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
        } onCancel: { Task { await self.recordCancellation() } }
    }
}
private struct BlockingDriver: AgentDriver {
    let id = "tests.driver", revision = 3
    let probe: DriverProbe
    func run(in context: AgentRunContext) async throws -> AgentDriverDecision {
        await probe.enter(); await probe.wait(); await probe.exited()
        return .respond(text: context.userText + " done")
    }
}
private actor ModuleProbe {
    private(set) var cleaned = false
    private(set) var driverWasExitedAtCleanup = false
    private(set) var scope: RuntimeScope?
    private var closing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func installed(_ value: RuntimeScope) { scope = value }
    func clean(driver: DriverProbe) async { driverWasExitedAtCleanup = await driver.exitedCount == driver.runCount; cleaned = true }
    func markClosing() { closing = true; let values = waiters; waiters.removeAll(); values.forEach { $0.resume() } }
    func waitUntilClosing() async { if !closing { await withCheckedContinuation { waiters.append($0) } } }
}

private actor ApplicationMaintenanceHandler: AgentLibraryMaintenanceHandler {
    nonisolated let identity = AgentLibraryMaintenanceHandlerIdentity(namespace: "test.application", revision: 1)
    let application: AgentApplicationRuntime
    let probe: ModuleProbe
    private(set) var applyCount = 0
    private(set) var verifyCount = 0
    init(application: AgentApplicationRuntime, probe: ModuleProbe) { self.application = application; self.probe = probe }
    func apply(_ operation: AgentLibraryMaintenanceOperation) async throws {
        applyCount += 1
        guard await application.snapshot().phase == .closed, await probe.cleaned else {
            throw MiraError(.conflict, "Maintenance began before the application closed.")
        }
    }
    func verify(_ operation: AgentLibraryMaintenanceOperation) async throws {
        verifyCount += 1
        guard await application.shutdown().isSettled else {
            throw MiraError(.conflict, "Maintenance observed unsettled application work.")
        }
    }
}
private struct FixtureModule: RuntimeModule {
    let registry: RuntimeRegistry<AgentCapability>
    let driver: DriverProbe
    let probe: ModuleProbe
    let id = "tests.module"
    let dependencies: Set<String> = []
    func activate(in scope: RuntimeScope) async throws {
        try await registry.register(id: "driver", value: .driver(BlockingDriver(probe: driver)), scope: scope)
        await probe.installed(scope)
        _ = try await scope.registerClosing { await probe.markClosing() }
        try await scope.registerCleanup { await probe.clean(driver: driver) }
    }
}
private struct NoPolicy: AgentToolPolicy {
    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision { throw MiraError(.unsupported, "Unexpected tool policy.") }
    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws { throw MiraError(.unsupported, "Unexpected tool policy.") }
}
private struct NoAuthority: AgentEffectAuthority {
    func authorization(for proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentLibraryAuthorization { throw MiraError(.unsupported, "Unexpected tool authority.") }
    func validate(_ authorization: AgentLibraryAuthorization, proposal: AgentToolProposal, context: AgentToolContext) async throws { throw MiraError(.unsupported, "Unexpected tool authority.") }
}
private struct AllowAuthorizer: AgentSourceAuthorizer { func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {} }
private struct NoBusiness: AgentBusinessEffects {
    func fenceExecution(sessionID: ConversationID, executionID: ExecutionID) async throws {}
    func commit(_ proof: AgentEffectProof) async -> AgentBusinessCommitOutcome { .notCommitted(.init(.unsupported, "Unexpected business effects.")) }
    func receipt(for proof: AgentEffectProof) async -> AgentBusinessReceiptLookup { .absent }
    func unpublished(after receiptID: UUID?, limit: Int) async throws -> [AgentReceiptPublication] { [] }
    func acknowledge(_ receipt: AgentBusinessReceiptReference, at cursor: SessionCursor) async throws {}
}

private actor ApplicationJournal: SessionJournal {
    enum Kind { case admitted, finished, renamed }
    enum Mode { case gate, committedUncertain, absentUncertain }
    let library: FileSessionLibrary
    private var armed: (Kind, Mode)?
    private var unresolved: UUID?
    private var reconciliationAllowed = false
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var appendWaiters: [CheckedContinuation<Void, Never>] = []
    private var appends: [UUID: Int] = [:]
    init(_ library: FileSessionLibrary) { self.library = library }
    func arm(_ kind: Kind, mode: Mode) { armed = (kind, mode); entered = false; released = false; reconciliationAllowed = false }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { enteredWaiters.append($0) } } }
    func releaseAppend() { released = true; let values = appendWaiters; appendWaiters.removeAll(); values.forEach { $0.resume() } }
    func allowReconciliation() { reconciliationAllowed = true }
    func appendCount(id: UUID) -> Int { appends[id, default: 0] }
    func append(_ batch: SessionBatch) async -> SessionAppendOutcome {
        appends[batch.id, default: 0] += 1
        if let (kind, mode) = armed, batch.events.contains(where: { matches(kind, $0.fact) }) {
            armed = nil; entered = true
            let values = enteredWaiters; enteredWaiters.removeAll(); values.forEach { $0.resume() }
            switch mode {
            case .gate:
                if !released { await withCheckedContinuation { appendWaiters.append($0) } }
            case .committedUncertain:
                let result = await library.append(batch)
                guard case .committed = result else { return result }
                unresolved = batch.id
                return .indeterminate(.init(.storage, "Synthetic lost commit acknowledgement."))
            case .absentUncertain:
                unresolved = batch.id
                return .indeterminate(.init(.storage, "Synthetic unconfirmed absent append."))
            }
        }
        return await library.append(batch)
    }
    func reconcile(_ batch: SessionBatch) async -> SessionAppendOutcome {
        if unresolved == batch.id, !reconciliationAllowed { return .indeterminate(.init(.storage, "Synthetic reconciliation unavailable.")) }
        unresolved = nil
        return await library.reconcile(batch)
    }
    func batch(id: UUID, sessionID: ConversationID) async throws -> SessionBatch? { try await library.batch(id: id, sessionID: sessionID) }
    func head(sessionID: ConversationID) async throws -> SessionJournalHead { try await library.head(sessionID: sessionID) }
    func read(sessionID: ConversationID, after sequence: Int64, limit: Int) async throws -> [SessionBatch] { try await library.read(sessionID: sessionID, after: sequence, limit: limit) }
    func sessions(after: ConversationID?, limit: Int) async throws -> [ConversationID] { try await library.sessions(after: after, limit: limit) }
    func flush() async throws { try await library.flush() }
    func close() async throws { try await library.close() }
    private func matches(_ kind: Kind, _ fact: SessionFact) -> Bool {
        switch (kind, fact) { case (.admitted, .admitted), (.finished, .finished), (.renamed, .renamed): true; default: false }
    }
}

private final class ApplicationFixture: Sendable {
    let directory: URL
    let library: FileSessionLibrary
    let journal: ApplicationJournal
    let application: AgentApplicationRuntime
    let accessFixture: LibraryAccessFixture
    var libraryAccess: AgentLibraryAccess { accessFixture.access }
    let driver: DriverProbe
    let moduleProbe: ModuleProbe
    let preloadedCommand: AgentSubmitCommand?
    private init(directory: URL, library: FileSessionLibrary, journal: ApplicationJournal, application: AgentApplicationRuntime, accessFixture: LibraryAccessFixture,
                 driver: DriverProbe, moduleProbe: ModuleProbe, preloadedCommand: AgentSubmitCommand?) {
        self.directory = directory; self.library = library; self.journal = journal; self.application = application; self.accessFixture = accessFixture
        self.driver = driver; self.moduleProbe = moduleProbe; self.preloadedCommand = preloadedCommand
    }
    static func make(preloaded: Bool, startupFault: Bool) async throws -> ApplicationFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-application-\(UUID().uuidString)")
        var library = try FileSessionLibrary(directory: directory)
        var accessFixture: LibraryAccessFixture?
        do {
            let command = preloaded ? makeCommand() : nil
            if let command {
                let runtime = try await SessionRuntime.open(id: command.sessionID, journal: library, payloads: library)
                do {
                    try requireCommitted(await runtime.commit(id: UUID()) { context in
                        let title = try await context.stageBytes(Data("Synthetic".utf8), kind: .title, retentionGroup: UUID())
                        return [.opened(.init(workspaceID: nil, title: title))]
                    })
                    try requireCommitted(await runtime.commit(id: command.id) { context in
                        guard case .message(let id, let text, let zone) = command.input else { throw MiraError(.invalidInput, "Invalid fixture message.") }
                        let user = try await context.stageBytes(Data(text.utf8), kind: .userText, retentionGroup: UUID())
                        let plan = try await context.stage(try command.options.plan(runtimeID: UUID(), generation: 1), kind: .executionPlan, retentionGroup: UUID())
                        return [.admitted(.init(executionID: command.executionID, userMessageID: id, userBody: user,
                            plan: plan, hasModelRoute: false, authorizationEpoch: 0, timeZoneIdentifier: zone))]
                    })
                    await runtime.close()
                } catch { await runtime.close(); throw error }
                try await library.close()
                library = try FileSessionLibrary(directory: directory)
            }
            let journal = ApplicationJournal(library), driver = DriverProbe(), probe = ModuleProbe()
            if startupFault { await journal.arm(.finished, mode: .committedUncertain) }
            let access = try await LibraryAccessFixture.make()
            accessFixture = access
            let libraryAccess = access.access
            let root = try await makeRoot(journal: journal, payloads: library, libraryAccess: libraryAccess, driver: driver, probe: probe)
            return .init(directory: directory, library: library, journal: journal, application: root,
                         accessFixture: access, driver: driver, moduleProbe: probe, preloadedCommand: command)
        } catch { await accessFixture?.close(); try? await library.close(); try? FileManager.default.removeItem(at: directory); throw error }
    }
    func command(sessionID: ConversationID = .init(), executionID: ExecutionID = .init(),
                 opening: AgentSessionOpening? = nil) -> AgentSubmitCommand {
        Self.makeCommand(sessionID: sessionID, executionID: executionID, opening: opening)
    }
    private static func makeCommand(sessionID: ConversationID = .init(), executionID: ExecutionID = .init(),
                                    opening: AgentSessionOpening? = nil) -> AgentSubmitCommand {
        .init(id: UUID(), sessionID: sessionID, executionID: executionID,
            input: .message(id: MessageID(), text: "Question", timeZoneIdentifier: "UTC"),
            options: .init(driverID: "tests.driver", driverRevision: 3, instructions: "Answer", priority: .background, route: nil), opening: opening)
    }
    func open(_ command: AgentSubmitCommand) async throws {
        try requireCommitted(await application.createSession(id: command.sessionID, commandID: UUID(), title: "Synthetic", workspaceID: nil))
    }
    func openAnotherRoot(library: FileSessionLibrary, schemas: [String: Set<Int>] = [:]) async throws -> AgentApplicationRuntime {
        let libraryAccess = self.libraryAccess
        return try await Self.makeRoot(journal: library, payloads: library, libraryAccess: libraryAccess, driver: driver, probe: ModuleProbe(), schemas: schemas)
    }
    private static func makeRoot(journal: any SessionJournal, payloads: any SessionPayloadStore, libraryAccess: AgentLibraryAccess,
                                 driver: DriverProbe, probe: ModuleProbe, schemas: [String: Set<Int>] = [:]) async throws -> AgentApplicationRuntime {
        let registry = RuntimeRegistry<AgentCapability>()
        return try await AgentApplicationRuntime.open(journal: journal, payloads: payloads, libraryAccess: libraryAccess, registry: registry,
            modules: [FixtureModule(registry: registry, driver: driver, probe: probe)], policy: NoPolicy(), authority: NoAuthority(),
            business: NoBusiness(), authorizer: AllowAuthorizer(), approvals: RuntimeApprovalService(),
            scheduler: RuntimeScheduler(modelCapacity: 1, backgroundCapacity: 1), extensionSchemas: schemas)
    }
    func shutdown() async {
        await journal.releaseAppend(); await journal.allowReconciliation(); await driver.release()
        _ = await application.shutdown()
        await accessFixture.close()
        try? await library.close(); try? FileManager.default.removeItem(at: directory)
    }
}
