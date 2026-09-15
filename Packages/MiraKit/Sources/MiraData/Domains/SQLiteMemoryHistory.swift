import Foundation
import GRDB
import MiraCore

extension SQLiteMemoryStore {
    public func memoryContextNotices(
        references: [MemoryCitationReference], workspaceID: WorkspaceID?, connectionID: ConnectionID?, at date: Date
    ) async throws -> [MemoryContextNotice] {
        guard references.count <= 8_192, Set(references).count == references.count,
            date.timeIntervalSince1970.isFinite,
            references.allSatisfy({ $0.revision > 0 })
        else {
            throw MiraError(.invalidInput, "The memory context notice request is invalid.")
        }
        return try await owner.read { db in
            if let workspaceID { _ = try SQLiteWorkspaceStore.read(workspaceID, in: db) }
            var notices: [MemoryContextNotice] = []
            for reference in references {
                do {
                    let memory = try Self.read(reference.memoryID, workspaceID: workspaceID, in: db)
                    let lifecycle = memory.lifecycleStatus(at: date)
                    if lifecycle != .active {
                        notices.append(.init(memoryID: memory.id, reason: Self.noticeReason(lifecycle)))
                        continue
                    }
                    let evidence = try Self.evidence(memory.id, in: db)
                    let connectionAllowed = Self.draftAllowed(memory.draft, connectionID: connectionID)
                    var sourceAvailable = true
                    do {
                        try SQLiteWorkspaceStore.validatePolicy(workspaceID, connectionID: connectionID, in: db)
                    } catch let error as MiraError where error.code == .notFound || error.code == .unauthorized {
                        sourceAvailable = false
                    }
                    for item in evidence {
                        guard item.bodyPurgedAt == nil else {
                            sourceAvailable = false
                            break
                        }
                        do {
                            try SQLiteWorkspaceStore.validatePolicy(
                                item.sourceWorkspaceID, connectionID: connectionID, in: db)
                        } catch let error as MiraError where error.code == .notFound || error.code == .unauthorized {
                            sourceAvailable = false
                            break
                        }
                    }
                    guard memory.draft != nil, connectionAllowed, sourceAvailable else {
                        notices.append(.init(memoryID: memory.id, reason: .unavailable))
                        continue
                    }
                    if memory.revision != reference.revision {
                        notices.append(.init(memoryID: memory.id, reason: .updated))
                    }
                } catch let error as MiraError where error.code == .notFound || error.code == .unauthorized {
                    notices.append(.init(memoryID: reference.memoryID, reason: .unavailable))
                }
            }
            return Array(Set(notices)).sorted { $0.id < $1.id }
        }
    }

    private static func noticeReason(_ status: MemoryLifecycleStatus) -> MemoryContextNotice.Reason {
        switch status {
        case .forgotten: return .forgotten
        case .superseded: return .superseded
        case .expired: return .expired
        case .notYetValid: return .notYetValid
        case .archived: return .archived
        case .rejected: return .rejected
        case .removed: return .removed
        case .candidate: return .candidate
        case .active: return .updated
        }
    }

    private static func draftAllowed(_ draft: MemoryDraft?, connectionID: ConnectionID?) -> Bool {
        guard let draft else { return false }
        if let connectionID {
            guard draft.allowsRemoteUse else { return false }
            return draft.allowedConnectionIDs?.contains(connectionID) ?? true
        }
        return true
    }
}
