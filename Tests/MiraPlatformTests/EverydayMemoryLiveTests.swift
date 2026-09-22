import Foundation
import MiraCore
import MiraData
import MiraProviders
import XCTest

/// Opt-in, bounded live-provider evaluation for the authored everyday-memory corpus.
/// A fresh library and an in-memory credential reader are used for every case; the
/// selected user library and system Keychain are never opened.
final class EverydayMemoryLiveTests: XCTestCase {
    func testOfflineEvaluationSetupReusesOneModelAndRequiresExplicitLimits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mira-Evaluation-Setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let corpus = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "scenarios", withExtension: "json"))
        var environment = [
            "MIRA_EVAL_CORPUS": corpus.path,
            "MIRA_EVAL_REPORT": directory.appendingPathComponent("report.json").path,
            "MIRA_EVAL_ENDPOINT": "https://fixture.invalid/v1",
            "MIRA_EVAL_API_KEY": "synthetic-evaluation-secret",
            "MIRA_EVAL_PROTOCOL": HTTPProtocolID.responses.rawValue,
            "MIRA_EVAL_CONVERSATION_MODEL": "gpt-4",
            "MIRA_EVAL_CASE_IDS": "synthetic-case",
        ]
        XCTAssertThrowsError(try LiveEvaluationConfiguration(environment: environment))
        environment["MIRA_EVAL_CONTEXT_WINDOW"] = "8192"
        environment["MIRA_EVAL_CONVERSATION_OUTPUT"] = "0"
        XCTAssertThrowsError(try LiveEvaluationConfiguration(environment: environment))
        environment["MIRA_EVAL_CONVERSATION_OUTPUT"] = "1024"
        let configuration = try LiveEvaluationConfiguration(environment: environment)
        let counter = RequestAuthorizationCounter()
        let credentials = EvaluationCredentials(secret: configuration.apiKey, counter: counter, limit: 1)
        let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
            directory: directory.appendingPathComponent("Library"),
            notifications: LiveNoopNotifications(), credentials: credentials,
            modules: { [MacHTTPModule(registry: $0, credentials: credentials)] })
        do {
            let group = try await library.workloads()
            let routes = try await Self.installSettings(in: group, configuration: configuration)
            let models = try await group.modelSettings.models(connectionID: Optional<ConnectionID>.none, after: Optional<ModelDescriptorID>.none, limit: 128)
            let presets = try await group.modelSettings.presets(modelID: Optional<ModelDescriptorID>.none, after: Optional<RouteID>.none, limit: 128)
            XCTAssertEqual(models.count, 1)
            XCTAssertEqual(presets.count, 1)
            XCTAssertEqual(routes.conversation.modelDescriptorID, routes.extraction.modelDescriptorID)
            XCTAssertEqual(routes.conversation.id, routes.extraction.id)
            XCTAssertEqual(counter.value, 0)
            _ = await library.close()
        } catch {
            _ = await library.close()
            throw error
        }
    }

    func testStateEvolutionCorpusIsValidOffline() throws {
        let base = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "scenarios", withExtension: "json"))
        let url = base.deletingLastPathComponent().appendingPathComponent("state-evolution.json")
        let data = try Data(contentsOf: url)
        let corpus = try StateEvolutionCorpus.load(data: data)
        XCTAssertEqual(corpus.version, 1)
        XCTAssertEqual(Set(corpus.scenarios.map(\.kind)), Set(StateEvolutionKind.allCases.map(\.rawValue)))
        XCTAssertTrue(corpus.scenarios.contains { $0.kind == StateEvolutionKind.automaticEnrichment.rawValue })
        XCTAssertTrue(corpus.scenarios.contains { $0.kind == StateEvolutionKind.foregroundEnrichment.rawValue })
        let nearMisses = corpus.scenarios.filter { $0.kind == StateEvolutionKind.retractionNearMiss.rawValue }
        XCTAssertEqual(nearMisses.count, 6)
        for language in ["en", "zh-CN"] {
            XCTAssertEqual(nearMisses.filter { $0.language == language }.count, 3)
        }

        var duplicate = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var scenarios = try XCTUnwrap(duplicate["scenarios"] as? [[String: Any]])
        scenarios.append(scenarios[0])
        duplicate["scenarios"] = scenarios
        XCTAssertThrowsError(try StateEvolutionCorpus.load(data: JSONSerialization.data(withJSONObject: duplicate)))

        var unknownKind = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var unknownKindScenarios = try XCTUnwrap(unknownKind["scenarios"] as? [[String: Any]])
        unknownKindScenarios[0]["kind"] = "notAStateKind"
        unknownKind["scenarios"] = unknownKindScenarios
        XCTAssertThrowsError(try StateEvolutionCorpus.load(data: JSONSerialization.data(withJSONObject: unknownKind)))

        var missingLineageStep = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var missingLineageScenarios = try XCTUnwrap(missingLineageStep["scenarios"] as? [[String: Any]])
        missingLineageScenarios[0]["steps"] = [["input": "", "expect": "establish"]]
        missingLineageStep["scenarios"] = missingLineageScenarios
        XCTAssertThrowsError(try StateEvolutionCorpus.load(data: JSONSerialization.data(withJSONObject: missingLineageStep)))
        XCTAssertThrowsError(try corpus.selected(ids: ["unknown-state-case"]))
    }

    func testNearMissRequiresUnchangedEstablishedMemoryAndRejectsMutationAttempts() throws {
        let baseline = StateEvolutionMemorySnapshot(
            id: "preference", revision: 1, state: "active", lifecycle: "active", isCurrent: true,
            body: "I prefer aisle seats", origin: "observedUserStatement", authority: "observedUser",
            forgottenAt: nil, supersededByID: nil, evidenceSourceReferences: ["original-source"],
            evidenceExecutionIDs: ["original-execution"], revisionNumbers: [1], previousMemoryIDs: [],
            evidenceCount: 1, evidenceExcerptCount: 1, evidenceHashCount: 1, revisionBodyCount: 1,
            detailAvailable: true, detailErrorCode: nil)
        func failures(_ memories: [StateEvolutionMemorySnapshot], mutations: Int = 0,
                      context: [String]? = nil) -> [String] {
            StateEvolutionAssertions.preservationFailures(
                memories: memories, baseline: baseline, mutationInvocationCount: mutations,
                contextMemoryReferences: context)
        }
        XCTAssertTrue(failures([baseline], context: ["memory:preference@1"]).isEmpty)
        XCTAssertTrue(StateEvolutionAssertions.preservationFailures(memories: [], baseline: nil)
            .contains("preservation_predecessor_not_established"))
        XCTAssertTrue(StateEvolutionAssertions.preservationFailures(
            memories: [baseline], baseline: baseline.with(detailAvailable: false))
            .contains("preservation_predecessor_not_established"))
        XCTAssertTrue(failures([]).contains("preservation_target_missing"))
        XCTAssertTrue(failures([baseline, baseline]).contains("preservation_memory_count_changed"))
        XCTAssertTrue(failures([baseline], mutations: 1).contains("preservation_attempted_memory_mutation"))
        XCTAssertTrue(failures([baseline], context: []).contains("preserved_memory_missing_from_fresh_context"))
        XCTAssertTrue(failures([baseline], context: ["memory:preference@2"])
            .contains("preserved_memory_missing_from_fresh_context"))

        let mutations: [(String, Any, String)] = [
            ("revision", 2, "preservation_assertion_changed"),
            ("state", "archived", "preservation_assertion_changed"),
            ("isCurrent", false, "preservation_assertion_changed"),
            ("body", "I prefer window seats", "preservation_assertion_changed"),
            ("detailAvailable", false, "preservation_assertion_changed"),
            ("evidenceSourceReferences", ["near-miss-source"], "preservation_history_or_evidence_changed"),
            ("evidenceExecutionIDs", ["near-miss-execution"], "preservation_history_or_evidence_changed"),
            ("revisionNumbers", [1, 2], "preservation_history_or_evidence_changed"),
            ("revisionBodyCount", 0, "preservation_history_or_evidence_changed"),
            ("evidenceExcerptCount", 0, "preservation_history_or_evidence_changed"),
            ("previousMemoryIDs", ["another-memory"], "preservation_history_or_evidence_changed"),
        ]
        for (key, value, expected) in mutations {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(baseline)) as? [String: Any])
            json[key] = value
            let altered = try JSONDecoder().decode(StateEvolutionMemorySnapshot.self,
                from: JSONSerialization.data(withJSONObject: json))
            XCTAssertTrue(failures([altered]).contains(expected), "Changed \(key) must fail preservation.")
        }
        var retired = baseline
        retired.retraction = .init(priorRevision: 1, revision: 2, evidence: [])
        XCTAssertTrue(failures([retired]).contains("preservation_assertion_changed"))
    }

    func testRetractionAssertionsRequireEstablishedTargetAndSeparateWithdrawalProvenance() {
        let baseline = StateEvolutionMemorySnapshot(
            id: "preference", revision: 1, state: "active", lifecycle: "active", isCurrent: true,
            body: "I prefer early flights", origin: "observedUserStatement", authority: "observedUser",
            forgottenAt: nil, supersededByID: nil, evidenceSourceReferences: ["original-source"],
            evidenceExecutionIDs: ["original-execution"], revisionNumbers: [1], previousMemoryIDs: [],
            evidenceCount: 1, evidenceExcerptCount: 1, evidenceHashCount: 1, revisionBodyCount: 1,
            detailAvailable: true, detailErrorCode: nil)
        var retired = StateEvolutionMemorySnapshot(
            id: baseline.id, revision: 2, state: "archived", lifecycle: "archived", isCurrent: false,
            body: baseline.body, origin: baseline.origin, authority: baseline.authority,
            forgottenAt: nil, supersededByID: nil, evidenceSourceReferences: baseline.evidenceSourceReferences,
            evidenceExecutionIDs: baseline.evidenceExecutionIDs, revisionNumbers: [1, 2], previousMemoryIDs: [],
            evidenceCount: 2, evidenceExcerptCount: 2, evidenceHashCount: 2, revisionBodyCount: 2,
            detailAvailable: true, detailErrorCode: nil,
            retraction: .init(priorRevision: 1, revision: 2, evidence: [
                .init(revision: 2, sourceReference: "withdrawal-source", executionID: "withdrawal-execution",
                      hasExcerpt: true, hasHash: true)]))
        func failures(_ memories: [StateEvolutionMemorySnapshot], context: [String] = []) -> [String] {
            StateEvolutionAssertions.retractionFailures(
                memories: memories, baseline: baseline, withdrawalExecutionID: "withdrawal-execution",
                contextMemoryReferences: context)
        }
        XCTAssertTrue(failures([retired]).isEmpty)
        XCTAssertTrue(StateEvolutionAssertions.retractionFailures(
            memories: [], baseline: nil, withdrawalExecutionID: "withdrawal-execution", contextMemoryReferences: [])
            .contains("retraction_predecessor_not_established"))
        XCTAssertTrue(failures([]).contains("retraction_target_missing"))
        XCTAssertTrue(failures([retired, baseline]).contains("retraction_created_replacement_or_current_fact"))
        XCTAssertTrue(failures([retired.with(evidenceSourceReferences: ["withdrawal-source"])])
            .contains("retraction_history_or_supporting_evidence_changed"))
        XCTAssertTrue(failures([retired], context: ["memory:preference@1"])
            .contains("retracted_memory_in_ordinary_context"))
        retired.retraction = .init(priorRevision: 1, revision: 2, evidence: [])
        XCTAssertTrue(failures([retired]).contains("retraction_withdrawal_provenance_missing"))
        retired.retraction = .init(priorRevision: 2, revision: 3, evidence: [])
        XCTAssertTrue(failures([retired]).contains("retraction_revision_not_bound_to_predecessor"))
        retired.retraction = nil
        XCTAssertTrue(failures([retired]).contains("retraction_marker_missing"))
    }

    func testStateEvaluationAssertionsRejectDuplicatesMissingLineageForgottenLeakAndLifecycleConfusion() {
        let firstID = UUID().uuidString.lowercased()
        let final = StateEvolutionMemorySnapshot(
            id: UUID().uuidString.lowercased(), revision: 1, state: "active", lifecycle: "active",
            isCurrent: true, body: "Miso is a black shorthair cat", origin: "observedUserStatement",
            authority: "observedUser", forgottenAt: nil, supersededByID: nil,
            evidenceSourceReferences: ["source:first", "source:second"],
            evidenceExecutionIDs: [firstID, "second-execution"], revisionNumbers: [1],
            previousMemoryIDs: ["previous-memory"], evidenceCount: 2, evidenceExcerptCount: 2,
            evidenceHashCount: 2, revisionBodyCount: 1, detailAvailable: true, detailErrorCode: nil)
        let previous = StateEvolutionMemorySnapshot(
            id: "previous-memory", revision: 2, state: "active", lifecycle: "superseded",
            isCurrent: false, body: "Miso is a shorthair cat", origin: "observedUserStatement",
            authority: "observedUser", forgottenAt: nil, supersededByID: final.id,
            evidenceSourceReferences: ["source:first"], evidenceExecutionIDs: [firstID],
            revisionNumbers: [1, 2], previousMemoryIDs: [], evidenceCount: 1,
            evidenceExcerptCount: 1, evidenceHashCount: 1, revisionBodyCount: 1,
            detailAvailable: true, detailErrorCode: nil)
        XCTAssertTrue(StateEvolutionAssertions.evolutionFailures(
            memories: [final, previous], expectedExecutionIDs: [firstID, "second-execution"],
            expectedPreviousMemoryIDs: ["previous-memory"], preservePreviousEvidence: true).isEmpty)
        XCTAssertTrue(StateEvolutionAssertions.evolutionFailures(
            memories: [final], expectedExecutionIDs: ["second-execution"],
            expectedPreviousMemoryIDs: [], preservePreviousEvidence: false)
            .contains("evolution_predecessor_not_established"))

        let duplicates = StateEvolutionAssertions.evolutionFailures(
            memories: [final, final, previous], expectedExecutionIDs: [firstID, "second-execution"],
            expectedPreviousMemoryIDs: ["previous-memory"], preservePreviousEvidence: true)
        XCTAssertTrue(duplicates.contains("current_representation_count_mismatch"))

        let missingLineage = StateEvolutionAssertions.evolutionFailures(
            memories: [final.with(evidenceExecutionIDs: [firstID], detailAvailable: false), previous],
            expectedExecutionIDs: [firstID, "second-execution"], expectedPreviousMemoryIDs: ["previous-memory"], preservePreviousEvidence: true)
        XCTAssertTrue(missingLineage.contains("memory_details_unavailable"))
        XCTAssertTrue(missingLineage.contains("source_lineage_missing"))

        let alteredSourceIdentity = StateEvolutionAssertions.evolutionFailures(
            memories: [final.with(evidenceSourceReferences: ["source:changed", "source:second"]), previous],
            expectedExecutionIDs: [firstID, "second-execution"],
            expectedPreviousMemoryIDs: [previous.id], preservePreviousEvidence: true)
        XCTAssertTrue(alteredSourceIdentity.contains("inherited_source_identity_missing"))

        let forgotten = StateEvolutionMemorySnapshot(
            id: final.id, revision: 2, state: "active", lifecycle: "forgotten", isCurrent: false,
            body: nil, origin: "observedUserStatement", authority: "observedUser",
            forgottenAt: Date(timeIntervalSince1970: 1), supersededByID: nil,
            evidenceSourceReferences: ["source:first"], evidenceExecutionIDs: [firstID],
            revisionNumbers: [1, 2], previousMemoryIDs: [], evidenceCount: 1,
            evidenceExcerptCount: 0, evidenceHashCount: 0, revisionBodyCount: 0,
            detailAvailable: true, detailErrorCode: nil)
        XCTAssertTrue(StateEvolutionAssertions.forgottenFailures(
            memory: forgotten, contextMemoryReferences: []).isEmpty)
        XCTAssertTrue(StateEvolutionAssertions.forgottenFailures(
            memory: forgotten, contextMemoryReferences: ["memory:\(forgotten.id)@2"])
            .contains("forgotten_memory_in_context"))
        XCTAssertTrue(StateEvolutionAssertions.forgottenFailures(
            memory: forgotten.with(body: "still present"), contextMemoryReferences: [])
            .contains("forgotten_memory_body_available"))

        XCTAssertTrue(StateEvolutionAssertions.forgottenFailures(
            memory: forgotten.with(detailAvailable: false), contextMemoryReferences: [])
            .contains("forgotten_memory_details_unavailable"))
        XCTAssertTrue(StateEvolutionAssertions.evolutionFailures(
            memories: [final], expectedExecutionIDs: [firstID, "second-execution"],
            expectedPreviousMemoryIDs: ["previous-memory"], preservePreviousEvidence: true)
            .contains("evolution_target_not_superseded_by_final"))

        let stillCurrentPredecessor = StateEvolutionMemorySnapshot(
            id: previous.id, revision: 1, state: "active", lifecycle: "active", isCurrent: true,
            body: previous.body, origin: previous.origin, authority: previous.authority,
            forgottenAt: nil, supersededByID: nil,
            evidenceSourceReferences: previous.evidenceSourceReferences,
            evidenceExecutionIDs: previous.evidenceExecutionIDs, revisionNumbers: [1],
            previousMemoryIDs: [], evidenceCount: 1, evidenceExcerptCount: 1,
            evidenceHashCount: 1, revisionBodyCount: 1, detailAvailable: true, detailErrorCode: nil)
        // A replacement relation alone cannot prove that the old preference stopped
        // being current. Replacement needs the new source; enrichment needs both.
        let incompleteReplacement = StateEvolutionAssertions.evolutionFailures(
            memories: [final, stillCurrentPredecessor], expectedExecutionIDs: ["second-execution"],
            expectedPreviousMemoryIDs: [previous.id], preservePreviousEvidence: false)
        XCTAssertTrue(incompleteReplacement.contains("current_representation_count_mismatch"))
        XCTAssertTrue(incompleteReplacement.contains("evolution_target_not_superseded_by_final"))

        let misleadingRawState = Memory(
            draft: .init(content: "old", scope: .global), scope: .global, subject: .user,
            state: .active, createdAt: .now, updatedAt: .now,
            forgottenAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(misleadingRawState.state, .active)
        XCTAssertEqual(misleadingRawState.lifecycleStatus(at: .now), .forgotten)
    }

    func testStateEvaluationConfigurationHasSeparateBoundedLimits() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mira-StateEvaluation-Config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let corpus = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "scenarios", withExtension: "json"))
        let base: [String: String] = [
            "MIRA_EVAL_CORPUS": corpus.path,
            "MIRA_EVAL_REPORT": directory.appendingPathComponent("report.json").path,
            "MIRA_EVAL_ENDPOINT": "https://fixture.invalid/v1",
            "MIRA_EVAL_API_KEY": "synthetic-evaluation-secret",
            "MIRA_EVAL_PROTOCOL": HTTPProtocolID.responses.rawValue,
            "MIRA_EVAL_CONVERSATION_MODEL": "gpt-4",
            "MIRA_EVAL_CONTEXT_WINDOW": "8192",
            "MIRA_EVAL_CASE_IDS": (0..<8).map { "case-\($0)" }.joined(separator: ","),
            "MIRA_EVAL_REQUEST_AUTHORIZATION_CAP": "64",
        ]
        XCTAssertNoThrow(try LiveEvaluationConfiguration(environment: base, mode: .stateEvolution))
        XCTAssertThrowsError(try LiveEvaluationConfiguration(environment: base, mode: .ordinary))
        var invalidProvider = base
        invalidProvider["MIRA_EVAL_PROVIDER_ID"] = "anthropic"
        XCTAssertThrowsError(try LiveEvaluationConfiguration(environment: invalidProvider, mode: .stateEvolution))
        var matchingDeepSeek = base
        matchingDeepSeek["MIRA_EVAL_PROVIDER_ID"] = "deepseek"
        matchingDeepSeek["MIRA_EVAL_PROTOCOL"] = HTTPProtocolID.chatCompletions.rawValue
        XCTAssertNoThrow(try LiveEvaluationConfiguration(environment: matchingDeepSeek, mode: .stateEvolution))
    }

    func testStateReportRetainsFailureAndUnrunCasesAfterIncrementalWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mira-StateReport-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("report.json")
        let writer = StateEvolutionReportWriter(report: .init(
            version: 1, status: "running", qualification: "synthetic offline report test",
            createdAt: .now, corpusVersion: 1, selectedCaseIDs: ["failed", "unrun"],
            providerID: "deepseek", conversationModelID: "synthetic-model",
            protocolID: "chat.completions", dialectProfileID: "deepseek.chat", adapterID: "synthetic",
            contextWindow: 8192, conversationOutputTokens: 1024, embeddingsMode: "offline",
            requestAuthorizationCap: 2, requestAuthorizationCount: 0,
            cases: [.pending(id: "failed", kind: "automaticEnrichment"),
                    .pending(id: "unrun", kind: "replacement")]), url: url)
        try writer.write()
        var failed = StateEvolutionCaseReport.pending(id: "failed", kind: "automaticEnrichment", status: "failed")
        failed.errorCode = "network"
        failed.failureStage = "step_audit"
        failed.failureStepIndex = 1
        failed.mismatchReasons = ["background_extraction_not_completed"]
        try writer.replaceCase(failed, requestAuthorizationCount: 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let partial = try decoder.decode(StateEvolutionLiveReport.self, from: Data(contentsOf: url))
        XCTAssertEqual(partial.status, "running")
        XCTAssertEqual(partial.cases[0].errorCode, "network")
        XCTAssertEqual(partial.cases[0].failureStage, "step_audit")
        XCTAssertEqual(partial.cases[0].failureStepIndex, 1)
        XCTAssertEqual(partial.cases[1].status, "pending")
        XCTAssertEqual(partial.extractionOutputTokenCap, 1024)
        try writer.replaceCase(.pending(id: "unrun", kind: "replacement", status: "not_run_request_cap_reached"),
                               requestAuthorizationCount: 2)
        let final = try writer.finish(requestAuthorizationCount: 2)
        XCTAssertEqual(final.status, "completed_with_failures_or_mismatches")
        XCTAssertEqual(final.cases[0].mismatchReasons, ["background_extraction_not_completed"])
        XCTAssertEqual(final.cases[1].status, "not_run_request_cap_reached")
        XCTAssertThrowsError(try writer.replaceCase(.pending(id: "unselected", kind: "replacement"),
                                                  requestAuthorizationCount: 2))
    }

    func testStateFailureCodePreservesSafeTypedAndAuditCodesWithoutBodies() throws {
        let rawMessage = "raw provider error body"
        var notCommitted = StateEvolutionCaseReport.pending(id: "not-committed", kind: "replacement", status: "failed")
        let notCommittedResult = SessionCommitResult.notCommitted(
            MiraError(.providerRejected, rawMessage))
        XCTAssertEqual(Self.recordStateFailureCode(
            in: &notCommitted, result: notCommittedResult, fallback: "admission_failed"), "providerRejected")

        var indeterminate = StateEvolutionCaseReport.pending(id: "indeterminate", kind: "replacement", status: "failed")
        let indeterminateResult = SessionCommitResult.indeterminate(
            batchID: UUID(), error: MiraError(.network, rawMessage))
        XCTAssertEqual(Self.recordStateFailureCode(
            in: &indeterminate, result: indeterminateResult, fallback: "execution_failed"), "network")

        var auditPreferred = StateEvolutionCaseReport.pending(id: "audit", kind: "replacement", status: "failed")
        let committed = SessionCommitResult.committed(
            SessionCursor(sessionID: ConversationID(), sequence: 1))
        XCTAssertEqual(Self.recordStateFailureCode(
            in: &auditPreferred, result: committed,
            auditError: MiraError(.outputLimit, rawMessage), fallback: "execution_failed"), "outputLimit")

        var generic = StateEvolutionCaseReport.pending(id: "generic", kind: "replacement", status: "failed")
        XCTAssertEqual(Self.recordStateFailureCode(
            in: &generic, result: committed, fallback: "execution_failed"), "execution_failed")
        XCTAssertEqual(notCommitted.errorCode, "providerRejected")
        XCTAssertEqual(indeterminate.errorCode, "network")
        XCTAssertEqual(auditPreferred.errorCode, "outputLimit")
        XCTAssertEqual(generic.errorCode, "execution_failed")

        XCTAssertEqual(Self.recordStateFailureCode(
            in: &auditPreferred, result: indeterminateResult,
            auditError: MiraError(.outputLimit, rawMessage), fallback: "execution_failed"), "outputLimit")
        let data = try JSONEncoder().encode([notCommitted, indeterminate, auditPreferred, generic])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(rawMessage))
    }

    func testRequestCapDistinguishesLastAuthorizedRequestFromDeniedAdmission() throws {
        let counter = RequestAuthorizationCounter()
        let credential = EvaluationCredentials(secret: "synthetic", counter: counter, limit: 1)
        XCTAssertEqual(try credential.read(reference: "synthetic-reference", version: 1), "synthetic")
        XCTAssertEqual(counter.value, 1)
        XCTAssertFalse(counter.wasDenied)
        XCTAssertThrowsError(try credential.read(reference: "synthetic-reference", version: 1))
        XCTAssertTrue(counter.wasDenied)
        XCTAssertEqual(counter.value, 1)
    }

    func testFailureExecutionRetainsSettledUsageWithoutQualifyingCappedFollowUp() async throws {
        let sessionID = ConversationID(), executionID = ExecutionID(), attemptID = UUID()
        let checkpoint = StateEvolutionExecutionCheckpoint(
            phase: "followup", stepIndex: nil, sessionID: sessionID, executionID: executionID,
            admissionOutcome: "committed", completionOutcome: "committed")
        let admission = SessionAdmission(
            executionID: executionID, userMessageID: MessageID(), userBody: nil,
            plan: .init(kind: .executionPlan, bytes: Data()), hasModelRoute: true,
            authorizationEpoch: 1, timeZoneIdentifier: "UTC")
        let audit = SessionExecutionAuditPage(
            head: .init(cursor: .init(sessionID: sessionID, sequence: 10), batchID: nil), workspaceID: nil,
            execution: .init(sessionID: sessionID, admission: admission, sequence: 1, admittedAt: .now,
                             phase: .settling, completion: .init(executionID: executionID, status: .failed)),
            plan: .absent, error: .available(MiraError(.outputLimit, "Synthetic raw failure body")),
            attempts: [], modelUsage: [
                .init(id: attemptID, startedAt: .now, usage: .init(inputTokens: 40, outputTokens: 12, reasoningTokens: 7),
                      isComplete: true),
                .init(id: UUID(), startedAt: .now, usage: .init(), isComplete: false)
            ], hasMore: true)
        var report = StateEvolutionCaseReport.pending(id: "capped-followup", kind: "retractionNearMiss", status: "failed")
        report.errorCode = "request_authorization_cap_reached"
        report.failureStage = "followup_status"
        report.failureExecution = await Self.captureFailureExecution(checkpoint) { audit }
        let snapshot = try XCTUnwrap(report.failureExecution)
        XCTAssertEqual(snapshot.sessionID, sessionID.rawValue.uuidString.lowercased())
        XCTAssertEqual(snapshot.executionID, executionID.rawValue.uuidString.lowercased())
        XCTAssertEqual(snapshot.executionOutcome, "failed")
        XCTAssertEqual(snapshot.executionErrorCode, "outputLimit")
        XCTAssertEqual(snapshot.auditHasMore, true)
        XCTAssertEqual(snapshot.memoryContextReferences, [])
        XCTAssertEqual(snapshot.conversationUsage?.count, 2)
        XCTAssertEqual(snapshot.conversationUsage?.first?.id, attemptID.uuidString.lowercased())
        XCTAssertEqual(snapshot.conversationUsage?.first?.reasoningTokens, 7)
        XCTAssertEqual(snapshot.conversationUsage?.last?.complete, false)
        XCTAssertNil(snapshot.conversationUsage?.last?.inputTokens)
        XCTAssertNil(report.followUp)
        XCTAssertEqual(report.status, "failed")
        XCTAssertEqual(report.errorCode, "request_authorization_cap_reached")
        XCTAssertEqual(report.failureStage, "followup_status")
        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(StateEvolutionCaseReport.self, from: encoded)
        XCTAssertEqual(decoded.failureExecution?.conversationUsage?.count, 2)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("Synthetic raw failure body"))
        let differentExecution = StateEvolutionExecutionCheckpoint(
            phase: "followup", stepIndex: nil, sessionID: sessionID, executionID: ExecutionID())
        let mismatched = await Self.captureFailureExecution(differentExecution) { audit }
        XCTAssertFalse(mismatched.auditAvailable)
        XCTAssertEqual(mismatched.auditReadErrorCode, "audit_identity_mismatch")
        XCTAssertNil(mismatched.conversationUsage)
    }

    func testFailureExecutionKeepsUnknownAuditSeparateFromPrimaryAdmissionFailure() async throws {
        let checkpoint = StateEvolutionExecutionCheckpoint(
            phase: "step", stepIndex: 1, sessionID: ConversationID(), executionID: ExecutionID(),
            admissionOutcome: "notCommitted")
        var report = StateEvolutionCaseReport.pending(id: "failed-admission", kind: "retractionNearMiss", status: "failed")
        report.errorCode = "unauthorized"
        report.failureStage = "step_submit"
        report.failureExecution = await Self.captureFailureExecution(checkpoint) {
            throw MiraError(.notFound, "Synthetic raw query failure")
        }
        let snapshot = try XCTUnwrap(report.failureExecution)
        XCTAssertEqual(snapshot.admissionOutcome, "notCommitted")
        XCTAssertNil(snapshot.completionOutcome)
        XCTAssertFalse(snapshot.auditAvailable)
        XCTAssertEqual(snapshot.auditReadErrorCode, "notFound")
        XCTAssertNil(snapshot.executionOutcome)
        XCTAssertNil(snapshot.memoryContextReferences)
        XCTAssertNil(snapshot.conversationUsage)
        XCTAssertEqual(report.errorCode, "unauthorized")
        XCTAssertEqual(report.failureStage, "step_submit")
        let encoded = try JSONEncoder().encode(report)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("Synthetic raw query failure"))
    }

    func testEvaluationAnswerIsBoundToExactSessionAndExecutionRegardlessOfPageOrder() throws {
        let sessionID = ConversationID(), oldExecution = ExecutionID(), currentExecution = ExecutionID()
        func message(_ executionID: ExecutionID, role: SessionMessageRole, sequence: Int64,
                     text: String?, session: ConversationID? = nil) -> SessionQueryMessage {
            .init(summary: .init(
                id: MessageID(), sessionID: session ?? sessionID, executionID: executionID,
                role: role, sequence: sequence, occurredAt: .now, body: nil, thinking: nil),
                body: text.map(SessionTextContent.available) ?? .absent, thinking: .absent)
        }
        let previous = message(oldExecution, role: .assistant, sequence: 2, text: "Previous preference acknowledgment")
        let input = message(currentExecution, role: .user, sequence: 3, text: "Translate a quoted withdrawal")
        let current = message(currentExecution, role: .assistant, sequence: 4, text: "Translation of the quoted line")
        func answer(_ messages: [SessionQueryMessage]) throws -> String? {
            try Self.assistantAnswer(in: .init(session: nil, messages: messages, executions: [], hasMore: false),
                                     sessionID: sessionID, executionID: currentExecution)
        }
        XCTAssertEqual(try answer([current, input, previous]), "Translation of the quoted line")
        XCTAssertEqual(try answer([previous, input, current]), "Translation of the quoted line")
        XCTAssertNil(try answer([previous, input]))
        XCTAssertNil(try answer([previous, message(currentExecution, role: .assistant, sequence: 4, text: nil)]))
        XCTAssertNil(try answer([message(currentExecution, role: .assistant, sequence: 4,
                                        text: "Another session", session: ConversationID())]))
        XCTAssertThrowsError(try answer([current, current]))
    }

    func testOptInStateEvolutionEvaluation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MIRA_RUN_LIVE_MEMORY_STATE_EVAL"] == "1" else {
            throw XCTSkip("Opt-in live memory state evaluation is disabled.")
        }
        let configuration = try LiveEvaluationConfiguration(environment: environment, mode: .stateEvolution)
        let corpus = try StateEvolutionCorpus.load(data: Data(contentsOf: configuration.corpusURL))
        let selected = try corpus.selected(ids: configuration.caseIDs)
        let counter = RequestAuthorizationCounter()
        let writer = StateEvolutionReportWriter(
            report: StateEvolutionLiveReport(
                version: 1, status: "running", qualification: "completed means host/state checks passed; memory contents and answers require separate semantic review",
                createdAt: .now, corpusVersion: corpus.version, selectedCaseIDs: configuration.caseIDs,
                providerID: configuration.providerID, conversationModelID: configuration.conversationModelID,
                protocolID: configuration.protocolID.rawValue, dialectProfileID: configuration.dialectProfileID.rawValue,
                adapterID: try configuration.protocolID.adapterIdentity.id,
                contextWindow: configuration.contextWindow, conversationOutputTokens: configuration.conversationOutputTokens,
                embeddingsMode: configuration.embeddingsMode.rawValue,
                requestAuthorizationCap: configuration.requestAuthorizationCap,
                requestAuthorizationCount: 0,
                cases: selected.map { StateEvolutionCaseReport.pending(id: $0.id, kind: $0.kind) }),
            url: configuration.reportURL)
        try writer.write()
        for (index, scenario) in selected.enumerated() {
            if counter.value >= configuration.requestAuthorizationCap {
                for skipped in selected.dropFirst(index) {
                    try writer.replaceCase(.pending(id: skipped.id, kind: skipped.kind, status: "not_run_request_cap_reached"),
                                           requestAuthorizationCount: counter.value)
                }
                break
            }
            let result = await Self.evaluateStateEvolution(
                scenario, configuration: configuration, requestAuthorizationCounter: counter,
                onProgress: { try writer.replaceCase($0, requestAuthorizationCount: counter.value) })
            try writer.replaceCase(result, requestAuthorizationCount: counter.value)
            if result.terminalOutcome == "request_authorization_cap_reached" {
                for skipped in selected.dropFirst(index + 1) {
                    try writer.replaceCase(.pending(id: skipped.id, kind: skipped.kind, status: "not_run_request_cap_reached"),
                                           requestAuthorizationCount: counter.value)
                }
                break
            }
        }
        let final = try writer.finish(requestAuthorizationCount: counter.value)
        let failed = final.cases.filter { !$0.mismatchReasons.isEmpty || ["failed", "not_run_request_cap_reached"].contains($0.status) }
        if !failed.isEmpty {
            XCTFail("State-evolution evaluation has failed, incomplete, or mismatched cases: \(failed.map(\.id).joined(separator: ",")); report: \(configuration.reportURL.path)")
        }
    }

    func testOptInEverydayMemoryEvaluation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MIRA_RUN_LIVE_MEMORY_EVAL"] == "1" else {
            throw XCTSkip("Opt-in live memory evaluation is disabled. Set MIRA_RUN_LIVE_MEMORY_EVAL=1 to run it.")
        }
        let configuration = try LiveEvaluationConfiguration(environment: environment)
        let corpus = try Self.loadCorpus(at: configuration.corpusURL)
        let scenarios = try corpus.selectedScenarios(ids: configuration.caseIDs)
        let startedAt = Date()
        var report = LiveEvaluationReport(
            version: 1, status: "running", qualification: "none", createdAt: startedAt,
            corpusVersion: corpus.version, selectedCaseIDs: configuration.caseIDs,
            providerID: configuration.providerID,
            conversationModelID: configuration.conversationModelID,
            conversationProtocol: configuration.protocolID.rawValue,
            extractionProtocol: configuration.protocolID.rawValue,
            dialectProfileID: configuration.dialectProfileID.rawValue,
            adapterID: try configuration.protocolID.adapterIdentity.id,
            embeddingsMode: configuration.embeddingsMode.rawValue,
            cases: [], aggregate: .init(),
            requestAuthorizationCap: configuration.requestAuthorizationCap, requestAuthorizationCount: 0)
        try Self.writeReport(report, to: configuration.reportURL)

        let requestAuthorizationCounter = RequestAuthorizationCounter()
        for scenario in scenarios {
            let result = await Self.evaluate(
                scenario: scenario, configuration: configuration, requestAuthorizationCounter: requestAuthorizationCounter)
            report.cases.append(result)
            report.aggregate = .from(report.cases)
            report.requestAuthorizationCount = requestAuthorizationCounter.value
            try Self.writeReport(report, to: configuration.reportURL)
        }
        report.status = report.cases.contains(where: { !$0.mismatchReasons.isEmpty })
            ? "completed_with_mismatches" : "completed"
        report.qualification = report.cases.isEmpty ? "none" : "measured"
        report.requestAuthorizationCount = requestAuthorizationCounter.value
        try Self.writeReport(report, to: configuration.reportURL)
        let mismatches = report.cases.filter { !$0.mismatchReasons.isEmpty }.map(\.id)
        if !mismatches.isEmpty {
            XCTFail("Everyday memory live evaluation mismatched expectations for case IDs: \(mismatches.joined(separator: ","))")
        }
    }

    private static func evaluate(
        scenario: EverydayMemoryScenario, configuration: LiveEvaluationConfiguration,
        requestAuthorizationCounter: RequestAuthorizationCounter
    ) async -> EverydayMemoryCaseReport {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mira-EverydayMemory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = EvaluationCredentials(secret: configuration.apiKey, counter: requestAuthorizationCounter, limit: configuration.requestAuthorizationCap)
        var library: MacLibrary?
        var group: MacLibraryWorkloads?
        var foregroundID: ExecutionID?
        var extractionState: String?
        var extractionErrorCode: String?
        var terminalErrorCode: String?
        var foregroundSucceeded = false
        var answer: String?
        var references = 0
        var verifiedCitations = 0
        var captured: [MemoryObservation] = []
        let approvalCounter = ApprovalCounter()
        var approvalTask: Task<Void, Never>?

        do {
            let opened = try await MacLibrary.open(embeddings: configuration.embeddingsMode.injectedService(),
                directory: directory, notifications: LiveNoopNotifications(), credentials: credentials,
                modules: { [MacHTTPModule(registry: $0, credentials: credentials)] })
            library = opened
            let workloads = try await opened.workloads()
            group = workloads
            try await configuration.embeddingsMode.prepare(in: workloads)
            let approvals = workloads.approvals
            approvalTask = Task {
                for await requests in await approvals.snapshots() {
                    for request in requests {
                        do {
                            try await approvals.resolve(
                                id: request.id, proposalHash: request.proposalHash,
                                authorizationEpoch: request.authorizationEpoch, decision: .denied)
                            approvalCounter.increment()
                        } catch { }
                    }
                }
            }
            let routes = try await Self.installSettings(in: workloads, configuration: configuration)

            let sessionID = ConversationID()
            let executionID = ExecutionID()
            let command = Self.command(
                sessionID: sessionID, executionID: executionID, text: scenario.statement,
                route: routes.conversation,
                opening: .init(title: "Everyday memory \(scenario.id)", workspaceID: nil))
            let admission = await workloads.application.submit(command)
            guard case .committed = admission else {
                terminalErrorCode = Self.errorCode(admission)
                throw MiraError(.storage, "The live evaluation admission was not committed.")
            }
            let completion = await workloads.application.waitForExecution(id: executionID, sessionID: sessionID)
            foregroundID = executionID
            if case .committed = completion, try await Self.executionStatus(
                in: workloads, sessionID: sessionID, executionID: executionID) == .completed {
                foregroundSucceeded = true
                await workloads.wake()
                do {
                    let observation = try await Self.waitForMemory(
                        in: workloads, sourceSession: sessionID, sourceExecution: executionID, timeout: 240)
                    captured = observation.memories
                    extractionState = observation.state
                    extractionErrorCode = observation.errorCode
                } catch {
                    extractionErrorCode = MiraError.safe(error).code.rawValue
                    captured = try await Self.captureMemories(in: workloads, sourceExecution: executionID)
                }
            } else {
                terminalErrorCode = Self.errorCode(completion) ?? "execution_failed"
            }

            let followupSessionID = ConversationID()
            let followupExecutionID = ExecutionID()
            let followup = Self.command(
                sessionID: followupSessionID, executionID: followupExecutionID, text: scenario.followUp,
                route: routes.conversation,
                opening: .init(title: "Everyday memory follow-up \(scenario.id)", workspaceID: nil))
            let followupAdmission = await workloads.application.submit(followup)
            guard case .committed = followupAdmission else {
                terminalErrorCode = terminalErrorCode ?? Self.errorCode(followupAdmission)
                throw MiraError(.storage, "The live evaluation follow-up admission was not committed.")
            }
            let followupCompletion = await workloads.application.waitForExecution(
                id: followupExecutionID, sessionID: followupSessionID)
            if case .committed = followupCompletion,
               try await Self.executionStatus(
                   in: workloads, sessionID: followupSessionID, executionID: followupExecutionID) == .completed {
                answer = try await Self.assistantAnswer(
                    in: workloads, sessionID: followupSessionID, executionID: followupExecutionID)
                let parsed = MemoryCitationReference.references(in: answer ?? "")
                references = parsed.count
                for reference in parsed {
                    do {
                        _ = try await workloads.memories.citation(
                            reference, sessionID: followupSessionID,
                            executionID: followupExecutionID, workspaceID: nil)
                        verifiedCitations += 1
                    } catch { }
                }
            } else if terminalErrorCode == nil {
                terminalErrorCode = Self.errorCode(followupCompletion) ?? "followup_failed"
            }

            let prefetched = try await Self.prefetchedMemoryCount(
                in: workloads, sessionID: followupSessionID, executionID: followupExecutionID)
            let result = Self.makeReport(
                scenario: scenario, foregroundSucceeded: foregroundSucceeded,
                extractionState: extractionState, extractionErrorCode: extractionErrorCode,
                captured: captured, answer: answer, references: references,
                verifiedCitations: verifiedCitations, prefetchedMemoryCount: prefetched,
                approvalDenialCount: approvalCounter.value, terminalErrorCode: terminalErrorCode)
            approvalTask?.cancel()
            _ = await workloads.close()
            _ = await approvalTask?.result
            group = nil
            _ = await opened.close()
            library = nil
            return result
        } catch {
            let safe = MiraError.safe(error)
            terminalErrorCode = terminalErrorCode ?? safe.code.rawValue
            if let workloads = group {
                captured = (try? await Self.captureMemories(in: workloads, sourceExecution: foregroundID)) ?? captured
                approvalTask?.cancel()
                _ = await workloads.close()
                _ = await approvalTask?.result
            }
            if let opened = library { _ = await opened.close() }
            library = nil
            return Self.makeReport(
                scenario: scenario, foregroundSucceeded: false, extractionState: extractionState,
                extractionErrorCode: extractionErrorCode, captured: captured, answer: answer,
                references: references, verifiedCitations: verifiedCitations, prefetchedMemoryCount: 0,
                approvalDenialCount: approvalCounter.value, terminalErrorCode: terminalErrorCode)
        }
    }

    private static func evaluateStateEvolution(
        _ scenario: StateEvolutionScenario, configuration: LiveEvaluationConfiguration,
        requestAuthorizationCounter: RequestAuthorizationCounter,
        onProgress: (StateEvolutionCaseReport) throws -> Void
    ) async -> StateEvolutionCaseReport {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mira-MemoryStateEval-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = EvaluationCredentials(
            secret: configuration.apiKey, counter: requestAuthorizationCounter,
            limit: configuration.requestAuthorizationCap)
        var library: MacLibrary?
        var group: MacLibraryWorkloads?
        var approvalTask: Task<Void, Never>?
        let approvalCounter = ApprovalCounter()
        var routes: EvaluationRoutes?
        var report = StateEvolutionCaseReport.pending(id: scenario.id, kind: scenario.kind, status: "running")
        var failureStage = "setup"
        var failureStepIndex: Int?
        var trackedMemoryIDs = Set<MemoryID>()
        var previousCurrentIDs = Set<String>()
        var establishedMemoryID: MemoryID?
        var establishedSnapshot: StateEvolutionMemorySnapshot?
        var withdrawalExecutionID: String?
        var lastExecutionID: ExecutionID?
        var lastSessionID: ConversationID?
        var lastExtractionState: String?
        var executionCheckpoint: StateEvolutionExecutionCheckpoint?
        let sourceSessionID = ConversationID()

        func publish() throws { try onProgress(report) }
        func startApprovalPump(_ workloads: MacLibraryWorkloads) async -> Task<Void, Never> {
            let approvals = workloads.approvals
            return Task {
                for await requests in await approvals.snapshots() {
                    for request in requests {
                        do {
                            try await approvals.resolve(
                                id: request.id, proposalHash: request.proposalHash,
                                authorizationEpoch: request.authorizationEpoch, decision: .denied)
                            approvalCounter.increment()
                        } catch { }
                    }
                }
            }
        }

        do {
            func openLibrary() async throws -> MacLibrary {
                try await MacLibrary.open(
                    embeddings: configuration.embeddingsMode.injectedService(), directory: directory,
                    notifications: LiveNoopNotifications(), credentials: credentials,
                    modules: { [MacHTTPModule(registry: $0, credentials: credentials)] })
            }
            failureStage = "library_open"
            let opened = try await openLibrary()
            library = opened
            failureStage = "workloads_open"
            var workloads = try await opened.workloads()
            group = workloads
            failureStage = "embeddings_prepare"
            try await configuration.embeddingsMode.prepare(in: workloads)
            failureStage = "approval_pump_start"
            approvalTask = await startApprovalPump(workloads)
            failureStage = "settings_install"
            routes = try await Self.installSettings(in: workloads, configuration: configuration)
            report.status = "running"
            report.terminalOutcome = "setup_ready"
            failureStage = "report_publish"
            try publish()

            for (stepIndex, step) in scenario.steps.enumerated() {
                failureStepIndex = stepIndex
                if step.expect == "forget" {
                    failureStage = "memory_capture"
                    guard let memoryID = establishedMemoryID,
                          let forgottenTarget = try? await workloads.memories.detail(memoryID, workspaceID: nil).memory else {
                        throw MiraError(.notFound, "The state evaluation has no established memory to forget.")
                    }
                    let request = AgentLibraryMaintenanceRequest(
                        id: UUID(), namespace: "memory.forget", revision: 1,
                        scope: .sources([.domain(namespace: "memories", id: forgottenTarget.id.rawValue,
                                                  revision: forgottenTarget.revision)]), requestedAt: .now)
                    failureStage = "maintenance"
                    let operation = try await opened.maintain(request)
                    guard operation.completedAt != nil else {
                        throw MiraError(.storage, "The memory forget maintenance operation did not complete.")
                    }
                    approvalTask?.cancel()
                    _ = await approvalTask?.result
                    failureStage = "library_close_before_reopen"
                    let closure = await opened.close()
                    guard closure.isSettled else {
                        report.errorCode = closure.storageError?.code.rawValue ?? "library_close_not_settled"
                        throw MiraError(.storage, "The evaluation library did not settle before reopening.")
                    }
                    library = nil
                    group = nil
                    failureStage = "library_reopen"
                    let reopened = try await openLibrary()
                    library = reopened
                    failureStage = "workloads_open"
                    workloads = try await reopened.workloads()
                    group = workloads
                    failureStage = "embeddings_prepare"
                    try await configuration.embeddingsMode.prepare(in: workloads)
                    failureStage = "approval_pump_start"
                    approvalTask = await startApprovalPump(workloads)
                    failureStage = "settings_resolve_after_reopen"
                    let reopenedConversation = try await workloads.modelSettings.resolve(
                        purpose: AgentModelPurposeID.conversation, explicitRouteID: nil,
                        sessionSelection: .inherit, workspaceID: nil, requiredCapabilities: []).route
                    routes = .init(conversation: reopenedConversation, extraction: routes?.extraction ?? reopenedConversation)
                    failureStage = "memory_capture"
                    let postReopenSnapshots = try await Self.captureState(in: workloads, knownIDs: trackedMemoryIDs)
                    let forgotten = postReopenSnapshots.first(where: { $0.id == forgottenTarget.id.rawValue.uuidString.lowercased() })
                    let stepReport = StateEvolutionStepSnapshot(
                        index: stepIndex, expectation: step.expect, input: step.input,
                        sessionID: nil, executionID: nil, executionOutcome: "maintenance_completed_library_reopened",
                        extraction: .init(status: "not_applicable", errorCode: nil, memoryCount: 0,
                                          candidateCount: 0, attempts: []),
                        memoryContextReferences: [], rememberInvocationCount: 0,
                        rememberSucceededCount: 0, conversationUsage: [], memories: forgotten.map { [$0] } ?? [])
                    report.stepSnapshots.append(stepReport)
                    report.finalMemorySnapshots = try await Self.captureState(in: workloads, knownIDs: trackedMemoryIDs)
                    let forgottenFailures = StateEvolutionAssertions.forgottenFailures(
                        memory: forgotten, contextMemoryReferences: [])
                    report.stateChecks.append(contentsOf: forgottenFailures.isEmpty
                        ? ["forgotten_body_unavailable_after_close_reopen"] : [])
                    report.mismatchReasons.append(contentsOf: forgottenFailures)
                    failureStage = "report_publish"
                    try publish()
                    continue
                }

                guard let activeRoutes = routes else { throw MiraError(.configuration, "The evaluation route is unavailable.") }
                let sessionID = sourceSessionID
                let executionID = ExecutionID()
                failureStage = "step_submit"
                executionCheckpoint = .init(phase: "step", stepIndex: stepIndex,
                                             sessionID: sessionID, executionID: executionID)
                let admission = await workloads.application.submit(Self.command(
                    sessionID: sessionID, executionID: executionID, text: step.input,
                    route: activeRoutes.conversation,
                    opening: stepIndex == 0
                        ? .init(title: "Memory state evaluation \(scenario.id)", workspaceID: nil)
                        : nil,
                    instructions: Self.stateEvaluationInstructions))
                executionCheckpoint?.admissionOutcome = Self.commitOutcome(admission)
                lastExecutionID = executionID
                lastSessionID = sessionID
                guard case .committed = admission else {
                    let code = Self.recordStateFailureCode(
                        in: &report, result: admission, fallback: "admission_failed")
                    throw MiraError(.storage, "State evaluation admission failed (\(code)).")
                }
                failureStage = "step_wait"
                let completion = await workloads.application.waitForExecution(id: executionID, sessionID: sessionID)
                executionCheckpoint?.completionOutcome = Self.commitOutcome(completion)
                failureStage = "step_completion"
                let status: ExecutionStatus?
                if case .committed = completion {
                    failureStage = "step_status"
                    status = try await Self.executionStatus(in: workloads, sessionID: sessionID, executionID: executionID)
                } else {
                    status = nil
                }
                guard case .committed = completion, status == .completed else {
                    let audit = try? await workloads.queries.executionAudit(
                        sessionID: sessionID, executionID: executionID, beforeSequence: nil, limit: 32)
                    let auditError: MiraError?
                    if let audit, case .available(let error) = audit.error { auditError = error } else { auditError = nil }
                    let code = Self.recordStateFailureCode(
                        in: &report, result: completion, auditError: auditError, fallback: "execution_failed")
                    if requestAuthorizationCounter.wasDenied {
                        report.status = "failed"
                        report.terminalOutcome = "request_authorization_cap_reached"
                        report.errorCode = "request_authorization_cap_reached"
                        throw MiraError(.outputLimit, "The state-evaluation request authorization cap was reached.")
                    }
                    throw MiraError(.storage, "State evaluation execution failed (\(code)).")
                }

                failureStage = "step_audit"
                let audit = try await workloads.queries.executionAudit(
                    sessionID: sessionID, executionID: executionID, beforeSequence: nil, limit: 32)
                let memoryReferences = Self.memoryReferences(in: audit)
                let rememberCalls = audit.attempts.flatMap(\.invocations).filter {
                    $0.state.invocation.toolName == "memory.remember"
                }
                let rememberSucceeded = rememberCalls.filter {
                    $0.state.resolution?.status == .succeeded && $0.state.resolution?.businessReceipt != nil
                }
                let retractCalls = audit.attempts.flatMap(\.invocations).filter {
                    $0.state.invocation.toolName == "memory.retract"
                }
                let retractSucceeded = retractCalls.filter {
                    $0.state.resolution?.status == .succeeded && $0.state.resolution?.businessReceipt != nil
                }
                failureStage = "step_answer"
                guard let stepAnswer = try await Self.assistantAnswer(
                    in: workloads, sessionID: sessionID, executionID: executionID),
                    !stepAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    report.errorCode = "step_answer_missing"
                    throw MiraError(.storage, "The completed evaluation step has no visible assistant answer.")
                }
                if step.expect == "preserve" {
                    failureStage = "foreground_preservation_capture"
                    let immediate = try await Self.captureState(in: workloads, knownIDs: trackedMemoryIDs)
                    let failures = StateEvolutionAssertions.preservationFailures(
                        memories: immediate, baseline: establishedSnapshot,
                        mutationInvocationCount: rememberCalls.count + retractCalls.count)
                    report.mismatchReasons.append(contentsOf: failures.map { "foreground_" + $0 })
                    if failures.isEmpty { report.stateChecks.append("near_miss_preserves_memory_before_background") }
                }
                var extraction: StateEvolutionExtractionSnapshot
                if step.expect == "retractWithoutReplacement", !retractCalls.isEmpty {
                    failureStage = "foreground_retraction_capture"
                    let immediate = try await Self.captureState(in: workloads, knownIDs: trackedMemoryIDs)
                    let failures = StateEvolutionAssertions.retractionFailures(
                        memories: immediate, baseline: establishedSnapshot,
                        withdrawalExecutionID: executionID.rawValue.uuidString.lowercased(), contextMemoryReferences: [])
                    report.mismatchReasons.append(contentsOf: failures.map { "foreground_" + $0 })
                    if retractSucceeded.isEmpty {
                        report.mismatchReasons.append("foreground_retraction_not_committed")
                    } else if failures.isEmpty {
                        report.stateChecks.append("foreground_retraction_committed_before_background")
                    }
                    // A committed withdrawal source is intentionally excluded from capture.
                    // This is a durable source barrier, not a completed extraction job.
                    extraction = try await Self.extractionSnapshot(
                        in: workloads, sourceSession: sessionID, sourceExecution: executionID,
                        fallbackState: failures.isEmpty && !retractSucceeded.isEmpty
                            ? "suppressed_retraction_source" : "not_waited_failed_retraction",
                        fallbackError: nil)
                    lastExtractionState = extraction.status
                } else if scenario.kind == StateEvolutionKind.foregroundEnrichment.rawValue {
                    failureStage = "foreground_capture_snapshot"
                    extraction = try await Self.extractionSnapshot(
                        in: workloads, sourceSession: sessionID, sourceExecution: executionID,
                        fallbackState: "not_waited_foreground_route", fallbackError: nil)
                    if rememberCalls.isEmpty || rememberSucceeded.isEmpty {
                        report.mismatchReasons.append("foreground_memory_remember_not_committed")
                    }
                    if !memoryReferences.isEmpty {
                        report.stateChecks.append("foreground_memory_context_recorded")
                    }
                } else {
                    if !rememberCalls.isEmpty {
                        if step.expect == "replace" {
                            // A clear correction can use the exact foreground target.
                            // Inspect it before extraction can repair or obscure the write.
                            failureStage = "foreground_replacement_capture"
                            let immediate = try await Self.captureState(in: workloads, knownIDs: trackedMemoryIDs)
                            let failures = StateEvolutionAssertions.evolutionFailures(
                                memories: immediate,
                                expectedExecutionIDs: [executionID.rawValue.uuidString.lowercased()],
                                expectedPreviousMemoryIDs: previousCurrentIDs, preservePreviousEvidence: false)
                            report.mismatchReasons.append(contentsOf: failures.map { "foreground_replacement_" + $0 })
                            if rememberSucceeded.isEmpty {
                                report.mismatchReasons.append("foreground_replacement_not_committed")
                            } else if failures.isEmpty {
                                report.stateChecks.append("foreground_replacement_committed_before_background")
                            }
                        } else {
                            report.mismatchReasons.append("automatic_case_used_foreground_remember")
                        }
                    }
                    await workloads.wake()
                    failureStage = "extraction_wait"
                    let extractionResult = try await Self.waitForMemory(
                        in: workloads, sourceSession: sessionID, sourceExecution: executionID, timeout: 240)
                    lastExtractionState = extractionResult.state
                    failureStage = "extraction_report"
                    extraction = try await Self.extractionSnapshot(
                        in: workloads, sourceSession: sessionID, sourceExecution: executionID,
                        fallbackState: extractionResult.state, fallbackError: extractionResult.errorCode)
                    if extractionResult.state != "completed" {
                        report.mismatchReasons.append("background_extraction_not_completed")
                    }
                }
                failureStage = "memory_capture"
                let memorySnapshots = try await Self.captureState(in: workloads, knownIDs: trackedMemoryIDs)
                for memory in memorySnapshots {
                    guard let uuid = UUID(uuidString: memory.id) else {
                        throw MiraError(.storage, "A persisted memory ID could not be read from its detail snapshot.")
                    }
                    trackedMemoryIDs.insert(MemoryID(uuid))
                }
                let currentIDs = Set(memorySnapshots.filter { $0.lifecycle == MemoryLifecycleStatus.active.rawValue }.map(\.id))
                if step.expect == "establish" || step.expect == "remember" {
                    previousCurrentIDs = currentIDs
                    let expectedOrigin: MemoryOrigin = scenario.kind == StateEvolutionKind.foregroundEnrichment.rawValue
                        ? .explicitUser : .observedUserStatement
                    if memorySnapshots.contains(where: { $0.lifecycle == "active" && $0.origin != expectedOrigin.rawValue }) {
                        report.mismatchReasons.append("established_memory_has_wrong_capture_origin")
                    }
                    let sourceLinked = memorySnapshots.filter {
                        $0.lifecycle == MemoryLifecycleStatus.active.rawValue &&
                        $0.evidenceExecutionIDs.contains(executionID.rawValue.uuidString.lowercased())
                    }
                    if sourceLinked.count != 1 || currentIDs.count != 1 {
                        report.mismatchReasons.append("established_memory_not_uniquely_source_linked")
                    } else if let uuid = UUID(uuidString: sourceLinked[0].id) {
                        establishedMemoryID = MemoryID(uuid)
                        establishedSnapshot = sourceLinked[0]
                    }
                }
                if step.expect == "replace" {
                    let failures = StateEvolutionAssertions.evolutionFailures(
                        memories: memorySnapshots,
                        expectedExecutionIDs: [executionID.rawValue.uuidString.lowercased()],
                        expectedPreviousMemoryIDs: previousCurrentIDs, preservePreviousEvidence: false)
                    report.mismatchReasons.append(contentsOf: failures.map { "replacement_" + $0 })
                    if failures.isEmpty { report.stateChecks.append("one_current_replacement_with_superseded_predecessor") }
                }
                if step.expect == "retractWithoutReplacement" {
                    withdrawalExecutionID = executionID.rawValue.uuidString.lowercased()
                    let failures = StateEvolutionAssertions.retractionFailures(
                        memories: memorySnapshots, baseline: establishedSnapshot,
                        withdrawalExecutionID: withdrawalExecutionID, contextMemoryReferences: [])
                    report.mismatchReasons.append(contentsOf: failures)
                    if failures.isEmpty {
                        report.stateChecks.append("established_memory_retracted_without_replacement_with_separate_provenance")
                    }
                    if !rememberCalls.isEmpty { report.mismatchReasons.append("retraction_used_assertion_write_tool") }
                }
                if step.expect == "enrich" {
                    let targetIDs = previousCurrentIDs
                    let expectedExecutions = Set(report.stepSnapshots.compactMap(\.executionID))
                        .union([executionID.rawValue.uuidString.lowercased()])
                    let failures = StateEvolutionAssertions.evolutionFailures(
                        memories: memorySnapshots, expectedExecutionIDs: expectedExecutions,
                        expectedPreviousMemoryIDs: targetIDs, preservePreviousEvidence: true)
                    report.mismatchReasons.append(contentsOf: failures)
                    if failures.isEmpty { report.stateChecks.append("one_current_enriched_representation_with_lineage") }
                }
                if step.expect == "preserve" {
                    let failures = StateEvolutionAssertions.preservationFailures(
                        memories: memorySnapshots, baseline: establishedSnapshot,
                        mutationInvocationCount: rememberCalls.count + retractCalls.count)
                    report.mismatchReasons.append(contentsOf: failures)
                    if failures.isEmpty { report.stateChecks.append("near_miss_preserves_memory_after_background") }
                }

                let stepSnapshot = StateEvolutionStepSnapshot(
                    index: stepIndex, expectation: step.expect, input: step.input,
                    sessionID: sessionID.rawValue.uuidString.lowercased(),
                    executionID: executionID.rawValue.uuidString.lowercased(),
                    executionOutcome: status?.rawValue ?? "unknown", extraction: extraction,
                    memoryContextReferences: memoryReferences,
                    rememberInvocationCount: rememberCalls.count,
                    rememberSucceededCount: rememberSucceeded.count,
                    conversationUsage: audit.modelUsage.map(StateEvolutionTokenUsageSnapshot.init),
                    memories: memorySnapshots, retractInvocationCount: retractCalls.count,
                    retractSucceededCount: retractSucceeded.count, answer: stepAnswer)
                report.stepSnapshots.append(stepSnapshot)
                executionCheckpoint = nil
                report.finalMemorySnapshots = memorySnapshots
                if scenario.kind == StateEvolutionKind.foregroundEnrichment.rawValue && step.expect == "remember" {
                    let committed = memorySnapshots.filter {
                        $0.lifecycle == MemoryLifecycleStatus.active.rawValue &&
                        $0.evidenceExecutionIDs.contains(executionID.rawValue.uuidString.lowercased()) &&
                        $0.origin == MemoryOrigin.explicitUser.rawValue
                    }
                    if rememberSucceeded.isEmpty || committed.count != 1 {
                        report.mismatchReasons.append("foreground_commit_not_bound_to_memory_remember_source")
                    } else {
                        report.stateChecks.append("foreground_memory_remember_receipt_and_explicit_origin_verified")
                    }
                }
                failureStage = "report_publish"
                try publish()
            }

            // Preserve the immediate tool snapshots above, then check what the ordinary
            // background worker does with those same completed source messages.
            if scenario.kind == StateEvolutionKind.foregroundEnrichment.rawValue,
               let executionID = lastExecutionID {
                let immediateCurrentIDs = Set(report.finalMemorySnapshots.filter { $0.lifecycle == "active" }.map(\.id))
                await workloads.wake()
                failureStepIndex = nil
                failureStage = "post_foreground_extraction_wait"
                let observation = try await Self.waitForMemory(
                    in: workloads, sourceSession: sourceSessionID, sourceExecution: executionID, timeout: 240)
                lastExtractionState = observation.state
                failureStage = "post_foreground_extraction_report"
                report.postForegroundExtraction = try await Self.extractionSnapshot(
                    in: workloads, sourceSession: sourceSessionID, sourceExecution: executionID,
                    fallbackState: observation.state, fallbackError: observation.errorCode)
                failureStage = "post_foreground_memory_capture"
                report.finalMemorySnapshots = try await Self.captureState(in: workloads, knownIDs: trackedMemoryIDs)
                if observation.state != "completed" {
                    report.mismatchReasons.append("post_foreground_extraction_not_completed")
                }
                let postExtractionCurrentIDs = Set(report.finalMemorySnapshots.filter { $0.lifecycle == "active" }.map(\.id))
                let failures = StateEvolutionAssertions.evolutionFailures(
                    memories: report.finalMemorySnapshots,
                    expectedExecutionIDs: Set(report.stepSnapshots.compactMap(\.executionID)),
                    expectedPreviousMemoryIDs: postExtractionCurrentIDs == immediateCurrentIDs
                        ? previousCurrentIDs : immediateCurrentIDs, preservePreviousEvidence: true)
                report.mismatchReasons.append(contentsOf: failures.map { "post_background_" + $0 })
                if observation.state == "completed" && failures.isEmpty {
                    report.stateChecks.append("foreground_enrichment_survives_background_extraction")
                }
                failureStage = "report_publish"
                try publish()
            }

            if [StateEvolutionKind.clearRetraction.rawValue, StateEvolutionKind.retractionNearMiss.rawValue]
                .contains(scenario.kind) {
                approvalTask?.cancel()
                _ = await approvalTask?.result
                failureStage = "retraction_library_close"
                guard let activeLibrary = library, await activeLibrary.close().isSettled else {
                    throw MiraError(.storage, "The retraction library did not settle before reopening.")
                }
                library = nil
                group = nil
                failureStage = "retraction_library_reopen"
                let reopened = try await openLibrary()
                library = reopened
                workloads = try await reopened.workloads()
                group = workloads
                try await configuration.embeddingsMode.prepare(in: workloads)
                approvalTask = await startApprovalPump(workloads)
                let conversation = try await workloads.modelSettings.resolve(
                    purpose: AgentModelPurposeID.conversation, explicitRouteID: nil,
                    sessionSelection: .inherit, workspaceID: nil, requiredCapabilities: []).route
                routes = .init(conversation: conversation, extraction: routes?.extraction ?? conversation)
                report.finalMemorySnapshots = try await Self.captureState(in: workloads, knownIDs: trackedMemoryIDs)
                let isNearMiss = scenario.kind == StateEvolutionKind.retractionNearMiss.rawValue
                let failures = isNearMiss
                    ? StateEvolutionAssertions.preservationFailures(
                        memories: report.finalMemorySnapshots, baseline: establishedSnapshot)
                    : StateEvolutionAssertions.retractionFailures(
                        memories: report.finalMemorySnapshots, baseline: establishedSnapshot,
                        withdrawalExecutionID: withdrawalExecutionID, contextMemoryReferences: [])
                report.mismatchReasons.append(contentsOf: failures.map { "reopened_" + $0 })
                if failures.isEmpty {
                    report.stateChecks.append(isNearMiss
                        ? "near_miss_preserves_memory_after_reopen"
                        : "retraction_and_provenance_survive_library_reopen")
                }
                try publish()
            }

            failureStepIndex = nil
            let currentIDsBeforeFollowUp = Set(report.finalMemorySnapshots.filter { $0.lifecycle == "active" }.map(\.id))
            guard let activeRoutes = routes else { throw MiraError(.configuration, "The evaluation route is unavailable.") }
            let followupSessionID = ConversationID(), followupExecutionID = ExecutionID()
            failureStage = "followup_submit"
            executionCheckpoint = .init(phase: "followup", stepIndex: nil,
                                         sessionID: followupSessionID, executionID: followupExecutionID)
            let admission = await workloads.application.submit(Self.command(
                sessionID: followupSessionID, executionID: followupExecutionID, text: scenario.followUp,
                route: activeRoutes.conversation,
                opening: .init(title: "Memory state follow-up \(scenario.id)", workspaceID: nil),
                instructions: Self.stateEvaluationInstructions))
            executionCheckpoint?.admissionOutcome = Self.commitOutcome(admission)
            guard case .committed = admission else {
                let code = Self.recordStateFailureCode(
                    in: &report, result: admission, fallback: "admission_failed")
                throw MiraError(.storage, "State follow-up admission failed (\(code)).")
            }
            failureStage = "followup_wait"
            let completion = await workloads.application.waitForExecution(id: followupExecutionID, sessionID: followupSessionID)
            executionCheckpoint?.completionOutcome = Self.commitOutcome(completion)
            failureStage = "followup_completion"
            if case .committed = completion { failureStage = "followup_status" }
            guard case .committed = completion,
                  try await Self.executionStatus(in: workloads, sessionID: followupSessionID,
                                                 executionID: followupExecutionID) == .completed else {
                let failedAudit = try? await workloads.queries.executionAudit(
                    sessionID: followupSessionID, executionID: followupExecutionID, beforeSequence: nil, limit: 32)
                let auditError: MiraError?
                if let failedAudit, case .available(let error) = failedAudit.error { auditError = error } else { auditError = nil }
                let code = Self.recordStateFailureCode(
                    in: &report, result: completion, auditError: auditError, fallback: "execution_failed")
                if requestAuthorizationCounter.wasDenied {
                    report.status = "failed"
                    report.terminalOutcome = "request_authorization_cap_reached"
                    report.errorCode = "request_authorization_cap_reached"
                    throw MiraError(.outputLimit, "The state-evaluation request authorization cap was reached.")
                }
                throw MiraError(.storage, "State follow-up failed (\(code)).")
            }
            failureStage = "followup_audit"
            let followupAudit = try await workloads.queries.executionAudit(
                sessionID: followupSessionID, executionID: followupExecutionID, beforeSequence: nil, limit: 32)
            failureStage = "followup_answer"
            guard let answer = try await Self.assistantAnswer(
                in: workloads, sessionID: followupSessionID, executionID: followupExecutionID),
                  !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                report.status = "failed"
                report.terminalOutcome = "followup_answer_missing"
                report.errorCode = "followup_answer_missing"
                throw MiraError(.storage, "The completed follow-up has no visible assistant answer.")
            }
            let visibleCitations = MemoryCitationReference.references(in: answer)
            var verifiedCitations: [String] = []
            var rejectedCitations: [String] = []
            failureStage = "citation_verification"
            for citation in visibleCitations {
                do {
                    _ = try await workloads.memories.citation(
                        citation, sessionID: followupSessionID,
                        executionID: followupExecutionID, workspaceID: nil)
                    verifiedCitations.append(citation.id)
                } catch { rejectedCitations.append(citation.id) }
            }
            let followupReferences = Self.memoryReferences(in: followupAudit)
            let answerKeywords = (scenario.requiredTerms.map { (term: $0, required: true) } +
                                  scenario.forbiddenTerms.map { (term: $0, required: false) }).map {
                StateEvolutionKeywordObservation(term: $0.term,
                    observed: answer.localizedCaseInsensitiveContains($0.term), expectedPresence: $0.required)
            }
            let followup = StateEvolutionFollowUpSnapshot(
                sessionID: followupSessionID.rawValue.uuidString.lowercased(),
                executionID: followupExecutionID.rawValue.uuidString.lowercased(),
                executionOutcome: "completed", answer: answer,
                memoryContextReferences: followupReferences,
                visibleCitationReferences: visibleCitations.map(\.id),
                verifiedCitationReferences: verifiedCitations, rejectedCitationReferences: rejectedCitations,
                answerKeywordObservations: answerKeywords,
                conversationUsage: followupAudit.modelUsage.map(StateEvolutionTokenUsageSnapshot.init))
            report.followUp = followup
            executionCheckpoint = nil
            failureStage = "final_memory_capture"
            report.finalMemorySnapshots = try await Self.captureState(in: workloads, knownIDs: trackedMemoryIDs)
            let currentIDsAfterFollowUp = Set(report.finalMemorySnapshots.filter { $0.lifecycle == "active" }.map(\.id))
            if currentIDsAfterFollowUp != currentIDsBeforeFollowUp {
                report.mismatchReasons.append("followup_changed_current_memories")
            }
            if !rejectedCitations.isEmpty { report.mismatchReasons.append("visible_citation_not_verified") }

            switch StateEvolutionKind(rawValue: scenario.kind) {
            case .automaticEnrichment, .foregroundEnrichment:
                let expectedFinal = report.finalMemorySnapshots.first(where: {
                    $0.lifecycle == MemoryLifecycleStatus.active.rawValue
                })
                if let expectedFinal,
                   !followupReferences.contains(Self.memoryReference(id: expectedFinal.id, revision: expectedFinal.revision)) {
                    report.mismatchReasons.append("current_enriched_memory_missing_from_context")
                }
                let supersededIDs = report.finalMemorySnapshots.filter { $0.lifecycle == MemoryLifecycleStatus.superseded.rawValue }.map(\.id)
                if followupReferences.contains(where: { reference in supersededIDs.contains { reference.contains($0) } }) {
                    report.mismatchReasons.append("superseded_memory_in_ordinary_context")
                }
            case .forgetReopen:
                let forgotten = report.finalMemorySnapshots.first(where: { $0.lifecycle == MemoryLifecycleStatus.forgotten.rawValue })
                let failures = StateEvolutionAssertions.forgottenFailures(
                    memory: forgotten, contextMemoryReferences: followupReferences)
                report.mismatchReasons.append(contentsOf: failures)
                if failures.isEmpty { report.stateChecks.append("forgotten_body_and_context_unavailable_after_reopen") }
            case .relatedUnsupported:
                report.stateChecks.append("related_context_and_answer_left_for_human_review")
            case .replacement:
                let successors = report.finalMemorySnapshots.filter {
                    $0.lifecycle == "active" && previousCurrentIDs.isSubset(of: Set($0.previousMemoryIDs))
                }
                if successors.count != 1 || !successors.allSatisfy({
                    followupReferences.contains(Self.memoryReference(id: $0.id, revision: $0.revision))
                }) {
                    report.mismatchReasons.append("replacement_successor_missing_from_context")
                }
                let supersededIDs = report.finalMemorySnapshots.filter { $0.lifecycle == MemoryLifecycleStatus.superseded.rawValue }.map(\.id)
                if followupReferences.contains(where: { reference in supersededIDs.contains { reference.contains($0) } }) {
                    report.mismatchReasons.append("superseded_memory_in_ordinary_context")
                }
            case .clearRetraction:
                let failures = StateEvolutionAssertions.retractionFailures(
                    memories: report.finalMemorySnapshots, baseline: establishedSnapshot,
                    withdrawalExecutionID: withdrawalExecutionID, contextMemoryReferences: followupReferences)
                report.mismatchReasons.append(contentsOf: failures)
                if failures.isEmpty { report.stateChecks.append("retracted_memory_excluded_from_fresh_session_after_reopen") }
            case .retractionNearMiss:
                let mutationCalls = followupAudit.attempts.flatMap(\.invocations).filter {
                    ["memory.remember", "memory.retract"].contains($0.state.invocation.toolName)
                }
                let failures = StateEvolutionAssertions.preservationFailures(
                    memories: report.finalMemorySnapshots, baseline: establishedSnapshot,
                    mutationInvocationCount: mutationCalls.count, contextMemoryReferences: followupReferences)
                report.mismatchReasons.append(contentsOf: failures)
                if failures.isEmpty { report.stateChecks.append("preserved_memory_in_fresh_session_after_reopen") }
            case .none: break
            }
            report.terminalOutcome = "followup_completed"
            report.status = report.mismatchReasons.isEmpty ? "completed" : "completed_with_state_mismatches"
            report.backgroundExtractionState = lastExtractionState ?? "not_waited"
            report.approvalDenialCount = approvalCounter.value
            failureStage = "report_publish"
            try publish()
        } catch {
            let safe = MiraError.safe(error)
            report.failureStage = failureStage
            report.failureStepIndex = failureStepIndex
            if report.terminalOutcome != "request_authorization_cap_reached" {
                report.terminalOutcome = requestAuthorizationCounter.wasDenied
                    ? "request_authorization_cap_reached" : (report.errorCode ?? safe.code.rawValue)
            }
            report.errorCode = report.errorCode ?? safe.code.rawValue
            report.status = "failed"
            if report.terminalOutcome == "request_authorization_cap_reached" {
                report.errorCode = "request_authorization_cap_reached"
            }
            report.backgroundExtractionState = lastExtractionState ?? "not_waited"
            report.approvalDenialCount = approvalCounter.value
            if let checkpoint = executionCheckpoint, let workloads = group {
                // Preserve whatever the failed execution actually settled. The
                // evidence read must never replace the primary failure or retry work.
                report.failureExecution = await Self.captureFailureExecution(checkpoint) {
                    try await workloads.queries.executionAudit(
                        sessionID: checkpoint.sessionID, executionID: checkpoint.executionID,
                        beforeSequence: nil, limit: 32)
                }
            }
            if let workloads = group, let sourceExecution = lastExecutionID, let sourceSession = lastSessionID {
                let page = try? await workloads.memories.extractionStatus(
                    sessionID: sourceSession, executionID: sourceExecution, workspaceID: nil,
                    before: nil, limit: 16)
                report.terminalExtractionJobs = page?.jobs.map {
                    .init(id: $0.id.rawValue.uuidString.lowercased(), state: $0.state.rawValue,
                          memoryCount: $0.memoryCount, candidateCount: $0.candidateCount)
                } ?? []
            }
            try? publish()
        }

        approvalTask?.cancel()
        failureStage = "cleanup"
        if let group { _ = await group.close() }
        _ = await approvalTask?.result
        if let library {
            let closure = await library.close()
            if !closure.isSettled {
                report.status = "failed"
                report.errorCode = report.errorCode ?? closure.storageError?.code.rawValue ?? "library_close_not_settled"
                report.mismatchReasons.append("library_cleanup_not_settled")
                report.failureStage = report.failureStage ?? failureStage
            }
        }
        return report
    }

    private static func installSettings(
        in group: MacLibraryWorkloads, configuration: LiveEvaluationConfiguration
    ) async throws -> EvaluationRoutes {
        let connectionID = ConnectionID()
        let conversationModelID = ModelDescriptorID()
        let conversationRouteID = RouteID(conversationModelID.rawValue)
        guard let provider = ProviderModelCatalog.bundled.providers.first(where: { $0.id == configuration.providerID }),
              provider.protocolID == configuration.protocolID,
              provider.dialectProfileID == configuration.dialectProfileID else {
            throw MiraError(.configuration, "The live evaluation provider, protocol, and dialect do not match.")
        }
        let connectionTemplate = try provider.makeConnection(
            id: connectionID, name: "Live evaluation", credential: nil,
            baseURL: configuration.endpoint, allowsLoopbackHTTP: configuration.allowsLoopbackHTTP)
        let saved = try await group.credentialSettings.saveConnection(
            id: connectionID, name: "Live evaluation", isEnabled: true,
            definitionID: connectionTemplate.definitionID, endpoints: connectionTemplate.endpoints,
            discovery: connectionTemplate.discovery, defaultInvocation: connectionTemplate.defaultInvocation,
            previous: nil, credentialEndpointID: connectionTemplate.endpoints[0].id,
            credential: .replace(configuration.apiKey)).connection
        let capabilities: [String: CapabilityState] = [
            AgentModelCapabilityID.streamingText: .declared,
            AgentModelCapabilityID.toolCalls: .declared,
            AgentModelCapabilityID.thinking: .declared,
            AgentModelCapabilityID.jsonOutput: .declared,
        ]
        let conversationBase = try ProviderModelCatalog.bundled.configuration(
            connection: saved, modelID: configuration.conversationModelID, isEnabled: true)
        let actualInvocation = try SessionCodec.decode(
            HTTPInvocationSettings.self,
            from: SessionCodec.encode(conversationBase.model.invocations[0].configuration.value))
        guard actualInvocation.protocolID == configuration.protocolID,
              actualInvocation.dialectProfileID == configuration.dialectProfileID else {
            throw MiraError(.configuration, "The selected model invocation does not match the live evaluation protocol and dialect.")
        }
        func explicitModel(
            _ base: AgentConfiguredModel, descriptorID: ModelDescriptorID, modelID: String, output: Int
        ) -> AgentConfiguredModel {
            let source = base.invocations[0]
            let invocation = AgentModelInvocationSpec(
                id: source.id, revision: source.revision, adapter: source.adapter,
                endpointID: source.endpointID, contextWindow: configuration.contextWindow,
                maximumOutputTokens: output, capabilities: capabilities,
                configuration: source.configuration, parameterSchema: source.parameterSchema)
            return AgentConfiguredModel(
                id: descriptorID, revision: 1, authorizationRevision: 1,
                reference: .init(connectionID: saved.id, modelID: modelID),
                displayName: base.displayName, isEnabled: true,
                invocations: [invocation], facts: [])
        }
        let conversationModel = explicitModel(
            conversationBase.model, descriptorID: conversationModelID,
            modelID: configuration.conversationModelID, output: configuration.conversationOutputTokens)
        let conversationPreset = AgentRoutePreset(
            id: conversationRouteID, revision: 1, name: "Live conversation",
            modelDescriptorID: conversationModelID, invocationID: "default",
            maximumOutputTokens: configuration.conversationOutputTokens,
            configuration: .init(schema: conversationModel.invocations[0].configuration.schema, value: .object([:])))
        try await group.modelSettings.savePoolModel(
            conversationModel, preset: conversationPreset,
            expectedModelRevision: nil, expectedPresetRevision: nil)
        let bindings = try await group.modelSettings.bindings(scope: .global)
        let conversationBinding = bindings.first { $0.purpose == AgentModelPurposeID.conversation }
        try await group.modelSettings.saveBinding(
            .init(scope: .global, purpose: AgentModelPurposeID.conversation,
                  routeID: conversationRouteID, revision: (conversationBinding?.revision ?? 0) + 1),
            expectedRevision: conversationBinding?.revision)
        let conversation = try await group.modelSettings.resolve(
            purpose: AgentModelPurposeID.conversation, explicitRouteID: conversationRouteID,
            sessionSelection: .inherit, workspaceID: nil, requiredCapabilities: [])
        return .init(conversation: conversation.route, extraction: conversation.route)
    }

    private static func command(
        sessionID: ConversationID, executionID: ExecutionID, text: String,
        route: AgentModelRoute, opening: AgentSessionOpening?,
        instructions: String = "Answer naturally using relevant memories. Visible citations are optional."
    ) -> AgentSubmitCommand {
        .init(id: UUID(), sessionID: sessionID, executionID: executionID,
              input: .message(id: MessageID(), text: text, timeZoneIdentifier: "UTC"),
              options: .init(
                  instructions: instructions,
                  limits: .init(modelTimeoutMilliseconds: 300_000), route: route), opening: opening)
    }

    private static let stateEvaluationInstructions =
        "You are Mira, a personal assistant. Reply in the user's requested language, otherwise the language of their message. Use tools when needed and preserve source citations."

    static func waitForMemory(
        in group: MacLibraryWorkloads, sourceSession: ConversationID,
        sourceExecution: ExecutionID, timeout: TimeInterval
    ) async throws -> MemoryObservationResult {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // A batch may complete with zero accepted facts. Persisted extraction
            // status is therefore the completion authority; active-memory presence
            // cannot be used as a proxy for a completed job.
            let page = try await group.memories.extractionStatus(
                sessionID: sourceSession, executionID: sourceExecution, workspaceID: nil,
                before: nil, limit: 16)
            if let job = page.jobs.last {
                switch job.state {
                case .completed:
                    _ = try? await group.memories.extractionReport(
                        job.id, sessionID: sourceSession, executionID: sourceExecution, workspaceID: nil)
                    let memories = try await captureMemories(in: group, sourceExecution: sourceExecution)
                    return .init(memories: memories, state: job.state.rawValue, errorCode: nil)
                case .failed, .paused, .cancelled, .suppressed:
                    return .init(memories: [], state: job.state.rawValue,
                                 errorCode: job.errorCode?.rawValue)
                case .queued, .running:
                    break
                }
            }
            // Workload failures are global and can outlive the preceding source's
            // job. Only this source's durable job can settle this observation.
            try await Task.sleep(for: .milliseconds(200))
        }
        // Keep timeout distinct from a terminal zero-item extraction. The caller
        // reports this as an evaluation mismatch rather than a successful capture.
        return .init(memories: [], state: "unavailable", errorCode: nil)
    }

    private static func captureMemories(
        in group: MacLibraryWorkloads, sourceExecution: ExecutionID?
    ) async throws -> [MemoryObservation] {
        let result = try await group.memories.list(
            workspaceID: nil, states: [.active, .candidate], query: "", limit: 32)
        var observations: [MemoryObservation] = []
        for memory in result.memories {
            guard let draft = memory.draft else { continue }
            let detail = try await group.memories.detail(memory.id, workspaceID: nil)
            let evidence = detail.evidence.filter { item in
                guard let sourceExecution else { return true }
                guard case .userMessage(let reference) = item.source else { return false }
                return reference.originalExecutionID == sourceExecution
            }.map { $0.id.uuidString.lowercased() }
            guard !evidence.isEmpty else { continue }
            observations.append(.init(state: memory.state.rawValue, content: draft.content, evidenceIDs: evidence))
        }
        return observations
    }

    private static func captureState(
        in group: MacLibraryWorkloads, knownIDs: Set<MemoryID>
    ) async throws -> [StateEvolutionMemorySnapshot] {
        let listed = try await group.memories.list(
            workspaceID: nil, states: Set(MemoryState.allCases), query: "", limit: 128)
        guard !listed.isTruncated else {
            throw MiraError(.outputLimit, "The state evaluation cannot assert cardinality from a truncated memory list.")
        }
        let ids = Set(listed.memories.map(\.id)).union(knownIDs)
        var snapshots: [StateEvolutionMemorySnapshot] = []
        for id in ids.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            do {
                let detail = try await group.memories.detail(id, workspaceID: nil)
                let memory = detail.memory
                let confirmedPreviousIDs = detail.replacements.compactMap { relation -> String? in
                    guard relation.state == .confirmed, relation.replacementID == memory.id else { return nil }
                    return relation.previousID.rawValue.uuidString.lowercased()
                }
                let userEvidence = detail.evidence.compactMap { evidence -> (String, String)? in
                    guard evidence.retractionRevision == nil,
                          case .userMessage(let reference) = evidence.source else { return nil }
                    return (Self.sourceReferenceString(reference), reference.originalExecutionID.rawValue.uuidString.lowercased())
                }
                let withdrawalEvidence = detail.evidence.compactMap { evidence -> StateEvolutionWithdrawalEvidence? in
                    guard let revision = evidence.retractionRevision,
                          case .userMessage(let reference) = evidence.source else { return nil }
                    return .init(revision: revision, sourceReference: Self.sourceReferenceString(reference),
                                 executionID: reference.originalExecutionID.rawValue.uuidString.lowercased(),
                                 hasExcerpt: evidence.excerpt != nil, hasHash: evidence.sourceHash != nil)
                }
                snapshots.append(.init(
                    id: memory.id.rawValue.uuidString.lowercased(), revision: memory.revision,
                    state: memory.state.rawValue, lifecycle: memory.lifecycleStatus(at: .now).rawValue,
                    isCurrent: memory.isCurrent, body: memory.draft?.content,
                    origin: memory.origin.rawValue, authority: memory.authority.rawValue,
                    forgottenAt: memory.forgottenAt, supersededByID: memory.supersededBy?.rawValue.uuidString.lowercased(),
                    evidenceSourceReferences: Array(Set(userEvidence.map(\.0))).sorted(),
                    evidenceExecutionIDs: Array(Set(userEvidence.map(\.1))).sorted(),
                    revisionNumbers: detail.revisions.map(\.revision).sorted(),
                    previousMemoryIDs: Array(Set(confirmedPreviousIDs)).sorted(),
                    evidenceCount: detail.evidence.count,
                    evidenceExcerptCount: detail.evidence.filter { $0.excerpt != nil }.count,
                    evidenceHashCount: detail.evidence.filter { $0.sourceHash != nil }.count,
                    revisionBodyCount: detail.revisions.filter { $0.draft != nil }.count,
                    detailAvailable: true, detailErrorCode: nil,
                    retraction: memory.retraction.map {
                        .init(priorRevision: $0.priorRevision, revision: $0.revision,
                              evidence: withdrawalEvidence)
                    }))
            } catch {
                snapshots.append(.init(
                    id: id.rawValue.uuidString.lowercased(), revision: 0, state: "unavailable",
                    lifecycle: "unavailable", isCurrent: false, body: nil, origin: "unavailable",
                    authority: "unavailable", forgottenAt: nil, supersededByID: nil,
                    evidenceSourceReferences: [], evidenceExecutionIDs: [], revisionNumbers: [],
                    previousMemoryIDs: [], evidenceCount: 0, evidenceExcerptCount: 0,
                    evidenceHashCount: 0, revisionBodyCount: 0, detailAvailable: false,
                    detailErrorCode: MiraError.safe(error).code.rawValue))
            }
        }
        return snapshots.sorted { $0.id < $1.id }
    }

    private static func sourceReferenceString(_ reference: SessionEvidenceReference) -> String {
        "session:\(reference.sessionID.rawValue.uuidString.lowercased())/execution:\(reference.originalExecutionID.rawValue.uuidString.lowercased())/message:\(reference.userMessageID.rawValue.uuidString.lowercased())/admission:\(reference.admissionEventID.uuidString.lowercased())@\(reference.admissionSequence)"
    }

    private static func memoryReferences(in audit: SessionExecutionAuditPage) -> [String] {
        let references = audit.attempts.flatMap { attempt -> [String] in
            guard case .available(let build) = attempt.request else { return [] }
            return build.sources.compactMap { source in
                guard case .domain(let namespace, let id, let revision) = source,
                      namespace == "memories" else { return nil }
                return Self.memoryReference(id: id.uuidString.lowercased(), revision: revision)
            }
        }
        return Array(Set(references)).sorted()
    }

    private static func memoryReference(id: String, revision: Int) -> String {
        "memory:\(id.lowercased())@\(revision)"
    }

    private static func extractionSnapshot(
        in group: MacLibraryWorkloads, sourceSession: ConversationID, sourceExecution: ExecutionID,
        fallbackState: String, fallbackError: String?
    ) async throws -> StateEvolutionExtractionSnapshot {
        let page = try await group.memories.extractionStatus(
            sessionID: sourceSession, executionID: sourceExecution, workspaceID: nil, before: nil, limit: 16)
        guard let job = page.jobs.last else {
            return .init(status: fallbackState,
                         errorCode: fallbackError, memoryCount: 0, candidateCount: 0, attempts: [])
        }
        let detail = try await group.memories.extractionReport(
            job.id, sessionID: sourceSession, executionID: sourceExecution, workspaceID: nil)
        let attempts = detail.attempts.map {
            StateEvolutionExtractionAttemptSnapshot(
                attemptID: $0.id.uuidString.lowercased(), ordinal: $0.ordinal, state: $0.state.rawValue,
                reservedTokens: $0.reservedTokens, chargedTokens: $0.chargedTokens,
                inputTokens: $0.usage?.totalInputTokens, outputTokens: $0.usage?.outputTokens,
                cacheReadTokens: $0.usage?.cacheReadTokens, cacheWriteTokens: $0.usage?.cacheWriteTokens,
                reasoningTokens: $0.usage?.reasoningTokens,
                dispatched: $0.dispatchedAt != nil)
        }
        return .init(jobID: job.id.rawValue.uuidString.lowercased(),
                     sourceExecutionID: sourceExecution.rawValue.uuidString.lowercased(),
                     status: detail.job.state.rawValue, errorCode: detail.job.errorCode?.rawValue,
                     memoryCount: job.memoryCount, candidateCount: job.candidateCount, attempts: attempts)
    }

    private static func assistantAnswer(
        in group: MacLibraryWorkloads, sessionID: ConversationID, executionID: ExecutionID
    ) async throws -> String? {
        _ = try await group.queries.synchronize(sessionID: sessionID)
        let page = try await group.queries.messagePage(sessionID: sessionID, beforeSequence: nil, limit: 128)
        return try Self.assistantAnswer(in: page, sessionID: sessionID, executionID: executionID)
    }

    private static func assistantAnswer(
        in page: SessionQueryMessagePage, sessionID: ConversationID, executionID: ExecutionID
    ) throws -> String? {
        let matching = page.messages.filter {
            $0.summary.sessionID == sessionID && $0.summary.executionID == executionID && $0.summary.role == .assistant
        }
        guard matching.count <= 1 else {
            throw MiraError(.storage, "The evaluated execution has multiple assistant messages.")
        }
        return matching.first?.body.text
    }

    private static func executionStatus(
        in group: MacLibraryWorkloads, sessionID: ConversationID, executionID: ExecutionID
    ) async throws -> ExecutionStatus? {
        let audit = try await group.queries.executionAudit(
            sessionID: sessionID, executionID: executionID, beforeSequence: nil, limit: 32)
        return audit.execution.completion?.status
    }

    private static func prefetchedMemoryCount(
        in group: MacLibraryWorkloads, sessionID: ConversationID, executionID: ExecutionID
    ) async throws -> Int {
        let audit = try await group.queries.executionAudit(
            sessionID: sessionID, executionID: executionID, beforeSequence: nil, limit: 32)
        var sources = Set<AgentSourceReference>()
        for attempt in audit.attempts {
            guard case .available(let build) = attempt.request else { continue }
            for source in build.sources {
                if case .domain(let namespace, _, _) = source, namespace == "memories" {
                    sources.insert(source)
                }
            }
        }
        return sources.count
    }

    private static func makeReport(
        scenario: EverydayMemoryScenario, foregroundSucceeded: Bool, extractionState: String?,
        extractionErrorCode: String?, captured: [MemoryObservation], answer: String?, references: Int,
        verifiedCitations: Int, prefetchedMemoryCount: Int, approvalDenialCount: Int,
        terminalErrorCode: String?
    ) -> EverydayMemoryCaseReport {
        let active = foregroundSucceeded ? captured.filter { $0.state == MemoryState.active.rawValue } : []
        let candidates = foregroundSucceeded ? captured.filter { $0.state == MemoryState.candidate.rawValue } : []
        let required = scenario.requiredTerms.map { KeywordObservation(term: $0, observed: (answer ?? "").localizedCaseInsensitiveContains($0)) }
        let forbidden = scenario.forbiddenTerms.map { KeywordObservation(term: $0, observed: (answer ?? "").localizedCaseInsensitiveContains($0)) }
        let expectationMet = scenario.expectation == "active" ? !active.isEmpty : active.isEmpty
        let keywordPass = required.allSatisfy(\.observed) && forbidden.allSatisfy { !$0.observed }
        var mismatches: [String] = []
        if !expectationMet { mismatches.append("memory_expectation_mismatch") }
        if references != verifiedCitations { mismatches.append("invalid_answer_citations") }
        if scenario.expectation == "active", !active.isEmpty, prefetchedMemoryCount == 0 { mismatches.append("recall_miss") }
        if extractionState == "unavailable" { mismatches.append("extraction_not_completed") }
        if terminalErrorCode != nil { mismatches.append("foreground_or_followup_error") }
        if extractionErrorCode != nil { mismatches.append("extraction_error") }
        return .init(
            id: scenario.id, expected: scenario.expectation,
            actual: !active.isEmpty ? "active" : (!candidates.isEmpty ? "candidate" : "none"),
            activeCount: active.count, candidateCount: candidates.count, active: active, candidates: candidates,
            extractionState: extractionState, extractionErrorCode: extractionErrorCode,
            activeCapturePassed: expectationMet, prefetchedMemoryCount: prefetchedMemoryCount,
            referencedMemoryCount: references, verifiedCitationCount: verifiedCitations,
            approvalDenialCount: approvalDenialCount, answer: answer, requiredTerms: required,
            forbiddenTerms: forbidden, keywordHeuristicsPass: keywordPass,
            expectationMet: expectationMet, errorCode: terminalErrorCode, mismatchReasons: mismatches)
    }

    private static func errorCode(_ result: SessionCommitResult) -> String? {
        switch result {
        case .committed: nil
        case .notCommitted(let error), .indeterminate(_, let error): error.code.rawValue
        }
    }

    private static func recordStateFailureCode(
        in report: inout StateEvolutionCaseReport, result: SessionCommitResult,
        auditError: MiraError? = nil, fallback: String
    ) -> String {
        let code = auditError?.code.rawValue ?? Self.errorCode(result) ?? fallback
        report.errorCode = code
        return code
    }

    private static func commitOutcome(_ result: SessionCommitResult) -> String {
        switch result {
        case .committed: "committed"
        case .notCommitted: "notCommitted"
        case .indeterminate: "indeterminate"
        }
    }

    private static func captureFailureExecution(
        _ checkpoint: StateEvolutionExecutionCheckpoint,
        readAudit: () async throws -> SessionExecutionAuditPage
    ) async -> StateEvolutionFailureExecutionSnapshot {
        var snapshot = StateEvolutionFailureExecutionSnapshot(
            phase: checkpoint.phase, stepIndex: checkpoint.stepIndex,
            sessionID: checkpoint.sessionID.rawValue.uuidString.lowercased(),
            executionID: checkpoint.executionID.rawValue.uuidString.lowercased(),
            admissionOutcome: checkpoint.admissionOutcome, completionOutcome: checkpoint.completionOutcome,
            auditAvailable: false)
        do {
            let audit = try await readAudit()
            guard audit.head.cursor.sessionID == checkpoint.sessionID,
                  audit.execution.sessionID == checkpoint.sessionID,
                  audit.execution.id == checkpoint.executionID else {
                snapshot.auditReadErrorCode = "audit_identity_mismatch"
                return snapshot
            }
            snapshot.auditAvailable = true
            snapshot.auditHasMore = audit.hasMore
            snapshot.executionOutcome = audit.execution.completion?.status.rawValue
            if case .available(let error) = audit.error { snapshot.executionErrorCode = error.code.rawValue }
            snapshot.memoryContextReferences = Self.memoryReferences(in: audit)
            snapshot.conversationUsage = audit.modelUsage.map(StateEvolutionTokenUsageSnapshot.init)
        } catch {
            snapshot.auditReadErrorCode = MiraError.safe(error).code.rawValue
        }
        return snapshot
    }

    private static func loadCorpus(at url: URL) throws -> EverydayMemoryCorpus {
        let corpus = try JSONDecoder().decode(EverydayMemoryCorpus.self, from: Data(contentsOf: url))
        guard corpus.version == 1, !corpus.scenarios.isEmpty,
              Set(corpus.scenarios.map(\.id)).count == corpus.scenarios.count,
              corpus.scenarios.allSatisfy({ scenario in
                  ["en", "zh-CN"].contains(scenario.language) &&
                  ["active", "notActive"].contains(scenario.expectation) &&
                  [scenario.id, scenario.language, scenario.category, scenario.statement, scenario.followUp, scenario.rationale]
                    .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } &&
                  scenario.requiredTerms.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } &&
                  scenario.forbiddenTerms.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
              }) else {
            throw MiraError(.invalidInput, "The everyday memory corpus contains an invalid scenario set.")
        }
        return corpus
    }

    private static func writeReport(_ report: LiveEvaluationReport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
    }
}

private struct EvaluationRoutes: Sendable { let conversation: AgentModelRoute; let extraction: AgentModelRoute }
struct MemoryObservationResult: Sendable { let memories: [MemoryObservation]; let state: String; let errorCode: String? }

private struct LiveNoopNotifications: LocalNotificationPort {
    func permission() async -> NotificationPermission { .denied }
    func requestPermission() async throws -> Bool { false }
    func pending() async -> [ReminderNotification] { [] }
    func install(_ notification: ReminderNotification) async throws {
        throw MiraError(.unsupported, "Live evaluation notifications are unavailable.")
    }
    func remove(_ identifier: String) async {}
}

/// HTTPModelAdapter reads the credential immediately before creating its
/// transport operation. This is a conservative request-authorization count;
/// it is deliberately reported separately from an exact transport dispatch count.
private final class RequestAuthorizationCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    private var denied = false
    var value: Int { lock.withLock { count } }
    var wasDenied: Bool { lock.withLock { denied } }
    func reserve(limit: Int) -> Bool {
        lock.withLock {
            guard count < limit else { denied = true; return false }
            count += 1
            return true
        }
    }
}

private final class ApprovalCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class EvaluationCredentials: MacCredentialStore, @unchecked Sendable {
    private let secret: String; private let counter: RequestAuthorizationCounter
    private let limit: Int
    init(secret: String, counter: RequestAuthorizationCounter, limit: Int) { self.secret = secret; self.counter = counter; self.limit = limit }
    func read(reference: String, version: Int) throws -> String {
        guard !reference.isEmpty, version > 0 else { throw MiraError(.credentialMissing, "The evaluation credential reference is invalid.") }
        guard counter.reserve(limit: limit) else { throw MiraError(.outputLimit, "The live evaluation request authorization cap was reached.") }
        return secret
    }
    func save(_ secret: String, reference: String, version: Int) throws {
        guard secret == self.secret else { throw MiraError(.credentialMissing, "The evaluation credential is immutable.") }
    }
    func delete(reference: String, version: Int) throws {}
}

private enum LiveEvaluationMode { case ordinary, stateEvolution }

private struct LiveEvaluationConfiguration: Sendable {
    let corpusURL: URL; let reportURL: URL; let endpoint: String; let allowsLoopbackHTTP: Bool; let apiKey: String
    let protocolID: HTTPProtocolID; let dialectProfileID: HTTPDialectProfileID
    let providerID: String; let conversationModelID: String; let caseIDs: [String]
    let embeddingsMode: MemoryEvaluationEmbeddingMode
    let requestAuthorizationCap: Int; let contextWindow: Int; let conversationOutputTokens: Int

    init(environment: [String: String], mode: LiveEvaluationMode = .ordinary) throws {
        func required(_ name: String) throws -> String {
            guard let value = environment[name], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MiraError(.configuration, "\(name) is required when live evaluation is enabled.")
            }
            return value
        }
        func absolute(_ name: String) throws -> URL {
            let value = try required(name)
            guard value.hasPrefix("/"), !value.contains("\0") else { throw MiraError(.configuration, "\(name) must be an absolute path.") }
            return URL(fileURLWithPath: value)
        }
        corpusURL = try absolute("MIRA_EVAL_CORPUS"); reportURL = try absolute("MIRA_EVAL_REPORT")
        guard FileManager.default.fileExists(atPath: corpusURL.path) else { throw MiraError(.configuration, "MIRA_EVAL_CORPUS must point to an existing file.") }
        guard FileManager.default.fileExists(atPath: reportURL.deletingLastPathComponent().path), !FileManager.default.fileExists(atPath: reportURL.path) else { throw MiraError(.configuration, "MIRA_EVAL_REPORT must be a new path in an existing directory.") }
        endpoint = try required("MIRA_EVAL_ENDPOINT"); apiKey = try required("MIRA_EVAL_API_KEY")
        let selectedProviderID = environment["MIRA_EVAL_PROVIDER_ID"] ?? "openai"
        providerID = selectedProviderID
        conversationModelID = try required("MIRA_EVAL_CONVERSATION_MODEL")
        protocolID = HTTPProtocolID(rawValue: try required("MIRA_EVAL_PROTOCOL"))
        guard let provider = ProviderModelCatalog.bundled.providers.first(where: { $0.id == selectedProviderID }) else {
            throw MiraError(.configuration, "MIRA_EVAL_PROVIDER_ID must name a bundled live evaluation provider.")
        }
        guard provider.protocolID == protocolID else {
            throw MiraError(.configuration, "MIRA_EVAL_PROTOCOL does not match the selected provider's serving protocol.")
        }
        dialectProfileID = provider.dialectProfileID
        guard let embeddingMode = MemoryEvaluationEmbeddingMode(rawValue: environment["MIRA_EVAL_EMBEDDINGS"] ?? "offline") else {
            throw MiraError(.configuration, "MIRA_EVAL_EMBEDDINGS must be offline or local.")
        }
        embeddingsMode = embeddingMode
        allowsLoopbackHTTP = environment["MIRA_EVAL_ALLOW_LOOPBACK_HTTP"] == "1"
        _ = try HTTPModelConfiguration(baseURL: endpoint, allowsLoopbackHTTP: allowsLoopbackHTTP,
                                       protocolID: protocolID, dialectProfileID: dialectProfileID).validatedEndpoint()
        let ids = try required("MIRA_EVAL_CASE_IDS").split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let maximumCases = mode == .stateEvolution ? 8 : 4
        guard (1...maximumCases).contains(ids.count), Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }) else {
            throw MiraError(.configuration, "MIRA_EVAL_CASE_IDS contains an invalid number of unique IDs for this evaluator.")
        }
        caseIDs = ids
        let maximumAuthorizations = mode == .stateEvolution ? 64 : 12
        let rawCap: String
        if mode == .stateEvolution {
            rawCap = try required("MIRA_EVAL_REQUEST_AUTHORIZATION_CAP")
        } else {
            rawCap = environment["MIRA_EVAL_REQUEST_AUTHORIZATION_CAP"] ?? "4"
        }
        guard let cap = Int(rawCap), (1...maximumAuthorizations).contains(cap) else {
            throw MiraError(.configuration, "MIRA_EVAL_REQUEST_AUTHORIZATION_CAP exceeds the limit for this evaluator.")
        }
        requestAuthorizationCap = cap
        func number(_ name: String, default value: Int) throws -> Int {
            guard let raw = environment[name] else { return value }
            guard let parsed = Int(raw) else { throw MiraError(.configuration, "\(name) must be an integer.") }
            return parsed
        }
        guard let contextRaw = environment["MIRA_EVAL_CONTEXT_WINDOW"],
              let explicitContextWindow = Int(contextRaw) else {
            throw MiraError(.configuration, "MIRA_EVAL_CONTEXT_WINDOW is required and must be an integer.")
        }
        contextWindow = explicitContextWindow
        conversationOutputTokens = try number("MIRA_EVAL_CONVERSATION_OUTPUT", default: 4_096)
        guard (1...10_000_000).contains(contextWindow),
              conversationOutputTokens > 0, conversationOutputTokens < contextWindow else {
            throw MiraError(.configuration, "The live evaluation model limits are invalid.")
        }
    }
}

private struct EverydayMemoryCorpus: Codable {
    let version: Int; let scenarios: [EverydayMemoryScenario]
    func selectedScenarios(ids: [String]) throws -> [EverydayMemoryScenario] {
        let values = Dictionary(uniqueKeysWithValues: scenarios.map { ($0.id, $0) }); let unknown = ids.filter { values[$0] == nil }
        guard unknown.isEmpty else { throw MiraError(.invalidInput, "MIRA_EVAL_CASE_IDS contains unknown scenario IDs.") }
        return ids.compactMap { values[$0] }
    }
}
private struct EverydayMemoryScenario: Codable { let id: String; let language: String; let category: String; let statement: String; let followUp: String; let expectation: String; let rationale: String; let requiredTerms: [String]; let forbiddenTerms: [String] }
struct MemoryObservation: Codable, Sendable { let state: String; let content: String; let evidenceIDs: [String] }
private struct KeywordObservation: Codable { let term: String; let observed: Bool; let basis: String = "keyword heuristic; not semantic correctness" }
private struct EverydayMemoryCaseReport: Codable { let id: String; let expected: String; let actual: String; let activeCount: Int; let candidateCount: Int; let active: [MemoryObservation]; let candidates: [MemoryObservation]; let extractionState: String?; let extractionErrorCode: String?; let activeCapturePassed: Bool; let prefetchedMemoryCount: Int; let referencedMemoryCount: Int; let verifiedCitationCount: Int; let approvalDenialCount: Int; let answer: String?; let requiredTerms: [KeywordObservation]; let forbiddenTerms: [KeywordObservation]; let keywordHeuristicsPass: Bool; let expectationMet: Bool; let errorCode: String?; let mismatchReasons: [String] }
private struct LiveEvaluationAggregate: Codable {
    var casesMeasured = 0; var casesWithErrors = 0; var activeMemoryCount = 0; var candidateMemoryCount = 0; var prefetchedMemoryCount = 0; var referencedMemoryCount = 0; var verifiedCitationCount = 0; var approvalDenialCount = 0
    static func from(_ values: [EverydayMemoryCaseReport]) -> Self { .init(casesMeasured: values.count, casesWithErrors: values.filter { $0.errorCode != nil || $0.extractionErrorCode != nil }.count, activeMemoryCount: values.reduce(0) { $0 + $1.activeCount }, candidateMemoryCount: values.reduce(0) { $0 + $1.candidateCount }, prefetchedMemoryCount: values.reduce(0) { $0 + $1.prefetchedMemoryCount }, referencedMemoryCount: values.reduce(0) { $0 + $1.referencedMemoryCount }, verifiedCitationCount: values.reduce(0) { $0 + $1.verifiedCitationCount }, approvalDenialCount: values.reduce(0) { $0 + $1.approvalDenialCount }) }
}
private struct LiveEvaluationReport: Codable {
    let version: Int
    var status: String
    var qualification: String
    let createdAt: Date
    let corpusVersion: Int
    let selectedCaseIDs: [String]
    let providerID: String
    let conversationModelID: String
    let conversationProtocol: String
    let extractionProtocol: String
    let dialectProfileID: String
    let adapterID: String
    let embeddingsMode: String
    var cases: [EverydayMemoryCaseReport]
    var aggregate: LiveEvaluationAggregate
    /// Credential-read admission count, not an exact HTTP transport dispatch count.
    let requestAuthorizationCap: Int
    var requestAuthorizationCount: Int
}

private enum StateEvolutionKind: String, CaseIterable, Codable {
    case replacement
    case clearRetraction
    case retractionNearMiss
    case forgetReopen
    case relatedUnsupported
    case automaticEnrichment
    case foregroundEnrichment
}

private struct StateEvolutionCorpus: Codable {
    let version: Int
    let scenarios: [StateEvolutionScenario]

    static func load(data: Data) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["version", "scenarios"],
              let scenarios = root["scenarios"] as? [[String: Any]],
              scenarios.allSatisfy({ Set($0.keys) == ["id", "language", "kind", "steps", "followUp", "requiredTerms", "forbiddenTerms"] }),
              scenarios.allSatisfy({ scenario in
                  (scenario["steps"] as? [[String: Any]])?.allSatisfy({ Set($0.keys) == ["input", "expect"] }) == true
              }) else {
            throw MiraError(.invalidInput, "The state-evolution corpus contains unknown or missing fields.")
        }
        let corpus = try JSONDecoder().decode(Self.self, from: data)
        try corpus.validate()
        return corpus
    }

    func validate() throws {
        let validID: (String) -> Bool = { id in
            let parts = id.split(separator: "-", omittingEmptySubsequences: false)
            return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLowercase || $0.isNumber } }
        }
        guard version == 1, !scenarios.isEmpty,
              Set(scenarios.map(\.id)).count == scenarios.count,
              scenarios.allSatisfy({ scenario in
                  validID(scenario.id) && ["en", "zh-CN"].contains(scenario.language) &&
                  StateEvolutionKind(rawValue: scenario.kind) != nil &&
                  !scenario.followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  !scenario.steps.isEmpty && scenario.steps.allSatisfy({
                      !$0.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) && scenario.requiredTerms.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) &&
                  scenario.forbiddenTerms.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) &&
                  Self.validExpectations(kind: scenario.kind, steps: scenario.steps.map(\.expect))
              }) else {
            throw MiraError(.invalidInput, "The state-evolution corpus has invalid IDs, kinds, or step sequences.")
        }
    }

    func selected(ids: [String]) throws -> [StateEvolutionScenario] {
        guard Set(ids).count == ids.count else {
            throw MiraError(.invalidInput, "MIRA_EVAL_CASE_IDS contains duplicate state-evolution IDs.")
        }
        let byID = Dictionary(uniqueKeysWithValues: scenarios.map { ($0.id, $0) })
        let unknown = ids.filter { byID[$0] == nil }
        guard unknown.isEmpty else {
            throw MiraError(.invalidInput, "MIRA_EVAL_CASE_IDS contains unknown state-evolution IDs: \(unknown.joined(separator: ",")).")
        }
        return ids.compactMap { byID[$0] }
    }

    private static func validExpectations(kind: String, steps: [String]) -> Bool {
        switch StateEvolutionKind(rawValue: kind) {
        case .replacement: steps == ["establish", "replace"]
        case .clearRetraction: steps == ["establish", "retractWithoutReplacement"]
        case .retractionNearMiss: steps == ["establish", "preserve"]
        case .forgetReopen: steps == ["establish", "forget"]
        case .relatedUnsupported: steps == ["establish"]
        case .automaticEnrichment: steps == ["establish", "enrich"]
        case .foregroundEnrichment: steps == ["remember", "enrich"]
        case .none: false
        }
    }
}

private struct StateEvolutionScenario: Codable {
    struct Step: Codable { let input: String; let expect: String }
    let id: String
    let language: String
    let kind: String
    let steps: [Step]
    let followUp: String
    let requiredTerms: [String]
    let forbiddenTerms: [String]
}

private struct StateEvolutionWithdrawalEvidence: Codable, Sendable {
    let revision: Int
    let sourceReference: String
    let executionID: String
    let hasExcerpt: Bool
    let hasHash: Bool
}

private struct StateEvolutionRetractionSnapshot: Codable, Sendable {
    let priorRevision: Int
    let revision: Int
    let evidence: [StateEvolutionWithdrawalEvidence]
}

private struct StateEvolutionMemorySnapshot: Codable, Sendable {
    let id: String
    let revision: Int
    let state: String
    let lifecycle: String
    let isCurrent: Bool
    let body: String?
    let origin: String
    let authority: String
    let forgottenAt: Date?
    let supersededByID: String?
    let evidenceSourceReferences: [String]
    let evidenceExecutionIDs: [String]
    let revisionNumbers: [Int]
    let previousMemoryIDs: [String]
    let evidenceCount: Int
    let evidenceExcerptCount: Int
    let evidenceHashCount: Int
    let revisionBodyCount: Int
    let detailAvailable: Bool
    let detailErrorCode: String?
    var retraction: StateEvolutionRetractionSnapshot? = nil

    func with(evidenceExecutionIDs: [String]? = nil, evidenceSourceReferences: [String]? = nil,
              detailAvailable: Bool? = nil,
              body: String? = nil) -> Self {
        .init(id: id, revision: revision, state: state, lifecycle: lifecycle, isCurrent: isCurrent,
              body: body ?? self.body, origin: origin, authority: authority, forgottenAt: forgottenAt,
              supersededByID: supersededByID,
              evidenceSourceReferences: evidenceSourceReferences ?? self.evidenceSourceReferences,
              evidenceExecutionIDs: evidenceExecutionIDs ?? self.evidenceExecutionIDs,
              revisionNumbers: revisionNumbers, previousMemoryIDs: previousMemoryIDs,
              evidenceCount: evidenceCount, evidenceExcerptCount: evidenceExcerptCount,
              evidenceHashCount: evidenceHashCount, revisionBodyCount: revisionBodyCount,
              detailAvailable: detailAvailable ?? self.detailAvailable, detailErrorCode: detailErrorCode,
              retraction: retraction)
    }
}

private enum StateEvolutionAssertions {
    static func preservationFailures(
        memories: [StateEvolutionMemorySnapshot], baseline: StateEvolutionMemorySnapshot?,
        mutationInvocationCount: Int = 0, contextMemoryReferences: [String]? = nil
    ) -> [String] {
        guard let baseline, baseline.detailAvailable, baseline.isCurrent, baseline.state == "active",
              baseline.lifecycle == "active", baseline.body != nil, baseline.retraction == nil,
              !baseline.evidenceSourceReferences.isEmpty, baseline.evidenceCount > 0 else {
            return ["preservation_predecessor_not_established"]
        }
        var failures: [String] = []
        if mutationInvocationCount != 0 { failures.append("preservation_attempted_memory_mutation") }
        if memories.count != 1 { failures.append("preservation_memory_count_changed") }
        guard let current = memories.first(where: { $0.id == baseline.id }) else {
            return failures + ["preservation_target_missing"]
        }
        if !current.detailAvailable || !current.isCurrent || current.state != baseline.state ||
            current.lifecycle != baseline.lifecycle || current.revision != baseline.revision ||
            current.body != baseline.body || current.origin != baseline.origin || current.authority != baseline.authority ||
            current.forgottenAt != nil || current.supersededByID != nil || current.retraction != nil {
            failures.append("preservation_assertion_changed")
        }
        if Set(current.evidenceSourceReferences) != Set(baseline.evidenceSourceReferences) ||
            Set(current.evidenceExecutionIDs) != Set(baseline.evidenceExecutionIDs) ||
            current.evidenceCount != baseline.evidenceCount ||
            current.evidenceExcerptCount != baseline.evidenceExcerptCount ||
            current.evidenceHashCount != baseline.evidenceHashCount ||
            current.revisionNumbers != baseline.revisionNumbers ||
            current.revisionBodyCount != baseline.revisionBodyCount ||
            Set(current.previousMemoryIDs) != Set(baseline.previousMemoryIDs) {
            failures.append("preservation_history_or_evidence_changed")
        }
        if let contextMemoryReferences,
           !contextMemoryReferences.contains("memory:\(baseline.id)@\(baseline.revision)") {
            failures.append("preserved_memory_missing_from_fresh_context")
        }
        return failures
    }

    static func retractionFailures(memories: [StateEvolutionMemorySnapshot], baseline: StateEvolutionMemorySnapshot?,
                                   withdrawalExecutionID: String?, contextMemoryReferences: [String]) -> [String] {
        guard let baseline, baseline.isCurrent, baseline.lifecycle == "active", baseline.body != nil,
              !baseline.evidenceSourceReferences.isEmpty else { return ["retraction_predecessor_not_established"] }
        var failures: [String] = []
        if memories.count != 1 || memories.contains(where: { $0.id != baseline.id || $0.isCurrent }) {
            failures.append("retraction_created_replacement_or_current_fact")
        }
        guard let retired = memories.first(where: { $0.id == baseline.id }) else {
            return failures + ["retraction_target_missing"]
        }
        if retired.state != "archived" || retired.lifecycle != "archived" || retired.isCurrent ||
            retired.supersededByID != nil || !retired.previousMemoryIDs.isEmpty {
            failures.append("retraction_target_not_archived_without_successor")
        }
        if !retired.detailAvailable || retired.body != baseline.body || retired.forgottenAt != nil ||
            !Set(baseline.revisionNumbers).isSubset(of: Set(retired.revisionNumbers)) ||
            retired.revisionBodyCount < baseline.revisionBodyCount ||
            Set(retired.evidenceSourceReferences) != Set(baseline.evidenceSourceReferences) {
            failures.append("retraction_history_or_supporting_evidence_changed")
        }
        if let retraction = retired.retraction {
            if retraction.priorRevision != baseline.revision || retraction.revision != baseline.revision + 1 ||
                retired.revision != retraction.revision {
                failures.append("retraction_revision_not_bound_to_predecessor")
            }
            let bound = retraction.evidence.filter {
                $0.revision == retraction.revision && $0.executionID == withdrawalExecutionID &&
                $0.hasExcerpt && $0.hasHash && !baseline.evidenceSourceReferences.contains($0.sourceReference)
            }
            if withdrawalExecutionID == nil || bound.count != 1 {
                failures.append("retraction_withdrawal_provenance_missing")
            }
        } else { failures.append("retraction_marker_missing") }
        if contextMemoryReferences.contains(where: { $0.hasPrefix("memory:\(baseline.id)@") }) {
            failures.append("retracted_memory_in_ordinary_context")
        }
        return failures
    }

    static func evolutionFailures(memories: [StateEvolutionMemorySnapshot], expectedExecutionIDs: Set<String>,
                                   expectedPreviousMemoryIDs: Set<String>, preservePreviousEvidence: Bool) -> [String] {
        let current = memories.filter { $0.lifecycle == MemoryLifecycleStatus.active.rawValue }
        var failures: [String] = []
        if expectedPreviousMemoryIDs.isEmpty { failures.append("evolution_predecessor_not_established") }
        if current.count != 1 { failures.append("current_representation_count_mismatch") }
        guard let final = current.first else { return failures }
        if !final.detailAvailable { failures.append("memory_details_unavailable") }
        if final.body == nil { failures.append("current_memory_body_unavailable") }
        if !final.isCurrent { failures.append("effective_lifecycle_not_current") }
        if !expectedExecutionIDs.isSubset(of: Set(final.evidenceExecutionIDs)) {
            failures.append("source_lineage_missing")
        }
        if !expectedPreviousMemoryIDs.isSubset(of: Set(final.previousMemoryIDs)) {
            failures.append("evolution_relation_missing")
        }
        for previousID in expectedPreviousMemoryIDs {
            guard let previous = memories.first(where: { $0.id == previousID }),
                  previous.lifecycle == MemoryLifecycleStatus.superseded.rawValue,
                  previous.supersededByID == final.id else {
                failures.append("evolution_target_not_superseded_by_final")
                break
            }
            if previous.body == nil || previous.revisionBodyCount == 0 {
                failures.append("evolution_previous_body_unavailable")
            }
            if preservePreviousEvidence,
               !Set(previous.evidenceSourceReferences).isSubset(of: Set(final.evidenceSourceReferences)) {
                failures.append("inherited_source_identity_missing")
            }
        }
        return failures
    }

    static func forgottenFailures(memory: StateEvolutionMemorySnapshot?, contextMemoryReferences: [String]) -> [String] {
        guard let memory else { return ["forgotten_memory_details_missing"] }
        var failures: [String] = []
        if !memory.detailAvailable { failures.append("forgotten_memory_details_unavailable") }
        if memory.lifecycle != MemoryLifecycleStatus.forgotten.rawValue { failures.append("forgotten_lifecycle_not_effective") }
        if memory.body != nil { failures.append("forgotten_memory_body_available") }
        if memory.evidenceExcerptCount > 0 || memory.evidenceHashCount > 0 || memory.revisionBodyCount > 0 {
            failures.append("forgotten_memory_body_material_retained")
        }
        if contextMemoryReferences.contains(where: { $0.hasPrefix("memory:\(memory.id)@") }) {
            failures.append("forgotten_memory_in_context")
        }
        return failures
    }
}

private struct StateEvolutionExtractionAttemptSnapshot: Codable, Sendable {
    let attemptID: String
    let ordinal: Int
    let state: String
    let reservedTokens: Int
    let chargedTokens: Int
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
    let reasoningTokens: Int?
    let dispatched: Bool
}

private struct StateEvolutionExtractionSnapshot: Codable, Sendable {
    let jobID: String?
    let sourceExecutionID: String?
    let status: String
    let errorCode: String?
    let memoryCount: Int
    let candidateCount: Int
    let attempts: [StateEvolutionExtractionAttemptSnapshot]

    init(jobID: String? = nil, sourceExecutionID: String? = nil, status: String,
         errorCode: String?, memoryCount: Int, candidateCount: Int,
         attempts: [StateEvolutionExtractionAttemptSnapshot]) {
        self.jobID = jobID; self.sourceExecutionID = sourceExecutionID; self.status = status
        self.errorCode = errorCode; self.memoryCount = memoryCount; self.candidateCount = candidateCount
        self.attempts = attempts
    }
}

private struct StateEvolutionTokenUsageSnapshot: Codable, Sendable {
    let id: String
    let complete: Bool
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
    let reasoningTokens: Int?

    init(_ usage: SessionModelAttemptUsage) {
        id = usage.id.uuidString.lowercased(); complete = usage.isComplete
        inputTokens = usage.usage.totalInputTokens; outputTokens = usage.usage.outputTokens
        cacheReadTokens = usage.usage.cacheReadTokens; cacheWriteTokens = usage.usage.cacheWriteTokens
        reasoningTokens = usage.usage.reasoningTokens
    }
}

private struct StateEvolutionStepSnapshot: Codable, Sendable {
    let index: Int
    let expectation: String
    let input: String
    let sessionID: String?
    let executionID: String?
    let executionOutcome: String
    let extraction: StateEvolutionExtractionSnapshot
    let memoryContextReferences: [String]
    let rememberInvocationCount: Int
    let rememberSucceededCount: Int
    let conversationUsage: [StateEvolutionTokenUsageSnapshot]
    let memories: [StateEvolutionMemorySnapshot]
    var retractInvocationCount: Int? = nil
    var retractSucceededCount: Int? = nil
    var answer: String? = nil
}

private struct StateEvolutionKeywordObservation: Codable, Sendable {
    let term: String
    let observed: Bool
    let expectedPresence: Bool
    let basis: String = "keyword heuristic; human review required; not a semantic judge"
}

private struct StateEvolutionFollowUpSnapshot: Codable, Sendable {
    let sessionID: String
    let executionID: String
    let executionOutcome: String
    let answer: String
    let memoryContextReferences: [String]
    let visibleCitationReferences: [String]
    let verifiedCitationReferences: [String]
    let rejectedCitationReferences: [String]
    let answerKeywordObservations: [StateEvolutionKeywordObservation]
    let conversationUsage: [StateEvolutionTokenUsageSnapshot]
}

private struct StateEvolutionExecutionCheckpoint: Sendable {
    let phase: String
    let stepIndex: Int?
    let sessionID: ConversationID
    let executionID: ExecutionID
    var admissionOutcome: String? = nil
    var completionOutcome: String? = nil
}

/// Nullable audit fields distinguish unavailable evidence from an observed empty result.
/// Usage retains attempt identity and completeness; it does not infer HTTP dispatch.
private struct StateEvolutionFailureExecutionSnapshot: Codable, Sendable {
    let phase: String
    let stepIndex: Int?
    let sessionID: String
    let executionID: String
    let admissionOutcome: String?
    let completionOutcome: String?
    var auditAvailable: Bool
    var auditHasMore: Bool? = nil
    var auditReadErrorCode: String? = nil
    var executionOutcome: String? = nil
    var executionErrorCode: String? = nil
    var memoryContextReferences: [String]? = nil
    var conversationUsage: [StateEvolutionTokenUsageSnapshot]? = nil
}

private struct StateEvolutionCaseReport: Codable, Sendable {
    let id: String
    let kind: String
    var status: String
    var terminalOutcome: String?
    var errorCode: String?
    var failureStage: String?
    var failureStepIndex: Int?
    var failureExecution: StateEvolutionFailureExecutionSnapshot? = nil
    var stepSnapshots: [StateEvolutionStepSnapshot]
    var finalMemorySnapshots: [StateEvolutionMemorySnapshot]
    var followUp: StateEvolutionFollowUpSnapshot?
    var backgroundExtractionState: String?
    var postForegroundExtraction: StateEvolutionExtractionSnapshot?
    var terminalExtractionJobs: [StateEvolutionTerminalJobSnapshot]
    var approvalDenialCount: Int
    var stateChecks: [String]
    var mismatchReasons: [String]

    static func pending(id: String, kind: String, status: String = "pending") -> Self {
        .init(id: id, kind: kind, status: status, terminalOutcome: nil, errorCode: nil,
              failureStage: nil, failureStepIndex: nil,
              stepSnapshots: [], finalMemorySnapshots: [], followUp: nil,
              backgroundExtractionState: nil, postForegroundExtraction: nil, terminalExtractionJobs: [], approvalDenialCount: 0,
              stateChecks: [], mismatchReasons: [])
    }
}

private struct StateEvolutionTerminalJobSnapshot: Codable, Sendable {
    let id: String
    let state: String
    let memoryCount: Int
    let candidateCount: Int
}

private struct StateEvolutionLiveReport: Codable, Sendable {
    let version: Int
    var status: String
    let qualification: String
    let createdAt: Date
    var updatedAt: Date
    let corpusVersion: Int
    let selectedCaseIDs: [String]
    let providerID: String
    let conversationModelID: String
    let protocolID: String
    let dialectProfileID: String
    let adapterID: String
    let conversationInstructions: String
    let contextWindow: Int
    let conversationOutputTokens: Int
    let extractionOutputTokenCap: Int
    var embeddingsMode: String
    let requestAuthorizationCap: Int
    var requestAuthorizationCount: Int
    var cases: [StateEvolutionCaseReport]

    init(version: Int, status: String, qualification: String, createdAt: Date, corpusVersion: Int,
         selectedCaseIDs: [String], providerID: String, conversationModelID: String,
         protocolID: String, dialectProfileID: String, adapterID: String,
         contextWindow: Int, conversationOutputTokens: Int, embeddingsMode: String,
         requestAuthorizationCap: Int, requestAuthorizationCount: Int,
         cases: [StateEvolutionCaseReport]) {
        self.version = version; self.status = status; self.qualification = qualification
        self.createdAt = createdAt; self.updatedAt = createdAt; self.corpusVersion = corpusVersion
        self.selectedCaseIDs = selectedCaseIDs; self.providerID = providerID
        self.conversationModelID = conversationModelID; self.protocolID = protocolID
        self.dialectProfileID = dialectProfileID; self.adapterID = adapterID
        self.conversationInstructions = "You are Mira, a personal assistant. Reply in the user's requested language, otherwise the language of their message. Use tools when needed and preserve source citations."
        self.contextWindow = contextWindow
        self.conversationOutputTokens = conversationOutputTokens
        self.extractionOutputTokenCap = min(MemoryExtractionRequestBuilder.outputTokenTarget, conversationOutputTokens)
        self.embeddingsMode = embeddingsMode
        self.requestAuthorizationCap = requestAuthorizationCap
        self.requestAuthorizationCount = requestAuthorizationCount; self.cases = cases
    }
}

private final class StateEvolutionReportWriter {
    private let lock = NSLock()
    private var report: StateEvolutionLiveReport
    private let url: URL

    init(report: StateEvolutionLiveReport, url: URL) { self.report = report; self.url = url }

    func write() throws {
        lock.lock(); defer { lock.unlock() }
        try persist()
    }

    func replaceCase(_ value: StateEvolutionCaseReport, requestAuthorizationCount: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard let index = report.cases.firstIndex(where: { $0.id == value.id }) else {
            throw MiraError(.invalidInput, "The state-evaluation report case ID is not selected.")
        }
        report.cases[index] = value
        report.requestAuthorizationCount = requestAuthorizationCount
        report.updatedAt = .now
        try persist()
    }

    func finish(requestAuthorizationCount: Int) throws -> StateEvolutionLiveReport {
        lock.lock(); defer { lock.unlock() }
        report.requestAuthorizationCount = requestAuthorizationCount
        report.updatedAt = .now
        report.status = report.cases.allSatisfy({ $0.status == "completed" }) ? "completed" : "completed_with_failures_or_mismatches"
        try persist()
        return report
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
    }
}
