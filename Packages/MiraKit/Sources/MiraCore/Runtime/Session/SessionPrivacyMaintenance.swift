import Foundation

/// Called by a library maintenance handler after all work owners have drained. Domain handlers
/// expand their own source identities and own their business/body cleanup; this engine knows no domain.
public actor SessionPrivacyMaintenance {
    private let journal: any SessionJournal
    private let payloads: any SessionPayloadMaintenance
    private let plans: any SessionPrivacyPlanStore
    private let reader: JournalSessionReader
    private var running = false

    public init(
        journal: any SessionJournal, payloads: any SessionPayloadMaintenance,
        plans: any SessionPrivacyPlanStore, extensionSchemas: [String: Set<Int>] = [:]
    ) {
        self.journal = journal
        self.payloads = payloads
        self.plans = plans
        reader = .init(journal: journal, payloads: payloads, extensionSchemas: extensionSchemas)
    }

    public func prepare(
        operation: AgentLibraryMaintenanceOperation, roots: [AgentSourceReference],
        retention: SessionPrivacyRetention, reason: SessionInvalidationReason
    ) async throws -> SessionPrivacyPlan {
        try enter()
        defer { running = false }
        try operation.validate()
        let roots = roots.sorted(by: AgentSourceReference.ordered)
        guard operation.completedAt == nil, !roots.isEmpty, roots.count <= 8_192,
            Set(roots).count == roots.count
        else { throw SessionPrivacyPlan.invalid }
        for root in roots { try root.validate() }
        if let saved = try await plans.load(operation: operation) {
            try saved.validate()
            guard saved.operation == operation, saved.roots == roots,
                saved.retention == retention, saved.reason == reason
            else { throw SessionPrivacyPlan.invalid }
            return saved
        }
        let ids = try await inventory()
        var snapshots: [SessionJournalSnapshot] = []
        var dependencies: [AgentSourceReference: Set<AgentSourceReference>] = [:]
        var retryEdges: [(AgentSourceReference, AgentSourceReference)] = []
        var edgeCount = 0
        for id in ids {
            try Task.checkCancellation()
            let snapshot = try await reader.snapshot(sessionID: id)
            guard snapshot.state.activeExecutionID == nil else { throw Self.notQuiescent }
            snapshots.append(snapshot)
            let retained = try await plans.retainedDependencies(
                sessionID: id,
                invalidationIDs: snapshot.state.privacyOperationIDs, operation: operation)
            guard Set(retained.map(\.executionID)).count == retained.count,
                retained.allSatisfy({ snapshot.state.executions[$0.executionID] != nil })
            else { throw SessionPrivacyPlan.invalid }
            for record in retained { try record.validate() }
            let preserved = Dictionary(uniqueKeysWithValues: retained.map { ($0.executionID, $0.sources) })
            let families = Dictionary(grouping: snapshot.state.executions.values, by: { $0.admission.userMessageID })
            for family in families.values {
                guard let first = family.first else { continue }
                let anchor = AgentSourceReference.sessionExecution(
                    sessionID: id, executionID: first.admission.executionID)
                for sibling in family.dropFirst() {
                    let key = AgentSourceReference.sessionExecution(
                        sessionID: id, executionID: sibling.admission.executionID)
                    retryEdges.append((anchor, key))
                    retryEdges.append((key, anchor))
                }
            }
            for execution in snapshot.state.executions.values {
                let executionID = execution.admission.executionID
                let key = AgentSourceReference.sessionExecution(sessionID: id, executionID: executionID)
                var sources = Set(preserved[executionID, default: []])
                if snapshot.state.excludedExecutionIDs.contains(executionID), preserved[executionID] == nil {
                    // Purged request bytes cannot be used to reconstruct missing maintenance provenance.
                    throw SessionPrivacyPlan.invalid
                }
                for attemptID in execution.attemptIDs {
                    guard let attempt = snapshot.state.attempts[attemptID] else { throw SessionPrivacyPlan.invalid }
                    if available(attempt.attempt.request, in: snapshot.state) {
                        let build = try SessionCodec.decode(
                            AgentContextBuild.self, from: await payloads.read(attempt.attempt.request))
                        guard build.request.sessionID == id, build.request.executionID == executionID,
                            build.request.workspaceID == snapshot.state.header?.workspaceID,
                            build.prepared.input.executionID == executionID,
                            build.prepared.input.stepID == attempt.attempt.stepID
                        else { throw SessionPrivacyPlan.invalid }
                        sources.formUnion(build.sources)
                    }
                    for invocationID in attempt.invocationIDs {
                        guard let invocation = snapshot.state.invocations[invocationID] else {
                            throw SessionPrivacyPlan.invalid
                        }
                        if let proposal = invocation.intent?.intent.proposal, available(proposal, in: snapshot.state) {
                            let value = try SessionCodec.decode(
                                AgentToolProposal.self, from: await payloads.read(proposal))
                            try value.validate()
                            sources.formUnion(value.plan.sources + value.plan.targets)
                        }
                    }
                }
                if let replay = execution.completion?.replay, available(replay, in: snapshot.state) {
                    let value = try SessionCodec.decode(AgentReplayRecord.self, from: await payloads.read(replay))
                    sources.formUnion(value.sources)
                }
                let record = SessionPrivacyDependencies(executionID: executionID, sources: Array(sources))
                try record.validate()
                dependencies[key] = sources
                edgeCount += sources.count
                guard dependencies.count <= 65_536, edgeCount <= 524_288 else { throw SessionPrivacyPlan.invalid }
            }
        }
        // Reverse edges include retry siblings: invalidating one original statement excludes every retry.
        var dependents: [AgentSourceReference: Set<AgentSourceReference>] = [:]
        for (execution, sources) in dependencies {
            for source in sources { dependents[source, default: []].insert(execution) }
        }
        for (source, sibling) in retryEdges { dependents[source, default: []].insert(sibling) }
        for root in roots {
            if case .sessionExecution = root, dependencies[root] == nil { throw SessionPrivacyPlan.invalid }
        }
        var affected = Set(roots)
        var queue = roots
        var index = 0
        while index < queue.count {
            let source = queue[index]
            index += 1
            for dependent in dependents[source, default: []] where affected.insert(dependent).inserted {
                queue.append(dependent)
            }
        }
        var changes: [SessionPrivacyChange] = []
        for snapshot in snapshots {
            let state = snapshot.state
            let selected = Set(
                state.executionOrder.filter {
                    affected.contains(.sessionExecution(sessionID: state.id, executionID: $0))
                })
            guard !selected.isEmpty else { continue }
            guard state.authorizationEpoch < UInt64.max else { throw SessionPrivacyPlan.invalid }
            let fact = SessionInvalidation(
                operationID: operation.request.id, executionIDs: selected,
                retentionGroups: state.privacyGroups(for: selected, retention: retention),
                authorizationEpoch: state.authorizationEpoch + 1, reason: reason)
            let batch = SessionBatch(
                id: UUID(), sessionID: state.id, expectedSequence: state.sequence,
                events: [
                    .init(
                        sequence: state.sequence + 1, occurredAt: operation.request.requestedAt,
                        fact: .invalidated(fact))
                ])
            var validated = state
            try validated.apply(batch)
            let records = selected.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }.map {
                SessionPrivacyDependencies(
                    executionID: $0,
                    sources: dependencies[
                        .sessionExecution(sessionID: state.id, executionID: $0), default: []
                    ].sorted(by: AgentSourceReference.ordered))
            }
            changes.append(.init(batch: batch, dependencies: records))
        }
        let plan = SessionPrivacyPlan(
            operation: operation, roots: roots, retention: retention, reason: reason,
            heads: snapshots.map(\.head), changes: changes)
        try plan.validate()
        try await validateHeads(plan, requireCommitted: false)
        // An acknowledgement failure leaves this exact plan retrievable; no deletion has started.
        try await plans.save(plan)
        return plan
    }

    public func apply(operation: AgentLibraryMaintenanceOperation) async throws {
        try enter()
        defer { running = false }
        let plan = try await requiredPlan(operation)
        try await validateHeads(plan, requireCommitted: false)
        // Publish the entire closure before deleting its first payload. A restart uses the saved batches.
        for change in plan.changes {
            var state = try await reader.snapshot(
                through: plan.heads.first { $0.cursor.sessionID == change.batch.sessionID }!
            ).state
            try state.apply(change.batch)
            if let existing = try await journal.batch(id: change.batch.id, sessionID: change.batch.sessionID) {
                guard existing == change.batch else { throw SessionPrivacyPlan.invalid }
            } else {
                var result = await journal.append(change.batch)
                if case .indeterminate = result { result = await journal.reconcile(change.batch) }
                switch result {
                case .committed(let cursor):
                    guard cursor == change.batch.cursor else { throw SessionPrivacyPlan.invalid }
                case .notCommitted(let error), .indeterminate(let error): throw error
                }
            }
        }
        try await validateHeads(plan, requireCommitted: true)
        for change in plan.changes {
            guard case .invalidated(let fact) = change.batch.events[0].fact else { throw SessionPrivacyPlan.invalid }
            try await payloads.purge(sessionID: change.batch.sessionID, retentionGroups: fact.retentionGroups)
        }
        try await payloads.purgeUnpublished()
    }

    public func verify(operation: AgentLibraryMaintenanceOperation) async throws {
        try enter()
        defer { running = false }
        let plan = try await requiredPlan(operation)
        try await validateHeads(plan, requireCommitted: true)
        try await payloads.verifyNoUnpublished()
        for change in plan.changes {
            guard case .invalidated(let fact) = change.batch.events[0].fact else { throw SessionPrivacyPlan.invalid }
            let state = try await reader.snapshot(sessionID: change.batch.sessionID).state
            guard state.excludedExecutionIDs.isSuperset(of: fact.executionIDs),
                state.invalidatedRetentionGroups.isSuperset(of: fact.retentionGroups)
            else { throw SessionPrivacyPlan.invalid }
            try await payloads.verifyPurged(sessionID: state.id, retentionGroups: fact.retentionGroups)
        }
    }

    private func requiredPlan(_ operation: AgentLibraryMaintenanceOperation) async throws -> SessionPrivacyPlan {
        guard let plan = try await plans.load(operation: operation), plan.operation == operation else {
            throw SessionPrivacyPlan.invalid
        }
        try plan.validate()
        return plan
    }
    private func validateHeads(_ plan: SessionPrivacyPlan, requireCommitted: Bool) async throws {
        let ids = try await inventory()
        guard ids == plan.heads.map({ $0.cursor.sessionID }) else { throw Self.notQuiescent }
        let changed = Dictionary(uniqueKeysWithValues: plan.changes.map { ($0.batch.sessionID, $0.batch) })
        for head in plan.heads {
            let current = try await journal.head(sessionID: head.cursor.sessionID)
            if let batch = changed[head.cursor.sessionID] {
                let committed = SessionJournalHead(cursor: batch.cursor, batchID: batch.id)
                guard current == committed || (!requireCommitted && current == head) else { throw Self.notQuiescent }
                if current == committed {
                    guard try await journal.batch(id: batch.id, sessionID: batch.sessionID) == batch else {
                        throw SessionPrivacyPlan.invalid
                    }
                }
            } else if current != head {
                throw Self.notQuiescent
            }
        }
    }
    private func inventory() async throws -> [ConversationID] {
        var ids: [ConversationID] = []
        var after: ConversationID?
        while true {
            try Task.checkCancellation()
            let page = try await journal.sessions(after: after, limit: 128)
            guard page.count <= 128 else { throw SessionPrivacyPlan.invalid }
            if page.isEmpty { return ids }
            for id in page {
                guard after.map({ $0.rawValue.uuidString < id.rawValue.uuidString }) ?? true else {
                    throw SessionPrivacyPlan.invalid
                }
                ids.append(id)
                after = id
            }
            guard ids.count <= 4_096 else { throw SessionPrivacyPlan.invalid }
        }
    }
    private func available(_ reference: SessionPayloadReference, in state: SessionState) -> Bool {
        !state.invalidatedRetentionGroups.contains(reference.retentionGroup)
    }
    private func enter() throws {
        guard !running else { throw MiraError(.busy, "Session privacy maintenance is already running.") }
        running = true
    }
    private static var notQuiescent: MiraError {
        .init(.conflict, "The session library changed during privacy maintenance.")
    }
}
