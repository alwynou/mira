import Foundation
import Testing
@testable import MiraCore

struct MemoryContextTests {
    @Test func prefetchSelectsAtMostSixWholeEntriesAndReferencesExactRevisions() throws {
        let fixture = ContextFixture(route: route(contextWindow: 100_000))
        let memories = (0..<8).map { index in
            makeMemory(
                id: MemoryID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!),
                draft: MemoryDraft(content: "Preference \(index)", scope: .global),
                revision: index + 1
            )
        }
        let request = try build(fixture, memories: memories)
        let memoryReferences = request.contextInfo?.references.filter { $0.kind == "memory" } ?? []
        let included = memories.filter { request.system.contains($0.citation) }

        #expect(included.count == 6)
        #expect(memoryReferences.count == included.count)
        #expect(Set(memoryReferences.map(\.id)) == Set(included.map { $0.id.rawValue.uuidString }))
        #expect(memoryReferences.allSatisfy { reference in
            included.contains { $0.id.rawValue.uuidString == reference.id && $0.revision == reference.revision }
        })
        #expect(!request.system.contains(memories[6].citation))
        #expect(!request.system.contains(memories[7].citation))
    }

    @Test func prefetchUsesEightPercentBudgetAndOmitsOversizedEntryWhole() throws {
        let fixture = ContextFixture(route: route(contextWindow: 10_000))
        let small = makeMemory(draft: MemoryDraft(content: String(repeating: "small ", count: 16), scope: .global), revision: 2)
        let oversized = makeMemory(draft: MemoryDraft(content: String(repeating: "too-large ", count: 300), scope: .global), revision: 3)
        let afterOversized = makeMemory(draft: MemoryDraft(content: "This entry should still be considered after an omitted entry.", scope: .global), revision: 4)

        let base = try build(fixture)
        let request = try build(fixture, memories: [small, oversized, afterOversized])
        let margin = max(512, fixture.route.contextWindow! / 10)
        let availableInput = fixture.route.contextWindow! - fixture.route.maxOutputTokens - margin
        let baseEstimate = base.system.utf8.count + base.messages.reduce(0) { $0 + $1.text.utf8.count + 16 }
        let memoryBudget = min(1_200, availableInput * 8 / 100, availableInput - baseEstimate)
        let addedMemoryBytes = request.system.utf8.count - base.system.utf8.count

        #expect(memoryBudget < 1_200)
        #expect(addedMemoryBytes <= memoryBudget)
        #expect(request.system.contains(small.citation))
        #expect(request.system.contains(afterOversized.citation))
        #expect(!request.system.contains(oversized.citation))
        #expect(!request.system.contains(String(repeating: "too-large ", count: 20)))
    }

    @Test func suppliedMemoriesAreRevalidatedForScopeStateTimeAndOutboundPolicy() throws {
        let workspaceID = WorkspaceID()
        let otherWorkspaceID = WorkspaceID()
        let connectionID = fixtureConnectionID
        let now = Date(timeIntervalSince1970: 1_000)
        let fixture = ContextFixture(route: route(contextWindow: 100_000, connectionID: connectionID), workspaceID: workspaceID, at: now)
        let valid = makeMemory(draft: MemoryDraft(content: "Allowed workspace memory", scope: .workspace(workspaceID), subject: .workspace), revision: 2)
        let wrongWorkspace = makeMemory(draft: MemoryDraft(content: "Wrong workspace", scope: .workspace(otherWorkspaceID), subject: .workspace))
        let candidate = makeMemory(draft: MemoryDraft(content: "Candidate", scope: .global), state: .candidate)
        let expired = makeMemory(draft: MemoryDraft(content: "Expired", scope: .global, validUntil: now))
        let localOnly = makeMemory(draft: MemoryDraft(content: "Local only", scope: .global, allowsRemoteUse: false))
        let restricted = makeMemory(draft: MemoryDraft(content: "Other connection", scope: .global, allowedConnectionIDs: [ConnectionID()]))
        let malformed = makeMemory(
            draft: MemoryDraft(content: "Malformed scope", scope: .workspace(otherWorkspaceID), subject: .workspace),
            scope: .global
        )

        let request = try build(fixture, memories: [valid, wrongWorkspace, candidate, expired, localOnly, restricted, malformed])
        #expect(request.system.contains(valid.citation))
        for memory in [wrongWorkspace, candidate, expired, localOnly, restricted, malformed] {
            #expect(!request.system.contains(memory.citation))
        }
        let memoryReferences = request.contextInfo?.references.filter { $0.kind == "memory" } ?? []
        #expect(memoryReferences.map(\.id) == [valid.id.rawValue.uuidString])
        #expect(memoryReferences.first?.revision == valid.revision)
    }

    @Test func suppressedSourcesAndPurgedAssistantBodiesDoNotEnterHistoryButCurrentInputRemains() throws {
        let fixture = ContextFixture(route: route(contextWindow: 100_000))
        let suppressedUserID = MessageID()
        let purgedUserID = MessageID()
        let suppressedExecutionID = ExecutionID()
        let purgedExecutionID = ExecutionID()
        let suppressedAnswerID = MessageID()
        let purgedAnswerID = MessageID()
        let suppressedExecution = Execution(
            id: suppressedExecutionID, conversationID: fixture.conversation.id, triggerMessageID: suppressedUserID,
            status: .completed, route: fixture.route, createdAt: fixture.now, updatedAt: fixture.now
        )
        let purgedExecution = Execution(
            id: purgedExecutionID, conversationID: fixture.conversation.id, triggerMessageID: purgedUserID,
            status: .completed, route: fixture.route, createdAt: fixture.now, updatedAt: fixture.now
        )
        let suppressedUser = Message(id: suppressedUserID, conversationID: fixture.conversation.id, executionID: suppressedExecutionID, sequence: 1, role: .user, status: .committed, text: "Suppressed source", createdAt: fixture.now)
        let purgedUser = Message(id: purgedUserID, conversationID: fixture.conversation.id, executionID: purgedExecutionID, sequence: 3, role: .user, status: .committed, text: "Purged answer source", createdAt: fixture.now)
        let suppressedAnswer = Message(id: suppressedAnswerID, conversationID: fixture.conversation.id, executionID: suppressedExecutionID, sequence: 2, role: .assistant, status: .committed, text: "Should be suppressed with its source", createdAt: fixture.now)
        let purgedAnswer = Message(id: purgedAnswerID, conversationID: fixture.conversation.id, executionID: purgedExecutionID, sequence: 4, role: .assistant, status: .committed, text: "Should not survive body purge", createdAt: fixture.now, bodyPurgedAt: fixture.now)
        var currentTrigger = fixture.trigger
        currentTrigger.sequence = 5
        let messages = [suppressedUser, suppressedAnswer, purgedUser, purgedAnswer, currentTrigger]

        let request = try ContextBuilder.build(
            execution: fixture.execution,
            conversations: [fixture.conversation],
            workspaces: fixture.workspaces,
            messages: messages,
            executions: [suppressedExecution, purgedExecution, fixture.execution],
            suppressedMessageIDs: [suppressedUserID],
            at: fixture.now
        )

        #expect(request.messages.map(\.text) == [fixture.trigger.text])
        #expect(request.contextInfo?.references.filter { $0.kind == "historyMessage" }.isEmpty == true)
        #expect(request.contextInfo?.references.first?.kind == "currentUserMessage")
    }
}

private let fixtureConnectionID = ConnectionID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)

private struct ContextFixture {
    let now: Date
    let route: ResolvedModelRouteSnapshot
    let conversation: Conversation
    let trigger: Message
    let execution: Execution
    let workspaces: [Workspace]

    init(route: ResolvedModelRouteSnapshot, workspaceID: WorkspaceID? = nil, at: Date = Date(timeIntervalSince1970: 1_000)) {
        now = at
        self.route = route
        let conversationID = ConversationID()
        let conversation = Conversation(id: conversationID, workspaceID: workspaceID, title: "Fixture", createdAt: at, updatedAt: at)
        self.conversation = conversation
        let triggerID = MessageID()
        let triggerExecutionID = ExecutionID()
        let trigger = Message(id: triggerID, conversationID: conversationID, executionID: triggerExecutionID, sequence: 1, role: .user, status: .committed, text: "Current user input", createdAt: at)
        self.trigger = trigger
        execution = Execution(id: triggerExecutionID, conversationID: conversationID, triggerMessageID: triggerID, route: route, createdAt: at, updatedAt: at)
        workspaces = workspaceID.map { [Workspace(id: $0, name: "Fixture workspace")] } ?? []
    }
}

private func route(
    contextWindow: Int,
    maxOutputTokens: Int = 1_024,
    connectionID: ConnectionID = fixtureConnectionID
) -> ResolvedModelRouteSnapshot {
    ResolvedModelRouteSnapshot(
        name: "Memory context fixture",
        providerKind: .openAICompatible,
        baseURL: "https://example.invalid/v1",
        modelID: "synthetic",
        credentialReference: "fixture",
        contextWindow: contextWindow,
        maxOutputTokens: maxOutputTokens,
        connectionID: connectionID
    )
}

private func build(_ fixture: ContextFixture, memories: [Memory] = []) throws -> CanonicalModelRequest {
    try ContextBuilder.build(
        execution: fixture.execution,
        conversations: [fixture.conversation],
        workspaces: fixture.workspaces,
        messages: [fixture.trigger],
        executions: [fixture.execution],
        memories: memories,
        at: fixture.now
    )
}

private func makeMemory(
    id: MemoryID = MemoryID(),
    draft: MemoryDraft,
    state: MemoryState = .active,
    revision: Int = 1,
    scope: MemoryScope? = nil
) -> Memory {
    let now = Date(timeIntervalSince1970: 1_000)
    return Memory(
        id: id,
        draft: draft,
        scope: scope ?? draft.scope,
        subject: draft.subject,
        state: state,
        revision: revision,
        createdAt: now,
        updatedAt: now
    )
}
