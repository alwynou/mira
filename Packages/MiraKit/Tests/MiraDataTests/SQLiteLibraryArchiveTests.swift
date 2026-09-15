import CryptoKit
import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("SQLite library archives", .timeLimit(.minutes(1)))
struct SQLiteLibraryArchiveTests {
    @Test
    func caseAliasCannotHideAnUnlistedPhysicalFile() async throws {
        let fixture = try await ArchiveFixture.make()
        let exporter = try fixture.exporter()
        let destination = fixture.root.appendingPathComponent("case-alias")
        do {
            let manifest = try await exporter.export(to: destination, authorization: fixture.authorization)
            var files: [LibraryArchiveManifest.File] = []
            try LibraryArchiveFileCatalog.forEachFile(in: destination, manifest: manifest) { files.append($0) }
            let payload = try #require(files.first { $0.path.hasPrefix("Sessions/payloads/") })
            let alias = payload.path.replacingOccurrences(of: "Sessions/payloads/", with: "Sessions/PAYLOADS/")
            if try destination.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames == false {
                #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(alias).path))
            }
            files.append(.init(path: alias, byteCount: payload.byteCount, digest: payload.digest))
            try Data("Unlisted synthetic file.".utf8).write(to: destination.appendingPathComponent("unlisted.bin"))
            try FileManager.default.removeItem(at: destination.appendingPathComponent("Catalog"))
            let writer = try LibraryArchiveFileCatalog.Writer(directory: destination)
            for file in files.sorted(by: { $0.path < $1.path }) { try writer.append(file) }
            let altered = LibraryArchiveManifest(formatVersion: 2, authorization: manifest.authorization,
                modules: manifest.modules, sessions: manifest.sessions, chunks: try writer.finish())
            try SessionCodec.encode(altered).write(to: destination.appendingPathComponent("manifest.json"))
            await #expect(throws: MiraError.self) {
                _ = try await SQLiteLibraryArchiveExporter.validate(at: destination, modules: [fixture.module])
            }
        } catch {
            await exporter.close()
            await fixture.close()
            throw error
        }
        await exporter.close()
        await fixture.close()
    }

    @Test
    func exportPublishesDatabaseSessionsPayloadsAttachmentsAndManifest() async throws {
        let fixture = try await ArchiveFixture.make()
        let exporter = try fixture.exporter()
        let destination = fixture.root.appendingPathComponent("archive")
        do {
            let manifest = try await exporter.export(to: destination, authorization: fixture.authorization)
            let checked = try await SQLiteLibraryArchiveExporter.validate(at: destination, modules: [fixture.module])
            #expect(checked == manifest)
            var files: [LibraryArchiveManifest.File] = []
            try LibraryArchiveFileCatalog.forEachFile(in: destination, manifest: manifest) { files.append($0) }
            #expect(manifest.modules.contains(fixture.module.identity))
            #expect(files.contains { $0.path == "Business.sqlite" })
            #expect(files.contains { $0.path.hasPrefix("Sessions/sessions/") && $0.path.hasSuffix(".jsonl") })
            #expect(files.contains { $0.path.hasPrefix("Sessions/payloads/") && $0.path.hasSuffix(".bin") })
            #expect(!files.contains { $0.path.contains("/indexes/") || $0.path.contains("/checkpoints/") || $0.path.contains(".cache-authentication") })
            #expect(files.contains { $0.path == fixture.attachmentPath })
            let copied = try Data(contentsOf: destination.appendingPathComponent(fixture.attachmentPath))
            #expect(copied == fixture.attachmentBytes)
            let archiveDB = try DatabaseQueue(path: destination.appendingPathComponent("Business.sqlite").path)
            #expect(
                try await archiveDB.read { try String.fetchOne($0, sql: "SELECT value FROM archive_fixture") }
                    == "proof")
            try archiveDB.close()
            await exporter.close()
            try await fixture.library.close()
            await fixture.authority.close()
            try fixture.database.close()
        } catch {
            await exporter.close()
            try? await fixture.library.close()
            await fixture.authority.close()
            try? fixture.database.close()
            try? FileManager.default.removeItem(at: fixture.root)
            throw error
        }
        try FileManager.default.removeItem(at: fixture.root)
    }

    @Test
    func coreCoordinatorOwnsAnActualArchiveAndLeavesAuthorizationUnchanged() async throws {
        let fixture = try await ArchiveFixture.make()
        let exporter = try fixture.exporter()
        let access = try await AgentLibraryAccess.open(store: fixture.authority)
        let scope = RuntimeScope(kind: .application)
        let lease = try await access.acquire(in: scope)
        let coordinator = try AgentLibraryMaintenanceCoordinator(
            access: access,
            handlers: RuntimeRegistry<any AgentLibraryMaintenanceHandler>(),
            workOwners: [.init(id: "archive.fixture") { await lease.release() }])
        do {
            let destination = fixture.root.appendingPathComponent("coordinated")
            let manifest = try await coordinator.withQuiescentSnapshot(expected: fixture.authorization) {
                authorization in
                try await exporter.export(to: destination, authorization: authorization)
            }
            #expect(manifest.authorization == fixture.authorization)
            #expect(lease.isRevoked)
            #expect((await access.snapshot()).phase == .ready)
            #expect(try await fixture.authority.state().pending == nil)
        } catch {
            await lease.release()
            await coordinator.close()
            await access.close()
            await scope.dispose()
            await exporter.close()
            await fixture.close()
            throw error
        }
        await coordinator.close()
        await access.close()
        await scope.dispose()
        await exporter.close()
        await fixture.close()
    }

    @Test
    func requiredSessionExtensionCanBeOwnedByModuleWithoutSQLTables() async throws {
        let fixture = try await ArchiveFixture.make(requiredExtension: true)
        let eventModule = try SQLiteArchiveModule(
            identity: .init(name: "event.only", revision: 1), schemaStatements: [],
            sessionExtensions: ["archive.fixture": [1]], restoration: .preserve, inspect: { _, _ in [] })
        let exporter = try SQLiteLibraryArchiveExporter(
            database: fixture.database, sessions: fixture.library,
            libraryID: fixture.authority.libraryID, attachmentDirectory: fixture.root,
            modules: [fixture.module, eventModule])
        do {
            let destination = fixture.root.appendingPathComponent("extensions")
            let manifest = try await exporter.export(to: destination, authorization: fixture.authorization)
            #expect(manifest.modules.contains(eventModule.identity))
            #expect(
                try await SQLiteLibraryArchiveExporter.validate(
                    at: destination, modules: [fixture.module, eventModule]) == manifest)
            await #expect(throws: MiraError.self) {
                _ = try await SQLiteLibraryArchiveExporter.validate(at: destination, modules: [fixture.module])
            }
            let missing = try fixture.exporter()
            await #expect(throws: MiraError.self) {
                _ = try await missing.export(
                    to: fixture.root.appendingPathComponent("missing-extension"), authorization: fixture.authorization)
            }
            await missing.close()
        } catch {
            await exporter.close()
            await fixture.close()
            throw error
        }
        await exporter.close()
        await fixture.close()
    }

    @Test
    func moduleValidationCannotWriteSourceDatabase() async throws {
        let fixture = try await ArchiveFixture.make()
        let writer = try SQLiteArchiveModule(
            identity: .init(name: "write.fixture", revision: 1), schemaStatements: [],
            sessionExtensions: ["write.fixture": [1]], restoration: .preserve,
            inspect: { db, _ in
                try db.execute(sql: "UPDATE archive_fixture SET value='changed'")
                return []
            })
        let exporter = try SQLiteLibraryArchiveExporter(
            database: fixture.database, sessions: fixture.library,
            libraryID: fixture.authority.libraryID, attachmentDirectory: fixture.root,
            modules: [fixture.module, writer])
        do {
            await #expect(throws: MiraError.self) {
                _ = try await exporter.export(
                    to: fixture.root.appendingPathComponent("no-write"), authorization: fixture.authorization)
            }
            #expect(
                try await fixture.database.read { try String.fetchOne($0, sql: "SELECT value FROM archive_fixture") }
                    == "proof")
        } catch {
            await exporter.close()
            await fixture.close()
            throw error
        }
        await exporter.close()
        await fixture.close()
    }

    @Test(arguments: [LibraryArchiveFaultStage.afterDatabaseSnapshot, .afterCatalogChunk])
    func faultPausesExportUntilReleasedAndLeavesNoPartialOrLateDestination(_ stage: LibraryArchiveFaultStage) async throws {
        let gate = ArchiveFaultGate(stage: stage)
        let fixture = try await ArchiveFixture.make(fault: gate)
        let exporter = try fixture.exporter()
        let destination = fixture.root.appendingPathComponent("paused")
        let exportTask = Task { try await exporter.export(to: destination, authorization: fixture.authorization) }
        var closeTask: Task<Void, Never>?
        var writer: Task<Void, any Error>?
        do {
            try await gate.waitUntilEntered()
            let closeFinished = ArchiveFlag()
            closeTask = Task {
                await exporter.close()
                closeFinished.mark()
            }
            #expect(closeFinished.value == false)
            let writerStarted = ArchiveFlag()
            let writerFinished = ArchiveFlag()
            writer = Task {
                writerStarted.mark()
                try await fixture.database.write {
                    try $0.execute(sql: "INSERT INTO archive_fixture(id, value) VALUES ('later', 'later')")
                }
                writerFinished.mark()
            }
            while !writerStarted.value { await Task.yield() }
            #expect(writerFinished.value == false)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("sentinel".utf8).write(to: destination.appendingPathComponent("sentinel"))
            gate.release()
            await #expect(throws: MiraError.self) { _ = try await exportTask.value }
            if let writer { try await writer.value }
            #expect(writerFinished.value)
            await closeTask?.value
            #expect(try Data(contentsOf: destination.appendingPathComponent("sentinel")) == Data("sentinel".utf8))
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.json").path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
                .allSatisfy { !$0.hasPrefix(".mira-archive-") })
            try await fixture.library.close()
            await fixture.authority.close()
            try fixture.database.close()
        } catch {
            gate.release()
            _ = await exportTask.result
            _ = await writer?.result
            await closeTask?.value
            await exporter.close()
            try? await fixture.library.close()
            await fixture.authority.close()
            try? fixture.database.close()
            try? FileManager.default.removeItem(at: fixture.root)
            throw error
        }
        try FileManager.default.removeItem(at: fixture.root)
    }

    @Test
    func publicationDoesNotReplaceDestinationCreatedAfterSnapshot() async throws {
        let gate = ArchiveFaultGate(stage: .beforePublication, throwsAfterRelease: false)
        let fixture = try await ArchiveFixture.make(fault: gate)
        let exporter = try fixture.exporter()
        let destination = fixture.root.appendingPathComponent("late")
        let task = Task { try await exporter.export(to: destination, authorization: fixture.authorization) }
        do {
            try await gate.waitUntilEntered()
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("late sentinel".utf8).write(to: destination.appendingPathComponent("sentinel"))
            gate.release()
            await #expect(throws: MiraError.self) { _ = try await task.value }
            #expect(try Data(contentsOf: destination.appendingPathComponent("sentinel")) == Data("late sentinel".utf8))
            await exporter.close()
            try await fixture.library.close()
            await fixture.authority.close()
            try fixture.database.close()
        } catch {
            gate.release()
            _ = await task.result
            await exporter.close()
            try? await fixture.library.close()
            await fixture.authority.close()
            try? fixture.database.close()
            try? FileManager.default.removeItem(at: fixture.root)
            throw error
        }
        try FileManager.default.removeItem(at: fixture.root)
    }

    @Test
    func validationRejectsMissingCorruptSymlinkAndModuleMismatchAndStaleAuthorization() async throws {
        let fixture = try await ArchiveFixture.make()
        let exporter = try fixture.exporter()
        do {
            let destination = fixture.root.appendingPathComponent("valid")
            _ = try await exporter.export(to: destination, authorization: fixture.authorization)
            await exporter.close()
            let missing = fixture.root.appendingPathComponent("missing")
            try FileManager.default.copyItem(at: destination, to: missing)
            try FileManager.default.removeItem(at: missing.appendingPathComponent("manifest.json"))
            await #expect(throws: MiraError.self) {
                _ = try await SQLiteLibraryArchiveExporter.validate(at: missing, modules: [fixture.module])
            }
            let corrupt = fixture.root.appendingPathComponent("corrupt")
            try FileManager.default.copyItem(at: destination, to: corrupt)
            try Data("corrupt".utf8).write(to: corrupt.appendingPathComponent("Business.sqlite"), options: .atomic)
            await #expect(throws: MiraError.self) {
                _ = try await SQLiteLibraryArchiveExporter.validate(at: corrupt, modules: [fixture.module])
            }
            let unknown = fixture.root.appendingPathComponent("unknown")
            try FileManager.default.copyItem(at: destination, to: unknown)
            let unknownDB = try DatabaseQueue(path: unknown.appendingPathComponent("Business.sqlite").path)
            try await unknownDB.write {
                try $0.execute(sql: "CREATE TABLE unexpected_archive_table(id TEXT PRIMARY KEY)")
            }
            try unknownDB.close()
            try refreshManifestFile("Business.sqlite", in: unknown)
            await #expect(throws: MiraError.self) {
                _ = try await SQLiteLibraryArchiveExporter.validate(at: unknown, modules: [fixture.module])
            }
            let traversal = fixture.root.appendingPathComponent("traversal")
            try FileManager.default.copyItem(at: destination, to: traversal)
            let manifestURL = traversal.appendingPathComponent("manifest.json")
            var manifestObject = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
            var chunks = manifestObject["chunks"] as! [[String: Any]]
            chunks[0]["path"] = "../escape"
            manifestObject["chunks"] = chunks
            try JSONSerialization.data(withJSONObject: manifestObject).write(to: manifestURL, options: .atomic)
            await #expect(throws: MiraError.self) {
                _ = try await SQLiteLibraryArchiveExporter.validate(at: traversal, modules: [fixture.module])
            }
            let symlink = fixture.root.appendingPathComponent("symlink")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: destination)
            await #expect(throws: MiraError.self) {
                _ = try await SQLiteLibraryArchiveExporter.validate(at: symlink, modules: [fixture.module])
            }
            let request = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: "archive.pending", revision: 1, scope: .library, requestedAt: Date())
            _ = try await fixture.authority.begin(request, expected: fixture.authorization)
            let staleDestination = fixture.root.appendingPathComponent("stale")
            let second = try fixture.exporter()
            await #expect(throws: MiraError.self) {
                _ = try await second.export(to: staleDestination, authorization: fixture.authorization)
            }
            await second.close()
            await fixture.authority.close()
            try fixture.database.close()
            try? await fixture.library.close()
            try FileManager.default.removeItem(at: fixture.root)
        } catch {
            await exporter.close()
            try? await fixture.library.close()
            await fixture.authority.close()
            try? fixture.database.close()
            try? FileManager.default.removeItem(at: fixture.root)
            throw error
        }
    }
}

private final class ArchiveFaultGate: @unchecked Sendable {
    private let enteredSignal = DispatchSemaphore(value: 0), releaseSignal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var entered = false
    private let stage: LibraryArchiveFaultStage
    private let throwsAfterRelease: Bool
    init(stage: LibraryArchiveFaultStage = .afterDatabaseSnapshot, throwsAfterRelease: Bool = true) {
        self.stage = stage
        self.throwsAfterRelease = throwsAfterRelease
    }
    func hit(_ stage: LibraryArchiveFaultStage) throws {
        guard stage == self.stage else { return }
        lock.withLock { entered = true }
        enteredSignal.signal()
        guard releaseSignal.wait(timeout: .now() + 10) == .success else {
            throw MiraError(.storage, "Archive fault release timed out.")
        }
        if throwsAfterRelease { throw MiraError(.storage, "Synthetic archive fault.") }
    }
    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !lock.withLock({ entered }) {
            guard ContinuousClock.now < deadline else { throw MiraError(.storage, "Archive fault was not reached.") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func release() { releaseSignal.signal() }
}

private final class ArchiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    var value: Bool { lock.withLock { marked } }
    func mark() { lock.withLock { marked = true } }
}

private struct ArchiveFixture: Sendable {
    let root: URL
    let database: DatabaseQueue
    let authority: SQLiteLibraryAuthority
    let library: FileSessionLibrary
    let authorization: AgentLibraryAuthorization
    let module: SQLiteArchiveModule
    let attachmentPath = "attachments/proof.txt"
    let attachmentBytes = Data("attachment proof".utf8)
    let fault: (@Sendable (LibraryArchiveFaultStage) throws -> Void)?

    static func make(fault: ArchiveFaultGate? = nil, requiredExtension: Bool = false) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mira-library-archive-\(UUID())")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("attachments"), withIntermediateDirectories: true)
        let attachment = Data("attachment proof".utf8)
        try attachment.write(to: root.appendingPathComponent("attachments/proof.txt"))
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
        let database = try DatabaseQueue(
            path: root.appendingPathComponent("business.sqlite").path, configuration: configuration)
        let authority = try SQLiteLibraryAuthority(database: database)
        try await database.write { db in
            try db.execute(sql: "CREATE TABLE archive_fixture(id TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO archive_fixture(id, value) VALUES ('proof', 'proof')")
        }
        let library = try FileSessionLibrary(directory: root.appendingPathComponent("source-sessions"))
        let sessionID = ConversationID()
        let batchID = UUID()
        let title = try await library.stage(
            Data("Archive fixture".utf8), sessionID: sessionID, batchID: batchID,
            retentionGroup: UUID(), kind: .title)
        let payload = try await library.stage(
            Data("payload proof".utf8), sessionID: sessionID, batchID: batchID,
            retentionGroup: UUID(), kind: .module)
        let batch = SessionBatch(
            id: batchID, sessionID: sessionID, expectedSequence: 0,
            events: [
                .init(
                    sequence: 1, occurredAt: Date(timeIntervalSince1970: 10),
                    fact: .opened(.init(workspaceID: nil, title: title))),
                .init(
                    sequence: 2, occurredAt: Date(timeIntervalSince1970: 10),
                    fact: .extensionRecorded(
                        namespace: "archive.fixture", schemaVersion: 1, required: requiredExtension, body: payload)),
            ])
        guard await library.append(batch) == .committed(batch.cursor) else {
            throw MiraError(.storage, "Fixture journal append failed.")
        }
        let module = try SQLiteArchiveModule(
            identity: .init(name: "archive.fixture", revision: 1),
            schemaStatements: ["CREATE TABLE archive_fixture(id TEXT PRIMARY KEY, value TEXT NOT NULL)"], restoration: .preserve,
            inspect: { _, _ in
                [.init(path: "attachments/proof.txt", byteCount: attachment.count, digest: digest(attachment))]
            })
        let injector: (@Sendable (LibraryArchiveFaultStage) throws -> Void)?
        if let fault { injector = { stage in try fault.hit(stage) } } else { injector = nil }
        let authorization = try await authority.authorization()
        return .init(
            root: root, database: database, authority: authority, library: library,
            authorization: authorization, module: module, fault: injector)
    }

    func close() async {
        try? await library.close()
        await authority.close()
        try? database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func exporter() throws -> SQLiteLibraryArchiveExporter {
        try .init(
            database: database, sessions: library, libraryID: authority.libraryID,
            attachmentDirectory: root, modules: [module], faultInjector: fault)
    }
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func refreshManifestFile(_ path: String, in directory: URL) throws {
    let url = directory.appendingPathComponent("manifest.json")
    let manifest = try SessionCodec.decode(LibraryArchiveManifest.self, from: Data(contentsOf: url))
    let file = try BackupFileIO.inspect(
        directory.appendingPathComponent(path), limit: LibraryArchiveLimits.maximumFileBytes)
    var files: [LibraryArchiveManifest.File] = []
    try LibraryArchiveFileCatalog.forEachFile(in: directory, manifest: manifest) { record in
        files.append(record.path == path ? .init(path: path, byteCount: file.byteCount, digest: file.digest) : record)
    }
    try FileManager.default.removeItem(at: directory.appendingPathComponent("Catalog"))
    let writer = try LibraryArchiveFileCatalog.Writer(directory: directory)
    for file in files { try writer.append(file) }
    let updated = LibraryArchiveManifest(formatVersion: 2, authorization: manifest.authorization,
        modules: manifest.modules, sessions: manifest.sessions, chunks: try writer.finish())
    try SessionCodec.encode(updated).write(to: url)
}
