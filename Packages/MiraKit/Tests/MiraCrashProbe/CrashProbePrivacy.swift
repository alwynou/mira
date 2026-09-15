import Foundation
import GRDB
import MiraCore
import MiraData

enum CrashProbePrivacy {
    private struct Visible: Codable, Sendable {
        let reference: SessionPayloadReference
        let bytes: Data
    }
    private struct Input: Codable, Sendable {
        let scenario: String
        let execution: ProbeExecution
        let operation: AgentLibraryMaintenanceOperation
        let plan: SessionPrivacyPlan
        let hidden: [SessionPayloadReference]
        let visible: [Visible]
    }

    static func crash(_ context: CrashProbeContext, scenario: String) async throws {
        let fixture = try await CrashProbeFixture.open(context)
        var application: AgentApplicationRuntime?
        var plans: SQLiteSessionPrivacyPlanStore?
        var results: SQLiteBusinessPrivacyStore?
        do {
            let execution = try await fixture.newExecution()
            let app = try await fixture.openApplication()
            application = app
            try probeCommit(await app.submit(execution.command))
            try probeCommit(await app.waitForExecution(id: execution.executionID, sessionID: execution.sessionID))
            let state = try await app.sessionSnapshot(id: execution.sessionID)
            try probeRequire(
                state.executions[execution.executionID]?.completion?.status == .completed,
                "The privacy probe seed did not complete.")
            let hidden = state.references.values.filter {
                ![.title, .userText, .visibleAnswer, .visibleThinking].contains($0.kind)
            }
            try probeRequire(
                Set(hidden.map(\.kind)).isSuperset(of: [
                    .request, .modelOutput, .toolCall, .effectIntent, .toolResult, .replay, .executionPlan,
                ]),
                "The privacy seed did not exercise the actual model and tool pipeline.")
            var visible: [Visible] = []
            for reference in state.references.values where [.userText, .visibleAnswer].contains(reference.kind) {
                visible.append(.init(reference: reference, bytes: try await fixture.library.read(reference)))
            }
            try probeRequire(visible.count == 2, "The privacy seed has an unexpected visible history.")
            try probeRequire(await app.shutdown().isSettled, "The privacy seed did not drain.")
            application = nil
            let roots: [AgentSourceReference] = [
                .sessionExecution(sessionID: execution.sessionID, executionID: execution.executionID)
            ]
            let request = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: "crash.privacy", revision: 1,
                scope: .sources(roots), requestedAt: CrashProbeFixture.now)
            let operation = try await fixture.access.begin(request, expected: fixture.authority.authorization())
            let p = try SQLiteSessionPrivacyPlanStore(
                database: fixture.database, libraryID: fixture.authority.libraryID)
            plans = p
            let r = try SQLiteBusinessPrivacyStore(database: fixture.database, libraryID: fixture.authority.libraryID)
            results = r
            let engine = SessionPrivacyMaintenance(journal: fixture.journal, payloads: fixture.library, plans: p)
            let plan = try await engine.prepare(
                operation: operation, roots: roots, retention: .preserveVisibleHistory, reason: .forgotten)
            try await r.purgeSessionResults(plan: plan)
            try context.save(
                Input(
                    scenario: scenario, execution: execution, operation: operation, plan: plan, hidden: hidden,
                    visible: visible))
            fixture.gate.arm(scenario)
            try await engine.apply(operation: operation)
            throw MiraError(.conflict, "The privacy crash boundary was missed.")
        } catch {
            _ = await application?.shutdown()
            await plans?.close()
            await results?.close()
            try? await fixture.close()
            throw error
        }
    }

    static func verify(_ context: CrashProbeContext, scenario: String) async throws -> [String: Int] {
        let input = try context.load(Input.self)
        try probeRequire(input.scenario == scenario, "The privacy probe input changed.")
        let fixture = try await CrashProbeFixture.open(context)
        var plans: SQLiteSessionPrivacyPlanStore?
        var results: SQLiteBusinessPrivacyStore?
        do {
            guard let storedOperation = try await fixture.authority.operation(id: input.operation.request.id) else {
                throw MiraError(.storage, "The original privacy operation is missing.")
            }
            if storedOperation.completedAt == nil {
                try probeRequire(
                    try await fixture.authority.state().pending == input.operation,
                    "The pending privacy operation changed.")
                var accessBlocked = false
                do { try await fixture.access.checkReady() } catch { accessBlocked = true }
                try probeRequire(accessBlocked, "Pending maintenance allowed ordinary access.")
                let p = try SQLiteSessionPrivacyPlanStore(
                    database: fixture.database, libraryID: fixture.authority.libraryID)
                plans = p
                let r = try SQLiteBusinessPrivacyStore(
                    database: fixture.database, libraryID: fixture.authority.libraryID)
                results = r
                try probeRequire(
                    try await p.load(operation: input.operation) == input.plan,
                    "Recovery changed the immutable privacy plan.")
                let engine = SessionPrivacyMaintenance(journal: fixture.journal, payloads: fixture.library, plans: p)
                try await r.purgeSessionResults(plan: input.plan)
                try await engine.apply(operation: input.operation)
                try await engine.apply(operation: input.operation)
                try await engine.verify(operation: input.operation)
                try await r.verifySessionResultsPurged(plan: input.plan)
                _ = try await fixture.access.complete(input.operation, at: CrashProbeFixture.now)
            }
            try await fixture.access.checkReady()
            try probeRequire(
                try await fixture.authority.state().pending == nil, "Privacy recovery did not return to ready.")
            try await fixture.library.verifyPurged(
                sessionID: input.execution.sessionID, retentionGroups: Set(input.hidden.map(\.retentionGroup)))
            try await fixture.library.verifyNoUnpublished()
            for item in input.visible {
                try probeRequire(
                    try await fixture.library.read(item.reference) == item.bytes,
                    "Allowed visible history changed during privacy recovery.")
            }
            let state = try await JournalSessionReader(journal: fixture.journal, payloads: fixture.library)
                .snapshot(sessionID: input.execution.sessionID).state
            try probeRequire(
                state.excludedExecutionIDs == [input.execution.executionID],
                "The retained reply regained replay eligibility.")
            let remainingBusinessBodies = try await fixture.database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM business_operations WHERE result_blob IS NOT NULL")
                    ?? -1
            }
            try probeRequire(remainingBusinessBodies == 0, "Privacy recovery retained a business result body.")
            try probeRequire(try await fixture.count("model") == 2, "Privacy recovery dispatched a model request.")
            let hiddenCount = input.hidden.filter { reference in
                let url = fixture.context.journalDirectory.appendingPathComponent("payloads")
                    .appendingPathComponent(reference.sessionID.rawValue.uuidString).appendingPathComponent(
                        reference.batchID.uuidString
                    )
                    .appendingPathComponent(reference.id.uuidString + ".bin")
                return FileManager.default.fileExists(atPath: url.path)
            }.count
            try probeRequire(hiddenCount == 0, "Hidden physical payload files survived recovery.")
            await plans?.close()
            await results?.close()
            try await fixture.close()
            return [
                "hiddenBodies": hiddenCount, "retainedBodies": input.visible.count, "maintenancePending": 0,
                "businessResultBodies": remainingBusinessBodies, "journalSequence": Int(state.sequence),
            ]
        } catch {
            await plans?.close()
            await results?.close()
            try? await fixture.close()
            throw error
        }
    }
}
