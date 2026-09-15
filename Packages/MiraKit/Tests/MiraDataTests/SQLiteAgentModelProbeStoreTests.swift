import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("SQLite model capability probes", .timeLimit(.minutes(1)))
struct SQLiteAgentModelProbeStoreTests {
    @Test func saveUsesExactCandidateAndAdvancesModelCAS() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-probe-(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
        let database = try DatabaseQueue(
            path: directory.appendingPathComponent("business.sqlite").path, configuration: configuration)
        let authority = try SQLiteLibraryAuthority(database: database)
        let authorization = try await authority.authorization()
        let settings = try SQLiteAgentModelSettings(database: database, libraryID: authority.libraryID)
        let config = AgentConfigurationValue(schema: .init(id: "probe.schema", revision: 1), value: .object([:]))
        let connection = AgentConfiguredConnection(id: .init(), revision: 1, configurationRevision: 1, name: "Probe", isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: config, credential: nil)], discovery: nil, defaultInvocation: nil)
        let model = AgentConfiguredModel(id: .init(), revision: 1, authorizationRevision: 1, reference: .init(connectionID: connection.id, modelID: "probe"), displayName: nil, isEnabled: true, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: .init(id: "probe.adapter", revision: 1), endpointID: "primary", contextWindow: 4096, maximumOutputTokens: nil, capabilities: [AgentModelCapabilityID.streamingText: .declared], configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: modelParameterSchema)], facts: [])
        let preset = AgentRoutePreset(id: RouteID(model.id.rawValue), revision: 1, name: "Probe route", modelDescriptorID: model.id, invocationID: "default", maximumOutputTokens: 128, configuration: config)
        try await settings.saveConnection(connection, expectedRevision: nil, authorization: authorization)
        try await settings.savePoolModel(
            model, preset: preset, expectedModelRevision: nil,
            expectedPresetRevision: nil, authorization: authorization)
        let candidate = try await settings.candidate(routeID: preset.id)
        let probe = try AgentModelProbeStoreObservationFixture.observation(candidate: candidate)
        let store = try SQLiteAgentModelProbeStore(database: database, libraryID: authority.libraryID)
        try await store.save(probe, authorization: authorization)
        let updated = try await settings.model(id: model.id)
        #expect(updated?.revision == 2)
        #expect(updated?.invocations.first?.capabilities[AgentModelCapabilityID.streamingText] == .declared)
        #expect(updated?.facts.contains {
            $0.source == .probe &&
            $0.field == "observation.mira.probe.test" &&
            $0.value == .string("verified") &&
            $0.invocationID == "default" &&
            $0.configurationFingerprint != nil
        } == true)
        await #expect(throws: MiraError.self) { try await store.save(probe, authorization: authorization) }
        await settings.close()
        await authority.close()
        try database.close()
    }
}

private enum AgentModelProbeStoreObservationFixture {
    static func observation(candidate: AgentModelRouteCandidate) throws -> AgentModelProbeObservation {
        .init(
            candidate: candidate,
            probe: .init(id: "probe.test", revision: 1, title: "Probe", capabilityIDs: ["mira.probe.test"]),
            outcome: .verified, observedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
}
