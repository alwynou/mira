import Foundation
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Session query lifecycle", .timeLimit(.minutes(1)))
struct SessionQueryLifecycleTests {
    @Test func cancelledCallerKeepsCatchupPinnedUntilServiceCloseAndApplyDrain() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Answer"))), .blockFinished(id: "text"), .finished(.stop)]]) { fixture in
            let address = try await fixture.run("Question")
            #expect(await fixture.runtime.shutdown().isSettled)

            let gate = ProjectionGate()
            let projection = try SQLiteSessionProjection(
                path: fixture.directory.appendingPathComponent("query-lifecycle-\(UUID()).sqlite").path
            )
            let delegated = GatedProjection(base: projection, gate: gate)
            let query = try SessionQueryService(
                journal: fixture.library, payloads: fixture.library,
                projection: delegated, access: fixture.access, scope: fixture.scope)
            var caller: Task<SessionQueryMessagePage, any Error>?
            var closing: Task<Void, Never>?
            do {
                let cancellation = CancellationProbe()
                let returned = CompletionProbe()
                caller = Task { () throws -> SessionQueryMessagePage in
                    do {
                        let page = try await withTaskCancellationHandler(
                            operation: {
                                try await query.messagePage(sessionID: address.sessionID)
                            },
                            onCancel: {
                                Task { await cancellation.mark() }
                            })
                        await returned.mark()
                        return page
                    } catch {
                        await returned.mark()
                        throw error
                    }
                }
                try await taskEventually { await gate.entered }
                caller?.cancel()
                try await taskEventually { await cancellation.value }

                #expect(await !returned.value)
                #expect(await fixture.access.snapshot().activeResources == 1)
                #expect(await !gate.ownerCancelled)

                closing = Task {
                    await query.close()
                    await gate.markCloseReturned()
                }
                try await taskEventually { await gate.ownerCancelled }
                #expect(await !gate.released)
                #expect(await !gate.closeReturned)
                #expect(await fixture.access.snapshot().activeResources == 1)

                await gate.release()
                let callerResult = await caller!.result
                if case .success = callerResult {
                    throw MiraError(.conflict, "A cancelled session query returned successfully.")
                }
                await closing?.value
                #expect(await gate.closeReturned)
                #expect(await fixture.access.snapshot().activeResources == 0)
                #expect(await fixture.access.snapshot().activeLeases == 0)
                #expect(await fixture.access.snapshot().activeReads == 0)
            } catch {
                await gate.release()
                caller?.cancel()
                _ = await caller?.result
                await closing?.value
                await query.close()
                try? await projection.close()
                throw error
            }
            await query.close()
            try await projection.close()
        }
    }

    @Test func unknownSessionMessagePageIsEmptyAtZeroJournalHead() async throws {
        try await withTaskWorkflow { fixture in
            let projection = try SQLiteSessionProjection(
                path: fixture.directory.appendingPathComponent("query-unknown-\(UUID()).sqlite").path
            )
            let query = try SessionQueryService(
                journal: fixture.library, payloads: fixture.library,
                projection: projection, access: fixture.access, scope: fixture.scope)
            do {
                let page = try await query.messagePage(sessionID: ConversationID())
                #expect(page == .init(session: nil, messages: [], executions: [], hasMore: false))
                await query.close()
                try await projection.close()
            } catch {
                await query.close()
                try? await projection.close()
                throw error
            }
        }
    }
}

private final class GatedProjection: SessionProjectionStore, Sendable {
    private let base: SQLiteSessionProjection
    private let gate: ProjectionGate

    init(base: SQLiteSessionProjection, gate: ProjectionGate) {
        self.base = base
        self.gate = gate
    }

    func head(sessionID: ConversationID) async throws -> SessionJournalHead? {
        try await base.head(sessionID: sessionID)
    }

    func apply(_ batch: SessionBatch) async throws {
        await gate.pauseIfNeeded()
        try await base.apply(batch)
    }

    func reset(sessionID: ConversationID) async throws {
        try await base.reset(sessionID: sessionID)
    }

    func session(id: ConversationID) async throws -> SessionSummary? {
        try await base.session(id: id)
    }

    func sessions(scope: SessionQueryScope, includeArchived: Bool, after: SessionListCursor?, limit: Int) async throws
        -> [SessionSummary]
    {
        try await base.sessions(scope: scope, includeArchived: includeArchived, after: after, limit: limit)
    }

    func messages(sessionID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> [SessionMessageSummary]
    {
        try await base.messages(sessionID: sessionID, beforeSequence: beforeSequence, limit: limit)
    }

    func messagePage(sessionID: ConversationID, beforeSequence: Int64?, limit: Int) async throws
        -> SessionProjectionMessagePage
    {
        try await base.messagePage(sessionID: sessionID, beforeSequence: beforeSequence, limit: limit)
    }

    func executions(sessionID: ConversationID, beforeSequence: Int64?, limit: Int) async throws
        -> [SessionExecutionSummary]
    {
        try await base.executions(sessionID: sessionID, beforeSequence: beforeSequence, limit: limit)
    }

    func close() async throws {
        try await base.close()
    }
}

private actor ProjectionGate {
    private(set) var entered = false
    private(set) var ownerCancelled = false
    private(set) var released = false
    private(set) var closeReturned = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pauseIfNeeded() async {
        guard !released else { return }
        entered = true
        await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { continuation in
                    if released {
                        continuation.resume()
                    } else {
                        self.continuation = continuation
                    }
                }
            },
            onCancel: {
                Task { await self.markOwnerCancelled() }
            })
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func markCloseReturned() {
        closeReturned = true
    }

    private func markOwnerCancelled() {
        ownerCancelled = true
    }
}

private actor CancellationProbe {
    private var markedValue = false

    var value: Bool { markedValue }

    func mark() {
        markedValue = true
    }
}

private actor CompletionProbe {
    private(set) var value = false
    func mark() { value = true }
}
