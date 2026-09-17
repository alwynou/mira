import Foundation
import GRDB
import MiraCore
import MiraData

/// Physical adapters owned by one open library. Producer groups must drain before close.
/// Presentation code receives use cases and queries, never this adapter collection.
actor MacLibraryStorage {
    let directory: URL
    let database: DatabaseQueue
    let sessions: FileSessionLibrary
    let authority: SQLiteLibraryAuthority
    let access: AgentLibraryAccess
    let workspaces: SQLiteWorkspaceStore
    let settings: SQLiteAgentModelSettings
    let modelMetadata: SQLiteAgentModelMetadataStore
    let memories: SQLiteMemoryStore
    let embeddings: any MemoryEmbeddingService
    let extraction: SQLiteMemoryExtractionStore
    let knowledge: SQLiteKnowledgeStore
    let tasks: SQLiteTaskStore
    let business: SQLiteBusinessEffects
    let businessPrivacy: SQLiteBusinessPrivacyStore
    let privacyPlans: SQLiteSessionPrivacyPlanStore
    let contextPolicy: SQLiteAgentContextPolicy
    let searchIndex: SQLiteSessionSearchIndex
    let projection: SQLiteSessionProjection
    let archiveModules: [SQLiteArchiveModule]
    let changes: SQLiteBusinessChanges
    private var closing: Task<MiraError?, Never>?

    private init(
        directory: URL, database: DatabaseQueue, sessions: FileSessionLibrary,
        authority: SQLiteLibraryAuthority, access: AgentLibraryAccess,
        workspaces: SQLiteWorkspaceStore, settings: SQLiteAgentModelSettings,
        modelMetadata: SQLiteAgentModelMetadataStore,
        memories: SQLiteMemoryStore, embeddings: any MemoryEmbeddingService, extraction: SQLiteMemoryExtractionStore,
        knowledge: SQLiteKnowledgeStore, tasks: SQLiteTaskStore, business: SQLiteBusinessEffects,
        businessPrivacy: SQLiteBusinessPrivacyStore, privacyPlans: SQLiteSessionPrivacyPlanStore,
        contextPolicy: SQLiteAgentContextPolicy, projection: SQLiteSessionProjection,
        searchIndex: SQLiteSessionSearchIndex,
        archiveModules: [SQLiteArchiveModule], changes: SQLiteBusinessChanges
    ) {
        self.directory = directory
        self.database = database
        self.sessions = sessions
        self.authority = authority
        self.access = access
        self.workspaces = workspaces
        self.settings = settings
        self.modelMetadata = modelMetadata
        self.memories = memories
        self.embeddings = embeddings
        self.extraction = extraction
        self.knowledge = knowledge
        self.tasks = tasks
        self.business = business
        self.businessPrivacy = businessPrivacy
        self.privacyPlans = privacyPlans
        self.contextPolicy = contextPolicy
        self.projection = projection
        self.searchIndex = searchIndex
        self.archiveModules = archiveModules
        self.changes = changes
    }

    /// Opening owns its blocking I/O independently of the UI actor and waiter cancellation.
    static func open(embeddings injectedEmbeddings: (any MemoryEmbeddingService)? = nil, directory: URL, expectedLibraryID: UUID? = nil, environment: RuntimeEnvironment = .init())
        async throws -> MacLibraryStorage
    {
        try Task.checkCancellation()
        return try await Task.detached {
            var cleanups: [@Sendable () async -> Void] = []
            do {
                if expectedLibraryID != nil {
                    guard
                        FileManager.default.fileExists(
                            atPath: directory.appendingPathComponent("Business.sqlite").path),
                        FileManager.default.fileExists(atPath: directory.appendingPathComponent("Sessions").path)
                    else {
                        throw MiraError(
                            .storage, "The selected library is missing. No replacement library was created.")
                    }
                }
                let directory = try prepareDirectory(directory)
                // Acquire the journal writer lock before any business database initialization.
                let sessions = try FileSessionLibrary(directory: directory.appendingPathComponent("Sessions"))
                cleanups.append { try? await sessions.close() }
                let path = directory.appendingPathComponent("Business.sqlite")
                try checkDatabaseFiles(path)
                var configuration = Configuration()
                configuration.foreignKeysEnabled = true
                configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
                let database = try DatabaseQueue(path: path.path, configuration: configuration)
                cleanups.append { try? database.close() }
                try restrictDatabaseFiles(path)
                let authority = try SQLiteLibraryAuthority(
                    database: database,
                    validators: [SQLiteMemoryStore.maintenanceValidator] + SQLiteKnowledgeStore.maintenanceValidators)
                cleanups.append { await authority.close() }
                guard expectedLibraryID == nil || authority.libraryID == expectedLibraryID else {
                    throw MiraError(.storage, "The selected library identity does not match its saved selection.")
                }
                let access = try await AgentLibraryAccess.open(store: authority)
                cleanups.append { await access.close() }
                let workspaces = try SQLiteWorkspaceStore(database: database, libraryID: authority.libraryID)
                cleanups.append { await workspaces.close() }
                let settings = try SQLiteAgentModelSettings(database: database, libraryID: authority.libraryID)
                cleanups.append { await settings.close() }
                let modelMetadata = try SQLiteAgentModelMetadataStore(
                    database: database, libraryID: authority.libraryID)
                let models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("MiraModels/qwen3-embedding-0.6b-4bit", isDirectory: true)
                let embeddings: any MemoryEmbeddingService = injectedEmbeddings ?? MacMemoryEmbeddingService(directory: models)
                cleanups.append { await embeddings.close() }
                let memories = try SQLiteMemoryStore(database: database, libraryID: authority.libraryID, embeddings: embeddings)
                cleanups.append { await memories.close() }
                let extraction = try SQLiteMemoryExtractionStore(database: database, libraryID: authority.libraryID)
                cleanups.append { await extraction.close() }
                let knowledge = try SQLiteKnowledgeStore(
                    database: database, libraryID: authority.libraryID,
                    directory: directory.appendingPathComponent("Knowledge"))
                cleanups.append { await knowledge.close() }
                let tasks = try SQLiteTaskStore(database: database, libraryID: authority.libraryID)
                cleanups.append { await tasks.close() }
                let business = try SQLiteBusinessEffects(
                    database: database, libraryID: authority.libraryID,
                    resolver: JournalAgentEffectResolver(journal: sessions, payloads: sessions),
                    handlers: [
                        SQLiteTaskCommandHandler(now: environment.now),
                        SQLiteMemoryRememberHandler(now: environment.now),
                    ],
                    validator: MacBusinessValidator(now: environment.now))
                cleanups.append { try? await business.close() }
                let businessPrivacy = try SQLiteBusinessPrivacyStore(database: database, libraryID: authority.libraryID)
                cleanups.append { await businessPrivacy.close() }
                let privacyPlans = try SQLiteSessionPrivacyPlanStore(database: database, libraryID: authority.libraryID)
                cleanups.append { await privacyPlans.close() }
                let contextPolicy = try SQLiteAgentContextPolicy(database: database, libraryID: authority.libraryID)
                cleanups.append { await contextPolicy.close() }
                let projectionDirectory = directory.appendingPathComponent("Projections")
                try ensureDirectory(projectionDirectory)
                let projectionPath = projectionDirectory.appendingPathComponent("Session.sqlite")
                try checkDatabaseFiles(projectionPath)
                let projection = try SQLiteSessionProjection(path: projectionPath.path)
                cleanups.append { try? await projection.close() }
                try restrictDatabaseFiles(projectionPath)
                let searchPath = projectionDirectory.appendingPathComponent("Search.sqlite")
                try checkDatabaseFiles(searchPath)
                let searchIndex = try SQLiteSessionSearchIndex(path: searchPath.path)
                cleanups.append { try? await searchIndex.close() }
                try restrictDatabaseFiles(searchPath)
                let modules = try archiveModules()
                let changes = SQLiteBusinessChanges(database: database)
                cleanups.append { await changes.close() }
                return MacLibraryStorage(
                    directory: directory, database: database, sessions: sessions,
                    authority: authority, access: access, workspaces: workspaces, settings: settings,
                    modelMetadata: modelMetadata,
                    memories: memories, embeddings: embeddings, extraction: extraction, knowledge: knowledge, tasks: tasks,
                    business: business, businessPrivacy: businessPrivacy, privacyPlans: privacyPlans,
                    contextPolicy: contextPolicy, projection: projection, searchIndex: searchIndex,
                    archiveModules: modules, changes: changes)
            } catch {
                for cleanup in cleanups.reversed() { await cleanup() }
                throw MiraError.safe(error)
            }
        }.value
    }

    /// Every caller waits for the same close; an error never prevents later adapters from draining.
    func close() async -> MiraError? {
        if let closing { return await closing.value }
        let task = Task { () -> MiraError? in
            await access.close()
            var failure: MiraError?
            do { try await business.close() } catch { failure = MiraError.safe(error) }
            await extraction.close()
            await memories.close()
            await embeddings.close()
            await knowledge.close()
            await tasks.close()
            await workspaces.close()
            await settings.close()
            await contextPolicy.close()
            await businessPrivacy.close()
            await privacyPlans.close()
            await authority.close()
            do { try await projection.close() } catch { failure = failure ?? MiraError.safe(error) }
            do { try await searchIndex.close() } catch { failure = failure ?? MiraError.safe(error) }
            await changes.close()
            do { try database.close() } catch { failure = failure ?? MiraError.safe(error) }
            // Keep the library lock through all business/projection closure, including failures.
            do { try await sessions.close() } catch { failure = failure ?? MiraError.safe(error) }
            return failure
        }
        closing = task
        return await task.value
    }

    func diagnostics(scope: RuntimeScope) async throws -> MacLibraryDiagnostics {
        let lease = try await access.acquire(in: scope)
        let database = self.database
        do {
            let result = try await lease.read {
                try MacLibraryDiagnostics.probe(database: database)
            }
            try await lease.check()
            await lease.release()
            return result
        } catch {
            await lease.release()
            throw MiraError.safe(error)
        }
    }

    static func archiveModules() throws -> [SQLiteArchiveModule] {
        try [
            SQLiteBusinessEffects.archiveModule(), SQLiteWorkspaceStore.archiveModule(),
            SQLiteAgentModelSettings.archiveModule(), SQLiteMemoryStore.archiveModule(),
            SQLiteAgentModelMetadataStore.archiveModule(),
            SQLiteMemoryExtractionStore.archiveModule(), SQLiteTaskStore.archiveModule(),
            SQLiteKnowledgeStore.archiveModule(blobDirectory: "Knowledge"),
            SQLiteSessionConsumer.archiveModule(), SQLiteSessionPrivacyPlanStore.archiveModule(),
        ]
    }

    private static func prepareDirectory(_ input: URL) throws -> URL {
        guard input.isFileURL, input.path.hasPrefix("/"), !input.lastPathComponent.isEmpty else {
            throw invalidDirectory
        }
        let directory = input.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(input.lastPathComponent, isDirectory: true).standardizedFileURL
        if let attributes = try attributesIfPresent(directory) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw invalidDirectory }
        } else {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        let allowed: Set<String> = [
            "Business.sqlite", "Business.sqlite-wal", "Business.sqlite-shm", "Business.sqlite-journal",
            "Sessions", "Knowledge", "Projections", "credential-cleanup.json", "credential-cleanup.json.next",
            ".DS_Store",
        ]
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard Set(names).isSubset(of: allowed) else { throw invalidDirectory }
        for name in ["Sessions", "Knowledge", "Projections"] {
            let child = directory.appendingPathComponent(name)
            if let attributes = try attributesIfPresent(child) {
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw invalidDirectory }
            }
        }
        for name in ["credential-cleanup.json", "credential-cleanup.json.next", ".DS_Store"] {
            if let attributes = try attributesIfPresent(directory.appendingPathComponent(name)) {
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                    (attributes[.referenceCount] as? NSNumber)?.intValue == 1
                else { throw invalidDirectory }
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    private static func ensureDirectory(_ url: URL) throws {
        if let attributes = try attributesIfPresent(url) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw invalidDirectory }
        } else {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
        { return nil }
    }

    private static func checkDatabaseFiles(_ url: URL) throws {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            if let attributes = try attributesIfPresent(URL(fileURLWithPath: url.path + suffix)) {
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                    (attributes[.referenceCount] as? NSNumber)?.intValue == 1
                else { throw invalidDirectory }
            }
        }
    }

    private static func restrictDatabaseFiles(_ url: URL) throws {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if try attributesIfPresent(file) != nil {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
    }

    private static var invalidDirectory: MiraError {
        .init(.storage, "The library directory is invalid or contains unsupported files.")
    }
}

/// Explicit host composition. Unregistered domain tools never inherit another validator.
private struct MacBusinessValidator: SQLiteBusinessAuthorizationValidator {
    let now: @Sendable () -> Date
    func validate(effect: AgentResolvedEffect, isReplay: Bool, in db: Database) throws {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo"),
           ProcessInfo.processInfo.arguments.contains("--verify-multiround-flow"),
           effect.proposal.descriptor == MacDemoSourceReadTool().descriptor {
            guard effect.context.route.adapter == MacDemoModule.adapterIdentity,
                  effect.context.route.connectionID == MacDemoModule.connectionID,
                  effect.proposal.effect == .read, effect.proposal.businessNamespace == nil,
                  effect.proposal.plan.targets.isEmpty, effect.proposal.plan.sources.isEmpty else {
                throw MiraError(.unauthorized, "The business tool is not registered in this library.")
            }
            _ = try ToolSchemaValidator.decode(try effect.proposal.plan.input.jsonString(),
                                               schema: MacDemoSourceReadTool().descriptor.definition.inputSchema)
            return
        }
        #endif
        switch effect.proposal.descriptor.definition.name {
        case "memory.search", "memory.get", "memory.remember":
            try SQLiteMemoryRememberHandler(now: now).validate(effect: effect, isReplay: isReplay, in: db)
        case "task.list", "task.change":
            try SQLiteTaskCommandHandler(now: now).validate(effect: effect, isReplay: isReplay, in: db)
        case "knowledge.search", "source.open", "source.read_chunk":
            try SQLiteKnowledgeReadValidator().validate(effect: effect, isReplay: isReplay, in: db)
        default:
            throw MiraError(.unauthorized, "The business tool is not registered in this library.")
        }
    }
}
