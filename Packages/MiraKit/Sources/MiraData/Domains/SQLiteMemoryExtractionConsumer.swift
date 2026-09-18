import Foundation
import GRDB
import MiraCore

/// Prepares journal evidence outside SQL, then enqueues jobs in the consumer's
/// checkpoint transaction. Model calls belong exclusively to the business worker.
public struct SQLiteMemoryExtractionConsumer: SQLiteSessionConsumerHandler {
    public static let identity = AgentSessionConsumerIdentity(id: "mira.memoryExtraction", revision: 1)
    private let journal: any SessionJournal
    private let reader: JournalSessionReader
    private let access: AgentLibraryAccess
    private let scope: RuntimeScope
    private let now: @Sendable () -> Date

    public init(
        journal: any SessionJournal, payloads: any SessionContentReader,
        access: AgentLibraryAccess, scope: RuntimeScope,
        extensionSchemas: [String: Set<Int>] = [:], now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.journal = journal
        reader = .init(journal: journal, payloads: payloads, extensionSchemas: extensionSchemas)
        self.access = access
        self.scope = scope
        self.now = now
    }

    public func prepare(_ delivery: AgentSessionConsumerDelivery) async throws -> any SQLiteSessionConsumerTransaction {
        try delivery.validate()
        guard delivery.consumer == Self.identity else { throw Self.invalid }
        let lease = try await access.acquire(in: scope)
        let resource: AgentLibraryResourceLease<Task<[Item], any Error>>
        do {
            resource = try await lease.start {
                let task = Task { try await self.items(delivery, lease: lease) }
                return .init(
                    value: task,
                    cleanup: {
                        task.cancel()
                        _ = await task.result
                    })
            }
        } catch {
            await lease.release()
            throw error
        }
        do {
            try lease.bindCancellation { resource.value.cancel() }
            let items = try await withTaskCancellationHandler(
                operation: { try await resource.value.value },
                onCancel: { resource.value.cancel() })
            await resource.release()
            try await lease.check()
            let at = now()
            guard at.timeIntervalSince1970.isFinite else { throw Self.invalid }
            return Transaction(items: items, lease: lease, at: at)
        } catch {
            await resource.release()
            await lease.release()
            throw error
        }
    }

    private func items(_ delivery: AgentSessionConsumerDelivery, lease: AgentLibraryAccessLease) async throws -> [Item]
    {
        try await lease.read {
            let batch = delivery.batch
            let actual = try await journal.read(sessionID: batch.sessionID, after: batch.expectedSequence, limit: 1)
            guard actual == [batch] else { throw Self.invalid }
            let snapshot = try await reader.snapshot(through: delivery.checkpoint.head)
            var result: [Item] = []
            for event in batch.events {
                try Task.checkCancellation()
                guard case .finished(let completion) = event.fact, completion.status == .completed,
                    completion.answer != nil, completion.assistantMessageID != nil
                else { continue }
                guard snapshot.state.executions[completion.executionID]?.completion == completion else {
                    throw Self.invalid
                }
                do {
                    let source = try await reader.userEvidence(
                        sessionID: batch.sessionID, executionID: completion.executionID)
                    try MemoryExtractionRequestBuilder.validate(source: source)
                    result.append(
                        .init(
                            origin: .init(
                                source: source.reference, completedExecutionID: completion.executionID,
                                completionEventID: event.id, completionHead: delivery.checkpoint.head), source: source, completedAt: event.occurredAt))
                } catch let error as MiraError where [.notFound, .unauthorized, .invalidInput].contains(error.code) {
                    // Excluded/purged evidence and bounded-out sources do not create jobs or obstruct later batches.
                    continue
                }
            }
            return result
        }
    }

    private struct Item: Sendable {
        let origin: MemoryExtractionOrigin
        let source: SessionUserEvidence
        let completedAt: Date
    }
    private struct Transaction: SQLiteSessionConsumerTransaction {
        let items: [Item]
        let lease: AgentLibraryAccessLease
        let at: Date
        func apply(in db: Database) throws {
            guard !lease.isRevoked,
                try SQLiteLibraryAuthority.availableAuthorization(in: db, libraryID: lease.authorization.libraryID)
                    == lease.authorization
            else {
                throw MiraError(.unauthorized, "The memory consumer library authorization is stale.")
            }
            _ = try SQLiteMemoryExtractionStore.enqueueBatch(
                turns: items.map { (origin: $0.origin, source: $0.source, completedAt: $0.completedAt) }, at: at, in: db)
        }
        func close() async { await lease.release() }
    }
    private static var invalid: MiraError {
        .init(.storage, "The memory consumer delivery does not match its journal evidence.")
    }
}
