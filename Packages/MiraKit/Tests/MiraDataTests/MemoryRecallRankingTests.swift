import Foundation
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Memory recall ranking")
struct MemoryRecallRankingTests {
    @Test func exactShortCJKPhraseWinsAgainstBroadWordCandidates() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("ready"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { f in
            let store = try #require(f.memory)
            let now = TaskWorkflowFixture.now
            let authorization = try await f.authority.authorization()
            var generic: [Memory] = []
            for index in 0..<25 {
                let created = try await store.createMemory(
                    draft: .init(content: "generic scale distractor \(index)", scope: .global),
                    source: .manualEntry(id: UUID(), statement: "generic scale distractor \(index)"),
                    operationID: UUID(), replacing: nil, expectedRevision: nil,
                    authorization: authorization, at: now)
                generic.append(created.memory)
            }
            let exactSeed = try #require(
                generic.max { $0.id.rawValue.uuidString.lowercased() < $1.id.rawValue.uuidString.lowercased() })
            let exact = try await store.reviseMemory(
                exactSeed.id, workspaceID: nil, draft: .init(content: "混合 scale exact phrase", scope: .global), // i18n-fixture: Chinese-English exact phrase.
                expectedRevision: 1,
                operationID: UUID(), authorization: authorization, at: now)

            let workspaceID = WorkspaceID()
            try await f.workspaces.saveWorkspace(
                .init(id: workspaceID, name: "Ranking workspace"), expectedRevision: nil,
                authorization: authorization)
            _ = try await store.createMemory(
                draft: .init(content: "混合 scale other workspace", scope: .workspace(workspaceID)),  // i18n-fixture: Chinese-English scope fixture.
                source: .manualEntry(id: UUID(), statement: "混合 scale other workspace"),  // i18n-fixture: Chinese-English scope fixture.
                operationID: UUID(), replacing: nil, expectedRevision: nil,
                authorization: authorization, at: now)
            _ = try await store.createMemory(
                draft: .init(content: "混合 scale expired", scope: .global, validUntil: now.addingTimeInterval(-1)),  // i18n-fixture: Chinese-English time fixture.
                source: .manualEntry(id: UUID(), statement: "混合 scale expired"),  // i18n-fixture: Chinese-English time fixture.
                operationID: UUID(), replacing: nil, expectedRevision: nil,
                authorization: authorization, at: now)

            let original = try await store.createMemory(
                draft: .init(content: "混合 scale superseded-old", scope: .global),  // i18n-fixture: Chinese-English replacement fixture.
                source: .manualEntry(id: UUID(), statement: "混合 scale superseded-old"),  // i18n-fixture: Chinese-English replacement fixture.
                operationID: UUID(), replacing: nil, expectedRevision: nil,
                authorization: authorization, at: now)
            let current = try await store.createMemory(
                draft: .init(content: "replacement current scale", scope: .global),
                source: .manualEntry(id: UUID(), statement: "replacement current scale"),
                operationID: UUID(), replacing: original.memory.id, expectedRevision: original.memory.revision,
                authorization: authorization, at: now)
            let candidate = try await store.createMemory(
                draft: .init(content: "replacement new scale", scope: .global),
                source: .manualEntry(id: UUID(), statement: "replacement new scale"),
                operationID: UUID(), replacing: original.memory.id, expectedRevision: 2,
                authorization: authorization, at: now)
            _ = try await store.confirmMemoryReplacement(
                candidate.memory.id, workspaceID: nil, replacingCurrent: current.memory.id,
                expectedCandidateRevision: 1, expectedCurrentRevision: 1, operationID: UUID(),
                authorization: authorization, at: now)

            let localRequest = AgentContextRequest(
                sessionID: .init(), executionID: .init(), workspaceID: nil,
                userText: "混合 scale", authorizationEpoch: 0, destination: .local)  // i18n-fixture: Chinese-English query.
            let local = try await store.recallMemories(query: "混合 scale", request: localRequest, limit: 6, at: now)  // i18n-fixture: Chinese-English query.
            #expect(local.memories.count == 6 && local.isTruncated)
            #expect(local.memories.first?.id == exact.id)
            #expect(!local.memories.contains { $0.id == original.memory.id })
            #expect(!local.memories.contains { $0.id == current.memory.id })
            #expect(!local.memories.contains { $0.draft?.content.contains("other workspace") == true })
            #expect(!local.memories.contains { $0.draft?.content.contains("expired") == true })

            let remoteRequest = AgentContextRequest(
                sessionID: .init(), executionID: .init(), workspaceID: nil,
                userText: "混合 scale", authorizationEpoch: 0, destination: .model(f.route))  // i18n-fixture: Chinese-English query.
            let remoteOnly = try await store.createMemory(
                draft: .init(content: "混合 scale local-only", scope: .global, allowsRemoteUse: false),  // i18n-fixture: Chinese-English privacy fixture.
                source: .manualEntry(id: UUID(), statement: "混合 scale local-only"),  // i18n-fixture: Chinese-English privacy fixture.
                operationID: UUID(), replacing: nil, expectedRevision: nil,
                authorization: authorization, at: now)
            let remote = try await store.recallMemories(query: "混合 scale", request: remoteRequest, limit: 6, at: now)  // i18n-fixture: Chinese-English query.
            #expect(remote.memories.first?.id == exact.id)
            #expect(!remote.memories.contains { $0.id == remoteOnly.memory.id })
        }
    }

    @Test func literalPercentAndUnderscoreRemainLiteral() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("ready"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { f in
            let store = try #require(f.memory)
            let now = TaskWorkflowFixture.now
            let authorization = try await f.authority.authorization()
            let request = AgentContextRequest(
                sessionID: .init(), executionID: .init(), workspaceID: nil,
                userText: "literal fixtures", authorizationEpoch: 0, destination: .local)
            let fixtures = [
                ("混合 50%_done", "混合 50XYZdone"),  // i18n-fixture: Chinese percent and underscore literals.
                ("混合 path\\name", "混合 pathXname"),  // i18n-fixture: Chinese backslash literal.
                ("混合 \"quoted\"", "混合 quoted"),  // i18n-fixture: Chinese quote literal.
            ]
            for (query, decoyText) in fixtures {
                let first = try await store.createMemory(
                    draft: .init(content: "literal seed one", scope: .global),
                    source: .manualEntry(id: UUID(), statement: "literal seed one"), operationID: UUID(),
                    replacing: nil,
                    expectedRevision: nil, authorization: authorization, at: now)
                let second = try await store.createMemory(
                    draft: .init(content: "literal seed two", scope: .global),
                    source: .manualEntry(id: UUID(), statement: "literal seed two"), operationID: UUID(),
                    replacing: nil,
                    expectedRevision: nil, authorization: authorization, at: now)
                let exactSeed =
                    first.memory.id.rawValue.uuidString.lowercased() > second.memory.id.rawValue.uuidString.lowercased()
                    ? first.memory : second.memory
                let decoySeed = exactSeed.id == first.memory.id ? second.memory : first.memory
                let exact = try await store.reviseMemory(
                    exactSeed.id, workspaceID: nil, draft: .init(content: query, scope: .global), expectedRevision: 1,
                    operationID: UUID(), authorization: authorization, at: now)
                _ = try await store.reviseMemory(
                    decoySeed.id, workspaceID: nil, draft: .init(content: decoyText, scope: .global),
                    expectedRevision: 1,
                    operationID: UUID(), authorization: authorization, at: now)
                let result = try await store.recallMemories(query: query, request: request, limit: 6, at: now)
                #expect(result.memories.first?.id == exact.id)
                #expect(result.memories.contains { $0.id == decoySeed.id })
            }
        }
    }
}
