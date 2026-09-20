import Foundation

/// The host-owned entry point for Memory operations. Every accepted operation owns a
/// scope task and library lease until its store call and any journal read have returned.
public actor MemoryApplication {
    private let store: any MemoryStore
    private let extractionStatusReader: any MemoryExtractionStatusReader
    private let reader: JournalSessionReader
    private let access: AgentLibraryAccess
    private let scope: RuntimeScope
    private let now: @Sendable () -> Date
    private var operations: [UUID: @Sendable () async -> Void] = [:]
    private var closed = false

    public init(
        store: any MemoryStore,
        extractionStatusReader: any MemoryExtractionStatusReader, reader: JournalSessionReader,
        access: AgentLibraryAccess, scope: RuntimeScope,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.extractionStatusReader = extractionStatusReader
        self.reader = reader
        self.access = access
        self.scope = scope
        self.now = now
    }

    public func list(
        workspaceID: WorkspaceID?, states: Set<MemoryState> = [.active], query: String = "",
        limit: Int = 100
    ) async throws -> MemorySearchResult {
        try await owned { lease in
            try await lease.read {
                try await self.store.memoryList(workspaceID: workspaceID, states: states, query: query, limit: limit)
            }
        }
    }

    public func detail(_ id: MemoryID, workspaceID: WorkspaceID?) async throws -> MemoryDetail {
        try await owned { lease in
            try await lease.read { try await self.store.memoryDetail(id, workspaceID: workspaceID) }
        }
    }

    public func managementPage(_ query: MemoryManagementQuery) async throws -> MemoryManagementPage {
        try await owned { lease in
            try await lease.read {
                try await self.store.memoryManagementPage(query, at: self.timestamp())
            }
        }
    }

    public func createMemory(
        draft: MemoryDraft, source: MemorySourceInput, operationID: UUID,
        replacing: MemoryID? = nil, expectedRevision: Int? = nil
    ) async throws -> MemoryWriteReceipt {
        try draft.validate()
        return try await owned { lease in
            let writeSource: MemoryWriteSource
            switch source {
            case .userMessage(let reference, let excerpt):
                guard !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    excerpt.utf8.count <= 8_192
                else {
                    throw MiraError(.invalidInput, "The memory evidence excerpt is invalid.")
                }
                try await lease.check()
                let evidence = try await self.reader.userEvidence(reference)
                guard evidence.text.range(of: excerpt) != nil else {
                    throw MiraError(
                        .invalidInput, "The memory evidence excerpt must be an exact user-message substring.")
                }
                try await lease.check()
                writeSource = .userMessage(evidence: evidence, excerpt: excerpt)
            case .manualEntry(let id, let statement):
                guard !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    statement.utf8.count <= 8_192
                else {
                    throw MiraError(.invalidInput, "The manual memory source is invalid.")
                }
                writeSource = .manualEntry(id: id, statement: statement)
            }
            try await lease.check()
            return try await self.store.createMemory(
                draft: draft, source: writeSource, operationID: operationID,
                replacing: replacing, expectedRevision: expectedRevision,
                authorization: lease.authorization, at: self.timestamp())
        }
    }

    public func reviseMemory(
        _ id: MemoryID, workspaceID: WorkspaceID?, draft: MemoryDraft,
        expectedRevision: Int, operationID: UUID
    ) async throws -> Memory {
        try draft.validate()
        return try await owned { lease in
            try await lease.check()
            return try await self.store.reviseMemory(
                id, workspaceID: workspaceID, draft: draft,
                expectedRevision: expectedRevision, operationID: operationID,
                authorization: lease.authorization, at: self.timestamp())
        }
    }

    public func changeMemoryState(
        _ id: MemoryID, workspaceID: WorkspaceID?, state: MemoryState,
        expectedRevision: Int, operationID: UUID
    ) async throws -> Memory {
        try await owned { lease in
            try await lease.check()
            return try await self.store.changeMemoryState(
                id, workspaceID: workspaceID, state: state,
                expectedRevision: expectedRevision, operationID: operationID,
                authorization: lease.authorization, at: self.timestamp())
        }
    }

    public func confirmMemoryReplacement(
        _ candidateID: MemoryID, workspaceID: WorkspaceID?, replacingCurrent currentID: MemoryID,
        expectedCandidateRevision: Int, expectedCurrentRevision: Int,
        operationID: UUID
    ) async throws -> Memory {
        try await owned { lease in
            try await lease.check()
            return try await self.store.confirmMemoryReplacement(
                candidateID, workspaceID: workspaceID,
                replacingCurrent: currentID, expectedCandidateRevision: expectedCandidateRevision,
                expectedCurrentRevision: expectedCurrentRevision, operationID: operationID,
                authorization: lease.authorization, at: self.timestamp())
        }
    }

    /// Resolves a citation only after the session journal proves that the exact memory
    /// revision was included in a completed visible reply's dispatched context.
    public func citation(
        _ reference: MemoryCitationReference, sessionID: ConversationID,
        executionID: ExecutionID, workspaceID: WorkspaceID?
    ) async throws -> MemoryCitationDetail {
        guard reference.revision > 0 else { throw MiraError(.invalidInput, "The memory citation revision is invalid.") }
        return try await owned { lease in
            try await lease.check()
            let snapshot = try await self.reader.snapshot(sessionID: sessionID)
            guard snapshot.state.header?.workspaceID == workspaceID else {
                throw MiraError(.unauthorized, "The memory citation workspace is no longer authorized.")
            }
            let expected = AgentSourceReference.domain(
                namespace: "memories", id: reference.memoryID.rawValue, revision: reference.revision)
            let evidence = try await self.reader.recordedContextEvidence(sessionID: sessionID, executionID: executionID)
            guard evidence.sources.contains(expected) else {
                throw MiraError(
                    .unauthorized, "This memory reference was not used in the selected reply or is no longer available."
                )
            }
            try await lease.check()
            return try await lease.read {
                try await self.store.memoryCitationRevision(reference, workspaceID: workspaceID)
            }
        }
    }

    /// Reads the selected completed replies' recorded memory sources and resolves their
    /// current lifecycle state.
    public func contextNotices(sessionID: ConversationID, executionIDs: Set<ExecutionID>,
                               workspaceID: WorkspaceID?) async throws -> [ExecutionID: [MemoryContextNotice]] {
        guard executionIDs.count <= 128 else {
            throw MiraError(.invalidInput, "The memory history selection exceeds its supported bounds.")
        }
        return try await owned { lease in
            try await lease.read {
                let snapshot = try await self.reader.snapshot(sessionID: sessionID)
                guard snapshot.state.header?.workspaceID == workspaceID else {
                    throw MiraError(.unauthorized, "The memory history workspace is no longer authorized.")
                }
                let timestamp = try await self.timestamp()
                var result: [ExecutionID: [MemoryContextNotice]] = [:]
                for id in executionIDs.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
                    try Task.checkCancellation()
                    guard snapshot.state.executions[id] != nil else {
                        throw MiraError(.unauthorized, "The selected reply does not belong to this session.")
                    }
                    let evidence: SessionRecordedContextEvidence
                    do {
                        evidence = try await self.reader.recordedContextEvidence(in: snapshot, executionID: id)
                    } catch let error as MiraError where error.code == .unauthorized {
                        continue
                    }
                    let references = evidence.sources.compactMap { source -> MemoryCitationReference? in
                        guard case .domain(let namespace, let id, let revision) = source,
                              namespace == "memories" else { return nil }
                        return .init(memoryID: .init(id), revision: revision)
                    }
                    guard !references.isEmpty else { continue }
                    let notices = try await self.store.memoryContextNotices(
                        references: references, workspaceID: workspaceID,
                        connectionID: evidence.route.connectionID, at: timestamp)
                    if !notices.isEmpty { result[id] = notices }
                }
                return result
            }
        }
    }

    public func extractionStatus(sessionID: ConversationID, executionID: ExecutionID, workspaceID: WorkspaceID?,
                                 before: MemoryExtractionStatusCursor? = nil, limit: Int = 8)
        async throws -> MemoryExtractionStatusPage {
        try await owned { lease in
            try await lease.read {
                try await self.validateExtractionScope(sessionID: sessionID, executionID: executionID, workspaceID: workspaceID)
                return try await self.extractionStatusReader.memoryExtractionStatus(
                    sessionID: sessionID, executionID: executionID, workspaceID: workspaceID, before: before, limit: limit)
            }
        }
    }

    public func extractionReport(_ id: MemoryExtractionJobID, sessionID: ConversationID,
                                 executionID: ExecutionID, workspaceID: WorkspaceID?) async throws -> MemoryExtractionJobReport {
        try await owned { lease in
            try await lease.read {
                try await self.validateExtractionScope(sessionID: sessionID, executionID: executionID, workspaceID: workspaceID)
                return try await self.extractionStatusReader.memoryExtractionReport(
                    id, sessionID: sessionID, executionID: executionID, workspaceID: workspaceID)
            }
        }
    }

    private func validateExtractionScope(sessionID: ConversationID, executionID: ExecutionID, workspaceID: WorkspaceID?)
        async throws {
        let snapshot = try await reader.snapshot(sessionID: sessionID)
        guard snapshot.state.header?.workspaceID == workspaceID, snapshot.state.executions[executionID] != nil else {
            throw MiraError(.notFound, "The extraction source execution is unavailable in this workspace.")
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
            throw MiraError(.configuration, "The memory operation clock returned an invalid date.")
        }
        return value
    }

    private func owned<T: Sendable>(_ operation: @escaping @Sendable (AgentLibraryAccessLease) async throws -> T)
        async throws -> T
    {
        try Task.checkCancellation()
        guard !closed else { throw MiraError(.busy, "The memory application is closed.") }
        let id = UUID()
        let task = Task {
            defer { self.operations[id] = nil }
            return try await self.perform(operation)
        }
        operations[id] = {
            task.cancel()
            _ = await task.result
        }
        return try await task.value
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable (AgentLibraryAccessLease) async throws -> T)
        async throws -> T
    {
        let lease = try await access.acquire(in: scope)
        let resource: AgentLibraryResourceLease<Task<T, any Error>>
        do {
            resource = try await lease.start {
                let task = Task { try await operation(lease) }
                return AgentLibraryResource(
                    value: task,
                    cleanup: {
                        task.cancel()
                        _ = await task.result
                    })
            }
        } catch {
            await lease.release()
            throw error
        }
        do {
            try lease.bindCancellation { resource.value.cancel() }
            let value = try await withTaskCancellationHandler(
                operation: { try await resource.value.value },
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
