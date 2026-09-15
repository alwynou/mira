import Foundation
import Testing

@testable import MiraCore

@Suite("Agent model probes")
struct AgentModelProbeTests {
    @Test func identitiesAreDiscoverableAndSorted() throws {
        let first = try definition(id: "probe.z", capability: "cap.z")
        let second = try definition(id: "probe.a", capability: "cap.a")
        let catalog = try AgentModelProbeCatalog(providers: [ProbeProvider(values: [first, second])])
        #expect(catalog.identities.map(\.id) == ["probe.a", "probe.z"])
        #expect(try catalog.definition(id: "probe.a").identity.capabilityIDs == ["cap.a"])
        #expect(throws: MiraError.self) { try catalog.definition(id: "missing") }
    }

    @Test func duplicateProbeIdentityIsRejected() throws {
        let one = try definition(id: "probe.same", capability: "cap.one")
        let two = try definition(id: "probe.same", capability: "cap.two")
        #expect(throws: MiraError.self) {
            try AgentModelProbeCatalog(providers: [ProbeProvider(values: [one]), ProbeProvider(values: [two])])
        }
    }

    @Test func registrySnapshotOwnsProbeProviderForTheCatalogGeneration() async throws {
        let registry = RuntimeRegistry<AgentCapability>()
        let scope = RuntimeScope(kind: .application)
        let value = try definition(id: "probe.registered", capability: "cap.registered")
        try await registry.register(id: "probes", value: .modelProbe(ProbeProvider(values: [value])), scope: scope)
        let snapshot = try await registry.freeze()
        let catalog = try AgentRuntimeCatalog(snapshot: snapshot)
        #expect(catalog.probes.identities.map(\.id) == ["probe.registered"])
        #expect(try catalog.probe(id: "probe.registered").identity == value.identity)
        await catalog.release()
    }

    @Test func evaluatorCanReturnOnlyVerifiedOrUnsupported() throws {
        let probe = try definition(id: "probe.result", capability: "cap.result")
        let route = testRoute()
        let input = try probe.makeInput(stepID: UUID(), executionID: ExecutionID(), route: route)
        #expect(input.messages.count == 1)
        #expect(
            try probe.evaluate(.init(blocks: [], continuation: nil, usage: .init(), finishReason: .stop))
                == .unsupported)
        #expect(
            try probe.evaluate(.init(blocks: [.init(id: "answer", content: .text("OK"))], continuation: nil, usage: .init(), finishReason: .stop))
                == .verified)
    }

    private func definition(id: String, capability: String) throws -> AgentModelProbeDefinition {
        try .init(
            identity: .init(id: id, revision: 1, title: "Probe", capabilityIDs: [capability]),
            preparationCapabilityIDs: [capability],
            prepareCandidate: { $0 },
            makeInput: { stepID, executionID, _ in
                .init(
                    stepID: stepID, executionID: executionID, instructions: "probe",
                    messages: [.init(role: .user, blocks: [.init(id: "user", content: .text("probe"))])], tools: [])
            }, evaluate: { $0.text.isEmpty ? .unsupported : .verified })
    }

    private func testRoute() -> AgentModelRoute {
        .init(
            id: .init(), revision: 1, connectionID: .init(), connectionRevision: 1,
            modelDescriptorID: .init(), modelRevision: 1, modelAuthorizationRevision: 1, adapter: .init(id: "probe.adapter", revision: 1),
            invocationID: "default", invocationRevision: 1, endpointID: "primary", metadataEvidence: [],
            modelID: "probe", credential: nil, contextWindow: 4096, maximumOutputTokens: 128,
            capabilities: .init(streamsText: true, callsTools: false, producesThinking: false),
            configuration: .object([:]))
    }
}

private struct ProbeProvider: AgentModelProbeProvider {
    let values: [AgentModelProbeDefinition]
    func probes() throws -> [AgentModelProbeDefinition] { values }
}
