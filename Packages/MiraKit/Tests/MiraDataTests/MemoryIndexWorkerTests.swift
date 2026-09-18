import Foundation
import GRDB
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Memory index worker lifecycle", .timeLimit(.minutes(1)))
struct MemoryIndexWorkerTests {
    @Test func nonIdleWakeLeavesJobPendingThenIdleWakeIndexesIt() async throws {
        try await withTaskWorkflow(memoryEnabled: true) { f in
            let embeddings = WorkerEmbeddingGate()
            let store = try SQLiteMemoryStore(database: f.database, libraryID: f.authority.libraryID,
                                              embeddings: embeddings)
            let authorization = try await f.authority.authorization()
            _ = try await create("A worker lifecycle preference", store: store, authorization: authorization)
            #expect(try await store.pendingMemoryIndexJobs(limit: 4).count == 1)

            let worker = MemoryIndexWorker(store: store, embeddings: embeddings, access: f.access, scope: f.scope)
            await worker.wake(isIdle: false)
            #expect(try await store.pendingMemoryIndexJobs(limit: 4).count == 1)

            await worker.wake(isIdle: true)
            try await waitForNoPendingJobs(store)
            await worker.close()
            await store.close()
        }
    }

    @Test func closeDrainsInFlightEmbeddingAndPreventsCommit() async throws {
        try await withTaskWorkflow(memoryEnabled: true) { f in
            let embeddings = WorkerEmbeddingGate(blockFirstDocument: true)
            let store = try SQLiteMemoryStore(database: f.database, libraryID: f.authority.libraryID,
                                              embeddings: embeddings)
            let authorization = try await f.authority.authorization()
            _ = try await create("A non-preemptible worker preference", store: store, authorization: authorization)
            let worker = MemoryIndexWorker(store: store, embeddings: embeddings, access: f.access, scope: f.scope)

            await worker.wake(isIdle: true)
            await embeddings.waitUntilDocumentEntered()
            let closing = Task { await worker.close() }
            await embeddings.waitUntilCancellationObserved()
            await embeddings.releaseDocuments()
            await closing.value

            #expect(try await store.pendingMemoryIndexJobs(limit: 4).count == 1)
            #expect(try await f.database.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_embeddings") == 0
            })
            await store.close()
        }
    }

    @Test func editDuringEmbeddingRejectsStaleResultAndIndexesCurrentRevision() async throws {
        try await withTaskWorkflow(memoryEnabled: true) { f in
            let embeddings = WorkerEmbeddingGate(blockFirstDocument: true)
            let store = try SQLiteMemoryStore(database: f.database, libraryID: f.authority.libraryID,
                                              embeddings: embeddings)
            let authorization = try await f.authority.authorization()
            let memory = try await create("The original worker preference", store: store, authorization: authorization)
            let worker = MemoryIndexWorker(store: store, embeddings: embeddings, access: f.access, scope: f.scope)

            await worker.wake(isIdle: true)
            await embeddings.waitUntilDocumentEntered()
            let revised = try await store.reviseMemory(memory.id, workspaceID: nil,
                draft: .init(content: "The revised worker preference", scope: .global), expectedRevision: 1,
                operationID: UUID(), authorization: authorization, at: TaskWorkflowFixture.now)
            await embeddings.releaseDocuments()
            try await waitForNoPendingJobs(store)

            #expect(try await f.database.read { db in
                try Int.fetchOne(db, sql: "SELECT revision FROM memory_embeddings WHERE memory_id = ?",
                                 arguments: [memory.id.rawValue.uuidString.lowercased()]) == revised.revision
            })
            await worker.close()
            await store.close()
        }
    }

    private func create(_ text: String, store: SQLiteMemoryStore,
                        authorization: AgentLibraryAuthorization) async throws -> Memory {
        try await store.createMemory(
            draft: .init(content: text, scope: .global, allowsRemoteUse: true),
            source: .manualEntry(id: UUID(), statement: text), operationID: UUID(), replacing: nil,
            expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now).memory
    }

    private func waitForNoPendingJobs(_ store: SQLiteMemoryStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if try await store.pendingMemoryIndexJobs(limit: 4).isEmpty { return }
            await Task.yield()
        }
        throw MiraError(.timeout, "The memory index worker did not settle.")
    }
}

private actor WorkerEmbeddingGate: MemoryEmbeddingService {
    nonisolated let identity = MemoryEmbeddingIdentity(fingerprint: "worker-lifecycle-v1", dimensions: 3)
    private let blockFirstDocument: Bool
    private var documentCount = 0
    private var documentEntered = false
    private var cancellationObserved = false
    private var releaseRequested = false
    private var documentWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(blockFirstDocument: Bool = false) {
        self.blockFirstDocument = blockFirstDocument
    }

    func status() async -> MemoryEmbeddingStatus { .ready }
    func prepare() async throws {}

    func embed(_ input: MemoryEmbeddingInput) async throws -> [[Float]] {
        guard case .documents = input else { return [[1, 0, 0]] }
        documentCount += 1
        if documentCount == 1 {
            documentEntered = true
            documentWaiters.forEach { $0.resume() }
            documentWaiters.removeAll()
        }
        if blockFirstDocument && documentCount == 1 {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if releaseRequested {
                        continuation.resume()
                    } else {
                        releaseWaiter = continuation
                    }
                }
            } onCancel: {
                Task { await self.markCancellationObserved() }
            }
        }
        return [[1, 0, 0]]
    }

    func waitUntilDocumentEntered() async {
        if documentEntered { return }
        await withCheckedContinuation { documentWaiters.append($0) }
    }

    func waitUntilCancellationObserved() async {
        if cancellationObserved { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func releaseDocuments() {
        releaseRequested = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func unload() async {}
    func close() async {}

    private func markCancellationObserved() {
        cancellationObserved = true
        cancellationWaiters.forEach { $0.resume() }
        cancellationWaiters.removeAll()
    }
}
