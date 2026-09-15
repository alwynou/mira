import Foundation
import Testing

@testable import MiraCore
@testable import MiraProviders

@Suite("HTTP model probes")
struct HTTPModelProbeTests {
    @Test func providerExposesTextToolsAndJSONWithoutVendorSwitches() throws {
        let definitions = try HTTPModelProbeProvider().probes()
        #expect(definitions.map(\.identity.id) == ["mira.probe.text", "mira.probe.tools", "mira.probe.json"])
        #expect(definitions.allSatisfy { $0.identity.revision == 1 && !$0.identity.title.isEmpty })
        #expect(try definitions[0].makeInput(stepID: UUID(), executionID: ExecutionID(), route: route()).tools.isEmpty)
        #expect(
            try definitions[1].makeInput(stepID: UUID(), executionID: ExecutionID(), route: route()).tools.map(\.name)
                == ["probe.echo"])
    }

    @Test func JSONProbeDoesNotTreatPlainTextAsVerified() throws {
        let definition = try HTTPModelProbeProvider().probes().first { $0.identity.id == "mira.probe.json" }!
        let plain = AgentModelOutput(blocks: [.init(id: "text", content: .text("OK"))], continuation: nil, usage: .init(), finishReason: .stop)
        let object = AgentModelOutput(
            blocks: [.init(id: "text", content: .text("{\"result\":\"OK\"}"))], continuation: nil, usage: .init(), finishReason: .stop)
        #expect(try definition.evaluate(plain) == .unsupported)
        #expect(try definition.evaluate(object) == .verified)
    }

    private func route() -> AgentModelRoute {
        .init(
            id: .init(), revision: 1, connectionID: .init(), connectionRevision: 1,
            modelDescriptorID: .init(), modelRevision: 1, adapter: .init(id: "probe.adapter", revision: 1),
            modelID: "probe", credential: nil, contextWindow: 4096, maximumOutputTokens: 128,
            capabilities: .init(streamsText: true, callsTools: true, producesThinking: false),
            configuration: .object([:]))
    }
}
