import Foundation
import GRDB
import MiraCore

extension SQLiteMiraStore {
    public func memoryContextNotices(in conversationID: ConversationID, at: Date) throws -> [ExecutionID: [MemoryContextNotice]] {
        try safely { try pool.read { db in
            try memoryContextNotices(in: conversationID, at: at, db: db)
        }}
    }

    /// Walk history provenance as well as direct usage: a memory may be captured
    /// from an earlier message after its replies have already been sent.
    func memoryContextNotices(in conversationID: ConversationID, at: Date, db: Database) throws -> [ExecutionID: [MemoryContextNotice]] {
        let workspaceID = try workspaceIDForConversation(conversationID, in: db)
        let rows = try Row.fetchAll(db, sql: """
            WITH RECURSIVE usage_history(root_id, memory_id, revision, usage_kind) AS (
                SELECT usage.execution_id, usage.memory_id, usage.revision, usage.usage_kind
                FROM memory_usages usage JOIN executions ON executions.id = usage.execution_id
                WHERE executions.conversation_id = ?
                UNION
                SELECT dependency.execution_id, history.memory_id, history.revision, history.usage_kind
                FROM usage_history history
                JOIN execution_history_dependencies dependency ON dependency.source_execution_id = history.root_id
            )
            SELECT root_id, memory_id, revision, usage_kind FROM usage_history
            """, arguments: [conversationIDString(conversationID)])
        guard !rows.isEmpty else { return [:] }
        var memories: [MemoryID: Memory] = [:]
        var routes: [ExecutionID: ResolvedModelRouteSnapshot] = [:]
        var notices: [ExecutionID: Set<MemoryContextNotice>] = [:]
        for row in rows {
            let rootID = try executionID(row["root_id"] as String)
            let memoryID = try memoryID(row["memory_id"] as String)
            let value: Memory
            if let cached = memories[memoryID] {
                value = cached
            } else {
                guard let stored = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [memoryIDString(memoryID)]) else {
                    notices[rootID, default: []].insert(.init(memoryID: memoryID, reason: .unavailable))
                    continue
                }
                value = try memory(stored)
                memories[memoryID] = value
            }
            let route: ResolvedModelRouteSnapshot
            if let cached = routes[rootID] {
                route = cached
            } else {
                guard let encoded = try String.fetchOne(db, sql: "SELECT route_json FROM executions WHERE id = ?", arguments: [executionIDString(rootID)]) else {
                    throw MiraError(.storage, "The memory history execution is unavailable.")
                }
                route = try decodeMemory(encoded)
                routes[rootID] = route
            }
            let reason: MemoryContextNotice.Reason?
            let status = value.lifecycleStatus(at: at)
            if status != .active {
                reason = MemoryContextNotice.Reason(rawValue: status.rawValue) ?? .unavailable
            } else if value.revision != (row["revision"] as Int) {
                reason = .updated
            } else if !memoryScopeVisible(value.scope, in: workspaceID) {
                reason = .unavailable
            } else if (row["usage_kind"] as String) == MemoryUsageKind.recall.rawValue {
                reason = try value.canRecall(in: workspaceID, connectionID: route.connectionID, at: at)
                    && memorySourcePolicyAllows(value, connectionID: route.connectionID, in: db) ? nil : .unavailable
            } else {
                // A save receipt may describe a local-only memory. Its policy
                // does not retroactively authorize remote recall of that memory.
                reason = nil
            }
            if let reason { notices[rootID, default: []].insert(.init(memoryID: memoryID, reason: reason)) }
        }
        return notices.mapValues { $0.sorted { $0.id < $1.id } }
    }
}
