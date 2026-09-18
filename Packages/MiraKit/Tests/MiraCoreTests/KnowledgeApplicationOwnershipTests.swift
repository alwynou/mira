import Foundation
import Testing
@testable import MiraCore

@Suite("Knowledge application ownership", .timeLimit(.minutes(1)))
struct KnowledgeApplicationOwnershipTests {
    @Test func readPreservesWorkspaceAndFrozenRoute() async throws {
        let fixture = try await KnowledgeApplicationFixture.make()
        try await withFixture(fixture) {
            let route = fixture.route
            let scope = KnowledgeReadScope(workspaceID: WorkspaceID(), destination: .model(route))
            _ = try await fixture.application.search(query: "guide", scope: scope)
            #expect(await fixture.store.lastScope == scope)
        }
    }

    @Test func importPassesLeaseAuthorizationAndFiniteClock() async throws {
        let fixture = try await KnowledgeApplicationFixture.make(now: { Date(timeIntervalSince1970: 1_700_000_000) })
        try await withFixture(fixture) {
            let receipt = try await fixture.application.importMarkdown(.init(title: "Guide.md", bytes: Data("# Guide".utf8)),
                workspaceID: nil, operationID: UUID())
            #expect(receipt.version.byteCount == 7)
            #expect(await fixture.store.lastAuthorization == fixture.authorization)
            #expect(await fixture.store.lastImportTitle == "Guide.md")
        }
    }

    @Test func closeDrainsAcceptedNonCooperativeRead() async throws {
        let gate = KnowledgeReadGate()
        let fixture = try await KnowledgeApplicationFixture.make(blockingGate: gate)
        let pending = Task { try await fixture.application.list(scope: .init(workspaceID: nil, destination: .local)) }
        var closing: Task<Void, Never>?
        do {
            await gate.waitUntilEntered()
            let closeTask = Task { await fixture.application.close() }
            closing = closeTask
            try await waitUntil { (await fixture.access.snapshot()).activeResources == 1 }
            await gate.release()
            _ = await pending.result
            await closeTask.value
            #expect((await fixture.access.snapshot()).activeResources == 0)
            #expect((await fixture.access.snapshot()).activeLeases == 0)
            await #expect(throws: MiraError.self) {
                _ = try await fixture.application.list(scope: .init(workspaceID: nil, destination: .local))
            }
        } catch {
            await gate.release()
            pending.cancel()
            _ = await pending.result
            await closing?.value
            await fixture.close()
            throw error
        }
        await fixture.closeAccessOnly()
    }

    @Test func cancelledQuiescenceWaiterDoesNotReleaseAcceptedRead() async throws {
        let gate = KnowledgeReadGate()
        let fixture = try await KnowledgeApplicationFixture.make(blockingGate: gate)
        let pendingRead = Task { try await fixture.application.list(scope: .init(workspaceID: nil, destination: .local)) }
        var waiter: Task<Bool, Never>?
        do {
            await gate.waitUntilEntered()
            try await waitUntil { (await fixture.access.snapshot()).activeLeases == 1 }
            let authorization = await fixture.access.snapshot().authorization
            let request = AgentLibraryMaintenanceRequest(id: UUID(), namespace: "knowledge.revoke", revision: 1,
                scope: .library, requestedAt: Date(timeIntervalSince1970: 1_700_000_000))
            let operation = try await fixture.access.begin(request, expected: authorization)
            waiter = Task {
                do {
                    try await fixture.access.waitForQuiescence()
                    return false
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }
            try await waitUntil { await fixture.access.pendingQuiescenceWaiterCount == 1 }
            waiter?.cancel()
            #expect(await waiter?.value == true)
            #expect((await fixture.access.snapshot()).activeLeases == 1)
            await gate.release()
            _ = await pendingRead.result
            _ = try await fixture.access.complete(operation, at: Date(timeIntervalSince1970: 1_700_000_001))
            await fixture.close()
        } catch {
            waiter?.cancel()
            _ = await waiter?.result
            await gate.release()
            _ = await pendingRead.result
            await fixture.close()
            throw error
        }
    }

    @Test func cancellingCallerRetainsAcceptedReadUntilStoreReturns() async throws {
        let gate = KnowledgeReadGate()
        let fixture = try await KnowledgeApplicationFixture.make(blockingGate: gate)
        let scope = KnowledgeReadScope(workspaceID: nil, destination: .local)
        let caller = Task { try await fixture.application.list(scope: scope) }
        do {
            await gate.waitUntilEntered()
            caller.cancel()
            #expect((await fixture.access.snapshot()).activeResources == 1)
            #expect((await fixture.access.snapshot()).activeLeases == 1)
            await gate.release()
            #expect(try await caller.value.isEmpty)
            #expect(await fixture.store.lastScope == scope)
            await fixture.close()
            #expect((await fixture.access.snapshot()).activeResources == 0)
        } catch {
            await gate.release()
            _ = await caller.result
            await fixture.close()
            throw error
        }
    }

    @Test func forgedCitationMetadataDoesNotReadChunk() async throws {
        let fixture = try await KnowledgeApplicationFixture.make()
        await #expect(throws: MiraError.self) {
            _ = try await fixture.application.citation(.init(versionID: .init(), chunkID: .init()),
                sessionID: ConversationID(), executionID: ExecutionID(), workspaceID: nil)
        }
        #expect(await fixture.store.citationReadCount == 0)
        await fixture.close()
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw MiraError(.timeout, "The synthetic knowledge condition was not reached.") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func withFixture<T: Sendable>(_ fixture: KnowledgeApplicationFixture,
                                          _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            await fixture.close()
            return value
        } catch {
            await fixture.close()
            throw error
        }
    }
}

private actor KnowledgeApplicationFixture {
    let store: KnowledgeTestStore
    let application: KnowledgeApplication
    let access: AgentLibraryAccess
    let scope: RuntimeScope
    let route: AgentModelRoute
    let authorization: AgentLibraryAuthorization

    static func make(blockingGate: KnowledgeReadGate? = nil,
                     now: @escaping @Sendable () -> Date = { Date() }) async throws -> KnowledgeApplicationFixture {
        let store = KnowledgeTestStore(blockingGate: blockingGate)
        let maintenance = KnowledgeMaintenanceStore()
        let access = try await AgentLibraryAccess.open(store: maintenance)
        let scope = RuntimeScope(kind: .application)
        let route = AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
            modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1, adapter: .init(id: "knowledge.fixture", revision: 1),
            invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", modelID: "knowledge", credential: nil, contextWindow: 4_096, maximumOutputTokens: 512,
            capabilities: .init(streamsText: true, callsTools: true, producesThinking: false), configuration: .object([:]))
        let journal = KnowledgeEmptyJournal()
        let reader = JournalSessionReader(journal: journal, payloads: journal)
        let application = KnowledgeApplication(store: store, reader: reader, access: access, scope: scope, now: now)
        return .init(store: store, application: application, access: access, scope: scope, route: route,
                     authorization: await maintenance.currentAuthorization())
    }

    private init(store: KnowledgeTestStore, application: KnowledgeApplication, access: AgentLibraryAccess,
                 scope: RuntimeScope, route: AgentModelRoute, authorization: AgentLibraryAuthorization) {
        self.store = store; self.application = application; self.access = access; self.scope = scope
        self.route = route; self.authorization = authorization
    }

    func close() async {
        await application.close()
        await access.close()
        await scope.dispose()
    }

    func closeAccessOnly() async {
        await access.close()
        await scope.dispose()
    }
}

private actor KnowledgeMaintenanceStore: AgentLibraryMaintenanceStore {
    private var authorizationValue = AgentLibraryAuthorization(libraryID: UUID(), epoch: 0)
    private var pending: AgentLibraryMaintenanceOperation?
    private var operations: [UUID: AgentLibraryMaintenanceOperation] = [:]
    func currentAuthorization() -> AgentLibraryAuthorization { authorizationValue }
    func state() async throws -> AgentLibraryMaintenanceState { .init(authorization: authorizationValue, pending: pending) }
    func operation(id: UUID) async throws -> AgentLibraryMaintenanceOperation? { operations[id] }
    func begin(_ request: AgentLibraryMaintenanceRequest, expected: AgentLibraryAuthorization) async throws -> AgentLibraryMaintenanceOperation {
        if let existing = operations[request.id] {
            guard existing.request == request, existing.previousAuthorization == expected else { throw MiraError(.conflict, "Synthetic maintenance request changed.") }
            return existing
        }
        guard pending == nil, authorizationValue == expected else { throw MiraError(.conflict, "Synthetic maintenance authorization changed.") }
        let operation = AgentLibraryMaintenanceOperation(request: request, previousAuthorization: expected,
            authorization: .init(libraryID: expected.libraryID, epoch: expected.epoch + 1), completedAt: nil)
        pending = operation; authorizationValue = operation.authorization; operations[request.id] = operation
        return operation
    }
    func complete(_ operation: AgentLibraryMaintenanceOperation, at date: Date) async throws -> AgentLibraryMaintenanceOperation {
        if let existing = operations[operation.request.id], existing.completedAt != nil { return existing }
        guard pending == operation else { throw MiraError(.conflict, "Synthetic maintenance operation changed.") }
        let completed = AgentLibraryMaintenanceOperation(request: operation.request,
            previousAuthorization: operation.previousAuthorization, authorization: operation.authorization, completedAt: date)
        pending = nil; authorizationValue = completed.authorization; operations[operation.request.id] = completed
        return completed
    }
}

private actor KnowledgeTestStore: KnowledgeStore {
    let blockingGate: KnowledgeReadGate?
    private(set) var lastScope: KnowledgeReadScope?
    private(set) var lastAuthorization: AgentLibraryAuthorization?
    private(set) var lastImportTitle: String?
    private(set) var citationReadCount = 0

    init(blockingGate: KnowledgeReadGate? = nil) { self.blockingGate = blockingGate }

    func knowledgeSources(scope: KnowledgeReadScope, limit: Int) async throws -> [KnowledgeSource] {
        if let blockingGate { await blockingGate.wait() }
        lastScope = scope
        return []
    }
    func knowledgeSource(_ id: KnowledgeSourceID, versionID: SourceVersionID?, scope: KnowledgeReadScope) async throws -> KnowledgeSourceDetail { lastScope = scope; throw MiraError(.notFound, "Synthetic source is unavailable.") }
    func sourceChunk(_ id: SourceChunkID, scope: KnowledgeReadScope) async throws -> SourceChunk { lastScope = scope; throw MiraError(.notFound, "Synthetic chunk is unavailable.") }
    func searchKnowledge(query: String, scope: KnowledgeReadScope, limit: Int) async throws -> KnowledgeSearchResult { lastScope = scope; return .init(hits: []) }
    func sourceCitation(_ reference: SourceCitationReference, scope: KnowledgeReadScope) async throws -> SourceCitationDetail { citationReadCount += 1; throw MiraError(.notFound, "Synthetic citation is unavailable.") }
    func validateKnowledgeSources(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {}
    func importMarkdown(_ input: KnowledgeImport, workspaceID: WorkspaceID?, updating: KnowledgeSourceID?, expectedRevision: Int?, operationID: UUID, authorization: AgentLibraryAuthorization, at: Date) async throws -> KnowledgeImportReceipt {
        lastAuthorization = authorization; lastImportTitle = input.title
        let source = KnowledgeSource(id: .init(), workspaceID: workspaceID, title: input.title, createdAt: at, updatedAt: at)
        let version = KnowledgeSourceVersion(id: .init(), sourceID: source.id, contentHash: String(repeating: "a", count: 64), byteCount: input.bytes.count, parserVersion: "fixture", parseState: .ready, parseError: nil, createdAt: at)
        return .init(source: source, version: version, reused: false)
    }
    func allowSourceRemoteUse(_ id: KnowledgeSourceID, workspaceID: WorkspaceID?, expectedRevision: Int, operationID: UUID, authorization: AgentLibraryAuthorization, at: Date) async throws -> KnowledgeSource { lastAuthorization = authorization; throw MiraError(.notFound, "Synthetic source is unavailable.") }
    func revokeSourceRemoteUse(_ id: KnowledgeSourceID, workspaceID: WorkspaceID?, expectedRevision: Int, maintenance: AgentLibraryMaintenanceOperation, at: Date) async throws -> KnowledgeSource { throw MiraError(.notFound, "Synthetic source is unavailable.") }
    func purgeKnowledgeSource(_ id: KnowledgeSourceID, workspaceID: WorkspaceID?, expectedRevision: Int, maintenance: AgentLibraryMaintenanceOperation, at: Date) async throws {}
}

private actor KnowledgeReadGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true; enteredWaiters.forEach { $0.resume() }; enteredWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
    func waitUntilEntered() async { if entered { return }; await withCheckedContinuation { enteredWaiters.append($0) } }
    func release() { released = true; releaseWaiters.forEach { $0.resume() }; releaseWaiters.removeAll() }
}

private actor KnowledgeEmptyJournal: SessionJournal, SessionContentReader {
    func append(_ batch: SessionBatch) async -> SessionAppendOutcome { .notCommitted(MiraError(.unsupported, "Synthetic journal is read-only.")) }
    func reconcile(_ batch: SessionBatch) async -> SessionAppendOutcome { .notCommitted(MiraError(.unsupported, "Synthetic journal is read-only.")) }
    func batch(id: UUID, sessionID: ConversationID) async throws -> SessionBatch? { nil }
    func head(sessionID: ConversationID) async throws -> SessionJournalHead { .init(cursor: .init(sessionID: sessionID, sequence: 0), batchID: nil) }
    func read(sessionID: ConversationID, after sequence: Int64, limit: Int) async throws -> [SessionBatch] { [] }
    func sessions(after: ConversationID?, limit: Int) async throws -> [ConversationID] { [] }
    func flush() async throws {}
    func close() async throws {}
    func read(_ reference: SessionContent) async throws -> Data { throw MiraError(.storage, "Synthetic payload is missing.") }
}
