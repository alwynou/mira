import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Durable session runtime integration")
struct JournalRuntimeIntegrationTests {
    @Test func admissionAndInterruptedAttemptRecoverFromRealJournal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-runtime-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try FileSessionLibrary(directory: directory)
        let sessionID = ConversationID(), executionID = ExecutionID(), attemptID = UUID()
        let route = AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
            modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1,
            adapter: .init(id: "synthetic.model", revision: 1), invocationID: "synthetic-invocation",
            invocationRevision: 1, endpointID: "synthetic-endpoint", modelID: "synthetic",
            credential: nil, contextWindow: 4096, maximumOutputTokens: 128,
            capabilities: .init(streamsText: true, callsTools: false, producesThinking: true), configuration: .object([:]))
        let runtime = try await SessionRuntime.open(id: sessionID, journal: library, payloads: library)
        let admission = await runtime.commit(id: UUID()) { context in
            let title = try await context.stageBytes(Data("Synthetic title".utf8), kind: .title)
            let user = try await context.stageBytes(Data("Synthetic question".utf8), kind: .userText)
            let planValue = AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 1, driverID: "mira.default",
                driverRevision: 1, instructions: "Answer.", limits: .init(), priority: .foreground, route: route)
            let plan = try await context.stage(planValue, kind: .executionPlan)
            let messageID = MessageID()
            return [.opened(.init(workspaceID: nil, title: title)),
                    .admitted(.init(executionID: executionID, userMessageID: messageID,
                        userBody: user, plan: plan, hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
        }
        guard case .committed = admission else { Issue.record("Admission failed"); return }
        let started = await runtime.commit(id: UUID()) { context in
            let build = AgentContextBuild(
                request: .init(sessionID: sessionID, executionID: executionID, workspaceID: nil,
                    userText: "Synthetic question", authorizationEpoch: 0, destination: .model(route)),
                prepared: .init(adapter: route.adapter,
                    input: .init(stepID: attemptID, executionID: executionID, instructions: "Answer.",
                        messages: [.init(role: .user, blocks: [.init(id: "user", content: .text("Synthetic question"))])], tools: []),
                    wirePayload: .object(["prompt": .string("Synthetic question")]), estimatedInputTokens: 1),
                inheritedSources: [], evidence: [], omissions: [])
            let request = try await context.stage(AgentSessionRequest(build), kind: .request)
            return [.phaseChanged(executionID: executionID, phase: .preparing),
                    .attemptStarted(.init(id: attemptID, executionID: executionID, stepID: attemptID,
                        stepIndex: 1, attemptIndex: 1, request: request))]
        }
        guard case .committed = started else { Issue.record("Attempt preparation failed"); return }
        let original = await runtime.snapshot()
        await runtime.close(); try await library.close()
        let reopenedLibrary = try FileSessionLibrary(directory: directory)
        let reopened = try await SessionRuntime.open(id: sessionID, journal: reopenedLibrary, payloads: reopenedLibrary)
        #expect(await reopened.snapshot() == original)
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
