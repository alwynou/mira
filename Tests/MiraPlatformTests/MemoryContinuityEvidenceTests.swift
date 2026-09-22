import Foundation
import MiraCore
import XCTest

final class MemoryContinuityEvidenceTests: XCTestCase {
    func testCorpusHasOneNaturalScenarioForEveryLanguageAndMode() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "continuity", withExtension: "json"))
        let corpus = try JSONDecoder().decode(MemoryContinuityCorpus.self, from: Data(contentsOf: url))
        XCTAssertNoThrow(try corpus.validate())
        XCTAssertEqual(corpus.scenarios.count, 4)
        XCTAssertEqual(Set(corpus.scenarios.map(\.id)).count, 4)
        XCTAssertEqual(Set(corpus.scenarios.map { "\($0.language):\($0.mode.rawValue)" }), [
            "en:automatic", "en:explicitSave", "zh-CN:automatic", "zh-CN:explicitSave"
        ])
        XCTAssertTrue(corpus.scenarios.allSatisfy {
            !$0.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
    }

    func testCorpusValidationRejectsMalformedCoverageAndEmptyText() throws {
        let scenario = MemoryContinuityScenario(id: "one", language: "en", input: "A preference.", followUp: "A question.", mode: .automatic)
        let valid = [
            scenario,
            .init(id: "two", language: "en", input: "A preference.", followUp: "A question.", mode: .explicitSave),
            .init(id: "three", language: "zh-CN", input: "A preference.", followUp: "A question.", mode: .automatic),
            .init(id: "four", language: "zh-CN", input: "A preference.", followUp: "A question.", mode: .explicitSave)
        ]
        XCTAssertNoThrow(try MemoryContinuityCorpus(version: 1, scenarios: valid).validate())

        let cases: [(MemoryContinuityCorpus, MemoryContinuityCorpusError)] = [
            (.init(version: 1, scenarios: Array(valid.dropLast())), .invalidScenarioCount(3)),
            (.init(version: 1, scenarios: valid + [valid[0]]), .invalidScenarioCount(5)),
            (.init(version: 1, scenarios: [valid[0], valid[0], valid[2], valid[3]]), .duplicateScenarioID("one")),
            (.init(version: 1, scenarios: [valid[0], valid[1], .init(id: "three", language: "fr", input: "A.", followUp: "B.", mode: .automatic), valid[3]]), .unknownLanguage("fr")),
            (.init(version: 1, scenarios: [valid[0], valid[1], .init(id: "three", language: "zh-CN", input: " ", followUp: "A question.", mode: .automatic), valid[3]]), .emptyInput("three")),
            (.init(version: 1, scenarios: [valid[0], valid[1], .init(id: "three", language: "zh-CN", input: "A preference.", followUp: " \n", mode: .automatic), valid[3]]), .emptyFollowUp("three"))
        ]
        for (corpus, expected) in cases {
            XCTAssertThrowsError(try corpus.validate()) { error in
                XCTAssertEqual(error as? MemoryContinuityCorpusError, expected)
            }
        }
    }

    func testEstablishmentRequiresFreshSourceBoundRecordForEachMode() {
        let sourceExecution = "execution-1"
        let sourceReference = "session:session-1/execution:execution-1/message:message-1/admission:admission-1@1"
        for mode in MemoryContinuityMode.allCases {
            let memory = snapshot(mode: mode, sourceExecutionID: sourceExecution, sourceReference: sourceReference)
            XCTAssertTrue(MemoryContinuityAssertions.establishmentFailures(
                memories: [memory], mode: mode, sourceExecutionID: sourceExecution, sourceReference: sourceReference).isEmpty)
        }
    }

    func testEstablishmentRejectsFalsePositiveRecordsAndMissingEvidence() {
        let sourceExecution = "execution-1"
        let sourceReference = "session:session-1/execution:execution-1/message:message-1/admission:admission-1@1"
        let baseline = snapshot(mode: .automatic, sourceExecutionID: sourceExecution, sourceReference: sourceReference)
        XCTAssertTrue(MemoryContinuityAssertions.establishmentFailures(
            memories: [], mode: .automatic, sourceExecutionID: sourceExecution, sourceReference: sourceReference)
            .contains("establishment_memory_count_mismatch"))
        XCTAssertTrue(MemoryContinuityAssertions.establishmentFailures(
            memories: [baseline, baseline], mode: .automatic, sourceExecutionID: sourceExecution, sourceReference: sourceReference)
            .contains("establishment_memory_count_mismatch"))

        let malformed = baseline.with(evidenceExecutionIDs: ["other"], evidenceSourceReferences: ["other"], detailAvailable: false, body: "")
        let failures = MemoryContinuityAssertions.establishmentFailures(
            memories: [malformed], mode: .automatic, sourceExecutionID: sourceExecution, sourceReference: sourceReference)
        XCTAssertTrue(failures.contains("establishment_memory_details_unavailable"))
        XCTAssertTrue(failures.contains("establishment_memory_body_unavailable"))
        XCTAssertTrue(failures.contains("establishment_source_evidence_mismatch"))
    }

    func testEstablishmentRejectsWrongAuthorityRevisionAndHistory() {
        let sourceExecution = "execution-1"
        let sourceReference = "session:session-1/execution:execution-1/message:message-1/admission:admission-1@1"
        let baseline = snapshot(mode: .automatic, sourceExecutionID: sourceExecution, sourceReference: sourceReference)
        let malformed = StateEvolutionMemorySnapshot(
            id: baseline.id, revision: 2, state: "active", lifecycle: "active", isCurrent: true,
            body: baseline.body, origin: "explicitUser", authority: "explicitUser", forgottenAt: nil,
            supersededByID: "successor", evidenceSourceReferences: baseline.evidenceSourceReferences,
            evidenceExecutionIDs: baseline.evidenceExecutionIDs, revisionNumbers: [1, 2], previousMemoryIDs: ["predecessor"],
            evidenceCount: 1, evidenceExcerptCount: 1, evidenceHashCount: 1, revisionBodyCount: 2,
            detailAvailable: true, detailErrorCode: nil, retraction: nil)
        let failures = MemoryContinuityAssertions.establishmentFailures(
            memories: [malformed], mode: .automatic, sourceExecutionID: sourceExecution, sourceReference: sourceReference)
        XCTAssertTrue(failures.contains("establishment_authority_mismatch"))
        XCTAssertTrue(failures.contains("establishment_revision_mismatch"))
        XCTAssertTrue(failures.contains("establishment_replacement_or_history_present"))
    }

    func testPreservationAddsStrictDetailAndBodyChecksToExistingAssertions() {
        let sourceExecution = "execution-1"
        let sourceReference = "session:session-1/execution:execution-1/message:message-1/admission:admission-1@1"
        let baseline = snapshot(mode: .automatic, sourceExecutionID: sourceExecution, sourceReference: sourceReference)
        XCTAssertTrue(MemoryContinuityAssertions.preservationFailures(memories: [baseline], baseline: baseline).isEmpty)

        let malformed = baseline.with(detailAvailable: false, body: "")
        let failures = MemoryContinuityAssertions.preservationFailures(memories: [malformed], baseline: baseline)
        XCTAssertTrue(failures.contains("preservation_assertion_changed"))
        XCTAssertTrue(failures.contains("continuity_memory_details_unavailable"))
        XCTAssertTrue(failures.contains("continuity_memory_body_unavailable"))
        XCTAssertFalse(MemoryContinuityAssertions.preservationFailures(memories: [], baseline: nil).isEmpty)
    }

    private func snapshot(mode: MemoryContinuityMode, sourceExecutionID: String, sourceReference: String) -> StateEvolutionMemorySnapshot {
        .init(id: "memory-1", revision: 1, state: "active", lifecycle: "active", isCurrent: true,
              body: "A durable low-risk preference.", origin: mode == .automatic ? "observedUserStatement" : "explicitUser",
              authority: mode == .automatic ? "observedUser" : "explicitUser", forgottenAt: nil, supersededByID: nil,
              evidenceSourceReferences: [sourceReference], evidenceExecutionIDs: [sourceExecutionID], revisionNumbers: [1],
              previousMemoryIDs: [], evidenceCount: 1, evidenceExcerptCount: 1, evidenceHashCount: 1,
              revisionBodyCount: 1, detailAvailable: true, detailErrorCode: nil, retraction: nil)
    }
}
