import Foundation
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Knowledge privacy workflows", .timeLimit(.minutes(1)))
struct KnowledgePrivacyWorkflowTests {
    @Test(arguments: [KnowledgePrivacyAction.revokeRemoteUse, .deleteSource])
    func domainRecordsFollowTheSelectedPrivacyAction(_ action: KnowledgePrivacyAction) async throws {
        try await withTaskWorkflow(knowledgeEnabled: true) { f in
            let original = try #require(f.knowledge)
            let app = KnowledgeApplication(
                store: original, reader: .init(journal: f.library, payloads: f.library),
                access: f.access, scope: f.scope, now: { TaskWorkflowFixture.now })
            let originalText = "# Original\nThe original source body."
            let imported = try await app.importMarkdown(
                .init(title: "privacy.md", bytes: Data(originalText.utf8)),
                workspaceID: nil, operationID: UUID())
            let allowed = try await app.allowRemoteUse(
                imported.source.id, workspaceID: nil,
                expectedRevision: imported.source.revision, operationID: UUID())
            let detail = try await app.detail(
                imported.source.id, versionID: imported.version.id,
                scope: .init(workspaceID: nil, destination: .model(f.route)))
            let chunk = try #require(detail.chunks.first)
            let updated = try await app.importMarkdown(
                .init(title: "privacy.md", bytes: Data("# Updated\nA later source body.".utf8)),
                workspaceID: nil, updating: imported.source.id, expectedRevision: allowed.revision, operationID: UUID())

            await #expect(f.runtime.shutdown().isSettled)
            let request = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: action.namespace, revision: 1,
                scope: .sources([KnowledgeSources.metadata(updated.source)]), requestedAt: TaskWorkflowFixture.now)
            let operation = try await f.access.begin(request, expected: f.authority.authorization())
            let handler = KnowledgePrivacyHandler(action: action, knowledge: original, blobs: original)
            try await handler.apply(operation)
            try await handler.verify(operation)
            _ = try await f.access.complete(operation, at: TaskWorkflowFixture.now)

            await #expect(throws: MiraError.self) {
                _ = try await original.sourceChunk(
                    chunk.id, scope: .init(workspaceID: nil, destination: .model(f.route)))
            }
            if action == .revokeRemoteUse {
                #expect(
                    try await original.sourceChunk(
                        chunk.id, scope: .init(workspaceID: nil, destination: .local)).text == originalText)
            } else {
                await #expect(throws: MiraError.self) {
                    _ = try await original.knowledgeSource(
                        imported.source.id, versionID: nil,
                        scope: .init(workspaceID: nil, destination: .local))
                }
                #expect(
                    try ManagedBlobStore(directory: f.directory.appendingPathComponent("knowledge")).digests()
                        .isEmpty)
            }
            try await app.close()
        }
    }
}
