import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Memory history context notices")
struct MemoryHistoryStoreTests {
    @Test(arguments: [
        "unchanged", "updated", "superseded", "archived", "expired", "notYetValid",
        "candidate", "removed", "rejected", "remoteDenied", "connectionDenied",
    ])
    func currentLifecycleAndPolicyAreReadWithoutReturningBodies(scenario: String) async throws {
        try await withTaskWorkflow(memoryEnabled: true) { f in
            let store = try #require(f.memory)
            let authorization = try await f.authority.authorization()
            let now = TaskWorkflowFixture.now
            var draft = MemoryDraft(content: "Synthetic tea preference", scope: .global)
            let memory = try await store.createMemory(
                draft: draft,
                source: .manualEntry(id: UUID(), statement: draft.content), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: authorization, at: now
            ).memory
            let references = [MemoryCitationReference(memoryID: memory.id, revision: 1)]
            switch scenario {
            case "unchanged": break
            case "superseded":
                _ = try await store.createMemory(
                    draft: .init(content: "Synthetic coffee preference", scope: .global),
                    source: .manualEntry(id: UUID(), statement: "Synthetic coffee preference"), operationID: UUID(),
                    replacing: memory.id, expectedRevision: 1, authorization: authorization, at: now)
            case "archived", "candidate", "removed", "rejected":
                _ = try await store.changeMemoryState(
                    memory.id, workspaceID: nil,
                    state: try #require(MemoryState(rawValue: scenario)), expectedRevision: 1, operationID: UUID(),
                    authorization: authorization, at: now)
            default:
                if scenario == "updated" { draft.content = "Synthetic clearer tea preference" }
                if scenario == "expired" { draft.validUntil = now }
                if scenario == "notYetValid" { draft.validFrom = now.addingTimeInterval(1) }
                if scenario == "remoteDenied" { draft.allowsRemoteUse = false }
                if scenario == "connectionDenied" { draft.allowedConnectionIDs = [.init()] }
                _ = try await store.reviseMemory(
                    memory.id, workspaceID: nil, draft: draft, expectedRevision: 1,
                    operationID: UUID(), authorization: authorization, at: now)
            }
            let notices = try await store.memoryContextNotices(
                references: references, workspaceID: nil,
                connectionID: f.route.connectionID, at: now)
            if scenario == "unchanged" {
                #expect(notices.isEmpty)
            } else {
                let reason = scenario.hasSuffix("Denied") ? "unavailable" : scenario
                #expect(notices == [.init(memoryID: memory.id, reason: try #require(.init(rawValue: reason)))])
                #expect(
                    try await store.memoryContextNotices(
                        references: references + [.init(memoryID: memory.id, revision: 2)],
                        workspaceID: nil, connectionID: f.route.connectionID, at: now) == notices)
            }
        }
    }

    @Test func globalMemoryRespectsItsOriginalSourceWorkspacePolicy() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Acknowledged"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) {
            f in
            let store = try #require(f.memory)
            let authorization = try await f.authority.authorization()
            var workspace = Workspace(id: .init(), name: "Synthetic source")
            try await f.workspaces.saveWorkspace(workspace, expectedRevision: nil, authorization: authorization)
            let source = try await f.run("I prefer synthetic tea", workspaceID: workspace.id)
            let evidence = try await f.evidence(source)
            let memory = try await store.createMemory(
                draft: .init(content: evidence.text, scope: .global),
                source: .userMessage(evidence: evidence, excerpt: evidence.text), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now
            ).memory
            let references = [MemoryCitationReference(memoryID: memory.id, revision: 1)]
            #expect(
                try await store.memoryContextNotices(
                    references: references, workspaceID: nil,
                    connectionID: f.route.connectionID, at: TaskWorkflowFixture.now
                ).isEmpty)
            workspace.revision += 1
            workspace.allowsRemoteSend = false
            try await f.workspaces.saveWorkspace(workspace, expectedRevision: 1, authorization: authorization)
            #expect(
                try await store.memoryContextNotices(
                    references: references, workspaceID: nil,
                    connectionID: f.route.connectionID, at: TaskWorkflowFixture.now) == [
                        .init(memoryID: memory.id, reason: .unavailable)
                    ])
            #expect(
                try await store.memoryContextNotices(
                    references: references, workspaceID: nil,
                    connectionID: nil, at: TaskWorkflowFixture.now
                ).isEmpty)
        }
    }

    @Test func missingOutOfScopeMalformedAndClosedReadsDoNotMasqueradeAsValidHistory() async throws {
        try await withTaskWorkflow(memoryEnabled: true) { f in
            let store = try #require(f.memory)
            let authorization = try await f.authority.authorization()
            let workspace = Workspace(id: .init(), name: "Private scope")
            try await f.workspaces.saveWorkspace(workspace, expectedRevision: nil, authorization: authorization)
            let memory = try await store.createMemory(
                draft: .init(content: "Scoped synthetic content", scope: .workspace(workspace.id)),
                source: .manualEntry(id: UUID(), statement: "Scoped synthetic content"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now
            ).memory
            let reference = MemoryCitationReference(memoryID: memory.id, revision: 1)
            let missing = MemoryCitationReference(memoryID: .init(), revision: 1)
            let notices = try await store.memoryContextNotices(
                references: [reference, missing], workspaceID: nil,
                connectionID: nil, at: TaskWorkflowFixture.now)
            #expect(
                Set(notices) == [
                    .init(memoryID: memory.id, reason: .unavailable),
                    .init(memoryID: missing.memoryID, reason: .unavailable),
                ])
            #expect(notices == notices.sorted { $0.id < $1.id })
            for selection in [
                [reference, reference], [.init(memoryID: memory.id, revision: 0)],
                Array(repeating: reference, count: 8_193),
            ] {
                await #expect(throws: MiraError.self) {
                    try await store.memoryContextNotices(
                        references: selection, workspaceID: nil, connectionID: nil, at: TaskWorkflowFixture.now)
                }
            }
            try await f.database.write { db in
                try db.execute(
                    sql: "UPDATE memory_records SET json = ? WHERE id = ?",
                    arguments: [Data("broken".utf8), memory.id.rawValue.uuidString.lowercased()])
            }
            do {
                _ = try await store.memoryContextNotices(
                    references: [reference], workspaceID: workspace.id,
                    connectionID: nil, at: TaskWorkflowFixture.now)
                Issue.record("Corrupt domain state must fail the query.")
            } catch let error as MiraError { #expect(error.code == .storage) }
            await store.close()
            await #expect(throws: MiraError.self) {
                try await store.memoryContextNotices(
                    references: [], workspaceID: nil, connectionID: nil, at: TaskWorkflowFixture.now)
            }
        }
    }
}
