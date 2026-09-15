import Foundation
import MiraCore
import MiraData

enum CrashProbeBusiness {
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
            throw MiraError(.conflict, "The business crash boundary was missed.")
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
            let before = try await JournalSessionReader(journal: fixture.journal, payloads: fixture.library)
                .snapshot(sessionID: execution.sessionID).state
            guard before.invocations.count == 1, let invocation = before.invocations.values.first,
                let intent = invocation.intent
            else { throw MiraError(.storage, "The interrupted invocation proof is missing.") }
            let proof = AgentEffectProof(
                sessionID: execution.sessionID, executionID: execution.executionID,
                invocationID: invocation.invocation.id, intentBatchID: intent.batchID, intentSequence: intent.sequence,
                authorization: intent.intent.authorization, proposal: intent.intent.proposal)
            guard case .committed(let originalReceipt) = await fixture.business.receipt(for: proof) else {
                throw MiraError(.storage, "The committed business receipt did not survive termination.")
            }
            try probeRequire(
                try await fixture.count("business") == 1, "The original transaction did not commit exactly once.")
            try probeRequire(
                try await fixture.count("model") == 1, "The crash boundary was reached after an unexpected model call.")
            if before.executions[execution.executionID]?.completion == nil {
                let pending = try await fixture.business.unpublished(after: nil, limit: 10)
                try probeRequire(
                    pending.count == 1 && pending[0].receipt.reference == originalReceipt.reference,
                    "The unacknowledged receipt did not survive termination.")
                if scenario == "businessCommitted" {
                    try probeRequire(
                        invocation.resolution == nil, "The pre-publication crash already had a journal result.")
                } else {
                    try probeRequire(
                        invocation.resolution?.businessReceipt == originalReceipt.reference,
                        "The published journal result lost its original receipt.")
                }
            }
            let app = try await fixture.openApplication()
            application = app
            try probeCommit(await app.waitForExecution(id: execution.executionID, sessionID: execution.sessionID))
            let recovered = try await app.sessionSnapshot(id: execution.sessionID)
            try probeRequire(
                recovered.executions[execution.executionID]?.completion?.status == .interrupted,
                "Startup did not settle the interrupted execution.")
            let result = recovered.invocations[invocation.invocation.id]?.resolution
            try probeRequire(
                result?.status == .succeeded && result?.businessReceipt == originalReceipt.reference,
                "Recovery did not reuse the durable business receipt.")
            let outstandingReceipts = try await fixture.business.unpublished(after: nil, limit: 10).count
            try probeRequire(outstandingReceipts == 0, "Recovery left a receipt unacknowledged.")
            let settledInvocations = recovered.invocations.values.filter { $0.resolution != nil }.count
            try probeRequire(
                recovered.invocations.count == 1 && settledInvocations == 1,
                "Recovery changed the number of settled invocations.")
            let businessWrites = try await fixture.count("business")
            let modelCalls = try await fixture.count("model")
            try probeRequire(
                businessWrites == 1 && modelCalls == 1,
                "Recovery dispatched the model or business handler again.")
            try probeRequire(await app.shutdown().isSettled, "Recovered application shutdown did not settle.")
            application = nil
            try await fixture.close()
            return [
                "businessWrites": businessWrites, "modelCalls": modelCalls,
                "outstandingReceipts": outstandingReceipts, "settledInvocations": settledInvocations,
                "journalSequence": Int(recovered.sequence),
            ]
        } catch {
            _ = await application?.shutdown()
            try? await fixture.close()
            throw error
        }
    }
}
