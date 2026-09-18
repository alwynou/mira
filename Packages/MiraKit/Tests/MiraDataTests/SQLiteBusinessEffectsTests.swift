import Foundation
import Testing
import GRDB
@testable import MiraCore
@testable import MiraData

private func sharedBusinessDatabase(path: String) throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA synchronous = FULL") }
    return try DatabaseQueue(path: path, configuration: configuration)
}

private func syntheticContext(sessionID: ConversationID, executionID: ExecutionID, invocationID: UUID, text: String) -> AgentToolContext {
    let batchID = UUID()
    let body = SessionContent(id: UUID(), kind: .userText, bytes: Data(text.utf8))
    let evidence = SessionUserEvidence(reference: .init(sessionID: sessionID, originalExecutionID: executionID, userMessageID: MessageID(), admissionEventID: UUID(), admissionSequence: 1), workspaceID: nil, admittedAt: Date(timeIntervalSince1970: 1), timeZoneIdentifier: "UTC", text: text, observedHead: .init(cursor: .init(sessionID: sessionID, sequence: 1), batchID: batchID), sessionAuthorizationEpoch: 0)
    let route = AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1, modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1, adapter: .init(id: "synthetic.model", revision: 1), invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", modelID: "synthetic", credential: nil, contextWindow: 4096, maximumOutputTokens: 128, capabilities: .init(streamsText: true, callsTools: true, producesThinking: false), configuration: .object([:]))
    return .init(executionID: executionID, invocationID: invocationID, evidence: evidence, route: route)
}

@Suite("SQLite business effects", .timeLimit(.minutes(1)))
struct SQLiteBusinessEffectsTests {
    @Test func sharedBusinessDatabasePreservesConsumerAndDomainOwnership() async throws {
        try await withFixture { fixture in
            let consumer = try SQLiteSessionConsumer(database: fixture.database,
                identity: .init(id: "tests.shared", revision: 1), handler: SharedConsumerHandler())
            do {
                guard case .committed = await fixture.store.commit(fixture.proof) else {
                    Issue.record("The shared business commit failed"); await consumer.close(); return
                }
                try await fixture.store.close()
                let batchID = UUID()
                let title = SessionContent(id: UUID(), kind: .title, bytes: Data("t".utf8))
                let batch = SessionBatch(id: batchID, sessionID: fixture.sessionID, expectedSequence: 0,
                    events: [.init(id: UUID(), sequence: 1, occurredAt: Date(timeIntervalSince1970: 1),
                                   fact: .opened(.init(workspaceID: nil, title: title)))])
                let delivery = AgentSessionConsumerDelivery(consumer: consumer.identity,
                    previous: .init(cursor: .init(sessionID: fixture.sessionID, sequence: 0), batchID: nil), batch: batch)
                #expect(try await consumer.consume(delivery) == delivery.checkpoint)
                #expect(try await consumer.checkpoint(sessionID: fixture.sessionID) == delivery.checkpoint)
                #expect(try fixture.count() == 1)
                let value = try await fixture.database.read { try String.fetchOne($0, sql: "SELECT value FROM unrelated_sentinel WHERE id = 1") }
                #expect(value == "keep")
                await consumer.close()
                try await fixture.database.write { try $0.execute(sql: "CREATE TABLE final_owner_write (id INTEGER PRIMARY KEY)") }
            } catch {
                await consumer.close(); throw error
            }
        }
    }

    @Test func closeDrainsSuspendedPublicationValidation() async throws {
        try await withFixture { fixture in
            guard case .committed(let receipt) = await fixture.store.commit(fixture.proof) else {
                Issue.record("The business commit failed"); return
            }
            await fixture.resolver.blockPublication()
            let acknowledgement = Task {
                try await fixture.store.acknowledge(receipt.reference,
                    at: .init(sessionID: fixture.sessionID, sequence: 1))
            }
            await fixture.resolver.waitUntilPublicationEntered()
            let completion = CloseCompletion()
            let closing = Task { try await fixture.store.close(); await completion.markFinished() }
            for _ in 0..<10_000 {
                if fixture.store.isClosing { break }
                await Task.yield()
            }
            #expect(fixture.store.isClosing)
            #expect(await completion.finished == false)
            await fixture.resolver.releasePublication()
            try await acknowledgement.value
            try await closing.value
            let acknowledged = try await fixture.database.read { try Int.fetchOne($0, sql: "SELECT acknowledged FROM business_receipts") }
            #expect(acknowledged == 1)
            #expect(await completion.finished)
        }
    }

    @Test func normalSynchronousDatabaseIsRejectedBeforeOwnedWrites() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("business-normal-\(UUID().uuidString).sqlite").path
        let database = try sharedBusinessDatabase(path: path)
        let authority = try SQLiteLibraryAuthority(database: database)
        defer { try? database.close(); try? FileManager.default.removeItem(atPath: path) }
        try await database.write { db in try db.execute(sql: "CREATE TABLE unrelated_sentinel (id INTEGER PRIMARY KEY, value TEXT NOT NULL)") }
        try await database.writeWithoutTransaction { try $0.execute(sql: "PRAGMA synchronous = NORMAL") }
        #expect(throws: MiraError.self) {
            try SQLiteBusinessEffects(database: database, libraryID: authority.libraryID, resolver: FixtureResolver(), handlers: [CounterHandler(failure: false, invalidResult: false)], validator: FixtureValidator())
        }
        let owned = try await database.read { db in try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = 'business_effects_metadata')") == true }
        #expect(!owned)
        await authority.close()
        try database.close()
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test func closeDrainsAfterCommitHookAndLeavesSharedDatabaseUsable() async throws {
        let hook = BlockingCommitHook()
        try await withFixture(afterCommitHook: { hook.enterAndWait() }) { fixture in
            let commit = Task { await fixture.store.commit(fixture.proof) }
            await hook.waitUntilEntered()
            let completion = CloseCompletion()
            let closing = Task { try await fixture.store.close(); await completion.markFinished() }
            for _ in 0..<10_000 {
                if fixture.store.isClosing { break }
                await Task.yield()
            }
            #expect(fixture.store.isClosing)
            #expect(await completion.finished == false)
            #expect(!hook.finished)
            hook.release()
            let outcome = await commit.value
            guard case .committed = outcome else { Issue.record("The owned commit failed"); try await closing.value; return }
            try await closing.value
            #expect(hook.finished)
            #expect(await completion.finished)
            #expect(try fixture.count() == 1)
            try await fixture.database.write { db in
                try db.execute(sql: "CREATE TABLE shared_after_close (id INTEGER PRIMARY KEY)")
            }
        }
    }

    @Test func foreignKeysOffAndPartialOwnedSchemaAreRejected() async throws {
        let offPath = FileManager.default.temporaryDirectory.appendingPathComponent("business-fk-off-\(UUID().uuidString).sqlite").path
        let offDB = try sharedBusinessDatabase(path: offPath)
        let offAuthority = try SQLiteLibraryAuthority(database: offDB)
        try await offDB.writeWithoutTransaction { try $0.execute(sql: "PRAGMA foreign_keys = OFF") }
        defer { try? offDB.close(); try? FileManager.default.removeItem(atPath: offPath) }
        #expect(throws: MiraError.self) {
            try SQLiteBusinessEffects(database: offDB, libraryID: offAuthority.libraryID, resolver: FixtureResolver(), handlers: [CounterHandler(failure: false, invalidResult: false)], validator: FixtureValidator())
        }
        await offAuthority.close()
        try offDB.close(); try? FileManager.default.removeItem(atPath: offPath)

        let partialPath = FileManager.default.temporaryDirectory.appendingPathComponent("business-partial-\(UUID().uuidString).sqlite").path
        let partialDB = try sharedBusinessDatabase(path: partialPath)
        defer { try? partialDB.close(); try? FileManager.default.removeItem(atPath: partialPath) }
        let partialAuthority = try SQLiteLibraryAuthority(database: partialDB)
        try await partialDB.write { db in try db.execute(sql: "CREATE TABLE business_effects_metadata (id INTEGER PRIMARY KEY)") }
        #expect(throws: MiraError.self) {
            try SQLiteBusinessEffects(database: partialDB, libraryID: partialAuthority.libraryID, resolver: FixtureResolver(), handlers: [CounterHandler(failure: false, invalidResult: false)], validator: FixtureValidator())
        }
        await partialAuthority.close()
        try partialDB.close(); try? FileManager.default.removeItem(atPath: partialPath)
    }

    @Test func mismatchedLibraryAuthorityIsRejectedBeforeOwnedSchema() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("business-authority-mismatch-\(UUID().uuidString).sqlite").path
        let database = try sharedBusinessDatabase(path: path)
        var authority: SQLiteLibraryAuthority?
        do {
            authority = try SQLiteLibraryAuthority(database: database)
            do {
                _ = try SQLiteBusinessEffects(database: database, libraryID: UUID(), resolver: FixtureResolver(),
                    handlers: [CounterHandler(failure: false, invalidResult: false)], validator: FixtureValidator())
                Issue.record("A different library identity was accepted")
            } catch let error as MiraError {
                #expect(error == MiraError(.storage, "The library authority metadata is invalid."))
            }
            let owned = try await database.read { db in
                try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = 'business_effects_metadata')") == true
            }
            #expect(!owned)
            await authority?.close()
            try database.close()
            try? FileManager.default.removeItem(atPath: path)
        } catch {
            await authority?.close(); try? database.close(); try? FileManager.default.removeItem(atPath: path)
            throw error
        }
    }

    @Test func duplicateInvocationAppliesOnce() async throws {
        try await withFixture { f in
            let a = await f.store.commit(f.proof)
            let b = await f.store.commit(f.proof)
            guard case .committed = a else { Issue.record("Initial commit did not commit"); return }
            #expect(a == b)
            let countAfter = try f.count()
            #expect(countAfter == 1)
        }
    }

    @Test func differentInvocationsShareBusinessOperation() async throws {
        try await withFixture { f in
            guard case let .committed(a) = await f.store.commit(f.proof),
                  case let .committed(b) = await f.store.commit(try await f.nextProof()) else {
                Issue.record("Expected commits to succeed"); return
            }
            #expect(a.result == b.result)
            let count = try f.count()
            #expect(count == 1)
        }
    }

    @Test func handlerAndOutputFailuresRollbackDomainMutation() async throws {
        for handler in [CounterHandler(failure: true, invalidResult: false), CounterHandler(failure: false, invalidResult: true)] {
            try await withFixture(handler: handler) { f in
                if case .committed = await f.store.commit(f.proof) { Issue.record("Invalid effect committed") }
                let count = try f.count()
                #expect(count == 0)
            }
        }
    }

    @Test func postCommitFailureIsIndeterminateAndReceiptRecovers() async throws {
        try await withFixture(afterCommitHook: { throw HookFailure.failed }) { f in
            guard case .indeterminate = await f.store.commit(f.proof) else { Issue.record("Expected uncertainty"); return }
            guard case let .committed(receipt) = await f.store.receipt(for: f.proof) else { Issue.record("Receipt missing"); return }
            #expect(receipt.result != nil)
            let count = try f.count()
            #expect(count == 1)
        }
    }

    @Test func mismatchedProofLookupIsUnavailable() async throws {
        try await withFixture { f in
            _ = await f.store.commit(f.proof)
            let bad = AgentEffectProof(sessionID: f.proof.sessionID, executionID: f.proof.executionID,
                invocationID: f.proof.invocationID, intentBatchID: f.proof.intentBatchID,
                intentSequence: f.proof.intentSequence + 1, authorization: f.proof.authorization,
                proposal: f.proof.proposal)
            guard case .unavailable = await f.store.receipt(for: bad) else { Issue.record("Mismatch accepted"); return }
        }
    }

    @Test func acknowledgementRemovesOutboxAfterResolverValidation() async throws {
        try await withFixture { f in
            guard case let .committed(receipt) = await f.store.commit(f.proof) else { Issue.record("Commit failed"); return }
            var denied = false
            do { try await f.store.acknowledge(receipt.reference, at: .init(sessionID: f.sessionID, sequence: 1)) }
            catch { denied = true }
            #expect(denied)
            await f.resolver.setPublicationAllowed(true)
            try await f.store.acknowledge(receipt.reference, at: .init(sessionID: f.sessionID, sequence: 1))
            let publications = try await f.store.unpublished(after: nil, limit: 10)
            #expect(publications.isEmpty)
        }
    }
}

private func withFixture<T>(
    handler: CounterHandler = .init(failure: false, invalidResult: false),
    afterCommitHook: (@Sendable () throws -> Void)? = nil,
    _ body: (Fixture) async throws -> T
) async throws -> T {
    let fixture = try await Fixture.make(handler: handler, afterCommitHook: afterCommitHook)
    do {
        let result = try await body(fixture)
        await fixture.resolver.releasePublication()
        try await fixture.store.close()
        await fixture.authority.close()
        try fixture.database.close()
        try? FileManager.default.removeItem(atPath: fixture.path)
        return result
    } catch {
        await fixture.resolver.releasePublication()
        try? await fixture.store.close()
        await fixture.authority.close()
        try? fixture.database.close()
        try? FileManager.default.removeItem(atPath: fixture.path)
        throw error
    }
}

private func withOpenedStore<T>(
    path: String,
    resolver: FixtureResolver,
    handler: CounterHandler,
    _ body: (SQLiteBusinessEffects) async throws -> T
) async throws -> T {
    let database = try sharedBusinessDatabase(path: path)
    let authority = try SQLiteLibraryAuthority(database: database)
    var store: SQLiteBusinessEffects?
    do {
        let openedStore = try SQLiteBusinessEffects(database: database, libraryID: authority.libraryID, resolver: resolver, handlers: [handler], validator: FixtureValidator())
        store = openedStore
        let result = try await body(openedStore)
        try await openedStore.close()
        await authority.close()
        try database.close()
        return result
    } catch {
        if let store { try? await store.close() }
        await authority.close()
        try? database.close()
        throw error
    }
}

private enum HookFailure: Error { case failed }

private actor CloseCompletion {
    private(set) var finished = false
    func markFinished() { finished = true }
}

private final class BlockingCommitHook: @unchecked Sendable {
    private let releaseGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didEnter = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var didFinish = false
    var finished: Bool { lock.withLock { didFinish } }
    func enterAndWait() {
        let pending = lock.withLock {
            didEnter = true
            let pending = waiters; waiters.removeAll(); return pending
        }
        pending.forEach { $0.resume() }
        releaseGate.wait()
        lock.withLock { didFinish = true }
    }
    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let entered = lock.withLock {
                if didEnter { return true }
                waiters.append(continuation); return false
            }
            if entered { continuation.resume() }
        }
    }
    func release() { releaseGate.signal() }
}

private actor FixtureResolver: AgentEffectIntentResolver {
    private var effects: [UUID: AgentResolvedEffect] = [:]
    private var allowPublication = false
    private var publicationBlocked = false
    private var publicationEntered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func blockPublication() { allowPublication = true; publicationBlocked = true }
    func waitUntilPublicationEntered() async {
        if publicationEntered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func releasePublication() {
        publicationBlocked = false
        let pending = releaseWaiters; releaseWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
    func set(_ effect: AgentResolvedEffect, for id: UUID) { effects[id] = effect }
    func setPublicationAllowed(_ value: Bool) { allowPublication = value }
    func resolve(_ proof: AgentEffectProof, requireEligible: Bool) async throws -> AgentResolvedEffect {
        guard let effect = effects[proof.invocationID] else { throw MiraError(.notFound, "Synthetic effect missing.") }
        return effect
    }
    func validatePublication(_ receipt: AgentBusinessReceiptReference, at cursor: SessionCursor) async throws {
        guard allowPublication else { throw MiraError(.unauthorized, "Synthetic publication denied.") }
        publicationEntered = true
        let pending = entryWaiters; entryWaiters.removeAll(); pending.forEach { $0.resume() }
        while publicationBlocked { await withCheckedContinuation { releaseWaiters.append($0) } }
    }
}

private struct CounterHandler: SQLiteBusinessCommandHandler {
    let failure: Bool
    let invalidResult: Bool
    let namespace = "tests"
    func businessKey(for effect: AgentResolvedEffect) throws -> String { "same-business-key" }
    func apply(effect: AgentResolvedEffect, in db: Database) throws -> JSONValue {
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS synthetic_counter (id INTEGER PRIMARY KEY CHECK(id = 1), count INTEGER NOT NULL)")
        try db.execute(sql: "INSERT OR IGNORE INTO synthetic_counter(id, count) VALUES (1, 0)")
        try db.execute(sql: "UPDATE synthetic_counter SET count = count + 1 WHERE id = 1")
        if failure { throw MiraError(.storage, "Synthetic handler failed.") }
        return invalidResult ? .object(["wrong": .bool(true)]) : .object(["ok": .bool(true)])
    }
}

private struct FixtureValidator: SQLiteBusinessAuthorizationValidator {
    func validate(effect: AgentResolvedEffect, isReplay: Bool, in db: Database) throws {}
}

private struct Fixture {
    let store: SQLiteBusinessEffects
    let authority: SQLiteLibraryAuthority
    let resolver: FixtureResolver
    let handler: CounterHandler
    let path: String
    let database: DatabaseQueue
    let proof: AgentEffectProof
    let sessionID: ConversationID
    let executionID: ExecutionID
    let proposal: AgentToolProposal

    static func make(handler: CounterHandler = .init(failure: false, invalidResult: false),
                     afterCommitHook: (@Sendable () throws -> Void)? = nil) async throws -> Fixture {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("business-\(UUID().uuidString).sqlite").path
        let resolver = FixtureResolver()
        let database = try sharedBusinessDatabase(path: path)
        try await database.write { db in
            try db.execute(sql: "CREATE TABLE unrelated_sentinel (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO unrelated_sentinel(id, value) VALUES (1, 'keep')")
        }
        let authority = try SQLiteLibraryAuthority(database: database)
        var ownedStore: SQLiteBusinessEffects?
        do {
            let store = try SQLiteBusinessEffects(database: database, libraryID: authority.libraryID, resolver: resolver, handlers: [handler], validator: FixtureValidator(), afterCommitHook: afterCommitHook)
            ownedStore = store
            let auth = try await authority.authorization()
            let sessionID = ConversationID(), executionID = ExecutionID(), invocationID = UUID(), batchID = UUID()
            let proposal = Self.proposal()
            let context = syntheticContext(sessionID: sessionID, executionID: executionID, invocationID: invocationID, text: "synthetic")
            await resolver.set(.init(proposal: proposal, context: context), for: invocationID)
            let proof = AgentEffectProof(sessionID: sessionID, executionID: executionID, invocationID: invocationID, intentBatchID: batchID, intentSequence: 1, authorization: auth, proposal: Self.reference(sessionID, batchID: batchID))
            return .init(store: store, authority: authority, resolver: resolver, handler: handler, path: path, database: database, proof: proof, sessionID: sessionID, executionID: executionID, proposal: proposal)
        } catch {
            if let ownedStore { try? await ownedStore.close() }
            await authority.close(); try? database.close(); try? FileManager.default.removeItem(atPath: path)
            throw error
        }
    }

    func nextProof() async throws -> AgentEffectProof {
        let invocation = UUID()
        let context = syntheticContext(sessionID: sessionID, executionID: executionID, invocationID: invocation, text: "synthetic")
        await resolver.set(.init(proposal: proposal, context: context), for: invocation)
        let batchID = UUID()
        return .init(sessionID: sessionID, executionID: executionID, invocationID: invocation, intentBatchID: batchID, intentSequence: 2, authorization: try await authority.authorization(), proposal: Self.reference(sessionID, batchID: batchID))
    }

    func count() throws -> Int {
        return try database.read {
            guard try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'synthetic_counter')") == true else { return 0 }
            return try Int.fetchOne($0, sql: "SELECT count FROM synthetic_counter WHERE id = 1") ?? 0
        }
    }
    private static func reference(_ sessionID: ConversationID, batchID: UUID) -> SessionContent {
        .init(id: UUID(), kind: .effectIntent, bytes: Data("effect".utf8))
    }
    private static func proposal() -> AgentToolProposal {
        let output: JSONValue = .object(["type": .string("object"), "properties": .object(["ok": .object(["type": .string("boolean")])]), "required": .array([.string("ok")]), "additionalProperties": .bool(false)])
        let input: JSONValue = .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])
        let descriptor = AgentToolDescriptor(definition: .init(name: "tests.write", description: "Synthetic write", inputSchema: input), revision: 1, outputSchema: output, executionMode: .exclusive, timeoutMilliseconds: 1_000, maximumResultBytes: 1_024)
        return .init(descriptor: descriptor, effect: .localWrite, businessNamespace: "tests", callDigest: String(repeating: "a", count: 64), plan: .init(input: .object([:]), sources: [], targets: []))
    }
}

private struct SharedConsumerHandler: SQLiteSessionConsumerHandler {
    func prepare(_ delivery: AgentSessionConsumerDelivery) async throws -> any SQLiteSessionConsumerTransaction {
        SharedConsumerTransaction()
    }
}

private struct SharedConsumerTransaction: SQLiteSessionConsumerTransaction {
    func apply(in db: Database) throws {
        guard try Int.fetchOne(db, sql: "SELECT count(*) FROM business_receipts") == 1 else {
            throw MiraError(.storage, "The shared business receipt is missing.")
        }
        try db.execute(sql: "CREATE TABLE consumer_job (id INTEGER PRIMARY KEY)")
        try db.execute(sql: "INSERT INTO consumer_job VALUES (1)")
    }
    func close() async {}
}
