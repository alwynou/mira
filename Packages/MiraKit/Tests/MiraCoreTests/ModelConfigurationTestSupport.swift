import Foundation
import MiraCore

/// Test-only bridge for fixtures that used to persist a resolved route as one value.
/// Production persistence stores the connection, model descriptor, and reusable preset
/// independently; keeping this decomposition here makes the fixture's intent explicit.
struct StoredRouteFixture {
    let snapshot: ResolvedModelRouteSnapshot
    let connection: ProviderConnection
    let model: ModelDescriptor
    let route: ModelRoute

    init(_ snapshot: ResolvedModelRouteSnapshot, connectionName: String = "Fixture connection") {
        self.snapshot = snapshot
        connection = ProviderConnection(
            id: snapshot.connectionID,
            revision: snapshot.connectionRevision,
            name: connectionName,
            providerKind: snapshot.providerKind,
            baseURL: snapshot.baseURL,
            credentialReference: snapshot.credentialReference,
            credentialVersion: snapshot.credentialVersion,
            allowsLoopbackHTTP: snapshot.allowsLoopbackHTTP
        )
        model = ModelDescriptor(
            id: snapshot.modelDescriptorID,
            revision: snapshot.modelRevision,
            connectionID: snapshot.connectionID,
            connectionRevision: snapshot.connectionRevision,
            modelID: snapshot.modelID,
            contextWindow: snapshot.contextWindow,
            textCapability: snapshot.textCapability,
            toolCapability: snapshot.toolCapability,
            probeObservation: snapshot.probeObservation,
            extractionCapability: snapshot.extractionCapability,
            protocolMode: snapshot.protocolMode,
            catalogMetadata: snapshot.catalogMetadata
        )
        route = ModelRoute(
            id: snapshot.id,
            revision: snapshot.revision,
            name: snapshot.name,
            modelDescriptorID: snapshot.modelDescriptorID,
            maxOutputTokens: snapshot.maxOutputTokens,
            requestsUsage: snapshot.requestsUsage
        )
    }

    func install(in store: any MiraStore, binding: RouteBinding? = nil) throws {
        try store.saveConnection(connection, expectedRevision: nil)
        try store.saveModel(model, expectedRevision: nil)
        try store.saveRoute(route, expectedRevision: nil)
        if let binding { try store.saveRouteBinding(binding, expectedRevision: nil) }
    }
}
