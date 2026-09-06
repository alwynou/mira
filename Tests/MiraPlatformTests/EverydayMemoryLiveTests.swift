import Foundation
import XCTest
import MiraCore
import MiraData
import MiraProviders

/// Opt-in, bounded live-provider evaluation for authored synthetic memory cases.
///
/// This test is intentionally disabled unless MIRA_RUN_LIVE_MEMORY_EVAL=1. The
/// source library is opened only to read its model configuration; every case
/// runs in a newly-created library and is removed after the case finishes.
final class EverydayMemoryLiveTests: XCTestCase {
    func testOptInEverydayMemoryEvaluation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MIRA_RUN_LIVE_MEMORY_EVAL"] == "1" else {
            throw XCTSkip("Opt-in live memory evaluation is disabled. Set MIRA_RUN_LIVE_MEMORY_EVAL=1 to run it.")
        }

        let configuration = try LiveEvaluationConfiguration(environment: environment)
        let corpus = try Self.loadCorpus(at: configuration.corpusURL)
        let scenarios = try corpus.selectedScenarios(ids: configuration.caseIDs)
        let sourceStore = try SQLiteMiraStore(directory: configuration.configurationDirectory)
        let routes = try Self.readConfiguredRoutes(from: sourceStore.modelConfiguration())
        let provider = BoundedHTTPProvider(upstream: HTTPModelProvider(credentials: KeychainCredentials()), limit: configuration.dispatchCap)
        let startedAt = Date()

        var report = LiveEvaluationReport(
            version: 1,
            status: "running",
            qualification: "none",
            createdAt: startedAt,
            corpusVersion: corpus.version,
            selectedCaseIDs: configuration.caseIDs,
            conversationModelID: routes.conversationModel.modelID,
            conversationProtocol: routes.conversationModel.protocolMode.rawValue,
            extractionModelID: routes.extractionModel.modelID,
            extractionProtocol: routes.extractionModel.protocolMode.rawValue,
            cases: [],
            aggregate: .init(),
            providerDispatchCap: configuration.dispatchCap,
            providerDispatchCount: 0
        )
        try Self.writeReport(report, to: configuration.reportURL)

        for scenario in scenarios {
            let result = await Self.evaluate(
                scenario: scenario,
                routes: routes,
                provider: provider
            )
            report.cases.append(result)
            report.aggregate = .from(report.cases)
            report.providerDispatchCount = provider.dispatchCount
            try Self.writeReport(report, to: configuration.reportURL)
        }

        report.status = report.cases.contains(where: {
            !$0.mismatchReasons.isEmpty
        })
            ? "completed_with_mismatches"
            : "completed"
        report.providerDispatchCount = provider.dispatchCount
        try Self.writeReport(report, to: configuration.reportURL)

        let mismatches = report.cases.filter {
            !$0.mismatchReasons.isEmpty
        }.map(\.id)
        if !mismatches.isEmpty {
            XCTFail("Everyday memory live evaluation mismatched expectations for case IDs: \(mismatches.joined(separator: ","))")
        }
    }

    private static func loadCorpus(at url: URL) throws -> EverydayMemoryCorpus {
        let data = try Data(contentsOf: url)
        let corpus = try JSONDecoder().decode(EverydayMemoryCorpus.self, from: data)
        guard corpus.version == 1, !corpus.scenarios.isEmpty else {
            throw MiraError(.invalidInput, "The everyday memory corpus must use version 1 and contain scenarios.")
        }
        guard Set(corpus.scenarios.map(\.id)).count == corpus.scenarios.count else {
            throw MiraError(.invalidInput, "The everyday memory corpus contains duplicate scenario IDs.")
        }
        guard corpus.scenarios.allSatisfy({ scenario in
            ["en", "zh-CN"].contains(scenario.language) &&
            ["active", "notActive"].contains(scenario.expectation) &&
            [scenario.id, scenario.language, scenario.category, scenario.statement, scenario.followUp, scenario.rationale]
                .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } &&
            scenario.requiredTerms.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } &&
            scenario.forbiddenTerms.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }) else {
            throw MiraError(.invalidInput, "The everyday memory corpus contains an invalid scenario.")
        }
        return corpus
    }

    private static func readConfiguredRoutes(from configuration: ModelConfiguration) throws -> EvaluationRoutes {
        guard let conversationBinding = configuration.bindings.first(where: { $0.scope == .global && $0.purpose == .conversation }),
              let extractionBinding = configuration.bindings.first(where: { $0.scope == .global && $0.purpose == .memoryExtraction }) else {
            throw MiraError(.configuration, "The configured library must have explicit global conversation and memory extraction bindings.")
        }
        guard let conversationRoute = configuration.routes.first(where: { $0.id == conversationBinding.routeID }),
              let extractionRoute = configuration.routes.first(where: { $0.id == extractionBinding.routeID }),
              let conversationModel = configuration.models.first(where: { $0.id == conversationRoute.modelDescriptorID }),
              let extractionModel = configuration.models.first(where: { $0.id == extractionRoute.modelDescriptorID }),
              let conversationConnection = configuration.connections.first(where: { $0.id == conversationModel.connectionID }),
              let extractionConnection = configuration.connections.first(where: { $0.id == extractionModel.connectionID }) else {
            throw MiraError(.configuration, "The configured model routes are incomplete.")
        }
        return EvaluationRoutes(
            conversationRoute: conversationRoute,
            conversationModel: conversationModel,
            conversationConnection: conversationConnection,
            extractionRoute: extractionRoute,
            extractionModel: extractionModel,
            extractionConnection: extractionConnection
        )
    }

    private static func evaluate(scenario: EverydayMemoryScenario, routes: EvaluationRoutes, provider: BoundedHTTPProvider) async -> EverydayMemoryCaseReport {
        let caseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mira-EverydayMemory-\(UUID().uuidString)", isDirectory: true)
        var store: SQLiteMiraStore?
        var app: MiraApplication?
        var approvalTask: Task<Void, Never>?
        var approvalDenialCounter: LockedCounter?
        var foregroundExecution: Execution?
        var extractionJob: MemoryExtractionJob?
        var followupExecution: Execution?
        var answer: String?
        var references = 0
        var verifiedCitations = 0
        var terminalErrorCode: String?
        var extractionErrorCode: String?
        defer {
            approvalTask?.cancel()
            app = nil
            store = nil
            try? FileManager.default.removeItem(at: caseDirectory)
        }

        do {
            let caseStore = try SQLiteMiraStore(directory: caseDirectory)
            store = caseStore
            try Self.install(routes: routes, in: caseStore)

            let approvals = MemoryApprovalCoordinator()
            let approvalDenials = LockedCounter()
            approvalDenialCounter = approvalDenials
            approvalTask = Task {
                let stream = await approvals.events()
                for await requests in stream {
                    for request in requests {
                        approvalDenials.increment()
                        await approvals.respond(request.id, approved: false)
                    }
                }
            }
            let tools = try ToolRegistry(
                MemoryTools.readOnly(store: caseStore) +
                [MemoryRememberTool(store: caseStore, approvals: approvals)]
            )
            let runtime = try MiraApplication(
                store: caseStore,
                provider: provider,
                tools: tools,
                limits: .init(turnTimeout: .seconds(120)),
                memoryApprovals: approvals
            )
            app = runtime
            let initialPolicy = try caseStore.memoryCapturePolicy()
            try await runtime.saveMemoryCapturePolicy(
                mode: .automaticWithUndo,
                dailyTokenLimit: max(initialPolicy.dailyTokenLimit, 100_000),
                expectedRevision: initialPolicy.revision
            )
            await runtime.startBackgroundWork()

            let conversationID = try await runtime.createConversation(workspaceID: nil)
            let firstID = try await runtime.send(conversationID: conversationID, text: scenario.statement, routeID: routes.conversationRoute.id)
            foregroundExecution = try await Self.waitForTerminal(firstID, in: caseStore)
            if foregroundExecution?.status != .completed {
                terminalErrorCode = foregroundExecution?.error?.code.rawValue ?? "execution_failed"
            } else {
                do {
                    extractionJob = try await Self.waitForExtraction(conversationID: conversationID, in: caseStore)
                    if let job = extractionJob, job.state != .completed {
                        extractionErrorCode = job.error?.code.rawValue ?? "extraction_\(job.state.rawValue)"
                    } else {
                        extractionErrorCode = extractionJob?.error?.code.rawValue
                    }
                } catch {
                    extractionErrorCode = MiraError.safe(error).code.rawValue
                }
            }

            let triggerID = foregroundExecution?.triggerMessageID
            let captured = try Self.captureMemories(from: caseStore, sourceMessageID: triggerID)

            let policyBeforeFollowup = try caseStore.memoryCapturePolicy()
            try await runtime.saveMemoryCapturePolicy(
                mode: .manualOnly,
                dailyTokenLimit: policyBeforeFollowup.dailyTokenLimit,
                expectedRevision: policyBeforeFollowup.revision
            )

            let followupConversationID = try await runtime.createConversation(workspaceID: nil)
            let followupID = try await runtime.send(conversationID: followupConversationID, text: scenario.followUp, routeID: routes.conversationRoute.id)
            followupExecution = try await Self.waitForTerminal(followupID, in: caseStore)
            if followupExecution?.status == .completed,
               let assistant = try caseStore.messages(in: followupConversationID).last(where: { $0.role == .assistant && $0.status == .committed }) {
                answer = assistant.text
                let parsed = MemoryCitationReference.references(in: assistant.text)
                references = parsed.count
                for reference in parsed {
                    if (try? caseStore.memoryCitation(reference, executionID: followupID, conversationID: followupConversationID)) != nil {
                        verifiedCitations += 1
                    }
                }
            } else if terminalErrorCode == nil {
                terminalErrorCode = followupExecution?.error?.code.rawValue ?? "followup_failed"
            }

            let prefetchedMemoryCount = (try caseStore.attempts(for: followupID).first?.request?.contextInfo?.references.filter { $0.kind == "memory" }.count) ?? 0

            let report = Self.makeReport(
                scenario: scenario,
                foregroundExecution: foregroundExecution,
                extractionJob: extractionJob,
                captured: captured,
                answer: answer,
                references: references,
                verifiedCitations: verifiedCitations,
                prefetchedMemoryCount: prefetchedMemoryCount,
                approvalDenialCount: approvalDenials.value,
                terminalErrorCode: terminalErrorCode,
                extractionErrorCode: extractionErrorCode
            )
            _ = await runtime.shutdown()
            approvalTask?.cancel()
            return report
        } catch {
            let safe = MiraError.safe(error)
            terminalErrorCode = terminalErrorCode ?? safe.code.rawValue
            let captured = (try? Self.captureMemories(from: store, sourceMessageID: foregroundExecution?.triggerMessageID)) ?? []
            if let runtime = app { _ = await runtime.shutdown() }
            approvalTask?.cancel()
            return Self.makeReport(
                scenario: scenario,
                foregroundExecution: foregroundExecution,
                extractionJob: extractionJob,
                captured: captured,
                answer: answer,
                references: references,
                verifiedCitations: verifiedCitations,
                prefetchedMemoryCount: 0,
                approvalDenialCount: approvalDenialCounter?.value ?? 0,
                terminalErrorCode: terminalErrorCode,
                extractionErrorCode: extractionErrorCode
            )
        }
    }

    private static func install(routes: EvaluationRoutes, in store: SQLiteMiraStore) throws {
        let connections = [routes.conversationConnection, routes.extractionConnection]
        var connectionIDs = Set<ConnectionID>()
        for connection in connections where connectionIDs.insert(connection.id).inserted {
            try store.saveConnection(.init(
                id: connection.id, revision: 1, name: connection.name, providerKind: connection.providerKind,
                baseURL: connection.baseURL, credentialReference: connection.credentialReference,
                credentialVersion: connection.credentialVersion, allowsLoopbackHTTP: connection.allowsLoopbackHTTP,
                isEnabled: connection.isEnabled
            ), expectedRevision: nil)
        }

        let models = [routes.conversationModel, routes.extractionModel]
        var modelIDs = Set<ModelDescriptorID>()
        for model in models where modelIDs.insert(model.id).inserted {
            try store.saveModel(.init(
                id: model.id, revision: 1, connectionID: model.connectionID, connectionRevision: 1,
                modelID: model.modelID, contextWindow: model.contextWindow, textCapability: model.textCapability,
                toolCapability: model.toolCapability, probeObservation: model.probeObservation, isEnabled: model.isEnabled,
                extractionCapability: model.extractionCapability, protocolMode: model.protocolMode,
                catalogMetadata: model.catalogMetadata
            ), expectedRevision: nil)
        }

        var conversationRoute = Self.normalizedRoute(routes.conversationRoute)
        if conversationRoute.maxOutputTokens > 1_024,
           routes.conversationRoute.id != routes.extractionRoute.id {
            var capped = conversationRoute
            capped.maxOutputTokens = 1_024
            let model = routes.conversationModel
            let connection = routes.conversationConnection
            let copiedModel = ModelDescriptor(
                id: model.id, revision: 1, connectionID: model.connectionID, connectionRevision: 1,
                modelID: model.modelID, contextWindow: model.contextWindow, textCapability: model.textCapability,
                toolCapability: model.toolCapability, probeObservation: model.probeObservation, isEnabled: model.isEnabled,
                extractionCapability: model.extractionCapability, protocolMode: model.protocolMode,
                catalogMetadata: model.catalogMetadata
            )
            let copiedConnection = ProviderConnection(
                id: connection.id, revision: 1, name: connection.name, providerKind: connection.providerKind,
                baseURL: connection.baseURL, credentialReference: connection.credentialReference,
                credentialVersion: connection.credentialVersion, allowsLoopbackHTTP: connection.allowsLoopbackHTTP,
                isEnabled: connection.isEnabled
            )
            if (try? ResolvedModelRouteSnapshot(route: capped, model: copiedModel, connection: copiedConnection, purpose: .conversation, selection: .explicit).validateForSending()) == nil {
                capped = conversationRoute
            }
            conversationRoute = capped
        }
        let extractionRoute = Self.normalizedRoute(routes.extractionRoute)
        try store.saveRoute(conversationRoute, expectedRevision: nil)
        if extractionRoute.id != conversationRoute.id {
            try store.saveRoute(extractionRoute, expectedRevision: nil)
        }
        try store.saveRouteBinding(.init(scope: .global, purpose: .conversation, routeID: conversationRoute.id), expectedRevision: nil)
        try store.saveRouteBinding(.init(scope: .global, purpose: .memoryExtraction, routeID: extractionRoute.id), expectedRevision: nil)
    }

    private static func normalizedRoute(_ route: ModelRoute) -> ModelRoute {
        .init(id: route.id, revision: 1, name: route.name, modelDescriptorID: route.modelDescriptorID,
              maxOutputTokens: route.maxOutputTokens, requestsUsage: route.requestsUsage, thinking: route.thinking)
    }

    private static func waitForTerminal(_ id: ExecutionID, in store: SQLiteMiraStore) async throws -> Execution {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if let execution = try store.execution(id), execution.status.isTerminal { return execution }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw MiraError(.timeout, "The bounded live evaluation wait expired.")
    }

    private static func waitForExtraction(conversationID: ConversationID, in store: SQLiteMiraStore) async throws -> MemoryExtractionJob {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if let job = try store.memoryExtractionJobs(conversationID: conversationID, limit: 1).first {
                switch job.state {
                case .completed, .failed, .cancelled, .suppressed, .paused: return job
                case .queued, .running: break
                }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw MiraError(.timeout, "The bounded live memory extraction wait expired.")
    }

    private static func captureMemories(from store: SQLiteMiraStore?, sourceMessageID: MessageID?) throws -> [MemoryObservation] {
        guard let store, let sourceMessageID else { return [] }
        let result = try store.memoryList(workspaceID: nil, states: [.active, .candidate], query: "", limit: 32)
        return try result.memories.compactMap { memory in
            guard let draft = memory.draft, memory.state == .active || memory.state == .candidate else { return nil }
            let detail = try store.memoryDetail(memory.id, workspaceID: nil)
            let evidence = detail.evidence.filter { $0.sourceID == sourceMessageID.rawValue }.map { $0.id.uuidString.lowercased() }
            guard !evidence.isEmpty else { return nil }
            return MemoryObservation(state: memory.state.rawValue, content: draft.content, evidenceIDs: evidence)
        }
    }

    private static func makeReport(
        scenario: EverydayMemoryScenario,
        foregroundExecution: Execution?,
        extractionJob: MemoryExtractionJob?,
        captured: [MemoryObservation],
        answer: String?,
        references: Int,
        verifiedCitations: Int,
        prefetchedMemoryCount: Int,
        approvalDenialCount: Int,
        terminalErrorCode: String?,
        extractionErrorCode: String?
    ) -> EverydayMemoryCaseReport {
        let actualActive = foregroundExecution?.status == .completed ? captured.filter { $0.state == MemoryState.active.rawValue } : []
        let actualCandidates = foregroundExecution?.status == .completed ? captured.filter { $0.state == MemoryState.candidate.rawValue } : []
        let activeCount = actualActive.count
        let candidateCount = actualCandidates.count
        let observedAnswer = answer ?? ""
        let required = scenario.requiredTerms.map { term in KeywordObservation(term: term, observed: observedAnswer.localizedCaseInsensitiveContains(term)) }
        let forbidden = scenario.forbiddenTerms.map { term in KeywordObservation(term: term, observed: observedAnswer.localizedCaseInsensitiveContains(term)) }
        let expectationMet = scenario.expectation == "active" ? activeCount > 0 : activeCount == 0
        let keywordPass = required.allSatisfy(\.observed) && forbidden.allSatisfy { !$0.observed }
        var mismatches: [String] = []
        if !expectationMet { mismatches.append("memory_expectation_mismatch") }
        if references != verifiedCitations { mismatches.append("invalid_answer_citations") }
        if scenario.expectation == "active", activeCount > 0, prefetchedMemoryCount == 0 { mismatches.append("recall_miss") }
        if terminalErrorCode != nil { mismatches.append("foreground_or_followup_error") }
        if extractionErrorCode != nil { mismatches.append("extraction_error") }
        return EverydayMemoryCaseReport(
            id: scenario.id,
            expected: scenario.expectation,
            actual: activeCount > 0 ? "active" : (candidateCount > 0 ? "candidate" : "none"),
            activeCount: activeCount,
            candidateCount: candidateCount,
            active: activeCount > 0 ? actualActive : [],
            candidates: actualCandidates,
            extractionState: extractionJob?.state.rawValue,
            extractionErrorCode: extractionErrorCode,
            activeCapturePassed: expectationMet,
            prefetchedMemoryCount: prefetchedMemoryCount,
            referencedMemoryCount: references,
            verifiedCitationCount: verifiedCitations,
            approvalDenialCount: approvalDenialCount,
            answer: answer,
            requiredTerms: required,
            forbiddenTerms: forbidden,
            keywordHeuristicsPass: keywordPass,
            expectationMet: expectationMet,
            errorCode: terminalErrorCode,
            mismatchReasons: mismatches
        )
    }

    private static func writeReport(_ report: LiveEvaluationReport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
    }
}

private struct LiveEvaluationConfiguration {
    let configurationDirectory: URL
    let corpusURL: URL
    let reportURL: URL
    let caseIDs: [String]
    let dispatchCap: Int

    init(environment: [String: String]) throws {
        func requiredAbsoluteURL(_ name: String) throws -> URL {
            guard let raw = environment[name], raw.hasPrefix("/"), !raw.contains("\0") else {
                throw MiraError(.configuration, "\(name) must be an absolute path.")
            }
            return URL(fileURLWithPath: raw, isDirectory: name == "MIRA_EVAL_CONFIGURATION_DIRECTORY")
        }
        configurationDirectory = try requiredAbsoluteURL("MIRA_EVAL_CONFIGURATION_DIRECTORY")
        corpusURL = try requiredAbsoluteURL("MIRA_EVAL_CORPUS")
        reportURL = try requiredAbsoluteURL("MIRA_EVAL_REPORT")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: configurationDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.fileExists(atPath: corpusURL.path) else {
            throw MiraError(.configuration, "The configured library and corpus paths must exist.")
        }
        let configurationPath = configurationDirectory.standardizedFileURL.path
        let reportPath = reportURL.standardizedFileURL.path
        let corpusPath = corpusURL.standardizedFileURL.path
        let databasePath = configurationDirectory.appendingPathComponent("Mira.sqlite").standardizedFileURL.path
        var reportParentIsDirectory: ObjCBool = false
        let reportParent = reportURL.deletingLastPathComponent()
        guard reportPath != corpusPath,
              reportPath != databasePath,
              !reportPath.hasPrefix(configurationPath + "/"),
              !FileManager.default.fileExists(atPath: reportPath),
              FileManager.default.fileExists(atPath: reportParent.path, isDirectory: &reportParentIsDirectory),
              reportParentIsDirectory.boolValue else {
            throw MiraError(.configuration, "MIRA_EVAL_REPORT must be a new path outside the configured library and corpus.")
        }
        guard let rawIDs = environment["MIRA_EVAL_CASE_IDS"] else {
            throw MiraError(.configuration, "MIRA_EVAL_CASE_IDS is required and must contain one to four IDs.")
        }
        let ids = rawIDs.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !ids.isEmpty, ids.count <= 4, Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }) else {
            throw MiraError(.configuration, "MIRA_EVAL_CASE_IDS must contain one to four unique IDs.")
        }
        caseIDs = ids
        guard let cap = Int(environment["MIRA_EVAL_DISPATCH_CAP"] ?? "4"), (1...12).contains(cap) else {
            throw MiraError(.configuration, "MIRA_EVAL_DISPATCH_CAP must be between 1 and 12.")
        }
        dispatchCap = cap
    }
}

private struct EverydayMemoryCorpus: Codable {
    let version: Int
    let scenarios: [EverydayMemoryScenario]

    func selectedScenarios(ids: [String]) throws -> [EverydayMemoryScenario] {
        let byID = Dictionary(uniqueKeysWithValues: scenarios.map { ($0.id, $0) })
        let unknown = ids.filter { byID[$0] == nil }
        guard unknown.isEmpty else { throw MiraError(.invalidInput, "MIRA_EVAL_CASE_IDS contains unknown scenario IDs.") }
        return ids.compactMap { byID[$0] }
    }
}

private struct EverydayMemoryScenario: Codable {
    let id: String
    let language: String
    let category: String
    let statement: String
    let followUp: String
    let expectation: String
    let rationale: String
    let requiredTerms: [String]
    let forbiddenTerms: [String]
}

private struct EvaluationRoutes {
    let conversationRoute: ModelRoute
    let conversationModel: ModelDescriptor
    let conversationConnection: ProviderConnection
    let extractionRoute: ModelRoute
    let extractionModel: ModelDescriptor
    let extractionConnection: ProviderConnection
}

private final class BoundedHTTPProvider: ModelProviderPort, @unchecked Sendable {
    private let upstream: HTTPModelProvider
    private let limit: Int
    private let lock = NSLock()
    private var count = 0

    init(upstream: HTTPModelProvider, limit: Int) { self.upstream = upstream; self.limit = limit }

    var dispatchCount: Int { lock.withLock { count } }

    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        let accepted = lock.withLock { () -> Bool in
            guard count < limit else { return false }
            count += 1
            return true
        }
        guard accepted else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: MiraError(.outputLimit, "The live evaluation provider dispatch cap was reached."))
            }
        }
        return upstream.stream(request: request, route: route)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private struct MemoryObservation: Codable {
    let state: String
    let content: String
    let evidenceIDs: [String]
}

private struct KeywordObservation: Codable {
    let term: String
    let observed: Bool
    let basis: String = "keyword heuristic; not semantic correctness"
}

private struct EverydayMemoryCaseReport: Codable {
    let id: String
    let expected: String
    let actual: String
    let activeCount: Int
    let candidateCount: Int
    let active: [MemoryObservation]
    let candidates: [MemoryObservation]
    let extractionState: String?
    let extractionErrorCode: String?
    let activeCapturePassed: Bool
    let prefetchedMemoryCount: Int
    let referencedMemoryCount: Int
    let verifiedCitationCount: Int
    let approvalDenialCount: Int
    let answer: String?
    let requiredTerms: [KeywordObservation]
    let forbiddenTerms: [KeywordObservation]
    let keywordHeuristicsPass: Bool
    let expectationMet: Bool
    let errorCode: String?
    let mismatchReasons: [String]
}

private struct LiveEvaluationAggregate: Codable {
    var casesMeasured: Int = 0
    var casesWithErrors: Int = 0
    var activeMemoryCount: Int = 0
    var candidateMemoryCount: Int = 0
    var prefetchedMemoryCount: Int = 0
    var referencedMemoryCount: Int = 0
    var verifiedCitationCount: Int = 0
    var approvalDenialCount: Int = 0

    static func from(_ cases: [EverydayMemoryCaseReport]) -> Self {
        .init(
            casesMeasured: cases.count,
            casesWithErrors: cases.filter { $0.errorCode != nil || $0.extractionErrorCode != nil }.count,
            activeMemoryCount: cases.reduce(0) { $0 + $1.activeCount },
            candidateMemoryCount: cases.reduce(0) { $0 + $1.candidateCount },
            prefetchedMemoryCount: cases.reduce(0) { $0 + $1.prefetchedMemoryCount },
            referencedMemoryCount: cases.reduce(0) { $0 + $1.referencedMemoryCount },
            verifiedCitationCount: cases.reduce(0) { $0 + $1.verifiedCitationCount },
            approvalDenialCount: cases.reduce(0) { $0 + $1.approvalDenialCount }
        )
    }
}

private struct LiveEvaluationReport: Codable {
    let version: Int
    var status: String
    let qualification: String
    let createdAt: Date
    let corpusVersion: Int
    let selectedCaseIDs: [String]
    let conversationModelID: String
    let conversationProtocol: String
    let extractionModelID: String
    let extractionProtocol: String
    var cases: [EverydayMemoryCaseReport]
    var aggregate: LiveEvaluationAggregate
    let providerDispatchCap: Int
    var providerDispatchCount: Int
}
