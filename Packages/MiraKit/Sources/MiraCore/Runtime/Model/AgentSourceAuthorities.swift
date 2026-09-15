import Foundation

/// Checks current destination and workspace policy, even when no auxiliary sources are selected.
public protocol AgentContextPolicy: Sendable {
    func validate(_ request: AgentContextRequest) async throws
}

/// One domain owns its source identities, versions, scope and disclosure policy.
/// The namespace is captured by the registration snapshot before any asynchronous checks.
public protocol AgentDomainSourceAuthority: Sendable {
    var namespace: String { get }
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws
}

/// Resolves session provenance from the journal and domain sources through scoped registrations.
/// Callers must own library access while this operation and its underlying readers are running.
public struct JournalAgentSourceAuthorizer: AgentSourceAuthorizer {
    private let reader: JournalSessionReader
    private let policy: any AgentContextPolicy
    private let domains: RuntimeRegistry<any AgentDomainSourceAuthority>

    public init(reader: JournalSessionReader, policy: any AgentContextPolicy,
                domains: RuntimeRegistry<any AgentDomainSourceAuthority>) {
        self.reader = reader; self.policy = policy; self.domains = domains
    }

    public func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {
        try Task.checkCancellation()
        guard sources.count <= 8_192, Set(sources).count == sources.count else {
            throw MiraError(.invalidInput, "The context source selection is invalid.")
        }
        for source in sources { try source.validate() }
        try request.destination.modelRoute?.validate()
        let snapshot = try await domains.freeze()
        do {
            guard snapshot.entries.count <= 128 else { throw Self.invalidCatalog }
            var authorities: [String: any AgentDomainSourceAuthority] = [:]
            for entry in snapshot.entries {
                let namespace = entry.value.namespace
                guard SessionState.validIdentifier(namespace, maximumBytes: 128), authorities[namespace] == nil else {
                    throw Self.invalidCatalog
                }
                authorities[namespace] = entry.value
            }
            try await policy.validate(request)
            try Task.checkCancellation()
            let sessionSources = sources.filter { if case .sessionExecution = $0 { true } else { false } }
            if !sessionSources.isEmpty {
                let evidence = try await reader.executionSources(sessionSources)
                guard evidence.allSatisfy({ $0.workspaceID == request.workspaceID }) else { throw Self.unavailableSource }
            }
            var grouped: [String: [AgentSourceReference]] = [:]
            for source in sources {
                if case .domain(let namespace, _, _) = source { grouped[namespace, default: []].append(source) }
            }
            for namespace in grouped.keys.sorted() {
                try Task.checkCancellation()
                guard let authority = authorities[namespace] else { throw Self.unavailableSource }
                try await authority.validate(grouped[namespace]!, for: request)
            }
            try await policy.validate(request)
            try Task.checkCancellation()
            await snapshot.release()
        } catch { await snapshot.release(); throw error }
    }

    private static var invalidCatalog: MiraError {
        .init(.configuration, "The source authority catalog is invalid.")
    }
    private static var unavailableSource: MiraError {
        .init(.unauthorized, "The context source is unavailable for this destination.")
    }
}
