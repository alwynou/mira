import Foundation
import Testing

@testable import MiraCore

@Suite("Memory application ownership", .timeLimit(.minutes(1)))
struct MemoryApplicationOwnershipTests {
    @Test func manualCreatePassesAuthorizationAndOperationIdentityToStore() async throws {
        let fixture = try await MemoryApplicationFixture.make()
        do {
            let application = fixture.application
            let draft = MemoryDraft(content: "Use four spaces.", scope: .global)
            let operationID = UUID()
            let receipt = try await application.createMemory(
                draft: draft, source: .manualEntry(id: UUID(), statement: "Use four spaces."), operationID: operationID)
            #expect(receipt.memory.draft == draft)
            #expect(await fixture.store.lastOperationID == operationID)
            #expect(await fixture.store.lastAuthorization == fixture.authorization)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    @Test func closeDrainsAcceptedNonCooperativeReadAndRejectsNewWork() async throws {
        let gate = BlockingReadGate()
        let fixture = try await MemoryApplicationFixture.make(store: MemoryTestStore(blockingGate: gate))
        do {
            let pending = Task { try await fixture.application.list(workspaceID: nil) }
            await gate.waitUntilEntered()

            let closed = CompletionFlag()
            let closing = Task {
                await fixture.application.close()
                closed.mark()
            }
            try await waitUntil {
                let snapshot = await fixture.access.snapshot()
                return snapshot.activeResources == 1 && !closed.value
            }
            #expect(closed.value == false)
            await gate.release()
            let pendingResult = await pending.result
            await closing.value
            #expect(closed.value)
            #expect((await fixture.access.snapshot()).activeResources == 0)
            #expect((await fixture.access.snapshot()).activeLeases == 0)
            if case .failure(let error) = pendingResult {
                #expect(error is CancellationError || error is MiraError)
            }
            await #expect(throws: MiraError.self) { try await fixture.application.list(workspaceID: nil) }
            await fixture.closeAccessOnly()
        } catch {
            await gate.release()
            await fixture.close()
            throw error
        }
    }

    @Test func userEvidenceIsResolvedThroughFreshJournalBeforeMutation() async throws {
        let fixture = try await MemoryApplicationFixture.make()
        do {
            let source = MemorySourceInput.userMessage(
                reference: fixture.userEvidenceReference, excerpt: "Remember this")
            let draft = MemoryDraft(content: "Remember this", scope: .global)
            _ = try await fixture.application.createMemory(draft: draft, source: source, operationID: UUID())
            #expect(await fixture.store.userEvidenceWriteCount == 1)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    @Test(arguments: [false, true]) func revokedAccountingReadWaitsForStoreReturnAndRejectsLateValue(status: Bool) async throws {
        let gate = BlockingReadGate()
        let fixture = try await MemoryApplicationFixture.make(store: MemoryTestStore(blockingBudgetGate: gate))
        let pending = Task {
            if status {
                _ = try await fixture.application.extractionStatus(sessionID: fixture.sessionID,
                    executionID: fixture.userEvidenceReference.originalExecutionID, workspaceID: nil)
            } else { _ = try await fixture.application.extractionBudget() }
        }
        var operation: AgentLibraryMaintenanceOperation?
        do {
            await gate.waitUntilEntered()
            let request = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: "memory.revoke", revision: 1,
                scope: .library, requestedAt: Date(timeIntervalSince1970: 1_700_000_000))
            operation = try await fixture.access.begin(request, expected: fixture.authorization)
            #expect((await fixture.access.snapshot()).activeResources == 1)
            await gate.release()
            let result = await pending.result
            if case .success = result { Issue.record("A revoked budget read published a late value.") }
            #expect((await fixture.access.snapshot()).activeResources == 0)
            #expect(operation != nil)
            await fixture.close()
        } catch {
            await gate.release()
            _ = await pending.result
            await fixture.close()
            throw error
        }
    }

    @Test(arguments: [false, true]) func closeDrainsAcceptedNonCooperativeAccountingRead(status: Bool) async throws {
        let gate = BlockingReadGate()
        let fixture = try await MemoryApplicationFixture.make(store: MemoryTestStore(blockingBudgetGate: gate))
        let pending = Task {
            if status {
                _ = try await fixture.application.extractionStatus(sessionID: fixture.sessionID,
                    executionID: fixture.userEvidenceReference.originalExecutionID, workspaceID: nil)
            } else { _ = try await fixture.application.extractionBudget() }
        }
        let closed = CompletionFlag()
        let closeStarted = CompletionFlag()
        var closing: Task<Void, Never>?
        do {
            await gate.waitUntilEntered()
            closing = Task {
                closeStarted.mark()
                await fixture.application.close()
                closed.mark()
            }
            try await waitUntil {
                guard closeStarted.value else { return false }
                return (await fixture.access.snapshot()).activeResources == 1
            }
            #expect(!closed.value)
            await gate.release()
            _ = await pending.result
            await closing?.value
            #expect(closed.value)
            #expect((await fixture.access.snapshot()).activeResources == 0)
            #expect((await fixture.access.snapshot()).activeLeases == 0)
            await fixture.closeAccessOnly()
        } catch {
            await gate.release()
            _ = await pending.result
            await closing?.value
            await fixture.closeAccessOnly()
            throw error
        }
    }

    @Test func mutationAndCapturePolicyUseFiniteClockAndCasArguments() async throws {
        let fixture = try await MemoryApplicationFixture.make(now: { Date(timeIntervalSince1970: 1_700_000_000) })
        do {
            let policy = MemoryCapturePolicy(
                revision: 2, mode: .candidateOnly, dailyTokenLimit: 2_000,
                enabledAt: Date(timeIntervalSince1970: 1_700_000_001))
            try await fixture.application.saveCapturePolicy(policy, expectedRevision: 1)
            #expect(await fixture.store.lastPolicy == policy)
            let memory = try await fixture.application.changeMemoryState(
                MemoryID(), workspaceID: nil, state: .archived, expectedRevision: 1, operationID: UUID())
            #expect(memory.state == .archived)
            #expect(await fixture.store.lastMutationDate == Date(timeIntervalSince1970: 1_700_000_000))
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    @Test func citationWithoutRecordedContextNeverReadsMemoryRevision() async throws {
        let fixture = try await MemoryApplicationFixture.make()
        do {
            await #expect(throws: MiraError.self) {
                _ = try await fixture.application.citation(
                    MemoryCitationReference(memoryID: MemoryID(), revision: 1),
                    sessionID: fixture.sessionID, executionID: ExecutionID(), workspaceID: nil)
            }
            #expect(await fixture.store.citationReadCount == 0)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                throw MiraError(.timeout, "The synthetic application condition was not reached.")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor MemoryApplicationFixture {
    let store: MemoryTestStore
    let application: MemoryApplication
    let access: AgentLibraryAccess
    let scope: RuntimeScope
    let sessionID: ConversationID
    let userEvidenceReference: SessionEvidenceReference
    let authorization: AgentLibraryAuthorization

    static func make(store: MemoryTestStore? = nil, now: @escaping @Sendable () -> Date = { Date() }) async throws
        -> MemoryApplicationFixture
    {
        let selectedStore = store ?? MemoryTestStore()
        let maintenance = MemoryMaintenanceStore()
        let access = try await AgentLibraryAccess.open(store: maintenance)
        let scope = RuntimeScope(kind: .application)
        let sessionID = ConversationID()
        let admissionBatchID = UUID()
        let body = SessionPayloadReference(
            id: UUID(), sessionID: sessionID, batchID: admissionBatchID, retentionGroup: UUID(), kind: .userText,
            byteCount: 13, digest: String(repeating: "a", count: 64))
        let originalExecutionID = ExecutionID()
        let userMessageID = MessageID()
        let admissionEventID = UUID()
        let openBatchID = UUID()
        let title = SessionPayloadReference(
            id: UUID(), sessionID: sessionID, batchID: openBatchID, retentionGroup: UUID(), kind: .title, byteCount: 4,
            digest: String(repeating: "c", count: 64))
        let plan = SessionPayloadReference(
            id: UUID(), sessionID: sessionID, batchID: admissionBatchID, retentionGroup: UUID(), kind: .executionPlan,
            byteCount: 4, digest: String(repeating: "d", count: 64))
        let opened = SessionBatch(
            id: openBatchID, sessionID: sessionID, expectedSequence: 0,
            events: [
                .init(
                    sequence: 1, occurredAt: Date(timeIntervalSince1970: 1),
                    fact: .opened(.init(workspaceID: nil, title: title)))
            ])
        let evidence = SessionEvidenceReference(
            sessionID: sessionID, originalExecutionID: originalExecutionID, userMessageID: userMessageID,
            admissionEventID: admissionEventID, admissionSequence: 2, body: body)
        let admitted = SessionBatch(
            id: admissionBatchID, sessionID: sessionID, expectedSequence: 1,
            events: [
                .init(
                    id: admissionEventID, sequence: 2, occurredAt: Date(timeIntervalSince1970: 2),
                    fact: .admitted(
                        .init(
                            executionID: originalExecutionID, userMessageID: userMessageID, userBody: body, plan: plan,
                            hasModelRoute: false, authorizationEpoch: 0, timeZoneIdentifier: "UTC")))
            ])
        let journal = EvidenceSessionJournal(sessionID: sessionID, batches: [opened, admitted])
        let payloads = MemoryPayloadReader(values: [body.id: Data("Remember this".utf8)])
        let reader = JournalSessionReader(journal: journal, payloads: payloads)
        let app = MemoryApplication(
            store: selectedStore, capturePolicyStore: selectedStore,
            extractionBudgetReader: selectedStore, extractionStatusReader: selectedStore, reader: reader, privacyHistory: selectedStore,
            access: access, scope: scope, now: now)
        return .init(
            store: selectedStore, application: app, access: access, scope: scope, sessionID: sessionID,
            userEvidenceReference: evidence, authorization: await maintenance.currentAuthorization())
    }

    private init(
        store: MemoryTestStore, application: MemoryApplication, access: AgentLibraryAccess,
        scope: RuntimeScope, sessionID: ConversationID, userEvidenceReference: SessionEvidenceReference,
        authorization: AgentLibraryAuthorization
    ) {
        self.store = store
        self.application = application
        self.access = access
        self.scope = scope
        self.sessionID = sessionID
        self.userEvidenceReference = userEvidenceReference
        self.authorization = authorization
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

private actor MemoryMaintenanceStore: AgentLibraryMaintenanceStore {
    private var authorizationValue = AgentLibraryAuthorization(libraryID: UUID(), epoch: 0)
    private var pending: AgentLibraryMaintenanceOperation?
    private var operations: [UUID: AgentLibraryMaintenanceOperation] = [:]
    func currentAuthorization() -> AgentLibraryAuthorization { authorizationValue }
    func state() async throws -> AgentLibraryMaintenanceState {
        .init(authorization: authorizationValue, pending: pending)
    }
    func operation(id: UUID) async throws -> AgentLibraryMaintenanceOperation? { operations[id] }
    func begin(_ request: AgentLibraryMaintenanceRequest, expected: AgentLibraryAuthorization) async throws
        -> AgentLibraryMaintenanceOperation
    {
        if let existing = operations[request.id] {
            guard existing.request == request, existing.previousAuthorization == expected else {
                throw MiraError(.conflict, "Synthetic maintenance request changed.")
            }
            return existing
        }
        guard pending == nil, authorizationValue == expected else {
            throw MiraError(.conflict, "Synthetic maintenance authorization changed.")
        }
        let operation = AgentLibraryMaintenanceOperation(
            request: request, previousAuthorization: expected,
            authorization: .init(libraryID: expected.libraryID, epoch: expected.epoch + 1), completedAt: nil)
        pending = operation
        authorizationValue = operation.authorization
        operations[request.id] = operation
        return operation
    }
    func complete(_ operation: AgentLibraryMaintenanceOperation, at date: Date) async throws
        -> AgentLibraryMaintenanceOperation
    {
        if let existing = operations[operation.request.id], existing.completedAt != nil { return existing }
        guard pending == operation else { throw MiraError(.conflict, "Synthetic maintenance operation changed.") }
        let completed = AgentLibraryMaintenanceOperation(
            request: operation.request, previousAuthorization: operation.previousAuthorization,
            authorization: operation.authorization, completedAt: date)
        pending = nil
        authorizationValue = completed.authorization
        operations[operation.request.id] = completed
        return completed
    }
}

private actor MemoryTestStore: MemoryStore, MemoryCapturePolicyStore, MemoryExtractionBudgetReader, MemoryExtractionStatusReader, SessionPrivacyHistoryReader {
    func retainedHistory(sessionID: ConversationID, operationIDs: Set<UUID>, executionIDs: Set<ExecutionID>) throws -> [SessionPrivacyHistoryRecord] {
        throw MiraError(.configuration, "The ownership fixture does not provide retained history.")
    }
    func memoryContextNotices(references: [MemoryCitationReference], workspaceID: WorkspaceID?, connectionID: ConnectionID?, at: Date) -> [MemoryContextNotice] { [] }
    let blockingGate: BlockingReadGate?
    let blockingBudgetGate: BlockingReadGate?
    private(set) var lastOperationID: UUID?
    private(set) var lastAuthorization: AgentLibraryAuthorization?
    private(set) var lastMutationDate: Date?
    private(set) var lastPolicy: MemoryCapturePolicy?
    private(set) var userEvidenceWriteCount = 0
    private(set) var citationReadCount = 0
    init(blockingGate: BlockingReadGate? = nil, blockingBudgetGate: BlockingReadGate? = nil) {
        self.blockingGate = blockingGate
        self.blockingBudgetGate = blockingBudgetGate
    }

    func memoryList(workspaceID: WorkspaceID?, states: Set<MemoryState>, query: String, limit: Int) async throws
        -> MemorySearchResult
    {
        if let blockingGate { await blockingGate.wait() }
        return .init(memories: [])
    }
    func memoryDetail(_ id: MemoryID, workspaceID: WorkspaceID?) async throws -> MemoryDetail {
        .init(memory: syntheticMemory(id), evidence: [], revisions: [], replacements: [])
    }
    func memoryCitationRevision(_ reference: MemoryCitationReference, workspaceID: WorkspaceID?) async throws
        -> MemoryCitationDetail
    {
        citationReadCount += 1
        let memory = syntheticMemory(reference.memoryID)
        let revision = MemoryRevision(
            memoryID: reference.memoryID, revision: reference.revision, draft: memory.draft, changedAt: Date())
        return .init(memory: memory, revision: revision, evidence: [])
    }
    func recallMemories(query: String, request: AgentContextRequest, limit: Int, at: Date) async throws
        -> MemorySearchResult
    { .init(memories: []) }
    func recallMemory(_ id: MemoryID, request: AgentContextRequest, at: Date) async throws -> Memory {
        syntheticMemory(id)
    }
    func validateMemorySources(_ sources: [AgentSourceReference], for request: AgentContextRequest, at: Date)
        async throws
    {}
    func suppressedMemorySources() async throws -> [MemoryEvidenceSource] { [] }
    func createMemory(
        draft: MemoryDraft, source: MemoryWriteSource, operationID: UUID, replacing: MemoryID?, expectedRevision: Int?,
        authorization: AgentLibraryAuthorization, at: Date
    ) async throws -> MemoryWriteReceipt {
        lastOperationID = operationID
        lastAuthorization = authorization
        lastMutationDate = at
        if case .userMessage = source { userEvidenceWriteCount += 1 }
        var memory = syntheticMemory()
        memory.draft = draft
        memory.scope = draft.scope
        memory.subject = draft.subject
        return .init(memory: memory, disposition: .created)
    }
    func reviseMemory(
        _ id: MemoryID, workspaceID: WorkspaceID?, draft: MemoryDraft, expectedRevision: Int, operationID: UUID,
        authorization: AgentLibraryAuthorization, at: Date
    ) async throws -> Memory {
        lastOperationID = operationID
        lastAuthorization = authorization
        lastMutationDate = at
        return syntheticMemory(id)
    }
    func changeMemoryState(
        _ id: MemoryID, workspaceID: WorkspaceID?, state: MemoryState, expectedRevision: Int, operationID: UUID,
        authorization: AgentLibraryAuthorization, at: Date
    ) async throws -> Memory {
        lastOperationID = operationID
        lastAuthorization = authorization
        lastMutationDate = at
        var memory = syntheticMemory(id)
        memory.state = state
        return memory
    }
    func confirmMemoryReplacement(
        _ candidateID: MemoryID, workspaceID: WorkspaceID?, replacingCurrent currentID: MemoryID,
        expectedCandidateRevision: Int, expectedCurrentRevision: Int, operationID: UUID,
        authorization: AgentLibraryAuthorization, at: Date
    ) async throws -> Memory {
        lastOperationID = operationID
        lastAuthorization = authorization
        lastMutationDate = at
        return syntheticMemory(candidateID)
    }
    func purgeMemory(
        _ id: MemoryID, workspaceID: WorkspaceID?, expectedRevision: Int, maintenance: AgentLibraryMaintenanceOperation,
        at: Date
    ) async throws -> MemoryForgetReceipt { .init(memoryID: id, suppressedSources: []) }
    func memoryCapturePolicy() async throws -> MemoryCapturePolicy { .init(revision: 1) }
    func saveMemoryCapturePolicy(
        _ policy: MemoryCapturePolicy, expectedRevision: Int, authorization: AgentLibraryAuthorization, at: Date
    ) async throws {
        lastPolicy = policy
        lastAuthorization = authorization
        lastMutationDate = at
    }
    func memoryExtractionBudget(at: Date) async throws -> MemoryExtractionBudget {
        if let blockingBudgetGate { await blockingBudgetGate.wait() }
        return .init(dayStart: at, tokenLimit: 10_000, reservedTokens: 0, chargedTokens: 0)
    }

    func memoryExtractionStatus(sessionID: ConversationID, executionID: ExecutionID, workspaceID: WorkspaceID?,
                                before: MemoryExtractionStatusCursor?, limit: Int) async throws -> MemoryExtractionStatusPage {
        if let blockingBudgetGate { await blockingBudgetGate.wait() }
        return .init(jobs: [], nextCursor: nil)
    }
    func memoryExtractionReport(_ id: MemoryExtractionJobID, sessionID: ConversationID,
                                executionID: ExecutionID, workspaceID: WorkspaceID?) async throws -> MemoryExtractionJobReport {
        throw MiraError(.notFound, "No extraction report in this fixture.")
    }

    private func syntheticMemory(_ id: MemoryID = MemoryID()) -> Memory {
        .init(
            id: id, draft: .init(content: "Synthetic", scope: .global), scope: .global, subject: .user,
            createdAt: Date(), updatedAt: Date())
    }
}

private actor BlockingReadGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var state = false
    var value: Bool { lock.withLock { state } }
    func mark() { lock.withLock { state = true } }
}

private actor EvidenceSessionJournal: SessionJournal {
    let sessionID: ConversationID
    let batches: [SessionBatch]
    init(sessionID: ConversationID, batches: [SessionBatch] = []) {
        self.sessionID = sessionID
        self.batches = batches
    }
    func append(_ batch: SessionBatch) async -> SessionAppendOutcome {
        .notCommitted(MiraError(.unsupported, "Synthetic journal is read-only."))
    }
    func reconcile(_ batch: SessionBatch) async -> SessionAppendOutcome {
        .notCommitted(MiraError(.unsupported, "Synthetic journal is read-only."))
    }
    func batch(id: UUID, sessionID: ConversationID) async throws -> SessionBatch? {
        batches.first { $0.id == id && $0.sessionID == sessionID }
    }
    func head(sessionID: ConversationID) async throws -> SessionJournalHead {
        guard let last = batches.last else {
            return .init(cursor: .init(sessionID: sessionID, sequence: 0), batchID: nil)
        }
        return .init(cursor: last.cursor, batchID: last.id)
    }
    func read(sessionID: ConversationID, after sequence: Int64, limit: Int) async throws -> [SessionBatch] {
        Array(batches.filter { $0.cursor.sequence > sequence }.prefix(limit))
    }
    func sessions(after: ConversationID?, limit: Int) async throws -> [ConversationID] { [] }
    func flush() async throws {}
    func close() async throws {}
}

private actor MemoryPayloadReader: SessionPayloadReader {
    let values: [UUID: Data]
    init(values: [UUID: Data]) { self.values = values }
    func read(_ reference: SessionPayloadReference) async throws -> Data {
        guard let data = values[reference.id] else { throw MiraError(.storage, "Synthetic payload is missing.") }
        return data
    }
}
