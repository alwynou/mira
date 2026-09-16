import Foundation

/// A payload may be absent, deliberately purged, or available and decoded.
/// Purged content is never read from the payload store.
public enum SessionAuditContent<Value: Sendable & Equatable>: Sendable, Equatable {
    case available(Value)
    case absent
    case purged
}

public struct SessionAuditInvocation: Sendable, Equatable, Identifiable {
    public var id: UUID { state.invocation.id }
    public let state: SessionInvocationState
    public let call: SessionAuditContent<CanonicalToolCall>
    public let proposal: SessionAuditContent<AgentToolProposal>
    public let result: SessionAuditContent<JSONValue>

    public init(state: SessionInvocationState,
                call: SessionAuditContent<CanonicalToolCall>,
                proposal: SessionAuditContent<AgentToolProposal>,
                result: SessionAuditContent<JSONValue>) {
        self.state = state; self.call = call
        self.proposal = proposal; self.result = result
    }
}

public struct SessionAuditAttempt: Sendable, Equatable, Identifiable {
    public var id: UUID { attempt.id }
    public let attempt: SessionAttempt
    public let sequence: Int64
    public let startedAt: Date
    public let resolution: SessionAttemptResolution?
    public let request: SessionAuditContent<AgentRequestRecord>
    public let output: SessionAuditContent<AgentModelOutput>
    public let failure: SessionAuditContent<AgentModelAttemptFailureRecord>
    public let invocations: [SessionAuditInvocation]

    public init(attempt: SessionAttempt, sequence: Int64, startedAt: Date,
                resolution: SessionAttemptResolution?, request: SessionAuditContent<AgentRequestRecord>,
                output: SessionAuditContent<AgentModelOutput>,
                failure: SessionAuditContent<AgentModelAttemptFailureRecord>,
                invocations: [SessionAuditInvocation]) {
        self.attempt = attempt; self.sequence = sequence; self.startedAt = startedAt
        self.resolution = resolution; self.request = request; self.output = output
        self.failure = failure; self.invocations = invocations
    }
}

/// Retained metadata for a recorded model attempt, without request or output bodies.
public struct SessionModelAttemptUsage: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let usage: TokenUsage
    public let isComplete: Bool

    public init(id: UUID, startedAt: Date, usage: TokenUsage, isComplete: Bool) {
        self.id = id; self.startedAt = startedAt
        self.usage = usage; self.isComplete = isComplete
    }
}

public struct SessionExecutionAuditPage: Sendable, Equatable {
    public let head: SessionJournalHead
    public let workspaceID: WorkspaceID?
    public let execution: SessionExecutionSummary
    public let plan: SessionAuditContent<AgentExecutionPlan>
    public let error: SessionAuditContent<MiraError>
    /// Attempts are newest first, ordered by their committed `attemptStarted` sequence.
    public let attempts: [SessionAuditAttempt]
    /// Every model attempt in this execution at `head`, independent of the audit page cursor.
    public let modelUsage: [SessionModelAttemptUsage]
    public let hasMore: Bool

    public init(head: SessionJournalHead, workspaceID: WorkspaceID?, execution: SessionExecutionSummary,
                plan: SessionAuditContent<AgentExecutionPlan>, error: SessionAuditContent<MiraError>,
                attempts: [SessionAuditAttempt], modelUsage: [SessionModelAttemptUsage], hasMore: Bool) {
        self.head = head; self.workspaceID = workspaceID; self.execution = execution
        self.plan = plan; self.error = error; self.attempts = attempts
        self.modelUsage = modelUsage; self.hasMore = hasMore
    }
}

/// Pure audit assembly from one fixed journal snapshot. The caller must invoke it
/// while holding the library lease; it never consults a projection or executes work.
struct SessionAuditReader: Sendable {
    static let maximumInvocations = 32

    /// A page may contain retries that intentionally share one frozen request.
    /// Keep the decoded request once so page assembly does not repeatedly read or
    /// decode the same retained payload.
    private final class PagePayloadCache {
        var requests: [UUID: AgentRequestRecord] = [:]
    }

    static func read(
        snapshot: SessionJournalSnapshot, sessionID: ConversationID, executionID: ExecutionID,
        beforeSequence: Int64?, limit: Int, maximumPageBytes: Int,
        payloads: any SessionPayloadReader
    ) async throws -> SessionExecutionAuditPage {
        try Task.checkCancellation()
        guard snapshot.state.id == sessionID, beforeSequence.map({ $0 > 0 }) ?? true,
              (1...32).contains(limit) else { throw invalidPage }
        guard let executionState = snapshot.state.executions[executionID] else { throw notFound }
        guard Set(executionState.attemptIDs).count == executionState.attemptIDs.count,
              executionState.attemptIDs.allSatisfy({ snapshot.state.attempts[$0]?.attempt.executionID == executionID }) else {
            throw invalidPage
        }

        let allAttempts = try executionState.attemptIDs.map { id -> SessionAttemptState in
            guard let value = snapshot.state.attempts[id], value.attempt.id == id,
                  value.sequence > 0, value.startedAt.timeIntervalSince1970.isFinite else { throw invalidPage }
            return value
        }.sorted { lhs, rhs in
            if lhs.sequence != rhs.sequence { return lhs.sequence > rhs.sequence }
            return lhs.attempt.id.uuidString > rhs.attempt.id.uuidString
        }
        let eligible = allAttempts.filter { value in beforeSequence.map { value.sequence < $0 } ?? true }
        let selected = Array(eligible.prefix(limit))
        let hasMore = eligible.count > selected.count

        // Reserve the complete selected page from metadata before touching any payload bytes.
        // A repeated reference is counted once; a revoked retention group is returned as
        // purged and contributes no physical bytes.
        var referenced: [(SessionPayloadReference, SessionPayloadKind)] = [(executionState.admission.plan, .executionPlan)]
        if let error = executionState.completion?.error { referenced.append((error, .error)) }
        for value in selected {
            referenced.append((value.attempt.request, .request))
            if let output = value.resolution?.output { referenced.append((output, .modelOutput)) }
            if let error = value.resolution?.error { referenced.append((error, .error)) }
            guard value.invocationIDs.count <= maximumInvocations,
                  Set(value.invocationIDs).count == value.invocationIDs.count else { throw invalidPage }
            for invocationID in value.invocationIDs {
                guard let invocation = snapshot.state.invocations[invocationID],
                      invocation.invocation.attemptID == value.attempt.id else { throw invalidPage }
                referenced.append((invocation.invocation.call, .toolCall))
                if let proposal = invocation.intent?.intent.proposal { referenced.append((proposal, .effectIntent)) }
                if let result = invocation.resolution?.result, invocation.resolution?.resultWasPurged != true {
                    referenced.append((result, .toolResult))
                }
            }
        }
        var reservedIDs = Set<UUID>()
        var reservedBytes = 0
        for (reference, expected) in referenced {
            try reference.validate()
            guard reference.kind == expected, snapshot.state.references[reference.id] == reference else { throw invalidPage }
            guard !snapshot.state.invalidatedRetentionGroups.contains(reference.retentionGroup) else { continue }
            guard reservedIDs.insert(reference.id).inserted else { continue }
            guard reference.byteCount <= maximumPageBytes - reservedBytes else { throw pageTooLarge }
            reservedBytes += reference.byteCount
        }

        let summary = SessionExecutionSummary(
            sessionID: sessionID, admission: executionState.admission,
            sequence: executionState.admissionSequence, admittedAt: executionState.admittedAt,
            phase: executionState.phase, completion: executionState.completion,
            isExcludedFromContext: snapshot.state.excludedExecutionIDs.contains(executionID))

        let plan = try await content(
            executionState.admission.plan, expected: .executionPlan, state: snapshot.state,
            payloads: payloads, maximumPageBytes: maximumPageBytes
        ) { try SessionCodec.decode(AgentExecutionPlan.self, from: $0) }
        if case .available(let value) = plan {
            try value.validate()
            guard executionState.admission.hasModelRoute == (value.route != nil) else { throw invalidPage }
        }

        let error: SessionAuditContent<MiraError>
        if let reference = executionState.completion?.error {
            error = try await content(reference, expected: .error, state: snapshot.state,
                                      payloads: payloads, maximumPageBytes: maximumPageBytes) {
                try SessionCodec.decode(MiraError.self, from: $0)
            }
        } else {
            error = .absent
        }

        var audits: [SessionAuditAttempt] = []
        let cache = PagePayloadCache()
        for value in selected {
            try Task.checkCancellation()
            let audit = try await readAttempt(value, execution: executionState, state: snapshot.state,
                                              payloads: payloads, maximumPageBytes: maximumPageBytes,
                                              route: planRoute(plan), cache: cache)
            audits.append(audit)
        }
        try Task.checkCancellation()
        return .init(head: snapshot.head, workspaceID: snapshot.state.header?.workspaceID,
                     execution: summary, plan: plan, error: error, attempts: audits,
                     modelUsage: allAttempts.map {
                         .init(id: $0.attempt.id, startedAt: $0.startedAt,
                               usage: $0.resolution?.usage ?? .init(),
                               isComplete: $0.resolution?.status == .completed)
                     }, hasMore: hasMore)
    }

    private static func planRoute(_ plan: SessionAuditContent<AgentExecutionPlan>) -> AgentModelRoute? {
        if case .available(let value) = plan { return value.route }
        return nil
    }

    private static func readAttempt(
        _ value: SessionAttemptState, execution: SessionExecutionState, state: SessionState,
        payloads: any SessionPayloadReader, maximumPageBytes: Int, route: AgentModelRoute?,
        cache: PagePayloadCache
    ) async throws -> SessionAuditAttempt {
        let attempt = value.attempt
        guard attempt.executionID == execution.admission.executionID,
              value.invocationIDs.count <= maximumInvocations,
              Set(value.invocationIDs).count == value.invocationIDs.count else { throw invalidPage }

        let request: SessionAuditContent<AgentRequestRecord>
        if let cached = cache.requests[attempt.request.id] {
            request = .available(cached)
        } else {
            let decoded = try await content(attempt.request, expected: .request, state: state,
                                            payloads: payloads, maximumPageBytes: maximumPageBytes) {
                try SessionCodec.decode(AgentRequestRecord.self, from: $0)
            }
            if case .available(let record) = decoded { cache.requests[attempt.request.id] = record }
            request = decoded
        }
        let effectiveRoute: AgentModelRoute?
        if case .available(let record) = request {
            guard record.request.workspaceID == state.header?.workspaceID,
                  let requestRoute = record.request.destination.modelRoute else { throw invalidPage }
            if let route, route != requestRoute { throw invalidPage }
            effectiveRoute = requestRoute
            guard record.request.sessionID == state.id,
                  record.request.executionID == attempt.executionID,
                  record.request.authorizationEpoch == execution.admission.authorizationEpoch,
                  record.input.executionID == attempt.executionID,
                  record.input.stepID == attempt.stepID,
                  record.adapter == requestRoute.adapter else { throw invalidPage }
            do { try record.validate(for: requestRoute) } catch { throw invalidPage }
            for source in record.sources { try source.validate() }
        } else {
            effectiveRoute = route
        }

        let output: SessionAuditContent<AgentModelOutput>
        if let reference = value.resolution?.output {
            output = try await content(reference, expected: .modelOutput, state: state,
                                       payloads: payloads, maximumPageBytes: maximumPageBytes) {
                let value = try SessionCodec.decode(AgentModelOutput.self, from: $0)
                guard let effectiveRoute else { throw invalidPage }
                var accumulator = try AgentModelAccumulator(route: effectiveRoute, maximumToolCalls: maximumInvocations)
                for block in value.blocks {
                    try accumulator.consume(.blockStarted(block))
                    try accumulator.consume(.blockFinished(id: block.id))
                }
                if let continuation = value.continuation {
                    try accumulator.consume(.continuation(continuation))
                }
                try accumulator.consume(.usage(value.usage))
                try accumulator.consume(.finished(value.finishReason))
                guard try accumulator.finish() == value else { throw invalidPage }
                return value
            }
        } else { output = .absent }

        let failure: SessionAuditContent<AgentModelAttemptFailureRecord>
        if let reference = value.resolution?.error {
            failure = try await content(reference, expected: .error, state: state,
                                        payloads: payloads, maximumPageBytes: maximumPageBytes) {
                let value = try SessionCodec.decode(AgentModelAttemptFailureRecord.self, from: $0)
                try value.failure.validate()
                return value
            }
        } else { failure = .absent }

        var invocations: [SessionAuditInvocation] = []
        for (order, invocationID) in value.invocationIDs.enumerated() {
            try Task.checkCancellation()
            guard let invocationState = state.invocations[invocationID],
                  invocationState.invocation.id == invocationID,
                  invocationState.invocation.attemptID == attempt.id,
                  invocationState.invocation.modelOrder == order else { throw invalidPage }
            let invocation = invocationState.invocation
            let call = try await content(invocation.call, expected: .toolCall, state: state,
                                         payloads: payloads, maximumPageBytes: maximumPageBytes) {
                let call = try SessionCodec.decode(CanonicalToolCall.self, from: $0)
                guard call.name == invocation.toolName, !call.id.isEmpty,
                      call.arguments.utf8.count <= 65_536 else { throw invalidPage }
                return call
            }
            if case .available(let decodedCall) = call,
               case .available(let modelOutput) = output {
                guard order < modelOutput.toolCalls.count, modelOutput.toolCalls[order] == decodedCall else { throw invalidPage }
            }
            let proposal: SessionAuditContent<AgentToolProposal>
            if let reference = invocationState.intent?.intent.proposal {
                proposal = try await content(reference, expected: .effectIntent, state: state,
                                             payloads: payloads, maximumPageBytes: maximumPageBytes) {
                    let proposal = try SessionCodec.decode(AgentToolProposal.self, from: $0)
                    try proposal.validate()
                    guard proposal.effect == invocation.effect, proposal.descriptor.definition.name == invocation.toolName,
                          proposal.callDigest == invocation.call.digest else { throw invalidPage }
                    return proposal
                }
            } else { proposal = .absent }
            let result: SessionAuditContent<JSONValue>
            if let resolution = invocationState.resolution, resolution.resultWasPurged {
                result = .purged
            } else if let reference = invocationState.resolution?.result {
                result = try await content(reference, expected: .toolResult, state: state,
                                           payloads: payloads, maximumPageBytes: maximumPageBytes) {
                    try SessionCodec.decode(JSONValue.self, from: $0)
                }
            } else { result = .absent }
            invocations.append(.init(state: invocationState, call: call,
                                     proposal: proposal, result: result))
        }
        if case .available(let modelOutput) = output {
            guard modelOutput.toolCalls.count == invocations.count else { throw invalidPage }
        }
        return .init(attempt: attempt, sequence: value.sequence, startedAt: value.startedAt,
                     resolution: value.resolution, request: request, output: output,
                     failure: failure, invocations: invocations)
    }

    private static func content<Value: Sendable & Equatable>(
        _ reference: SessionPayloadReference, expected: SessionPayloadKind, state: SessionState,
        payloads: any SessionPayloadReader, maximumPageBytes: Int,
        decode: (Data) throws -> Value
    ) async throws -> SessionAuditContent<Value> {
        try reference.validate()
        guard reference.kind == expected, state.references[reference.id] == reference else { throw invalidPage }
        if state.invalidatedRetentionGroups.contains(reference.retentionGroup) { return .purged }
        guard reference.byteCount <= maximumPageBytes else { throw pageTooLarge }
        try Task.checkCancellation()
        let bytes = try await payloads.read(reference)
        try Task.checkCancellation()
        guard bytes.count == reference.byteCount, bytes.count <= maximumPageBytes else { throw invalidPage }
        do {
            return .available(try decode(bytes))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MiraError {
            throw error
        } catch {
            throw MiraError(.storage, "The session audit payload is corrupt.")
        }
    }

    private static var notFound: MiraError { .init(.notFound, "The execution is unavailable.") }
    private static var invalidPage: MiraError { .init(.storage, "The session audit is inconsistent.") }
    private static var pageTooLarge: MiraError { .init(.outputLimit, "The session audit exceeds its content limit.") }
}
