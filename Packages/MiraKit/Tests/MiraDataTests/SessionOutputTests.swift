import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Session live output", .timeLimit(.minutes(1)))
struct SessionOutputTests {
    @Test(arguments: [false, true])
    func successfulAttemptHandsOffWithoutRetainingCoreTextAndRevocationClearsMarker(privacy: Bool) async throws {
        try await withTaskWorkflow { fixture in
            let prepared = try await makeOutputRuntime(fixture)
            let lease = try await fixture.access.acquire(in: fixture.scope)
            do {
                var iterator = try await prepared.runtime.outputObservations().makeAsyncIterator()
                _ = await iterator.next()
                try await prepared.runtime.beginOutput(ownerID: prepared.ownerID,
                    executionID: prepared.executionID, attemptID: prepared.attemptID,
                    authorizationEpoch: lease.authorization.epoch, lease: lease)
                #expect(await prepared.runtime.publishOutput(ownerID: prepared.ownerID, answer: "Final answer", thinking: ""))
                _ = await iterator.next()
                let result = await prepared.runtime.commit(id: UUID()) { context in
                    let output = try await context.stageBytes(Data("output".utf8), kind: .modelOutput, retentionGroup: UUID())
                    return [.attemptResolved(.init(attemptID: prepared.attemptID, status: .completed, output: output))]
                }
                guard case .committed = result else { throw MiraError(.storage, "Output test settlement failed.") }
                let handoff = try #require(await iterator.next())
                #expect(handoff.value == nil)
                #expect(handoff.handoffExecutionID == prepared.executionID)
                await prepared.runtime.releaseOutput(ownerID: prepared.ownerID)
                var subscriber = try await prepared.runtime.outputObservations().makeAsyncIterator()
                #expect(await subscriber.next()?.handoffExecutionID == prepared.executionID)
                if privacy {
                    let state = await prepared.runtime.snapshot()
                    let hidden = Set(state.references.values.filter {
                        [.executionPlan, .request, .modelOutput].contains($0.kind)
                    }.map(\.retentionGroup))
                    let result = await prepared.runtime.commit(id: UUID()) { _ in
                        [.invalidated(.init(operationID: UUID(), executionIDs: [prepared.executionID],
                            retentionGroups: hidden, authorizationEpoch: state.authorizationEpoch + 1, reason: .forgotten))]
                    }
                    guard case .committed = result else { throw MiraError(.storage, "Output test invalidation failed.") }
                } else {
                    await prepared.runtime.requestCancellation(executionID: prepared.executionID)
                }
                let revoked = try #require(await iterator.next())
                #expect(revoked.value == nil && revoked.handoffExecutionID == nil)
                #expect(revoked.revision > handoff.revision)
                await lease.release()
                await prepared.runtime.close()
            } catch {
                await lease.release()
                await prepared.runtime.close()
                throw error
            }
        }
    }
    @Test func coalescesLatestValueAndClearsOnRelease() async throws {
        try await withTaskWorkflow { fixture in
            let prepared = try await makeOutputRuntime(fixture)
            let lease = try await fixture.access.acquire(in: fixture.scope)
            do {
                let stream = try await prepared.runtime.outputObservations()
                var iterator = stream.makeAsyncIterator()
                let initial = try #require(await iterator.next())
                #expect(initial.value == nil)
                #expect(initial.cursor.sequence == 4)

                try await prepared.runtime.beginOutput(ownerID: prepared.ownerID,
                    executionID: prepared.executionID, attemptID: prepared.attemptID,
                    authorizationEpoch: lease.authorization.epoch, lease: lease)
                #expect(await prepared.runtime.publishOutput(ownerID: prepared.ownerID, answer: "A", thinking: ""))
                #expect(await prepared.runtime.publishOutput(ownerID: prepared.ownerID, answer: "Answer", thinking: "Opaque"))
                let latest = try #require(await iterator.next())
                #expect(latest.revision == 2)
                #expect(latest.value?.answer == "Answer")
                #expect(latest.value?.thinking == "Opaque")
                #expect(latest.value?.stepID == prepared.stepID)

                await prepared.runtime.releaseOutput(ownerID: prepared.ownerID)
                let cleared = try #require(await iterator.next())
                #expect(cleared.value == nil)

                await lease.release()
                await prepared.runtime.close()
            } catch {
                await lease.release()
                await prepared.runtime.close()
                throw error
            }
        }
    }

    @Test func cancellationAndLeaseRevocationClearStaleWriter() async throws {
        try await withTaskWorkflow { fixture in
            let prepared = try await makeOutputRuntime(fixture)
            let lease = try await fixture.access.acquire(in: fixture.scope)
            do {
                let stream = try await prepared.runtime.outputObservations()
                var iterator = stream.makeAsyncIterator()
                _ = try #require(await iterator.next())
                try await prepared.runtime.beginOutput(ownerID: prepared.ownerID,
                    executionID: prepared.executionID, attemptID: prepared.attemptID,
                    authorizationEpoch: lease.authorization.epoch, lease: lease)
                #expect(await prepared.runtime.publishOutput(ownerID: prepared.ownerID, answer: "Visible", thinking: ""))
                _ = try #require(await iterator.next())

                await prepared.runtime.requestCancellation(executionID: prepared.executionID)
                let cancellation = try #require(await iterator.next())
                #expect(cancellation.value == nil)
                #expect(await !prepared.runtime.publishOutput(ownerID: prepared.ownerID, answer: "Late", thinking: ""))

                await lease.release()
                #expect(await !prepared.runtime.publishOutput(ownerID: prepared.ownerID, answer: "After revoke", thinking: ""))
                await prepared.runtime.close()
            } catch {
                await lease.release()
                await prepared.runtime.close()
                throw error
            }
        }
    }

    @Test func resolvedWriterCannotPublishIntoANewerAttempt() async throws {
        try await withTaskWorkflow { fixture in
            let prepared = try await makeOutputRuntime(fixture)
            let lease = try await fixture.access.acquire(in: fixture.scope)
            do {
                let oldStream = try await prepared.runtime.outputObservations()
                var oldIterator = oldStream.makeAsyncIterator()
                _ = try #require(await oldIterator.next())
                try await prepared.runtime.beginOutput(ownerID: prepared.ownerID,
                    executionID: prepared.executionID, attemptID: prepared.attemptID,
                    authorizationEpoch: lease.authorization.epoch, lease: lease)
                #expect(await prepared.runtime.publishOutput(ownerID: prepared.ownerID, answer: "Old", thinking: ""))
                let oldLive = try #require(await oldIterator.next())
                let oldRequest = try #require(await prepared.runtime.snapshot().attempts[prepared.attemptID]?.attempt.request)
                let newAttemptID = UUID()
                let failed = await prepared.runtime.commit(id: UUID()) { _ in
                    [.attemptResolved(.init(attemptID: prepared.attemptID, status: .failed))]
                }
                guard case .committed = failed else { throw MiraError(.storage, "Failed to settle the old output attempt.") }
                let retry = await prepared.runtime.commit(id: UUID()) { _ in
                    [.phaseChanged(executionID: prepared.executionID, phase: .preparing),
                     .attemptStarted(.init(id: newAttemptID, executionID: prepared.executionID,
                         stepID: prepared.stepID, stepIndex: 1, attemptIndex: 2, request: oldRequest))]
                }
                guard case .committed = retry else { throw MiraError(.storage, "Failed to start the replacement attempt.") }
                let replacementOwner = UUID()
                try await prepared.runtime.beginOutput(ownerID: replacementOwner,
                    executionID: prepared.executionID, attemptID: newAttemptID,
                    authorizationEpoch: lease.authorization.epoch, lease: lease)
                #expect(await !prepared.runtime.publishOutput(ownerID: prepared.ownerID, answer: "Late old", thinking: ""))
                #expect(await prepared.runtime.publishOutput(ownerID: replacementOwner, answer: "New", thinking: ""))
                let currentStream = try await prepared.runtime.outputObservations()
                var currentIterator = currentStream.makeAsyncIterator()
                let current = try #require(await currentIterator.next())
                #expect(current.value?.answer == "New")
                #expect(current.revision > oldLive.revision)
                await prepared.runtime.releaseOutput(ownerID: prepared.ownerID)
                let afterLateRelease = try await prepared.runtime.outputObservations()
                var afterLateReleaseIterator = afterLateRelease.makeAsyncIterator()
                let retained = try #require(await afterLateReleaseIterator.next())
                #expect(retained.value?.answer == "New")
                await prepared.runtime.releaseOutput(ownerID: replacementOwner)
                await lease.release()
                await prepared.runtime.close()
            } catch {
                await lease.release()
                await prepared.runtime.close()
                throw error
            }
        }
    }

    @Test func activeLeaseRevocationClearsOutputBeforeNextSubscription() async throws {
        try await withTaskWorkflow { fixture in
            let prepared = try await makeOutputRuntime(fixture)
            let lease = try await fixture.access.acquire(in: fixture.scope)
            do {
                try await prepared.runtime.beginOutput(ownerID: prepared.ownerID,
                    executionID: prepared.executionID, attemptID: prepared.attemptID,
                    authorizationEpoch: lease.authorization.epoch, lease: lease)
                #expect(await prepared.runtime.publishOutput(ownerID: prepared.ownerID, answer: "Revoked", thinking: ""))
                await lease.release()

                let stream = try await prepared.runtime.outputObservations()
                var iterator = stream.makeAsyncIterator()
                let cleared = try #require(await iterator.next())
                #expect(cleared.value == nil)
                #expect(await !prepared.runtime.publishOutput(ownerID: prepared.ownerID, answer: "Late", thinking: ""))
                await prepared.runtime.close()
            } catch {
                await lease.release()
                await prepared.runtime.close()
                throw error
            }
        }
    }

    @Test func cancelledObserverDoesNotCancelExecution() async throws {
        try await withTaskWorkflow { fixture in
            let prepared = try await makeOutputRuntime(fixture)
            let lease = try await fixture.access.acquire(in: fixture.scope)
            do {
                let stream = try await prepared.runtime.outputObservations()
                let observer = Task {
                    var iterator = stream.makeAsyncIterator()
                    _ = await iterator.next()
                    _ = await iterator.next()
                }
                await Task.yield()
                observer.cancel()
                _ = await observer.value

                try await prepared.runtime.beginOutput(ownerID: prepared.ownerID,
                    executionID: prepared.executionID, attemptID: prepared.attemptID,
                    authorizationEpoch: lease.authorization.epoch, lease: lease)
                #expect(await prepared.runtime.publishOutput(ownerID: prepared.ownerID, answer: "Still running", thinking: ""))
                await prepared.runtime.releaseOutput(ownerID: prepared.ownerID)
                await lease.release()
                await prepared.runtime.close()
            } catch {
                await lease.release()
                await prepared.runtime.close()
                throw error
            }
        }
    }

    @Test func closePublishesClearAndFinishesOutputStream() async throws {
        try await withTaskWorkflow { fixture in
            let prepared = try await makeOutputRuntime(fixture)
            let lease = try await fixture.access.acquire(in: fixture.scope)
            do {
                let stream = try await prepared.runtime.outputObservations()
                var iterator = stream.makeAsyncIterator()
                _ = try #require(await iterator.next())
                try await prepared.runtime.beginOutput(ownerID: prepared.ownerID,
                    executionID: prepared.executionID, attemptID: prepared.attemptID,
                    authorizationEpoch: lease.authorization.epoch, lease: lease)
                #expect(await prepared.runtime.publishOutput(ownerID: prepared.ownerID, answer: "Closing", thinking: ""))
                _ = try #require(await iterator.next())

                await prepared.runtime.close()
                let closing = try #require(await iterator.next())
                #expect(closing.isClosing)
                #expect(closing.value == nil)
                #expect(await iterator.next() == nil)
                let closedStream = try await prepared.runtime.outputObservations()
                var closedIterator = closedStream.makeAsyncIterator()
                let initialClosed = try #require(await closedIterator.next())
                #expect(initialClosed.isClosing)
                #expect(initialClosed.value == nil)
                #expect(await closedIterator.next() == nil)
                await lease.release()
            } catch {
                await lease.release()
                await prepared.runtime.close()
                throw error
            }
        }
    }

    @Test func enforcesObserverAndPayloadBounds() async throws {
        try await withTaskWorkflow { fixture in
            let prepared = try await makeOutputRuntime(fixture)
            let lease = try await fixture.access.acquire(in: fixture.scope)
            do {
                var streams: [AsyncStream<SessionOutputObservation>] = []
                for _ in 0..<256 { streams.append(try await prepared.runtime.outputObservations()) }
                await #expect(throws: MiraError.self) { try await prepared.runtime.outputObservations() }
                try await prepared.runtime.beginOutput(ownerID: prepared.ownerID,
                    executionID: prepared.executionID, attemptID: prepared.attemptID,
                    authorizationEpoch: lease.authorization.epoch, lease: lease)
                let oversizedAnswer = String(repeating: "x", count: 2 * 1_024 * 1_024 + 1)
                #expect(await !prepared.runtime.publishOutput(ownerID: prepared.ownerID,
                    answer: oversizedAnswer, thinking: ""))
                await prepared.runtime.releaseOutput(ownerID: prepared.ownerID)
                await lease.release()
                await prepared.runtime.close()
            } catch {
                await lease.release()
                await prepared.runtime.close()
                throw error
            }
        }
    }

    @Test func uncertainHiddenJournalCommitClearsOutputUntilReconciliation() async throws {
        try await withTaskWorkflow { fixture in
            let journal = HiddenCommitJournal(base: fixture.library)
            let prepared = try await makeOutputRuntime(fixture, journal: journal)
            let lease = try await fixture.access.acquire(in: fixture.scope)
            do {
                let stream = try await prepared.runtime.outputObservations()
                var iterator = stream.makeAsyncIterator()
                _ = try #require(await iterator.next())
                try await prepared.runtime.beginOutput(ownerID: prepared.ownerID,
                    executionID: prepared.executionID, attemptID: prepared.attemptID,
                    authorizationEpoch: lease.authorization.epoch, lease: lease)
                #expect(await prepared.runtime.publishOutput(ownerID: prepared.ownerID, answer: "Visible", thinking: ""))
                let live = try #require(await iterator.next())
                #expect(live.value?.answer == "Visible")
                await journal.armNextAppend()
                let uncertain = await prepared.runtime.commit(id: UUID()) { context in
                    let title = try await context.stageBytes(Data("Renamed".utf8), kind: .title, retentionGroup: UUID())
                    return [.renamed(title: title, revision: context.state.revision + 1)]
                }
                guard case .indeterminate = uncertain else {
                    throw MiraError(.storage, "The hidden journal acknowledgement was not surfaced as uncertainty.")
                }
                #expect(await prepared.runtime.currentObservation().requiresReconciliation)
                let cleared = try #require(await iterator.next())
                #expect(cleared.value == nil)
                #expect(cleared.revision > live.revision)
                #expect(await !prepared.runtime.publishOutput(ownerID: prepared.ownerID, answer: "Late", thinking: ""))
                let reconciled = await prepared.runtime.reconcile()
                guard case .committed = reconciled else {
                    throw MiraError(.storage, "The hidden journal append did not reconcile.")
                }
                #expect(await !prepared.runtime.currentObservation().requiresReconciliation)
                #expect(await !prepared.runtime.publishOutput(ownerID: prepared.ownerID, answer: "After reconcile", thinking: ""))
                let state = await prepared.runtime.snapshot()
                #expect(state.executions[prepared.executionID]?.completion == nil)
                #expect(state.attempts[prepared.attemptID]?.resolution == nil)
                let after = try await prepared.runtime.outputObservations()
                var afterIterator = after.makeAsyncIterator()
                #expect(try #require(await afterIterator.next()).value == nil)
                await lease.release()
                await prepared.runtime.close()
            } catch {
                await lease.release()
                await prepared.runtime.close()
                throw error
            }
        }
    }

    private struct PreparedOutput: Sendable {
        let runtime: SessionRuntime
        let executionID: ExecutionID
        let attemptID: UUID
        let stepID: UUID
        let ownerID: UUID
    }

    private func makeOutputRuntime(_ fixture: TaskWorkflowFixture,
                                   journal: (any SessionJournal & SessionPayloadStore)? = nil) async throws -> PreparedOutput {
        let store: any SessionJournal & SessionPayloadStore = journal ?? fixture.library
        let runtime = try await SessionRuntime.open(id: ConversationID(), journal: store, payloads: store)
        let executionID = ExecutionID(), attemptID = UUID(), stepID = UUID()
        do {
            let admitted = await runtime.commit(id: UUID()) { context in
                let title = try await context.stageBytes(Data("Output test".utf8), kind: .title, retentionGroup: UUID())
                let user = try await context.stageBytes(Data("Question".utf8), kind: .userText, retentionGroup: UUID())
                let plan = try await context.stage(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 1,
                    driverID: "mira.fixture", driverRevision: 1, instructions: "Answer.", limits: .init(),
                    priority: .foreground, route: fixture.route), kind: .executionPlan, retentionGroup: UUID())
                return [.opened(.init(workspaceID: nil, title: title)),
                    .admitted(.init(executionID: executionID, userMessageID: MessageID(), userBody: user,
                        plan: plan, hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
            }
            guard case .committed = admitted else { throw MiraError(.storage, "Output test admission failed.") }
            let started = await runtime.commit(id: UUID()) { context in
                let request = try await context.stageBytes(Data("request".utf8), kind: .request, retentionGroup: UUID())
                return [.phaseChanged(executionID: executionID, phase: .preparing),
                    .attemptStarted(.init(id: attemptID, executionID: executionID, stepID: stepID,
                        stepIndex: 1, attemptIndex: 1, request: request))]
            }
            guard case .committed = started else { throw MiraError(.storage, "Output test attempt failed.") }
            return .init(runtime: runtime, executionID: executionID, attemptID: attemptID,
                         stepID: stepID, ownerID: UUID())
        } catch {
            await runtime.close()
            throw error
        }
    }
}

private actor HiddenCommitJournal: SessionJournal, SessionPayloadStore {
    private let base: FileSessionLibrary
    private var armed = false

    func activeDraft(sessionID: ConversationID) async throws -> SessionActiveDraft? {
        try await base.activeDraft(sessionID: sessionID)
    }
    func saveActiveDraft(_ draft: SessionActiveDraft) async throws { try await base.saveActiveDraft(draft) }
    func removeActiveDraft(sessionID: ConversationID, attemptID: UUID) async throws {
        try await base.removeActiveDraft(sessionID: sessionID, attemptID: attemptID)
    }

    init(base: FileSessionLibrary) { self.base = base }

    func armNextAppend() { armed = true }

    func append(_ batch: SessionBatch) async -> SessionAppendOutcome {
        guard armed else { return await base.append(batch) }
        armed = false
        let outcome = await base.append(batch)
        guard case .committed = outcome else { return outcome }
        return .indeterminate(.init(.storage, "The hidden journal acknowledgement was lost."))
    }

    func reconcile(_ batch: SessionBatch) async -> SessionAppendOutcome { await base.reconcile(batch) }
    func batch(id: UUID, sessionID: ConversationID) async throws -> SessionBatch? { try await base.batch(id: id, sessionID: sessionID) }
    func head(sessionID: ConversationID) async throws -> SessionJournalHead { try await base.head(sessionID: sessionID) }
    func read(sessionID: ConversationID, after sequence: Int64, limit: Int) async throws -> [SessionBatch] {
        try await base.read(sessionID: sessionID, after: sequence, limit: limit)
    }
    func sessions(after: ConversationID?, limit: Int) async throws -> [ConversationID] {
        try await base.sessions(after: after, limit: limit)
    }
    func flush() async throws { try await base.flush() }
    func close() async throws { try await base.close() }
    func stage(_ data: Data, sessionID: ConversationID, batchID: UUID,
               retentionGroup: UUID, kind: SessionPayloadKind) async throws -> SessionPayloadReference {
        try await base.stage(data, sessionID: sessionID, batchID: batchID,
                             retentionGroup: retentionGroup, kind: kind)
    }
    func read(_ reference: SessionPayloadReference) async throws -> Data { try await base.read(reference) }
    func purge(sessionID: ConversationID, retentionGroups: Set<UUID>) async throws {
        try await base.purge(sessionID: sessionID, retentionGroups: retentionGroups)
    }
}
