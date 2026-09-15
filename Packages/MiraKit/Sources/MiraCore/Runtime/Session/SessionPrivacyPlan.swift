import Foundation

public enum SessionPrivacyRetention: String, Codable, Sendable {
    case preserveVisibleHistory
    case purgeGeneratedHistory
}

/// Content-free provenance survives deletion of the request and replay payloads.
public struct SessionPrivacyDependencies: Codable, Sendable, Equatable {
    public let executionID: ExecutionID
    public let sources: [AgentSourceReference]
    public init(executionID: ExecutionID, sources: [AgentSourceReference]) {
        self.executionID = executionID
        self.sources = sources
    }
    public func validate() throws {
        guard sources.count <= 8_192, Set(sources).count == sources.count else { throw SessionPrivacyPlan.invalid }
        for source in sources { try source.validate() }
    }
}

public struct SessionPrivacyChange: Codable, Sendable, Equatable {
    public let batch: SessionBatch
    public let dependencies: [SessionPrivacyDependencies]
    public init(batch: SessionBatch, dependencies: [SessionPrivacyDependencies]) {
        self.batch = batch
        self.dependencies = dependencies
    }
}

/// The complete immutable plan is durable before any journal invalidation or physical deletion.
/// Heads include unaffected sessions so an unexpected writer cannot escape the captured closure.
public struct SessionPrivacyPlan: Codable, Sendable, Equatable {
    public let operation: AgentLibraryMaintenanceOperation
    public let roots: [AgentSourceReference]
    public let retention: SessionPrivacyRetention
    public let reason: SessionInvalidationReason
    public let heads: [SessionJournalHead]
    public let changes: [SessionPrivacyChange]

    public init(
        operation: AgentLibraryMaintenanceOperation, roots: [AgentSourceReference],
        retention: SessionPrivacyRetention, reason: SessionInvalidationReason,
        heads: [SessionJournalHead], changes: [SessionPrivacyChange]
    ) {
        self.operation = operation
        self.roots = roots
        self.retention = retention
        self.reason = reason
        self.heads = heads
        self.changes = changes
    }

    public func validate() throws {
        try operation.validate()
        guard operation.completedAt == nil, !roots.isEmpty, roots.count <= 8_192,
            Set(roots).count == roots.count, heads.count <= 4_096,
            Set(heads.map { $0.cursor.sessionID }).count == heads.count,
            changes.count <= heads.count, Set(changes.map { $0.batch.sessionID }).count == changes.count
        else { throw Self.invalid }
        for root in roots { try root.validate() }
        for head in heads { try head.validate() }
        let inventory = Dictionary(uniqueKeysWithValues: heads.map { ($0.cursor.sessionID, $0) })
        for change in changes {
            try change.batch.validate()
            guard change.batch.events.count == 1,
                case .invalidated(let fact) = change.batch.events[0].fact,
                fact.operationID == operation.request.id, fact.reason == reason,
                change.batch.events[0].occurredAt == operation.request.requestedAt,
                change.batch.expectedSequence == inventory[change.batch.sessionID]?.cursor.sequence,
                !fact.executionIDs.isEmpty, change.dependencies.count == fact.executionIDs.count,
                Set(change.dependencies.map(\.executionID)) == fact.executionIDs
            else { throw Self.invalid }
            for item in change.dependencies { try item.validate() }
            guard try SessionCodec.encode(change).count <= SessionFormatLimits.maximumBatchBytes else {
                throw Self.invalid
            }
        }
        guard try SessionCodec.encode(self).count <= Self.maximumBytes else { throw Self.invalid }
    }
    public static let maximumBytes = 32 * 1_024 * 1_024
    static var invalid: MiraError { .init(.storage, "The session privacy plan is inconsistent or exceeds its limits.") }
}

/// A maintenance authority, not a rebuildable conversation projection. All operations require
/// the exact pending library operation. Save is atomic, immutable and idempotent; acknowledgement
/// loss is resolved by loading the original plan. Prior provenance must remain in backups.
public protocol SessionPrivacyPlanStore: Sendable {
    func load(operation: AgentLibraryMaintenanceOperation) async throws -> SessionPrivacyPlan?
    func save(_ plan: SessionPrivacyPlan) async throws
    func retainedDependencies(
        sessionID: ConversationID, invalidationIDs: Set<UUID>, operation: AgentLibraryMaintenanceOperation
    )
        async throws -> [SessionPrivacyDependencies]
}

/// Display-only provenance from completed maintenance. The journal must independently
/// confirm each original invalidation batch; these references cannot authorize replay.
public struct SessionPrivacyHistoryRecord: Sendable, Equatable {
    public let batch: SessionBatch
    public let request: AgentLibraryMaintenanceRequest
    public let dependencies: [SessionPrivacyDependencies]
    public init(batch: SessionBatch, request: AgentLibraryMaintenanceRequest, dependencies: [SessionPrivacyDependencies]) {
        self.batch = batch; self.request = request; self.dependencies = dependencies
    }
}

public protocol SessionPrivacyHistoryReader: Sendable {
    func retainedHistory(sessionID: ConversationID, operationIDs: Set<UUID>,
                         executionIDs: Set<ExecutionID>) async throws -> [SessionPrivacyHistoryRecord]
}

public protocol SessionPayloadMaintenance: SessionPayloadStore {
    /// After library-wide quiescence, discard staged/orphan bytes that no committed fact owns.
    func purgeUnpublished() async throws
    func verifyNoUnpublished() async throws
    /// Inspect actual storage under its writer ownership; a read denied by invalidation is not proof of deletion.
    func verifyPurged(sessionID: ConversationID, retentionGroups: Set<UUID>) async throws
}
