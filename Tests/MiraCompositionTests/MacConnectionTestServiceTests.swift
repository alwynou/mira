import Foundation
import MiraCore
import MiraData
import Testing

@Suite("macOS connection test service", .timeLimit(.minutes(1)))
struct MacConnectionTestServiceTests {
    @Test func unsavedDraftUsesEphemeralCredentialAndPreservesThinking() async throws {
        try await withConnectionFixture { fixture in
            let beforeConnections = try await fixture.settings.connections(after: nil, limit: 128)
            let beforeModels = try await fixture.settings.models(connectionID: nil, after: nil, limit: 128)
            let beforePresets = try await fixture.settings.presets(modelID: nil, after: nil, limit: 128)

            try await fixture.service.test(fixture.request(isSavedModel: false))

            #expect(await fixture.state.credentialRead)
            #expect(await fixture.state.thinkingSeen)
            #expect(await fixture.state.temporaryCredentialIsUnavailable)
            #expect(fixture.credentials.enteredOperations.isEmpty)
            #expect(try await fixture.settings.connections(after: nil, limit: 128) == beforeConnections)
            #expect(try await fixture.settings.models(connectionID: nil, after: nil, limit: 128) == beforeModels)
            #expect(try await fixture.settings.presets(modelID: nil, after: nil, limit: 128) == beforePresets)
        }
    }

    @Test func providerFailurePreservesNetworkCodeAndDrainsTemporaryOperation() async throws {
        let failure = AgentModelFailure(error: .init(.network, "Synthetic network failure."))
        try await withConnectionFixture(failure: failure) { fixture in
            let beforeConnections = try await fixture.settings.connections(after: nil, limit: 128)
            let beforeModels = try await fixture.settings.models(connectionID: nil, after: nil, limit: 128)
            let beforePresets = try await fixture.settings.presets(modelID: nil, after: nil, limit: 128)

            do {
                try await fixture.service.test(fixture.request(isSavedModel: false))
                Issue.record("Expected the synthetic network failure to be thrown.")
            } catch let error as MiraError {
                #expect(error.code == .network)
            }

            #expect(await fixture.state.credentialRead)
            #expect(await fixture.state.closeCompleted)
            #expect(await fixture.state.temporaryCredentialIsUnavailable)
            #expect(fixture.credentials.enteredOperations.isEmpty)
            #expect(try await fixture.settings.connections(after: nil, limit: 128) == beforeConnections)
            #expect(try await fixture.settings.models(connectionID: nil, after: nil, limit: 128) == beforeModels)
            #expect(try await fixture.settings.presets(modelID: nil, after: nil, limit: 128) == beforePresets)
        }
    }

    @Test func staleSavedBaselineIsRejectedBeforeCredentialOrNetworkWork() async throws {
        try await withConnectionFixture { fixture in
            try await fixture.settings.saveConnection(fixture.connection, expectedRevision: nil)
            try await fixture.settings.savePoolModel(
                fixture.model, preset: fixture.preset,
                expectedModelRevision: nil, expectedPresetRevision: nil)
            let changed = AgentConfiguredConnection(
                id: fixture.connection.id, revision: 2, configurationRevision: 1,
                name: "Changed baseline", isEnabled: true, definitionID: fixture.connection.definitionID,
                endpoints: fixture.connection.endpoints, discovery: fixture.connection.discovery,
                defaultInvocation: fixture.connection.defaultInvocation)
            try await fixture.settings.saveConnection(changed, expectedRevision: 1)

            await #expect(throws: MiraError.self) {
                try await fixture.service.test(fixture.request(isSavedModel: true))
            }
            #expect(await fixture.state.operationStarted == false)
            #expect(await fixture.state.credentialRead == false)
            #expect(fixture.credentials.enteredOperations.isEmpty)
        }
    }

    @Test func closeCancelsAndDrainsAcceptedOperation() async throws {
        try await withConnectionFixture(blocked: true) { fixture in
            let running = Task { try await fixture.service.test(fixture.request(isSavedModel: false)) }
            try await eventually { await fixture.state.operationStarted }

            let closing = Task { await fixture.service.close() }
            try await eventually { await fixture.state.closeStarted }
            #expect(await fixture.state.closeCompleted == false)

            await fixture.state.releaseOperation()
            await closing.value
            _ = await running.result
            #expect(await fixture.state.closeCompleted)
        }
    }
}

private struct ConnectionFixture {
    let storage: MacLibraryStorage
    let settings: AgentModelSettingsApplication
    let credentials: CompositionCredentials
    let service: MacConnectionTestService
    let scope: RuntimeScope
    let state: ConnectionProbeState
    let connection: AgentConfiguredConnection
    let model: AgentConfiguredModel
    let preset: AgentRoutePreset

    func request(isSavedModel: Bool) -> MacConnectionTestRequest {
        .init(
            connectionID: connection.id, name: connection.name, connection: connection,
            previous: isSavedModel ? connection : nil,
            model: model, preset: preset,
            isSavedModel: isSavedModel, replacementSecret: "temporary-draft-secret")
    }

    func close() async {
        await service.close()
        await settings.close()
        await scope.dispose()
        _ = await storage.close()
    }
}

private func withConnectionFixture(
    blocked: Bool = false,
    failure: AgentModelFailure? = nil,
    _ body: (ConnectionFixture) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mira-connection-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = try await MacLibraryStorage.open(embeddings: OfflineMemoryEmbedding(), directory: directory)
    let scope = RuntimeScope(kind: .application)
    let registry = RuntimeRegistry<AgentCapability>()
    let credentials = CompositionCredentials()
    let state = ConnectionProbeState(blocked: blocked, failure: failure)
    do {
        let settings = try AgentModelSettingsApplication(
            store: storage.settings, registry: registry, access: storage.access, scope: scope)
        let credentialSettings = MacCredentialSettings(
            settings: settings, access: storage.access, scope: scope,
            directory: directory, credentials: credentials)
        let schema = AgentConfigurationSchema(
            identity: .init(id: "tests.connection.schema", revision: 1), title: "Synthetic connection",
            schema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ]), defaults: .object([:]))
        let configuration = AgentConfigurationValue(schema: schema.identity, value: .object([:]))
        let routeConfiguration = AgentConfigurationValue(
            schema: SyntheticConnectionModule.routeSchema, value: .object([:]))
        let endpoint = AgentModelEndpoint(id: "primary", configuration: configuration, credential: nil)
        let connection = AgentConfiguredConnection(
            id: .init(), revision: 1, configurationRevision: 1,
            name: "Synthetic draft", isEnabled: true, definitionID: nil,
            endpoints: [endpoint], discovery: nil, defaultInvocation: nil)
        let invocation = AgentModelInvocationSpec(
            id: "default", revision: 1, adapter: SyntheticConnectionModule.identity,
            endpointID: endpoint.id, contextWindow: 4096, maximumOutputTokens: 1024,
            capabilities: [
                AgentModelCapabilityID.streamingText: .declared,
                AgentModelCapabilityID.thinking: .declared,
            ], configuration: routeConfiguration,
            parameterSchema: .object([
                "type": .string("object"), "properties": .object([:]),
                "additionalProperties": .bool(false),
            ]))
        let model = AgentConfiguredModel(
            id: .init(), revision: 1, authorizationRevision: 1,
            reference: .init(connectionID: connection.id, modelID: "synthetic"), displayName: nil,
            isEnabled: true, invocations: [invocation], facts: [])
        let preset = AgentRoutePreset(
            id: .init(model.id.rawValue), revision: 1, name: "Synthetic route",
            modelDescriptorID: model.id, invocationID: invocation.id,
            maximumOutputTokens: 128, configuration: routeConfiguration)
        let service = MacConnectionTestService(
            settings: settings, credentials: credentialSettings,
            access: storage.access, scope: scope,
            modules: { registry, reader in
                [SyntheticConnectionModule(registry: registry, reader: reader, state: state)]
            })
        let fixture = ConnectionFixture(
            storage: storage, settings: settings, credentials: credentials,
            service: service, scope: scope, state: state,
            connection: connection, model: model, preset: preset)
        do {
            try await body(fixture)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    } catch {
        await scope.dispose()
        _ = await storage.close()
        throw error
    }
}

private actor ConnectionProbeState {
    private let blocked: Bool
    private let failure: AgentModelFailure?
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var operationStarted = false
    var credentialRead = false
    var thinkingSeen = false
    var closeStarted = false
    var closeCompleted = false
    var reader: EphemeralCredentialReader?

    init(blocked: Bool, failure: AgentModelFailure? = nil) {
        self.blocked = blocked
        self.failure = failure
    }

    func install(reader: EphemeralCredentialReader) { self.reader = reader }

    var temporaryCredentialIsUnavailable: Bool {
        guard let reader else { return false }
        return reader.isUnavailable
    }

    func markCredentialRead() { credentialRead = true }
    func markStarted() { operationStarted = true }
    func markThinking() { thinkingSeen = true }
    func markCloseStarted() { closeStarted = true }
    func markCloseCompleted() { closeCompleted = true }
    func streamFailure() -> AgentModelFailure? { failure }

    func waitForRelease() async {
        guard blocked, !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseOperation() {
        released = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private final class EphemeralCredentialReader: CredentialReader, @unchecked Sendable {
    private let base: any CredentialReader
    private let lock = NSLock()
    private var reference: AgentCredentialReference?

    init(base: any CredentialReader) { self.base = base }

    var isUnavailable: Bool {
        guard let reference = lock.withLock({ reference }) else { return false }
        do {
            _ = try base.read(reference: reference.reference, version: reference.version)
            return false
        } catch {
            return true
        }
    }

    func read(reference: String, version: Int) throws -> String {
        lock.withLock { self.reference = .init(reference: reference, version: version) }
        return try base.read(reference: reference, version: version)
    }

}

private struct SyntheticConnectionModule: RuntimeModule, Sendable {
    static let identity = AgentAdapterIdentity(id: "tests.connection.adapter", revision: 1)
    static let connectionSchema = AgentConfigurationIdentity(id: "tests.connection.schema", revision: 1)
    static let routeSchema = AgentConfigurationIdentity(id: "tests.connection.route", revision: 1)

    let id = "tests.connection.module"
    let dependencies: Set<String> = []
    let registry: RuntimeRegistry<AgentCapability>
    let reader: any CredentialReader
    let state: ConnectionProbeState

    func activate(in scope: RuntimeScope) async throws {
        let ephemeral = EphemeralCredentialReader(base: reader)
        await state.install(reader: ephemeral)
        try await registry.register(
            id: "tests.connection.model", value: .model(SyntheticConnectionAdapter(reader: ephemeral, state: state)),
            scope: scope)
        try await registry.register(
            id: "tests.connection.configuration", value: .modelConfiguration(SyntheticConnectionConfiguration()),
            scope: scope)
        try await registry.register(
            id: "tests.connection.probes", value: .modelProbe(SyntheticConnectionProbes()), scope: scope)
    }
}

private struct SyntheticConnectionConfiguration: AgentModelConfigurationProvider {
    let identity = SyntheticConnectionModule.identity

    func descriptor(for invocation: AgentModelInvocationSpec) throws -> AgentModelConfigurationDescriptor {
        guard invocation.adapter == identity else {
            throw MiraError(.configuration, "The synthetic connection model is unavailable.")
        }
        return .init(
            adapter: identity, title: "Synthetic connection", credential: .required,
            connection: schema(SyntheticConnectionModule.connectionSchema),
            route: schema(SyntheticConnectionModule.routeSchema))
    }

    func configuration(for candidate: AgentModelRouteCandidate) throws -> JSONValue {
        let descriptor = try descriptor(for: candidate.invocation)
        let endpoint = try candidate.endpoint
        try descriptor.connection.validate(endpoint.configuration)
        try descriptor.route.validate(candidate.preset.configuration)
        guard endpoint.credential != nil else {
            throw MiraError(.credentialMissing, "The synthetic connection credential is unavailable.")
        }
        return candidate.preset.configuration.value
    }

    private func schema(_ identity: AgentConfigurationIdentity) -> AgentConfigurationSchema {
        .init(
            identity: identity, title: "Synthetic settings",
            schema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ]), defaults: .object([:]))
    }
}

private struct SyntheticConnectionProbes: AgentModelProbeProvider {
    func probes() throws -> [AgentModelProbeDefinition] {
        [
            try .init(
                identity: .init(
                    id: "mira.probe.text", revision: 1, title: "Synthetic text",
                    capabilityIDs: [AgentModelCapabilityID.streamingText]),
                preparationCapabilityIDs: [AgentModelCapabilityID.streamingText],
                prepareCandidate: { candidate in
                    let original = candidate.model
                    guard let selected = original.invocations.first(where: { $0.id == candidate.preset.invocationID }) else {
                        throw MiraError(.configuration, "The synthetic invocation is unavailable.")
                    }
                    var capabilities = selected.capabilities
                    capabilities[AgentModelCapabilityID.streamingText] = .declared
                    let invocation = AgentModelInvocationSpec(
                        id: selected.id, revision: selected.revision, adapter: selected.adapter,
                        endpointID: selected.endpointID, contextWindow: selected.contextWindow,
                        maximumOutputTokens: selected.maximumOutputTokens, capabilities: capabilities,
                        configuration: selected.configuration, parameterSchema: selected.parameterSchema,
                        maximumInputTokens: selected.maximumInputTokens)
                    let model = AgentConfiguredModel(
                        id: original.id, revision: original.revision,
                        authorizationRevision: original.authorizationRevision,
                        reference: original.reference, displayName: original.displayName,
                        isEnabled: original.isEnabled,
                        invocations: original.invocations.map { $0.id == invocation.id ? invocation : $0 },
                        facts: original.facts)
                    return .init(connection: candidate.connection, model: model, preset: candidate.preset)
                },
                makeInput: { stepID, executionID, _ in
                    .init(
                        stepID: stepID, executionID: executionID,
                        instructions: "Reply with exactly OK.",
                        messages: [.init(role: .user, blocks: [
                            .init(id: "probe-input", content: .text("Capability test")),
                        ])], tools: [])
                },
                evaluate: { output in output.text == "OK" ? .verified : .unsupported })
        ]
    }
}

private struct SyntheticConnectionAdapter: AgentModelAdapter {
    let identity = SyntheticConnectionModule.identity
    let reader: EphemeralCredentialReader
    let state: ConnectionProbeState

    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        try input.validate(for: route)
        return .init(adapter: identity, input: input, wirePayload: .object([:]), estimatedInputTokens: 1)
    }

    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        let (events, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
        let producer = Task {
            do {
                guard let credential = route.credential else {
                    throw MiraError(.credentialMissing, "The synthetic connection credential is unavailable.")
                }
                _ = try reader.read(reference: credential.reference, version: credential.version)
                await state.markCredentialRead()
                await state.markStarted()
                if let failure = await state.streamFailure() { throw failure }
                await state.waitForRelease()
                try Task.checkCancellation()
                await state.markThinking()
                continuation.yield(.blockStarted(.init(id: "thinking", content: .thinking(""))))
                continuation.yield(.blockDelta(id: "thinking", text: "Synthetic thinking"))
                continuation.yield(.blockFinished(id: "thinking"))
                continuation.yield(.blockStarted(.init(id: "text", content: .text(""))))
                continuation.yield(.blockDelta(id: "text", text: "OK"))
                continuation.yield(.blockFinished(id: "text"))
                continuation.yield(.finished(.stop))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return .init(events: events) {
            await state.markCloseStarted()
            await state.waitForRelease()
            producer.cancel()
            _ = await producer.result
            await state.markCloseCompleted()
        }
    }

    func replay(
        _ messages: [AgentModelMessage], from source: AgentModelRoute,
        to target: AgentModelRoute, boundary: AgentReplayBoundary
    ) throws -> AgentReplayDecision { .include(messages) }
}

private func eventually(_ condition: @escaping () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard clock.now < deadline else {
            throw MiraError(.timeout, "The connection test fixture did not reach its gate.")
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}
