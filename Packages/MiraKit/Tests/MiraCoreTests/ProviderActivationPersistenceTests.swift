import Foundation
import Testing
import MiraCore
import MiraData

struct ProviderActivationPersistenceTests {
    @Test func textProbeCannotCertifyToolsOrExtraction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-text-probe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let connection = ProviderConnection(name: "Fixture", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", credentialReference: "fixture")
        let model = ModelDescriptor(connectionID: connection.id, modelID: "fixture", contextWindow: 8192)
        let route = ModelRoute(id: model.poolRouteID, name: "Fixture", modelDescriptorID: model.id)
        try store.saveConnection(connection, expectedRevision: nil)
        try store.savePoolModel(model, route: route, expectedModelRevision: nil, expectedRouteRevision: nil)
        let app = try MiraApplication(store: store, provider: NoopActivationProvider())
        let original = try store.modelConfiguration().snapshot(routeID: route.id)
        var temporaryProbeCopy = original
        temporaryProbeCopy.textCapability = .declared
        temporaryProbeCopy.toolCapability = .declared
        temporaryProbeCopy.extractionCapability = .declared
        await #expect(throws: MiraError.self) {
            try await app.saveProbe(.init(type: .text, state: .verified), for: temporaryProbeCopy)
        }
        try await app.saveProbe(.init(type: .text, state: .verified), for: original)
        let configuration = try store.modelConfiguration()
        #expect(configuration.models.first?.textCapability == .verified)
        #expect(configuration.models.first?.toolCapability == .unknown)
        #expect(configuration.models.first?.extractionCapability == .unknown)
        #expect(configuration.models(for: .conversation).count == 1)
        #expect(configuration.models(for: .agentTools).isEmpty)
        #expect(configuration.models(for: .memoryExtraction).isEmpty)
        #expect(await app.shutdown())
    }

    @Test func probeUpdatesOnlyTheRequestedCapabilityAndRejectsStaleSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-probe-persistence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let connection = ProviderConnection(name: "Provider", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", credentialReference: "fixture")
        let catalog = ModelCatalogMetadata(providerID: "provider", modelID: "fixture", sourceURL: "https://catalog.example", sourceRevision: "1", retrievedAt: "2026-09-06")
        let model = ModelDescriptor(connectionID: connection.id, modelID: "fixture", contextWindow: 8192, textCapability: .verified, toolCapability: .declared, protocolMode: .standard, catalogMetadata: catalog)
        let route = ModelRoute(id: model.poolRouteID, name: "Fixture", modelDescriptorID: model.id)
        try store.saveConnection(connection, expectedRevision: nil)
        try store.savePoolModel(model, route: route, expectedModelRevision: nil, expectedRouteRevision: nil)
        let app = try MiraApplication(store: store, provider: NoopActivationProvider())

        let extractionSnapshot = try store.modelConfiguration().snapshot(routeID: route.id, purpose: .memoryExtraction)
        try await app.saveProbe(.init(type: .jsonExtraction, state: .verified), for: extractionSnapshot)
        let afterJSON = try #require(try store.modelConfiguration().models.first)
        #expect(afterJSON.extractionCapability == .verified)
        #expect(afterJSON.textCapability == .verified)
        #expect(afterJSON.toolCapability == .declared)
        #expect(afterJSON.protocolMode == .standard)
        #expect(afterJSON.catalogMetadata == catalog)

        let staleJSONSnapshot = try store.modelConfiguration().snapshot(routeID: route.id, purpose: .memoryExtraction)
        var rotated = connection
        rotated.revision = 2
        rotated.credentialVersion = 2
        try store.saveConnection(rotated, expectedRevision: 1)
        let currentTextSnapshot = try store.modelConfiguration().snapshot(routeID: route.id, purpose: .conversation)
        #expect(currentTextSnapshot.extractionCapability == .unknown)
        try await app.saveProbe(.init(type: .text, state: .verified), for: currentTextSnapshot)
        let afterText = try #require(try store.modelConfiguration().models.first)
        #expect(afterText.textCapability == .verified)
        #expect(afterText.toolCapability == .unknown)
        #expect(afterText.extractionCapability == .unknown)

        await #expect(throws: MiraError.self) {
            try await app.saveProbe(.init(type: .jsonExtraction, state: .verified), for: staleJSONSnapshot)
        }
        #expect(await app.shutdown())
    }
}

private struct NoopActivationProvider: ModelProviderPort {
    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}
