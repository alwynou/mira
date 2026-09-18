import Foundation
import GRDB
import MiraCore
import MiraData
import Testing

@Suite("Public provider and driver extension challenge", .timeLimit(.minutes(1)))
struct AgentProviderDriverChallengeTests {
    @Test func independentConfigurationAndOpaqueContinuationSurviveToolAndTurnBoundaries() async throws {
        try await withProviderChallenge { f in
            let session = ConversationID()
            let first = try await f.run(session: session)
            #expect(first.executions.values.first?.completion?.status == .completed)
            let inputs = await f.provider.inputs
            try #require(inputs.count == 2)
            #expect(inputs[1].messages.contains { $0.continuation == ChallengeProvider.continuation })
            let outputReference = try #require(
                first.attempts.values.min(by: { $0.sequence < $1.sequence })?.resolution?.output)
            let output = try SessionCodec.decode(
                AgentModelOutput.self, from: await f.data.library.read(outputReference))
            #expect(output.continuation == ChallengeProvider.continuation)
            let requestReference = try #require(
                first.attempts.values.max(by: { $0.sequence < $1.sequence })?.attempt.request)
            let request = try SessionCodec.decode(
                AgentSessionRequest.self, from: await f.data.library.read(requestReference))
            #expect(request.contextMessages.allSatisfy { $0.role == .context })

            let second = try await f.run(session: session)
            #expect(second.executions.count == 2)
            #expect(second.executions.values.allSatisfy { $0.completion?.status == .completed })
            let continuedInputs = await f.provider.inputs
            try #require(continuedInputs.count == 4)
            #expect(continuedInputs[2].messages.contains { $0.role == .assistant && $0.text == "Challenge answer." })
            #expect(continuedInputs[2].messages.allSatisfy { $0.blocks.allSatisfy { if case .thinking = $0.content { return false }; return true } })
            #expect(continuedInputs[3].messages.filter { $0.continuation != nil }.count == 1)
            #expect(await f.tool.executions == 2)
            #expect(second.invocations.values.allSatisfy { $0.resolution?.status == .succeeded })
            #expect(await f.provider.drains == 4)

            let schema = try ChallengeConfiguration().descriptor(for: f.candidate.model.invocations[0])
            #expect(schema.connection.identity.id == "challenge.settings")
            #expect(f.route.configuration == .object(["mode": .string("opaque")]))
            let invalid = AgentModelRouteCandidate(
                connection: f.candidate.connection, model: f.candidate.model,
                preset: .init(id: .init(), revision: 1, name: "Invalid", modelDescriptorID: f.candidate.model.id, invocationID: "default", maximumOutputTokens: 256, configuration: .init(schema: schema.route.identity, value: .object(["mode": .string("unknown")]))))
            let snapshot = try await f.registry.freeze()
            let catalog: AgentRuntimeCatalog
            do { catalog = try AgentRuntimeCatalog(snapshot: snapshot) } catch {
                await snapshot.release()
                throw error
            }
            #expect(throws: MiraError.self) { try catalog.configuredRoute(invalid) }
            await catalog.release()
        }
    }

    @Test(arguments: [false, true])
    func replacementDriverChangesIterationButCannotExceedKernelBudget(exceedBudget: Bool) async throws {
        try await withProviderChallenge { f in
            let state = try await f.run(
                driver: exceedBudget ? ChallengeDriver.budgetID : ChallengeDriver.stopID,
                maximumSteps: 1)
            let execution = try #require(state.executions.values.first)
            #expect(execution.attemptIDs.count == 1)
            #expect(await f.provider.inputs.count == 1)
            #expect(await f.provider.drains == 1)
            #expect(await f.tool.executions == (exceedBudget ? 1 : 0))
            #expect(execution.completion?.status == (exceedBudget ? .failed : .interrupted))
            #expect(state.invocations.values.allSatisfy { $0.resolution != nil })
            if exceedBudget {
                let reference = try #require(execution.completion?.error)
                let error = try SessionCodec.decode(MiraError.self, from: await f.data.library.read(reference))
                #expect(error.code == .outputLimit)
            }
        }
    }

    @Test func providerRejectsInvalidOpaqueFormatWithoutTeachingTheKernelItsFormat() async throws {
        try await withProviderChallenge { f in
            let malformed = AgentModelContinuation(
                adapter: ChallengeProvider.adapterIdentity, format: "foreign.format", payload: .object([:]),
                isComplete: true)
            #expect(throws: MiraError.self) {
                try f.provider.replay(
                    [.init(role: .assistant, blocks: [.init(id: "thinking", content: .thinking("Synthetic reasoning."))], continuation: malformed)],
                    from: f.route, to: f.route, boundary: .sameExecution)
            }
            #expect(await f.provider.inputs.isEmpty)
        }
    }
}

private struct ProviderChallengeFixture {
    let data: TaskWorkflowFixture
    let application: AgentApplicationRuntime
    let registry: RuntimeRegistry<AgentCapability>
    let provider: ChallengeProvider
    let tool: ChallengeReadTool
    let route: AgentModelRoute
    let candidate: AgentModelRouteCandidate

    func run(session: ConversationID = .init(), driver: String = "mira.default", maximumSteps: Int = 4) async throws
        -> SessionState
    {
        let execution = ExecutionID()
        let opening: AgentSessionOpening? =
            try await application.sessionSnapshot(id: session).header == nil
            ? .init(title: "Provider challenge", workspaceID: nil) : nil
        let command = AgentSubmitCommand(
            id: UUID(), sessionID: session, executionID: execution,
            input: .message(id: .init(), text: "Use the challenge provider.", timeZoneIdentifier: "UTC"),
            options: .init(
                driverID: driver, instructions: "Read once and answer.",
                limits: .init(maximumSteps: maximumSteps), route: route), opening: opening)
        try requireProviderCommit(await application.submit(command))
        try requireProviderCommit(await application.waitForExecution(id: execution, sessionID: session))
        return try await application.sessionSnapshot(id: session)
    }
}

private func withProviderChallenge(_ body: (ProviderChallengeFixture) async throws -> Void) async throws {
    try await withTaskWorkflow { data in
        #expect(await data.runtime.shutdown().isSettled)
        let provider = ChallengeProvider()
        let tool = ChallengeReadTool()
        let registry = RuntimeRegistry<AgentCapability>()
        let schema = ChallengeConfiguration.schema
        let configuration = AgentConfigurationValue(schema: schema.identity, value: schema.defaults)
        let connection = AgentConfiguredConnection(id: .init(), revision: 1, configurationRevision: 1, name: "Independent challenge provider", isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: configuration, credential: nil)], discovery: nil, defaultInvocation: nil)
        let model = AgentConfiguredModel(id: .init(), revision: 1, authorizationRevision: 1, reference: .init(connectionID: connection.id, modelID: "challenge-model"), displayName: nil, isEnabled: true, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: ChallengeProvider.adapterIdentity, endpointID: "primary", contextWindow: 16_384, maximumOutputTokens: nil, capabilities: [
                AgentModelCapabilityID.streamingText: .declared, AgentModelCapabilityID.toolCalls: .declared,
                AgentModelCapabilityID.thinking: .declared,
            ], configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: modelParameterSchema)], facts: [])
        let preset = AgentRoutePreset(id: RouteID(model.id.rawValue), revision: 1, name: "Opaque challenge", modelDescriptorID: model.id, invocationID: "default", maximumOutputTokens: 256, configuration: configuration)
        try await data.settings.saveConnection(
            connection, expectedRevision: nil, authorization: data.authority.authorization())
        try await data.settings.savePoolModel(
            model, preset: preset, expectedModelRevision: nil,
            expectedPresetRevision: nil, authorization: data.authority.authorization())
        let candidate = try await data.settings.candidate(routeID: preset.id)
        let business = try SQLiteBusinessEffects(
            database: data.database, libraryID: data.authority.libraryID,
            resolver: JournalAgentEffectResolver(journal: data.library, payloads: data.library),
            handlers: [], validator: ChallengeReadValidator())
        let scheduler = RuntimeScheduler()
        let approvals = RuntimeApprovalService()
        var application: AgentApplicationRuntime?
        do {
            let app = try await AgentApplicationRuntime.open(
                journal: data.library, payloads: data.library, libraryAccess: data.access,
                registry: registry, modules: [ChallengeModule(registry: registry, provider: provider, tool: tool)],
                policy: ChallengeAllowPolicy(), authority: business, business: business, authorizer: data.authorizer,
                approvals: approvals, scheduler: scheduler, environment: .init(now: { TaskWorkflowFixture.now }))
            application = app
            let snapshot = try await registry.freeze()
            let catalog: AgentRuntimeCatalog
            do { catalog = try AgentRuntimeCatalog(snapshot: snapshot) } catch {
                await snapshot.release()
                throw error
            }
            let route: AgentModelRoute
            do {
                route = try catalog.configuredRoute(candidate)
                await catalog.release()
            } catch {
                await catalog.release()
                throw error
            }
            try await body(
                .init(
                    data: data, application: app, registry: registry, provider: provider, tool: tool,
                    route: route, candidate: candidate))
            #expect(await app.shutdown().isSettled)
            let released = try await registry.freeze()
            #expect(released.entries.isEmpty)
            await released.release()
            try await business.close()
        } catch {
            _ = await application?.shutdown()
            await scheduler.shutdown()
            await approvals.shutdown()
            try? await business.close()
            throw error
        }
    }
}

private struct ChallengeModule: RuntimeModule {
    let id = "challenge.provider-module"
    let dependencies: Set<String> = []
    let registry: RuntimeRegistry<AgentCapability>
    let provider: ChallengeProvider
    let tool: ChallengeReadTool
    func activate(in scope: RuntimeScope) async throws {
        try await registry.register(id: "challenge.provider", value: .model(provider), scope: scope)
        try await registry.register(
            id: "challenge.configuration", value: .modelConfiguration(ChallengeConfiguration()), scope: scope)
        try await registry.register(id: "challenge.default", value: .driver(DefaultAgentDriver()), scope: scope)
        try await registry.register(
            id: "challenge.stop", value: .driver(ChallengeDriver(exceedBudget: false)), scope: scope)
        try await registry.register(
            id: "challenge.budget", value: .driver(ChallengeDriver(exceedBudget: true)), scope: scope)
        try await registry.register(id: "challenge.read", value: .tool(.read(tool)), scope: scope)
    }
}

private struct ChallengeConfiguration: AgentModelConfigurationProvider {
    static let schema = AgentConfigurationSchema(
        identity: .init(id: "challenge.settings", revision: 1),
        title: "Independent settings",
        schema: .object([
            "type": .string("object"),
            "properties": .object(["mode": .object(["type": .string("string"), "enum": .array([.string("opaque")])])]),
            "required": .array([.string("mode")]), "additionalProperties": .bool(false),
        ]),
        defaults: .object(["mode": .string("opaque")]))
    let identity = ChallengeProvider.adapterIdentity
    func descriptor(for invocation: AgentModelInvocationSpec) throws -> AgentModelConfigurationDescriptor {
        .init(
            adapter: identity, title: "Independent provider", credential: .none, connection: Self.schema,
            route: Self.schema)
    }
    func configuration(for candidate: AgentModelRouteCandidate) throws -> JSONValue {
        candidate.preset.configuration.value
    }
}

private struct ChallengeDriver: AgentDriver {
    static let stopID = "challenge.stop", budgetID = "challenge.budget"
    var id: String { exceedBudget ? Self.budgetID : Self.stopID }
    let revision = 1
    let exceedBudget: Bool
    func run(in context: AgentRunContext) async throws -> AgentDriverDecision {
        let first = try await context.modelStep()
        if exceedBudget {
            _ = try await context.executeTools(for: first)
            _ = try await context.modelStep()
        }
        return .stop
    }
}

private actor ChallengeProvider: AgentModelAdapter {
    static let adapterIdentity = AgentAdapterIdentity(id: "challenge.provider", revision: 1)
    nonisolated let identity = ChallengeProvider.adapterIdentity
    static let continuation = AgentModelContinuation(
        adapter: adapterIdentity, format: "challenge.opaque-v1",
        payload: .object(["opaque": .array([.string("family-token"), .number(17)]), "version": .number(1)]),
        isComplete: true)
    private(set) var inputs: [AgentModelInput] = []
    private(set) var drains = 0
    nonisolated func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        try input.validate(for: route)
        return .init(
            adapter: identity, input: input, wirePayload: .object(["family": .string("challenge")]),
            estimatedInputTokens: 128)
    }
    nonisolated func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        let (events, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
        let producer = Task {
            let needsTool = await self.recordInput(request.input)
            if Task.isCancelled {
                continuation.finish(throwing: CancellationError())
                return
            }
            continuation.yield(.blockStarted(.init(id: "thinking", content: .thinking("Synthetic reasoning."))))
            continuation.yield(.continuation(Self.continuation))
            continuation.yield(.blockFinished(id: "thinking"))
            if needsTool {
                continuation.yield(.blockStarted(.init(id: "tool-0", content: .toolCall(.init(id: request.input.stepID.uuidString, name: "challenge.read", arguments: "{}")))))
                continuation.yield(.blockFinished(id: "tool-0"))
                continuation.yield(.finished(.toolCalls))
            } else {
                continuation.yield(.blockStarted(.init(id: "text", content: .text("Challenge answer."))))
                continuation.yield(.blockFinished(id: "text"))
                continuation.yield(.finished(.stop))
            }
            continuation.finish()
        }
        return AgentModelOperation(events: events) {
            producer.cancel()
            await producer.value
            await self.recordDrain()
        }
    }
    private func recordInput(_ input: AgentModelInput) -> Bool {
        let first = !inputs.contains { $0.executionID == input.executionID }
        inputs.append(input)
        return first
    }
    private func recordDrain() { drains += 1 }
    nonisolated func replay(
        _ messages: [AgentModelMessage], from source: AgentModelRoute, to target: AgentModelRoute,
        boundary: AgentReplayBoundary
    ) throws -> AgentReplayDecision {
        guard source.adapter == identity, target.adapter == identity, source.modelID == target.modelID,
            source.connectionID == target.connectionID, source.credential == target.credential
        else { return .omit }
        if case .previousExecution = boundary {
            return .include(
                messages.map { message in
                    .init(role: message.role, blocks: message.blocks.filter {
                        if case .thinking = $0.content { return false }
                        return true
                    })
                }
            )
        }
        for message in messages {
            if let value = message.continuation, value != Self.continuation {
                throw MiraError(.malformedStream, "The independent provider rejected its opaque continuation.")
            }
        }
        return .include(messages)
    }
}

private actor ChallengeReadTool: AgentReadTool {
    nonisolated let policy = AgentToolPolicyRequirement.hostOnly
    nonisolated var descriptor: AgentToolDescriptor {
        let schema = JSONValue.object([
            "type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false),
        ])
        return .init(
            definition: .init(
                name: "challenge.read", description: "Read synthetic extension data.", inputSchema: schema),
            revision: 1, outputSchema: schema, executionMode: .exclusive, timeoutMilliseconds: 1_000,
            maximumResultBytes: 128)
    }
    private(set) var executions = 0
    func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan {
        .init(input: arguments, sources: [], targets: [])
    }
    func execute(_ plan: AgentToolPlan, context: AgentToolContext) async throws -> JSONValue {
        executions += 1
        return .object([:])
    }
}
private struct ChallengeAllowPolicy: AgentToolPolicy {
    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision {
        .allow
    }
    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws {}
}
private func requireProviderCommit(_ result: SessionCommitResult) throws {
    if case .committed = result { return }
    if case .notCommitted(let error) = result { throw error }
    throw MiraError(.storage, "The provider challenge commit was indeterminate.")
}

private struct ChallengeReadValidator: SQLiteBusinessAuthorizationValidator {
    func validate(effect: AgentResolvedEffect, isReplay: Bool, in db: Database) throws {
        guard effect.proposal.effect == .read, effect.proposal.descriptor.definition.name == "challenge.read",
            effect.proposal.businessNamespace == nil,
            effect.proposal.plan.sources.allSatisfy({ source in
                if case .sessionExecution(let sessionID, _) = source {
                    return sessionID == effect.context.evidence.reference.sessionID
                }
                return false
            }),
            effect.proposal.plan.targets.isEmpty
        else {
            throw MiraError(.unauthorized, "The challenge tool authority rejected an unrelated operation.")
        }
    }
}
