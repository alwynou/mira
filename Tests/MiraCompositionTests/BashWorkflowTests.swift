import Darwin
import Foundation
import MiraCore
import MiraData
import Testing

@Suite("Bash through the macOS agent runtime", .timeLimit(.minutes(1)))
struct BashWorkflowTests {
    @MainActor @Test func runtimeUsesInvokingConversationConsentDespiteChangedGlobalDefault() async throws {
        let suite = "mira-runtime-permissions-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let permissions = ToolPermissionPreferences(defaults: defaults)
        try await withDirectory { directory in
            let arguments = try JSONValue.object([
                "command": .string("printf 'run\\n' >> runs.txt"), "working_directory": .string(directory.path)
            ]).jsonString()
            let tool: [AgentModelStreamEvent] = [
                .blockStarted(.init(id: "bash", content: .toolCall(.init(id: "scoped-bash", name: "bash", arguments: arguments)))),
                .blockFinished(id: "bash"), .finished(.toolCalls)
            ]
            let answer: [AgentModelStreamEvent] = [
                .blockStarted(.init(id: "answer", content: .text("Synthetic result."))),
                .blockFinished(id: "answer"), .finished(.stop)
            ]
            let model = CompositionModel(outputs: [tool, answer, tool, answer])
            let storage = try await MacLibraryStorage.open(embeddings: OfflineMemoryEmbedding(), directory: directory)
            let route: AgentModelRoute
            do { route = try await seedRoute(storage, model: model); #expect(await storage.close() == nil) }
            catch { _ = await storage.close(); throw error }
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory,
                notifications: CompositionNotifications(), credentials: CompositionCredentials(),
                modules: { [CompositionModelModule(registry: $0, model: model)] },
                toolPermissionLevel: { await permissions.level(for: $0) })
            do {
                let group = try await library.workloads()
                let guarded = ConversationID(), allowed = ConversationID()
                permissions.captureDefault(for: .conversation(libraryID: library.id, conversationID: guarded))
                permissions.select(.fullAccess, for: .conversation(libraryID: library.id, conversationID: allowed))
                permissions.select(.fullAccess)
                for id in [guarded, allowed] {
                    let request = AgentSubmitCommand(id: UUID(), sessionID: id, executionID: .init(),
                        input: .message(id: .init(), text: "Run the synthetic scoped command.", timeZoneIdentifier: "UTC"),
                        options: .init(instructions: ConversationInstructions.default, route: route),
                        opening: .init(title: "Scoped permissions", workspaceID: nil))
                    try committed(await group.application.submit(request))
                    try committed(await group.application.waitForExecution(id: request.executionID, sessionID: id))
                    let state = try await group.application.sessionSnapshot(id: id)
                    let invocation = try #require(state.invocations.values.first)
                    #expect((invocation.dispatchedAt != nil) == (id == allowed))
                    #expect((invocation.resolution?.status == .succeeded) == (id == allowed))
                    if id == guarded { #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("runs.txt").path)) }
                }
                #expect(try String(contentsOf: directory.appendingPathComponent("runs.txt"), encoding: .utf8) == "run\n")
                #expect(await library.close().isSettled)
            } catch { _ = await library.close(); throw error }
        }
    }

    enum Scenario: CaseIterable { case approved, denied, noObserver, cancelPending, cancelRunning, closeRunning, fullAccess, automaticRead, automaticRisk, changePending }

    @Test(arguments: Scenario.allCases)
    func approvalExecutionCancellationAndReopen(scenario: Scenario) async throws {
        try await withDirectory { directory in
            let libraryDirectory = directory.appendingPathComponent("Library")
            try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
            let marker = directory.appendingPathComponent("runs.txt")
            let running = scenario == .cancelRunning || scenario == .closeRunning
            let script = scenario == .automaticRead ? "pwd" : running
                ? "trap '' TERM; printf 'run\\n' >> runs.txt; echo $$ > shell.pid; /bin/sleep 30 & wait"
                : "printf 'run\\n' >> runs.txt; printf output; printf diagnostic >&2; exit 7"
            let skipsReview = scenario == .fullAccess || scenario == .automaticRead
            let permission = BashTestPermission(level: scenario == .fullAccess ? .fullAccess :
                (scenario == .automaticRead || scenario == .automaticRisk ? .automatic : .ask))
            let arguments = try JSONValue.object(["command": .string(script), "working_directory": .string(directory.path)]).jsonString()
            let model = CompositionModel(outputs: [
                [.blockStarted(.init(id: "bash", content: .toolCall(.init(id: "bash-one", name: "bash", arguments: arguments)))),
                 .blockFinished(id: "bash"), .finished(.toolCalls)],
                [.blockStarted(.init(id: "answer", content: .text("Synthetic command result reviewed."))),
                 .blockFinished(id: "answer"), .finished(.stop)]
            ])
            let storage = try await MacLibraryStorage.open(embeddings: OfflineMemoryEmbedding(), directory: libraryDirectory)
            let route: AgentModelRoute
            do { route = try await seedRoute(storage, model: model); #expect(await storage.close() == nil) }
            catch { _ = await storage.close(); throw error }
            let modules: MacLibrary.ModuleFactory = { [CompositionModelModule(registry: $0, model: model)] }
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: libraryDirectory,
                notifications: CompositionNotifications(), credentials: CompositionCredentials(), modules: modules, toolPermissionLevel: { _ in await permission.level })
            let request = AgentSubmitCommand(id: UUID(), sessionID: .init(), executionID: .init(),
                input: .message(id: .init(), text: "Run the synthetic local command.", timeZoneIdentifier: "UTC"),
                options: .init(instructions: ConversationInstructions.default, route: route),
                opening: .init(title: "Bash fixture", workspaceID: nil))
            let observer = BashApprovalObserver()
            var observation: Task<Void, Never>?
            do {
                let group = try await library.workloads()
                if scenario != .noObserver && !skipsReview {
                    let stream = await group.approvals.snapshots()
                    observation = Task { for await values in stream { await observer.update(values.first) } }
                }
                try committed(await group.application.submit(request))
                if scenario != .noObserver && !skipsReview {
                    try await eventually {
                        if await observer.request != nil { return true }
                        return (try? await group.application.sessionSnapshot(id: request.sessionID))?
                            .executions[request.executionID]?.completion != nil
                    }
                    let beforeApproval = try await group.application.sessionSnapshot(id: request.sessionID)
                    let approval = try #require(await observer.request,
                        "Approval missing: \(String(describing: beforeApproval.executions[request.executionID]?.completion)); \(beforeApproval.invocations.values.map { String(describing: $0.resolution) })")
                    #expect(approval.prompt.contains(script))
                    #expect(!FileManager.default.fileExists(atPath: marker.path))
                    let pending = try await group.application.sessionSnapshot(id: request.sessionID)
                    #expect(pending.invocations.values.first?.dispatchedAt == nil)
                    #expect(pending.invocations.values.first?.invocation.effect == .externalWrite)
                    if scenario == .changePending {
                        await permission.set(.fullAccess)
                        #expect(!FileManager.default.fileExists(atPath: marker.path))
                        #expect(await observer.request?.id == approval.id)
                    }
                    if scenario == .cancelPending {
                        await group.application.cancel(sessionID: request.sessionID)
                    } else {
                        await #expect(throws: MiraError.self) {
                            try await group.approvals.resolve(id: approval.id, proposalHash: "wrong-proposal",
                                authorizationEpoch: approval.authorizationEpoch, decision: .approved)
                        }
                        #expect(!FileManager.default.fileExists(atPath: marker.path))
                        try await group.approvals.resolve(id: approval.id, proposalHash: approval.proposalHash,
                            authorizationEpoch: approval.authorizationEpoch,
                            decision: scenario == .denied ? .denied : .approved)
                    }
                }
                if running {
                    try await eventually { FileManager.default.fileExists(atPath: directory.appendingPathComponent("shell.pid").path) }
                    let start = ContinuousClock.now
                    if scenario == .closeRunning { #expect(await library.close().isSettled) }
                    else { await group.application.cancel(sessionID: request.sessionID) }
                    if scenario != .closeRunning {
                        try committed(await group.application.waitForExecution(id: request.executionID, sessionID: request.sessionID))
                        #expect(await library.close().isSettled)
                    }
                    #expect(start.duration(to: .now) < .seconds(5))
                    let pid = try #require(Int32(try String(contentsOf: directory.appendingPathComponent("shell.pid"), encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)))
                    #expect(kill(pid, 0) == -1 && errno == ESRCH)
                } else {
                    try committed(await group.application.waitForExecution(id: request.executionID, sessionID: request.sessionID))
                    #expect(await library.close().isSettled)
                }
                observation?.cancel(); await observation?.value
            } catch {
                observation?.cancel(); await observation?.value
                _ = await library.close(); throw error
            }

            let inputCount = await model.inputs.count
            let reopened = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: libraryDirectory,
                notifications: CompositionNotifications(), credentials: CompositionCredentials(), modules: modules, toolPermissionLevel: { _ in await permission.level })
            do {
                let group = try await reopened.workloads()
                let state = try await group.application.sessionSnapshot(id: request.sessionID)
                #expect(state.activeExecutionID == nil)
                let invocation = try #require(state.invocations.values.first)
                let resolution = try #require(invocation.resolution)
                #expect(resolution.businessReceipt == nil)
                if scenario == .approved || skipsReview || scenario == .automaticRisk || scenario == .changePending {
                    #expect(resolution.status == .succeeded && resolution.effectIsKnown)
                    let content = try #require(resolution.result)
                    let result = try SessionCodec.decode(JSONValue.self, from: content.bytes)
                    #expect(result["exit_code"] == .number(scenario == .automaticRead ? 0 : 7))
                    if scenario == .automaticRead {
                        let path = try #require(realpath(directory.path, nil))
                        defer { free(path) }
                        #expect(result["stdout"] == .string(String(cString: path) + "\n"))
                        #expect(!FileManager.default.fileExists(atPath: marker.path))
                    } else {
                        #expect(result["stdout"] == .string("output") && result["stderr"] == .string("diagnostic"))
                        let continuation = try #require(await model.inputs.last?.messages.flatMap(\.toolResults).first)
                        #expect(continuation.text.contains("diagnostic"))
                    }
                } else if running {
                    #expect(invocation.dispatchedAt != nil && !resolution.effectIsKnown)
                    #expect(resolution.status != .succeeded)
                } else {
                    #expect(invocation.dispatchedAt == nil && resolution.effectIsKnown)
                    #expect(resolution.status != .succeeded)
                }
                if scenario == .approved || running || scenario == .fullAccess || scenario == .automaticRisk || scenario == .changePending {
                    #expect(try String(contentsOf: marker, encoding: .utf8) == "run\n")
                } else { #expect(!FileManager.default.fileExists(atPath: marker.path)) }
                #expect(await model.inputs.count == inputCount)
                #expect(await reopened.close().isSettled)
            } catch { _ = await reopened.close(); throw error }
        }
    }

    private func seedRoute(_ storage: MacLibraryStorage, model: CompositionModel) async throws -> AgentModelRoute {
        let configuration = AgentConfigurationValue(schema: .init(id: "tests.composition", revision: 1), value: .object([:]))
        let endpoint = AgentModelEndpoint(id: "primary", configuration: configuration, credential: nil)
        let connection = AgentConfiguredConnection(id: .init(), revision: 1, configurationRevision: 1,
            name: "Synthetic Bash", isEnabled: true, definitionID: nil, endpoints: [endpoint], discovery: nil, defaultInvocation: nil)
        let invocation = AgentModelInvocationSpec(id: "default", revision: 1, adapter: model.identity, endpointID: endpoint.id,
            contextWindow: 32_768, maximumOutputTokens: 1_024,
            capabilities: [AgentModelCapabilityID.streamingText: .declared, AgentModelCapabilityID.toolCalls: .declared],
            configuration: configuration,
            parameterSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]))
        let configured = AgentConfiguredModel(id: .init(), revision: 1, authorizationRevision: 1,
            reference: .init(connectionID: connection.id, modelID: "synthetic"), displayName: nil, isEnabled: true, invocations: [invocation], facts: [])
        let preset = AgentRoutePreset(id: .init(configured.id.rawValue), revision: 1, name: "Synthetic Bash",
            modelDescriptorID: configured.id, invocationID: invocation.id, maximumOutputTokens: 1_024, configuration: configuration)
        try await storage.settings.saveConnection(connection, expectedRevision: nil, authorization: storage.authority.state().authorization)
        try await storage.settings.savePoolModel(configured, preset: preset, expectedModelRevision: nil,
            expectedPresetRevision: nil, authorization: storage.authority.state().authorization)
        return try await storage.settings.candidate(routeID: preset.id).freeze(configuration: .object([:]))
    }
}

private actor BashApprovalObserver {
    private(set) var request: RuntimeApprovalRequest?
    func update(_ request: RuntimeApprovalRequest?) { self.request = request }
}

private actor BashTestPermission {
    private(set) var level: ToolPermissionLevel
    init(level: ToolPermissionLevel) { self.level = level }
    func set(_ level: ToolPermissionLevel) { self.level = level }
}
