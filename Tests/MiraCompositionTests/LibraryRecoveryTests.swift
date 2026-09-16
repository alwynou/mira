import Foundation
import MiraData
import Testing

@testable import MiraCore

@Suite("macOS library startup recovery", .timeLimit(.minutes(1)))
struct LibraryRecoveryTests {
    @Test func pendingMaintenancePreservesUnrelatedDraftsButStillSuppressesRevokedSources() async throws {
        try await withDirectory { directory in
            let storage = try await MacLibraryStorage.open(embeddings: OfflineMemoryEmbedding(), directory: directory)
            var addresses: [AgentExecutionAddress] = []
            do {
                let authorization = try await storage.authority.authorization()
                let retained = try await storage.memories.createMemory(
                    draft: .init(content: "Retained synthetic fact", scope: .global),
                    source: .manualEntry(id: UUID(), statement: "Retained synthetic fact"),
                    operationID: UUID(), replacing: nil, expectedRevision: nil, authorization: authorization, at: Date()
                ).memory
                let removed = try await storage.memories.createMemory(
                    draft: .init(content: "Removed synthetic fact", scope: .global),
                    source: .manualEntry(id: UUID(), statement: "Removed synthetic fact"),
                    operationID: UUID(), replacing: nil, expectedRevision: nil, authorization: authorization, at: Date()
                ).memory
                _ = try await storage.memories.changeMemoryState(
                    removed.id, workspaceID: nil, state: .removed,
                    expectedRevision: removed.revision, operationID: UUID(), authorization: authorization, at: Date())
                for sources: [AgentSourceReference] in [
                    [.domain(namespace: "memories", id: retained.id.rawValue, revision: retained.revision)],
                    [], [.domain(namespace: "memories", id: removed.id.rawValue, revision: removed.revision)],
                ] {
                    addresses.append(try await stageInterruptedDraft(storage.sessions, sources: sources))
                }
                _ = try await storage.authority.begin(
                    .init(
                        id: UUID(), namespace: "knowledge.collect", revision: 1,
                        scope: .library, requestedAt: Date()), expected: authorization)
                #expect(await storage.close() == nil)
            } catch {
                _ = await storage.close()
                throw error
            }

            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: directory, notifications: CompositionNotifications(), credentials: CompositionCredentials(), modules: { _ in [] })
            #expect(await library.status().phase == .ready)
            #expect(await library.pendingMaintenance() == nil)
            #expect(await library.close().isSettled)
            let reopened = try await MacLibraryStorage.open(embeddings: OfflineMemoryEmbedding(), directory: directory)
            do {
                for (index, address) in addresses.enumerated() {
                    let reader = JournalSessionReader(journal: reopened.sessions, payloads: reopened.sessions)
                    let state = try await reader.snapshot(sessionID: address.sessionID).state
                    #expect(state.activeExecutionID == nil)
                    let completion = try #require(state.executions[address.executionID]?.completion)
                    #expect(completion.status == .interrupted)
                    if index == 2 {
                        #expect(completion.answer == nil)
                        #expect(completion.visibleThinking == nil)
                    } else {
                        let answer = try #require(completion.answer)
                        let thinking = try #require(completion.visibleThinking)
                        #expect(try await reopened.sessions.read(answer) == Data("Interrupted answer".utf8))
                        #expect(try await reopened.sessions.read(thinking) == Data("Interrupted thinking".utf8))
                    }
                }
                #expect(await reopened.close() == nil)
            } catch {
                _ = await reopened.close()
                throw error
            }
        }
    }
}

/// Simulates a process stopping after real journal admission, attempt and draft commits.
/// No model adapter or compatibility fixture is used to manufacture canonical state.
private func stageInterruptedDraft(_ sessions: FileSessionLibrary, sources: [AgentSourceReference]) async throws
    -> AgentExecutionAddress
{
    let address = AgentExecutionAddress(sessionID: .init(), executionID: .init())
    let runtime = try await SessionRuntime.open(id: address.sessionID, journal: sessions, payloads: sessions)
    let route = AgentModelRoute(
        id: .init(), revision: 1, connectionID: .init(), connectionRevision: 1,
        modelDescriptorID: .init(), modelRevision: 1, modelAuthorizationRevision: 1,
        adapter: .init(id: "tests.restoration", revision: 1), invocationID: "default",
        invocationRevision: 1, endpointID: "primary", metadataEvidence: [],
        modelID: "synthetic", credential: nil, contextWindow: 8_192, maximumOutputTokens: 1_024,
        capabilities: .init(streamsText: true, callsTools: false, producesThinking: true), configuration: .object([:]))
    do {
        try committed(
            await runtime.commit(id: UUID()) { context in
                let title = try await context.stageBytes(
                    Data("Interrupted session".utf8), kind: .title, retentionGroup: UUID())
                let user = try await context.stageBytes(
                    Data("Synthetic question".utf8), kind: .userText, retentionGroup: UUID())
                let plan = AgentExecutionPlan(
                    runtimeID: UUID(), catalogGeneration: 1, driverID: "mira.default", driverRevision: 1,
                    instructions: "Synthetic instructions", limits: .init(), priority: .foreground, route: route)
                let reference = try await context.stage(plan, kind: .executionPlan, retentionGroup: UUID())
                return [
                    .opened(.init(workspaceID: nil, title: title)),
                    .admitted(
                        .init(
                            executionID: address.executionID, userMessageID: .init(), userBody: user,
                            plan: reference, hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC")),
                ]
            })
        let attemptID = UUID()
        let stepID = UUID()
        try committed(
            await runtime.commit(id: UUID()) { context in
                let request = AgentContextRequest(
                    sessionID: address.sessionID, executionID: address.executionID,
                    workspaceID: nil, userText: "Synthetic question", authorizationEpoch: 0, destination: .model(route))
                let input = AgentModelInput(
                    stepID: stepID, executionID: address.executionID, instructions: "Synthetic instructions",
                    messages: [.init(role: .user, blocks: [.init(id: "user", content: .text("Synthetic question"))])], tools: [])
                let build = AgentContextBuild(
                    request: request,
                    prepared: .init(
                        adapter: route.adapter, input: input, wirePayload: .object([:]), estimatedInputTokens: 1),
                    inheritedSources: sources, evidence: [], omissions: [])
                let reference = try await context.stage(build, kind: .request, retentionGroup: UUID())
                return [
                    .phaseChanged(executionID: address.executionID, phase: .preparing),
                    .attemptStarted(
                        .init(
                            id: attemptID, executionID: address.executionID, stepID: stepID,
                            stepIndex: 1, attemptIndex: 1, request: reference)),
                ]
            })
        try committed(
            await runtime.commit(id: UUID()) { context in
                var facts: [SessionFact] = []
                for (part, text): (SessionDraftPart, String) in [
                    (.answer, "Interrupted answer"), (.thinking, "Interrupted thinking"),
                ] {
                    let bytes = Data(text.utf8)
                    let reference = try await context.stageBytes(bytes, kind: .draft, retentionGroup: UUID())
                    facts.append(
                        .draftCheckpoint(
                            .init(
                                executionID: address.executionID, attemptID: attemptID,
                                part: part, baseSequence: nil, prefixByteCount: 0, suffixByteCount: 0,
                                replacement: reference, resultByteCount: bytes.count)))
                }
                return facts
            })
        await runtime.close()
        return address
    } catch {
        await runtime.close()
        throw error
    }
}
