import Foundation
@testable import MiraCore
import XCTest

final class EverydayMemoryBaselineTests: XCTestCase {
    /// Exercise v3 classification fields with authored labels, independently of language.
    /// This tests structural policy only; semantic accuracy requires a real extractor eval.
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
            let source = Self.syntheticEvidence(text: scenario.statement, executionID: executionID)
            let annotation = corpus.hostAnnotations[scenario.id]
            let item: [String: Any] = [
                "content": scenario.statement, "inputIndex": 0,
                "kind": "preference", "subject": "user", "sensitivity": "standard",
                "inferred": false, "stable": true, "confidence": "high",
                "validFrom": NSNull(), "validUntil": NSNull(),
                "assertion": ["mode": annotation?.assertionMode ?? "uncertain", "aspectKey": annotation?.aspectKey ?? "unannotated.preference", "changeIntent": annotation?.changeIntent ?? "independent"]
            ]
            let data = try JSONSerialization.data(withJSONObject: ["version": 3, "items": [item]])
            let proposals = try MemoryExtractionValidator.validate(
                output: String(decoding: data, as: UTF8.self), source: source)
            let active = proposals.contains { $0.triage == .active }
            results.append(.init(id: scenario.id, expected: scenario.expectation, gate: active ? "active" : "candidate"))
            if scenario.expectation == "notActive" {
                XCTAssertFalse(active, "Unsafe automatic activation for authored case: \(scenario.id)")
            }
        }
        let report = Report(
            qualification: "none; authored semantic labels test v3 host policy, not extractor accuracy",
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

    private static func syntheticEvidence(text: String, executionID: ExecutionID) -> SessionUserEvidence {
        let sessionID = ConversationID()
        let batchID = UUID()
        let reference = SessionEvidenceReference(
            sessionID: sessionID, originalExecutionID: executionID, userMessageID: MessageID(),
            admissionEventID: UUID(), admissionSequence: 1)
        return SessionUserEvidence(
            reference: reference, workspaceID: nil, admittedAt: Date(timeIntervalSince1970: 1_000),
            timeZoneIdentifier: "UTC", text: text,
            observedHead: .init(cursor: .init(sessionID: sessionID, sequence: 1), batchID: batchID),
            sessionAuthorizationEpoch: 0)
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
