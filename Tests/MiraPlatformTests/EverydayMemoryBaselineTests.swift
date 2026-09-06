import Foundation
import MiraCore
import XCTest

final class EverydayMemoryBaselineTests: XCTestCase {
    /// Give the host an optimistic, whole-source proposal for every utterance.
    /// This isolates the host gate; it is neither an extractor nor an LLM eval.
    func testCorpusSafetyAndRecordCaptureCoverage() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "scenarios", withExtension: "json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        XCTAssertEqual(corpus.version, 1)
        XCTAssertEqual(corpus.scenarios.count, 32)
        XCTAssertEqual(Set(corpus.scenarios.map(\.id)).count, 32)
        for language in ["en", "zh-CN"] {
            for expectation in ["active", "notActive"] {
                XCTAssertEqual(corpus.scenarios.filter { $0.language == language && $0.expectation == expectation }.count, 8)
            }
        }

        var results: [Observation] = []
        for scenario in corpus.scenarios {
            let executionID = ExecutionID()
            let message = Message(id: .init(), conversationID: .init(), executionID: executionID, sequence: 1, role: .user, status: .committed, text: scenario.statement, createdAt: Date(timeIntervalSince1970: 1_000))
            let source = MemoryExtractionSource(message: message, executionID: executionID, workspaceID: nil, sourceHash: "synthetic")
            let annotation = corpus.hostAnnotations[scenario.id]
            let item: [String: Any] = [
                "content": scenario.statement, "quote": scenario.statement,
                "kind": "preference", "subject": "user", "sensitivity": "standard",
                "inferred": false, "stable": true, "confidence": "high",
                "validFrom": NSNull(), "validUntil": NSNull(),
                "assertion": ["mode": annotation?.assertionMode ?? "directStable", "aspectKey": annotation?.aspectKey ?? "unannotated.preference", "changeIntent": annotation?.changeIntent ?? "independent"]
            ]
            let data = try JSONSerialization.data(withJSONObject: ["version": 2, "items": [item]])
            let proposals = try MemoryExtractionValidator.validate(output: String(decoding: data, as: UTF8.self), source: source, mode: .automaticWithUndo)
            let active = proposals.contains { $0.triage == .active }
            results.append(.init(id: scenario.id, expected: scenario.expectation, gate: active ? "active" : "candidate"))
            if scenario.expectation == "notActive" {
                XCTAssertFalse(active, "Unsafe automatic activation for authored case: \(scenario.id)")
            }
        }
        let report = Report(
            qualification: "none; optimistic synthetic extractor output isolates host triage only",
            expectedActive: results.filter { $0.expected == "active" }.count,
            acceptedActive: results.filter { $0.expected == "active" && $0.gate == "active" }.count,
            unsafeActive: results.filter { $0.expected == "notActive" && $0.gate == "active" }.count,
            cases: results
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let attachment = XCTAttachment(data: try encoder.encode(report), uniformTypeIdentifier: "public.json")
        attachment.name = "everyday-host-triage-baseline.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Positive misses are retained as coverage gaps in the report. This CI
        // check asserts safety only and must not be described as Q04 acceptance.
        print("Everyday host gate: \(report.acceptedActive)/\(report.expectedActive) authored positives accepted; \(report.unsafeActive) unsafe activations.")
    }

    private struct Corpus: Decodable { let version: Int; let scenarios: [Scenario]; let hostAnnotations: [String: HostAnnotation] }
    private struct HostAnnotation: Decodable { let assertionMode: String; let aspectKey: String; let changeIntent: String }
    private struct Scenario: Decodable {
        let id: String
        let language: String
        let expectation: String
        let statement: String
    }
    private struct Observation: Encodable { let id: String; let expected: String; let gate: String }
    private struct Report: Encodable {
        let qualification: String
        let expectedActive: Int
        let acceptedActive: Int
        let unsafeActive: Int
        let cases: [Observation]
    }
}
