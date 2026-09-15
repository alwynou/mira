import Foundation

public struct AgentModelRouteResolution: Sendable, Equatable {
    public let route: AgentModelRoute
    /// The binding observed at selection time. Nil means the caller selected a route explicitly.
    public let binding: AgentRouteBinding?

    public init(route: AgentModelRoute, binding: AgentRouteBinding?) {
        self.route = route
        self.binding = binding
    }
}

/// Resolves current business settings through the caller's leased runtime catalog.
/// These checks do not grant permission to read or send workspace/session data.
public struct AgentModelRouteResolver: Sendable {
    private let settings: any AgentModelSettingsStore

    public init(settings: any AgentModelSettingsStore) { self.settings = settings }

    public func resolve(
        purpose: String, explicitRouteID: RouteID?, sessionSelection: AgentSessionModelSelection,
        workspaceID: WorkspaceID?, catalog: AgentRuntimeCatalog,
        requiredCapabilities: Set<String> = []
    ) async throws -> AgentModelRouteResolution {
        try Task.checkCancellation()
        try sessionSelection.validate()
        let reference: AgentSessionModelReference?
        if case .selected(let value) = sessionSelection { reference = value } else { reference = nil }
        if let reference, let explicitRouteID, reference.routeID != explicitRouteID {
            throw MiraError(.configuration, "An explicit route cannot override the recorded session model selection.")
        }
        let selection = try await settings.select(
            purpose: purpose, explicitRouteID: explicitRouteID ?? reference?.routeID,
            workspaceID: workspaceID)
        if let reference {
            guard selection.candidate.model.reference == reference.model,
                selection.candidate.model.id == reference.modelConfigurationID else {
                throw MiraError(.configuration, "The selected session model configuration no longer exists.")
            }
        }
        try Task.checkCancellation()
        let route = try catalog.configuredRoute(selection.candidate, requiredCapabilities: requiredCapabilities)
        return .init(route: route, binding: selection.binding)
    }

    /// A frozen route is never silently replaced by newly edited settings. A new execution must resolve again.
    /// Binding changes affect future selections; the selected route's own records must still match exactly.
    public func validateCurrent(
        _ route: AgentModelRoute, catalog: AgentRuntimeCatalog,
        requiredCapabilities: Set<String> = []
    ) async throws {
        try route.validate()
        try Task.checkCancellation()
        let candidate = try await settings.candidate(routeID: route.id)
        try Task.checkCancellation()
        _ = try catalog.model(identity: route.adapter)
        try candidate.validateAuthorization(for: route)

    }
}
