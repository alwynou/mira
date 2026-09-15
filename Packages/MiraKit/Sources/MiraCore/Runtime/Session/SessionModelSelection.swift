import Foundation

/// The immutable identity a session records when a user explicitly chooses a
/// model. The remote model string is intentionally paired with both the local
/// connection and its current configuration incarnation.
public struct AgentSessionModelReference: Codable, Sendable, Equatable, Hashable {
    public let routeID: RouteID
    public let model: AgentModelReference
    public let modelConfigurationID: ModelDescriptorID

    public init(routeID: RouteID, model: AgentModelReference, modelConfigurationID: ModelDescriptorID) {
        self.routeID = routeID
        self.model = model
        self.modelConfigurationID = modelConfigurationID
    }

    public func validate() throws {
        try model.validate()
    }
}

/// A session preference is an intent. Resolution against current settings is
/// performed at admission time and never mutates this value implicitly.
public enum AgentSessionModelSelection: Codable, Sendable, Equatable, Hashable {
    case inherit
    case selected(AgentSessionModelReference)

    public func validate() throws {
        if case .selected(let reference) = self { try reference.validate() }
    }
}
