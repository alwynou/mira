import Foundation
import MiraCore
import MiraData
import Testing

@Suite("SQLite pending recovery source capabilities", .timeLimit(.minutes(1)))
struct SQLitePendingRecoverySourceTests {
    @Test func knowledgeCapabilitiesValidateRealMetadataAndImmutableChunks() async throws {
        try await withTaskWorkflow(knowledgeEnabled: true) { fixture in
            let knowledge = try #require(fixture.knowledge)
            let imported = try await knowledge.importMarkdown(
                .init(title: "Synthetic knowledge", bytes: Data("# Notes\nRetained source body.".utf8)),
                workspaceID: nil, updating: nil, expectedRevision: nil, operationID: UUID(),
                authorization: await fixture.access.snapshot().authorization, at: TaskWorkflowFixture.now)
            let detail = try await knowledge.knowledgeSource(
                imported.source.id, versionID: nil,
                scope: .init(workspaceID: nil, destination: .local))
            let chunk = try #require(detail.chunks.first)
            let pending = try await beginLibraryMaintenance(fixture)
            let local = request(destination: .local)
            let sources: [AgentSourceReference] = [
                .domain(
                    namespace: KnowledgeSources.metadataNamespace, id: imported.source.id.rawValue,
                    revision: imported.source.revision),
                .domain(namespace: KnowledgeSources.chunkNamespace, id: chunk.id.rawValue, revision: 1),
            ]
            let authorities = knowledge.pendingRecoveryAuthorities(pending)
            #expect(authorities.count == 2)
            for (authority, source) in zip(authorities, sources) {
                try await authority.validate([source], for: local)
                guard case .domain(let namespace, let id, let revision) = source else { continue }
                await #expect(throws: MiraError.self) {
                    try await authority.validate(
                        [.domain(namespace: namespace, id: id, revision: revision + 1)], for: local)
                }
                await #expect(throws: MiraError.self) {
                    try await authority.validate([source, source], for: local)
                }
                await #expect(throws: MiraError.self) {
                    try await authority.validate([source], for: request(destination: .model(fixture.route)))
                }
            }
            await #expect(throws: MiraError.self) {
                try await knowledge.validateKnowledgeSources(sources, for: local)
            }
            await knowledge.close()
            await #expect(throws: MiraError.self) { try await authorities[0].validate([sources[0]], for: local) }
        }
    }

    @Test func ordinaryReadsRemainBlockedAndExactLocalCapabilitiesWork() async throws {
        try await withTaskWorkflow(memoryEnabled: true, knowledgeEnabled: true) { fixture in
            let pending = try await beginLibraryMaintenance(fixture)
            let local = request(destination: .local)
            let model = request(destination: .model(fixture.route))

            await #expect(throws: MiraError.self) { try await fixture.contextPolicy.validate(local) }
            try await fixture.contextPolicy.pendingRecoveryPolicy(pending).validate(local)
            await #expect(throws: MiraError.self) {
                try await fixture.contextPolicy.pendingRecoveryPolicy(pending).validate(model)
            }

            try await fixture.memory?.pendingRecoveryAuthority(pending).validate([], for: local)
            for authority in fixture.knowledge?.pendingRecoveryAuthorities(pending) ?? [] {
                try await authority.validate([], for: local)
            }
            try await fixture.store.pendingRecoveryAuthority(pending).validate([], for: local)

            do {
                _ = try await fixture.store.taskList(workspaceID: nil, includeCompleted: true, limit: 1)
                Issue.record("An ordinary domain read passed while maintenance was pending")
            } catch let error as MiraError {
                #expect(error.code == .unauthorized)
            }

            let mismatched = AgentLibraryMaintenanceOperation(
                request: pending.request, previousAuthorization: pending.previousAuthorization,
                authorization: pending.authorization, completedAt: nil)
            let completed = try await fixture.authority.complete(pending, at: TaskWorkflowFixture.now)
            #expect(completed.completedAt != nil)
            do {
                try await fixture.contextPolicy.pendingRecoveryPolicy(mismatched).validate(local)
                Issue.record("A stale pending operation was accepted")
            } catch let error as MiraError {
                #expect(error.code != .unauthorized)
            }
        }
    }

    @Test func sourceCapabilitiesRetainRevisionAndRevocationRules() async throws {
        try await withTaskWorkflow(memoryEnabled: true) { fixture in
            let task = try await fixture.save(draft: .init(title: "Synthetic task"))
            let memory = try await fixture.memory!.createMemory(
                draft: .init(content: "Synthetic memory", scope: .global),
                source: .manualEntry(id: UUID(), statement: "Synthetic memory"),
                operationID: UUID(), replacing: nil, expectedRevision: nil,
                authorization: await fixture.access.snapshot().authorization,
                at: TaskWorkflowFixture.now
            ).memory
            let memorySource = AgentSourceReference.domain(
                namespace: "memories", id: memory.id.rawValue, revision: memory.revision)
            _ = try await fixture.memory!.changeMemoryState(
                memory.id, workspaceID: nil, state: .rejected, expectedRevision: memory.revision,
                operationID: UUID(), authorization: await fixture.access.snapshot().authorization,
                at: TaskWorkflowFixture.now)
            await fixture.runtime.shutdown()
            let pending = try await beginLibraryMaintenance(fixture)
            let local = request(destination: .local)
            let taskAuthority = fixture.store.pendingRecoveryAuthority(pending)
            let validTask = AgentSourceReference.domain(
                namespace: "tasks", id: task.id.rawValue, revision: task.revision)
            try await taskAuthority.validate([validTask], for: local)

            for source in [
                AgentSourceReference.domain(namespace: "tasks", id: task.id.rawValue, revision: task.revision + 1),
                AgentSourceReference.domain(namespace: "tasks", id: UUID(), revision: 1),
            ] {
                await #expect(throws: MiraError.self) { try await taskAuthority.validate([source], for: local) }
            }
            await #expect(throws: MiraError.self) {
                try await fixture.memory!.pendingRecoveryAuthority(pending).validate([memorySource], for: local)
            }
            await #expect(throws: MiraError.self) {
                try await taskAuthority.validate([validTask], for: request(destination: .model(fixture.route)))
            }
        }
    }

    @Test func mismatchedOrCompletedPendingStateIsNotReportedAsRevocation() async throws {
        try await withTaskWorkflow { fixture in
            let pending = try await beginLibraryMaintenance(fixture)
            let local = request(destination: .local)
            let wrongRequest = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: pending.request.namespace, revision: pending.request.revision,
                scope: pending.request.scope, requestedAt: pending.request.requestedAt)
            let wrongOperation = AgentLibraryMaintenanceOperation(
                request: wrongRequest, previousAuthorization: pending.previousAuthorization,
                authorization: pending.authorization, completedAt: nil)
            do {
                try await fixture.contextPolicy.pendingRecoveryPolicy(wrongOperation).validate(local)
                Issue.record("A mismatched pending operation was accepted")
            } catch let error as MiraError {
                #expect(error.code != .unauthorized)
            }

            _ = try await fixture.authority.complete(pending, at: TaskWorkflowFixture.now)
            do {
                try await fixture.contextPolicy.pendingRecoveryPolicy(pending).validate(local)
                Issue.record("A completed pending operation was accepted")
            } catch let error as MiraError {
                #expect(error.code != .unauthorized)
            }
        }
    }
}

private func request(destination: AgentContextDestination) -> AgentContextRequest {
    .init(
        sessionID: .init(), executionID: .init(), workspaceID: nil,
        userText: "Synthetic local recovery", authorizationEpoch: 0, destination: destination)
}

private func beginLibraryMaintenance(_ fixture: TaskWorkflowFixture) async throws -> AgentLibraryMaintenanceOperation {
    let authorization = await fixture.access.snapshot().authorization
    return try await fixture.authority.begin(
        .init(
            id: UUID(), namespace: "tests.pending-recovery", revision: 1,
            scope: .library, requestedAt: TaskWorkflowFixture.now), expected: authorization)
}
