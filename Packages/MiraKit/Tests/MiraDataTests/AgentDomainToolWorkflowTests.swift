import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Domain tools with inherited conversation context", .timeLimit(.minutes(1)))
struct AgentDomainToolWorkflowTests {
    @Test(arguments: ["memory.remember", "memory.search", "memory.get", "task.change", "task.list",
                      "knowledge.search", "source.open", "source.read_chunk"])
    func toolSucceedsAfterAnEarlierConversationTurn(name: String) async throws {
        try await withTaskWorkflow(memoryEnabled: true, knowledgeEnabled: true) { f in
            let memoryStore = try #require(f.memory)
            let memory = try await memoryStore.createMemory(
                draft: .init(content: "I prefer green tea", scope: .global),
                source: .manualEntry(id: UUID(), statement: "I prefer green tea"),
                operationID: UUID(), replacing: nil, expectedRevision: nil,
                authorization: f.authority.authorization(), at: TaskWorkflowFixture.now).memory
            _ = try await f.save(draft: .init(title: "Existing task"))
            let knowledge = KnowledgeApplication(store: try #require(f.knowledge),
                reader: .init(journal: f.library, payloads: f.library), access: f.access,
                scope: f.scope, now: { TaskWorkflowFixture.now })
            let imported: KnowledgeImportReceipt
            let chunk: SourceChunkSummary
            do {
                imported = try await knowledge.importMarkdown(
                    .init(title: "Guide.md", bytes: Data("# Guide\nSynthetic lookup marker.".utf8)),
                    workspaceID: nil, operationID: UUID())
                _ = try await knowledge.allowRemoteUse(imported.source.id, workspaceID: nil,
                    expectedRevision: imported.source.revision, operationID: UUID())
                chunk = try #require(try await knowledge.detail(imported.source.id,
                    scope: .init(workspaceID: nil, destination: .local)).chunks.first)
                await knowledge.close()
            } catch { await knowledge.close(); throw error }

            await f.model.append([Self.answer])
            let prior = try await f.run("Hello")
            let text: String
            let arguments: JSONValue
            switch name {
            case "memory.remember":
                text = "Remember: I prefer black coffee"
                arguments = .object(["content": .string("I prefer black coffee"),
                    "quote": .string("I prefer black coffee"), "kind": .string("preference"),
                    "scope": .string("current"), "sensitive": .bool(false)])
            case "memory.search":
                text = "Find my tea preference"
                arguments = .object(["query": .string("green tea")])
            case "memory.get":
                text = "Read my saved preference"
                arguments = .object(["memory_id": .string(memory.id.rawValue.uuidString.lowercased())])
            case "task.change":
                text = "create a task to review notes"
                arguments = taskArguments(quote: text)
            case "task.list":
                text = "List my tasks"
                arguments = .object([:])
            case "knowledge.search":
                text = "Find the lookup marker"
                arguments = .object(["query": .string("lookup marker")])
            case "source.open":
                text = "Open the guide"
                arguments = .object(["source_id": .string(imported.source.id.rawValue.uuidString.lowercased())])
            default:
                text = "Read the guide section"
                arguments = .object(["chunk_id": .string(chunk.id.rawValue.uuidString.lowercased())])
            }
            await f.model.append([modelToolStream([.init(id: "call", name: name,
                arguments: try arguments.jsonString())]), Self.answer])
            let address = try await f.run(text, sessionID: prior.sessionID)
            let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
            let invocation = try #require(state.invocations.values.first)
            #expect(invocation.resolution?.status == .succeeded)
            #expect(invocation.resolution?.result != nil)
            if ["memory.remember", "task.change"].contains(name) {
                #expect(invocation.resolution?.businessReceipt != nil)
            }
            let attempt = try #require(state.attempts[invocation.invocation.attemptID])
            let request = try SessionCodec.decode(AgentSessionRequest.self,
                from: await f.library.read(attempt.attempt.request))
            let historySource = AgentSourceReference.sessionExecution(
                sessionID: prior.sessionID, executionID: prior.executionID)
            #expect(request.sources.contains(historySource))
            let proposal = try SessionCodec.decode(AgentToolProposal.self,
                from: await f.library.read(#require(invocation.intent?.intent.proposal)))
            #expect(!proposal.plan.sources.contains(historySource))
            let evidence = try await JournalSessionReader(journal: f.library, payloads: f.library)
                .recordedContextEvidence(sessionID: address.sessionID, executionID: address.executionID)
            #expect(evidence.sources.contains(historySource))
            #expect(Set(proposal.plan.sources).isSubset(of: Set(evidence.sources)))
        }
    }

    @Test func consecutiveToolsKeepEarlierDomainSourcesOutOfTheNextToolPlan() async throws {
        try await withTaskWorkflow(memoryEnabled: true, knowledgeEnabled: true) { f in
            let task = try await f.save(draft: .init(title: "Existing task"))
            await f.model.append([
                modelToolStream([.init(id: "tasks", name: "task.list", arguments: "{}")]),
                modelToolStream([.init(id: "memories", name: "memory.search", arguments: "{\"query\":\"tea\"}")]),
                modelToolStream([.init(id: "knowledge", name: "knowledge.search", arguments: "{\"query\":\"guide\"}")]),
                Self.answer
            ])
            let address = try await f.run("Check my tasks, memories and knowledge")
            let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
            #expect(state.invocations.count == 3)
            #expect(state.invocations.values.allSatisfy { $0.resolution?.status == .succeeded })
            let taskSource = AgentSourceReference.domain(namespace: "tasks", id: task.id.rawValue, revision: 1)
            for invocation in state.invocations.values where invocation.invocation.toolName != "task.list" {
                let proposal = try SessionCodec.decode(AgentToolProposal.self,
                    from: await f.library.read(#require(invocation.intent?.intent.proposal)))
                #expect(proposal.plan.sources.isEmpty)
                let attempt = try #require(state.attempts[invocation.invocation.attemptID])
                let request = try SessionCodec.decode(AgentSessionRequest.self,
                    from: await f.library.read(attempt.attempt.request))
                #expect(request.sources.contains(taskSource))
            }
            let evidence = try await JournalSessionReader(journal: f.library, payloads: f.library)
                .recordedContextEvidence(sessionID: address.sessionID, executionID: address.executionID)
            #expect(evidence.sources.contains(taskSource))
        }
    }

    private static var answer: [AgentModelStreamEvent] {
        [.blockStarted(.init(id: "text", content: .text("Synthetic answer."))),
         .blockFinished(id: "text"), .finished(.stop)]
    }
}
