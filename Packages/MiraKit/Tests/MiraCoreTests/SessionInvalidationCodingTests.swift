import Foundation
import Testing

@testable import MiraCore

@Suite("Stable session invalidation coding")
struct SessionInvalidationCodingTests {
    @Test func identitiesEncodeInCanonicalOrderAndSurviveRoundTrips() throws {
        let executions = (0..<32).map { _ in ExecutionID() }
        let groups = (0..<32).map { _ in UUID() }
        let fact = SessionInvalidation(
            operationID: UUID(), executionIDs: Set(executions), retentionGroups: Set(groups),
            authorizationEpoch: 1, reason: .forgotten)
        let bytes = try SessionCodec.encode(fact)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object["retentionGroups"] as? [String] == groups.map(\.uuidString).sorted())
        for _ in 0..<20 {
            let decoded = try SessionCodec.decode(SessionInvalidation.self, from: bytes)
            #expect(decoded == fact)
            #expect(try SessionCodec.encode(decoded) == bytes)
        }
    }

    @Test(arguments: ["executionIDs", "retentionGroups"])
    func duplicateIdentitiesAreRejected(field: String) throws {
        let fact = SessionInvalidation(
            operationID: UUID(), executionIDs: [ExecutionID()], retentionGroups: [UUID()],
            authorizationEpoch: 1, reason: .forgotten)
        var object = try #require(JSONSerialization.jsonObject(with: SessionCodec.encode(fact)) as? [String: Any])
        let values = try #require(object[field] as? [Any])
        object[field] = values + values
        let bytes = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { _ = try SessionCodec.decode(SessionInvalidation.self, from: bytes) }
    }
}
