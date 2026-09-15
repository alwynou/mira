import Foundation

/// Owns local search and its revocable payload reads. The host drains this service
/// before clearing the text index or replacing the library work group.
public actor SessionSearchService {
    private let journal: any SessionJournal
    private let payloads: any SessionPayloadReader
    private let index: any SessionSearchIndex
    private let access: AgentLibraryAccess
    private let scope: RuntimeScope
    private let schemas: [String: Set<Int>]
    private let maximumPageBytes: Int
    private var jobs: [UUID: @Sendable () async -> Void] = [:]
    private var refresh: (id: UUID, task: Task<Void, any Error>)?
    private var closeTask: Task<Void, Never>?

    public init(
        journal: any SessionJournal, payloads: any SessionPayloadReader,
        index: any SessionSearchIndex, access: AgentLibraryAccess, scope: RuntimeScope,
        maximumPageBytes: Int = 64 * 1_024 * 1_024,
        extensionSchemas: [String: Set<Int>] = [:]
    ) throws {
        guard (1...(128 * 1_024 * 1_024)).contains(maximumPageBytes) else {
            throw MiraError(.invalidInput, "The session query limit is invalid.")
        }
        self.journal = journal
        self.payloads = payloads
        self.index = index
        self.access = access
        self.scope = scope
        self.maximumPageBytes = maximumPageBytes
        self.schemas = extensionSchemas
    }

    /// One shared refresh owns its own library lease. Cancelling a waiter never
    /// cancels another searcher's replay; close and maintenance still drain it.
    public func synchronizeLibrary() async throws {
        try await owned { _ in try await self.refreshLibrary() }
    }

    public func search(
        _ selection: SessionSearchSelection, after: SessionSearchCursor? = nil,
        limit: Int = 32
    ) async throws -> SessionSearchPage {
        try selection.validate()
        guard (1...128).contains(limit) else {
            throw MiraError(.invalidInput, "The session query limit is invalid.")
        }
        return try await owned { lease in
            try await self.refreshLibrary()
            try Task.checkCancellation()
            let page = try await lease.read {
                try await self.index.search(selection, after: after, limit: limit)
            }
            return try await SessionSearchReader.resolve(
                page, selection: selection, limit: limit, journal: self.journal,
                payloads: self.payloads, schemas: self.schemas, lease: lease,
                maximumPageBytes: self.maximumPageBytes)
        }
    }

    public func close() async {
        if let closeTask {
            await closeTask.value
            return
        }
        let drains = Array(jobs.values)
        let refreshTask = refresh?.task
        refreshTask?.cancel()
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                if let refreshTask { group.addTask { _ = await refreshTask.result } }
                for drain in drains { group.addTask { await drain() } }
            }
        }
        closeTask = task
        await task.value
    }

    private func refreshLibrary() async throws {
        try requireOpen()
        if let refresh {
            try await refresh.task.value
            try requireOpen()
            return
        }
        let id = UUID()
        let task = Task {
            defer { if self.refresh?.id == id { self.refresh = nil } }
            try await self.perform { lease in
                try await SessionSearchReader.synchronize(
                    journal: self.journal, payloads: self.payloads, index: self.index,
                    schemas: self.schemas, lease: lease)
            }
        }
        refresh = (id, task)
        try await task.value
        try requireOpen()
    }

    private func requireOpen() throws {
        try Task.checkCancellation()
        guard closeTask == nil else { throw MiraError(.busy, "The session search service is closed.") }
    }

    private func owned<T: Sendable>(_ operation: @escaping @Sendable (AgentLibraryAccessLease) async throws -> T)
        async throws -> T
    {
        try requireOpen()
        guard jobs.count < 16 else { throw MiraError(.busy, "Too many session queries are in progress.") }
        let id = UUID()
        let task = Task {
            defer { self.jobs[id] = nil }
            return try await self.perform(operation)
        }
        jobs[id] = {
            task.cancel()
            _ = await task.result
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
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
                operation: { try await resource.value.value }, onCancel: { resource.value.cancel() })
            try Task.checkCancellation()
            try await lease.check()
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
