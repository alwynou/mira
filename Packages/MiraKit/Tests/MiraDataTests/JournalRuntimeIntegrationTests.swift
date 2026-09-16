import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Durable session runtime integration")
struct JournalRuntimeIntegrationTests {
    @Test func admissionAndThinkingDraftRecoverFromRealJournal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-runtime-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try FileSessionLibrary(directory: directory)
        let sessionID = ConversationID(), executionID = ExecutionID(), attemptID = UUID()
        let runtime = try await SessionRuntime.open(id: sessionID, journal: library, payloads: library)
        let admission = await runtime.commit(id: UUID()) { context in
            let title = try await context.stageBytes(Data("Synthetic title".utf8), kind: .title, retentionGroup: UUID())
            let user = try await context.stageBytes(Data("Synthetic question".utf8), kind: .userText, retentionGroup: UUID())
            let route = try await context.stageBytes(Data("Synthetic route".utf8), kind: .executionPlan, retentionGroup: UUID())
            return [.opened(.init(workspaceID: nil, title: title)),
                    .admitted(.init(executionID: executionID, userMessageID: MessageID(),
                        userBody: user, plan: route, hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
        }
        guard case .committed = admission else { Issue.record("Admission failed"); return }
        let started = await runtime.commit(id: UUID()) { context in
            let request = try await context.stageBytes(Data("Synthetic request".utf8), kind: .request, retentionGroup: UUID())
            return [.phaseChanged(executionID: executionID, phase: .preparing),
                    .attemptStarted(.init(id: attemptID, executionID: executionID, stepID: UUID(),
                        stepIndex: 1, attemptIndex: 1, request: request))]
        }
        guard case .committed = started else { Issue.record("Attempt preparation failed"); return }
        let requestValue = await runtime.snapshot().attempts[attemptID]?.attempt.request
        let request = try #require(requestValue)
        try await runtime.saveActiveDraft(.init(request: request, executionID: executionID, attemptID: attemptID,
            authorizationEpoch: 0, revision: 1,
            blocks: [.init(id: "thinking", content: .thinking("Synthetic partial thinking"))]))
        let original = await runtime.snapshot()
        let draftValue = try await library.activeDraft(sessionID: sessionID)
        let draft = try #require(draftValue)
        await runtime.close(); try await library.close()
        let reopenedLibrary = try FileSessionLibrary(directory: directory)
        let reopened = try await SessionRuntime.open(id: sessionID, journal: reopenedLibrary, payloads: reopenedLibrary)
        #expect(await reopened.snapshot() == original)
        #expect(try await reopenedLibrary.activeDraft(sessionID: sessionID) == draft)
        let settlement = await reopened.commit(id: UUID()) { _ in
            [.phaseChanged(executionID: executionID, phase: .cancelling),
             .attemptResolved(.init(attemptID: attemptID, status: .interrupted)),
             .finished(.init(executionID: executionID, status: .interrupted))]
        }
        guard case .committed = settlement else { Issue.record("Recovered interruption failed"); return }
        #expect(await reopened.snapshot().activeExecutionID == nil)
        await reopened.close(); try await reopenedLibrary.close()
    }

    @Test func exclusivePayloadPublicationNeverOverwritesExistingBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-publication-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source"), destination = directory.appendingPathComponent("destination")
        try Data("new".utf8).write(to: source)
        try Data("owned".utf8).write(to: destination)
        #expect(throws: MiraError.self) { try FileSessionIO.publishExclusive(source, to: destination) }
        #expect(try Data(contentsOf: source) == Data("new".utf8))
        #expect(try Data(contentsOf: destination) == Data("owned".utf8))
    }
}
