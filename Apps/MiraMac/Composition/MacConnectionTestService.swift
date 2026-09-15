import Foundation
import MiraCore

/// An ephemeral connectivity check. It freezes the supplied draft long enough to
/// run the provider probe, while leaving connection, model, preset, and Keychain
/// state untouched.
struct MacConnectionTestRequest: Sendable {
    let connectionID: ConnectionID
    let name: String
    let connection: AgentConfiguredConnection
    let previous: AgentConfiguredConnection?
    let model: AgentConfiguredModel
    let preset: AgentRoutePreset
    let isSavedModel: Bool
    let replacementSecret: String?
}

actor MacConnectionTestService {
    typealias ModuleFactory = @Sendable (RuntimeRegistry<AgentCapability>, any CredentialReader) -> [any RuntimeModule]
    private let settings: any MacModelSettings
    private let credentials: MacCredentialSettings
    private let access: AgentLibraryAccess
    private let scope: RuntimeScope
    private let environment: RuntimeEnvironment
    private let modules: ModuleFactory
    private var operations: [UUID: Task<Void, any Error>] = [:]
    private var closed = false
    private var closing: Task<Void, Never>?

    init(
        settings: any MacModelSettings, credentials: MacCredentialSettings,
        access: AgentLibraryAccess, scope: RuntimeScope, environment: RuntimeEnvironment = .init(),
        modules: @escaping ModuleFactory = { [MacHTTPModule(registry: $0, credentials: $1)] }
    ) {
        self.settings = settings; self.credentials = credentials; self.access = access
        self.scope = scope; self.environment = environment; self.modules = modules
    }

    func test(_ request: MacConnectionTestRequest) async throws {
        try Task.checkCancellation()
        guard !closed else { throw Self.closedError }
        guard operations.count < 4 else { throw MiraError(.busy, "Too many connection tests are already running.") }
        let id = UUID()
        let task = Task {
            let lease = try await access.acquire(in: scope)
            let work = Task { try await self.perform(request, lease: lease) }
            do {
                try lease.bindCancellation { work.cancel() }
                try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                await lease.release()
            } catch {
                work.cancel(); _ = await work.result; await lease.release(); throw error
            }
        }
        operations[id] = task
        defer { operations[id] = nil }
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
            guard !closed else { throw Self.closedError }
        } onCancel: { task.cancel() }
    }

    func close() async {
        if let closing { await closing.value; return }
        closed = true
        let tasks = Array(operations.values); tasks.forEach { $0.cancel() }
        let drain = Task { for task in tasks { _ = await task.result } }
        closing = drain; await drain.value
    }

    private func perform(_ request: MacConnectionTestRequest, lease: AgentLibraryAccessLease) async throws {
        try await validateBaseline(request, lease: lease)
        let secret: String
        if let replacement = request.replacementSecret {
            guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MiraError(.credentialMissing, "Enter an API key.")
            }
            secret = replacement
        } else {
            let endpointID = request.model.invocations.first(where: { $0.id == request.preset.invocationID })?.endpointID
                ?? request.connection.endpoints.first?.id ?? "primary"
            let persisted = request.previous ?? request.connection
            guard let stored = try await credentials.credential(for: persisted, endpointID: endpointID) else {
                throw MiraError(.credentialMissing, "Enter an API key.")
            }
            secret = stored
        }
        try await validateBaseline(request, lease: lease)
        let vault = MacTestCredential(secret: secret)
        let testScope = RuntimeScope(kind: .application)
        let registry = RuntimeRegistry<AgentCapability>()
        var activation: RuntimeModuleActivation?
        do {
            let host = try RuntimeModuleHost(modules: modules(registry, vault))
            activation = try await host.activate(in: testScope)
            let candidate = try candidate(request, credential: vault.reference)
            let execution = try AgentModelProbeExecution(registry: registry, environment: environment)
            let result = try await execution.run(candidate: candidate, probeID: "mira.probe.text", lease: lease)
            try await validateBaseline(request, lease: lease)
            guard result.outcome == .verified else {
                throw MiraError(.configuration, "The model did not return a text response.")
            }
            await activation?.dispose(); await testScope.dispose(); vault.clear()
        } catch {
            await activation?.dispose(); await testScope.dispose(); vault.clear(); throw MiraError.safe(error)
        }
    }

    private func validateBaseline(_ request: MacConnectionTestRequest, lease: AgentLibraryAccessLease) async throws {
        guard request.connection.id == request.connectionID,
              request.previous?.id == request.connectionID || request.previous == nil,
              request.model.connectionID == request.connectionID,
              request.preset.modelDescriptorID == request.model.id else { throw Self.conflict }
        try await lease.read {
            guard try await self.settings.connection(id: request.connectionID) == request.previous else { throw Self.conflict }
            if request.isSavedModel {
                guard try await self.settings.model(id: request.model.id) == request.model,
                      try await self.settings.preset(id: request.preset.id) == request.preset else { throw Self.conflict }
            }
        }
    }

    private func candidate(_ request: MacConnectionTestRequest, credential: AgentCredentialReference)
        throws -> AgentModelRouteCandidate {
        guard request.connection.revision < Int.max,
              request.connection.configurationRevision < Int.max else { throw Self.conflict }
        let endpointID = request.model.invocations.first(where: { $0.id == request.preset.invocationID })?.endpointID
            ?? request.connection.endpoints.first?.id ?? "primary"
        let endpoints = request.connection.endpoints.map {
            AgentModelEndpoint(
                id: $0.id, configuration: $0.configuration,
                credential: $0.id == endpointID ? credential : $0.credential)
        }
        let connection = AgentConfiguredConnection(
            id: request.connection.id, revision: request.connection.revision + 1,
            configurationRevision: request.connection.configurationRevision + 1,
            name: request.name, isEnabled: true, definitionID: request.connection.definitionID,
            endpoints: endpoints, discovery: request.connection.discovery,
            defaultInvocation: request.connection.defaultInvocation)
        try connection.validate(); try request.model.validate(); try request.preset.validate()
        return .init(connection: connection, model: request.model, preset: request.preset)
    }

    private static var conflict: MiraError {
        .init(.conflict, "The provider configuration changed. Discard your draft and try again.")
    }
    private static var closedError: MiraError { .init(.cancelled, "Connection testing was stopped.") }
}

private final class MacTestCredential: CredentialReader, @unchecked Sendable {
    let reference = AgentCredentialReference(reference: "mira-test-\(UUID().uuidString)", version: 1)
    private let lock = NSLock(); private var secret: String?
    init(secret: String) { self.secret = secret }
    func read(reference: String, version: Int) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard reference == self.reference.reference, version == self.reference.version, let secret else {
            throw MiraError(.credentialMissing, "The temporary test credential is unavailable.")
        }
        return secret
    }
    func clear() { lock.lock(); secret = nil; lock.unlock() }
}
