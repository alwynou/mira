import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Journal provenance for local domain citations")
struct RecordedContextSourcesTests {
    @Test func successfulReplyProvesOnlyItsRecordedExactDomainRevision() async throws {
        let replies: [[AgentModelStreamEvent]] = [
            modelToolStream([.init(id: "list", name: "task.list", arguments: "{}")]),
            [.blockStarted(.init(id: "text", content: .text("Recorded task answer"))), .blockFinished(id: "text"), .finished(.stop)]
        ]
        try await withTaskWorkflow(outputs: replies) { f in
            let task = try await f.save(draft: .init(title: "A source used by the reply"))
            let address = try await f.run("List tasks")
            let reader = JournalSessionReader(journal: f.library, payloads: f.library)
            let lease = try await f.access.acquire(in: f.scope)
            do {
                let evidence = try await lease.read {
                    try await reader.recordedContextEvidence(sessionID: address.sessionID, executionID: address.executionID)
                }
                #expect(evidence.sources == [.domain(namespace: "tasks", id: task.id.rawValue, revision: 1)])
                #expect(evidence.workspaceID == nil)
                _ = try await f.save(id: task.id, draft: .init(title: "A later wording revision"), expectedRevision: 1)
                #expect(try await lease.read {
                    try await reader.recordedContextEvidence(sessionID: address.sessionID, executionID: address.executionID)
                }.sources == evidence.sources)
                await #expect(throws: MiraError.self) {
                    _ = try await reader.recordedContextEvidence(sessionID: .init(), executionID: address.executionID)
                }
                await lease.release()
            } catch { await lease.release(); throw error }
        }
    }

    @Test func failedReplyCannotGrantCitationAccess() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("A partial reply without successful completion")))]]) { f in
            let address = try await f.run("Reply", expectedStatus: .failed)
            let reader = JournalSessionReader(journal: f.library, payloads: f.library)
            let lease = try await f.access.acquire(in: f.scope)
            do {
                await #expect(throws: MiraError.self) {
                    _ = try await lease.read {
                        try await reader.recordedContextEvidence(sessionID: address.sessionID, executionID: address.executionID)
                    }
                }
                await lease.release()
            } catch { await lease.release(); throw error }
        }
    }
}
