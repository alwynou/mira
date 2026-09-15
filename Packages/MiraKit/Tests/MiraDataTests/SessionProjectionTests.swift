import Foundation
import Testing
import GRDB
@testable import MiraCore
@testable import MiraData

@Suite("Session projection", .timeLimit(.minutes(1)))
struct SessionProjectionTests {
    @Test func projectionApplyIsIdempotentAndRejectsConflictsAndGaps() async throws {
        let fixture = try await ProjectionFixture.make()
        do {
            let session = try await fixture.openSession(title: "Original")
            let batches = try await fixture.library.read(sessionID: session.id, after: 0, limit: 16)
            let opened = try #require(batches.first)
            for batch in batches { try await fixture.projection.apply(batch) }
            let before = try #require(try await fixture.projection.head(sessionID: session.id))
            let beforeSummary = try #require(try await fixture.projection.session(id: session.id))
            for batch in batches { try await fixture.projection.apply(batch) }
            #expect(try await fixture.projection.messages(sessionID: session.id, beforeSequence: nil, limit: 16).count == 1)
            #expect(try await fixture.projection.head(sessionID: session.id) == before)

            let altered = SessionBatch(id: opened.id, sessionID: opened.sessionID, expectedSequence: opened.expectedSequence,
                events: opened.events.map { .init(id: UUID(), sequence: $0.sequence, occurredAt: $0.occurredAt.addingTimeInterval(1), fact: $0.fact) })
            await #expect(throws: MiraError.self) { try await fixture.projection.apply(altered) }
            let skipped = SessionBatch(id: UUID(), sessionID: session.id, expectedSequence: before.cursor.sequence + 10,
                events: [.init(sequence: before.cursor.sequence + 11, occurredAt: Date(), fact: .renamed(title: opened.events[0].fact.titleReference!, revision: 2))])
            await #expect(throws: MiraError.self) { try await fixture.projection.apply(skipped) }
            #expect(try await fixture.projection.head(sessionID: session.id) == before)
            #expect(try await fixture.projection.session(id: session.id) == beforeSummary)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func retryKeepsOneUserMessageAndPagesQueryRowsWithScopeAndTies() async throws {
        let fixture = try await ProjectionFixture.make()
        do {
            let workspace = WorkspaceID()
            let first = try await fixture.openSession(title: "Retry", workspaceID: workspace, finish: .failed, at: Date(timeIntervalSince1970: 100))
            _ = try await fixture.retry(session: first)
            let archived = try await fixture.openSession(title: "Archived", finish: .failed, at: Date(timeIntervalSince1970: 100), archive: true)
            let current = try await fixture.openSession(title: "Current", workspaceID: workspace, at: Date(timeIntervalSince1970: 100))
            try await fixture.renameAt(session: current, title: "Current older", revision: 2, at: Date(timeIntervalSince1970: 50))
            _ = try await fixture.coordinator.catchUp(sessionID: first.id)
            _ = try await fixture.coordinator.catchUp(sessionID: archived.id)
            _ = try await fixture.coordinator.catchUp(sessionID: current.id)

            let messages = try await fixture.projection.messages(sessionID: first.id, beforeSequence: nil, limit: 16)
            #expect(messages.filter { $0.role == .user }.count == 1)
            #expect(messages.filter { $0.role == .assistant }.count == 1)
            #expect(try await fixture.projection.executions(sessionID: first.id, beforeSequence: nil, limit: 16).count == 2)

            let workspaceRows = try await fixture.projection.sessions(scope: .workspace(workspace), includeArchived: false, after: nil, limit: 16)
            #expect(Set(workspaceRows.map(\.id)) == Set([first.id, current.id]))
            let inboxRows = try await fixture.projection.sessions(scope: .inbox, includeArchived: false, after: nil, limit: 16)
            #expect(inboxRows.isEmpty)
            let archivedInboxRows = try await fixture.projection.sessions(scope: .inbox, includeArchived: true, after: nil, limit: 16)
            #expect(archivedInboxRows.map(\.id) == [archived.id])
            let allRows = try await fixture.projection.sessions(scope: .all, includeArchived: true, after: nil, limit: 16)
            #expect(Set(allRows.map(\.id)) == Set([first.id, archived.id, current.id]))
            #expect(try await fixture.projection.session(id: current.id)?.updatedAt == Date(timeIntervalSince1970: 100))
            #expect(allRows.map(\.id) == allRows.map(\.id).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString })
            let page = try await fixture.projection.sessions(scope: .all, includeArchived: true, after: nil, limit: 1)
            #expect(page == Array(allRows.prefix(1)))
            let row = try #require(page.first)
            let cursor = SessionListCursor(updatedAt: row.updatedAt, sessionID: row.id)
            let next = try await fixture.projection.sessions(scope: .all, includeArchived: true, after: cursor, limit: 16)
            #expect(next.map(\.id) == Array(allRows.dropFirst()).map(\.id))

            let messageRows = try await fixture.projection.messages(sessionID: first.id, beforeSequence: nil, limit: 16)
            let newestMessage = try #require(messageRows.first)
            #expect(try await fixture.projection.messages(sessionID: first.id, beforeSequence: newestMessage.sequence, limit: 16) == Array(messageRows.dropFirst()))
            let executionRows = try await fixture.projection.executions(sessionID: first.id, beforeSequence: nil, limit: 16)
            let newestExecution = try #require(executionRows.first)
            #expect(try await fixture.projection.executions(sessionID: first.id, beforeSequence: newestExecution.sequence, limit: 16) == Array(executionRows.dropFirst()))
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func messagePageLinksRowsIncludesActiveExecutionAndPaginatesAtomically() async throws {
        let fixture = try await ProjectionFixture.make()
        do {
            let session = try await fixture.openSession(title: "Page", finish: .failed)
            let retry = try await fixture.retry(session: session)
            _ = try await fixture.coordinator.catchUp(sessionID: session.id)

            let all = try await fixture.projection.messagePage(sessionID: session.id, beforeSequence: nil, limit: 128)
            let allSession = try #require(all.session)
            #expect(all.messages.filter { $0.role == .user }.count == 1)
            #expect(all.messages.count == 2)
            #expect(all.executions.map(\.id) == [retry.executionID, session.executionID])
            #expect(all.messages.map(\.sequence) == all.messages.map(\.sequence).sorted(by: >))
            #expect(!all.hasMore)
            #expect(allSession.activeExecutionID == retry.executionID)
            #expect(allSession.latestExecutionID == retry.executionID)

            let first = try await fixture.projection.messagePage(sessionID: session.id, beforeSequence: nil, limit: 1)
            let firstMessage = try #require(first.messages.first)
            #expect(first.hasMore)
            #expect(first.messages.count == 1)
            #expect(first.executions.map(\.id) == [retry.executionID, session.executionID])
            let second = try await fixture.projection.messagePage(sessionID: session.id, beforeSequence: firstMessage.sequence, limit: 1)
            #expect(second.messages.count == 1)
            #expect(!second.hasMore)
            #expect(second.messages.first?.sequence == all.messages.last?.sequence)
            #expect(second.executions.map(\.id) == [retry.executionID, session.executionID])

            let unknown = try await fixture.projection.messagePage(sessionID: ConversationID(), beforeSequence: nil, limit: 1)
            #expect(unknown == .init(session: nil, messages: [], executions: [], hasMore: false))
            await #expect(throws: MiraError.self) {
                try await fixture.projection.messagePage(sessionID: session.id, beforeSequence: nil, limit: 0)
            }
            await #expect(throws: MiraError.self) {
                try await fixture.projection.messagePage(sessionID: session.id, beforeSequence: -1, limit: 1)
            }
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func messagePageRetainsLatestFailedNoOutputRetryAcrossOlderPages() async throws {
        let fixture = try await ProjectionFixture.make()
        do {
            let session = try await fixture.openSession(title: "No output retry")
            try await fixture.finishWithoutOutput(executionID: session.executionID, status: .failed)
            let retry = try await fixture.retry(session: session)
            try await fixture.finishWithoutOutput(executionID: retry.executionID, status: .failed)
            _ = try await fixture.coordinator.catchUp(sessionID: session.id)

            let newest = try await fixture.projection.messagePage(sessionID: session.id, beforeSequence: nil, limit: 1)
            let user = try #require(newest.messages.first)
            #expect(newest.messages.count == 1)
            #expect(!newest.hasMore)
            #expect(newest.executions.map(\.id) == [retry.executionID, session.executionID])
            #expect(newest.session?.latestExecutionID == retry.executionID)

            let older = try await fixture.projection.messagePage(
                sessionID: session.id, beforeSequence: user.sequence, limit: 1)
            #expect(older.messages.isEmpty)
            #expect(!older.hasMore)
            #expect(older.executions.map(\.id) == [retry.executionID])
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func rebuildRestoresRowsWithoutChangingJournalOrBusinessSentinel() async throws {
        let fixture = try await ProjectionFixture.make()
        do {
            let session = try await fixture.openSession(title: "Rebuild", finish: .completed)
            let journalHead = try await fixture.library.head(sessionID: session.id)
            _ = try await fixture.coordinator.catchUp(sessionID: session.id)
            let expectedSession = try #require(try await fixture.projection.session(id: session.id))
            let expectedMessages = try await fixture.projection.messages(sessionID: session.id, beforeSequence: nil, limit: 16)
            let expectedExecutions = try await fixture.projection.executions(sessionID: session.id, beforeSequence: nil, limit: 16)
            await fixture.coordinator.close()
            try await fixture.projection.close()
            try FileManager.default.removeItem(atPath: fixture.projectionPath)
            fixture.projection = try SQLiteSessionProjection(path: fixture.projectionPath)
            fixture.coordinator = try SessionProjectionCoordinator(journal: fixture.library, projection: fixture.projection)
            _ = try await fixture.coordinator.rebuild(sessionID: session.id)
            #expect(try await fixture.projection.session(id: session.id) == expectedSession)
            #expect(try await fixture.projection.messages(sessionID: session.id, beforeSequence: nil, limit: 16) == expectedMessages)
            #expect(try await fixture.projection.executions(sessionID: session.id, beforeSequence: nil, limit: 16) == expectedExecutions)
            #expect(try await fixture.library.head(sessionID: session.id) == journalHead)
            let sentinel = try DatabaseQueue(path: fixture.sentinelPath)
            defer { try? sentinel.close() }
            let sentinelValue: String? = try await sentinel.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM sentinel LIMIT 1")
            }
            #expect(sentinelValue == "business-sentinel")
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func invalidatedGroupsMarkPurgedContextWhileVisibleAnswerBodyRemainsRetained() async throws {
        let fixture = try await ProjectionFixture.make()
        do {
            let session = try await fixture.openSession(title: "Privacy", finish: .failed)
            let retry = try await fixture.retry(session: session)
            try await fixture.finish(executionID: retry.executionID, status: .failed)
            let state = await fixture.runtime.snapshot()
            let completion = try #require(state.executions[session.executionID]?.completion)
            let visibleAnswer = try #require(completion.answer)
            let hiddenGroups = Set(state.references.values.compactMap { reference in
                [.title, .userText, .visibleAnswer, .visibleThinking].contains(reference.kind) ? nil : reference.retentionGroup
            })
            let executionIDs = Set([session.executionID, retry.executionID])
            try requireCommitted(await fixture.runtime.commit(id: UUID()) { _ in
                [.invalidated(.init(operationID: UUID(), executionIDs: executionIDs,
                    retentionGroups: hiddenGroups, authorizationEpoch: 1, reason: .forgotten))]
            })
            try await fixture.library.purge(sessionID: session.id, retentionGroups: hiddenGroups)
            _ = try await fixture.coordinator.catchUp(sessionID: session.id)
            let rows = try await fixture.projection.messages(sessionID: session.id, beforeSequence: nil, limit: 16)
            let user = try #require(rows.first { $0.role == .user })
            let assistants = rows.filter { $0.role == .assistant }
            #expect(user.isExcludedFromContext && user.body != nil && !user.bodyInvalidated)
            #expect(assistants.count == 2 && assistants.allSatisfy { $0.isExcludedFromContext && $0.body != nil && !$0.bodyInvalidated })
            let executionRows = try await fixture.projection.executions(sessionID: session.id, beforeSequence: nil, limit: 16)
            #expect(executionRows.count == 2 && executionRows.allSatisfy { $0.isExcludedFromContext && $0.completion?.error != nil })
            #expect(try await fixture.library.read(visibleAnswer) == Data("Answer".utf8))
            for execution in executionRows {
                let error = try #require(execution.completion?.error)
                await #expect(throws: MiraError.self) { try await fixture.library.read(error) }
            }

            let userGroup = try #require(state.references.values.first { $0.kind == .userText }?.retentionGroup)
            try requireCommitted(await fixture.runtime.commit(id: UUID()) { _ in
                [.invalidated(.init(operationID: UUID(), executionIDs: executionIDs,
                    retentionGroups: [userGroup], authorizationEpoch: 2, reason: .forgotten))]
            })
            try await fixture.library.purge(sessionID: session.id, retentionGroups: [userGroup])
            _ = try await fixture.coordinator.catchUp(sessionID: session.id)
            let afterUserPurge = try await fixture.projection.messages(sessionID: session.id, beforeSequence: nil, limit: 16)
            let purgedUser = try #require(afterUserPurge.first { $0.role == .user })
            let retainedAssistants = afterUserPurge.filter { $0.role == .assistant }
            #expect(purgedUser.body != nil && purgedUser.bodyInvalidated)
            #expect(retainedAssistants.count == 2 && retainedAssistants.allSatisfy { !$0.bodyInvalidated && $0.body != nil })
            #expect(try await fixture.library.read(visibleAnswer) == Data("Answer".utf8))

            let page = try await fixture.projection.messagePage(sessionID: session.id, beforeSequence: nil, limit: 16)
            let pageUser = try #require(page.messages.first { $0.role == .user })
            #expect(pageUser.bodyInvalidated)
            #expect(page.messages.filter { $0.role == .assistant }.allSatisfy { !$0.bodyInvalidated })
            #expect(page.executions.allSatisfy { $0.isExcludedFromContext })
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func coordinatorLeavesCheckpointOnFailureAndRejectsUnknownExtensionsAndBadCheckpoint() async throws {
        let fixture = try await ProjectionFixture.make()
        do {
            let session = try await fixture.openSession(title: "Failure")
            try await fixture.rename(session: session, title: "Later", revision: 2)
            let target = try await fixture.library.head(sessionID: session.id)
            try await fixture.rename(session: session, title: "Latest", revision: 3)
            let later = try await fixture.library.head(sessionID: session.id)
            let failing = ProjectionStoreForwarder(base: fixture.projection, failAfterSequence: target.cursor.sequence)
            await fixture.coordinator.close()
            fixture.coordinator = try SessionProjectionCoordinator(journal: fixture.library, projection: failing)
            await #expect(throws: MiraError.self) { try await fixture.coordinator.catchUp(through: later) }
            #expect(try await fixture.projection.head(sessionID: session.id) == target)
            await failing.setFailAfterSequence(nil)
            _ = try await fixture.coordinator.catchUp(through: later)
            #expect(try await fixture.projection.head(sessionID: session.id) == later)

            let bad = ProjectionStoreForwarder(base: fixture.projection,
                headOverride: .init(cursor: .init(sessionID: session.id, sequence: later.cursor.sequence + 1), batchID: UUID()))
            await fixture.coordinator.close()
            fixture.coordinator = try SessionProjectionCoordinator(journal: fixture.library, projection: bad)
            await #expect(throws: MiraError.self) { try await fixture.coordinator.catchUp(sessionID: session.id) }

            let extensionID = UUID()
            let body = try await fixture.library.stage(Data("extension".utf8), sessionID: session.id, batchID: extensionID,
                retentionGroup: UUID(), kind: .module)
            let head = try await fixture.library.head(sessionID: session.id)
            let extensionBatch = SessionBatch(id: extensionID, sessionID: session.id, expectedSequence: head.cursor.sequence,
                events: [.init(sequence: head.cursor.sequence + 1, occurredAt: Date(), fact: .extensionRecorded(namespace: "tests.unknown", schemaVersion: 1, required: true, body: body))])
            try requireAppended(await fixture.library.append(extensionBatch))
            await fixture.coordinator.close()
            fixture.coordinator = try SessionProjectionCoordinator(journal: fixture.library, projection: fixture.projection)
            await #expect(throws: MiraError.self) { try await fixture.coordinator.catchUp(sessionID: session.id) }
            #expect(try await fixture.projection.head(sessionID: session.id) == later)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }
}

private struct SessionFixture {
    let id: ConversationID
    let executionID: ExecutionID
    let userMessageID: MessageID
}

private final class ProjectionFixture: @unchecked Sendable {
    let root: URL
    let library: FileSessionLibrary
    let sentinelPath: String
    let projectionPath: String
    var projection: SQLiteSessionProjection
    var coordinator: SessionProjectionCoordinator
    var runtime: SessionRuntime!
    private var closed = false

    private init(root: URL, library: FileSessionLibrary, projection: SQLiteSessionProjection,
                 coordinator: SessionProjectionCoordinator) {
        self.root = root; self.library = library; self.projection = projection; self.coordinator = coordinator
        projectionPath = root.appendingPathComponent("projection.sqlite").path
        sentinelPath = root.appendingPathComponent("business.sqlite").path
    }

    static func make(extensionSchemas: [String: Set<Int>] = [:]) async throws -> ProjectionFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mira-session-projection-\(UUID().uuidString)")
        var library: FileSessionLibrary?
        var projection: SQLiteSessionProjection?
        var coordinator: SessionProjectionCoordinator?
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = try FileSessionLibrary(directory: root.appendingPathComponent("journal"))
            let projectionPath = root.appendingPathComponent("projection.sqlite").path
            projection = try SQLiteSessionProjection(path: projectionPath)
            coordinator = try SessionProjectionCoordinator(journal: library!, projection: projection!, extensionSchemas: extensionSchemas)
            let fixture = ProjectionFixture(root: root, library: library!, projection: projection!, coordinator: coordinator!)
            let sentinel = try DatabaseQueue(path: root.appendingPathComponent("business.sqlite").path)
            defer { try? sentinel.close() }
            try await sentinel.write { db in
                try db.execute(sql: "CREATE TABLE sentinel(value TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO sentinel(value) VALUES (?)", arguments: ["business-sentinel"])
            }
            return fixture
        } catch {
            if let coordinator { await coordinator.close() }
            if let projection { try? await projection.close() }
            if let library { try? await library.close() }
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func openSession(title: String, workspaceID: WorkspaceID? = nil, finish: ExecutionStatus? = nil,
                     at date: Date = Date(), archive: Bool = false) async throws -> SessionFixture {
        if let runtime { await runtime.close() }
        let id = ConversationID(), executionID = ExecutionID(), userMessageID = MessageID()
        runtime = try await SessionRuntime.open(id: id, journal: library, payloads: library,
            environment: .init(now: { date }))
        try requireCommitted(await runtime.commit(id: UUID()) { context in
            let title = try await context.stageBytes(Data(title.utf8), kind: .title, retentionGroup: UUID())
            return [.opened(.init(workspaceID: workspaceID, title: title))]
        })
        try requireCommitted(await runtime.commit(id: UUID()) { context in
            let user = try await context.stageBytes(Data("Question".utf8), kind: .userText, retentionGroup: UUID())
            let plan = try await context.stage(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 1, driverID: "mira.default", driverRevision: 1, instructions: "", limits: .init(), priority: .foreground, route: nil), kind: .executionPlan, retentionGroup: UUID())
            return [.admitted(.init(executionID: executionID, userMessageID: userMessageID, userBody: user, plan: plan, hasModelRoute: false, authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
        })
        if let finish {
            try requireCommitted(await runtime.commit(id: UUID()) { context in
                let answer = try await context.stageBytes(Data("Answer".utf8), kind: .visibleAnswer, retentionGroup: UUID())
                let thinking = try await context.stageBytes(Data("Thinking".utf8), kind: .visibleThinking, retentionGroup: UUID())
                let error = finish == .completed ? nil : try await context.stageBytes(Data("Hidden error".utf8), kind: .error, retentionGroup: UUID())
                let completion = SessionCompletion(executionID: executionID, status: finish, assistantMessageID: MessageID(), answer: answer, visibleThinking: thinking, error: error)
                return [.phaseChanged(executionID: executionID, phase: .settling), .finished(completion)]
            })
        }
        if archive { try requireCommitted(await runtime.commit(id: UUID()) { _ in [.archived(revision: 2)] }) }
        return .init(id: id, executionID: executionID, userMessageID: userMessageID)
    }

    func retry(session: SessionFixture) async throws -> SessionFixture {
        let retryID = ExecutionID()
        try requireCommitted(await runtime.commit(id: UUID()) { context in
            let plan = try await context.stage(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 1, driverID: "mira.default", driverRevision: 1, instructions: "", limits: .init(), priority: .foreground, route: nil), kind: .executionPlan, retentionGroup: UUID())
            return [.admitted(.init(executionID: retryID, userMessageID: session.userMessageID, retryOfExecutionID: session.executionID, userBody: nil, plan: plan, hasModelRoute: false, authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
        })
        return .init(id: session.id, executionID: retryID, userMessageID: session.userMessageID)
    }

    func finish(executionID: ExecutionID, status: ExecutionStatus) async throws {
        try requireCommitted(await runtime.commit(id: UUID()) { context in
            let answer = try await context.stageBytes(Data("Answer".utf8), kind: .visibleAnswer, retentionGroup: UUID())
            let thinking = try await context.stageBytes(Data("Thinking".utf8), kind: .visibleThinking, retentionGroup: UUID())
            let error = status == .completed ? nil : try await context.stageBytes(Data("Hidden error".utf8), kind: .error, retentionGroup: UUID())
            let completion = SessionCompletion(executionID: executionID, status: status, assistantMessageID: MessageID(), answer: answer, visibleThinking: thinking, error: error)
            return [.phaseChanged(executionID: executionID, phase: .settling), .finished(completion)]
        })
    }

    func finishWithoutOutput(executionID: ExecutionID, status: ExecutionStatus) async throws {
        try requireCommitted(await runtime.commit(id: UUID()) { context in
            let error = try await context.stageBytes(Data("No visible output".utf8), kind: .error, retentionGroup: UUID())
            let completion = SessionCompletion(executionID: executionID, status: status, error: error)
            return [.phaseChanged(executionID: executionID, phase: .settling), .finished(completion)]
        })
    }

    func rename(session: SessionFixture, title: String, revision: Int) async throws {
        try requireCommitted(await runtime.commit(id: UUID()) { context in
            let reference = try await context.stageBytes(Data(title.utf8), kind: .title, retentionGroup: UUID())
            return [.renamed(title: reference, revision: revision)]
        })
    }

    func renameAt(session: SessionFixture, title: String, revision: Int, at date: Date) async throws {
        await runtime?.close()
        runtime = try await SessionRuntime.open(id: session.id, journal: library, payloads: library,
            environment: .init(now: { date }))
        try await rename(session: session, title: title, revision: revision)
    }

    func close() async {
        guard !closed else { return }; closed = true
        await runtime?.close()
        await coordinator.close(); try? await projection.close(); try? await library.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ProjectionStoreForwarder: SessionProjectionStore {
    let base: any SessionProjectionStore
    private var failAfterSequence: Int64?
    let headOverride: SessionJournalHead?
    init(base: any SessionProjectionStore, failAfterSequence: Int64? = nil, headOverride: SessionJournalHead? = nil) {
        self.base = base; self.failAfterSequence = failAfterSequence; self.headOverride = headOverride
    }
    func setFailAfterSequence(_ value: Int64?) { failAfterSequence = value }
    func head(sessionID: ConversationID) async throws -> SessionJournalHead? {
        if let headOverride { return headOverride }
        return try await base.head(sessionID: sessionID)
    }
    func apply(_ batch: SessionBatch) async throws {
        if let failAfterSequence, batch.cursor.sequence > failAfterSequence { throw MiraError(.storage, "Synthetic projection failure.") }
        try await base.apply(batch)
    }
    func reset(sessionID: ConversationID) async throws { try await base.reset(sessionID: sessionID) }
    func session(id: ConversationID) async throws -> SessionSummary? { try await base.session(id: id) }
    func sessions(scope: SessionQueryScope, includeArchived: Bool, after: SessionListCursor?, limit: Int) async throws -> [SessionSummary] { try await base.sessions(scope: scope, includeArchived: includeArchived, after: after, limit: limit) }
    func messages(sessionID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> [SessionMessageSummary] { try await base.messages(sessionID: sessionID, beforeSequence: beforeSequence, limit: limit) }
    func messagePage(sessionID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> SessionProjectionMessagePage { try await base.messagePage(sessionID: sessionID, beforeSequence: beforeSequence, limit: limit) }
    func executions(sessionID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> [SessionExecutionSummary] { try await base.executions(sessionID: sessionID, beforeSequence: beforeSequence, limit: limit) }
    func close() async throws { try await base.close() }
}

private func requireCommitted(_ result: SessionCommitResult) throws {
    guard case .committed = result else {
        if case .notCommitted(let error) = result { throw error }
        throw MiraError(.storage, "Synthetic session command did not commit.")
    }
}

private func requireAppended(_ result: SessionAppendOutcome) throws {
    guard case .committed = result else { throw MiraError(.storage, "Synthetic journal append did not commit.") }
}

private extension SessionFact {
    var titleReference: SessionPayloadReference? { if case .opened(let header) = self { return header.title }; return nil }
}
