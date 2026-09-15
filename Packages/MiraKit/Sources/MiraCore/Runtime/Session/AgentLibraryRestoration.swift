import Foundation

/// Reconciles every archived session locally after a library restore.
///
/// Restoration owns no model, tool, catalog, scheduler, or platform capability. It
/// only consumes the journal/payload stores and the business receipt boundary. The
/// caller must keep the restored library quiescent for the lifetime of this actor.
public actor AgentLibraryRestoration {
    private static let maximumSessions = 4_096
    private static let sessionPageSize = 128
    private static let maximumReceipts = 100_000
    private static let receiptPageSize = 1_000

    private let journal: any SessionJournal
    private let payloads: any SessionPayloadStore
    private let receipts: any AgentBusinessReceipts
    private let authorizer: any AgentSourceAuthorizer
    private let environment: RuntimeEnvironment
    private let extensionSchemas: [String: Set<Int>]
    private var operation: Task<[SessionJournalHead], any Error>?
    private var closed = false

    public init(
        journal: any SessionJournal,
        payloads: any SessionPayloadStore,
        receipts: any AgentBusinessReceipts,
        authorizer: any AgentSourceAuthorizer,
        environment: RuntimeEnvironment = .init(),
        extensionSchemas: [String: Set<Int>] = [:]
    ) {
        self.journal = journal
        self.payloads = payloads
        self.receipts = receipts
        self.authorizer = authorizer
        self.environment = environment
        self.extensionSchemas = extensionSchemas
    }

    /// Concurrent callers share the same accepted operation. Caller cancellation
    /// never cancels the operation already owned by this actor.
    public func restore() async throws -> [SessionJournalHead] {
        try Task.checkCancellation()
        guard !closed else { throw Self.closedError }
        if let operation { return try await operation.value }

        let journal = self.journal
        let payloads = self.payloads
        let receipts = self.receipts
        let authorizer = self.authorizer
        let environment = self.environment
        let extensionSchemas = self.extensionSchemas
        let task = Task.detached {
            try await Self.performRestore(
                journal: journal, payloads: payloads, receipts: receipts,
                authorizer: authorizer, environment: environment, extensionSchemas: extensionSchemas)
        }
        operation = task
        do {
            let result = try await task.value
            operation = nil
            return result
        } catch {
            operation = nil
            throw error
        }
    }

    /// Stops new restore calls and drains an accepted operation without cancelling it.
    public func close() async {
        closed = true
        if let operation { _ = await operation.result }
    }

    private static func performRestore(
        journal: any SessionJournal,
        payloads: any SessionPayloadStore,
        receipts: any AgentBusinessReceipts,
        authorizer: any AgentSourceAuthorizer,
        environment: RuntimeEnvironment,
        extensionSchemas: [String: Set<Int>]
    ) async throws -> [SessionJournalHead] {
        var sessionIDs: [ConversationID] = []
        var seen: Set<ConversationID> = []
        var cursor: ConversationID?
        while true {
            let page = try await journal.sessions(after: cursor, limit: sessionPageSize)
            guard page.count <= sessionPageSize else { throw Self.invalidJournal }
            if page.isEmpty { break }
            for id in page {
                guard seen.insert(id).inserted,
                    sessionIDs.last.map({ $0.rawValue.uuidString < id.rawValue.uuidString }) ?? true
                else { throw Self.invalidJournal }
                sessionIDs.append(id)
                guard sessionIDs.count <= maximumSessions else { throw Self.limitError }
            }
            guard cursor != page.last else { throw Self.invalidJournal }
            cursor = page.last
        }

        // Keep only bounded identity metadata after each runtime is closed. A
        // restored library may contain many sessions and receipt result bodies
        // must never accumulate in this coordinator.
        for sessionID in sessionIDs {
            let runtime = try await SessionRuntime.open(
                id: sessionID, journal: journal, payloads: payloads,
                environment: environment, extensionSchemas: extensionSchemas)
            do {
                guard await runtime.snapshot().header != nil else { throw Self.invalidJournal }
                if let executionID = await runtime.snapshot().activeExecutionID {
                    let recovery = AgentExecutionRecovery(
                        runtime: runtime, journal: journal, payloads: payloads,
                        executionID: executionID, business: receipts,
                        authorizer: LocalRestorationAuthorizer(authorizer), environment: environment)
                    try requireCommitted(await recovery.settle())
                    guard await runtime.snapshot().activeExecutionID == nil else {
                        throw MiraError(.storage, "The restored session still owns an active execution.")
                    }
                }
                await runtime.close()
            } catch {
                await runtime.close()
                throw error
            }
        }

        var receiptCursor: UUID?
        var seenReceiptIDs: Set<UUID> = []
        var receiptCount = 0
        while true {
            try Task.checkCancellation()
            let page = try await receipts.unpublished(after: receiptCursor, limit: receiptPageSize)
            guard page.count <= receiptPageSize else { throw Self.invalidReceipt }
            if page.isEmpty { break }

            var grouped: [ConversationID: [AgentReceiptPublication]] = [:]
            for publication in page {
                let id = publication.receipt.reference.id
                guard seenReceiptIDs.insert(id).inserted else { throw Self.invalidReceipt }
                receiptCount += 1
                guard receiptCount <= maximumReceipts else { throw Self.limitError }
                let sessionID = publication.proof.sessionID
                guard seen.contains(sessionID) else { throw Self.invalidReceipt }
                grouped[sessionID, default: []].append(publication)
            }
            for sessionID in grouped.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
                let runtime = try await SessionRuntime.open(
                    id: sessionID, journal: journal, payloads: payloads,
                    environment: environment, extensionSchemas: extensionSchemas)
                do {
                    let state = await runtime.snapshot()
                    guard state.activeExecutionID == nil else { throw Self.invalidJournal }
                    for publication in grouped[sessionID]! {
                        try validate(publication, in: state)
                        try await receipts.acknowledge(
                            publication.receipt.reference,
                            at: .init(sessionID: state.id, sequence: state.sequence))
                    }
                    await runtime.close()
                } catch {
                    await runtime.close()
                    throw error
                }
            }
            guard receiptCursor != page.last?.receipt.reference.id else { throw Self.invalidReceipt }
            receiptCursor = page.last?.receipt.reference.id
        }
        let remaining = try await receipts.unpublished(after: nil, limit: 1)
        guard remaining.isEmpty else {
            throw MiraError(.storage, "The restored business receipt outbox is not empty.")
        }

        var heads: [SessionJournalHead] = []
        heads.reserveCapacity(sessionIDs.count)
        for sessionID in sessionIDs {
            heads.append(try await journal.head(sessionID: sessionID))
        }
        return heads
    }

    private static func validate(_ publication: AgentReceiptPublication, in state: SessionState) throws {
        let proof = publication.proof
        let receipt = publication.receipt.reference
        try proof.proposal.validate()
        try receipt.validate()
        guard proof.sessionID == state.id,
            proof.intentSequence > 0,
            proof.proposal.sessionID == state.id,
            proof.proposal.kind == .effectIntent,
            receipt.invocationID == proof.invocationID,
            receipt.authorization == proof.authorization,
            receipt.intentDigest == proof.proposal.digest,
            let execution = state.executions[proof.executionID],
            let item = state.invocations[proof.invocationID],
            item.invocation.effect == .localWrite,
            item.invocation.id == proof.invocationID,
            item.dispatchedAt != nil,
            execution.attemptIDs.contains(item.invocation.attemptID),
            let intent = item.intent,
            intent.batchID == proof.intentBatchID,
            intent.sequence == proof.intentSequence,
            intent.intent.invocationID == proof.invocationID,
            intent.intent.authorization == proof.authorization,
            intent.intent.proposal == proof.proposal,
            proof.proposal.batchID == proof.intentBatchID,
            let resolution = item.resolution,
            resolution.businessReceipt == receipt,
            resolution.status == .succeeded,
            resolution.effectIsKnown,
            !resolution.resultWasPurged || publication.receipt.result == nil
        else {
            throw Self.invalidReceipt
        }
    }

    private static func requireCommitted(_ result: SessionCommitResult) throws {
        switch result {
        case .committed: return
        case .notCommitted(let error): throw error
        case .indeterminate(_, let error): throw error
        }
    }

    private static var closedError: MiraError {
        .init(.interrupted, "The library restoration service is closed.")
    }

    private static var invalidJournal: MiraError {
        .init(.storage, "The restored session journal inventory is invalid.")
    }

    private static var invalidReceipt: MiraError {
        .init(.storage, "The restored business receipt is not backed by the session journal.")
    }

    private static var limitError: MiraError {
        .init(.outputLimit, "The restored library exceeds the recovery limit.")
    }
}

private struct LocalRestorationAuthorizer: AgentSourceAuthorizer {
    let base: any AgentSourceAuthorizer

    init(_ base: any AgentSourceAuthorizer) { self.base = base }

    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {
        let localRequest = AgentContextRequest(
            sessionID: request.sessionID, executionID: request.executionID,
            workspaceID: request.workspaceID, userText: request.userText,
            authorizationEpoch: request.authorizationEpoch, destination: .local)
        try await base.validate(sources, for: localRequest)
    }
}
