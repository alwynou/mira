import Foundation
import MiraCore
import MiraData
import MiraProviders
import XCTest

final class EverydayMemoryWaitTests: XCTestCase {
    func testStaleExtractionFailureDoesNotSettleUnrelatedSourceWithoutAJob() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mira-MemoryWait-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = try await MacLibrary.open(
            embeddings: OfflineMemoryEmbedding(), directory: directory,
            notifications: WaitRegressionNotifications(), credentials: WaitRegressionCredentials(),
            modules: { [WaitRegressionModule(registry: $0)] })
        do {
            let group = try await library.workloads()
            let route = try await WaitRegressionRoute.install(in: group)
            let sourceSession = ConversationID()
            var executions: [ExecutionID] = []
            let turns = [
                "Synthetic completed turn one.",
                "Synthetic completed turn two.",
                "Synthetic completed turn three.",
                "Synthetic completed turn four."
            ]
            for (index, text) in turns.enumerated() {
                let command = Self.command(
                    sessionID: sourceSession, route: route, text: text,
                    opening: index == 0 ? .init(title: "Memory wait regression", workspaceID: nil) : nil)
                executions.append(command.executionID)
                guard case .committed = await group.application.submit(command),
                      case .committed = await group.application.waitForExecution(
                        id: command.executionID, sessionID: sourceSession) else {
                    throw MiraError(.storage, "A synthetic source conversation did not complete.")
                }
            }

            await group.wake()
            try await Self.waitForTerminalExtractionFailure(
                in: group, sessionID: sourceSession, executionIDs: executions, timeout: 15)
            let staleFailure = await group.status().failures["extraction"]
            XCTAssertNotNil(staleFailure, "The first source must leave a visible extraction failure.")

            let unrelatedSession = ConversationID()
            let unrelated = Self.command(
                sessionID: unrelatedSession, route: route, text: "A separate one-turn source.",
                opening: .init(title: "Unrelated memory wait source", workspaceID: nil))
            guard case .committed = await group.application.submit(unrelated),
                  case .committed = await group.application.waitForExecution(
                    id: unrelated.executionID, sessionID: unrelatedSession) else {
                throw MiraError(.storage, "The unrelated synthetic source did not complete.")
            }
            await group.wake()
            let page = try await group.memories.extractionStatus(
                sessionID: unrelatedSession, executionID: unrelated.executionID, workspaceID: nil,
                before: nil, limit: 16)
            XCTAssertTrue(page.jobs.isEmpty, "A single turn must not create an extraction job immediately.")
            let failureBeforeWait = await group.status().failures["extraction"]
            XCTAssertEqual(failureBeforeWait?.code, .invalidInput,
                           "The stale failure must still be present when the waiter starts.")

            let result = try await EverydayMemoryLiveTests.waitForMemory(
                in: group, sourceSession: unrelatedSession,
                sourceExecution: unrelated.executionID, timeout: 0.25)
            XCTAssertEqual(result.state, "unavailable")
            XCTAssertNil(result.errorCode, "A prior source's workload failure cannot settle this source.")
            XCTAssertTrue(result.memories.isEmpty)

            let closeResult = await library.close()
            XCTAssertTrue(closeResult.isSettled)
        } catch {
            _ = await library.close()
            throw error
        }
    }

    private static func command(
        sessionID: ConversationID, route: AgentModelRoute, text: String,
        opening: AgentSessionOpening?
    ) -> AgentSubmitCommand {
        .init(id: UUID(), sessionID: sessionID, executionID: .init(),
              input: .message(id: .init(), text: text, timeZoneIdentifier: "UTC"),
              options: .init(instructions: "Synthetic offline test.", route: route), opening: opening)
    }

    private static func waitForTerminalExtractionFailure(
        in group: MacLibraryWorkloads, sessionID: ConversationID,
        executionIDs: [ExecutionID], timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var terminalJobFound = false
            for executionID in executionIDs {
                let page = try await group.memories.extractionStatus(
                    sessionID: sessionID, executionID: executionID, workspaceID: nil,
                    before: nil, limit: 16)
                terminalJobFound = terminalJobFound || page.jobs.contains {
                    $0.state == .failed || $0.state == .paused
                }
            }
            let workloadFailure = await group.status().failures["extraction"]
            if terminalJobFound, workloadFailure != nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MiraError(.timeout, "The synthetic extraction failure did not settle in time.")
    }
}

private struct WaitRegressionRoute {
    static func install(in group: MacLibraryWorkloads) async throws -> AgentModelRoute {
        let schema = AgentConfigurationValue(
            schema: .init(id: "test.memory.wait.schema", revision: 1), value: .object([:]))
        let endpoint = AgentModelEndpoint(id: "test", configuration: schema, credential: nil)
        let connection = AgentConfiguredConnection(
            id: .init(), revision: 1, configurationRevision: 1, name: "Memory wait regression",
            isEnabled: true, definitionID: nil, endpoints: [endpoint], discovery: nil, defaultInvocation: nil)
        let identity = WaitRegressionModule.identity
        let model = AgentConfiguredModel(
            id: .init(), revision: 1, authorizationRevision: 1,
            reference: .init(connectionID: connection.id, modelID: "memory-wait-regression"),
            displayName: "Memory wait regression", isEnabled: true,
            invocations: [.init(
                id: "default", revision: 1, adapter: identity, endpointID: endpoint.id,
                contextWindow: 32_768, maximumOutputTokens: 1_024,
                capabilities: [AgentModelCapabilityID.streamingText: .declared,
                               AgentModelCapabilityID.toolCalls: .declared],
                configuration: schema,
                parameterSchema: .object(["type": .string("object"), "properties": .object([:]),
                                          "additionalProperties": .bool(false)]))], facts: [])
        let preset = AgentRoutePreset(
            id: RouteID(model.id.rawValue), revision: 1, name: "Memory wait regression",
            modelDescriptorID: model.id, invocationID: "default", maximumOutputTokens: 1_024,
            configuration: schema)
        _ = try await group.credentialSettings.saveConnection(
            id: connection.id, name: connection.name, isEnabled: connection.isEnabled,
            definitionID: connection.definitionID, endpoints: connection.endpoints,
            discovery: connection.discovery, defaultInvocation: connection.defaultInvocation,
            previous: nil, credentialEndpointID: endpoint.id, credential: .keep)
        try await group.modelSettings.savePoolModel(
            model, preset: preset, expectedModelRevision: nil, expectedPresetRevision: nil)
        return try await group.modelSettings.resolve(
            purpose: AgentModelPurposeID.conversation, explicitRouteID: preset.id,
            sessionSelection: .inherit, workspaceID: nil).route
    }
}

private struct WaitRegressionModule: RuntimeModule {
    static let identity = AgentAdapterIdentity(id: "test.memory.wait", revision: 1)
    let id = "test.memory.wait"
    let dependencies: Set<String> = []
    let registry: RuntimeRegistry<AgentCapability>

    func activate(in scope: RuntimeScope) async throws {
        try await registry.register(id: id, value: .model(WaitRegressionAdapter()), scope: scope)
        try await registry.register(
            id: "test.memory.wait.configuration", value: .modelConfiguration(WaitRegressionConfiguration()), scope: scope)
    }
}

private struct WaitRegressionConfiguration: AgentModelConfigurationProvider {
    let identity = WaitRegressionModule.identity

    func descriptor(for invocation: AgentModelInvocationSpec) throws -> AgentModelConfigurationDescriptor {
        let schema = AgentConfigurationSchema(
            identity: .init(id: "test.memory.wait.schema", revision: 1), title: "Memory wait regression",
            schema: .object(["type": .string("object"), "properties": .object([:]),
                             "additionalProperties": .bool(false)]), defaults: .object([:]))
        return .init(adapter: identity, title: "Memory wait regression", credential: .none,
                     connection: schema, route: schema)
    }

    func configuration(for candidate: AgentModelRouteCandidate) throws -> JSONValue { .object([:]) }
}

private struct WaitRegressionAdapter: AgentModelAdapter {
    let identity = WaitRegressionModule.identity

    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        try input.validate(for: route)
        guard input.allowsToolCalls else {
            throw MiraError(.invalidInput, "Synthetic background extraction failure for the wait regression.")
        }
        let wire = try SessionCodec.decode(JSONValue.self, from: SessionCodec.encode(input))
        let request = AgentPreparedModelRequest(
            adapter: identity, input: input, wirePayload: wire,
            estimatedInputTokens: try SessionCodec.encode(wire).count)
        try request.validate(for: route)
        return request
    }

    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        let (stream, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
        continuation.yield(.blockStarted(.init(id: "text", content: .text("Done."))))
        continuation.yield(.blockFinished(id: "text"))
        continuation.yield(.finished(.stop))
        continuation.finish()
        return .init(events: stream, cancelAndDrain: { continuation.finish() })
    }

    func replay(
        _ messages: [AgentModelMessage], from source: AgentModelRoute, to target: AgentModelRoute,
        boundary: AgentReplayBoundary
    ) throws -> AgentReplayDecision { .include(messages) }
}

private struct WaitRegressionNotifications: LocalNotificationPort {
    func permission() async -> NotificationPermission { .denied }
    func requestPermission() async throws -> Bool { false }
    func pending() async -> [ReminderNotification] { [] }
    func install(_ notification: ReminderNotification) async throws {
        throw MiraError(.unsupported, "Synthetic notifications are unavailable.")
    }
    func remove(_ identifier: String) async {}
}

private struct WaitRegressionCredentials: MacCredentialStore {
    func read(reference: String, version: Int) throws -> String {
        throw MiraError(.credentialMissing, "The offline wait regression never reads credentials.")
    }
    func save(_ secret: String, reference: String, version: Int) throws {
        throw MiraError(.unsupported, "The offline wait regression never writes credentials.")
    }
    func delete(reference: String, version: Int) throws {}
}
