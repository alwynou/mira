import Foundation

/// A capability registered by the composition root and made visible atomically
/// by one runtime registry snapshot.
public enum AgentCapability: Sendable {
    case model(any AgentModelAdapter)
    case modelConfiguration(any AgentModelConfigurationProvider)
    case modelDiscovery(any AgentModelDiscoveryProvider)
    case modelProbe(any AgentModelProbeProvider)
    case modelMetadata(any AgentModelMetadataProvider)
    case tool(AgentTool)
    case context(any AgentContextContributor)
    case driver(any AgentDriver)
    case consumer(any AgentSessionConsumer)
}

/// Immutable executable capabilities for one runtime generation.
///
/// The caller transfers ownership of `snapshot` to this catalog. If
/// initialization throws, the caller remains responsible for releasing it.
public final class AgentRuntimeCatalog: Sendable {
    private struct DriverKey: Hashable, Sendable {
        let id: String
        let revision: Int
    }

    private let snapshot: RuntimeRegistrySnapshot<AgentCapability>
    private let models: [AgentAdapterIdentity: any AgentModelAdapter]
    private let configurations: [AgentAdapterIdentity: FrozenConfigurationProvider]
    private let discoveries: [AgentAdapterIdentity: FrozenDiscoveryProvider]
    private let metadata: [String: any AgentModelMetadataProvider]
    private let probeCatalog: AgentModelProbeCatalog
    private let drivers: [DriverKey: any AgentDriver]
    private let consumers: [String: any AgentSessionConsumer]
    public let generation: UInt64
    public let tools: AgentToolCatalog
    public let contributors: [any AgentContextContributor]
    public var probes: AgentModelProbeCatalog { probeCatalog }

    public init(snapshot: RuntimeRegistrySnapshot<AgentCapability>) throws {
        let entries = snapshot.entries
        var models: [AgentAdapterIdentity: any AgentModelAdapter] = [:]
        var configurations: [AgentAdapterIdentity: FrozenConfigurationProvider] = [:]
        var configurationIDs = Set<String>()
        var discoveries: [AgentAdapterIdentity: FrozenDiscoveryProvider] = [:]
        var discoveryIDs = Set<String>()
        var metadata: [String: any AgentModelMetadataProvider] = [:]
        var probeProviders: [any AgentModelProbeProvider] = []
        var drivers: [DriverKey: any AgentDriver] = [:]
        var contributors: [any AgentContextContributor] = []
        var tools: [AgentTool] = []
        var consumers: [String: any AgentSessionConsumer] = [:]
        var modelIDs = Set<String>()
        var driverIDs = Set<DriverKey>()
        var contributorIDs = Set<String>()
        var modelCount = 0
        var driverCount = 0
        var contributorCount = 0
        var toolCount = 0

        for entry in entries {
            switch entry.value {
            case .model(let model):
                modelCount += 1
                guard modelCount <= 64 else {
                    throw Self.configuration("The runtime model capability limit was exceeded.")
                }
                let identity = model.identity
                try identity.validate()
                guard modelIDs.insert(identity.id).inserted else {
                    throw Self.configuration("The runtime contains duplicate model adapter identities.")
                }
                models[identity] = model
            case .modelConfiguration(let provider):
                let identity = provider.identity
                try identity.validate()
                guard configurations.count < 64, configurationIDs.insert(identity.id).inserted else {
                    throw Self.configuration("The runtime contains duplicate or too many model settings providers.")
                }
                configurations[identity] = .init(identity: identity, implementation: provider)
            case .modelDiscovery(let provider):
                let identity = provider.identity
                try identity.validate()
                guard discoveries.count < 64, discoveryIDs.insert(identity.id).inserted else {
                    throw Self.configuration("The runtime contains duplicate or too many model discovery providers.")
                }
                let frozen = FrozenDiscoveryProvider(identity: identity, implementation: provider)
                _ = try frozen.descriptor()
                discoveries[identity] = frozen
            case .modelMetadata(let provider):
                try provider.identity.validate()
                guard metadata.count < 16, metadata.updateValue(provider, forKey: provider.identity.id) == nil else {
                    throw Self.configuration("The runtime contains duplicate or too many model metadata sources.")
                }
            case .modelProbe(let provider):
                guard probeProviders.count < 32 else {
                    throw Self.configuration("The runtime capability probe provider limit was exceeded.")
                }
                probeProviders.append(provider)
            case .driver(let driver):
                driverCount += 1
                let id = driver.id
                let revision = driver.revision
                let key = DriverKey(id: id, revision: revision)
                guard driverCount <= 64, SessionState.validIdentifier(id, maximumBytes: 128), revision > 0,
                    driverIDs.insert(key).inserted
                else {
                    throw Self.configuration("The runtime contains duplicate or invalid driver identities.")
                }
                drivers[key] = driver
            case .context(let contributor):
                contributorCount += 1
                let id = contributor.id
                guard contributorCount <= 128,
                    SessionState.validIdentifier(id, maximumBytes: 128),
                    contributorIDs.insert(id).inserted
                else {
                    throw Self.configuration(
                        "The runtime contains duplicate or invalid context contributor identities.")
                }
                contributors.append(
                    FrozenContributor(id: id, isRequired: contributor.isRequired, implementation: contributor))
            case .tool(let tool):
                toolCount += 1
                guard toolCount <= 256 else {
                    throw Self.configuration("The runtime tool capability limit was exceeded.")
                }
                tools.append(tool)
            case .consumer(let consumer):
                let identity = consumer.identity
                try identity.validate()
                guard consumers.count < 64, consumers[identity.id] == nil else {
                    throw Self.configuration("The runtime contains duplicate or too many session consumers.")
                }
                consumers[identity.id] = FrozenConsumer(identity: identity, implementation: consumer)
            }
        }

        self.tools = try AgentToolCatalog(tools)
        self.snapshot = snapshot
        self.metadata = metadata
        self.models = models
        self.configurations = configurations
        self.discoveries = discoveries
        self.probeCatalog = try AgentModelProbeCatalog(providers: probeProviders)
        self.drivers = drivers
        self.consumers = consumers
        self.contributors = contributors.sorted { $0.id < $1.id }
        self.generation = snapshot.generation
    }

    public func model(identity: AgentAdapterIdentity) throws -> any AgentModelAdapter {
        guard let model = models[identity] else {
            throw MiraError(.notFound, "The requested model adapter is unavailable in this runtime generation.")
        }
        return model
    }

    public func driver(id: String, revision: Int) throws -> any AgentDriver {
        guard let driver = drivers[.init(id: id, revision: revision)] else {
            throw MiraError(.notFound, "The requested runtime driver is unavailable in this runtime generation.")
        }
        return driver
    }

    public func modelConfiguration(identity: AgentAdapterIdentity) throws -> any AgentModelConfigurationProvider {
        guard let provider = configurations[identity] else {
            throw MiraError(
                .notFound, "The requested model settings provider is unavailable in this runtime generation.")
        }
        return provider
    }

    public func modelDiscovery(identity: AgentAdapterIdentity) throws -> any AgentModelDiscoveryProvider {
        guard let provider = discoveries[identity] else {
            throw MiraError(
                .notFound, "The requested model discovery provider is unavailable in this runtime generation.")
        }
        return provider
    }

    public func modelMetadata(id: String) throws -> any AgentModelMetadataProvider {
        guard let value = metadata[id] else { throw Self.configuration("The model metadata source is not installed.") }
        return value
    }

    public func modelDiscoveryDescriptors() throws -> [AgentModelDiscoveryDescriptor] {
        try discoveries.values.sorted { $0.identity.id < $1.identity.id }.map { try $0.descriptor() }
    }

    public func probe(id: String) throws -> AgentModelProbeDefinition {
        try probeCatalog.definition(id: id)
    }

    public func modelConfigurationDescriptors(for invocation: AgentModelInvocationSpec) throws -> [AgentModelConfigurationDescriptor] {
        [try modelConfiguration(identity: invocation.adapter).descriptor(for: invocation)]
    }

    /// Freezes only configuration facts. Workspace/source authorization remains an effect-boundary responsibility.
    public func configuredRoute(
        _ candidate: AgentModelRouteCandidate,
        requiredCapabilities: Set<String> = []
    ) throws -> AgentModelRoute {
        try candidate.validate(requiredCapabilities: requiredCapabilities)
        _ = try model(identity: candidate.invocation.adapter)
        let provider = try modelConfiguration(identity: candidate.invocation.adapter)
        return try candidate.freeze(configuration: provider.configuration(for: candidate))
    }

    public func release() async { await snapshot.release() }

    public var consumerIdentities: [AgentSessionConsumerIdentity] {
        consumers.values.map(\.identity).sorted { $0.id < $1.id }
    }

    public func consumer(id: String) throws -> any AgentSessionConsumer {
        guard let consumer = consumers[id] else {
            throw MiraError(.notFound, "The requested session consumer is unavailable in this runtime generation.")
        }
        return consumer
    }

    private struct FrozenConfigurationProvider: AgentModelConfigurationProvider {
        let identity: AgentAdapterIdentity
        let implementation: any AgentModelConfigurationProvider

        func descriptor(for invocation: AgentModelInvocationSpec) throws -> AgentModelConfigurationDescriptor {
            guard invocation.adapter == identity else {
                throw MiraError(.configuration, "The configured model identity or capabilities are invalid.")
            }
            let descriptor = try implementation.descriptor(for: invocation)
            try descriptor.validate()
            guard descriptor.adapter == identity else {
                throw MiraError(.configuration, "The model settings descriptor changed its registered identity.")
            }
            return descriptor
        }

        func configuration(for candidate: AgentModelRouteCandidate) throws -> JSONValue {
            try candidate.validate()
            guard try candidate.invocation.adapter == identity else {
                throw MiraError(.configuration, "The selected model does not match its settings provider.")
            }
            let descriptor = try descriptor(for: candidate.invocation)
            try descriptor.connection.validate(candidate.endpoint.configuration)
            try descriptor.route.validate(candidate.preset.configuration)
            switch descriptor.credential {
            case .required:
                guard try candidate.endpoint.credential != nil else {
                    throw MiraError(.credentialMissing, "The provider credential is unavailable.")
                }
            case .none:
                guard try candidate.endpoint.credential == nil else {
                    throw MiraError(
                        .configuration, "This model settings provider does not accept a credential reference.")
                }
            case .optional: break
            }
            let value = try implementation.configuration(for: candidate)
            _ = try candidate.freeze(configuration: value)
            return value
        }
    }

    private struct FrozenDiscoveryProvider: AgentModelDiscoveryProvider {
        let identity: AgentAdapterIdentity
        let implementation: any AgentModelDiscoveryProvider
        func descriptor() throws -> AgentModelDiscoveryDescriptor {
            let descriptor = try implementation.descriptor()
            try descriptor.validate()
            guard descriptor.adapter == identity else {
                throw MiraError(.configuration, "The model discovery descriptor changed its registered identity.")
            }
            return descriptor
        }
        func discover(connection: AgentConfiguredConnection) -> AgentModelDiscoveryOperation {
            implementation.discover(connection: connection)
        }
    }

    private struct FrozenConsumer: AgentSessionConsumer {
        let identity: AgentSessionConsumerIdentity
        let implementation: any AgentSessionConsumer
        func checkpoint(sessionID: ConversationID) async throws -> AgentSessionConsumerCheckpoint? {
            try await implementation.checkpoint(sessionID: sessionID)
        }
        func consume(_ delivery: AgentSessionConsumerDelivery) async throws -> AgentSessionConsumerCheckpoint {
            try await implementation.consume(delivery)
        }
    }

    private struct FrozenContributor: AgentContextContributor {
        let id: String
        let isRequired: Bool
        let implementation: any AgentContextContributor
        func contribute(to request: AgentContextRequest) async throws -> [AgentContextItem] {
            try await implementation.contribute(to: request)
        }
    }

    private static func configuration(_ message: String) -> MiraError {
        MiraError(.configuration, message)
    }
}
