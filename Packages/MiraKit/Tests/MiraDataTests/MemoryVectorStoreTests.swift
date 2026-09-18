import Foundation
import GRDB
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Revision-bound memory vectors")
struct MemoryVectorStoreTests {
    @Test(arguments: [1, 3])
    func broadLexicalMatchesCannotOverrideSemanticRejection(limit: Int) async throws {
        try await withTaskWorkflow(memoryEnabled: true) { f in
            let embedding = VectorFixture(queryVectors: ["tea database": [0, 1, 0]])
            let store = try SQLiteMemoryStore(database: f.database, libraryID: f.authority.libraryID, embeddings: embedding)
            let authorization = try await f.authority.authorization()
            _ = try await create("I prefer green tea.", store: store, authorization: authorization)
            let job = try #require(try await store.pendingMemoryIndexJobs(limit: 4).first)
            #expect(try await store.completeMemoryIndexJob(job, vector: [1, 0, 0], authorization: authorization))
            let result = try await store.recallMemories(query: "tea database", request: request(route: f.route), limit: limit, at: TaskWorkflowFixture.now)
            #expect(result.memories.isEmpty)
            #expect(result.retrieval == .hybrid)
            await store.close()
        }
    }

    @Test func missingDerivedProjectionRebuildsWithoutChangingCanonicalMemory() async throws {
        try await withTaskWorkflow(memoryEnabled: true) { f in
            let store = try #require(f.memory)
            let authorization = try await f.authority.authorization()
            let memory = try await create("A retained preference", store: store, authorization: authorization)
            let before = try await store.memoryDetail(memory.id, workspaceID: nil)
            try await f.database.write { db in
                try db.execute(sql: "DROP TABLE memory_embeddings")
                try db.execute(sql: "DROP TABLE memory_embedding_jobs")
                try db.execute(sql: "DROP TABLE memory_embedding_state")
            }
            let reopened = try SQLiteMemoryStore(database: f.database, libraryID: f.authority.libraryID)
            let after = try await reopened.memoryDetail(memory.id, workspaceID: nil)
            #expect(after.memory == before.memory)
            #expect(after.evidence == before.evidence)
            #expect(try await reopened.pendingMemoryIndexJobs(limit: 4).map(\.memoryID) == [memory.id])
            await reopened.close()
        }
    }

    @Test func searchToolRejectsUnrelatedNeighborsInASmallLibrary() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { f in
            let embedding = VectorFixture(queryVectors: [
                "pet name": [1, 0, 0], "quantum mechanics": [0.2, sqrt(0.96), 0],
                "postgres indexes": [0, 1, 0], "Mochi": [0, 1, 0]
            ])
            let store = try SQLiteMemoryStore(database: f.database, libraryID: f.authority.libraryID, embeddings: embedding)
            let authorization = try await f.authority.authorization()
            let name = try await create("The user's pet is named Mochi.", store: store, authorization: authorization)
            _ = try await create("The user's pet is a spaniel.", store: store, authorization: authorization)
            _ = try await create("The user walks the dog every evening.", store: store, authorization: authorization)
            for job in try await store.pendingMemoryIndexJobs(limit: 4) {
                #expect(try await store.completeMemoryIndexJob(job, vector: [1, 0, 0], authorization: authorization))
            }
            let address = try await f.run("Tell me about my pet")
            let evidence = try await JournalSessionReader(journal: f.library, payloads: f.library)
                .userEvidence(sessionID: address.sessionID, executionID: address.executionID)
            let context = AgentToolContext(executionID: address.executionID, invocationID: UUID(), evidence: evidence, route: f.route)
            guard case .read(let tool) = MemoryTools.readOnly(store: store, now: { TaskWorkflowFixture.now })[0] else {
                Issue.record("The memory search tool is not a read tool."); return
            }
            for query in ["quantum mechanics", "postgres indexes"] {
                let plan = try await tool.prepare(.object(["query": .string(query)]), context: context)
                let result = try await tool.execute(plan, context: context)
                #expect(result["memories"] == .array([]))
                #expect(result["truncated"] == .bool(false))
                #expect(plan.sources.isEmpty)
            }
            let relevant = try await store.recallMemories(query: "pet name", request: request(route: f.route), limit: 3, at: TaskWorkflowFixture.now)
            #expect(relevant.memories.count == 3)
            #expect(!relevant.isTruncated)
            #expect(try await store.recallMemories(query: "pet name", request: request(route: f.route), limit: 2, at: TaskWorkflowFixture.now).isTruncated)
            let literal = try await store.recallMemories(query: "Mochi", request: request(route: f.route), limit: 6, at: TaskWorkflowFixture.now)
            #expect(literal.memories.map(\.id) == [name.id])
            #expect(try await store.recallMemories(query: " \n ", request: request(route: f.route), limit: 6, at: TaskWorkflowFixture.now).memories.isEmpty)
            #expect(try await store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 6).memories.count == 3)
            await embedding.disable()
            #expect(try await store.recallMemories(query: "Mochi", request: request(route: f.route), limit: 6, at: TaskWorkflowFixture.now).memories.map(\.id) == [name.id])
            #expect(try await store.recallMemories(query: "quantum mechanics", request: request(route: f.route), limit: 6, at: TaskWorkflowFixture.now).memories.isEmpty)
            await store.close()
        }
    }

    @Test func semanticRecallFindsParaphraseAndSurvivesReopen() async throws {
        try await withTaskWorkflow(memoryEnabled: true) { f in
            let embedding = VectorFixture()
            let store = try SQLiteMemoryStore(database: f.database, libraryID: f.authority.libraryID, embeddings: embedding)
            let authorization = try await f.authority.authorization()
            let memory = try await create("I avoid all dairy products.", store: store, authorization: authorization)
            let job = try #require(try await store.pendingMemoryIndexJobs(limit: 4).first)
            #expect(try await store.completeMemoryIndexJob(job, vector: [1, 0, 0], authorization: authorization))
            let request = request(route: f.route)
            let result = try await store.recallMemories(query: "breakfast suggestions", request: request, limit: 6, at: TaskWorkflowFixture.now)
            #expect(result.retrieval == .hybrid)
            #expect(result.memories.map(\.id) == [memory.id])
            await store.close()
            let reopened = try SQLiteMemoryStore(database: f.database, libraryID: f.authority.libraryID, embeddings: embedding)
            #expect(try await reopened.pendingMemoryIndexJobs(limit: 4).isEmpty)
            #expect(try await reopened.recallMemories(query: "breakfast suggestions", request: request, limit: 6, at: TaskWorkflowFixture.now).memories.map(\.id) == [memory.id])
            await reopened.close()
        }
    }

    @Test func indexWorkerLoadsAnExistingIndexAndStopsBeforeCloseReturns() async throws {
        try await withTaskWorkflow(memoryEnabled: true) { f in
            let embedding = VectorFixture()
            let store = try SQLiteMemoryStore(database: f.database, libraryID: f.authority.libraryID, embeddings: embedding)
            let authorization = try await f.authority.authorization()
            _ = try await create("An indexed preference", store: store, authorization: authorization)
            let job = try #require(try await store.pendingMemoryIndexJobs(limit: 4).first)
            #expect(try await store.completeMemoryIndexJob(job, vector: [1, 0, 0], authorization: authorization))
            await embedding.disable()
            let worker = MemoryIndexWorker(store: store, embeddings: embedding, access: f.access, scope: f.scope)
            await worker.wake(isIdle: true)
            for _ in 0..<200 {
                if await embedding.status() == .ready { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await embedding.status() == .ready)
            await worker.close()
            #expect(try await store.pendingMemoryIndexJobs(limit: 4).isEmpty)
            #expect(await embedding.prepareCount == 1)
            await store.close()
        }
    }

    @Test func editRemoveAndGenerationChangeRejectLateJobs() async throws {
        try await withTaskWorkflow(memoryEnabled: true) { f in
            let store = try SQLiteMemoryStore(database: f.database, libraryID: f.authority.libraryID, embeddings: VectorFixture())
            let authorization = try await f.authority.authorization()
            let memory = try await create("I prefer morning meetings.", store: store, authorization: authorization)
            let old = try #require(try await store.pendingMemoryIndexJobs(limit: 4).first)
            let revised = try await store.reviseMemory(memory.id, workspaceID: nil,
                draft: .init(content: "I prefer afternoon meetings.", scope: .global), expectedRevision: 1,
                operationID: UUID(), authorization: authorization, at: TaskWorkflowFixture.now)
            #expect(try await store.completeMemoryIndexJob(old, vector: [1, 0, 0], authorization: authorization) == false)
            let current = try #require(try await store.pendingMemoryIndexJobs(limit: 4).first)
            let other = try SQLiteMemoryStore(database: f.database, libraryID: f.authority.libraryID,
                                            embeddings: VectorFixture(fingerprint: "new-space"))
            #expect(try await store.completeMemoryIndexJob(current, vector: [1, 0, 0], authorization: authorization) == false)
            let reset = try #require(try await other.pendingMemoryIndexJobs(limit: 4).first)
            _ = try await other.changeMemoryState(revised.id, workspaceID: nil, state: .removed, expectedRevision: revised.revision,
                                                  operationID: UUID(), authorization: authorization, at: TaskWorkflowFixture.now)
            #expect(try await other.completeMemoryIndexJob(reset, vector: [1, 0, 0], authorization: authorization) == false)
            #expect(try await other.pendingMemoryIndexJobs(limit: 4).isEmpty)
            await other.close(); await store.close()
        }
    }

    @Test func eligibilityPrecedesVectorTopKAndUnavailableModelKeepsLexical() async throws {
        try await withTaskWorkflow(memoryEnabled: true) { f in
            let embedding = VectorFixture()
            let store = try SQLiteMemoryStore(database: f.database, libraryID: f.authority.libraryID, embeddings: embedding)
            let authorization = try await f.authority.authorization()
            let workspace = Workspace(id: .init(), name: "Other")
            try await f.workspaces.saveWorkspace(workspace, expectedRevision: nil, authorization: authorization)
            for index in 0..<12 {
                _ = try await create("private dairy record \(index)", store: store, authorization: authorization, scope: .workspace(workspace.id))
            }
            _ = try await create("dairy local only", store: store, authorization: authorization, allowsRemoteUse: false)
            let allowed = try await create("dairy preference", store: store, authorization: authorization)
            while true {
                let jobs = try await store.pendingMemoryIndexJobs(limit: 4)
                if jobs.isEmpty { break }
                for job in jobs {
                    #expect(try await store.completeMemoryIndexJob(job, vector: [1, 0, 0], authorization: authorization))
                }
            }
            let result = try await store.recallMemories(query: "breakfast", request: request(route: f.route), limit: 1, at: TaskWorkflowFixture.now)
            #expect(result.memories.map(\.id) == [allowed.id])
            await embedding.disable()
            let lexical = try await store.recallMemories(query: "dairy", request: request(route: f.route), limit: 6, at: TaskWorkflowFixture.now)
            #expect(lexical.retrieval == .lexical)
            #expect(lexical.memories.map(\.id) == [allowed.id])
            await store.close()
        }
    }

    @Test func invalidVectorsNeverCommitAndForgottenFactsHaveNoDerivedRows() async throws {
        try await withTaskWorkflow(memoryEnabled: true) { f in
            let store = try SQLiteMemoryStore(database: f.database, libraryID: f.authority.libraryID, embeddings: VectorFixture())
            let authorization = try await f.authority.authorization()
            let memory = try await create("Forget this synthetic fact.", store: store, authorization: authorization)
            let job = try #require(try await store.pendingMemoryIndexJobs(limit: 4).first)
            for vector: [Float] in [[0, 0, 0], [Float.nan, 0, 0], [1, 0]] {
                await #expect(throws: MiraError.self) {
                    _ = try await store.completeMemoryIndexJob(job, vector: vector, authorization: authorization)
                }
            }
            #expect(try await store.completeMemoryIndexJob(job, vector: [1, 0, 0], authorization: authorization))
            let operation = try await f.authority.begin(.init(id: UUID(), namespace: "memory.forget", revision: 1,
                scope: .sources([.domain(namespace: "memories", id: memory.id.rawValue, revision: 1)]),
                requestedAt: TaskWorkflowFixture.now), expected: authorization)
            _ = try await store.purgeMemory(memory.id, workspaceID: nil, expectedRevision: 1, maintenance: operation, at: TaskWorkflowFixture.now)
            try await f.authority.complete(operation, at: TaskWorkflowFixture.now)
            let nextAuthorization = try await f.authority.authorization()
            #expect(try await store.completeMemoryIndexJob(job, vector: [1, 0, 0], authorization: nextAuthorization) == false)
            #expect(try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_embeddings") } == 0)
            #expect(try await store.pendingMemoryIndexJobs(limit: 4).isEmpty)
            await store.close()
        }
    }

    private func create(_ text: String, store: SQLiteMemoryStore, authorization: AgentLibraryAuthorization,
                        scope: MemoryScope = .global, allowsRemoteUse: Bool = true) async throws -> Memory {
        try await store.createMemory(draft: .init(content: text, scope: scope, allowsRemoteUse: allowsRemoteUse),
            source: .manualEntry(id: UUID(), statement: text), operationID: UUID(), replacing: nil, expectedRevision: nil,
            authorization: authorization, at: TaskWorkflowFixture.now).memory
    }
    private func request(route: AgentModelRoute) -> AgentContextRequest {
        .init(sessionID: .init(), executionID: .init(), workspaceID: nil, userText: "breakfast suggestions",
              authorizationEpoch: 0, destination: .model(route))
    }
}

private actor VectorFixture: MemoryEmbeddingService {
    nonisolated let identity: MemoryEmbeddingIdentity
    private var ready = true
    private let queryVectors: [String: [Float]]
    private(set) var prepareCount = 0
    init(fingerprint: String = "synthetic-vector-v1", queryVectors: [String: [Float]] = [:]) {
        identity = .init(fingerprint: fingerprint, dimensions: 3)
        self.queryVectors = queryVectors
    }
    func status() -> MemoryEmbeddingStatus { ready ? .ready : .unavailable }
    func disable() { ready = false }
    func prepare() { prepareCount += 1; ready = true }
    func embed(_ input: MemoryEmbeddingInput) -> [[Float]] {
        if case .query(let query) = input, let vector = queryVectors[query] { return [vector] }
        return [[1, 0, 0]]
    }
    func unload() { ready = false }
    func close() { ready = false }
}
