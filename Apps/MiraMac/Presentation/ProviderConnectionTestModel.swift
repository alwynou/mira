import Foundation
import MiraCore
import MiraProviders

/// A saved model plus its selected invocation. This is retained for the
/// optional connectivity check and never gates saving or enabling a model.
struct ProviderConnectionTestModel: Identifiable, Sendable, Equatable {
    let model: AgentConfiguredModel
    let preset: AgentRoutePreset
    let isSaved: Bool

    var id: String { model.modelID }

    init(model: AgentConfiguredModel, preset: AgentRoutePreset) {
        self.model = model; self.preset = preset; isSaved = true
    }

    init(catalog: CatalogModel, connection: AgentConfiguredConnection) throws {
        let configured = try catalog.makeModel(connection: connection)
        self.model = configured.model
        self.preset = configured.preset
        isSaved = false
    }

    func candidate(for connection: AgentConfiguredConnection) -> AgentModelRouteCandidate {
        .init(connection: connection, model: model, preset: preset)
    }

    func canTest(with connection: AgentConfiguredConnection) -> Bool {
        let capabilities = model.invocations
        guard let invocation = capabilities.first(where: { $0.id == preset.invocationID }) else { return false }
        let updated = AgentConfiguredModel(
            id: model.id, revision: model.revision, authorizationRevision: model.authorizationRevision,
            reference: model.reference, displayName: model.displayName, isEnabled: model.isEnabled,
            invocations: capabilities.map { value in
                guard value.id == invocation.id else { return value }
                var states = value.capabilities; states[AgentModelCapabilityID.streamingText] = .declared
                return AgentModelInvocationSpec(id: value.id, revision: value.revision, adapter: value.adapter,
                    endpointID: value.endpointID, contextWindow: value.contextWindow,
                    maximumOutputTokens: value.maximumOutputTokens, capabilities: states,
                    configuration: value.configuration, parameterSchema: value.parameterSchema)
            }, facts: model.facts)
        return (try? AgentModelRouteCandidate(connection: connection, model: updated, preset: preset).validate()) != nil
    }
}
