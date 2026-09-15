import Foundation
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Session search service", .timeLimit(.minutes(1)))
struct SessionSearchServiceTests {
    @Test func readsVisibleTextAndThinkingIncrementallyWithoutDispatchingModels() async throws {
        try await withTaskWorkflow(
            outputs: [
                [
                    .blockStarted(.init(id: "thinking", content: .thinking("Search planning"))),
                    .blockFinished(id: "thinking"),
                    .blockStarted(.init(id: "text", content: .text("Search answer"))), .blockFinished(id: "text"), .finished(.stop),
                ],
                [.blockStarted(.init(id: "text", content: .text("Later response"))), .blockFinished(id: "text"), .finished(.stop)],
            ], thinkingEnabled: true
        ) { f in
            let address = try await f.run("Search question")
            let reader = SearchPayloadProbe(base: f.library)
            try await withSearch(f, reader: reader) { service, index in
                let page = try await service.search(.init(text: "search"))
                #expect(Set(page.hits.map(\.location.part)) == [.user, .assistant, .thinking])
                #expect(
                    page.hits.allSatisfy { $0.location.sessionID == address.sessionID && $0.snippet.contains("Search") }
                )
                #expect(!page.isTruncated)
                #expect(
                    Set(await reader.references.map(\.kind)) == [.title, .userText, .visibleAnswer, .visibleThinking])
                await reader.reset()
                try await service.synchronizeLibrary()
                #expect(await reader.references.isEmpty)
                let previous = try #require(try await index.head(sessionID: address.sessionID))
                _ = try await f.run("Later question", sessionID: address.sessionID)
                try await service.synchronizeLibrary()
                #expect(
                    try await index.head(sessionID: address.sessionID)?.cursor.sequence ?? 0 > previous.cursor.sequence)
                #expect(Set(await reader.references.map(\.kind)) == [.userText, .visibleAnswer])
                #expect(await f.model.inputs.count == 2)
            }
        }
    }

    @Test func missingOrMalformedSourceCannotBeReplacedByCachedText() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Search answer"))), .blockFinished(id: "text"), .finished(.stop)]]) { f in
            _ = try await f.run("Search question")
            let reader = SearchPayloadProbe(base: f.library)
            try await withSearch(f, reader: reader) { service, _ in
                try await service.synchronizeLibrary()
                await reader.fail(.missing)
                await #expect(throws: MiraError(.notFound, "Synthetic search payload is missing.")) {
                    try await service.search(.init(text: "answer"))
                }
                await reader.fail(.encoding)
                await #expect(throws: MiraError(.storage, "The session payload contains invalid text encoding.")) {
                    try await service.search(.init(text: "answer"))
                }
                await reader.fail(nil)
                #expect(try await service.search(.init(text: "answer")).hits.first?.snippet == "Search answer")
            }
        }
    }

    @Test func wholeResultBudgetRejectsBeforeBodyReads() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Search answer"))), .blockFinished(id: "text"), .finished(.stop)]]) { f in
            _ = try await f.run("Search question")
            let reader = SearchPayloadProbe(base: f.library)
            try await withSearch(f, reader: reader, maximumPageBytes: 1) { service, _ in
                try await service.synchronizeLibrary()
                await reader.reset()
                await #expect(throws: MiraError(.outputLimit, "The session query page exceeds its content limit.")) {
                    try await service.search(.init(text: "answer"))
                }
                #expect(await reader.references.isEmpty)
            }
        }
    }

    @Test func rebuildSkipsPurgedHistoricalBodiesButKeepsVisibleExcludedHistory() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Retained answer"))), .blockFinished(id: "text"), .finished(.stop)]]) { f in
            let address = try await f.run("Purged question")
            #expect(await f.runtime.shutdown().isSettled)
            let runtime = try await SessionRuntime.open(id: address.sessionID, journal: f.library, payloads: f.library)
            do {
                let state = await runtime.snapshot()
                let groups = Set(state.references.values.filter { $0.kind != .visibleAnswer }.map(\.retentionGroup))
                try searchCommitted(
                    await runtime.commit(id: UUID()) { _ in
                        [
                            .invalidated(
                                .init(
                                    operationID: UUID(), executionIDs: [address.executionID],
                                    retentionGroups: groups, authorizationEpoch: 1, reason: .forgotten))
                        ]
                    })
                try await f.library.purge(sessionID: address.sessionID, retentionGroups: groups)
                let reader = SearchPayloadProbe(base: f.library)
                try await withSearch(f, reader: reader) { service, index in
                    #expect(try await service.search(.init(text: "Purged")).hits.isEmpty)
                    #expect(try await service.search(.init(text: "Retained")).hits.first?.snippet == "Retained answer")
                    #expect(Set(await reader.references.map(\.kind)) == [.visibleAnswer])
                    await service.close()
                    try await index.clear()
                    try await index.verifyEmpty()
                    let fresh = try SessionSearchService(
                        journal: f.library, payloads: reader, index: index, access: f.access, scope: f.scope)
                    do {
                        #expect(try await fresh.search(.init(text: "Retained")).hits.count == 1)
                        #expect(try await fresh.search(.init(text: "Purged")).hits.isEmpty)
                        await fresh.close()
                    } catch {
                        await fresh.close()
                        throw error
                    }
                }
                await runtime.close()
            } catch {
                await runtime.close()
                throw error
            }
        }
    }

    @Test func privacyMaintenanceDiscardsPopulatedTextCacheBeforeReopeningSearch() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Generated secret"))), .blockFinished(id: "text"), .finished(.stop)]]) { f in
            let address = try await f.run("Original question")
            try await withSearch(f) { service, index in
                #expect(try await service.search(.init(text: "secret")).hits.count == 1)
                #expect(await f.runtime.shutdown().isSettled)
                await service.close()
                let expected = await f.access.snapshot().authorization
                let source = AgentSourceReference.sessionExecution(
                    sessionID: address.sessionID, executionID: address.executionID)
                let operation = try await f.access.begin(
                    .init(
                        id: UUID(), namespace: "privacy.fixture", revision: 1,
                        scope: .sources([source]), requestedAt: TaskWorkflowFixture.now), expected: expected)
                try await f.access.waitForQuiescence()
                let plans = try SQLiteSessionPrivacyPlanStore(database: f.database, libraryID: f.authority.libraryID)
                let engine = SessionPrivacyMaintenance(journal: f.library, payloads: f.library, plans: plans)
                do {
                    let plan = try await engine.prepare(
                        operation: operation, roots: [source], retention: .purgeGeneratedHistory, reason: .forgotten)
                    try await engine.apply(operation: operation)
                    try await engine.verify(operation: operation)
                    let projections = try SessionPrivacyProjections(
                        journal: f.library, payloads: f.library, stores: [], searchIndexes: [index])
                    await #expect(throws: MiraError.self) { try await projections.verify(plan: plan) }
                    try await projections.rebuild(plan: plan)
                    try await projections.verify(plan: plan)
                    // Repeating maintenance is safe even after the first clear already removed every cache file.
                    try await projections.rebuild(plan: plan)
                    try await projections.verify(plan: plan)
                    _ = try await f.access.complete(operation, at: TaskWorkflowFixture.now)
                    let fresh = try SessionSearchService(
                        journal: f.library, payloads: f.library, index: index, access: f.access, scope: f.scope)
                    do {
                        #expect(try await fresh.search(.init(text: "secret")).hits.isEmpty)
                        #expect(try await fresh.search(.init(text: "Original")).hits.count == 1)
                        await fresh.close()
                    } catch {
                        await fresh.close()
                        throw error
                    }
                    await plans.close()
                } catch {
                    await plans.close()
                    throw error
                }
            }
        }
    }

    @Test func staleLocationsAreRecheckedAgainstCurrentArchiveScopeAndOriginalEvent() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Search answer"))), .blockFinished(id: "text"), .finished(.stop)]]) { f in
            let address = try await f.run("Search question")
            try await withSearch(f) { service, index in
                let page = try await service.search(.init(text: "answer"))
                let hit = try #require(page.hits.first)
                let sourcePage = try await index.search(.init(text: "answer"), after: nil, limit: 32)
                // A compromised cache cannot substitute text from an unrelated event or bypass filters.
                let foreign = WorkspaceID()
                let lease = try await f.access.acquire(in: f.scope)
                do {
                    let denied = try await SessionSearchReader.resolve(
                        sourcePage, selection: .init(text: "answer", scope: .workspace(foreign)),
                        limit: 32, journal: f.library, payloads: f.library, schemas: [:], lease: lease,
                        maximumPageBytes: 64 * 1_024 * 1_024)
                    #expect(denied.hits.isEmpty && denied.isTruncated)
                    let altered = SessionSearchLocation(
                        sessionID: address.sessionID, messageID: hit.location.messageID,
                        executionID: hit.location.executionID, part: hit.location.part, sequence: hit.location.sequence,
                        occurredAt: hit.location.occurredAt.addingTimeInterval(1), reference: hit.location.reference)
                    let malformed = SessionSearchIndexPage(
                        matches: [altered], nextCursor: nil, isTruncated: false,
                        scannedCandidates: 1, capabilities: sourcePage.capabilities)
                    await #expect(throws: MiraError(.storage, "The session search index does not match the journal.")) {
                        try await SessionSearchReader.resolve(
                            malformed, selection: .init(text: "answer"), limit: 32,
                            journal: f.library, payloads: f.library, schemas: [:], lease: lease,
                            maximumPageBytes: 64 * 1_024 * 1_024)
                    }
                    await lease.release()
                } catch {
                    await lease.release()
                    throw error
                }
            }
        }
    }

    @Test func cancelledWaiterDoesNotCancelSharedRefreshButCloseDrainsItsActualRead() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Search answer"))), .blockFinished(id: "text"), .finished(.stop)]]) { f in
            _ = try await f.run("Search question")
            #expect(await f.runtime.shutdown().isSettled)
            let reader = SearchPayloadProbe(base: f.library)
            await reader.holdNextRead()
            try await withSearch(f, reader: reader) { service, _ in
                let caller = Task { try await service.search(.init(text: "answer")) }
                try await taskEventually { await reader.isHeld }
                caller.cancel()
                let second = Task { try await service.search(.init(text: "question")) }
                let done = SearchCompletionProbe()
                let close = Task {
                    await service.close()
                    await done.mark()
                }
                do {
                    try await taskEventually {
                        do {
                            try await service.synchronizeLibrary()
                            return false
                        } catch let error as MiraError {
                            return error == MiraError(.busy, "The session search service is closed.")
                        } catch { return false }
                    }
                    #expect(await !done.value)
                    #expect(await f.access.snapshot().activeResources >= 2)
                    await reader.release()
                    await #expect(throws: (any Error).self) { try await caller.value }
                    await #expect(throws: (any Error).self) { try await second.value }
                    await close.value
                    #expect(await f.access.snapshot().activeLeases == 0)
                    #expect(await f.access.snapshot().activeResources == 0)
                } catch {
                    await reader.release()
                    _ = await caller.result
                    _ = await second.result
                    await close.value
                    throw error
                }
            }
        }
    }

    @Test func maintenanceRejectsLatePlaintextAndWaitsForSharedRefresh() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Search answer"))), .blockFinished(id: "text"), .finished(.stop)]]) { f in
            _ = try await f.run("Search question")
            #expect(await f.runtime.shutdown().isSettled)
            let reader = SearchPayloadProbe(base: f.library)
            await reader.holdNextRead()
            try await withSearch(f, reader: reader) { service, _ in
                let caller = Task { try await service.search(.init(text: "answer")) }
                try await taskEventually { await reader.isHeld }
                do {
                    let expected = await f.access.snapshot().authorization
                    let operation = try await f.access.begin(
                        .init(
                            id: UUID(), namespace: "privacy.fixture", revision: 1,
                            scope: .library, requestedAt: TaskWorkflowFixture.now), expected: expected)
                    await #expect(throws: MiraError(.busy, "Library access has not drained.")) {
                        try await f.access.complete(operation, at: TaskWorkflowFixture.now)
                    }
                    await reader.release()
                    await #expect(throws: (any Error).self) { try await caller.value }
                    try await f.access.waitForQuiescence()
                    _ = try await f.access.complete(operation, at: TaskWorkflowFixture.now)
                    #expect(try await service.search(.init(text: "answer")).hits.count == 1)
                } catch {
                    await reader.release()
                    _ = await caller.result
                    throw error
                }
            }
        }
    }
}

private func withSearch(
    _ f: TaskWorkflowFixture, reader: (any SessionPayloadReader)? = nil,
    maximumPageBytes: Int = 64 * 1_024 * 1_024,
    _ body: (SessionSearchService, SQLiteSessionSearchIndex) async throws -> Void
) async throws {
    let index = try SQLiteSessionSearchIndex(path: f.directory.appendingPathComponent("search-\(UUID()).sqlite").path)
    let service = try SessionSearchService(
        journal: f.library, payloads: reader ?? f.library, index: index,
        access: f.access, scope: f.scope, maximumPageBytes: maximumPageBytes)
    do { try await body(service, index) } catch {
        await service.close()
        try? await index.close()
        throw error
    }
    await service.close()
    try await index.close()
}

private actor SearchPayloadProbe: SessionPayloadReader {
    enum Failure { case missing, encoding }
    let base: any SessionPayloadReader
    private var failure: Failure?
    private var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var references: [SessionPayloadReference] = []
    private(set) var isHeld = false
    init(base: any SessionPayloadReader) { self.base = base }
    func reset() { references.removeAll() }
    func fail(_ failure: Failure?) { self.failure = failure }
    func holdNextRead() { hold = true }
    func release() {
        continuation?.resume()
        continuation = nil
        isHeld = false
    }
    func read(_ reference: SessionPayloadReference) async throws -> Data {
        references.append(reference)
        let bytes = try await base.read(reference)
        if hold {
            hold = false
            isHeld = true
            await withCheckedContinuation { continuation = $0 }
        }
        if reference.kind == .visibleAnswer {
            switch failure {
            case .missing: throw MiraError(.notFound, "Synthetic search payload is missing.")
            case .encoding: return Data(repeating: 0xFF, count: reference.byteCount)
            case nil: break
            }
        }
        return bytes
    }
}
private actor SearchCompletionProbe {
    private(set) var value = false
    func mark() { value = true }
}
private func searchCommitted(_ result: SessionCommitResult) throws {
    if case .committed = result { return }
    throw MiraError(.storage, "Synthetic search setup did not commit.")
}
