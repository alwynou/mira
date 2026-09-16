import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Task tool sequences", .timeLimit(.minutes(1)))
struct TaskToolSequenceTests {
    @Test(arguments: ["complete", "update", "cancel"])
    func listThenChangeKeepsHistoricalSourceAndCompletes(operation: String) async throws {
        let quote: String
        let title: String
        switch operation {
        case "complete":
            quote = "complete task review notes"
            title = "review notes"
        case "update":
            quote = "update task review notes to renewed notes with new details"
            title = "renewed notes"
        default:
            quote = "cancel task review notes"
            title = "review notes"
        }

        try await withTaskWorkflow { fixture in
            let task = try await fixture.save(draft: .init(title: "review notes", notes: "old details"))
            var fields: [String: JSONValue] = [
                "operation": .string(operation),
                "title": .string(title),
                "quote": .string(quote),
                "task_id": .string(task.id.rawValue.uuidString.lowercased()),
                "expected_revision": .number(Double(task.revision)),
                "remind": .bool(false)
            ]
            if operation == "update" { fields["notes"] = .string("new details") }
            let change = try JSONValue.object(fields).jsonString()
            await fixture.model.append([
                modelToolStream([.init(id: "list", name: "task.list", arguments: "{}")]),
                modelToolStream([.init(id: "change", name: "task.change", arguments: change)]),
                modelTextStream("Task change completed")
            ])

            let address = try await fixture.run(quote)
            let state = try await fixture.runtime.sessionSnapshot(id: address.sessionID)
            #expect(state.executions[address.executionID]?.completion?.status == .completed)

            let listInvocation = try #require(state.invocations.values.first { $0.invocation.toolName == "task.list" })
            #expect(listInvocation.resolution?.status == .succeeded)
            let listResult = try SessionCodec.decode(
                JSONValue.self,
                from: await fixture.library.read(try #require(listInvocation.resolution?.result))
            )
            guard case .array(let listed) = listResult["tasks"], let first = listed.first else {
                Issue.record("The task list result is missing its task array")
                return
            }
            #expect(first["revision"] == .number(1))

            let changeInvocation = try #require(state.invocations.values.first { $0.invocation.toolName == "task.change" })
            #expect(changeInvocation.resolution?.status == .succeeded)
            #expect(changeInvocation.resolution?.businessReceipt != nil)
            let changeResult = try SessionCodec.decode(
                JSONValue.self,
                from: await fixture.library.read(try #require(changeInvocation.resolution?.result))
            )
            #expect(changeResult["record_saved"] == .bool(true))

            let changed = try await fixture.store.taskDetail(task.id, workspaceID: nil)
            #expect(changed.revision == 2)
            switch operation {
            case "complete":
                #expect(changed.status == .completed)
                #expect(changed.draft == task.draft)
            case "update":
                #expect(changed.status == .open)
                #expect(changed.draft.title == "renewed notes")
                #expect(changed.draft.notes == "new details")
            default:
                #expect(changed.status == .cancelled)
                #expect(changed.draft == task.draft)
            }

            let completion = try #require(state.executions[address.executionID]?.completion)
            let replayReference = try #require(completion.replay)
            let replay = try SessionCodec.decode(AgentReplayRecord.self, from: await fixture.library.read(replayReference))
            #expect(replay.messages.last?.text == "Task change completed")
            #expect(replay.sources.contains(.domain(namespace: "tasks", id: task.id.rawValue, revision: 1)))
        }
    }

    @Test
    func staleTargetIsRejectedAfterListWhileFinalAnswerStillCompletes() async throws {
        let quote = "complete task review notes"
        try await withTaskWorkflow { fixture in
            let task = try await fixture.save(draft: .init(title: "review notes"))
            let change = try JSONValue.object([
                "operation": .string("complete"), "title": .string("review notes"), "quote": .string(quote),
                "task_id": .string(task.id.rawValue.uuidString.lowercased()),
                "expected_revision": .number(Double(task.revision)), "remind": .bool(false)
            ]).jsonString()
            await fixture.model.append([
                modelToolStream([.init(id: "list", name: "task.list", arguments: "{}")] ),
                modelToolStream([.init(id: "change", name: "task.change", arguments: change)]),
                modelTextStream("I could not complete the stale task")
            ])
            await fixture.model.holdStream(number: 2, afterEvents: 0)

            let run = Task { try await fixture.run(quote) }
            try await taskEventually { await fixture.model.streamHeld }
            let externallyChanged = try await fixture.save(
                id: task.id, draft: .init(title: "review notes", notes: "changed elsewhere"), expectedRevision: task.revision
            )
            await fixture.model.releaseStream()
            let address = try await run.value
            let state = try await fixture.runtime.sessionSnapshot(id: address.sessionID)
            let invocation = try #require(state.invocations.values.first { $0.invocation.toolName == "task.change" })
            #expect(invocation.resolution?.status == .invalidArguments)
            #expect(try await fixture.store.taskDetail(task.id, workspaceID: nil) == externallyChanged)
            #expect(state.executions[address.executionID]?.completion?.status == .completed)
            #expect(try await fixture.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM business_receipts") } == 0)
        }
    }

    @Test
    func historicalTaskSourceLookupIsExactAndBoundedByCurrentWorkspace() async throws {
        try await withTaskWorkflow { fixture in
            var task = try await fixture.save(draft: .init(title: "revision 1"))
            for revision in 2...101 {
                task = try await fixture.save(
                    id: task.id, draft: .init(title: "revision \(revision)"), expectedRevision: task.revision
                )
            }
            let source = AgentSourceReference.domain(namespace: "tasks", id: task.id.rawValue, revision: 1)
            let request = AgentContextRequest(
                sessionID: .init(), executionID: .init(), workspaceID: nil, userText: "review",
                authorizationEpoch: 1, destination: .model(fixture.route)
            )
            try await fixture.authorizer.validate([source], for: request)

            await #expect(throws: MiraError.self) {
                _ = try await fixture.store.taskRevision(task.id, revision: 102, workspaceID: nil)
            }
            await #expect(throws: MiraError.self) {
                _ = try await fixture.store.taskRevision(task.id, revision: 1, workspaceID: .init())
            }
            await #expect(throws: MiraError.self) {
                try await fixture.authorizer.validate(
                    [.domain(namespace: "tasks", id: task.id.rawValue, revision: 102)], for: request
                )
            }
        }
    }
}
