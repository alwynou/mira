#if DEBUG
import Foundation
import MiraCore
import Testing

@Suite("knowledge management model", .timeLimit(.minutes(1)))
@MainActor
struct KnowledgeManagementModelTests {
    @Test
    func listsSelectsCurrentAndHistoricalVersionsAndPagesMatchingDocument() async throws {
        try await withLibrary { library, directory in
            let group = try await library.workloads()
            let workspaceID = WorkspaceID()
            try await group.workspaces.save(.init(id: workspaceID, name: "Synthetic knowledge workspace"), expectedRevision: nil)
            let body = (1...400).map {
                "## Section \($0)\n" + String(repeating: "Synthetic knowledge line \($0) ", count: 40) + "\n"
            }.joined()
            let first = try await group.knowledge.importMarkdown(
                .init(title: "existing-notes.md", bytes: Data(body.utf8)),
                workspaceID: workspaceID, operationID: UUID())
            let secondBody = body + "\n## Current\nCurrent source text."
            let second = try await group.knowledge.importMarkdown(
                .init(title: "renamed-by-user.md", bytes: Data(secondBody.utf8)),
                workspaceID: workspaceID, updating: first.source.id,
                expectedRevision: first.source.revision,
                operationID: UUID())

            let model = KnowledgeManagementModel(library: library)
            let observer = Task { @MainActor in await model.observe() }
            do {
                try await eventually { model.items.count == 1 && model.items[0].source.title == "existing-notes.md" }
                let item = try #require(model.items.first)
                #expect(item.currentVersion?.id == second.version.id)
                #expect(item.latestVersion?.id == second.version.id)
                #expect(item.versionCount == 2)
                #expect(item.source.workspaceID == workspaceID)

                model.searchText = "Current source text"
                try await eventually { model.items.count == 1 && model.items[0].match != nil }
                #expect(model.items[0].match?.sourceVersionID == second.version.id)
                model.select(item.id)
                try await eventually { model.detail?.source.id == item.id && model.document != nil && model.selectedMatch != nil }
                #expect(model.selectedMatch?.sourceVersionID == second.version.id)
                #expect(model.detail?.selectedVersion?.id == second.version.id)

                model.selectVersion(first.version.id)
                try await eventually {
                    model.detail?.selectedVersion?.id == first.version.id && model.document?.version.id == first.version.id
                }
                let firstPage = try #require(model.document)
                #expect(firstPage.chunks.first?.text.contains("Section 1") == true)
                #expect(firstPage.nextSequence != nil)
                model.nextDocumentPage()
                try await eventually {
                    model.document != nil && !model.isLoadingDocument
                        && model.document?.chunks.first?.summary.sequence != firstPage.chunks.first?.summary.sequence
                }
                model.previousDocumentPage()
                try await eventually {
                    model.document != nil && !model.isLoadingDocument
                        && model.document?.chunks.first?.summary.sequence == firstPage.chunks.first?.summary.sequence
                }

                model.scope = .workspace(workspaceID)
                try await eventually { model.items.count == 1 }
                model.scope = .inbox
                try await eventually { model.items.isEmpty }
                observer.cancel(); await observer.value
            } catch {
                observer.cancel(); await observer.value
                throw error
            }
        }
    }

    @Test
    func multiFileImportDefaultsToLocalAndDuplicateDoesNotChangePermission() async throws {
        try await withLibrary { library, directory in
            let group = try await library.workloads()
            let sourceURL = directory.appendingPathComponent("privacy.md")
            let duplicateURL = directory.appendingPathComponent("privacy-copy.md")
            let secondURL = directory.appendingPathComponent("second.md")
            try Data("Private source body".utf8).write(to: sourceURL)
            try Data("Private source body".utf8).write(to: duplicateURL)
            try Data("Second private source body".utf8).write(to: secondURL)

            let model = KnowledgeManagementModel(library: library)
            let observer = Task { @MainActor in await model.observe() }
            do {
                try await eventually { model.generation != nil }
                model.prepareImport(urls: [sourceURL, secondURL])
                #expect(model.showsImport)
                #expect(model.importAllowsRemoteUse == false)
                model.startImport()
                await model.waitForAction()
                try await eventually { model.importResults.count == 2 && !model.isWorking }

                #expect(model.importResults.allSatisfy { $0.state == .imported })
                model.prepareImport(urls: [duplicateURL])
                model.importAllowsRemoteUse = true
                model.startImport()
                await model.waitForAction()
                try await eventually { model.importResults.count == 1 && !model.isWorking }
                let duplicate = try #require(model.importResults.first)
                #expect(duplicate.state == .reused)
                #expect(duplicate.permissionUnchanged)
                let sources = try await group.knowledge.list(scope: .init(workspaceID: nil, destination: .local), limit: 20)
                #expect(sources.count == 2)
                #expect(sources.allSatisfy { $0.allowsRemoteUse == false })
                try await eventually { model.items.count == 2 }
                observer.cancel(); await observer.value
            } catch {
                observer.cancel(); await observer.value
                throw error
            }
        }
    }

    @Test
    func failedUpdateRetainsCurrentVersionAndReportsFailedVersion() async throws {
        try await withLibrary { library, directory in
            let group = try await library.workloads()
            let initial = try await group.knowledge.importMarkdown(
                .init(title: "stable.md", bytes: Data("Stable current body".utf8)),
                workspaceID: nil, operationID: UUID())
            let invalidURL = directory.appendingPathComponent("broken.md")
            try Data([0xff, 0xfe, 0xfd]).write(to: invalidURL)

            let model = KnowledgeManagementModel(library: library)
            let observer = Task { @MainActor in await model.observe() }
            do {
                try await eventually { model.items.contains { $0.id == initial.source.id } }
                model.select(initial.source.id)
                try await eventually { model.detail?.source.id == initial.source.id }
                model.prepareImport(urls: [invalidURL], updating: initial.source)
                model.startImport()
                await model.waitForAction()
                try await eventually {
                    guard let item = model.items.first(where: { $0.id == initial.source.id }) else { return false }
                    return item.currentVersion?.id == initial.version.id && item.latestVersion?.parseState == .failed
                        && item.versionCount == 2 && model.importResults.count == 1 && !model.isWorking
                }
                model.status = .needsAttention
                try await eventually { model.items.count == 1 && model.items[0].id == initial.source.id }
                let outcome = try #require(model.importResults.first)
                #expect(outcome.state == .imported)
                #expect(outcome.error?.code == .invalidInput)
                #expect(outcome.versionFailed)
                let detail = try await group.knowledge.detail(initial.source.id, scope: .init(workspaceID: nil, destination: .local))
                #expect(detail.source.currentVersionID == initial.version.id)
                #expect(detail.versions.contains { $0.parseState == .failed })
                observer.cancel(); await observer.value
            } catch {
                observer.cancel(); await observer.value
                throw error
            }
        }
    }

    @Test
    func staleAllowReportsConflictAndLeavesAuthoritativePermission() async throws {
        try await withLibrary { library, _ in
            let group = try await library.workloads()
            let receipt = try await group.knowledge.importMarkdown(
                .init(title: "allow.md", bytes: Data("Allow me later".utf8)),
                workspaceID: nil, operationID: UUID())
            let model = KnowledgeManagementModel(library: library)
            let observer = Task { @MainActor in await model.observe() }
            do {
                try await eventually { model.items.contains { $0.id == receipt.source.id } }
                let stale = try #require(model.items.first { $0.id == receipt.source.id })
                _ = try await group.knowledge.allowRemoteUse(
                    receipt.source.id, workspaceID: nil, expectedRevision: stale.source.revision, operationID: UUID())
                model.allow(stale.source)
                await model.waitForAction()
                #expect(model.error?.code == .conflict)
                let authoritative = try await group.knowledge.detail(
                    receipt.source.id, scope: .init(workspaceID: nil, destination: .local))
                #expect(authoritative.source.allowsRemoteUse)
                #expect(authoritative.source.revision == stale.source.revision + 1)
                observer.cancel(); await observer.value
            } catch {
                observer.cancel(); await observer.value
                throw error
            }
        }
    }

    @Test
    func revokeClearsCachedDocumentAndRebindsTheSourceAsLocalOnly() async throws {
        try await withLibrary { library, _ in
            let group = try await library.workloads()
            let receipt = try await group.knowledge.importMarkdown(
                .init(title: "revoke.md", bytes: Data("Cached private document".utf8)),
                workspaceID: nil, operationID: UUID())
            let allowed = try await group.knowledge.allowRemoteUse(
                receipt.source.id, workspaceID: nil, expectedRevision: receipt.source.revision, operationID: UUID())
            let model = KnowledgeManagementModel(library: library)
            let observer = Task { @MainActor in await model.observe() }
            do {
                try await eventually { model.items.contains { $0.id == allowed.id && $0.source.allowsRemoteUse } }
                model.select(allowed.id)
                try await eventually { model.document != nil }
                let previousGeneration = try #require(model.generation)
                model.revoke(allowed)
                await model.waitForAction()
                #expect(model.error == nil)
                try await eventually {
                    model.generation != nil && model.generation != previousGeneration
                        && model.items.first(where: { $0.id == allowed.id })?.source.allowsRemoteUse == false
                        && model.detail?.source.id == allowed.id
                        && model.detail?.source.allowsRemoteUse == false
                        && model.document != nil && !model.isLoadingDocument
                }
                let rebound = try await library.workloads()
                let local = try await rebound.knowledge.detail(
                    allowed.id, scope: .init(workspaceID: nil, destination: .local))
                #expect(local.source.deletedAt == nil)
                #expect(local.source.currentVersionID == receipt.version.id)
                observer.cancel(); await observer.value
            } catch {
                observer.cancel(); await observer.value
                throw error
            }
        }
    }

    @Test
    func deleteRemovesAllSourceVersionsAndClearsSelection() async throws {
        try await withLibrary { library, _ in
            let group = try await library.workloads()
            let first = try await group.knowledge.importMarkdown(
                .init(title: "delete.md", bytes: Data("First".utf8)), workspaceID: nil, operationID: UUID())
            let updated = try await group.knowledge.importMarkdown(
                .init(title: "ignored-on-update.md", bytes: Data("Second".utf8)), workspaceID: nil,
                updating: first.source.id, expectedRevision: first.source.revision, operationID: UUID())
            let model = KnowledgeManagementModel(library: library)
            let observer = Task { @MainActor in await model.observe() }
            do {
                try await eventually { model.items.contains { $0.id == first.source.id } }
                model.select(first.source.id)
                try await eventually { model.detail?.source.id == first.source.id }
                let source = try #require(model.detail?.source)
                #expect(source.revision == updated.source.revision)
                let previousGeneration = try #require(model.generation)
                model.delete(source)
                await model.waitForAction()
                #expect(model.error == nil)
                try await eventually {
                    model.generation != nil && model.generation != previousGeneration
                        && model.items.isEmpty && model.selectedID == nil && model.detail == nil && model.document == nil
                }
                let rebound = try await library.workloads()
                #expect(try await rebound.knowledge.list(
                    scope: .init(workspaceID: nil, destination: .local), limit: 20).isEmpty)
                observer.cancel(); await observer.value
            } catch {
                observer.cancel(); await observer.value
                throw error
            }
        }
    }

    @Test
    func cancellingObservationClearsStaleContentAndReobservationReloadsIt() async throws {
        try await withLibrary { library, _ in
            let group = try await library.workloads()
            let receipt = try await group.knowledge.importMarkdown(
                .init(title: "reobserve.md", bytes: Data("Reobserve this source".utf8)),
                workspaceID: nil, operationID: UUID())
            let model = KnowledgeManagementModel(library: library)
            let firstObserver = Task { @MainActor in await model.observe() }
            try await eventually { model.items.contains { $0.id == receipt.source.id } }
            model.select(receipt.source.id)
            try await eventually { model.detail?.source.id == receipt.source.id }
            firstObserver.cancel(); await firstObserver.value
            #expect(model.items.isEmpty)
            #expect(model.detail == nil)
            #expect(model.document == nil)

            let secondObserver = Task { @MainActor in await model.observe() }
            do {
                try await eventually { model.items.contains { $0.id == receipt.source.id } }
                #expect(model.selectedID == receipt.source.id)
                secondObserver.cancel(); await secondObserver.value
            } catch {
                secondObserver.cancel(); await secondObserver.value
                throw error
            }
        }
    }

    @Test
    func mixedImportReportsUnsupportedFileWithoutAbortingFollowingFiles() async throws {
        try await withLibrary { library, directory in
            let group = try await library.workloads()
            let goodURL = directory.appendingPathComponent("accepted.md")
            let unsupportedURL = directory.appendingPathComponent("ignored.txt")
            try Data("Accepted Markdown".utf8).write(to: goodURL)
            try Data("This extension is not accepted by the Markdown reader.".utf8).write(to: unsupportedURL)

            let model = KnowledgeManagementModel(library: library)
            let observer = Task { @MainActor in await model.observe() }
            do {
                try await eventually { model.generation != nil }
                model.prepareImport(urls: [goodURL, unsupportedURL])
                model.startImport()
                await model.waitForAction()
                try await eventually { model.importResults.count == 2 && !model.isWorking }

                let accepted = try #require(model.importResults.first { $0.filename == goodURL.lastPathComponent })
                let rejected = try #require(model.importResults.first { $0.filename == unsupportedURL.lastPathComponent })
                #expect(accepted.state == .imported)
                #expect(accepted.error == nil)
                #expect(rejected.state == .failed)
                #expect(rejected.error != nil)
                let sources = try await group.knowledge.list(scope: .init(workspaceID: nil, destination: .local), limit: 20)
                #expect(sources.count == 1)
                #expect(sources[0].title == goodURL.lastPathComponent)
                observer.cancel(); await observer.value
            } catch {
                observer.cancel(); await observer.value
                throw error
            }
        }
    }

    @Test
    func cancellingImportBeforeFirstAdmissionLeavesNoSourceOrOutcome() async throws {
        try await withLibrary { library, directory in
            let group = try await library.workloads()
            let fileURL = directory.appendingPathComponent("cancelled.md")
            try Data("This import is cancelled before admission.".utf8).write(to: fileURL)
            let model = KnowledgeManagementModel(library: library)
            let observer = Task { @MainActor in await model.observe() }
            do {
                try await eventually { model.generation != nil }
                model.prepareImport(urls: [fileURL])
                model.startImport()
                model.cancelImport()
                await model.waitForAction()
                #expect(model.importResults.isEmpty)
                #expect(!model.isWorking)
                let sources = try await group.knowledge.list(scope: .init(workspaceID: nil, destination: .local), limit: 20)
                #expect(sources.isEmpty)
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
            .appendingPathComponent("mira-knowledge-management-\(UUID().uuidString)", isDirectory: true)
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

    private func eventually(
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                throw MiraError(.timeout, "The knowledge management condition was not reached.")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
#endif
