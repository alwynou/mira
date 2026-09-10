import Foundation
import MiraCore
import MiraProviders

/// A selected model and its frozen settings for an explicit synthetic connection check.
/// This value contains no credentials and never changes model-pool membership.
struct ProviderConnectionTestModel: Identifiable, Sendable, Equatable {
    let model: ModelDescriptor
    let route: ModelRoute
    let isSaved: Bool
    var id: String { model.modelID }

    init(model: ModelDescriptor, route: ModelRoute) {
        self.model = model; self.route = route; isSaved = true
    }

    init(catalog: CatalogModel, connection: ProviderConnection) {
        let metadata = catalog.metadata
        model = ModelDescriptor(connectionID: connection.id, connectionRevision: connection.revision,
                                modelID: catalog.id, contextWindow: metadata.contextWindow,
                                textCapability: metadata.task == .textGeneration ? .declared : .unknown,
                                toolCapability: metadata.toolCall == true ? .declared : .unknown,
                                protocolMode: catalog.suggestedProtocolMode, catalogMetadata: metadata)
        let output = max(1, min(8192, metadata.maxOutputTokens ?? 8192, (metadata.contextWindow ?? 8193) - 1))
        let mode = catalog.suggestedProtocolMode
        route = ModelRoute(id: model.poolRouteID, name: String(catalog.id.prefix(100)), modelDescriptorID: model.id,
                           maxOutputTokens: output,
                           thinking: .init(mode: mode == .anthropicManual || mode == .anthropicAdaptive ? .enabled : .providerDefault))
        isSaved = false
    }

    func snapshot(for connection: ProviderConnection) -> ResolvedModelRouteSnapshot {
        var snapshot = ResolvedModelRouteSnapshot(route: route, model: model, connection: connection,
                                                  purpose: .conversation, selection: .explicit)
        // This temporary declaration permits only the requested synthetic text check.
        // No capability observation is written back to the user's model.
        snapshot.textCapability = .declared
        return snapshot
    }

    func canTest(with connection: ProviderConnection) -> Bool {
        (try? snapshot(for: connection).validateForSending()) != nil
    }
}
