import Foundation
import MiraCore
import Testing
@testable import MiraProviders

@Suite("Model capability presentation")
struct ModelCapabilitySummaryTests {
    @Test func explicitTextOnlyAndNegativeCapabilitiesOverrideCatalogBadges() throws {
        let (model, catalog) = try fixture()
        let facts: [AgentModelMetadataFact] = [
            .init(field: AgentModelMetadataField.inputModalities, value: .array([.string("text")]),
                  source: .user, sourceID: "fixture.user", sourceRevision: "1", observedAt: Date(), invocationID: "default"),
            .init(field: AgentModelMetadataField.capability(AgentModelCapabilityID.toolCalls), value: .bool(false),
                  source: .user, sourceID: "fixture.user", sourceRevision: "1", observedAt: Date(), invocationID: "default"),
            .init(field: AgentModelMetadataField.capability(AgentModelCapabilityID.thinking), value: .bool(false),
                  source: .provider, sourceID: "fixture.provider", sourceRevision: "1", observedAt: Date(), invocationID: "default")
        ]
        let updated = replacingFacts(model, model.facts + facts)
        let summary = try ModelCapabilitySummary(model: updated, invocationID: "default", catalog: catalog)
        #expect(!summary.vision)
        #expect(!summary.tools)
        #expect(!summary.thinking)
        let original = try ModelCapabilitySummary(model: model, invocationID: "default", catalog: catalog)
        #expect(original.vision && original.tools && original.thinking)
    }

    @Test func otherInvocationFactsCannotOverrideCurrentModelAndConflictsFailClosed() throws {
        let (model, catalog) = try fixture()
        let text = AgentModelMetadataFact(field: AgentModelMetadataField.inputModalities,
            value: .array([.string("text")]), source: .user, sourceID: "fixture.user", sourceRevision: "1",
            observedAt: Date(), invocationID: "other")
        #expect(try ModelCapabilitySummary(model: replacingFacts(model, model.facts + [text]),
            invocationID: "default", catalog: catalog).vision)
        let conflict = AgentModelMetadataFact(field: AgentModelMetadataField.inputModalities,
            value: .array([.string("text")]), source: .catalog, sourceID: "fixture.conflict", sourceRevision: "1",
            observedAt: Date(), invocationID: "default")
        #expect(throws: (any Error).self) {
            try ModelCapabilitySummary(model: replacingFacts(model, model.facts + [conflict]), invocationID: "default", catalog: catalog)
        }
        #expect(try !ModelCapabilitySummary(model: replacingFacts(model, []), invocationID: "default").vision)
    }

    private func fixture() throws -> (AgentConfiguredModel, CatalogModelMetadata) {
        let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "deepseek" })
        let catalog = try #require(provider.model(id: "deepseek-flash"))
        let connection = try provider.makeConnection(credential: nil)
        return (try catalog.makeModel(connection: connection).model, catalog.metadata)
    }

    private func replacingFacts(_ model: AgentConfiguredModel, _ facts: [AgentModelMetadataFact]) -> AgentConfiguredModel {
        .init(id: model.id, revision: model.revision, authorizationRevision: model.authorizationRevision,
              reference: model.reference, displayName: model.displayName, isEnabled: model.isEnabled,
              invocations: model.invocations, facts: facts)
    }
}
