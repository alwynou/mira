import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Memory retraction authorization boundaries")
struct MemoryRetractionAuthorizationTests {
    @Test func sharedSourceRetractionLeavesUnrelatedCurrentMemoryRecallableAndEnrichable() async throws {
        try await withAuthorizationFixture { fixture in
            let source = userEvidence("I prefer early flights, and I usually travel light.", sequence: 2)
            let target = try await fixture.store.createMemory(
                draft: .init(content: "I prefer early flights", scope: .global, kind: .preference),
                source: .userMessage(evidence: source, excerpt: "I prefer early flights"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: fixture.authorization, at: fixture.date).memory
            let unrelated = try await fixture.store.createMemory(
                draft: .init(content: "I usually travel light", scope: .global, kind: .fact),
                source: .userMessage(evidence: source, excerpt: "I usually travel light"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: fixture.authorization, at: fixture.date).memory
            let request = request(for: source, text: "Actually the flight preference was only for one trip.")
            let retracted = try await fixture.database.write { db in
                try SQLiteMemoryStore.retractMemoryInTransaction(
                    target: .init(memoryID: target.id, revision: target.revision),
                    source: .manualEntry(id: UUID(), statement: "Actually the flight preference was only for one trip."),
                    operationID: UUID(), request: request, at: fixture.date, in: db)
            }
            #expect(retracted.disposition == .retracted)
            let recalled = try await fixture.store.recallMemory(unrelated.id, request: request, at: fixture.date)
            #expect(recalled.id == unrelated.id)
            let enriched = try await fixture.database.write { db in
                try SQLiteMemoryStore.enrichRememberedMemory(
                    draft: .init(content: "I usually travel light and pack one bag", scope: .global, kind: .fact),
                    source: .manualEntry(id: UUID(), statement: "I also pack one bag."),
                    targets: [.init(memoryID: unrelated.id, revision: unrelated.revision)],
                    operationID: UUID(), at: fixture.date, in: db)
            }
            #expect(enriched.memory.draft?.content == "I usually travel light and pack one bag")
        }
    }

    @Test func revokedWithdrawalSourceCannotReplayCommittedRetraction() async throws {
        try await withAuthorizationFixture { fixture in
            let original = try await fixture.store.createMemory(
                draft: .init(content: "A temporary preference", scope: .global),
                source: .manualEntry(id: UUID(), statement: "A temporary preference"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: fixture.authorization, at: fixture.date).memory
            let sourceID = UUID()
            let request = AgentContextRequest(sessionID: ConversationID(), executionID: ExecutionID(), workspaceID: nil,
                                              userText: "Withdraw that", authorizationEpoch: 0, destination: .local)
            let operationID = UUID()
            _ = try await fixture.database.write { db in
                try SQLiteMemoryStore.retractMemoryInTransaction(
                    target: .init(memoryID: original.id, revision: original.revision),
                    source: .manualEntry(id: sourceID, statement: "Withdraw that"), operationID: operationID,
                    request: request, at: fixture.date, in: db)
            }
            try await fixture.database.write { db in
                try SQLiteMemoryStore.suppress(.manualEntry(sourceID), strength: 3, in: db)
            }
            await #expect(throws: MiraError.self) {
                _ = try await fixture.database.write { db in
                    try SQLiteMemoryStore.retractMemoryInTransaction(
                        target: .init(memoryID: original.id, revision: original.revision),
                        source: .manualEntry(id: sourceID, statement: "Withdraw that"), operationID: operationID,
                        request: request, at: fixture.date, in: db)
                }
            }
        }
    }

    @Test func explicitReactivationAllowsLatestRevisionContextAndFreshRetraction() async throws {
        try await withAuthorizationFixture { fixture in
            let original = try await fixture.store.createMemory(
                draft: .init(content: "I prefer aisle seats", scope: .global),
                source: .manualEntry(id: UUID(), statement: "I prefer aisle seats"), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: fixture.authorization, at: fixture.date).memory
            let request = AgentContextRequest(sessionID: ConversationID(), executionID: ExecutionID(), workspaceID: nil,
                                              userText: "Withdraw that", authorizationEpoch: 0, destination: .local)
            let first = try await fixture.database.write { db in
                try SQLiteMemoryStore.retractMemoryInTransaction(
                    target: .init(memoryID: original.id, revision: original.revision),
                    source: .manualEntry(id: UUID(), statement: "Withdraw that"), operationID: UUID(),
                    request: request, at: fixture.date, in: db)
            }
            let reactivated = try await fixture.store.changeMemoryState(
                original.id, workspaceID: nil, state: .active, expectedRevision: first.memory.revision,
                operationID: UUID(), authorization: fixture.authorization, at: fixture.date)
            #expect(reactivated.state == .active)
            let latestRequest = AgentContextRequest(sessionID: request.sessionID, executionID: ExecutionID(), workspaceID: nil,
                                                    userText: "Withdraw that again", authorizationEpoch: 0, destination: .local)
            let latest = try await fixture.store.recallMemory(original.id, request: latestRequest, at: fixture.date)
            #expect(latest.revision == reactivated.revision)
            let second = try await fixture.database.write { db in
                try SQLiteMemoryStore.retractMemoryInTransaction(
                    target: .init(memoryID: original.id, revision: reactivated.revision),
                    source: .manualEntry(id: UUID(), statement: "Withdraw that again"), operationID: UUID(),
                    request: latestRequest, at: fixture.date, in: db)
            }
            #expect(second.memory.state == .archived)
            #expect(second.memory.retraction?.priorRevision == reactivated.revision)
            let restored = try await fixture.store.changeMemoryState(
                original.id, workspaceID: nil, state: .active, expectedRevision: second.memory.revision,
                operationID: UUID(), authorization: fixture.authorization, at: fixture.date)
            let enriched = try await fixture.database.write { db in
                try SQLiteMemoryStore.enrichRememberedMemory(
                    draft: .init(content: "I prefer aisle seats near the front", scope: .global),
                    source: .manualEntry(id: UUID(), statement: "I also prefer sitting near the front"),
                    targets: [.init(memoryID: original.id, revision: restored.revision)],
                    operationID: UUID(), at: fixture.date, in: db)
            }
            let enrichedDetail = try await fixture.store.memoryDetail(enriched.memory.id, workspaceID: nil)
            #expect(enrichedDetail.evidence.count == 2)
            #expect(enrichedDetail.evidence.allSatisfy { $0.retractionRevision == nil })
        }
    }
}

private struct AuthorizationFixture: Sendable {
    let database: DatabaseQueue
    let authority: SQLiteLibraryAuthority
    let workspaces: SQLiteWorkspaceStore
    let store: SQLiteMemoryStore
    let authorization: AgentLibraryAuthorization
    let date = Date(timeIntervalSince1970: 20_000)
}

private func withAuthorizationFixture(_ body: (AuthorizationFixture) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-retraction-auth-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var configuration = Configuration(); configuration.foreignKeysEnabled = true
    let database = try DatabaseQueue(path: directory.appendingPathComponent("memory.sqlite").path, configuration: configuration)
    let authority = try SQLiteLibraryAuthority(database: database, validators: [SQLiteMemoryStore.maintenanceValidator])
    let workspaces = try SQLiteWorkspaceStore(database: database, libraryID: authority.libraryID)
    let store = try SQLiteMemoryStore(database: database, libraryID: authority.libraryID)
    do {
        try await body(.init(database: database, authority: authority, workspaces: workspaces, store: store, authorization: try await authority.authorization()))
        await store.close(); await workspaces.close(); await authority.close(); try database.close()
        try? FileManager.default.removeItem(at: directory)
    } catch {
        await store.close(); await workspaces.close(); await authority.close(); try? database.close()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

private func userEvidence(_ text: String, sequence: Int64) -> SessionUserEvidence {
    let session = ConversationID(), execution = ExecutionID()
    return .init(reference: .init(sessionID: session, originalExecutionID: execution, userMessageID: MessageID(), admissionEventID: UUID(), admissionSequence: sequence),
                 workspaceID: nil, admittedAt: Date(timeIntervalSince1970: 19_000), timeZoneIdentifier: "UTC", text: text,
                 observedHead: .init(cursor: .init(sessionID: session, sequence: sequence), batchID: UUID()), sessionAuthorizationEpoch: 0)
}

private func request(for evidence: SessionUserEvidence, text: String) -> AgentContextRequest {
    .init(sessionID: evidence.reference.sessionID, executionID: evidence.reference.originalExecutionID,
          workspaceID: nil, userText: text, authorizationEpoch: evidence.sessionAuthorizationEpoch, destination: .local)
}
