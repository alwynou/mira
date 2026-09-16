import Foundation

/// Resolves business eligibility from the journal authority. Query projections are never consulted.
public struct JournalAgentEffectResolver: AgentEffectIntentResolver {
    private let payloads: any SessionPayloadReader
    private let reader: JournalSessionReader

    public init(journal: any SessionJournal, payloads: any SessionPayloadReader, extensionSchemas: [String: Set<Int>] = [:]) {
        self.payloads = payloads
        self.reader = .init(journal: journal, payloads: payloads, extensionSchemas: extensionSchemas)
    }

    public func resolve(_ proof: AgentEffectProof, requireEligible: Bool) async throws -> AgentResolvedEffect {
        try Task.checkCancellation()
        let snapshot = try await reader.snapshot(sessionID: proof.sessionID)
        let state = snapshot.state
        guard proof.intentSequence > 0, proof.proposal.kind == .effectIntent,
              proof.proposal.sessionID == proof.sessionID, proof.proposal.batchID == proof.intentBatchID,
              let invocation = state.invocations[proof.invocationID], let intent = invocation.intent,
              intent.sequence == proof.intentSequence, intent.batchID == proof.intentBatchID,
              intent.intent.invocationID == proof.invocationID, intent.intent.proposal == proof.proposal,
              intent.intent.authorization == proof.authorization,
              let attempt = state.attempts[invocation.invocation.attemptID],
              attempt.attempt.executionID == proof.executionID,
              let execution = state.executions[proof.executionID] else { throw Self.invalidIntent }
        if requireEligible {
            guard state.activeExecutionID == proof.executionID, execution.completion == nil,
                  !state.excludedExecutionIDs.contains(proof.executionID), invocation.dispatchedAt != nil,
                  invocation.resolution == nil, [.waitingForTools, .waitingForUser].contains(execution.phase),
                  attempt.resolution?.status == .completed else { throw Self.ineligible }
        }
        let proposal = try SessionCodec.decode(AgentToolProposal.self, from: await payloads.read(proof.proposal))
        try proposal.validate()
        guard proposal.descriptor.definition.name == invocation.invocation.toolName,
              proposal.effect == invocation.invocation.effect, proposal.callDigest == invocation.invocation.call.digest else {
            throw Self.invalidIntent
        }
        let build = try SessionCodec.decode(AgentRequestRecord.self, from: await payloads.read(attempt.attempt.request))
        let plan = try await AgentExecutionPlan.read(for: execution.admission, from: payloads)
        guard let route = plan.route else { throw Self.invalidIntent }
        try build.validate(for: route)
        guard build.request.destination == .model(route),
              build.request.executionID == proof.executionID, build.request.sessionID == proof.sessionID,
              build.request.workspaceID == state.header?.workspaceID,
              build.input.executionID == proof.executionID,
              build.input.stepID == attempt.attempt.stepID,
              build.sources == proposal.inheritedSources,
              build.input.tools.contains(where: { $0 == proposal.descriptor.definition }) else {
            throw Self.invalidIntent
        }
        if requireEligible, build.request.authorizationEpoch != state.authorizationEpoch { throw Self.ineligible }
        let evidence = try await reader.userEvidence(in: snapshot, executionID: proof.executionID)
        guard evidence.text == build.request.userText,
              build.input.messages.last(where: { $0.role == .user })?.text == evidence.text,
              build.input.instructions == plan.instructions else { throw Self.invalidIntent }
        try Task.checkCancellation()
        return .init(proposal: proposal, context: .init(executionID: proof.executionID,
            invocationID: proof.invocationID, evidence: evidence, route: route))
    }

    public func validatePublication(_ receipt: AgentBusinessReceiptReference, at cursor: SessionCursor) async throws {
        try receipt.validate()
        let state = try await reader.snapshot(through: cursor).state
        guard state.sequence == cursor.sequence,
              state.invocations[receipt.invocationID]?.resolution?.businessReceipt == receipt else {
            throw MiraError(.conflict, "The receipt publication does not match the durable session prefix.")
        }
    }

    private static var invalidIntent: MiraError { .init(.conflict, "The business effect proof does not match its durable intent.") }
    private static var ineligible: MiraError { .init(.unauthorized, "The business effect is no longer eligible to commit.") }
}
