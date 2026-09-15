import Foundation
import Testing
@testable import MiraCore

struct MemoryModelTests {
    @Test func draftValidationUsesUTF8BytesAndRequiresCompatibleScopeAndSubject() throws {
        let workspaceID = WorkspaceID()
        let validWorkspaceDraft = MemoryDraft(
            content: String(repeating: "中", count: 2_730), // i18n-fixture: Exercise the UTF-8 byte limit with non-ASCII content.
            scope: .workspace(workspaceID),
            subject: .workspace
        )
        #expect(validWorkspaceDraft.content.utf8.count == 8_190)
        try validWorkspaceDraft.validate()

        let tooLarge = MemoryDraft(content: String(repeating: "中", count: 2_731), scope: .global) // i18n-fixture: Exercise rejection just beyond the UTF-8 byte limit.
        #expect(tooLarge.content.utf8.count == 8_193)
        #expect(throws: MiraError.self) { try tooLarge.validate() }

        let blank = MemoryDraft(content: " \n\t", scope: .global)
        #expect(throws: MiraError.self) { try blank.validate() }

        let workspaceSubjectAtGlobalScope = MemoryDraft(content: "A project decision", scope: .global, subject: .workspace)
        #expect(throws: MiraError.self) { try workspaceSubjectAtGlobalScope.validate() }
    }

    @Test func draftValidationRejectsNonIncreasingValidityInterval() throws {
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)
        try MemoryDraft(content: "valid", scope: .global, validFrom: start, validUntil: end).validate()
        #expect(throws: MiraError.self) {
            try MemoryDraft(content: "same instant", scope: .global, validFrom: start, validUntil: start).validate()
        }
        #expect(throws: MiraError.self) {
            try MemoryDraft(content: "reversed", scope: .global, validFrom: end, validUntil: start).validate()
        }
    }

    @Test func recallUsesGlobalOrOwningWorkspaceScopeAndConnectionPolicy() {
        let now = Date(timeIntervalSince1970: 1_000)
        let workspaceID = WorkspaceID()
        let otherWorkspaceID = WorkspaceID()
        let allowedConnection = ConnectionID()
        let otherConnection = ConnectionID()

        let global = makeMemory(draft: MemoryDraft(content: "Global preference", scope: .global, allowedConnectionIDs: [allowedConnection]))
        #expect(global.canRecall(in: nil, connectionID: allowedConnection, at: now))
        #expect(global.canRecall(in: workspaceID, connectionID: allowedConnection, at: now))
        #expect(!global.canRecall(in: workspaceID, connectionID: otherConnection, at: now))

        let project = makeMemory(draft: MemoryDraft(content: "Project decision", scope: .workspace(workspaceID), subject: .workspace, allowedConnectionIDs: [allowedConnection]))
        #expect(project.canRecall(in: workspaceID, connectionID: allowedConnection, at: now))
        #expect(!project.canRecall(in: nil, connectionID: allowedConnection, at: now))
        #expect(!project.canRecall(in: otherWorkspaceID, connectionID: allowedConnection, at: now))
        #expect(!project.canRecall(in: workspaceID, connectionID: otherConnection, at: now))

        let localOnly = makeMemory(draft: MemoryDraft(content: "Keep local", scope: .global, allowsRemoteUse: false))
        #expect(!localOnly.canRecall(in: workspaceID, connectionID: allowedConnection, at: now))
    }

    @Test(arguments: [
        MemoryState.candidate,
        MemoryState.archived,
        MemoryState.rejected,
        MemoryState.removed
    ])
    func nonActiveStatesAreNeverRecalled(_ state: MemoryState) {
        let memory = makeMemory(draft: MemoryDraft(content: "Not current", scope: .global), state: state)
        #expect(!memory.canRecall(in: nil, connectionID: ConnectionID(), at: Date()))
    }

    @Test func supersededDeletedAndForgottenMemoriesAreNeverRecalled() {
        let now = Date(timeIntervalSince1970: 1_000)
        let connectionID = ConnectionID()

        let superseded = makeMemory(draft: MemoryDraft(content: "Old", scope: .global), supersededBy: MemoryID())
        let deleted = makeMemory(draft: MemoryDraft(content: "Deleted", scope: .global), deletedAt: now)
        let forgotten = makeMemory(draft: MemoryDraft(content: "Forgotten", scope: .global), forgottenAt: now)

        #expect(!superseded.canRecall(in: nil, connectionID: connectionID, at: now))
        #expect(!deleted.canRecall(in: nil, connectionID: connectionID, at: now))
        #expect(!forgotten.canRecall(in: nil, connectionID: connectionID, at: now))
    }

    @Test func recallHonorsValidityIntervalAtItsBoundaries() {
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)
        let memory = makeMemory(draft: MemoryDraft(content: "Temporary context", scope: .global, validFrom: start, validUntil: end))
        let connectionID = ConnectionID()

        #expect(!memory.canRecall(in: nil, connectionID: connectionID, at: start.addingTimeInterval(-1)))
        #expect(memory.canRecall(in: nil, connectionID: connectionID, at: start))
        #expect(memory.canRecall(in: nil, connectionID: connectionID, at: end.addingTimeInterval(-1)))
        #expect(!memory.canRecall(in: nil, connectionID: connectionID, at: end))
    }

    @Test func citationIsStableForAnIdentityAndRevision() {
        let id = MemoryID(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        let memory = makeMemory(id: id, draft: MemoryDraft(content: "A preference", scope: .global), revision: 3)
        #expect(memory.citation == "memory:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee@3")
    }
}

private func makeMemory(
    id: MemoryID = MemoryID(),
    draft: MemoryDraft?,
    state: MemoryState = .active,
    supersededBy: MemoryID? = nil,
    revision: Int = 1,
    deletedAt: Date? = nil,
    forgottenAt: Date? = nil
) -> Memory {
    let now = Date(timeIntervalSince1970: 1_000)
    return Memory(
        id: id,
        draft: draft,
        scope: draft?.scope ?? .global,
        subject: draft?.subject ?? .user,
        state: state,
        supersededBy: supersededBy,
        revision: revision,
        createdAt: now,
        updatedAt: now,
        deletedAt: deletedAt,
        forgottenAt: forgottenAt
    )
}
