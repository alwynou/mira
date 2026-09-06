import Foundation

/// A model returned by a provider's model-list endpoint.
///
/// Discovery deliberately carries only provider supplied identity and an
/// optional display name. It does not claim that a model supports any Mira
/// capability or has a particular context window.
public struct DiscoveredModel: Identifiable, Sendable, Equatable {
    public let id: String
    public let displayName: String?

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName
    }
}

/// Reads the models exposed by one configured provider connection.
public protocol ProviderModelDiscoveryPort: Sendable {
    func models(for connection: ProviderConnection) async throws -> [DiscoveredModel]
}
