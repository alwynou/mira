import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("SQLite session privacy plans", .timeLimit(.minutes(1)))
struct SQLiteSessionPrivacyPlanStoreTests {
    @Test func missingOrMismatchedJournalProvenanceCannotDisappearFromTheClosure() async throws {
        try await withFixture { f in
            let operation = try await f.pendingOperation()
            let plan = try plan(for: operation)
            try await f.store.save(plan)
            let session = try #require(plan.changes.first?.batch.sessionID)
            await #expect(throws: MiraError.self) {
                try await f.store.retainedDependencies(
                    sessionID: session, invalidationIDs: [UUID()], operation: operation)
            }
            await #expect(throws: MiraError.self) {
                try await f.store.retainedDependencies(
                    sessionID: ConversationID(), invalidationIDs: [operation.request.id], operation: operation)
            }
            let otherLibrary = UUID()
            let wrong = AgentLibraryMaintenanceOperation(
                request: operation.request,
                previousAuthorization: .init(libraryID: otherLibrary, epoch: operation.previousAuthorization.epoch),
                authorization: .init(libraryID: otherLibrary, epoch: operation.authorization.epoch), completedAt: nil)
            await #expect(throws: MiraError.self) { try await f.store.load(operation: wrong) }
            try await f.database.write { db in
                try db.execute(sql: "UPDATE session_privacy_plans SET plan_json = zeroblob(byte_count)")
            }
            await #expect(throws: MiraError.self) {
                try await f.store.retainedDependencies(
                    sessionID: session, invalidationIDs: [operation.request.id], operation: operation)
            }
        }
    }

    @Test func saveLoadAndReopenPreservesImmutablePlan() async throws {
        try await withFixture { f in
            let operation = try await f.pendingOperation()
            let plan = try plan(for: operation)
            try await f.store.save(plan)
            #expect(try await f.store.load(operation: operation) == plan)
            await f.store.close()
            let reopened = try SQLiteSessionPrivacyPlanStore(database: f.database, libraryID: f.authority.libraryID)
            #expect(try await reopened.load(operation: operation) == plan)
            await reopened.close()
        }
    }

    @Test func duplicateIsIdempotentButChangedPlanConflicts() async throws {
        try await withFixture { f in
            let operation = try await f.pendingOperation()
            let plan = try plan(for: operation)
            try await f.store.save(plan)
            try await f.store.save(plan)
            let changed = SessionPrivacyPlan(
                operation: operation, roots: plan.roots,
                retention: .purgeGeneratedHistory, reason: plan.reason, heads: plan.heads, changes: plan.changes)
            await #expect(throws: MiraError.self) { try await f.store.save(changed) }
        }
    }

    @Test func retainedDependenciesAreFilteredMergedAndDeterministic() async throws {
        try await withFixture { f in
            let operation = try await f.pendingOperation()
            let first = ConversationID()
            let second = ConversationID()
            let e1 = ExecutionID()
            let e2 = ExecutionID()
            let source = AgentSourceReference.domain(namespace: "memory", id: UUID(), revision: 1)
            let plan = try plan(for: operation, sessions: [(first, [(e1, [source])]), (second, [(e2, [source])])])
            try await f.store.save(plan)
            let result = try await f.store.retainedDependencies(
                sessionID: first, invalidationIDs: [operation.request.id], operation: operation)
            #expect(result == [.init(executionID: e1, sources: [source])])
            #expect(
                try await f.store.retainedDependencies(
                    sessionID: ConversationID(), invalidationIDs: [], operation: operation
                ).isEmpty)
        }
    }

    @Test func pendingAndStaleOperationsAreRejected() async throws {
        try await withFixture { f in
            let operation = try await f.pendingOperation()
            let plan = try plan(for: operation)
            try await f.store.save(plan)
            let state = try await f.authority.state()
            #expect(state.pending == operation)
            let stale = AgentLibraryMaintenanceOperation(
                request: operation.request,
                previousAuthorization: operation.previousAuthorization,
                authorization: operation.authorization, completedAt: Date(timeIntervalSince1970: 1_800_000_001))
            await #expect(throws: MiraError.self) { try await f.store.load(operation: stale) }
            let wrong = AgentLibraryMaintenanceOperation(
                request: .init(
                    id: UUID(), namespace: operation.request.namespace,
                    revision: operation.request.revision, scope: operation.request.scope,
                    requestedAt: operation.request.requestedAt),
                previousAuthorization: operation.previousAuthorization, authorization: operation.authorization,
                completedAt: nil)
            await #expect(throws: MiraError.self) { try await f.store.load(operation: wrong) }
        }
    }

    @Test func acknowledgementLossAndTamperingFailClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-privacy-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
        let database = try DatabaseQueue(
            path: directory.appendingPathComponent("business.sqlite").path, configuration: configuration)
        let authority = try SQLiteLibraryAuthority(database: database)
        let operation = try await SQLiteSessionPrivacyPlanStoreTests.begin(authority: authority)
        let store = try SQLiteSessionPrivacyPlanStore(
            database: database, libraryID: authority.libraryID,
            afterCommitHook: { throw MiraError(.storage, "Synthetic acknowledgement loss.") })
        let plan = try plan(for: operation)
        await #expect(throws: MiraError.self) { try await store.save(plan) }
        let confirmed = try #require(try await store.load(operation: operation))
        #expect(confirmed == plan)
        try await database.write { db in
            try db.execute(
                sql: "UPDATE session_privacy_plans SET digest = 'tampered' WHERE operation_id = ?",
                arguments: [operation.request.id.uuidString])
        }
        await #expect(throws: MiraError.self) { try await store.load(operation: operation) }
        await store.close()
        await authority.close()
        try database.close()
    }

    @Test func completedPriorPlanDependenciesRemainVisibleToNextMaintenance() async throws {
        try await withFixture { f in
            let first = try await f.pendingOperation()
            let session = ConversationID()
            let plan = try plan(for: first, sessions: [(session, [(ExecutionID(), [])])])
            try await f.store.save(plan)
            _ = try await f.authority.complete(first, at: Date(timeIntervalSince1970: 1_800_000_001))
            let second = try await f.pendingOperation()
            #expect(
                try await f.store.retainedDependencies(
                    sessionID: session, invalidationIDs: [first.request.id], operation: second
                ).count == 1)
        }
    }

    @Test func completedLoadAndClosedStoreAreRejected() async throws {
        try await withFixture { f in
            let operation = try await f.pendingOperation()
            try await f.store.save(try plan(for: operation))
            _ = try await f.authority.complete(operation, at: Date(timeIntervalSince1970: 1_800_000_001))
            await #expect(throws: MiraError.self) { _ = try await f.store.load(operation: operation) }
            await f.store.close()
            await #expect(throws: MiraError.self) { _ = try await f.store.load(operation: operation) }
        }
    }

    private struct Fixture {
        let database: DatabaseQueue
        let authority: SQLiteLibraryAuthority
        let store: SQLiteSessionPrivacyPlanStore
        func pendingOperation() async throws -> AgentLibraryMaintenanceOperation {
            try await SQLiteSessionPrivacyPlanStoreTests.begin(authority: authority)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-privacy-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
        let database = try DatabaseQueue(
            path: directory.appendingPathComponent("business.sqlite").path, configuration: configuration)
        let authority = try SQLiteLibraryAuthority(database: database)
        let store = try SQLiteSessionPrivacyPlanStore(database: database, libraryID: authority.libraryID)
        do {
            try await body(.init(database: database, authority: authority, store: store))
            await store.close()
            await authority.close()
            try database.close()
        } catch {
            await store.close()
            await authority.close()
            try? database.close()
            throw error
        }
    }

    private static func begin(authority: SQLiteLibraryAuthority) async throws -> AgentLibraryMaintenanceOperation {
        let auth = try await authority.authorization()
        let request = AgentLibraryMaintenanceRequest(
            id: UUID(), namespace: "session.privacy",
            revision: 1, scope: .library, requestedAt: Date(timeIntervalSince1970: 1_800_000_000))
        return try await authority.begin(request, expected: auth)
    }

    private func plan(
        for operation: AgentLibraryMaintenanceOperation,
        sessions: [(ConversationID, [(ExecutionID, [AgentSourceReference])])] = []
    ) throws -> SessionPrivacyPlan {
        let root = AgentSourceReference.domain(namespace: "memory", id: UUID(), revision: 1)
        let entries = sessions.isEmpty ? [(ConversationID(), [(ExecutionID(), [root])])] : sessions
        let heads = entries.map { SessionJournalHead(cursor: .init(sessionID: $0.0, sequence: 1), batchID: UUID()) }
        let changes = zip(entries, heads).map { entry, head in
            let facts = SessionInvalidation(
                operationID: operation.request.id,
                executionIDs: Set(entry.1.map(\.0)), retentionGroups: [UUID()],
                authorizationEpoch: operation.authorization.epoch,
                reason: .forgotten)
            let event = SessionEvent(sequence: 2, occurredAt: operation.request.requestedAt, fact: .invalidated(facts))
            let batch = SessionBatch(id: UUID(), sessionID: entry.0, expectedSequence: 1, events: [event])
            return SessionPrivacyChange(
                batch: batch, dependencies: entry.1.map { .init(executionID: $0.0, sources: $0.1) })
        }
        return .init(
            operation: operation, roots: [root], retention: .preserveVisibleHistory,
            reason: .forgotten, heads: heads, changes: changes)
    }
}
