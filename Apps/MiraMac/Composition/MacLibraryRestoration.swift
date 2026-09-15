import Foundation
import MiraCore
import MiraData

protocol MacLibraryRestorationBackend: Sendable {
    func restore(from archive: URL, to destination: URL) async throws -> SQLiteLibraryRestorationResult
    func close() async
}

extension SQLiteLibraryRestorer: MacLibraryRestorationBackend {}

/// Restores a closed library directory without touching the currently open library.
/// The restored directory is only published after local settlement and validation.
actor MacLibraryRestoration {
    private let backend: any MacLibraryRestorationBackend
    private var closed = false
    private var operations: [UUID: Task<SQLiteLibraryRestorationResult, Error>] = [:]
    private var closeTask: Task<Void, Never>?

    init(environment: RuntimeEnvironment = .init()) throws {
        self.backend = try SQLiteLibraryRestorer(
            modules: MacLibraryStorage.archiveModules(), environment: environment,
            sourceFactory: Self.makeSources)
    }

    init(backend: any MacLibraryRestorationBackend) {
        self.backend = backend
    }

    func restore(from archive: URL, to destination: URL) async throws -> SQLiteLibraryRestorationResult {
        try Task.checkCancellation()
        guard !closed else {
            throw MiraError(.storage, "The library restoration service is closed.")
        }
        guard operations.count < 4 else {
            throw MiraError(.busy, "Too many library restorations are already running.")
        }
        let id = UUID()
        let backend = self.backend
        let operation = Task {
            let sourceAccessed = archive.startAccessingSecurityScopedResource()
            let destinationAccessed = destination.deletingLastPathComponent()
                .startAccessingSecurityScopedResource()
            defer {
                if destinationAccessed { destination.deletingLastPathComponent().stopAccessingSecurityScopedResource() }
                if sourceAccessed { archive.stopAccessingSecurityScopedResource() }
            }
            return try await backend.restore(from: archive, to: destination)
        }
        operations[id] = operation
        defer { operations[id] = nil }
        return try await operation.value
    }

    func close() async {
        if let closeTask {
            await closeTask.value
            return
        }
        closed = true
        let accepted = Array(operations.values)
        let backend = self.backend
        let task = Task {
            for operation in accepted { _ = await operation.result }
            await backend.close()
        }
        closeTask = task
        await task.value
    }

    static func makeSources(
        _ context: SQLiteLibraryRestorationContext
    ) async throws -> SQLiteLibraryRestorationSources {
        var memory: SQLiteMemoryStore?
        var knowledge: SQLiteKnowledgeStore?
        var tasks: SQLiteTaskStore?
        var policy: SQLiteAgentContextPolicy?
        let scope = RuntimeScope(kind: .application)
        do {
            let memoryStore = try SQLiteMemoryStore(
                database: context.database, libraryID: context.authorization.libraryID)
            memory = memoryStore
            let knowledgeStore = try SQLiteKnowledgeStore(
                database: context.database, libraryID: context.authorization.libraryID,
                directory: context.directory.appendingPathComponent("Knowledge"))
            knowledge = knowledgeStore
            let taskStore = try SQLiteTaskStore(
                database: context.database, libraryID: context.authorization.libraryID)
            tasks = taskStore
            let contextPolicy = try SQLiteAgentContextPolicy(
                database: context.database, libraryID: context.authorization.libraryID)
            policy = contextPolicy

            let authorities = RuntimeRegistry<any AgentDomainSourceAuthority>()
            try await authorities.register(
                id: "memories", value: MemorySourceAuthority(store: memoryStore), scope: scope)
            try await authorities.register(
                id: KnowledgeSources.metadataNamespace,
                value: try KnowledgeSourceAuthority(
                    store: knowledgeStore, namespace: KnowledgeSources.metadataNamespace),
                scope: scope)
            try await authorities.register(
                id: KnowledgeSources.chunkNamespace,
                value: try KnowledgeSourceAuthority(
                    store: knowledgeStore, namespace: KnowledgeSources.chunkNamespace),
                scope: scope)
            try await authorities.register(
                id: "tasks", value: TaskSourceAuthority(store: taskStore), scope: scope)

            let reader = JournalSessionReader(
                journal: context.sessions, payloads: context.sessions,
                extensionSchemas: context.extensionSchemas)
            let authorizer = JournalAgentSourceAuthorizer(
                reader: reader, policy: contextPolicy, domains: authorities)
            return SQLiteLibraryRestorationSources(
                authorizer: authorizer,
                close: {
                    await scope.dispose()
                    await memoryStore.close()
                    await knowledgeStore.close()
                    await taskStore.close()
                    await contextPolicy.close()
                })
        } catch {
            await scope.dispose()
            await memory?.close()
            await knowledge?.close()
            await tasks?.close()
            await policy?.close()
            throw error
        }
    }
}
