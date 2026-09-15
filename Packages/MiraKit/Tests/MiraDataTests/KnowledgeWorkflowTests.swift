import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Knowledge journal workflows", .timeLimit(.minutes(1)))
struct KnowledgeWorkflowTests {
    @Test func exactChunkToolPublishesBoundedBodyAndJournalProvenance() async throws {
        try await withTaskWorkflow(knowledgeEnabled: true) { fixture in
            let store = try #require(fixture.knowledge)
            let app = KnowledgeApplication(store: store, reader: .init(journal: fixture.library, payloads: fixture.library),
                access: fixture.access, scope: fixture.scope, now: { TaskWorkflowFixture.now })
            do {
                let text = "# Exact section\nComplete evidence body."
                let imported = try await app.importMarkdown(.init(title: "Exact.md", bytes: Data(text.utf8)),
                    workspaceID: nil, operationID: UUID())
                _ = try await app.allowRemoteUse(imported.source.id, workspaceID: nil, expectedRevision: 1, operationID: UUID())
                let summary = try #require(try await app.detail(imported.source.id, scope: .init(workspaceID: nil, destination: .local)).chunks.first)
                let arguments = try JSONValue.object(["chunk_id": .string(summary.id.rawValue.uuidString.lowercased())]).jsonString()
                await fixture.model.append([
                    modelToolStream([.init(id: "read-1", name: "source.read_chunk", arguments: arguments)]),
                    [.blockStarted(.init(id: "text", content: .text("Read the complete section."))), .blockFinished(id: "text"), .finished(.stop)]
                ])
                let address = try await fixture.run("Read the exact section")
                let evidence = try await JournalSessionReader(journal: fixture.library, payloads: fixture.library)
                    .recordedContextEvidence(sessionID: address.sessionID, executionID: address.executionID)
                #expect(evidence.sources.contains(KnowledgeSources.chunk(summary)))
                let detail = try await app.citation(.init(versionID: imported.version.id, chunkID: summary.id),
                    sessionID: address.sessionID, executionID: address.executionID, workspaceID: nil)
                #expect(detail.chunk.text == text)
                await app.close()
            } catch { await app.close(); throw error }
        }
    }
    @Test func searchReplyCitationUsesExactChunkAndOriginalRoute() async throws {
        let text = "# Guide\nMira source citation marker."
        let outputs: [[AgentModelStreamEvent]] = [
            modelToolStream([.init(id: "search-1", name: "knowledge.search", arguments: "{\"query\":\"citation marker\"}")]),
            [.blockStarted(.init(id: "text", content: .text("The guide says [source:pending]."))), .blockFinished(id: "text"), .finished(.stop)]
        ]
        try await withTaskWorkflow(outputs: outputs, knowledgeEnabled: true) { fixture in
            guard let store = fixture.knowledge else { throw MiraError(.configuration, "Knowledge fixture was not enabled.") }
            let app = KnowledgeApplication(store: store, reader: .init(journal: fixture.library, payloads: fixture.library),
                                            access: fixture.access, scope: fixture.scope, now: { TaskWorkflowFixture.now })
            do {
                let imported = try await app.importMarkdown(.init(title: "Guide.md", bytes: Data(text.utf8)), workspaceID: nil, operationID: UUID())
                _ = try await app.allowRemoteUse(imported.source.id, workspaceID: nil, expectedRevision: imported.source.revision, operationID: UUID())
                let address = try await fixture.run("Find the citation marker")
                let detail = try await app.detail(imported.source.id, versionID: imported.version.id,
                    scope: .init(workspaceID: nil, destination: .model(fixture.route)))
                let chunk = try #require(detail.chunks.first)
                let citation = try await app.citation(.init(versionID: imported.version.id, chunkID: chunk.id),
                    sessionID: address.sessionID, executionID: address.executionID, workspaceID: nil)
                #expect(citation.chunk.id == chunk.id)
                #expect(citation.version.id == imported.version.id)
                #expect(citation.source.id == imported.source.id)
                await app.close()
            } catch {
                await app.close()
                throw error
            }
        }
    }

    @Test func priorVersionCitationRemainsAvailableAfterSourceUpdate() async throws {
        let outputs: [[AgentModelStreamEvent]] = [
            modelToolStream([.init(id: "search-1", name: "knowledge.search", arguments: "{\"query\":\"old marker\"}")]),
            [.blockStarted(.init(id: "text", content: .text("Old source answer"))), .blockFinished(id: "text"), .finished(.stop)]
        ]
        try await withTaskWorkflow(outputs: outputs, knowledgeEnabled: true) { fixture in
            guard let store = fixture.knowledge else { throw MiraError(.configuration, "Knowledge fixture was not enabled.") }
            let app = KnowledgeApplication(store: store, reader: .init(journal: fixture.library, payloads: fixture.library),
                                            access: fixture.access, scope: fixture.scope, now: { TaskWorkflowFixture.now })
            do {
                let first = try await app.importMarkdown(.init(title: "Guide.md", bytes: Data("# Guide\nold marker".utf8)), workspaceID: nil, operationID: UUID())
                let allowed = try await app.allowRemoteUse(first.source.id, workspaceID: nil, expectedRevision: first.source.revision, operationID: UUID())
                let address = try await fixture.run("Find old marker")
                let before = try await app.detail(first.source.id, versionID: first.version.id,
                    scope: .init(workspaceID: nil, destination: .model(fixture.route)))
                let oldChunk = try #require(before.chunks.first)
                let updated = try await app.importMarkdown(.init(title: "Guide.md", bytes: Data("# Guide\nnew marker".utf8)),
                    workspaceID: nil, updating: first.source.id, expectedRevision: allowed.revision, operationID: UUID())
                #expect(updated.version.id != first.version.id)
                let citation = try await app.citation(.init(versionID: first.version.id, chunkID: oldChunk.id),
                    sessionID: address.sessionID, executionID: address.executionID, workspaceID: nil)
                #expect(citation.version.id == first.version.id)
                await app.close()
            } catch {
                await app.close()
                throw error
            }
        }
    }

    @Test func metadataOnlySourceOpenCannotAuthorizeChunkCitation() async throws {
        try await withTaskWorkflow(knowledgeEnabled: true) { fixture in
            guard let store = fixture.knowledge else { throw MiraError(.configuration, "Knowledge fixture was not enabled.") }
            let app = KnowledgeApplication(store: store, reader: .init(journal: fixture.library, payloads: fixture.library),
                                            access: fixture.access, scope: fixture.scope, now: { TaskWorkflowFixture.now })
            do {
                let imported = try await app.importMarkdown(.init(title: "Guide.md", bytes: Data("# Guide\nmetadata marker".utf8)), workspaceID: nil, operationID: UUID())
                let allowed = try await app.allowRemoteUse(imported.source.id, workspaceID: nil, expectedRevision: imported.source.revision, operationID: UUID())
                let detail = try await app.detail(imported.source.id, versionID: imported.version.id,
                    scope: .init(workspaceID: nil, destination: .model(fixture.route)))
                let chunk = try #require(detail.chunks.first)
                await fixture.model.append([
                    modelToolStream([.init(id: "open-1", name: "source.open", arguments: "{\"source_id\":\"\(imported.source.id.rawValue.uuidString.lowercased())\"}")]),
                    [.blockStarted(.init(id: "text", content: .text("Metadata answer"))), .blockFinished(id: "text"), .finished(.stop)]
                ])
                let address = try await fixture.run("Open the guide")
                #expect(await fixture.model.inputs.count == 2)
                let lease = try await fixture.access.acquire(in: fixture.scope)
                let evidence: SessionRecordedContextEvidence
                do {
                    evidence = try await lease.read {
                        try await JournalSessionReader(journal: fixture.library, payloads: fixture.library)
                            .recordedContextEvidence(sessionID: address.sessionID, executionID: address.executionID)
                    }
                } catch {
                    await lease.release()
                    throw error
                }
                await lease.release()
                #expect(evidence.sources.contains(.domain(namespace: KnowledgeSources.metadataNamespace,
                    id: imported.source.id.rawValue, revision: allowed.revision)))
                #expect(!evidence.sources.contains(.domain(namespace: KnowledgeSources.chunkNamespace,
                    id: chunk.id.rawValue, revision: 1)))
                await #expect(throws: MiraError.self) {
                    _ = try await app.citation(.init(versionID: imported.version.id, chunkID: chunk.id),
                        sessionID: address.sessionID, executionID: address.executionID, workspaceID: nil)
                }
                await app.close()
            } catch {
                await app.close()
                throw error
            }
        }
    }

    @Test func revokedSourceCannotBeCitedAfterCompletedMaintenance() async throws {
        let outputs: [[AgentModelStreamEvent]] = [
            modelToolStream([.init(id: "search-1", name: "knowledge.search", arguments: "{\"query\":\"revocation marker\"}")]),
            [.blockStarted(.init(id: "text", content: .text("Revocation answer"))), .blockFinished(id: "text"), .finished(.stop)]
        ]
        try await withTaskWorkflow(outputs: outputs, knowledgeEnabled: true) { fixture in
            guard let store = fixture.knowledge else { throw MiraError(.configuration, "Knowledge fixture was not enabled.") }
            let app = KnowledgeApplication(store: store, reader: .init(journal: fixture.library, payloads: fixture.library),
                                            access: fixture.access, scope: fixture.scope, now: { TaskWorkflowFixture.now })
            do {
                let imported = try await app.importMarkdown(.init(title: "Guide.md", bytes: Data("# Guide\nrevocation marker".utf8)), workspaceID: nil, operationID: UUID())
                let allowed = try await app.allowRemoteUse(imported.source.id, workspaceID: nil,
                    expectedRevision: imported.source.revision, operationID: UUID())
                let address = try await fixture.run("Find the revocation marker")
                let detail = try await app.detail(imported.source.id, versionID: imported.version.id,
                    scope: .init(workspaceID: nil, destination: .model(fixture.route)))
                let chunk = try #require(detail.chunks.first)
                let authorization = await fixture.access.snapshot().authorization
                let request = AgentLibraryMaintenanceRequest(id: UUID(), namespace: "knowledge.revoke", revision: 1,
                    scope: .sources([.domain(namespace: KnowledgeSources.metadataNamespace, id: imported.source.id.rawValue,
                        revision: allowed.revision)]), requestedAt: TaskWorkflowFixture.now)
                let operation = try await fixture.access.begin(request, expected: authorization)
                #expect(await fixture.runtime.shutdown().isSettled)
                await fixture.reminders.close()
                await fixture.tasks.close()
                try await fixture.access.waitForQuiescence()
                _ = try await store.revokeSourceRemoteUse(imported.source.id, workspaceID: nil,
                    expectedRevision: allowed.revision, maintenance: operation, at: TaskWorkflowFixture.now)
                _ = try await fixture.access.complete(operation, at: TaskWorkflowFixture.now)
                await #expect(throws: MiraError.self) {
                    _ = try await app.citation(.init(versionID: imported.version.id, chunkID: chunk.id),
                        sessionID: address.sessionID, executionID: address.executionID, workspaceID: nil)
                }
                await app.close()
            } catch {
                await app.close()
                throw error
            }
        }
    }

    @Test func localOnlySourceIsNotReturnedToModelScopedSearch() async throws {
        try await withTaskWorkflow(knowledgeEnabled: true) { fixture in
            guard let store = fixture.knowledge else { throw MiraError(.configuration, "Knowledge fixture was not enabled.") }
            let app = KnowledgeApplication(store: store, reader: .init(journal: fixture.library, payloads: fixture.library),
                                            access: fixture.access, scope: fixture.scope, now: { TaskWorkflowFixture.now })
            do {
                _ = try await app.importMarkdown(.init(title: "Private.md", bytes: Data("# Private\nlocal only marker".utf8)),
                    workspaceID: nil, operationID: UUID())
                let result = try await app.search(query: "local only marker",
                    scope: .init(workspaceID: nil, destination: .model(fixture.route)))
                #expect(result.hits.isEmpty)
                await app.close()
            } catch {
                await app.close()
                throw error
            }
        }
    }
}
