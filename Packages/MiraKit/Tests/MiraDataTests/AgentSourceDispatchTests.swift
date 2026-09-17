import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Source authorization at production dispatch and settlement")
struct AgentSourceDispatchTests {
    @Test(arguments: ["workspace", "connection"])
    func revokedAfterPreparationCannotDispatchWhenCapacityBecomesAvailable(revoked: String) async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Must not dispatch"))), .blockFinished(id: "text"), .finished(.stop)]]) { f in
            let workspace = Workspace(id: .init(), name: "Dispatch workspace")
            try await saveWorkspace(workspace, in: f)
            let first = try await f.scheduler.acquire(executionID: .init(), priority: .foreground)
            let second = try await f.scheduler.acquire(executionID: .init(), priority: .foreground)
            let run = Task { try await f.run("Prepared before revocation", workspaceID: workspace.id, expectedStatus: .failed) }
            do {
                try await taskEventually { f.model.preparations.count > 0 }
                #expect(await f.model.inputs.isEmpty)
                try await revoke(revoked, workspace: workspace, in: f)
                await first.release(); await second.release()
                let address = try await run.value
                let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
                #expect(state.attempts.isEmpty)
                #expect(state.invocations.isEmpty)
                #expect(await f.model.inputs.isEmpty)
            } catch { await first.release(); await second.release(); _ = await run.result; throw error }
        }
    }

    @Test(arguments: ["workspace", "connection"])
    func revocationAfterModelDispatchSuppressesCompletedContent(revoked: String) async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Output from revoked destination"))), .blockFinished(id: "text"), .finished(.stop)]]) { f in
            let workspace = Workspace(id: .init(), name: "Settlement workspace")
            try await saveWorkspace(workspace, in: f)
            await f.model.holdStream(number: 1)
            let run = Task { try await f.run("Dispatched before revocation", workspaceID: workspace.id, expectedStatus: .interrupted) }
            do {
                try await taskEventually { await f.model.streamHeld }
                try await revoke(revoked, workspace: workspace, in: f)
                await f.model.releaseStream()
                let address = try await run.value
                let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
                let completion = try #require(state.executions[address.executionID]?.completion)
                #expect(completion.answer == nil)
                #expect(completion.visibleThinking == nil)
                #expect(completion.replay == nil)
                #expect(await f.model.inputs.count == 1)
            } catch { await f.model.releaseStream(); _ = await run.result; throw error }
        }
    }

    @Test func revokedSourceSuppressesPartialOutputWhenTheModelFails() async throws {
        // EOF without a finish event fails after a partial answer has reached the durable draft.
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Partial output from revoked context")))]]) { f in
            let workspace = Workspace(id: .init(), name: "Failed stream workspace")
            try await saveWorkspace(workspace, in: f)
            await f.model.holdStream(number: 1)
            let run = Task { try await f.run("Dispatched before failure", workspaceID: workspace.id, expectedStatus: .interrupted) }
            do {
                try await taskEventually { await f.model.streamHeld }
                try await revoke("workspace", workspace: workspace, in: f)
                await f.model.releaseStream()
                let address = try await run.value
                let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
                let completion = try #require(state.executions[address.executionID]?.completion)
                #expect(completion.answer == nil && completion.visibleThinking == nil && completion.replay == nil)
                #expect(state.attempts.values.first?.resolution?.status == .failed)
            } catch { await f.model.releaseStream(); _ = await run.result; throw error }
        }
    }

    @Test(arguments: [false, true])
    func cancellationPublishesOnlyStillAuthorizedDrafts(revoked: Bool) async throws {
        let partial = String(repeating: "Partial draft. ", count: 400)
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text(partial))), .blockFinished(id: "text"), .finished(.stop)]]) { f in
            let workspace = Workspace(id: .init(), name: "Cancelled stream workspace")
            try await saveWorkspace(workspace, in: f)
            await f.model.holdStream(number: 1, afterEvents: 1)
            let sessionID = ConversationID()
            let run = Task { try await f.run("Cancel after a durable draft", sessionID: sessionID,
                workspaceID: workspace.id, expectedStatus: revoked ? .interrupted : .cancelled) }
            do {
                try await taskEventually { await f.model.streamHeld }
                try await taskEventually {
                    return try await f.library.activeDraft(sessionID: sessionID) != nil
                }
                if revoked { try await revoke("workspace", workspace: workspace, in: f) }
                await f.runtime.cancel(sessionID: sessionID)
                await f.model.releaseStream()
                let address = try await run.value
                let state = try await f.runtime.sessionSnapshot(id: sessionID)
                let completion = try #require(state.executions[address.executionID]?.completion)
                #expect(completion.replay == nil)
                if revoked {
                    #expect(completion.answer == nil && completion.visibleThinking == nil)
                } else {
                    let answer = try #require(completion.answer)
                    #expect(try await f.library.read(answer) == Data(partial.utf8))
                }
                #expect(await f.model.inputs.count == 1)
            } catch { await f.model.releaseStream(); _ = await run.result; throw error }
        }
    }

    @Test func updatedTaskRetainsItsAuthorizedHistoricalRevisionInReplay() async throws {
        let call = CanonicalToolCall(id: "list", name: "task.list", arguments: "{}")
        try await withTaskWorkflow(outputs: [modelToolStream([call]),
            [.blockStarted(.init(id: "text", content: .text("Answer using a historical task"))), .blockFinished(id: "text"), .finished(.stop)]]) { f in
            let task = try await f.save(draft: .init(title: "Original task"))
            await f.model.holdStream(number: 2)
            let sessionID = ConversationID()
            let run = Task { try await f.run("List current tasks", sessionID: sessionID, expectedStatus: .completed) }
            do {
                try await taskEventually { await f.model.streamHeld }
                _ = try await f.save(id: task.id, draft: .init(title: "Updated task"), expectedRevision: task.revision)
                await f.model.releaseStream()
                let address = try await run.value
                let state = try await f.runtime.sessionSnapshot(id: sessionID)
                let completion = try #require(state.executions[address.executionID]?.completion)
                #expect(completion.answer != nil && completion.replay != nil)
                let attemptID = try #require(state.executions[address.executionID]?.attemptIDs.last)
                let reference = try #require(state.attempts[attemptID]?.attempt.request)
                let build = try await AgentRequestRecord.read(reference, payloads: f.library)
                #expect(build.request.destination == .model(f.route))
                #expect(build.sources.contains(.domain(namespace: "tasks", id: task.id.rawValue, revision: task.revision)))
                await f.model.append([[.blockStarted(.init(id: "text", content: .text("Fresh answer"))), .blockFinished(id: "text"), .finished(.stop)]])
                _ = try await f.run("Continue with fresh context", sessionID: sessionID)
                let input = try #require(await f.model.inputs.last)
                #expect(input.messages.contains { $0.text.contains("Answer using a historical task") })
                #expect(input.messages.flatMap(\.toolResults).contains { $0.text.contains("Original task") })
            } catch { await f.model.releaseStream(); _ = await run.result; throw error }
        }
    }
}

private func saveWorkspace(_ workspace: Workspace, expectedRevision: Int? = nil, in f: TaskWorkflowFixture) async throws {
    let lease = try await f.access.acquire(in: f.scope)
    do { try await f.workspaces.saveWorkspace(workspace, expectedRevision: expectedRevision, authorization: lease.authorization) }
    catch { await lease.release(); throw error }
    await lease.release()
}
private func revoke(_ kind: String, workspace: Workspace, in f: TaskWorkflowFixture) async throws {
    if kind == "workspace" {
        var updated = workspace; updated.revision += 1; updated.allowsRemoteSend = false
        try await saveWorkspace(updated, expectedRevision: workspace.revision, in: f)
    } else {
        let current = try #require(try await f.settings.connection(id: f.route.connectionID))
        try await f.settings.saveConnection(.init(id: current.id, revision: current.revision + 1,
            configurationRevision: current.configurationRevision + 1, name: current.name, isEnabled: false,
            definitionID: current.definitionID, endpoints: current.endpoints, discovery: current.discovery,
            defaultInvocation: current.defaultInvocation), expectedRevision: current.revision,
            authorization: f.authority.authorization())
    }
}
