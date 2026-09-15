import Foundation

/// Host-owned entry point for workspace operations. Each accepted operation owns
/// its library lease until the store call has actually returned.
public actor WorkspaceApplication {
    private let store: any WorkspaceStore
    private let access: AgentLibraryAccess
    private let scope: RuntimeScope
    private var operations: [UUID: @Sendable () async -> Void] = [:]
    private var closed = false

    public init(store: any WorkspaceStore, access: AgentLibraryAccess, scope: RuntimeScope) {
        self.store = store
        self.access = access
        self.scope = scope
    }

    public func workspaces() async throws -> [Workspace] {
        try await owned { lease in
            try await lease.read { try await self.store.workspaces() }
        }
    }

    public func workspace(_ id: WorkspaceID) async throws -> Workspace {
        try await owned { lease in
            try await lease.read { try await self.store.workspace(id) }
        }
    }

    public func save(_ value: Workspace, expectedRevision: Int?) async throws {
        try await owned { lease in
            try await lease.check()
            try await self.store.saveWorkspace(
                value, expectedRevision: expectedRevision,
                authorization: lease.authorization)
        }
    }

    public func close() async {
        closed = true
        let drains = Array(operations.values)
        await withTaskGroup(of: Void.self) { group in
            for drain in drains { group.addTask { await drain() } }
        }
    }

    private func owned<T: Sendable>(
        _ operation: @escaping @Sendable (AgentLibraryAccessLease) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard !closed else { throw MiraError(.busy, "The workspace application is closed.") }

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

    private func perform<T: Sendable>(
        _ operation: @escaping @Sendable (AgentLibraryAccessLease) async throws -> T
    ) async throws -> T {
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
                onCancel: { resource.value.cancel() }
            )
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
