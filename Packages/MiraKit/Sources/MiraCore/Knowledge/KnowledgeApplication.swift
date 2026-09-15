import Foundation

/// Host-owned entry point for knowledge operations. Accepted work keeps its
/// library lease until the store or journal operation has actually returned.
public actor KnowledgeApplication {
    private let store: any KnowledgeStore
    private let reader: JournalSessionReader
    private let access: AgentLibraryAccess
    private let scope: RuntimeScope
    private let now: @Sendable () -> Date
    private var operations: [UUID: @Sendable () async -> Void] = [:]
    private var closed = false

    public init(store: any KnowledgeStore, reader: JournalSessionReader, access: AgentLibraryAccess,
                scope: RuntimeScope, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.reader = reader
        self.access = access
        self.scope = scope
        self.now = now
    }

    public func list(scope: KnowledgeReadScope, limit: Int = 100) async throws -> [KnowledgeSource] {
        try await owned { lease in
            try await lease.read { try await self.store.knowledgeSources(scope: scope, limit: limit) }
        }
    }

    public func detail(_ id: KnowledgeSourceID, versionID: SourceVersionID? = nil,
                       scope: KnowledgeReadScope) async throws -> KnowledgeSourceDetail {
        try await owned { lease in
            try await lease.read { try await self.store.knowledgeSource(id, versionID: versionID, scope: scope) }
        }
    }

    public func chunk(_ id: SourceChunkID, scope: KnowledgeReadScope) async throws -> SourceChunk {
        try await owned { lease in
            try await lease.read { try await self.store.sourceChunk(id, scope: scope) }
        }
    }

    public func search(query: String, scope: KnowledgeReadScope, limit: Int = 6) async throws -> KnowledgeSearchResult {
        try await owned { lease in
            try await lease.read { try await self.store.searchKnowledge(query: query, scope: scope, limit: limit) }
        }
    }

    public func importMarkdown(_ input: KnowledgeImport, workspaceID: WorkspaceID?, updating: KnowledgeSourceID? = nil,
                               expectedRevision: Int? = nil, operationID: UUID) async throws -> KnowledgeImportReceipt {
        try input.validate()
        return try await owned { lease in
            try await lease.check()
            return try await self.store.importMarkdown(input, workspaceID: workspaceID, updating: updating,
                expectedRevision: expectedRevision, operationID: operationID,
                authorization: lease.authorization, at: self.timestamp())
        }
    }

    public func allowRemoteUse(_ id: KnowledgeSourceID, workspaceID: WorkspaceID?, expectedRevision: Int,
                               operationID: UUID) async throws -> KnowledgeSource {
        return try await owned { lease in
            try await lease.check()
            return try await self.store.allowSourceRemoteUse(id, workspaceID: workspaceID,
                expectedRevision: expectedRevision, operationID: operationID,
                authorization: lease.authorization, at: self.timestamp())
        }
    }

    /// A citation is valid only when the journal proves that this exact chunk
    /// source was dispatched for a completed visible reply. The original
    /// frozen route is then passed to the current knowledge policy check.
    public func citation(_ reference: SourceCitationReference, sessionID: ConversationID,
                         executionID: ExecutionID, workspaceID: WorkspaceID?) async throws -> SourceCitationDetail {
        return try await owned { lease in
            try await lease.check()
            let evidence = try await self.reader.recordedContextEvidence(sessionID: sessionID, executionID: executionID)
            guard evidence.workspaceID == workspaceID else {
                throw MiraError(.unauthorized, "The knowledge citation workspace is no longer authorized.")
            }
            guard evidence.sources.contains(.domain(namespace: KnowledgeSources.chunkNamespace,
                                                     id: reference.chunkID.rawValue, revision: 1)) else {
                throw MiraError(.unauthorized, "This knowledge reference was not used in the selected reply or is no longer available.")
            }
            try evidence.route.validate()
            try await lease.check()
            let scope = KnowledgeReadScope(workspaceID: workspaceID, destination: .model(evidence.route))
            let detail = try await lease.read { try await self.store.sourceCitation(reference, scope: scope) }
            guard detail.source.id == detail.chunk.summary.sourceID,
                  detail.version.id == reference.versionID,
                  detail.version.sourceID == detail.source.id,
                  detail.chunk.id == reference.chunkID,
                  detail.chunk.summary.sourceID == detail.source.id,
                  detail.chunk.summary.sourceVersionID == detail.version.id else {
                throw MiraError(.storage, "The knowledge citation result is inconsistent.")
            }
            return detail
        }
    }

    public func close() async {
        closed = true
        let drains = Array(operations.values)
        await withTaskGroup(of: Void.self) { group in
            for drain in drains { group.addTask { await drain() } }
        }
    }

    private func timestamp() throws -> Date {
        let value = now()
        guard value.timeIntervalSince1970.isFinite else {
            throw MiraError(.configuration, "The knowledge operation clock returned an invalid date.")
        }
        return value
    }

    private func owned<T: Sendable>(_ operation: @escaping @Sendable (AgentLibraryAccessLease) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard !closed else { throw MiraError(.busy, "The knowledge application is closed.") }
        let id = UUID()
        let task = Task {
            defer { self.operations[id] = nil }
            return try await self.perform(operation)
        }
        operations[id] = { task.cancel(); _ = await task.result }
        return try await task.value
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable (AgentLibraryAccessLease) async throws -> T) async throws -> T {
        let lease = try await access.acquire(in: scope)
        let resource: AgentLibraryResourceLease<Task<T, any Error>>
        do {
            resource = try await lease.start {
                let task = Task { try await operation(lease) }
                return AgentLibraryResource(value: task, cleanup: { task.cancel(); _ = await task.result })
            }
        } catch {
            await lease.release()
            throw error
        }
        do {
            try lease.bindCancellation { resource.value.cancel() }
            let value = try await withTaskCancellationHandler(operation: { try await resource.value.value },
                                                               onCancel: { resource.value.cancel() })
            await resource.release()
            await lease.release()
            return value
        } catch {
            await resource.release()
            await lease.release()
            throw error
        }
    }
}
