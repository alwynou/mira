import Foundation
import MiraCore
import MiraProviders
import Testing

@Suite("Provider connection test model")
struct ProviderConnectionTestModelTests {
    @Test func catalogDraftUsesTheConnectionInvocationAndAdvisoryFacts() throws {
        let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
        let catalog = try #require(provider.model(id: "gpt-4"))
        let connection = try provider.makeConnection(credential: .init(reference: "fixture-key", version: 1))
        let value = try ProviderConnectionTestModel(catalog: catalog, connection: connection)

        try value.model.validate()
        try value.preset.validate()
        #expect(value.isSaved == false)
        #expect(value.model.reference == .init(connectionID: connection.id, modelID: catalog.id))
        #expect(value.model.invocations.first?.endpointID == "primary")
        #expect(value.model.facts.contains { $0.source == .catalog })
        #expect(value.preset.invocationID == "default")
        #expect(value.preset.configuration.value == .object([:]))
    }

    @Test func unknownContextRemainsSavableButCandidateValidationReportsMissingLimit() throws {
        let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
        let connection = try provider.makeConnection(credential: .init(reference: "fixture-key", version: 1))
        let configured = try ProviderModelCatalog.bundled.configuration(
            connection: connection, modelID: "unlisted-model")
        #expect(configured.model.invocations.first?.contextWindow == nil)
        try configured.model.validate()
        try configured.preset.validate()
        #expect(throws: MiraError.self) {
            try AgentModelRouteCandidate(connection: connection, model: configured.model,
                                         preset: configured.preset).validate()
        }
    }

    @Test func savedValuesAreRetainedWithoutReconstruction() throws {
        let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
        let connection = try provider.makeConnection(credential: .init(reference: "fixture-key", version: 1))
        let invocation = try provider.model(id: "gpt-4")!.invocation(connection: connection)
        let model = AgentConfiguredModel(
            id: .init(), revision: 12, authorizationRevision: 8,
            reference: .init(connectionID: connection.id, modelID: "saved-model"),
            displayName: "Saved model", isEnabled: false, invocations: [invocation], facts: [])
        let preset = AgentRoutePreset(
            id: RouteID(model.id.rawValue), revision: 13, name: "Saved route",
            modelDescriptorID: model.id, invocationID: invocation.id, maximumOutputTokens: 2_048,
            configuration: .init(schema: invocation.configuration.schema, value: .object(["kept": .bool(true)])))

        let value = ProviderConnectionTestModel(model: model, preset: preset)
        #expect(value.isSaved)
        #expect(value.model == model)
        #expect(value.preset == preset)
        #expect(value.id == "saved-model")
    }
}
