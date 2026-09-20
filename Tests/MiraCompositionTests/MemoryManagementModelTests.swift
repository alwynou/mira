#if DEBUG
import Foundation
import MiraCore
import Testing

@Suite("memory management model", .timeLimit(.minutes(1)))
@MainActor
struct MemoryManagementModelTests {
    @Test
    func filtersSelectsAndRefreshesSelectedDetail() async throws {
        try await withLibrary { library, directory in
            let group = try await library.workloads()
            let workspaceID = WorkspaceID()
            try await group.workspaces.save(.init(id: workspaceID, name: "Synthetic workspace"), expectedRevision: nil)
            let global = try await makeMemory(group, content: "Global preference", scope: .global)
            _ = try await makeMemory(group, content: "Workspace preference", scope: .workspace(workspaceID))

            let model = MemoryManagementModel(library: library)
            let observer = Task { @MainActor in await model.observe() }
            do {
                try await eventually { model.memories.count == 2 }
                model.scope = .workspace(workspaceID)
                try await eventually { model.memories.count == 1 && model.memories[0].id != global.id }
                let selected = try #require(model.memories.first)
                model.select(selected.id)
                try await eventually { model.detail?.memory.id == selected.id }
                model.order = .oldestFirst
                try await eventually { !model.isLoading && model.detail?.memory.id == selected.id }
                model.refresh()
                try await eventually { !model.isLoading && model.detail?.memory.id == selected.id }
                #expect(model.selectedID == selected.id)
                #expect(model.detail?.memory.scope.workspaceID == workspaceID)

                let archive = directory.deletingLastPathComponent().appendingPathComponent("MemoryManagementExport-\(UUID())")
                defer { try? FileManager.default.removeItem(at: archive) }
                let generation = await library.status().generation
                _ = try await library.exportArchive(to: archive)
                try await eventually {
                    await library.status().generation > generation && model.detail?.memory.id == selected.id
                }
                #expect(model.detail?.memory.id == selected.id)
                observer.cancel(); await observer.value
                #expect(model.detail == nil && model.memories.isEmpty)
            } catch {
                observer.cancel(); await observer.value
                throw error
            }
        }
    }

    @Test
    func staleStateActionReportsConflictAndKeepsAuthoritativeRevision() async throws {
        try await withLibrary { library, _ in
            let group = try await library.workloads()
            let original = try await makeMemory(group, content: "Keep this preference", scope: .global)
            let model = MemoryManagementModel(library: library)
            let observer = Task { @MainActor in await model.observe() }
            do {
                try await eventually { model.memories.contains(where: { $0.id == original.id }) }
                let stale = try #require(model.memories.first { $0.id == original.id })
                _ = try await group.memories.reviseMemory(
                    original.id, workspaceID: nil,
                    draft: .init(content: "A concurrent revision", scope: .global),
                    expectedRevision: original.revision, operationID: UUID())
                model.changeState(stale, to: .archived)
                await model.waitForAction()
                #expect(model.error?.code == .conflict)
                let detail = try await group.memories.detail(original.id, workspaceID: nil)
                #expect(detail.memory.revision == original.revision + 1)
                #expect(detail.memory.draft?.content == "A concurrent revision")
                observer.cancel(); await observer.value
            } catch {
                observer.cancel(); await observer.value
                throw error
            }
        }
    }

    @Test
    func replacementDetailsLoadBothEndpointsAndRelatedSelectionEscapesListFilter() async throws {
        try await withLibrary { library, _ in
            let group = try await library.workloads()
            let workspaceID = WorkspaceID()
            try await group.workspaces.save(.init(id: workspaceID, name: "Replacement workspace"), expectedRevision: nil)
            let previous = try await makeMemory(group, content: "Previous workspace preference", scope: .workspace(workspaceID))
            let candidate = try await group.memories.createMemory(
                draft: .init(content: "Current workspace preference", scope: .workspace(workspaceID), allowsRemoteUse: false),
                source: .manualEntry(id: UUID(), statement: "Current workspace preference"),
                operationID: UUID(), replacing: previous.id, expectedRevision: previous.revision).memory

            let model = MemoryManagementModel(library: library)
            let observer = Task { @MainActor in await model.observe() }
            do {
                try await eventually { model.memories.contains(where: { $0.id == candidate.id }) }
                model.scope = .global
                try await eventually { !model.isLoading && model.memories.isEmpty }
                model.section = .history
                model.scope = .workspace(workspaceID)
                try await eventually { model.memories.contains(where: { $0.id == previous.id }) }
                model.select(previous.id)
                try await eventually {
                    model.detail?.memory.id == previous.id && model.relatedMemories[candidate.id]?.id == candidate.id
                }
                let related = try #require(model.relatedMemories[candidate.id])
                model.selectRelated(related)
                try await eventually {
                    model.detail?.memory.id == candidate.id && model.relatedMemories[previous.id]?.id == previous.id
                }
                #expect(model.selectedID == candidate.id)
                #expect(model.memories.allSatisfy { $0.id != candidate.id })
                observer.cancel(); await observer.value
            } catch {
                observer.cancel(); await observer.value
                throw error
            }
        }
    }

    @Test
    func competingReplacementResolvesCurrentSuccessorAndForgetNeverRevivesIt() async throws {
        try await withLibrary { library, _ in
            let group = try await library.workloads()
            let original = try await makeMemory(group, content: "Original preference", scope: .global)
            func replace(_ content: String, revision: Int) async throws -> MemoryWriteReceipt {
                try await group.memories.createMemory(
                    draft: .init(content: content, scope: .global, allowsRemoteUse: false),
                    source: .manualEntry(id: UUID(), statement: content), operationID: UUID(),
                    replacing: original.id, expectedRevision: revision)
            }
            let winner = try await replace("First replacement", revision: original.revision).memory
            let proposal = try await replace("Competing replacement", revision: original.revision + 1)
            #expect(proposal.disposition == .replacementProposed)
            let model = MemoryManagementModel(library: library)
            model.section = .history
            let observer = Task { @MainActor in await model.observe() }
            do {
                try await eventually { model.memories.contains { $0.id == proposal.memory.id } }
                model.select(proposal.memory.id)
                try await eventually { model.relatedMemories[winner.id]?.isCurrent == true }
                let current = try #require(model.relatedMemories[winner.id])
                let candidate = try #require(model.detail?.memory)
                model.confirmReplacement(candidate: candidate, current: current)
                await model.waitForAction()
                #expect(model.error == nil)
                let confirmed = try await group.memories.detail(candidate.id, workspaceID: nil).memory
                #expect(confirmed.isCurrent)
                model.forget(confirmed)
                await model.waitForAction()
                let rebound = try await library.workloads()
                #expect(try await rebound.memories.managementPage(.init()).memories.isEmpty)
                observer.cancel(); await observer.value
            } catch {
                observer.cancel(); await observer.value
                throw error
            }
        }
    }

    @Test
    func forgetCreatesBodyFreeTombstoneWithoutRestoringOldBody() async throws {
        try await withLibrary { library, _ in
            let group = try await library.workloads()
            let original = try await makeMemory(group, content: "Forget this private preference", scope: .global)
            let model = MemoryManagementModel(library: library)
            let observer = Task { @MainActor in await model.observe() }
            do {
                try await eventually { model.memories.contains(where: { $0.id == original.id }) }
                let visible = try #require(model.memories.first { $0.id == original.id })
                model.select(visible.id)
                try await eventually { model.detail?.memory.id == visible.id }
                model.forget(visible)
                await model.waitForAction()
                try await eventually { !model.isWorking && model.detail == nil }
                model.section = .history
                try await eventually { model.memories.contains(where: { $0.id == original.id }) }

                let rebound = try await library.workloads()
                let page = try await rebound.memories.managementPage(
                    .init(scope: .all, section: .history))
                let tombstone = try #require(page.memories.first { $0.id == original.id })
                #expect(tombstone.managementStatus(at: .now) == .forgotten)
                #expect(tombstone.draft == nil)
                #expect(tombstone.forgottenAt != nil)
                observer.cancel(); await observer.value
            } catch {
                observer.cancel(); await observer.value
                throw error
            }
        }
    }

    private func withLibrary<T: Sendable>(
        _ body: @escaping @MainActor (MacLibrary, URL) async throws -> T
    ) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mira-memory-management-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await MacLibrary.open(
            embeddings: OfflineMemoryEmbedding(), directory: directory,
            notifications: CompositionNotifications(), credentials: CompositionCredentials(), modules: { _ in [] })
        do {
            let result = try await body(library, directory)
            #expect(await library.close().isSettled)
            return result
        } catch {
            _ = await library.close()
            throw error
        }
    }

    private func makeMemory(
        _ group: MacLibraryWorkloads, content: String, scope: MemoryScope
    ) async throws -> Memory {
        let result = try await group.memories.createMemory(
            draft: .init(content: content, scope: scope, allowsRemoteUse: false),
            source: .manualEntry(id: UUID(), statement: content), operationID: UUID())
        return result.memory
    }

    private func eventually(
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                throw MiraError(.timeout, "The memory management condition was not reached.")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
#endif
