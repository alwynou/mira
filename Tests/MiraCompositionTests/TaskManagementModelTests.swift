#if DEBUG
import Foundation
import MiraCore
import Testing

@Suite("task management model", .timeLimit(.minutes(2)))
@MainActor
struct TaskManagementModelTests {
    @Test
    func observesGenerationAndAppliesScopeSearchAndStatusFilters() async throws {
        try await withLibrary { library, _ in
            let group = try await library.workloads()
            let workspace = Workspace(id: WorkspaceID(), name: "Tasks test workspace")
            try await group.workspaces.save(workspace, expectedRevision: nil)
            _ = try await group.tasks.save(id: .init(), workspaceID: nil, draft: .init(title: "Inbox alpha"), status: .open, expectedRevision: nil, operationID: UUID())
            let beta = try await group.tasks.save(id: .init(), workspaceID: workspace.id, draft: .init(title: "Workspace beta"), status: .open, expectedRevision: nil, operationID: UUID())
            _ = try await group.tasks.save(id: beta.id, workspaceID: workspace.id, draft: beta.draft, status: .inProgress, expectedRevision: beta.revision, operationID: UUID())
            let done = try await group.tasks.save(id: .init(), workspaceID: workspace.id, draft: .init(title: "Workspace done"), status: .open, expectedRevision: nil, operationID: UUID())
            _ = try await group.tasks.save(id: done.id, workspaceID: workspace.id, draft: done.draft, status: .completed, expectedRevision: done.revision, operationID: UUID())
            let model = TaskManagementModel(library: library)
            let observer = Task { @MainActor in await model.observe() }
            defer { observer.cancel() }
            try await eventually { model.items.count == 1 && model.generation != nil }
            model.workspaceID = workspace.id
            try await eventually { model.items.count == 1 && model.items[0].draft.title == "Workspace beta" }
            model.status = .completed
            try await eventually { model.items.count == 1 && model.items[0].draft.title == "Workspace done" }
            model.status = .all; model.searchText = "beta"
            try await eventually { model.items.count == 1 && model.items[0].draft.title == "Workspace beta" }
            model.workspaceID = nil
            try await eventually { model.items.isEmpty }
            observer.cancel(); await observer.value
        }
    }

    @Test
    func createEditConflictPreservesDraftAndReloadIsExplicit() async throws {
        try await withLibrary { library, _ in
            let group = try await library.workloads(); let model = TaskManagementModel(library: library)
            let observer = Task { @MainActor in await model.observe() }; defer { observer.cancel() }
            try await eventually { model.generation != nil }
            model.beginCreate(); try #require(model.editor != nil); model.editor?.title = "Original task"
            model.saveEditor(); await model.waitForAction(); try await eventually { model.items.count == 1 }
            let original = try #require(model.items.first)
            model.beginEdit(original); model.editor?.title = "Typed draft survives conflict"
            _ = try await group.tasks.save(id: original.id, workspaceID: nil, draft: .init(title: "External update"), status: .open, expectedRevision: original.revision, operationID: UUID())
            model.saveEditor(); await model.waitForAction()
            #expect(model.editor?.error?.code == .conflict); #expect(model.editor?.title == "Typed draft survives conflict")
            model.reloadEditor(); try await eventually { model.editor?.title == "External update" }
            model.editor?.title = "Final update"; model.saveEditor(); await model.waitForAction()
            try await eventually { model.items.first?.draft.title == "Final update" }; observer.cancel(); await observer.value
        }
    }

    @Test
    func statusTransitionsAndReminderValidationFollowTaskLifecycle() async throws {
        try await withLibrary { library, _ in
            let group = try await library.workloads()
            let saved = try await group.tasks.save(id: .init(), workspaceID: nil, draft: .init(title: "Lifecycle task"), status: .open, expectedRevision: nil, operationID: UUID())
            let model = TaskManagementModel(library: library); let observer = Task { @MainActor in await model.observe() }; defer { observer.cancel() }
            try await eventually { model.items.contains(where: { $0.id == saved.id }) }
            let task = try #require(model.items.first(where: { $0.id == saved.id })); model.status = .all; model.changeStatus(task, to: .completed); await model.waitForAction()
            try await eventually { model.items.first(where: { $0.id == saved.id })?.status == .completed }
            let completed = try #require(model.items.first(where: { $0.id == saved.id })); model.changeStatus(completed, to: .open); await model.waitForAction()
            try await eventually { model.items.first(where: { $0.id == saved.id })?.status == .open }
            model.beginEdit(try #require(model.items.first(where: { $0.id == saved.id }))); model.editor?.includesReminder = true; model.editor?.reminderAt = .now.addingTimeInterval(-1)
            #expect(model.editor?.canSave == false); model.editor?.reminderAt = .now.addingTimeInterval(3600); #expect(model.editor?.canSave == true); observer.cancel(); await observer.value
        }
    }

    @Test
    func acceptedSaveSurvivesNavigationAndMaintenanceClearsEditingSnapshot() async throws {
        try await withLibrary { library, _ in
            let model = TaskManagementModel(library: library)
            let observer = Task { @MainActor in await model.observe() }
            do {
                try await eventually { model.generation != nil && !model.isLoading }
                model.beginCreate()
                model.editor?.title = "Save while leaving Tasks"
                model.saveEditor()
                observer.cancel()
                await observer.value
                await model.waitForAction()
                let group = try await library.workloads()
                let saved = try #require(try await group.tasks.managementPage(.init()).items.first)
                #expect(saved.draft.title == "Save while leaving Tasks")
                #expect(model.generation == nil)
                #expect(model.items.isEmpty)
                let reopened = Task { @MainActor in await model.observe() }
                do {
                    try await eventually { model.items.contains { $0.id == saved.id } }
                    model.beginEdit(saved)
                    model.editor?.title = "Revocable unsaved draft"
                    let previous = try #require(model.generation)
                    _ = try await library.maintain(.init(id: UUID(), namespace: "knowledge.collect", revision: 1,
                                                        scope: .library, requestedAt: Date()))
                    try await eventually { model.generation != nil && model.generation != previous && !model.isLoading }
                    #expect(model.editor == nil)
                    #expect(model.items.first?.draft.title == saved.draft.title)
                    reopened.cancel(); await reopened.value
                } catch {
                    reopened.cancel(); await reopened.value
                    throw error
                }
            } catch {
                observer.cancel(); await observer.value
                throw error
            }
        }
    }

    private func withLibrary<T: Sendable>(_ body: @escaping @MainActor (MacLibrary, URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-task-management-\(UUID())", isDirectory: true); defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: CompositionNotifications(), credentials: CompositionCredentials(), modules: { _ in [] })
        do { let result = try await body(library, directory); #expect(await library.close().isSettled); return result } catch { _ = await library.close(); throw error }
    }
    private func eventually(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()) { guard ContinuousClock.now < deadline else { throw MiraError(.timeout, "Task management condition was not reached.") }; try await Task.sleep(for: .milliseconds(10)) }
    }
}
#endif
