import Foundation
import MiraCore
import MiraData
import MiraProviders
import XCTest

/// Each invocation runs one phase. The launcher waits for process exit before
/// starting recall and owns the disposable library's eventual deletion.
final class MemoryContinuityLiveTests: XCTestCase {
    private static let processInstanceID = UUID().uuidString.lowercased()

    func testOptInContinuityPhase() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MIRA_RUN_LIVE_MEMORY_CONTINUITY_EVAL"] == "1" else {
            throw XCTSkip("Live memory continuity evaluation is explicitly opt-in.")
        }
        let configuration = try LiveEvaluationConfiguration(environment: environment, mode: .stateEvolution)
        let corpus = try JSONDecoder().decode(MemoryContinuityCorpus.self, from: Data(contentsOf: configuration.corpusURL))
        try corpus.validate()
        let scenario = try XCTUnwrap(corpus.scenarios.first { configuration.caseIDs == [$0.id] })
        let root = URL(fileURLWithPath: try XCTUnwrap(environment["MIRA_CONTINUITY_ROOT"])).resolvingSymlinksInPath()
        let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard root.path.hasPrefix(temporaryRoot.path + "/"),
              root.lastPathComponent.hasPrefix("Mira-Continuity-"),
              FileManager.default.fileExists(atPath: root.path),
              let phase = MemoryContinuityPhase(rawValue: environment["MIRA_CONTINUITY_PHASE"] ?? ""),
              let runID = environment["MIRA_CONTINUITY_RUN_ID"], UUID(uuidString: runID) != nil,
              (1...8).contains(configuration.requestAuthorizationCap) else {
            throw MemoryContinuityFailure(code: "invalid_continuity_configuration")
        }
        let libraryURL = root.appendingPathComponent("Library")
        let markerURL = root.appendingPathComponent("identity.json")
        let identity = MemoryContinuityIdentity(runID: runID, scenario: scenario,
            root: root.path, configuration: configuration)
        var prior: MemoryContinuityReport?
        if phase == .establish {
            guard configuration.requestAuthorizationCap <= 6,
                  !FileManager.default.fileExists(atPath: libraryURL.path),
                  !FileManager.default.fileExists(atPath: markerURL.path) else {
                throw MemoryContinuityFailure(code: "establishment_requires_fresh_library")
            }
            try JSONEncoder().encode(identity).write(to: markerURL, options: .atomic)
        } else {
            let savedIdentity = try JSONDecoder().decode(MemoryContinuityIdentity.self, from: Data(contentsOf: markerURL))
            let handoffURL = URL(fileURLWithPath: try XCTUnwrap(environment["MIRA_CONTINUITY_HANDOFF"]))
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            prior = try decoder.decode(MemoryContinuityReport.self, from: Data(contentsOf: handoffURL))
            let failures = MemoryContinuityHandoff.failures(
                prior: prior, identity: identity, marker: savedIdentity,
                currentProcessID: ProcessInfo.processInfo.processIdentifier,
                currentProcessInstanceID: Self.processInstanceID,
                recallAuthorizationCap: configuration.requestAuthorizationCap)
            guard failures.isEmpty, FileManager.default.fileExists(atPath: libraryURL.path) else {
                throw MemoryContinuityFailure(code: failures.first ?? "established_library_missing")
            }
        }
        let report = await Self.evaluate(
            scenario: scenario, phase: phase, identity: identity, prior: prior,
            configuration: configuration, libraryURL: libraryURL)
        try Self.write(report, to: configuration.reportURL)
        XCTAssertEqual(report.status, "completed", "Continuity phase failed: \(report.errorCode ?? report.mismatches.joined(separator: ","))")
    }

    private static func evaluate(
        scenario: MemoryContinuityScenario, phase: MemoryContinuityPhase,
        identity: MemoryContinuityIdentity, prior: MemoryContinuityReport?,
        configuration: LiveEvaluationConfiguration, libraryURL: URL
    ) async -> MemoryContinuityReport {
        let counter = RequestAuthorizationCounter()
        let credentials = EvaluationCredentials(secret: configuration.apiKey, counter: counter,
                                                limit: configuration.requestAuthorizationCap)
        let approvals = ApprovalCounter()
        var report = MemoryContinuityReport(identity: identity, phase: phase,
            processID: ProcessInfo.processInfo.processIdentifier, processInstanceID: processInstanceID,
            requestAuthorizationCap: configuration.requestAuthorizationCap)
        var library: MacLibrary?
        var group: MacLibraryWorkloads?
        var approvalTask: Task<Void, Never>?
        var checkpoint: StateEvolutionExecutionCheckpoint?
        var stage = "library_open"
        func publish() throws {
            report.requestAuthorizationCount = counter.value
            report.approvalDenialCount = approvals.value
            try write(report, to: configuration.reportURL)
        }
        do {
            try publish()
            let opened = try await MacLibrary.open(embeddings: configuration.embeddingsMode.injectedService(),
                directory: libraryURL, notifications: LiveNoopNotifications(), credentials: credentials,
                modules: { [MacHTTPModule(registry: $0, credentials: credentials)] })
            library = opened
            let workloads = try await opened.workloads(); group = workloads
            stage = "embeddings_prepare"
            try await configuration.embeddingsMode.prepare(in: workloads)
            approvalTask = Task {
                for await requests in await workloads.approvals.snapshots() {
                    for request in requests {
                        do {
                            try await workloads.approvals.resolve(id: request.id, proposalHash: request.proposalHash,
                                authorizationEpoch: request.authorizationEpoch, decision: .denied)
                            approvals.increment()
                        } catch {}
                    }
                }
            }
            let route: AgentModelRoute
            if phase == .establish {
                stage = "empty_baseline"
                report.before = try await EverydayMemoryLiveTests.captureState(in: workloads, knownIDs: [])
                guard report.before?.isEmpty == true else { throw MemoryContinuityFailure(code: "baseline_not_empty") }
                stage = "settings_install"
                route = try await EverydayMemoryLiveTests.installSettings(in: workloads, configuration: configuration).conversation
            } else {
                stage = "restart_read"
                guard let prior, let established = prior.after?.first, let source = prior.execution,
                      let sourceSession = UUID(uuidString: source.sessionID),
                      let sourceExecution = UUID(uuidString: source.executionID) else {
                    throw MemoryContinuityFailure(code: "handoff_source_missing")
                }
                report.before = try await EverydayMemoryLiveTests.captureState(in: workloads, knownIDs: [])
                report.mismatches += MemoryContinuityAssertions.preservationFailures(
                    memories: report.before ?? [], baseline: established)
                report.beforeMaterial = try await memoryMaterial(in: workloads, snapshots: report.before)
                guard report.beforeMaterial == prior.afterMaterial else {
                    throw MemoryContinuityFailure(code: "memory_material_changed_after_restart")
                }
                let original = try await executionSnapshot(in: workloads, sessionID: .init(sourceSession),
                    executionID: .init(sourceExecution), expectedInput: scenario.input)
                guard original == source else { throw MemoryContinuityFailure(code: "source_or_receipt_changed_after_restart") }
                report.reopenedSource = original
                route = try await workloads.modelSettings.resolve(
                    purpose: AgentModelPurposeID.conversation, explicitRouteID: nil, sessionSelection: .inherit, workspaceID: nil,
                    requiredCapabilities: []).route
                guard route == prior.route else { throw MemoryContinuityFailure(code: "route_changed_after_restart") }
                guard report.mismatches.isEmpty else { throw MemoryContinuityFailure(code: "restart_state_mismatch") }
                report.checks.append("source_receipt_and_memory_unchanged_in_new_process")
            }
            report.route = route
            let sessionID = ConversationID(), executionID = ExecutionID()
            if phase == .recall, sessionID.rawValue.uuidString.lowercased() == prior?.execution?.sessionID {
                throw MemoryContinuityFailure(code: "recall_session_not_fresh")
            }
            let input = phase == .establish ? scenario.input : scenario.followUp
            checkpoint = .init(phase: phase.rawValue, stepIndex: nil, sessionID: sessionID, executionID: executionID)
            stage = "submit"
            let admission = await workloads.application.submit(EverydayMemoryLiveTests.command(
                sessionID: sessionID, executionID: executionID, text: input, route: route,
                opening: .init(title: "Synthetic memory continuity \(scenario.id)", workspaceID: nil)))
            checkpoint?.admissionOutcome = EverydayMemoryLiveTests.commitOutcome(admission)
            guard case .committed = admission else { throw MemoryContinuityFailure(code: "admission_not_committed") }
            stage = "completion"
            let completion = await workloads.application.waitForExecution(id: executionID, sessionID: sessionID)
            checkpoint?.completionOutcome = EverydayMemoryLiveTests.commitOutcome(completion)
            guard case .committed = completion else { throw MemoryContinuityFailure(code: "completion_not_committed") }
            stage = "execution_evidence"
            let execution = try await executionSnapshot(in: workloads, sessionID: sessionID,
                executionID: executionID, expectedInput: input)
            report.execution = execution
            checkpoint = nil
            report.immediate = try await EverydayMemoryLiveTests.captureState(in: workloads, knownIDs: [])
            report.immediateMaterial = try await memoryMaterial(in: workloads, snapshots: report.immediate)
            report.mismatches += MemoryReplyPresentationAssertions.failures(
                answer: execution.answer, memoryIDs: (report.immediate ?? []).map(\.id))
            if phase == .establish {
                let writes = execution.tools.filter { ["memory.remember", "memory.retract"].contains($0.name) }
                if scenario.mode == .automatic {
                    if !writes.isEmpty { report.mismatches.append("ordinary_statement_attempted_foreground_write") }
                    if report.immediate?.isEmpty != true { report.mismatches.append("ordinary_statement_saved_before_background") }
                } else {
                    report.mismatches += MemoryContinuityAssertions.establishmentFailures(
                        memories: report.immediate ?? [], mode: scenario.mode,
                        sourceExecutionID: execution.executionID, sourceReference: execution.sourceReference)
                    report.mismatches += MemoryContinuityReceipt.failures(
                        execution: execution, memory: report.immediate?.first)
                }
                try publish()
                stage = "background_extraction"
                await workloads.wake()
                let observation = try await EverydayMemoryLiveTests.waitForMemory(
                    in: workloads, sourceSession: sessionID, sourceExecution: executionID, timeout: 240)
                report.extraction = try await EverydayMemoryLiveTests.extractionSnapshot(
                    in: workloads, sourceSession: sessionID, sourceExecution: executionID,
                    fallbackState: observation.state, fallbackError: observation.errorCode)
                guard report.extraction?.status == "completed", report.extraction?.jobID != nil,
                      report.extraction?.sourceExecutionID == execution.executionID else {
                    throw MemoryContinuityFailure(code: "background_extraction_not_completed")
                }
                report.after = try await EverydayMemoryLiveTests.captureState(in: workloads, knownIDs: [])
                report.afterMaterial = try await memoryMaterial(in: workloads, snapshots: report.after)
                report.mismatches += MemoryContinuityAssertions.establishmentFailures(
                    memories: report.after ?? [], mode: scenario.mode,
                    sourceExecutionID: execution.executionID, sourceReference: execution.sourceReference)
                if scenario.mode == .explicitSave {
                    report.mismatches += MemoryContinuityAssertions.preservationFailures(
                        memories: report.after ?? [], baseline: report.immediate?.first)
                    if report.afterMaterial != report.immediateMaterial {
                        report.mismatches.append("explicit_save_material_changed_during_extraction")
                    }
                }
                if report.mismatches.isEmpty { report.checks.append("exact_source_and_memory_survive_completed_background_extraction") }
            } else {
                report.after = report.immediate
                report.afterMaterial = report.immediateMaterial
                if report.afterMaterial != prior?.afterMaterial {
                    report.mismatches.append("memory_material_changed_during_recall")
                }
                report.mismatches += StateEvolutionAssertions.preservationFailures(
                    memories: report.after ?? [], baseline: prior?.after?.first,
                    mutationInvocationCount: execution.tools.filter { ["memory.remember", "memory.retract"].contains($0.name) }.count,
                    contextMemoryReferences: execution.memoryReferences)
                if report.mismatches.isEmpty { report.checks.append("same_memory_in_fresh_session_after_process_restart") }
            }
            report.status = report.mismatches.isEmpty ? "completed" : "completed_with_mismatches"
        } catch {
            report.status = "failed"; report.failureStage = stage
            report.errorCode = counter.wasDenied ? "request_authorization_cap_reached"
                : ((error as? MemoryContinuityFailure)?.code ?? MiraError.safe(error).code.rawValue)
            if let checkpoint, let group {
                report.failureExecution = await EverydayMemoryLiveTests.captureFailureExecution(checkpoint) {
                    try await group.queries.executionAudit(sessionID: checkpoint.sessionID,
                        executionID: checkpoint.executionID, beforeSequence: nil, limit: 32)
                }
            }
            if let execution = report.execution, report.extraction == nil, let group,
               let session = UUID(uuidString: execution.sessionID), let id = UUID(uuidString: execution.executionID) {
                report.extraction = try? await EverydayMemoryLiveTests.extractionSnapshot(
                    in: group, sourceSession: .init(session), sourceExecution: .init(id),
                    fallbackState: "unavailable", fallbackError: report.errorCode)
            }
        }
        approvalTask?.cancel()
        if let library {
            let closure = await library.close()
            report.closeSettled = closure.isSettled
            if !closure.isSettled {
                report.status = "failed"
                report.errorCode = report.errorCode ?? "library_close_not_settled"
            }
        }
        _ = await approvalTask?.result
        report.requestAuthorizationCount = counter.value
        report.approvalDenialCount = approvals.value
        if approvals.value != 0 { report.mismatches.append("unexpected_approval_request"); report.status = "failed" }
        report.finishedAt = Date()
        return report
    }

    private static func memoryMaterial(
        in group: MacLibraryWorkloads, snapshots: [StateEvolutionMemorySnapshot]?
    ) async throws -> JSONValue? {
        guard let snapshots, snapshots.count == 1, let id = UUID(uuidString: snapshots[0].id) else { return nil }
        let detail = try await group.memories.detail(.init(id), workspaceID: nil)
        // Canonical numeric dates preserve stored precision independently of the
        // report's human-readable timestamps. Include exact bodies and policies,
        // not just evidence/revision cardinality, across the process boundary.
        let material = MemoryContinuityMaterial(memory: detail.memory,
            evidence: detail.evidence.sorted { $0.id.uuidString < $1.id.uuidString },
            revisions: detail.revisions.sorted { $0.revision < $1.revision },
            replacements: detail.replacements.sorted { $0.id.uuidString < $1.id.uuidString })
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(material))
    }

    private static func executionSnapshot(
        in group: MacLibraryWorkloads, sessionID: ConversationID, executionID: ExecutionID,
        expectedInput: String
    ) async throws -> MemoryContinuityExecution {
        let audit = try await group.queries.executionAudit(
            sessionID: sessionID, executionID: executionID, beforeSequence: nil, limit: 32)
        guard !audit.hasMore, audit.execution.completion?.status == .completed,
              audit.execution.id == executionID, audit.execution.sessionID == sessionID else {
            if case .available(let error) = audit.error { throw error }
            throw MemoryContinuityFailure(code: "execution_audit_incomplete")
        }
        let state = try await group.application.sessionSnapshot(id: sessionID)
        guard let original = state.executions[executionID],
              let body = original.admission.userBody,
              String(data: body.bytes, encoding: .utf8) == expectedInput,
              let answer = try await EverydayMemoryLiveTests.assistantAnswer(in: group, sessionID: sessionID, executionID: executionID),
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryContinuityFailure(code: "execution_source_or_answer_missing")
        }
        let reference = SessionEvidenceReference(sessionID: sessionID, originalExecutionID: executionID,
            userMessageID: original.admission.userMessageID, admissionEventID: original.admissionEventID,
            admissionSequence: original.admissionSequence)
        let rounds = try audit.attempts.sorted { $0.sequence < $1.sequence }.map { attempt in
            guard case .available(let request) = attempt.request,
                  request.instructions == ConversationInstructions.default else {
                throw MemoryContinuityFailure(code: "actual_request_instructions_mismatch")
            }
            let text: String?
            if case .available(let output) = attempt.output {
                text = output.blocks.compactMap { if case .text(let value) = $0.content { value } else { nil } }.joined()
            } else { text = nil }
            let references = request.sources.compactMap { source -> String? in
                guard case .domain(let namespace, let id, let revision) = source, namespace == "memories" else { return nil }
                return "memory:\(id.uuidString.lowercased())@\(revision)"
            }
            return MemoryContinuityRound(attemptID: attempt.id, sequence: attempt.sequence,
                visibleText: text, memoryReferences: Array(Set(references)).sorted())
        }
        let tools = audit.attempts.flatMap { attempt in
            attempt.invocations.map { invocation in
                let result: JSONValue?
                if case .available(let value) = invocation.result { result = value } else { result = nil }
                return MemoryContinuityTool(id: invocation.id, attemptID: attempt.id,
                    name: invocation.state.invocation.toolName,
                    status: invocation.state.resolution?.status.rawValue,
                    receipt: invocation.state.resolution?.businessReceipt, result: result)
            }
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        return .init(sessionID: sessionID.rawValue.uuidString.lowercased(),
            executionID: executionID.rawValue.uuidString.lowercased(), input: expectedInput, answer: answer,
            sourceReference: EverydayMemoryLiveTests.sourceReferenceString(reference),
            memoryReferences: rounds.last?.memoryReferences ?? [],
            rounds: rounds, tools: tools, usage: audit.modelUsage.map(StateEvolutionTokenUsageSnapshot.init))
    }

    private static func write(_ report: MemoryContinuityReport, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
    }
}

enum MemoryContinuityPhase: String, Codable { case establish, recall }
struct MemoryContinuityFailure: Error { let code: String }

private struct MemoryContinuityMaterial: Encodable {
    let memory: Memory
    let evidence: [MemoryEvidence]
    let revisions: [MemoryRevision]
    let replacements: [MemoryReplacement]
}

struct MemoryContinuityIdentity: Codable, Equatable {
    let runID: String
    let caseID: String
    let language: String
    let mode: MemoryContinuityMode
    let input: String
    let followUp: String
    let asksForSource: Bool
    let root: String
    let providerID: String
    let modelID: String
    let endpoint: String
    let protocolID: String
    let contextWindow: Int
    let outputTokens: Int
    let embeddings: String
    let instructions: String

    init(runID: String, scenario: MemoryContinuityScenario, root: String, configuration: LiveEvaluationConfiguration) {
        self.runID = runID; caseID = scenario.id; language = scenario.language; mode = scenario.mode
        input = scenario.input; followUp = scenario.followUp; asksForSource = scenario.asksForSource; self.root = root
        providerID = configuration.providerID; modelID = configuration.conversationModelID
        endpoint = configuration.endpoint; protocolID = configuration.protocolID.rawValue
        contextWindow = configuration.contextWindow; outputTokens = configuration.conversationOutputTokens
        embeddings = configuration.embeddingsMode.rawValue; instructions = ConversationInstructions.default
    }
}

struct MemoryContinuityRound: Codable, Equatable {
    let attemptID: UUID
    let sequence: Int64
    let visibleText: String?
    let memoryReferences: [String]

    init(attemptID: UUID, sequence: Int64, visibleText: String?, memoryReferences: [String] = []) {
        self.attemptID = attemptID; self.sequence = sequence
        self.visibleText = visibleText; self.memoryReferences = memoryReferences
    }
}

struct MemoryContinuityTool: Codable, Equatable {
    let id: UUID
    let attemptID: UUID
    let name: String
    let status: String?
    let receipt: AgentBusinessReceiptReference?
    let result: JSONValue?
}

struct MemoryContinuityExecution: Codable, Equatable {
    let sessionID: String
    let executionID: String
    let input: String
    let answer: String
    let sourceReference: String
    let memoryReferences: [String]
    let rounds: [MemoryContinuityRound]
    let tools: [MemoryContinuityTool]
    let usage: [StateEvolutionTokenUsageSnapshot]
}

struct MemoryContinuityReport: Codable {
    var version = 1
    let identity: MemoryContinuityIdentity
    let phase: MemoryContinuityPhase
    let processID: Int32
    let processInstanceID: String
    var startedAt = Date()
    var finishedAt: Date?
    var status = "running"
    var qualification = "host evidence only; reply and fact semantics require separate review"
    let requestAuthorizationCap: Int
    var requestAuthorizationCount = 0
    var approvalDenialCount = 0
    var closeSettled = false
    var route: AgentModelRoute?
    var before: [StateEvolutionMemorySnapshot]?
    var immediate: [StateEvolutionMemorySnapshot]?
    var after: [StateEvolutionMemorySnapshot]?
    var beforeMaterial: JSONValue?
    var immediateMaterial: JSONValue?
    var afterMaterial: JSONValue?
    var execution: MemoryContinuityExecution?
    var reopenedSource: MemoryContinuityExecution?
    var extraction: StateEvolutionExtractionSnapshot?
    var failureExecution: StateEvolutionFailureExecutionSnapshot?
    var failureStage: String?
    var errorCode: String?
    var checks: [String] = []
    var mismatches: [String] = []
}

enum MemoryContinuityHandoff {
    static func failures(prior: MemoryContinuityReport?, identity: MemoryContinuityIdentity,
                         marker: MemoryContinuityIdentity, currentProcessID: Int32,
                         currentProcessInstanceID: String, recallAuthorizationCap: Int) -> [String] {
        guard let prior else { return ["handoff_missing"] }
        var result: [String] = []
        if prior.version != 1 || prior.phase != .establish || prior.status != "completed" ||
            !prior.closeSettled || prior.finishedAt == nil || !prior.mismatches.isEmpty ||
            prior.execution == nil || prior.route == nil || prior.afterMaterial == nil || prior.extraction?.status != "completed" ||
            prior.extraction?.jobID == nil || prior.extraction?.sourceExecutionID != prior.execution?.executionID ||
            prior.approvalDenialCount != 0 || prior.errorCode != nil {
            result.append("handoff_not_settled")
        }
        if prior.identity != identity || marker != identity { result.append("handoff_identity_mismatch") }
        if prior.processID == currentProcessID || prior.processInstanceID == currentProcessInstanceID {
            result.append("handoff_requires_new_process")
        }
        if !(1...8).contains(recallAuthorizationCap) || !(1...6).contains(prior.requestAuthorizationCap) ||
            !(0...6).contains(prior.requestAuthorizationCount) ||
            prior.requestAuthorizationCount > prior.requestAuthorizationCap ||
            prior.requestAuthorizationCount + recallAuthorizationCap > 8 {
            result.append("handoff_budget_exceeded")
        }
        result += MemoryContinuityAssertions.establishmentFailures(
            memories: prior.after ?? [], mode: identity.mode,
            sourceExecutionID: prior.execution?.executionID ?? "",
            sourceReference: prior.execution?.sourceReference ?? "")
        return result
    }
}

enum MemoryContinuityReceipt {
    static func failures(execution: MemoryContinuityExecution, memory: StateEvolutionMemorySnapshot?) -> [String] {
        let writes = execution.tools.filter { ["memory.remember", "memory.retract"].contains($0.name) }
        guard writes.count == 1, let tool = writes.first, tool.name == "memory.remember",
              tool.status == "succeeded", let receipt = tool.receipt, receipt.invocationID == tool.id,
              let memory, let result = tool.result,
              result["memory_id"]?.stringValue == memory.id,
              result["revision"] == .number(Double(memory.revision)),
              result["state"] == .string("active"), result["allows_remote_use"] == .bool(true),
              result["policy"] == .string("remote_allowed"),
              let callRound = execution.rounds.first(where: { $0.attemptID == tool.attemptID }),
              let last = execution.rounds.last, last.sequence > callRound.sequence,
              last.visibleText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return ["explicit_save_missing_matching_committed_receipt_or_continuation"]
        }
        do { try receipt.validate() } catch {
            return ["explicit_save_invalid_receipt_digest"]
        }
        return []
    }
}
