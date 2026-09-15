import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("SQLite domain library archives", .timeLimit(.minutes(2)))
struct SQLiteDomainLibraryArchiveTests {
    @Test
    func exportsInitializedDomainSchemasAndKnowledgeAttachments() async throws {
        try await withTaskWorkflow(
            outputs: [[.blockStarted(.init(id: "text", content: .text("Archive source"))), .blockFinished(id: "text"), .finished(.stop)]],
            memoryEnabled: true,
            knowledgeEnabled: true
        ) { fixture in
            let memory = try #require(fixture.memory)
            let knowledge = try #require(fixture.knowledge)
            let authorization = try await fixture.authority.authorization()

            // Create one real journal execution so session provenance is part of the archive.
            _ = try await fixture.run("Archive source")
            _ = try await memory.createMemory(
                draft: .init(content: "A manually recorded archive fact", scope: .global),
                source: .manualEntry(id: UUID(), statement: "A manually recorded archive fact"),
                operationID: UUID(), replacing: nil, expectedRevision: nil,
                authorization: authorization, at: TaskWorkflowFixture.now)
            let imported = try await knowledge.importMarkdown(
                .init(title: "Archive guide.md", bytes: Data("# Archive guide\nAttached source body.".utf8)),
                workspaceID: nil, updating: nil, expectedRevision: nil,
                operationID: UUID(), authorization: authorization, at: TaskWorkflowFixture.now)
            #expect(imported.version.byteCount > 0)
            _ = try await fixture.tasks.save(
                id: .init(), workspaceID: nil,
                draft: .init(
                    title: "Archive reminder", notes: "Retained task reminder",
                    reminderAt: TaskWorkflowFixture.now.addingTimeInterval(3_600), timeZoneID: "UTC"),
                status: .open, expectedRevision: nil, operationID: UUID())

            let extraction = try SQLiteMemoryExtractionStore(
                database: fixture.database, libraryID: fixture.authority.libraryID)
            let privacy = try SQLiteSessionPrivacyPlanStore(
                database: fixture.database, libraryID: fixture.authority.libraryID)
            let consumerIdentity = AgentSessionConsumerIdentity(id: "archive.domain.consumer", revision: 1)
            let consumer = try SQLiteSessionConsumer(
                database: fixture.database, identity: consumerIdentity, handler: ArchiveDomainNoopHandler())

            do {
                // Stop all host-owned work before the archive opens its shared read fence.
                await fixture.model.releaseStream()
                _ = await fixture.runtime.shutdown()
                await fixture.reminders.close()
                await fixture.tasks.close()
                await fixture.scheduler.shutdown()
                await fixture.scope.dispose()
                try await fixture.business.close()
                await memory.close()
                await knowledge.close()
                await extraction.close()
                await privacy.close()
                await consumer.close()

                let modules: [SQLiteArchiveModule] = [
                    try SQLiteWorkspaceStore.archiveModule(),
                    try SQLiteAgentModelSettings.archiveModule(),
                    try SQLiteMemoryStore.archiveModule(),
                    try SQLiteMemoryExtractionStore.archiveModule(),
                    try SQLiteKnowledgeStore.archiveModule(blobDirectory: "knowledge/Blobs"),
                    try SQLiteTaskStore.archiveModule(),
                    try SQLiteBusinessEffects.archiveModule(),
                    try SQLiteSessionConsumer.archiveModule(),
                    try SQLiteSessionPrivacyPlanStore.archiveModule(),
                ]
                let exporter = try SQLiteLibraryArchiveExporter(
                    database: fixture.database, sessions: fixture.library,
                    libraryID: fixture.authority.libraryID, attachmentDirectory: fixture.directory,
                    modules: modules)
                let destination = fixture.directory.appendingPathComponent("domain-archive")
                do {
                    let manifest = try await exporter.export(to: destination, authorization: authorization)
                    let checked = try await SQLiteLibraryArchiveExporter.validate(
                        at: destination, modules: modules)
                    #expect(checked == manifest)
                    var files: [LibraryArchiveManifest.File] = []
                    try LibraryArchiveFileCatalog.forEachFile(in: destination, manifest: manifest) { files.append($0) }

                    let expectedNames = Set(modules.map(\.identity.name)).union(["library.authority"])
                    #expect(Set(manifest.modules.map(\.name)) == expectedNames)
                    #expect(files.contains { $0.path == "Business.sqlite" })
                    #expect(files.contains { $0.path.hasPrefix("Sessions/sessions/") })
                    let attachments = files.filter { $0.path.hasPrefix("knowledge/Blobs/") }
                    #expect(!attachments.isEmpty)
                    #expect(attachments.contains { $0.byteCount == imported.version.byteCount })
                    for file in attachments {
                        #expect(
                            FileManager.default.fileExists(atPath: destination.appendingPathComponent(file.path).path))
                    }
                } catch {
                    await exporter.close()
                    throw error
                }
                await exporter.close()
            } catch {
                await consumer.close()
                await privacy.close()
                await extraction.close()
                throw error
            }
        }
    }
}

private struct ArchiveDomainNoopHandler: SQLiteSessionConsumerHandler {
    func prepare(_ delivery: AgentSessionConsumerDelivery) async throws -> any SQLiteSessionConsumerTransaction {
        ArchiveDomainNoopTransaction()
    }
}

private struct ArchiveDomainNoopTransaction: SQLiteSessionConsumerTransaction {
    func apply(in db: Database) throws {}
    func close() async {}
}
