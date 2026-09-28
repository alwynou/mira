#if DEBUG
import Foundation
import MiraCore
import MiraProviders
import Testing

@Suite("macOS task management fixture")
struct MacTaskManagementFixtureTests {
    @Test func fixtureSeedsStatusesAndProposal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-task-management-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: DemoLocalNotifications(), credentials: CompositionCredentials(), modules: { registry in
            [MacDemoModule(registry: registry, verifyTaskManagement: true)]
        })
        do {
            let group = try await library.workloads()
            try await MacDemoModule.seed(in: group, verifyTaskManagement: true)
            try await MacTaskManagementFixture.seed(in: group)
            let execution = try await group.application.sessionSnapshot(id: ConversationID(UUID(uuidString: "0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E321")!))
            #expect(execution.executions[ExecutionID(UUID(uuidString: "0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E322")!)]?.completion?.status == .completed)
            let inbox = try await group.tasks.tasks(workspaceID: nil, includeCompleted: true, limit: 100)
            #expect(inbox.contains(where: { $0.status == .open }))
            #expect(inbox.contains(where: { $0.status == .cancelled }))
            let workspace = try await group.tasks.tasks(workspaceID: WorkspaceID(UUID(uuidString: "0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E301")!), includeCompleted: true, limit: 100)
            #expect(workspace.contains(where: { $0.status == .inProgress }))
            #expect(workspace.contains(where: { $0.status == .completed }))
            let proposals = try await group.tasks.proposals(workspaceID: nil)
            let proposal = try #require(proposals.first(where: { $0.state == .pending && $0.evidence.quote.contains("local task management fixture") }))
            var corrected = proposal.draft
            corrected.reminderAt = .now.addingTimeInterval(3600)
            let receipt = try await group.tasks.resolve(id: proposal.id, workspaceID: nil, accept: true, correctedDraft: corrected)
            #expect(receipt.task?.draft.title == "Review local task fixture")

            let editedID = MiraTaskID(UUID(uuidString: "0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E311")!)
            let edited = try await group.tasks.detail(id: editedID, workspaceID: nil)
            var draft = edited.draft
            draft.title = "Manual QA edit survives reopen"
            _ = try await group.tasks.save(id: edited.id, workspaceID: nil, draft: draft, status: edited.status,
                                           expectedRevision: edited.revision, operationID: UUID())
            try await MacTaskManagementFixture.seed(in: group)
            #expect(try await group.tasks.detail(id: editedID, workspaceID: nil).draft.title == "Manual QA edit survives reopen")
            #expect(try await group.tasks.proposals(workspaceID: nil).isEmpty)
        } catch {
            _ = await library.close()
            throw error
        }
        _ = await library.close()
    }
}
#endif
