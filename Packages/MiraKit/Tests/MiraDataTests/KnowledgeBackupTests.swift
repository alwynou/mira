import Foundation
import MiraCore
import Testing
@testable import MiraData

@Suite("Knowledge library backups")
struct KnowledgeBackupTests {
    @Test func bundleRoundTripPreservesMixedScopesAndHistoricalCitation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let workspace = Workspace(id: .init(), name: "Notes")
        try fixture.store.saveWorkspace(workspace, expectedRevision: nil)
        let global = try fixture.importFile("# Global\n\nOriginal global fact.\n", workspaceID: nil)
        let scoped = try fixture.importFile("# Private\n\nWorkspace fact.\n", workspaceID: workspace.id)
        let oldContent = try fixture.importFile("# Global\n\nRevised global fact.\n", workspaceID: nil, updating: global.source.id, expectedRevision: global.source.revision)
        #expect(oldContent.version.id != global.version.id)

        let backup = fixture.root.appendingPathComponent("library.bundle")
        try fixture.store.exportBackup(to: backup)
        #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("Mira.sqlite").path))
        #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("Blobs").path))

        let restoredDirectory = fixture.root.appendingPathComponent("restored")
        try fixture.store.restoreBackup(from: backup, to: restoredDirectory)
        let restored = try SQLiteMiraStore(directory: restoredDirectory)
        let restoredGlobal = try restored.knowledgeSource(global.source.id, versionID: global.version.id, workspaceID: nil, connectionID: nil)
        #expect(restoredGlobal.selectedVersion?.id == global.version.id)
        #expect(restoredGlobal.chunks.isEmpty == false)
        let summary = try #require(restoredGlobal.chunks.first)
        #expect(SourceCitationReference.references(in: summary.citation).first?.versionID == global.version.id)
        let oldChunk = try restored.sourceChunk(summary.id, workspaceID: nil, connectionID: nil)
        #expect(oldChunk.text.contains("Original global fact"))
        #expect(try restored.knowledgeSource(scoped.source.id, versionID: scoped.version.id, workspaceID: workspace.id, connectionID: nil).source.workspaceID == workspace.id)
    }

    @Test func restoreRejectsMissingBlobAndLeavesDestinationAbsent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.importFile("# Source\n\nA backed up fact.\n", workspaceID: nil)
        let backup = fixture.root.appendingPathComponent("missing.bundle")
        try fixture.store.exportBackup(to: backup)
        let manifestDigest = try fixture.firstManifestDigest(at: backup)
        let digest = try #require(manifestDigest)
        try FileManager.default.removeItem(at: fixture.blobPath(digest, in: backup))

        let destination = fixture.root.appendingPathComponent("missing-restored")
        #expect(throws: MiraError.self) { try fixture.store.restoreBackup(from: backup, to: destination) }
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test func restoreRejectsBlobDigestTamperingAndPathSymlinks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.importFile("# Source\n\nA backed up fact.\n", workspaceID: nil)
        let backup = fixture.root.appendingPathComponent("tampered.bundle")
        try fixture.store.exportBackup(to: backup)
        let manifestDigest = try fixture.firstManifestDigest(at: backup)
        let digest = try #require(manifestDigest)
        try Data("tampered".utf8).write(to: fixture.blobPath(digest, in: backup))
        #expect(throws: MiraError.self) { try fixture.store.restoreBackup(from: backup, to: fixture.root.appendingPathComponent("tampered-restored")) }

        let symlinkBundle = fixture.root.appendingPathComponent("symlink.bundle")
        try fixture.store.exportBackup(to: symlinkBundle)
        let database = symlinkBundle.appendingPathComponent("Mira.sqlite")
        try FileManager.default.removeItem(at: database)
        try FileManager.default.createSymbolicLink(at: database, withDestinationURL: fixture.store.libraryDirectory.appendingPathComponent("Mira.sqlite"))
        #expect(throws: MiraError.self) { try fixture.store.restoreBackup(from: symlinkBundle, to: fixture.root.appendingPathComponent("symlink-restored")) }
    }

    @Test func restoreRejectsMalformedManifest() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let backup = fixture.root.appendingPathComponent("manifest.bundle")
        try fixture.store.exportBackup(to: backup)
        try Data("{}".utf8).write(to: backup.appendingPathComponent("manifest.json"), options: .atomic)
        #expect(throws: MiraError.self) { try fixture.store.restoreBackup(from: backup, to: fixture.root.appendingPathComponent("manifest-restored")) }
    }

    @Test func exportAndRestoreRefuseOverwritingExistingDirectories() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let backup = fixture.root.appendingPathComponent("existing.bundle")
        try fixture.store.exportBackup(to: backup)
        #expect(throws: MiraError.self) { try fixture.store.exportBackup(to: backup) }
        let destination = fixture.root.appendingPathComponent("existing-destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        #expect(throws: MiraError.self) { try fixture.store.restoreBackup(from: backup, to: destination) }
    }

    @Test(arguments: [LibraryBackupFaultStage.afterDatabaseSnapshot, .beforeExportInstall])
    func exportFaultsLeaveNoPartialBundle(_ stage: LibraryBackupFaultStage) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.importFile("# Source\n\nA backed up fact.\n", workspaceID: nil)
        let baseline = fixture.root.appendingPathComponent("baseline.bundle")
        try fixture.store.exportBackup(to: baseline)
        let baselineManifest = try Data(contentsOf: baseline.appendingPathComponent("manifest.json"))
        let baselineDatabase = try Data(contentsOf: testBackupDatabaseURL(baseline))
        let destination = fixture.root.appendingPathComponent("fault-\(stage)")
        fixture.store.installLibraryBackupFaultInjector { current in
            if current == stage { throw MiraError(.storage, "Synthetic backup failure.") }
        }
        defer { fixture.store.installLibraryBackupFaultInjector(nil) }
        #expect(throws: MiraError.self) { try fixture.store.exportBackup(to: destination) }
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        #expect(try Data(contentsOf: baseline.appendingPathComponent("manifest.json")) == baselineManifest)
        #expect(try Data(contentsOf: testBackupDatabaseURL(baseline)) == baselineDatabase)
        #expect(try fixture.store.knowledgeSources(workspaceID: nil, limit: 10).count == 1)
    }

    @Test(arguments: [LibraryBackupFaultStage.afterRestoreValidation, .beforeRestoreInstall])
    func restoreFaultsLeaveSourceAndDestinationUntouched(_ stage: LibraryBackupFaultStage) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.importFile("# Source\n\nA backed up fact.\n", workspaceID: nil)
        let backup = fixture.root.appendingPathComponent("fault-source.bundle")
        try fixture.store.exportBackup(to: backup)
        let before = try Data(contentsOf: testBackupDatabaseURL(backup))
        let destination = fixture.root.appendingPathComponent("fault-restored-\(stage)")
        fixture.store.installLibraryBackupFaultInjector { current in
            if current == stage { throw MiraError(.storage, "Synthetic restore failure.") }
        }
        defer { fixture.store.installLibraryBackupFaultInjector(nil) }
        #expect(throws: MiraError.self) { try fixture.store.restoreBackup(from: backup, to: destination) }
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        #expect(try Data(contentsOf: testBackupDatabaseURL(backup)) == before)
    }

    private struct Fixture {
        let root: URL
        let store: SQLiteMiraStore
        private let sourceFile: URL

        init() throws {
            root = URL(fileURLWithPath: "/Users/alwyn/dev/mira", isDirectory: true).appendingPathComponent(".mira-knowledge-backup-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let library = root.appendingPathComponent("library")
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            store = try SQLiteMiraStore(directory: library)
            sourceFile = root.appendingPathComponent("source.md")
        }

        func importFile(_ text: String, workspaceID: WorkspaceID?, updating: KnowledgeSourceID? = nil, expectedRevision: Int? = nil) throws -> KnowledgeImportReceipt {
            try Data(text.utf8).write(to: sourceFile, options: .atomic)
            return try store.importMarkdownFile(sourceFile, workspaceID: workspaceID, updating: updating, expectedRevision: expectedRevision, at: Date(timeIntervalSince1970: 2_000_000 + Double(UUID().uuidString.hashValue & 0xFFFF)))
        }

        func firstManifestDigest(at bundle: URL) throws -> String? {
            let data = try Data(contentsOf: bundle.appendingPathComponent("manifest.json"))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let blobs = try #require(object["blobs"] as? [[String: Any]])
            return blobs.first?["digest"] as? String
        }

        func blobPath(_ digest: String, in bundle: URL) -> URL {
            bundle.appendingPathComponent("Blobs").appendingPathComponent(String(digest.prefix(2))).appendingPathComponent(String(digest.dropFirst(2).prefix(2))).appendingPathComponent(digest)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
