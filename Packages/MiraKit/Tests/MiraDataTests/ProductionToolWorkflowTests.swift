import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Production tools with inherited context", .timeLimit(.minutes(1)))
struct ProductionToolWorkflowTests {
    @Test(arguments: ["memory.search", "memory.get", "memory.remember", "knowledge.search",
                      "source.open", "source.read_chunk", "task.list", "task.change"])
    func toolReturnsUsefulResultAfterHistoryAndRecall(name: String) async throws {
        try await withTaskWorkflow(memoryEnabled: true, knowledgeEnabled: true) { f in
            let memoryStore = try #require(f.memory), knowledgeStore = try #require(f.knowledge)
            let authorization = try await f.authority.authorization()
            let content = "I prefer green tea"
            let memory = try await memoryStore.createMemory(
                draft: .init(content: content, scope: .global),
                source: .manualEntry(id: UUID(), statement: content), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now).memory
            let source = try await knowledgeStore.importMarkdown(
                .init(title: "Tea.md", bytes: Data("# Tea\ngreen tea brewing guide".utf8)),
                workspaceID: nil, updating: nil, expectedRevision: nil, operationID: UUID(),
                authorization: authorization, at: TaskWorkflowFixture.now)
            _ = try await knowledgeStore.allowSourceRemoteUse(source.source.id, workspaceID: nil,
                expectedRevision: source.source.revision, operationID: UUID(), authorization: authorization,
                at: TaskWorkflowFixture.now)
            let detail = try await knowledgeStore.knowledgeSource(source.source.id, versionID: nil,
                scope: .init(workspaceID: nil, destination: .model(f.route)))
            let chunk = try #require(detail.chunks.first)
            let task = try await f.save(draft: .init(title: "brew green tea"))
            await f.model.append([Self.reply("Prior conversation")])
            let prior = try await f.run("Hello")
            let text = name == "memory.remember" ? "Remember: I prefer green tea" : "Create a task to brew green tea"
            let arguments: JSONValue
            switch name {
            case "memory.search", "knowledge.search": arguments = .object(["query": .string("green tea")])
            case "memory.get": arguments = .object(["memory_id": .string(memory.id.rawValue.uuidString)])
            case "memory.remember":
                arguments = .object(["content": .string(content), "quote": .string(content),
                    "kind": .string("preference"), "scope": .string("current"), "sensitive": .bool(false),
                    "enriches": .array([])])
            case "source.open": arguments = .object(["source_id": .string(source.source.id.rawValue.uuidString)])
            case "source.read_chunk": arguments = .object(["chunk_id": .string(chunk.id.rawValue.uuidString)])
            case "task.list": arguments = .object([:])
            default: arguments = taskArguments(title: "brew green tea", quote: text)
            }
            await f.model.append([
                modelToolStream([.init(id: "tested-tool", name: name, arguments: try arguments.jsonString())]),
                Self.reply("Used the tool result")
            ])
            let address = try await f.run(text, sessionID: prior.sessionID)
            let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
            let invocation = try #require(state.invocations.values.first)
            #expect(invocation.resolution?.status == .succeeded)
            let resultReference = try #require(invocation.resolution?.result)
            let result = try SessionCodec.decode(JSONValue.self, from: await f.library.read(resultReference))
            switch name {
            case "memory.search", "memory.get":
                #expect(Self.first(result["memories"])?["content"]?.stringValue == content)
            case "memory.remember":
                let id = try #require(result["memory_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
                let saved = try await memoryStore.memoryDetail(.init(id), workspaceID: nil)
                #expect(saved.memory.draft?.content == content)
                #expect(result["allows_remote_use"] == .bool(true))
                #expect(invocation.resolution?.businessReceipt != nil)
            case "knowledge.search": #expect(Self.first(result["hits"])?["chunk_id"]?.stringValue == chunk.id.rawValue.uuidString.lowercased())
            case "source.open": #expect(result["title"]?.stringValue == "Tea.md")
            case "source.read_chunk": #expect(result["content"]?.stringValue == "# Tea\ngreen tea brewing guide")
            case "task.list": #expect(Self.first(result["tasks"])?["id"]?.stringValue == task.id.rawValue.uuidString.lowercased())
            default:
                #expect(result["record_saved"] == .bool(true))
                #expect(try await f.tasks.tasks(workspaceID: nil).count == 2)
                #expect(invocation.resolution?.businessReceipt != nil)
            }
            let proposalReference = try #require(invocation.intent?.intent.proposal)
            let proposal = try SessionCodec.decode(AgentToolProposal.self, from: await f.library.read(proposalReference))
            // The recorded proposal must retain prior history and recall for privacy cleanup.
            #expect(proposal.inheritedSources.contains(.sessionExecution(sessionID: prior.sessionID, executionID: prior.executionID)))
            #expect(!proposal.plan.sources.contains(.sessionExecution(sessionID: prior.sessionID, executionID: prior.executionID)))
            #expect(proposal.sources.contains(.sessionExecution(sessionID: prior.sessionID, executionID: prior.executionID)))
            #expect(proposal.sources.contains(.domain(namespace: "memories", id: memory.id.rawValue, revision: memory.revision)))
            let inputs = await f.model.inputs
            #expect(inputs.count == 3)
            let observation = try #require(inputs.last?.messages.flatMap(\.toolResults).first { $0.callID == "tested-tool" })
            let observed = try SessionCodec.decode(JSONValue.self, from: Data(observation.text.utf8))
            #expect(observed["status"] == .string("succeeded"))
            #expect(observed["content"] == result)
        }
    }

    private static func first(_ value: JSONValue?) -> JSONValue? {
        guard case .array(let values) = value else { return nil }
        return values.first
    }

    private static func reply(_ text: String) -> [AgentModelStreamEvent] {
        [.blockStarted(.init(id: "text", content: .text(text))), .blockFinished(id: "text"), .finished(.stop)]
    }
}
