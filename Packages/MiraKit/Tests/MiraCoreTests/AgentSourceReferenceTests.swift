import Foundation
import Testing
@testable import MiraCore

@Suite("Typed agent source references")
struct AgentSourceReferenceTests {
    @Test func sourceKindsPreserveIdentityAndRoundTripWithoutAmbiguity() throws {
        let id = UUID(), sessionA = ConversationID(), sessionB = ConversationID()
        let sources: [AgentSourceReference] = [
            .domain(namespace: "memory", id: id, revision: 1),
            .domain(namespace: "memory", id: id, revision: 2),
            .sessionExecution(sessionID: sessionA, executionID: ExecutionID(id)),
            .sessionExecution(sessionID: sessionB, executionID: ExecutionID(id))
        ]
        for source in sources {
            try source.validate()
            #expect(try SessionCodec.decode(AgentSourceReference.self, from: SessionCodec.encode(source)) == source)
        }
        #expect(Set(sources).count == 4)
        let ordered = AgentContextBuild.orderedSources(sources + sources.reversed())
        #expect(Set(ordered) == Set(sources))
        #expect(ordered == AgentContextBuild.orderedSources(sources.reversed()))
        #expect(ordered.prefix(2) == sources.prefix(2))
    }

    @Test func domainSourcesRequireValidNamesAndRevisions() {
        for source in [AgentSourceReference.domain(namespace: "", id: UUID(), revision: 1),
                       .domain(namespace: "memory", id: UUID(), revision: 0),
                       .domain(namespace: "bad source", id: UUID(), revision: 1)] {
            #expect(throws: MiraError.self) { try source.validate() }
        }
    }

    @Test func unqualifiedSourceObjectsAreNotDecodedAsCurrentSources() throws {
        let value: JSONValue = .object(["namespace": .string("memory"), "id": .string(UUID().uuidString), "revision": .number(1)])
        #expect(throws: DecodingError.self) {
            try SessionCodec.decode(AgentSourceReference.self, from: SessionCodec.encode(value))
        }
    }
}
