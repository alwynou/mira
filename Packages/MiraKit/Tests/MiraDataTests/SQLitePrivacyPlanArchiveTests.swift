import CryptoKit
import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Session privacy plan archives", .timeLimit(.minutes(1)))
struct SQLitePrivacyPlanArchiveTests {
    @Test(arguments: ["valid", "head", "batch", "dependency", "dependencyPrefix", "missing"])
    func validatesCompletedPlanAgainstActualJournal(_ mutation: String) async throws {
        try await withTaskWorkflow(outputs: [
            [.blockStarted(.init(id: "text", content: .text("A synthetic answer"))), .blockFinished(id: "text"), .finished(.stop)], [.blockStarted(.init(id: "text", content: .text("Another answer"))), .blockFinished(id: "text"), .finished(.stop)],
        ]) { fixture in
            let address = try await fixture.run("A synthetic source")
            let unrelated = try await fixture.run("Another source")
            _ = await fixture.runtime.shutdown()
            let authority = try SQLiteLibraryAuthority(
                database: fixture.database,
                validators: [
                    .init(identity: .init(namespace: "archive.privacy", revision: 1), validate: { _, _ in })
                ])
            let plans = try SQLiteSessionPrivacyPlanStore(database: fixture.database, libraryID: authority.libraryID)
            do {
                let operation = try await authority.begin(
                    .init(
                        id: UUID(), namespace: "archive.privacy", revision: 1,
                        scope: .library, requestedAt: TaskWorkflowFixture.now), expected: authority.authorization())
                let maintenance = SessionPrivacyMaintenance(
                    journal: fixture.library, payloads: fixture.library, plans: plans)
                let plan = try await maintenance.prepare(
                    operation: operation,
                    roots: [.sessionExecution(sessionID: address.sessionID, executionID: address.executionID)],
                    retention: .preserveVisibleHistory, reason: .forgotten)
                #expect(plan.changes.count == 1)
                try await maintenance.apply(operation: operation)
                try await maintenance.verify(operation: operation)
                _ = try await authority.complete(operation, at: TaskWorkflowFixture.now)
                var heads = plan.heads
                var changes = plan.changes
                if mutation == "head" { heads[0] = .init(cursor: heads[0].cursor, batchID: UUID()) }
                if mutation == "batch" {
                    let old = changes[0].batch
                    changes[0] = .init(
                        batch: .init(
                            id: UUID(), sessionID: old.sessionID,
                            expectedSequence: old.expectedSequence, events: old.events),
                        dependencies: changes[0].dependencies)
                }
                if mutation == "dependency" {
                    changes[0] = .init(
                        batch: changes[0].batch,
                        dependencies: [
                            .init(
                                executionID: address.executionID,
                                sources: [.sessionExecution(sessionID: .init(), executionID: .init())])
                        ])
                }
                if mutation == "dependencyPrefix" {
                    heads.removeAll { $0.cursor.sessionID == unrelated.sessionID }
                    changes[0] = .init(
                        batch: changes[0].batch,
                        dependencies: [
                            .init(
                                executionID: address.executionID,
                                sources: [
                                    .sessionExecution(
                                        sessionID: unrelated.sessionID, executionID: unrelated.executionID)
                                ])
                        ])
                }
                if ["head", "batch", "dependency", "dependencyPrefix"].contains(mutation) {
                    let changed = SessionPrivacyPlan(
                        operation: plan.operation, roots: plan.roots,
                        retention: plan.retention, reason: plan.reason, heads: heads, changes: changes)
                    try changed.validate()
                    let bytes = try SessionCodec.encode(changed)
                    try await fixture.database.write { db in
                        try db.execute(
                            sql: "UPDATE session_privacy_plans SET byte_count = ?, digest = ?, plan_json = ?",
                            arguments: [
                                bytes.count, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                                bytes,
                            ])
                    }
                } else if mutation == "missing" {
                    try await fixture.database.write { try $0.execute(sql: "DELETE FROM session_privacy_plans") }
                }
                let module = try SQLiteSessionPrivacyPlanStore.archiveModule()
                if mutation == "valid" {
                    try await fixture.library.withSnapshot { snapshot in
                        try fixture.database.read { db in _ = try module.inspect(db, snapshot) }
                    }
                } else {
                    await #expect(throws: MiraError.self) {
                        try await fixture.library.withSnapshot { snapshot in
                            try fixture.database.read { db in _ = try module.inspect(db, snapshot) }
                        }
                    }
                }
                await plans.close()
                await authority.close()
            } catch {
                await plans.close()
                await authority.close()
                throw error
            }
        }
    }
}
