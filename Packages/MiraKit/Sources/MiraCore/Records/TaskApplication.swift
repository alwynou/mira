import Foundation

/// Explicit host operations for the task domain. Notification delivery is reconciled separately.
/// Accepted operations own their library resources until the actual work returns.
public actor TaskApplication {
    private let store: any TaskStore
    private let reader: JournalSessionReader
    private let access: AgentLibraryAccess
    private let scope: RuntimeScope
    private let now: @Sendable () -> Date
    private var jobs: [UUID: @Sendable () async -> Void] = [:]
    private var closed = false

    public init(store: any TaskStore, reader: JournalSessionReader, access: AgentLibraryAccess,
                scope: RuntimeScope, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.reader = reader; self.access = access; self.scope = scope; self.now = now
    }

    public func tasks(workspaceID: WorkspaceID?, includeCompleted: Bool = false, limit: Int = 50) async throws -> [MiraTask] {
        try await owned { lease in
            try await lease.read { try await self.store.taskList(workspaceID: workspaceID, includeCompleted: includeCompleted, limit: limit) }
        }
    }

    public func proposals(workspaceID: WorkspaceID?) async throws -> [TaskProposal] {
        try await owned { lease in
            try await lease.read { try await self.store.taskProposals(workspaceID: workspaceID) }
        }
    }

    public func save(id: MiraTaskID, workspaceID: WorkspaceID?, draft: TaskDraft, status: MiraTaskStatus,
                     expectedRevision: Int?, operationID: UUID) async throws -> MiraTask {
        try await owned { lease in
            try await lease.check()
            return try await self.store.saveTask(id, workspaceID: workspaceID, draft: draft, status: status,
                expectedRevision: expectedRevision, operationID: operationID, authorization: lease.authorization, at: self.now())
        }
    }

    public func resolve(id: UUID, workspaceID: WorkspaceID?, accept: Bool,
                        correctedDraft: TaskDraft? = nil) async throws -> TaskWriteReceipt {
        try await owned { lease in
            let source: SessionUserEvidence?
            if accept {
                let proposals = try await lease.read { try await self.store.taskProposals(workspaceID: workspaceID) }
                guard let proposal = proposals.first(where: { $0.id == id }) else {
                    throw MiraError(.conflict, "This task proposal has already been reviewed.")
                }
                source = try await lease.read { try await self.reader.userEvidence(proposal.evidence.source) }
            } else { source = nil }
            try await lease.check()
            return try await self.store.resolveTaskProposal(id, workspaceID: workspaceID, accept: accept,
                correctedDraft: correctedDraft, source: source, authorization: lease.authorization, at: self.now())
        }
    }

    public func resumeReminder(id: MiraTaskID, workspaceID: WorkspaceID?, expectedRevision: Int) async throws {
        try await owned { lease in
            try await lease.check()
            try await self.store.resumeReminder(id, workspaceID: workspaceID, expectedRevision: expectedRevision,
                                               authorization: lease.authorization, at: self.now())
        }
    }

    public func close() async {
        closed = true
        let draining = Array(jobs.values)
        await withTaskGroup(of: Void.self) { group in
            for drain in draining { group.addTask { await drain() } }
        }
    }

    private func owned<T: Sendable>(_ operation: @escaping @Sendable (AgentLibraryAccessLease) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard !closed else { throw MiraError(.busy, "The task application is closed.") }
        let id = UUID()
        let task = Task {
            defer { self.jobs[id] = nil }
            return try await self.perform(operation)
        }
        jobs[id] = { task.cancel(); _ = await task.result }
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
        } catch { await lease.release(); throw error }
        do {
            try lease.bindCancellation { resource.value.cancel() }
            let value = try await withTaskCancellationHandler(operation: { try await resource.value.value },
                                                               onCancel: { resource.value.cancel() })
            await resource.release(); await lease.release()
            return value
        } catch { await resource.release(); await lease.release(); throw error }
    }
}
