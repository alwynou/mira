import Foundation
import Testing
import GRDB
@testable import MiraCore
@testable import MiraData

@Suite("Session projection lifecycle", .timeLimit(.minutes(1)))
struct SessionProjectionLifecycleTests {
    @Test("Close cancels projection work but waits for a blocked apply to drain")
    func closeDrainsBlockedApplyAndRejectsNewWork() async throws {
        try await withProjectionFixture { fixture in
            try await withSQLiteProjection(fixture) { base in
                let gate = ProjectionGate()
                await gate.arm()
                let projection = ProjectionDelegate(base: base, gate: gate)
                let coordinator = try SessionProjectionCoordinator(journal: fixture.library, projection: projection)
                do {
                    let replay = Task { try await coordinator.catchUp(through: fixture.initialHead) }
                    await gate.waitUntilEntered()
                    let closing = Task {
                        await coordinator.close()
                        await gate.markCloseReturned()
                    }
                    await gate.waitUntilOwnerCancelled()
                    await #expect(throws: MiraError.self) {
                        _ = try await coordinator.catchUp(through: fixture.initialHead)
                    }
                    #expect(await gate.isBlocked)
                    #expect(await gate.closeReturned == false)
                    await gate.release()
                    await closing.value
                    #expect(await gate.closedWhileBlocked == false)
                    _ = try await replay.value
                    #expect(await projection.applyCount == 1)
                } catch {
                    await gate.release()
                    await coordinator.close()
                    throw error
                }
            }
        }
    }

    @Test("Same-session waiters share one replay and cancellation does not lose the checkpoint")
    func sharedReplayHasOneEffectiveApply() async throws {
        try await withProjectionFixture { fixture in
            try await withSQLiteProjection(fixture) { base in
                let gate = ProjectionGate()
                await gate.arm()
                let projection = ProjectionDelegate(base: base, gate: gate)
                let coordinator = try SessionProjectionCoordinator(journal: fixture.library, projection: projection)
                do {
                    let first = Task { try await coordinator.catchUp(through: fixture.initialHead) }
                    await gate.waitUntilEntered()
                    let waiter = Task { try await coordinator.catchUp(through: fixture.initialHead) }
                    let survivor = Task { try await coordinator.catchUp(through: fixture.initialHead) }
                    waiter.cancel()
                    await gate.release()
                    #expect(try await first.value == fixture.initialHead)
                    #expect(try await survivor.value == fixture.initialHead)
                    do {
                        _ = try await waiter.value
                        Issue.record("Cancelled waiter unexpectedly succeeded")
                    } catch {
                        #expect(error is CancellationError || (error as? MiraError)?.code == .cancelled)
                    }
                    #expect(await projection.applyCount == 1)
                    #expect(try await projection.head(sessionID: fixture.sessionID) == fixture.initialHead)
                } catch {
                    await gate.release()
                    await coordinator.close()
                    throw error
                }
                await coordinator.close()
            }
        }
    }

    @Test("A fixed old head stops before a later append")
    func fixedHeadDoesNotIncludeLaterAppend() async throws {
        try await withProjectionFixture { fixture in
            try await withSQLiteProjection(fixture) { projection in
                let coordinator = try SessionProjectionCoordinator(journal: fixture.library, projection: projection)
                do {
                    let later = try await fixture.appendRename(title: "Later")
                    #expect(later.cursor.sequence > fixture.initialHead.cursor.sequence)
                    #expect(try await coordinator.catchUp(through: fixture.initialHead) == fixture.initialHead)
                    #expect(try await projection.head(sessionID: fixture.sessionID) == fixture.initialHead)
                    #expect(try await coordinator.catchUp(through: later) == later)
                    #expect(try await projection.head(sessionID: fixture.sessionID) == later)
                    #expect(try await projection.session(id: fixture.sessionID)?.revision == 2)
                } catch {
                    await coordinator.close()
                    throw error
                }
                await coordinator.close()
            }
        }
    }

    @Test("Unknown schema, invalid rows, and invalid page cursors fail as MiraError")
    func corruptionAndBoundsFailClosed() async throws {
        let schemaDirectory = try temporaryProjectionDirectory()
        do {
            let path = schemaDirectory.appendingPathComponent("projection.sqlite")
            let projection = try SQLiteSessionProjection(path: path.path)
            try await projection.close()
            let database = try DatabaseQueue(path: path.path)
            try await database.write { db in try db.execute(sql: "PRAGMA user_version = 99") }
            #expect(throws: MiraError.self) { _ = try SQLiteSessionProjection(path: path.path) }
            remove(schemaDirectory)
        } catch {
            remove(schemaDirectory)
            throw error
        }

        try await withProjectionFixture { fixture in
            let projection = try SQLiteSessionProjection(path: fixture.projectionPath.path)
            do {
                try await projection.apply(fixture.initialBatch)
                await #expect(throws: MiraError.self) { try await projection.messages(sessionID: fixture.sessionID, beforeSequence: nil, limit: 0) }
                await #expect(throws: MiraError.self) { try await projection.executions(sessionID: fixture.sessionID, beforeSequence: -1, limit: 1) }
                try await projection.close()

                let database = try DatabaseQueue(path: fixture.projectionPath.path)
                try await database.write { db in
                    try db.execute(sql: "UPDATE projection_sessions SET head_batch_id = 'not-a-uuid' WHERE session_id = ?",
                                   arguments: [fixture.sessionID.rawValue.uuidString])
                }
                let invalidBatchProjection = try SQLiteSessionProjection(path: fixture.projectionPath.path)
                do {
                    await #expect(throws: MiraError.self) { try await invalidBatchProjection.head(sessionID: fixture.sessionID) }
                    try await invalidBatchProjection.close()
                } catch {
                    try? await invalidBatchProjection.close()
                    throw error
                }
            } catch {
                try? await projection.close()
                throw error
            }
        }
    }

    @Test("Invalid execution enum rows fail without crashing")
    func invalidExecutionPhaseFailsClosed() async throws {
        try await withProjectionFixture { fixture in
            let admission = try await fixture.appendAdmission()
            try await withSQLiteProjection(fixture) { projection in
                try await projection.apply(fixture.initialBatch)
                try await projection.apply(admission)
                try await projection.close()
                let database = try DatabaseQueue(path: fixture.projectionPath.path)
                try await database.write { db in
                    try db.execute(sql: "UPDATE projection_executions SET phase = 'corrupt' WHERE session_id = ?",
                                   arguments: [fixture.sessionID.rawValue.uuidString])
                }
                let corrupted = try SQLiteSessionProjection(path: fixture.projectionPath.path)
                do {
                    await #expect(throws: MiraError.self) {
                        try await corrupted.executions(sessionID: fixture.sessionID, beforeSequence: nil, limit: 10)
                    }
                    try await corrupted.close()
                } catch {
                    try? await corrupted.close()
                    throw error
                }
            }
        }
    }

    @Test("A failed multi-event apply rolls back rows, checkpoint, and batch identity")
    func failedBatchIsAtomic() async throws {
        try await withProjectionFixture { fixture in
            try await withSQLiteProjection(fixture) { projection in
                try await projection.apply(fixture.initialBatch)
                let batchID = UUID()
                let title = try await fixture.library.stage(Data("Broken".utf8), sessionID: fixture.sessionID,
                                                            batchID: batchID, retentionGroup: UUID(), kind: .title)
                let broken = SessionBatch(id: batchID, sessionID: fixture.sessionID,
                    expectedSequence: fixture.initialHead.cursor.sequence, events: [
                        .init(sequence: fixture.initialHead.cursor.sequence + 1, occurredAt: Date(),
                              fact: .renamed(title: title, revision: 2)),
                        .init(sequence: fixture.initialHead.cursor.sequence + 2, occurredAt: Date(),
                              fact: .phaseChanged(executionID: ExecutionID(), phase: .preparing))
                    ])
                await #expect(throws: MiraError.self) { try await projection.apply(broken) }
                #expect(try await projection.head(sessionID: fixture.sessionID) == fixture.initialHead)
                #expect(try await projection.session(id: fixture.sessionID)?.revision == 1)
                #expect(try await projection.session(id: fixture.sessionID)?.title == fixture.initialTitle)
                try await projection.close()
                let database = try DatabaseQueue(path: fixture.projectionPath.path)
                #expect(try await database.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM projection_batches WHERE session_id = ? AND batch_id = ?",
                                     arguments: [fixture.sessionID.rawValue.uuidString, batchID.uuidString])
                } == 0)
            }
        }
    }
}

private final class ProjectionFixture: @unchecked Sendable {
    let directory: URL
    let library: FileSessionLibrary
    let sessionID: ConversationID
    let projectionPath: URL
    let initialBatch: SessionBatch
    let initialHead: SessionJournalHead
    let initialTitle: SessionPayloadReference

    static func make() async throws -> ProjectionFixture {
        let directory = try temporaryProjectionDirectory()
        var openedLibrary: FileSessionLibrary?
        do {
            let library = try FileSessionLibrary(directory: directory)
            openedLibrary = library
            let sessionID = ConversationID()
            let batchID = UUID()
            let title = try await library.stage(Data("Initial".utf8), sessionID: sessionID, batchID: batchID,
                                                retentionGroup: UUID(), kind: .title)
            let batch = SessionBatch(id: batchID, sessionID: sessionID, expectedSequence: 0,
                events: [.init(sequence: 1, occurredAt: Date(), fact: .opened(.init(workspaceID: nil, title: title)))])
            guard await library.append(batch) == .committed(batch.cursor) else {
                try? await library.close(); remove(directory)
                throw MiraError(.storage, "The projection fixture could not commit its opening batch.")
            }
            return ProjectionFixture(directory: directory, library: library, sessionID: sessionID,
                projectionPath: directory.appendingPathComponent("projection.sqlite"), initialBatch: batch,
                initialHead: .init(cursor: batch.cursor, batchID: batch.id), initialTitle: title)
        } catch {
            try? await openedLibrary?.close()
            remove(directory)
            throw error
        }
    }

    func appendRename(title: String) async throws -> SessionJournalHead {
        let head = try await library.head(sessionID: sessionID)
        let batchID = UUID()
        let reference = try await library.stage(Data(title.utf8), sessionID: sessionID, batchID: batchID,
                                                retentionGroup: UUID(), kind: .title)
        let batch = SessionBatch(id: batchID, sessionID: sessionID, expectedSequence: head.cursor.sequence,
            events: [.init(sequence: head.cursor.sequence + 1, occurredAt: Date(),
                            fact: .renamed(title: reference, revision: 2))])
        guard await library.append(batch) == .committed(batch.cursor) else {
            throw MiraError(.storage, "The projection fixture could not commit its rename batch.")
        }
        return .init(cursor: batch.cursor, batchID: batch.id)
    }

    func appendAdmission() async throws -> SessionBatch {
        let head = try await library.head(sessionID: sessionID)
        let batchID = UUID()
        let body = try await library.stage(Data("Question".utf8), sessionID: sessionID, batchID: batchID,
                                           retentionGroup: UUID(), kind: .userText)
        let plan = try await library.stage(Data("Plan".utf8), sessionID: sessionID, batchID: batchID,
                                           retentionGroup: UUID(), kind: .executionPlan)
        let batch = SessionBatch(id: batchID, sessionID: sessionID, expectedSequence: head.cursor.sequence,
            events: [.init(sequence: head.cursor.sequence + 1, occurredAt: Date(),
                            fact: .admitted(.init(executionID: ExecutionID(), userMessageID: MessageID(), userBody: body,
                                                  plan: plan, hasModelRoute: false, authorizationEpoch: 0,
                                                  timeZoneIdentifier: "UTC")))])
        guard await library.append(batch) == .committed(batch.cursor) else {
            throw MiraError(.storage, "The projection fixture could not commit its admission batch.")
        }
        return batch
    }

    func close() async {
        try? await library.close()
        remove(directory)
    }

    private init(directory: URL, library: FileSessionLibrary, sessionID: ConversationID, projectionPath: URL,
                 initialBatch: SessionBatch, initialHead: SessionJournalHead, initialTitle: SessionPayloadReference) {
        self.directory = directory; self.library = library; self.sessionID = sessionID; self.projectionPath = projectionPath
        self.initialBatch = initialBatch; self.initialHead = initialHead; self.initialTitle = initialTitle
    }
}

private func withProjectionFixture<T>(_ body: (ProjectionFixture) async throws -> T) async throws -> T {
    let fixture = try await ProjectionFixture.make()
    do {
        let result = try await body(fixture)
        await fixture.close()
        return result
    } catch {
        await fixture.close()
        throw error
    }
}

private func withSQLiteProjection<T>(_ fixture: ProjectionFixture,
                                     _ body: (SQLiteSessionProjection) async throws -> T) async throws -> T {
    let projection = try SQLiteSessionProjection(path: fixture.projectionPath.path)
    do {
        let result = try await body(projection)
        try await projection.close()
        return result
    } catch {
        try? await projection.close()
        throw error
    }
}

private actor ProjectionGate {
    private var armed = false
    private var released = false
    private var entered = false
    private var ownerCancelled = false
    private(set) var closeReturned = false
    private(set) var closedWhileBlocked = false

    func markCloseReturned() {
        closeReturned = true
        closedWhileBlocked = isBlocked
    }
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func arm() { armed = true; released = false; entered = false; ownerCancelled = false }
    var isBlocked: Bool { armed && entered && !released }

    func pauseIfNeeded() async {
        guard armed else { return }
        entered = true
        let waiters = enteredWaiters; enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if released { continuation.resume() } else { releaseContinuation = continuation }
            }
        }, onCancel: {
            Task { await self.markOwnerCancelled() }
        })
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func waitUntilOwnerCancelled() async {
        if ownerCancelled { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func release() {
        released = true
        releaseContinuation?.resume(); releaseContinuation = nil
    }

    private func markOwnerCancelled() {
        ownerCancelled = true
        let waiters = cancellationWaiters; cancellationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor ProjectionDelegate: SessionProjectionStore {
    private let base: SQLiteSessionProjection
    private let gate: ProjectionGate?
    private(set) var applyCount = 0

    init(base: SQLiteSessionProjection, gate: ProjectionGate? = nil) {
        self.base = base; self.gate = gate
    }

    func head(sessionID: ConversationID) async throws -> SessionJournalHead? { try await base.head(sessionID: sessionID) }
    func apply(_ batch: SessionBatch) async throws {
        applyCount += 1
        await gate?.pauseIfNeeded()
        try await base.apply(batch)
    }
    func reset(sessionID: ConversationID) async throws { try await base.reset(sessionID: sessionID) }
    func session(id: ConversationID) async throws -> SessionSummary? { try await base.session(id: id) }
    func sessions(scope: SessionQueryScope, includeArchived: Bool, after: SessionListCursor?, limit: Int) async throws -> [SessionSummary] {
        try await base.sessions(scope: scope, includeArchived: includeArchived, after: after, limit: limit)
    }
    func messages(sessionID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> [SessionMessageSummary] {
        try await base.messages(sessionID: sessionID, beforeSequence: beforeSequence, limit: limit)
    }
    func messagePage(sessionID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> SessionProjectionMessagePage {
        try await base.messagePage(sessionID: sessionID, beforeSequence: beforeSequence, limit: limit)
    }
    func executions(sessionID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> [SessionExecutionSummary] {
        try await base.executions(sessionID: sessionID, beforeSequence: beforeSequence, limit: limit)
    }
    func close() async { try? await base.close() }
}

private func temporaryProjectionDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-projection-lifecycle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private func remove(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
}
