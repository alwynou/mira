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
            "MIRA_EVAL_PROTOCOL": HTTPProtocolID.chatCompletions.rawValue,
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
            conversationModelID: configuration.conversationModelID,
            conversationProtocol: configuration.protocolID.rawValue,
            extractionProtocol: configuration.protocolID.rawValue, cases: [], aggregate: .init(),
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
            let opened = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: directory, notifications: LiveNoopNotifications(), credentials: credentials,
                modules: { [MacHTTPModule(registry: $0, credentials: credentials)] })
            library = opened
            let workloads = try await opened.workloads()
            group = workloads
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
                answer = try await Self.assistantAnswer(in: workloads, sessionID: followupSessionID)
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
            await workloads.close()
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
                await workloads.close()
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

    private static func installSettings(
        in group: MacLibraryWorkloads, configuration: LiveEvaluationConfiguration
    ) async throws -> EvaluationRoutes {
        let connectionID = ConnectionID()
        let conversationModelID = ModelDescriptorID()
        let conversationRouteID = RouteID(conversationModelID.rawValue)
        let provider = try XCTUnwrap(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
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
        route: AgentModelRoute, opening: AgentSessionOpening
    ) -> AgentSubmitCommand {
        .init(id: UUID(), sessionID: sessionID, executionID: executionID,
              input: .message(id: MessageID(), text: text, timeZoneIdentifier: "UTC"),
              options: .init(
                  instructions: "Answer naturally using relevant memories. Visible citations are optional.",
                  limits: .init(modelTimeoutMilliseconds: 300_000), route: route), opening: opening)
    }

    private static func waitForMemory(
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
                    let report = try? await group.memories.extractionReport(
                        job.id, sessionID: sourceSession, executionID: sourceExecution, workspaceID: nil)
                    let attemptError = report?.attempts.last.map { $0.state.rawValue }
                    return .init(memories: [], state: job.state.rawValue,
                                 errorCode: attemptError ?? job.state.rawValue)
                case .queued, .running:
                    break
                }
            }
            let status = await group.status()
            if let failure = status.failures["extraction"] {
                return .init(memories: [], state: "failed", errorCode: failure.code.rawValue)
            }
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

    private static func assistantAnswer(in group: MacLibraryWorkloads, sessionID: ConversationID) async throws -> String? {
        _ = try await group.queries.synchronize(sessionID: sessionID)
        let page = try await group.queries.messagePage(sessionID: sessionID, beforeSequence: nil, limit: 128)
        return page.messages.reversed().first(where: { $0.summary.role == .assistant })?.body.text
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
private struct MemoryObservationResult: Sendable { let memories: [MemoryObservation]; let state: String; let errorCode: String? }

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
    var value: Int { lock.withLock { count } }
    func reserve(limit: Int) -> Bool {
        lock.withLock {
            guard count < limit else { return false }
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

private struct LiveEvaluationConfiguration: Sendable {
    let corpusURL: URL; let reportURL: URL; let endpoint: String; let allowsLoopbackHTTP: Bool; let apiKey: String
    let protocolID: HTTPProtocolID; let dialectProfileID: HTTPDialectProfileID
    let conversationModelID: String; let caseIDs: [String]
    let requestAuthorizationCap: Int; let contextWindow: Int; let conversationOutputTokens: Int; let extractionOutputTokens: Int

    init(environment: [String: String]) throws {
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
        conversationModelID = try required("MIRA_EVAL_CONVERSATION_MODEL")
        protocolID = HTTPProtocolID(rawValue: try required("MIRA_EVAL_PROTOCOL"))
        dialectProfileID = .openAI
        allowsLoopbackHTTP = environment["MIRA_EVAL_ALLOW_LOOPBACK_HTTP"] == "1"
        _ = try HTTPModelConfiguration(baseURL: endpoint, allowsLoopbackHTTP: allowsLoopbackHTTP,
                                       protocolID: protocolID, dialectProfileID: dialectProfileID).validatedEndpoint()
        let ids = try required("MIRA_EVAL_CASE_IDS").split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (1...4).contains(ids.count), Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }) else { throw MiraError(.configuration, "MIRA_EVAL_CASE_IDS must contain one to four unique IDs.") }
        caseIDs = ids
        guard let cap = Int(environment["MIRA_EVAL_REQUEST_AUTHORIZATION_CAP"] ?? "4"), (1...12).contains(cap) else { throw MiraError(.configuration, "MIRA_EVAL_REQUEST_AUTHORIZATION_CAP must be between 1 and 12.") }
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
        extractionOutputTokens = try number("MIRA_EVAL_EXTRACTION_OUTPUT", default: 4_096)
        guard (1...10_000_000).contains(contextWindow),
              conversationOutputTokens > 0, conversationOutputTokens < contextWindow,
              extractionOutputTokens > 0, extractionOutputTokens < contextWindow else {
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
private struct MemoryObservation: Codable, Sendable { let state: String; let content: String; let evidenceIDs: [String] }
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
    let conversationModelID: String
    let conversationProtocol: String
    let extractionProtocol: String
    var cases: [EverydayMemoryCaseReport]
    var aggregate: LiveEvaluationAggregate
    /// Credential-read admission count, not an exact HTTP transport dispatch count.
    let requestAuthorizationCap: Int
    var requestAuthorizationCount: Int
}
