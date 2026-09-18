import Foundation
import Testing
@testable import MiraCore

@Suite("Agent tool policy composition")
struct AgentToolPolicyCompositionTests {
    @Test func hostDenialCannotBeOverriddenAndSkipsModule() async throws {
        let module = RecordingPolicy(decision: .allow)
        let composition = AgentToolPolicyComposition(host: RecordingPolicy(decision: .deny), requirement: .constrained(module))

        let decision = try await composition.evaluate(proposal(), context: context())
        #expect(isDeny(decision))
        #expect(await module.evaluationCount == 0)
    }

    @Test func moduleDenialOverridesHostApproval() async throws {
        let module = RecordingPolicy(decision: .deny)
        let host = RecordingPolicy(decision: .requireApproval(prompt: "Host approval", expiresAt: Date(timeIntervalSince1970: 200)))
        let composition = AgentToolPolicyComposition(host: host, requirement: .constrained(module))

        let decision = try await composition.evaluate(proposal(), context: context())
        #expect(isDeny(decision))
        #expect(await module.evaluationCount == 1)
    }

    @Test func approvalsCombineInOrderWithEarliestDeadlineAndSingleApprovalPreservesText() async throws {
        let hostDeadline = Date(timeIntervalSince1970: 400)
        let moduleDeadline = Date(timeIntervalSince1970: 300)
        let module = RecordingPolicy(decision: .requireApproval(prompt: "Module approval", expiresAt: moduleDeadline))
        let composed = AgentToolPolicyComposition(
            host: RecordingPolicy(decision: .requireApproval(prompt: "Host approval", expiresAt: hostDeadline)),
            requirement: .constrained(module)
        )

        let combined = try await composed.evaluate(proposal(), context: context())
        guard case .requireApproval(let prompt, let deadline) = combined else {
            Issue.record("Expected combined approval")
            return
        }
        #expect(prompt == "Host approval\n\nModule approval")
        #expect(deadline == moduleDeadline)

        let hostOnly = AgentToolPolicyComposition(
            host: RecordingPolicy(decision: .requireApproval(prompt: "Keep this wording", expiresAt: hostDeadline)),
            requirement: .hostOnly
        )
        let single = try await hostOnly.evaluate(proposal(), context: context())
        guard case .requireApproval(let singlePrompt, let singleDeadline) = single else {
            Issue.record("Expected a single approval")
            return
        }
        #expect(singlePrompt == "Keep this wording")
        #expect(singleDeadline == hostDeadline)
    }

    @Test func invalidApprovalPromptDateAndCombinedSizeAreConfigurationErrors() async throws {
        let cases: [AgentToolPolicyComposition] = [
            .init(host: RecordingPolicy(decision: .requireApproval(prompt: "   ", expiresAt: Date(timeIntervalSince1970: 1))), requirement: .hostOnly),
            .init(host: RecordingPolicy(decision: .requireApproval(prompt: "valid", expiresAt: Date(timeIntervalSince1970: .infinity))), requirement: .hostOnly),
            .init(host: RecordingPolicy(decision: .requireApproval(prompt: String(repeating: "x", count: 4_097), expiresAt: Date(timeIntervalSince1970: 1))), requirement: .hostOnly),
            .init(host: RecordingPolicy(decision: .requireApproval(prompt: String(repeating: "h", count: 2_050), expiresAt: Date(timeIntervalSince1970: 1))),
                  requirement: .constrained(RecordingPolicy(decision: .requireApproval(prompt: String(repeating: "m", count: 2_050), expiresAt: Date(timeIntervalSince1970: 2))))),
        ]

        for composition in cases {
            do {
                _ = try await composition.evaluate(proposal(), context: context())
                Issue.record("Invalid approval was accepted")
            } catch let error as MiraError {
                #expect(error.code == .configuration)
            }
        }
    }

    @Test func validateRunsBothPoliciesAndHostFailureSkipsModule() async throws {
        let host = RecordingPolicy(decision: .allow)
        let module = RecordingPolicy(decision: .allow)
        let composition = AgentToolPolicyComposition(host: host, requirement: .constrained(module))
        try await composition.validate(proposal(), context: context())
        #expect(await host.validationCount == 1)
        #expect(await module.validationCount == 1)

        let failingHost = RecordingPolicy(decision: .allow, validationError: MiraError(.unauthorized, "host denied"))
        let skippedModule = RecordingPolicy(decision: .allow)
        let failingComposition = AgentToolPolicyComposition(host: failingHost, requirement: .constrained(skippedModule))
        do {
            try await failingComposition.validate(proposal(), context: context())
            Issue.record("Host validation failure was not propagated")
        } catch let error as MiraError {
            #expect(error.code == .unauthorized)
        }
        #expect(await skippedModule.validationCount == 0)
    }

    @Test func cancellationDuringModuleEvaluationCannotReturnLateAllow() async throws {
        let entered = AsyncGate()
        let module = RecordingPolicy(decision: .allow, gate: entered)
        let composition = AgentToolPolicyComposition(host: RecordingPolicy(decision: .allow), requirement: .constrained(module))
        let task = Task {
            try await composition.evaluate(proposal(), context: context())
        }
        await entered.waitUntilEntered()
        task.cancel()
        await entered.release()

        do {
            _ = try await task.value
            Issue.record("Cancelled composition returned a valid decision")
        } catch is CancellationError {
            // Expected after the post-policy cancellation check.
        } catch let error as MiraError {
            #expect(error.code == .cancelled)
        }
    }

    @Test func catalogCapturesConstrainedPolicyBeforeToolPolicyChanges() throws {
        let tool = MutablePolicyTool()
        let catalog = try AgentToolCatalog([.read(tool)])
        tool.setPolicy(.hostOnly)

        guard let entry = catalog.entry(named: "policy.capture") else {
            Issue.record("Catalog entry was missing")
            return
        }
        guard case .constrained = entry.policy else {
            Issue.record("Catalog did not capture the constrained policy")
            return
        }
    }

    private func proposal() -> AgentToolProposal {
        let descriptor = AgentToolDescriptor(
            definition: .init(name: "policy.test", description: "Policy composition test", inputSchema: objectSchema()),
            revision: 1,
            outputSchema: objectSchema(),
            executionMode: .ordered,
            timeoutMilliseconds: 1_000,
            maximumResultBytes: 1_024
        )
        return AgentToolProposal(descriptor: descriptor, effect: .read, businessNamespace: nil,
                                 callDigest: String(repeating: "a", count: 64),
                                 inheritedSources: [], plan: .init(input: .object([:]), sources: [], targets: []))
    }

    private func context() -> AgentToolContext {
        let sessionID = ConversationID()
        let executionID = ExecutionID()
        let evidenceReference = SessionEvidenceReference(sessionID: sessionID, originalExecutionID: executionID,
                                                         userMessageID: MessageID(), admissionEventID: UUID(),
                                                         admissionSequence: 2)
        let evidence = SessionUserEvidence(reference: evidenceReference, workspaceID: nil,
                                           admittedAt: Date(timeIntervalSince1970: 100), timeZoneIdentifier: "UTC",
                                           text: "User", observedHead: .init(cursor: .init(sessionID: sessionID, sequence: 2), batchID: UUID()),
                                           sessionAuthorizationEpoch: 0)
        let route = AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
                                    modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1,
                                    adapter: .init(id: "policy.adapter", revision: 1), invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", modelID: "policy-model",
                                    credential: nil, contextWindow: 4_096, maximumOutputTokens: 512,
                                    capabilities: .init(streamsText: true, callsTools: true, producesThinking: false),
                                    configuration: .object([:]))
        return AgentToolContext(executionID: executionID, invocationID: UUID(), evidence: evidence, route: route)
    }

    private func objectSchema() -> JSONValue {
        .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])
    }

    private func isDeny(_ decision: AgentToolPolicyDecision) -> Bool {
        if case .deny = decision { return true }
        return false
    }
}

private actor RecordingPolicy: AgentToolPolicy {
    let decision: AgentToolPolicyDecision
    let validationError: MiraError?
    let gate: AsyncGate?
    private var evaluations = 0
    private var validations = 0

    init(decision: AgentToolPolicyDecision, validationError: MiraError? = nil, gate: AsyncGate? = nil) {
        self.decision = decision; self.validationError = validationError; self.gate = gate
    }

    var evaluationCount: Int { evaluations }
    var validationCount: Int { validations }

    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision {
        evaluations += 1
        if let gate { await gate.wait() }
        // Deliberately returns its decision after cancellation; the composition owns the final check.
        return decision
    }

    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws {
        validations += 1
        if let validationError { throw validationError }
    }
}

private final class MutablePolicyTool: AgentReadTool, @unchecked Sendable {
    private let lock = NSLock()
    private var current: AgentToolPolicyRequirement = .constrained(RecordingPolicy(decision: .requireApproval(prompt: "module", expiresAt: Date(timeIntervalSince1970: 500))))

    var policy: AgentToolPolicyRequirement {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func setPolicy(_ value: AgentToolPolicyRequirement) {
        lock.lock(); current = value; lock.unlock()
    }

    var descriptor: AgentToolDescriptor {
        .init(definition: .init(name: "policy.capture", description: "Policy capture test", inputSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])),
              revision: 1, outputSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]), executionMode: .ordered,
              timeoutMilliseconds: 1_000, maximumResultBytes: 1_024)
    }

    func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan {
        .init(input: arguments, sources: [], targets: [])
    }

    func execute(_ plan: AgentToolPlan, context: AgentToolContext) async throws -> JSONValue { .object([:]) }
}

private actor AsyncGate {
    private var isOpen = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
