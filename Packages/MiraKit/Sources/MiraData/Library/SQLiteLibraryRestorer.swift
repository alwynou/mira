import Foundation
import GRDB
import MiraCore

/// The composition root opens only local source authorities against this private stage.
/// It must not start producers, register tools, or retain these resources after close.
public struct SQLiteLibraryRestorationContext: Sendable {
    public let directory: URL
    public let database: DatabaseQueue
    public let sessions: FileSessionLibrary
    public let authorization: AgentLibraryAuthorization
    public let extensionSchemas: [String: Set<Int>]
}

/// Owns source readers until local settlement has drained, including failure paths.
public struct SQLiteLibraryRestorationSources: Sendable {
    public let authorizer: any AgentSourceAuthorizer
    let close: @Sendable () async -> Void

    public init(authorizer: any AgentSourceAuthorizer, close: @escaping @Sendable () async -> Void) {
        self.authorizer = authorizer
        self.close = close
    }
}

public struct SQLiteLibraryRestorationResult: Sendable, Equatable {
    public let directory: URL
    public let authorization: AgentLibraryAuthorization
    public let sessions: [SessionJournalHead]
}

public enum LibraryRestorationFaultStage: Sendable, CaseIterable {
    case afterCopy, afterPreparation, afterSettlement, beforePublication
}

/// Publishes a new, closed library. It never replaces or opens the host's current library.
public actor SQLiteLibraryRestorer {
    public typealias SourceFactory =
        @Sendable (SQLiteLibraryRestorationContext) async throws -> SQLiteLibraryRestorationSources
    private let modules: [SQLiteArchiveModule]
    private let sourceFactory: SourceFactory
    private let environment: RuntimeEnvironment
    private let fault: @Sendable (LibraryRestorationFaultStage) throws -> Void
    private var operations: [UUID: Task<SQLiteLibraryRestorationResult, Error>] = [:]
    private var closed = false

    public init(
        modules: [SQLiteArchiveModule], environment: RuntimeEnvironment = .init(),
        sourceFactory: @escaping SourceFactory,
        faultInjector: (@Sendable (LibraryRestorationFaultStage) throws -> Void)? = nil
    ) throws {
        self.modules = try SQLiteLibraryArchiveExporter.catalog(modules)
        guard modules.contains(where: { $0.identity.name == "business.effects" }) else {
            throw LibraryArchiveIO.invalid
        }
        self.sourceFactory = sourceFactory
        self.environment = environment
        self.fault = faultInjector ?? { _ in }
    }

    public func restore(from archive: URL, to destination: URL) async throws -> SQLiteLibraryRestorationResult {
        try Task.checkCancellation()
        guard !closed else { throw MiraError(.storage, "The library restorer is closed.") }
        guard operations.count < 4 else {
            throw MiraError(.busy, "The library restoration concurrency limit was reached.")
        }
        let id = UUID()
        let modules = self.modules
        let factory = sourceFactory
        let environment = self.environment
        let fault = self.fault
        let task = Task.detached(priority: .utility) {
            do {
                return try await Self.perform(
                    archive: archive, destination: destination, modules: modules,
                    factory: factory, environment: environment, fault: fault)
            } catch { throw error as? MiraError ?? LibraryArchiveIO.invalid }
        }
        operations[id] = task
        defer { operations[id] = nil }
        return try await task.value
    }

    /// Accepted restoration owns its work independently of the caller's cancellation.
    public func close() async {
        closed = true
        for task in operations.values { _ = await task.result }
    }

    private static func perform(
        archive: URL, destination: URL, modules: [SQLiteArchiveModule],
        factory: SourceFactory, environment: RuntimeEnvironment,
        fault: @Sendable (LibraryRestorationFaultStage) throws -> Void
    ) async throws -> SQLiteLibraryRestorationResult {
        let manifest = try SQLiteLibraryArchiveExporter.validateSync(at: archive, modules: modules)
        let stage = try LibraryArchiveIO.createStage(for: destination)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: stage.stage) } }
        for path in ["Sessions", "Sessions/sessions"] {
            try FileSessionIO.ensureDirectory(stage.stage.appendingPathComponent(path))
        }
        try LibraryArchiveFileCatalog.forEachFile(in: archive, manifest: manifest) { file in
            let source = try LibraryArchiveIO.file(file.path, under: archive)
            guard
                try SQLiteLibraryArchiveExporter.copy(source, path: file.path, to: stage.stage, limit: file.byteCount)
                    == file
            else {
                throw LibraryArchiveIO.invalid
            }
        }
        for chunk in manifest.chunks {
            let source = try LibraryArchiveIO.file(chunk.path, under: archive)
            let copy = try SQLiteLibraryArchiveExporter.copy(source, path: chunk.path, to: stage.stage, limit: chunk.byteCount)
            guard copy.byteCount == chunk.byteCount, copy.digest == chunk.digest else { throw LibraryArchiveIO.invalid }
        }
        let manifestURL = stage.stage.appendingPathComponent("manifest.json")
        try LibraryArchiveIO.write(SessionCodec.encode(manifest), to: manifestURL)
        guard try SQLiteLibraryArchiveExporter.validateSync(at: stage.stage, modules: modules) == manifest else {
            throw LibraryArchiveIO.invalid
        }
        try fault(.afterCopy)
        // Archive hashes describe the imported prefix, never the locally settled active library.
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.removeItem(at: stage.stage.appendingPathComponent("Catalog"))
        let heads = try await settle(
            directory: stage.stage, manifest: manifest, modules: modules,
            factory: factory, environment: environment, fault: fault)
        try LibraryArchiveIO.removeEmptyStageDirectories(stage.stage)
        try verifyClosed(directory: stage.stage, manifest: manifest, heads: heads, modules: modules)
        try LibraryArchiveIO.syncTree(stage.stage)
        try fault(.beforePublication)
        try FileSessionIO.publishExclusive(stage.stage, to: stage.destination)
        published = true
        // Failure here is publication uncertainty. Never delete the published target.
        try FileSessionIO.syncDirectory(stage.destination.deletingLastPathComponent())
        return .init(directory: stage.destination, authorization: manifest.authorization, sessions: heads)
    }

    private static func settle(
        directory: URL, manifest: LibraryArchiveManifest, modules: [SQLiteArchiveModule],
        factory: SourceFactory, environment: RuntimeEnvironment,
        fault: @Sendable (LibraryRestorationFaultStage) throws -> Void
    ) async throws -> [SessionJournalHead] {
        let database = try DatabaseQueue(path: directory.appendingPathComponent("Business.sqlite").path)
        var sessions: FileSessionLibrary?
        var receipts: SQLiteBusinessReceiptStore?
        var sources: SQLiteLibraryRestorationSources?
        var restoration: AgentLibraryRestoration?
        var projection: SQLiteSessionProjection?
        var coordinator: SessionProjectionCoordinator?
        func closeResources() async throws {
            await coordinator?.close()
            try await projection?.close()
            await restoration?.close()
            await sources?.close()
            await receipts?.close()
            try await sessions?.close()
            try database.close()
        }
        do {
            let at = environment.now()
            guard at.timeIntervalSince1970.isFinite else { throw LibraryArchiveIO.invalid }
            try await database.write { db in
                try SQLiteDomainDatabase.requireDurability(db)
                for module in modules {
                    if case .prepare(let apply, _) = module.restoration { try apply(db, at) }
                }
                for module in modules {
                    if case .prepare(_, let verify) = module.restoration { try verify(db) }
                }
            }
            try fault(.afterPreparation)
            let schemas = Dictionary(
                uniqueKeysWithValues: modules.flatMap { $0.sessionExtensions.map { ($0.key, $0.value) } })
            let library = try FileSessionLibrary(directory: directory.appendingPathComponent("Sessions"))
            sessions = library
            let receiptStore = try SQLiteBusinessReceiptStore(
                database: database, libraryID: manifest.authorization.libraryID,
                journal: library, payloads: library, extensionSchemas: schemas)
            receipts = receiptStore
            let local = try await factory(
                .init(
                    directory: directory, database: database, sessions: library,
                    authorization: manifest.authorization, extensionSchemas: schemas))
            sources = local
            let recovery = AgentLibraryRestoration(
                journal: library, payloads: library, receipts: receiptStore,
                authorizer: local.authorizer, environment: environment, extensionSchemas: schemas)
            restoration = recovery
            let heads = try await recovery.restore()
            try fault(.afterSettlement)
            let projectionURL = try LibraryArchiveIO.file(
                "Projections/Session.sqlite", under: directory, createParents: true)
            try LibraryArchiveIO.write(Data(), to: projectionURL)
            let index = try SQLiteSessionProjection(path: projectionURL.path)
            projection = index
            let replay = try SessionProjectionCoordinator(
                journal: library, projection: index, extensionSchemas: schemas)
            coordinator = replay
            for head in heads {
                guard try await replay.catchUp(through: head) == head,
                    try await index.head(sessionID: head.cursor.sessionID) == head
                else { throw LibraryArchiveIO.invalid }
            }
            try await closeResources()
            // This lock belongs exclusively to the stage opened above; all its writers have drained.
            try FileManager.default.removeItem(at: directory.appendingPathComponent("Sessions/.lock"))
            // Source validation is deliberately independent of every disposable cache.
            // These paths were created only by the drained writer in this private stage.
            for name in ["indexes", "checkpoints", ".cache-authentication"] {
                try FileManager.default.removeItem(at: directory.appendingPathComponent("Sessions/" + name))
            }
            return heads
        } catch {
            // Attempt every close even if one adapter cannot confirm closure.
            await coordinator?.close()
            try? await projection?.close()
            await restoration?.close()
            await sources?.close()
            await receipts?.close()
            try? await sessions?.close()
            try? database.close()
            throw error
        }
    }

    private static func verifyClosed(
        directory: URL, manifest: LibraryArchiveManifest, heads: [SessionJournalHead],
        modules: [SQLiteArchiveModule]
    ) throws {
        let snapshot = try FileSessionArchive.inspect(directory: directory.appendingPathComponent("Sessions"))
        guard snapshot.sessions.map(\.head) == heads else { throw LibraryArchiveIO.invalid }
        var configuration = Configuration()
        configuration.readonly = true
        let database = try DatabaseQueue(
            path: directory.appendingPathComponent("Business.sqlite").path, configuration: configuration)
        defer { try? database.close() }
        let attachments = try database.read { db in
            guard
                try SQLiteLibraryAuthority.availableAuthorization(in: db, libraryID: manifest.authorization.libraryID)
                    == manifest.authorization,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM business_receipts WHERE acknowledged = 0") == 0
            else {
                throw LibraryArchiveIO.invalid
            }
            for module in modules {
                if case .prepare(_, let verify) = module.restoration { try verify(db) }
            }
            return try SQLiteLibraryArchiveExporter.inspectDatabase(db, snapshot: snapshot, modules: modules)
        }
        let attachmentsByPath = Dictionary(uniqueKeysWithValues: attachments.map { ($0.path, $0) })
        let expectedSessionFiles = snapshot.sessions.count
        var sessionFiles = 0, attachmentFiles = 0
        var sawBusiness = false, sawProjection = false
        var total: Int64 = 0
        try LibraryArchiveIO.forEachFile(directory) { path in
            let url = try LibraryArchiveIO.file(path, under: directory)
            if path == "Business.sqlite" { sawBusiness = true }
            else if path == "Projections/Session.sqlite" { sawProjection = true }
            else if path.hasPrefix("Sessions/") { sessionFiles += 1 }
            else {
                guard let attachment = attachmentsByPath[path] else { throw LibraryArchiveIO.invalid }
                let file = try SQLiteLibraryArchiveExporter.inspectFile(url, path: path)
                guard file.byteCount == attachment.byteCount, file.digest == attachment.digest else {
                    throw LibraryArchiveIO.invalid
                }
                attachmentFiles += 1
            }
            let size = try LibraryArchiveIO.byteCount(url, limit: LibraryArchiveLimits.maximumFileBytes)
            guard size <= LibraryArchiveLimits.maximumTotalBytes - total else { throw LibraryArchiveIO.invalid }
            total += size
        }
        guard sawBusiness, sawProjection, sessionFiles == expectedSessionFiles,
              attachmentFiles == attachments.count else { throw LibraryArchiveIO.invalid }

    }
}
