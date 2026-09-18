import Foundation
import Testing
@testable import MiraCore

@Suite("Session tool observations")
struct SessionToolObservationTests {
    @Test func rendersNullResultAndStatus() throws {
        let resolution = SessionToolResolution(invocationID: UUID(), status: .denied,
                                                error: MiraError(.unauthorized, "Policy denied the tool."))
        let value = try SessionToolObservation.value(resolution)
        #expect(try value.jsonString() == "{\"authority\":\"untrusted_tool_observation\",\"content\":null,\"error\":{\"code\":\"unauthorized\",\"message\":\"Policy denied the tool.\"},\"status\":\"denied\"}")
    }

    @Test func preservesStructuredResultAndOmitsAbsentError() throws {
        let raw = Data(#"{"answer":"ok","items":[1,2]}"#.utf8)
        let resolution = SessionToolResolution(invocationID: UUID(), status: .succeeded,
            result: SessionContent(kind: .toolResult, bytes: raw))
        let value = try SessionToolObservation.value(resolution)
        #expect(try value.jsonString() == "{\"authority\":\"untrusted_tool_observation\",\"content\":{\"answer\":\"ok\",\"items\":[1,2]},\"status\":\"succeeded\"}")
        #expect(resolution.result?.bytes == raw)
    }

    @Test func rejectsNonToolResultContent() {
        let resolution = SessionToolResolution(invocationID: UUID(), status: .failed,
            result: SessionContent(kind: .userText, bytes: Data(#"{"x":1}"#.utf8)))
        #expect(throws: MiraError.self) { try SessionToolObservation.value(resolution) }
    }
}
