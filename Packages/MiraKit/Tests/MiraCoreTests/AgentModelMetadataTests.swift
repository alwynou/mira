import Foundation
import Testing
@testable import MiraCore

@Suite("Model metadata field resolution")
struct AgentModelMetadataTests {
    @Test func overridesAndSourceRecencyAreIndependentOfInputOrder() throws {
        let facts = [
            fact(100, .catalog, "catalog-a"), fact(200, .catalog, "catalog-b"),
            fact(300, .provider, "provider", time: 1), fact(400, .provider, "provider", time: 2),
            fact(500, .user, "settings")
        ]
        for order in [facts, facts.reversed(), Array(facts.dropFirst()) + [facts[0]]] {
            let resolved = try AgentModelMetadataResolver.resolve(spec(), facts: Array(order))
            #expect(resolved.contextWindow == 500)
        }
        let provider = Array(facts.dropLast())
        #expect(try AgentModelMetadataResolver.resolve(spec(), facts: provider).contextWindow == 400)
        #expect(try AgentModelMetadataResolver.resolve(spec(), facts: provider.reversed()).contextWindow == 400)
    }

    @Test func equalAuthorityConflictsAndInvalidLimitsDoNotGuess() throws {
        for values in [[fact(100, .provider, "a"), fact(200, .provider, "b")],
                       [fact(100, .provider, "a"), fact(200, .provider, "a")]] {
            #expect(throws: MiraError.self) { try AgentModelMetadataResolver.resolve(spec(), facts: values) }
            #expect(throws: MiraError.self) { try AgentModelMetadataResolver.resolve(spec(), facts: values.reversed()) }
        }
        #expect(throws: MiraError.self) { try AgentModelMetadataResolver.resolve(spec(), facts: [fact(-1, .user, "settings")]) }
    }

    @Test func invocationSpecificFactsAndProbesStayScoped() throws {
        let other = fact(200, .user, "settings", invocation: "other")
        let probe = AgentModelMetadataFact(field: AgentModelMetadataField.contextWindow, value: .number(800),
                                          source: .probe, sourceID: "probe", sourceRevision: "1",
                                          observedAt: .init(timeIntervalSince1970: 1), invocationID: "default",
                                          configurationFingerprint: "fixture-hash")
        let generic = fact(300, .catalog, "catalog", invocation: nil)
        let specific = fact(400, .catalog, "catalog")
        #expect(try AgentModelMetadataResolver.resolve(spec(), facts: [other, probe]).contextWindow == nil)
        let selected = try AgentModelMetadataResolver.selectedFacts(for: "default", facts: [generic, specific, other, probe])
        #expect(selected[AgentModelMetadataField.contextWindow] == specific)
    }

    @Test func metadataResolutionPreservesRequestAndAuthorizationInputs() throws {
        let original = spec()
        let resolved = try AgentModelMetadataResolver.resolve(original, facts: [fact(4096, .catalog, "catalog")])
        #expect(resolved.configuration == original.configuration)
        #expect(resolved.adapter == original.adapter)
        #expect(resolved.endpointID == original.endpointID)
        #expect(resolved.parameterSchema == original.parameterSchema)
        #expect(resolved.contextWindow == 4096)
    }

    @Test func removingInvocationRevokesOldAuthorizationWithoutPenalizingAdditions() throws {
        let reference = AgentModelReference(connectionID: .init(), modelID: "same-name")
        let id = ModelDescriptorID()
        func model(_ specs: [AgentModelInvocationSpec], authorization: Int = 1) -> AgentConfiguredModel {
            .init(id: id, revision: 3, authorizationRevision: authorization, reference: reference,
                  displayName: nil, isEnabled: true, invocations: specs, facts: [])
        }
        let original = model([spec()])
        let removed = model([], authorization: 2)
        #expect(try removed.authorizationRevision(replacing: original) == 2)
        #expect(try model([spec()], authorization: 2).authorizationRevision(replacing: removed) == 2)
        #expect(try model([spec(), spec(id: "second")]).authorizationRevision(replacing: original) == 1)
    }

    private func fact(_ value: Double, _ source: AgentModelMetadataSourceKind, _ sourceID: String,
                      time: TimeInterval = 1, invocation: String? = "default") -> AgentModelMetadataFact {
        .init(field: AgentModelMetadataField.contextWindow, value: .number(value), source: source,
              sourceID: sourceID, sourceRevision: String(time), observedAt: .init(timeIntervalSince1970: time), invocationID: invocation)
    }
    private func spec(id: String = "default") -> AgentModelInvocationSpec {
        .init(id: id, revision: 1, adapter: .init(id: "fixture.model", revision: 1), endpointID: "primary",
              contextWindow: nil, maximumOutputTokens: nil, capabilities: [:],
              configuration: .init(schema: .init(id: "fixture.invocation", revision: 1), value: .object([:])),
              parameterSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]))
    }
}
