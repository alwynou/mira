import Foundation
import MiraCore
import MiraData

enum CrashProbeExecution {
    static func crash(_ context: CrashProbeContext, scenario: String) async throws {
        let fixture = try await CrashProbeFixture.open(context)
        var application: AgentApplicationRuntime?
        do {
            let execution = try await fixture.newExecution()
            try context.save(execution)
            let app = try await fixture.openApplication()
            application = app
            fixture.gate.arm(scenario)
            try probeCommit(await app.submit(execution.command))
            try probeCommit(await app.waitForExecution(id: execution.executionID, sessionID: execution.sessionID))
            throw MiraError(.conflict, "The execution crash boundary was missed.")
        } catch {
            _ = await application?.shutdown()
            try? await fixture.close()
            throw error
        }
    }

    static func verify(_ context: CrashProbeContext, scenario: String) async throws -> [String: Int] {
        let execution = try context.load(ProbeExecution.self)
        let fixture = try await CrashProbeFixture.open(context)
        var application: AgentApplicationRuntime?
        do {
            let reader = JournalSessionReader(journal: fixture.journal, payloads: fixture.library)
            if scenario == "thinkingDraft" {
                let batches = try await fixture.journal.read(sessionID: execution.sessionID, after: 0, limit: 128)
                guard
                    let draftBatch = batches.last(where: { batch in
                        batch.events.contains { event in
                            if case .draftCheckpoint(let value) = event.fact { return value.part == .transcript }
                            return false
                        }
                    })
                else { throw MiraError(.storage, "The process did not stop after a durable thinking draft.") }
                let prefix = try await reader.snapshot(
                    through: .init(cursor: draftBatch.cursor, batchID: draftBatch.id)
                ).state
                let drafts = try await SessionDraftReader(journal: fixture.journal, payloads: fixture.library)
                    .read(state: prefix, executionID: execution.executionID)
                try probeRequire(
                    drafts[.thinking] == Data(CrashProbeFixture.interruptedThought.utf8),
                    "The durable thinking text changed.")
                guard let transcript = drafts[.transcript],
                    let continuation = try SessionCodec.decode(JSONValue.self, from: transcript)["continuation"]
                else {
                    throw MiraError(.storage, "The durable draft lost its opaque continuation.")
                }
                let value = try SessionCodec.decode(
                    AgentModelContinuation.self, from: SessionCodec.encode(continuation))
                try probeRequire(
                    value == CrashProbeFixture.interruptedContinuation,
                    "The opaque continuation changed across process termination.")
            }
            let app = try await fixture.openApplication()
            application = app
            try probeCommit(await app.waitForExecution(id: execution.executionID, sessionID: execution.sessionID))
            let state = try await app.sessionSnapshot(id: execution.sessionID)
            guard let completion = state.executions[execution.executionID]?.completion,
                let user = state.executions[execution.executionID]?.admission.userBody
            else {
                throw MiraError(.storage, "Recovery lost the admitted message or terminal state.")
            }
            let expectedStatus: ExecutionStatus = scenario == "terminalPublished" ? .completed : .interrupted
            try probeRequire(completion.status == expectedStatus, "Recovery changed the execution outcome.")
            try probeRequire(
                try await fixture.library.read(user) == Data("Record the synthetic counter.".utf8),
                "Recovery changed the admitted user message.")
            var thinkingBytes = 0
            if scenario == "thinkingDraft" {
                guard let thinking = completion.visibleThinking else {
                    throw MiraError(.storage, "Recovery lost visible thinking.")
                }
                let bytes = try await fixture.library.read(thinking)
                thinkingBytes = bytes.count
                try probeRequire(
                    bytes == Data(CrashProbeFixture.interruptedThought.utf8),
                    "Recovery discarded the latest thinking checkpoint.")
                try probeRequire(
                    completion.answer == nil && completion.replay == nil,
                    "An incomplete thought became replayable assistant history.")
            }
            if scenario == "terminalPublished" {
                guard let answer = completion.answer else {
                    throw MiraError(.storage, "The committed answer was lost.")
                }
                try probeRequire(
                    try await fixture.library.read(answer) == Data("The synthetic counter was recorded.".utf8),
                    "The committed answer changed.")
            }
            try probeCommit(await app.submit(execution.command))
            try probeRequire(
                try await app.sessionSnapshot(id: execution.sessionID) == state,
                "Retrying the original command created new facts.")
            let expectedModels = scenario == "admissionPublished" ? 0 : scenario == "thinkingDraft" ? 1 : 2
            let models = try await fixture.count("model")
            let writes = try await fixture.count("business")
            try probeRequire(
                models == expectedModels && writes == (scenario == "terminalPublished" ? 1 : 0),
                "Recovery dispatched new work.")
            let batches = try await fixture.journal.read(sessionID: execution.sessionID, after: 0, limit: 128)
            let terminals = batches.flatMap(\.events).filter { event in
                if case .finished(let value) = event.fact { return value.executionID == execution.executionID }
                return false
            }.count
            try probeRequire(
                state.executions.count == 1 && terminals == 1, "Recovery duplicated admission or terminal facts.")
            try probeRequire(await app.shutdown().isSettled, "The recovered execution could not close.")
            application = nil
            try await fixture.close()
            return [
                "executions": state.executions.count, "terminalFacts": terminals, "modelCalls": models,
                "businessWrites": writes, "thinkingBytes": thinkingBytes, "journalSequence": Int(state.sequence),
            ]
        } catch {
            _ = await application?.shutdown()
            try? await fixture.close()
            throw error
        }
    }
}
