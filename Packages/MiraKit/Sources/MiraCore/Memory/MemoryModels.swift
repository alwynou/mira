import Foundation

public enum MemoryTag: Sendable {}
public typealias MemoryID = EntityID<MemoryTag>

public enum MemoryScope: Codable, Hashable, Sendable {
    case global
    case workspace(WorkspaceID)
    public var workspaceID: WorkspaceID? { if case .workspace(let id) = self { id } else { nil } }
    public var key: String { workspaceID.map { "workspace:\($0.rawValue.uuidString.lowercased())" } ?? "global" }
    public func isVisible(in workspaceID: WorkspaceID?) -> Bool { self.workspaceID == nil || self.workspaceID == workspaceID }
}
public enum MemorySubject: String, Codable, CaseIterable, Sendable { case user, workspace }
public enum MemoryKind: String, Codable, CaseIterable, Sendable { case fact, preference, decision, goal, constraint, procedure, learning, context }
public enum MemoryState: String, Codable, CaseIterable, Sendable { case active, candidate, archived, rejected, removed }
public enum MemoryOrigin: String, Codable, Sendable { case explicitUser, observedUserStatement, agentInference }
public enum MemoryAuthority: String, Codable, Sendable { case explicitUser, observedUser, inferred }
public enum MemorySensitivity: String, Codable, CaseIterable, Sendable { case standard, sensitive }

/// User-reviewed content and disclosure policy. Sensitive storage and remote use are separate choices.
public struct MemoryDraft: Codable, Equatable, Sendable {
    public var content: String
    public var scope: MemoryScope
    public var subject: MemorySubject
    public var kind: MemoryKind
    public var sensitivity: MemorySensitivity
    public var allowsRemoteUse: Bool
    public var allowedConnectionIDs: Set<ConnectionID>?
    public var validFrom: Date?
    public var validUntil: Date?
    public init(content: String, scope: MemoryScope, subject: MemorySubject = .user, kind: MemoryKind = .fact, sensitivity: MemorySensitivity = .standard, allowsRemoteUse: Bool = true, allowedConnectionIDs: Set<ConnectionID>? = nil, validFrom: Date? = nil, validUntil: Date? = nil) {
        self.content = content; self.scope = scope; self.subject = subject; self.kind = kind
        self.sensitivity = sensitivity; self.allowsRemoteUse = allowsRemoteUse; self.allowedConnectionIDs = allowedConnectionIDs
        self.validFrom = validFrom; self.validUntil = validUntil
    }
    public func validate() throws {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.utf8.count <= 8_192 else {
            throw MiraError(.invalidInput, "Memory content is required and must be at most 8 KiB.")
        }
        guard subject != .workspace || scope.workspaceID != nil else {
            throw MiraError(.invalidInput, "A project memory requires a workspace scope.")
        }
        if let validFrom, let validUntil, validFrom >= validUntil {
            throw MiraError(.invalidInput, "Memory validity must end after it starts.")
        }
    }
}

/// The store resolves the source itself; caller-provided excerpts never establish authorship.
public enum MemorySourceInput: Codable, Equatable, Sendable {
    case message(id: MessageID, excerpt: String)
    case manualEntry(id: UUID, statement: String)
}
public enum MemoryEvidenceKind: String, Codable, Sendable { case message, manualEntry }
public struct MemoryEvidence: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var memoryID: MemoryID
    public var sourceKind: MemoryEvidenceKind
    public var sourceID: UUID
    public var sourceRevision: Int
    public var conversationID: ConversationID?
    public var excerpt: String?
    public var sourceHash: String?
    public var speakerRole: MessageRole
    public var createdAt: Date
    public var bodyPurgedAt: Date?
    public init(id: UUID = UUID(), memoryID: MemoryID, sourceKind: MemoryEvidenceKind, sourceID: UUID, sourceRevision: Int = 1, conversationID: ConversationID? = nil, excerpt: String?, sourceHash: String?, speakerRole: MessageRole = .user, createdAt: Date, bodyPurgedAt: Date? = nil) {
        self.id = id; self.memoryID = memoryID; self.sourceKind = sourceKind; self.sourceID = sourceID
        self.sourceRevision = sourceRevision; self.conversationID = conversationID; self.excerpt = excerpt
        self.sourceHash = sourceHash; self.speakerRole = speakerRole; self.createdAt = createdAt; self.bodyPurgedAt = bodyPurgedAt
    }
}

public struct Memory: Identifiable, Codable, Equatable, Sendable {
    public var id: MemoryID
    /// Nil only for a forgotten record; scope and subject remain in body-free metadata below.
    public var draft: MemoryDraft?
    public var scope: MemoryScope
    public var subject: MemorySubject
    public var state: MemoryState
    public var origin: MemoryOrigin
    public var authority: MemoryAuthority
    public var supersededBy: MemoryID?
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var forgottenAt: Date?
    public var isCurrent: Bool { supersededBy == nil && state == .active && forgottenAt == nil }
    public init(id: MemoryID = .init(), draft: MemoryDraft?, scope: MemoryScope, subject: MemorySubject, state: MemoryState = .active, origin: MemoryOrigin = .explicitUser, authority: MemoryAuthority = .explicitUser, supersededBy: MemoryID? = nil, revision: Int = 1, createdAt: Date, updatedAt: Date, deletedAt: Date? = nil, forgottenAt: Date? = nil) {
        self.id = id; self.draft = draft; self.scope = scope; self.subject = subject; self.state = state
        self.origin = origin; self.authority = authority; self.supersededBy = supersededBy; self.revision = revision
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt; self.forgottenAt = forgottenAt
    }
    public func canRecall(in workspaceID: WorkspaceID?, connectionID: ConnectionID, at: Date) -> Bool {
        guard isCurrent, deletedAt == nil, scope.isVisible(in: workspaceID), let draft,
              draft.scope == scope, draft.subject == subject, draft.allowsRemoteUse,
              draft.allowedConnectionIDs.map({ $0.contains(connectionID) }) ?? true,
              draft.validFrom.map({ $0 <= at }) ?? true,
              draft.validUntil.map({ $0 > at }) ?? true else { return false }
        return true
    }
    public var citation: String { "memory:\(id.rawValue.uuidString.lowercased())@\(revision)" }
}

public struct MemoryRevision: Identifiable, Codable, Equatable, Sendable {
    public var memoryID: MemoryID
    public var revision: Int
    public var draft: MemoryDraft?
    public var actor: String
    public var changedAt: Date
    public var bodyPurgedAt: Date?
    public var id: String { "\(memoryID.rawValue):\(revision)" }
    public init(memoryID: MemoryID, revision: Int, draft: MemoryDraft?, actor: String = "user", changedAt: Date, bodyPurgedAt: Date? = nil) {
        self.memoryID = memoryID; self.revision = revision; self.draft = draft; self.actor = actor
        self.changedAt = changedAt; self.bodyPurgedAt = bodyPurgedAt
    }
}
public enum MemoryReplacementState: String, Codable, Sendable { case proposed, confirmed, rejected }
public struct MemoryReplacement: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var replacementID: MemoryID
    public var previousID: MemoryID
    public var state: MemoryReplacementState
    public var createdAt: Date
    public init(id: UUID = UUID(), replacementID: MemoryID, previousID: MemoryID, state: MemoryReplacementState, createdAt: Date) {
        self.id = id; self.replacementID = replacementID; self.previousID = previousID; self.state = state; self.createdAt = createdAt
    }
}
public struct MemoryDetail: Sendable {
    public var memory: Memory
    public var evidence: [MemoryEvidence]
    public var revisions: [MemoryRevision]
    public var replacements: [MemoryReplacement]
    public init(memory: Memory, evidence: [MemoryEvidence], revisions: [MemoryRevision], replacements: [MemoryReplacement]) {
        self.memory = memory; self.evidence = evidence; self.revisions = revisions; self.replacements = replacements
    }
}
public enum MemoryWriteDisposition: String, Codable, Sendable { case created, existing, replacementProposed }
public struct MemoryWriteReceipt: Sendable {
    public var memory: Memory
    public var disposition: MemoryWriteDisposition
    public init(memory: Memory, disposition: MemoryWriteDisposition) { self.memory = memory; self.disposition = disposition }
}
public struct MemorySearchResult: Sendable {
    public var memories: [Memory]
    public var isTruncated: Bool
    public init(memories: [Memory], isTruncated: Bool = false) { self.memories = memories; self.isTruncated = isTruncated }
}
public struct MemoryUsage: Codable, Equatable, Sendable {
    public var memoryID: MemoryID
    public var revision: Int
    public init(memoryID: MemoryID, revision: Int) { self.memoryID = memoryID; self.revision = revision }
}
public struct MemoryForgetReceipt: Sendable {
    public var memoryID: MemoryID
    public var redactedExecutionIDs: Set<ExecutionID>
    public init(memoryID: MemoryID, redactedExecutionIDs: Set<ExecutionID>) { self.memoryID = memoryID; self.redactedExecutionIDs = redactedExecutionIDs }
}
