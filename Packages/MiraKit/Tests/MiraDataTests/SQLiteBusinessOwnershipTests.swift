import Foundation
import Testing
import GRDB
@testable import MiraCore
@testable import MiraData

private func ownershipDatabase(path: String) throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA synchronous = FULL") }
    return try DatabaseQueue(path: path, configuration: configuration)
}

private func ownershipContext(sessionID: ConversationID, executionID: ExecutionID, invocationID: UUID) -> AgentToolContext {
    let batchID = UUID()
    let body = SessionPayloadReference(id: UUID(), sessionID: sessionID, batchID: batchID, retentionGroup: UUID(), kind: .userText, byteCount: 5, digest: String(repeating: "0", count: 64))
    let evidence = SessionUserEvidence(reference: .init(sessionID: sessionID, originalExecutionID: executionID, userMessageID: MessageID(), admissionEventID: UUID(), admissionSequence: 1, body: body), workspaceID: nil, admittedAt: Date(timeIntervalSince1970: 1), timeZoneIdentifier: "UTC", text: "owner", observedHead: .init(cursor: .init(sessionID: sessionID, sequence: 1), batchID: batchID), sessionAuthorizationEpoch: 0)
    let route = AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1, modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1, adapter: .init(id: "synthetic.model", revision: 1), invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", metadataEvidence: [], modelID: "synthetic", credential: nil, contextWindow: 4096, maximumOutputTokens: 128, capabilities: .init(streamsText: true, callsTools: true, producesThinking: false), configuration: .object([:]))
    return .init(executionID: executionID, invocationID: invocationID, evidence: evidence, route: route)
}

@Suite("SQLite business commit ownership", .timeLimit(.minutes(1)))
struct SQLiteBusinessOwnershipTests {
    @Test func concurrentSameProofResolvesAndAppliesOnce() async throws {
        try await withOwnershipFixture { f in
            let first = Task { await f.store.commit(f.proof) }
            await f.resolver.waitUntilEntered()
            let second = Task { await f.store.commit(f.proof) }
            await f.resolver.open()
            let a = await first.value, b = await second.value
            guard case .committed = a, case .committed = b else { Issue.record("Owned commits did not commit"); return }
            #expect(a == b)
            let count = try f.count()
            #expect(count == 1)
            #expect(await f.resolver.resolveCount == 1)
        }
    }

    @Test func fenceWaitsForResolverThenDeniesBeforeMutation() async throws {
        try await withOwnershipFixture { f in
            let commit = Task { await f.store.commit(f.proof) }
            await f.resolver.waitUntilEntered()
            try await f.store.fenceExecution(sessionID: f.proof.sessionID, executionID: f.proof.executionID)
            await f.resolver.open()
            guard case .notCommitted = await commit.value else { Issue.record("Fenced commit succeeded"); return }
            let count = try f.count()
            #expect(count == 0)
            guard case .absent = await f.store.receipt(for: f.proof) else { Issue.record("Fenced receipt exists"); return }
        }
    }

    @Test func closeDrainsResolverOwnedCommitBeforeReturning() async throws {
        try await withOwnershipFixture { f in
            guard case let .notCommitted(error) = await f.store.commit(f.probeProof()), error.code == .notFound else {
                Issue.record("Probe should reach resolver before close")
                return
            }
            let commit = Task { await f.store.commit(f.proof) }
            await f.resolver.waitUntilEntered()
            _ = try await f.store.unpublished(after: nil, limit: 1)
            let probe = CompletionProbe()
            let closing = Task { try await f.store.close(); await probe.markFinished() }
            var sawClosing = false
            for _ in 0..<1_000 {
                let probe = await f.store.commit(f.probeProof())
                if case let .notCommitted(error) = probe, error.code == .storage {
                    sawClosing = true
                    break
                }
                await Task.yield()
            }
            #expect(sawClosing)
            #expect(await probe.isFinished == false)
            await f.resolver.open()
            guard case .committed = await commit.value else { Issue.record("Owned commit did not drain"); return }
            try await closing.value
            #expect(await probe.isFinished)
            try await f.database.write { try $0.execute(sql: "CREATE TABLE after_owner_close (id INTEGER PRIMARY KEY)") }
            guard case let .notCommitted(error) = await f.store.commit(f.probeProof()), error.code == .storage else {
                Issue.record("Closed store accepted a new commit")
                return
            }
        }
    }

    @Test func receiptLookupWaitsForOwnedCommit() async throws {
        try await withOwnershipFixture { f in
            let commit = Task { await f.store.commit(f.proof) }
            await f.resolver.waitUntilEntered()
            let probe = CompletionProbe()
            let lookup = Task {
                await probe.markStarted()
                let result = await f.store.receipt(for: f.proof)
                await probe.markFinished()
                return result
            }
            var started = false
            for _ in 0..<1_000 {
                if await probe.isStarted { started = true; break }
                await Task.yield()
            }
            #expect(started)
            #expect(await probe.isFinished == false)
            await f.resolver.open()
            guard case .committed = await commit.value else { Issue.record("Commit failed"); return }
            guard case .committed = await lookup.value else { Issue.record("Lookup raced to absence"); return }
        }
    }

    @Test func maintenancePendingDuringResolverReadCannotCommitStaleProof() async throws {
        try await withOwnershipFixture { f in
            let commit = Task { await f.store.commit(f.proof) }
            let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !(await f.resolver.hasEntered) {
                guard clock.now < deadline else { throw MiraError(.timeout, "The resolver did not enter the maintenance race.") }
                try await Task.sleep(for: .milliseconds(1))
            }
            let operation = try await f.authority.begin(
                .init(id: UUID(), namespace: "tests.invalidate", revision: 1, scope: .library, requestedAt: Date()),
                expected: f.proof.authorization)
            let resolved = f.resolver.effect
            do {
                _ = try await f.store.authorization(for: resolved.proposal, context: resolved.context)
                Issue.record("Pending maintenance granted a fresh business authorization")
            } catch let error as MiraError {
                #expect(error.code == .unauthorized)
                #expect(error.message == "Library maintenance prevents new authorization.")
            }
            await f.resolver.open()
            guard case .notCommitted(let error) = await commit.value else {
                Issue.record("A stale proof committed while library maintenance was pending")
                return
            }
            #expect(error.code == .unauthorized)
            #expect(error.message == "Library maintenance prevents new authorization.")
            #expect(try f.count() == 0)
            _ = try await f.authority.complete(operation, at: Date())
            guard case .notCommitted(let stale) = await f.store.commit(f.proof) else {
                Issue.record("The old proof committed after maintenance completion")
                return
            }
            #expect(stale.code == .unauthorized)
            #expect(stale.message == "Business authorization is stale.")
            #expect(await f.resolver.resolveCount == 1)
            #expect(try f.count() == 0)
            guard case .absent = await f.store.receipt(for: f.proof) else {
                Issue.record("The rejected proof created a business receipt")
                return
            }
        }
    }
}

private func withOwnershipFixture<T>(_ body: (OwnershipFixture) async throws -> T) async throws -> T {
    let fixture = try await OwnershipFixture.make()
    do {
        let result = try await body(fixture)
        await fixture.resolver.open()
        try await fixture.store.close()
        await fixture.authority.close()
        try fixture.database.close()
        try? FileManager.default.removeItem(atPath: fixture.path)
        return result
    } catch {
        await fixture.resolver.open()
        try? await fixture.store.close()
        await fixture.authority.close()
        try? fixture.database.close()
        try? FileManager.default.removeItem(atPath: fixture.path)
        throw error
    }
}

private actor CompletionProbe {
    private var started = false
    private var finished = false
    func markStarted() { started = true }
    func markFinished() { finished = true }
    var isStarted: Bool { started }
    var isFinished: Bool { finished }
}

private actor GatedResolver: AgentEffectIntentResolver {
    let effect: AgentResolvedEffect
    private var openGate = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var resolveCount = 0
    var isOpen: Bool { openGate }
    var hasEntered: Bool { entered }
    init(effect: AgentResolvedEffect) { self.effect = effect }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        openGate = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
    }
    func resolve(_ proof: AgentEffectProof, requireEligible: Bool) async throws -> AgentResolvedEffect {
        guard proof.invocationID == effect.context.invocationID else {
            throw MiraError(.notFound, "Synthetic effect was not registered.")
        }
        resolveCount += 1; entered = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
        while !openGate { await withCheckedContinuation { waiters.append($0) } }
        return effect
    }
    func validatePublication(_ receipt: AgentBusinessReceiptReference, at cursor: SessionCursor) async throws {}
}

private struct OwnershipHandler: SQLiteBusinessCommandHandler {
    let namespace = "tests"
    func businessKey(for effect: AgentResolvedEffect) throws -> String { "ownership-key" }
    func apply(effect: AgentResolvedEffect, in db: Database) throws -> JSONValue {
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS ownership_counter (id INTEGER PRIMARY KEY CHECK(id = 1), count INTEGER NOT NULL)")
        try db.execute(sql: "INSERT OR IGNORE INTO ownership_counter(id, count) VALUES (1, 0)")
        try db.execute(sql: "UPDATE ownership_counter SET count = count + 1 WHERE id = 1")
        return .object(["ok": .bool(true)])
    }
}

private struct OwnershipValidator: SQLiteBusinessAuthorizationValidator {
    func validate(effect: AgentResolvedEffect, isReplay: Bool, in db: Database) throws {}
}

private final class OwnershipFixture: Sendable {
    let store: SQLiteBusinessEffects
    let authority: SQLiteLibraryAuthority
    let resolver: GatedResolver
    let path: String
    let database: DatabaseQueue
    let proof: AgentEffectProof
    let sessionID: ConversationID

    init(store: SQLiteBusinessEffects, authority: SQLiteLibraryAuthority, resolver: GatedResolver, path: String, database: DatabaseQueue,
         proof: AgentEffectProof, sessionID: ConversationID) {
        self.store = store; self.authority = authority; self.resolver = resolver; self.path = path
        self.database = database
        self.proof = proof; self.sessionID = sessionID
    }

    static func make() async throws -> OwnershipFixture {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mira-business-owner-\(UUID().uuidString).sqlite").path
        let sessionID = ConversationID(), executionID = ExecutionID(), invocationID = UUID(), batchID = UUID()
        let input = JSONValue.object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])
        let output = JSONValue.object(["type": .string("object"), "properties": .object(["ok": .object(["type": .string("boolean")])]), "required": .array([.string("ok")]), "additionalProperties": .bool(false)])
        let descriptor = AgentToolDescriptor(definition: .init(name: "tests.write", description: "Ownership test", inputSchema: input), revision: 1, outputSchema: output, executionMode: .exclusive, timeoutMilliseconds: 1000, maximumResultBytes: 1024)
        let proposal = AgentToolProposal(descriptor: descriptor, effect: .localWrite, businessNamespace: "tests", callDigest: String(repeating: "a", count: 64), inheritedSources: [], plan: .init(input: .object([:]), sources: [], targets: []))
        let context = ownershipContext(sessionID: sessionID, executionID: executionID, invocationID: invocationID)
        let resolver = GatedResolver(effect: .init(proposal: proposal, context: context))
        let database = try ownershipDatabase(path: path)
        let authority = try SQLiteLibraryAuthority(database: database)
        var ownedStore: SQLiteBusinessEffects?
        do {
            let store = try SQLiteBusinessEffects(database: database, libraryID: authority.libraryID, resolver: resolver, handlers: [OwnershipHandler()], validator: OwnershipValidator())
            ownedStore = store
            let auth = try await authority.authorization()
            let reference = SessionPayloadReference(id: UUID(), sessionID: sessionID, batchID: batchID, retentionGroup: UUID(), kind: .effectIntent, byteCount: 1, digest: String(repeating: "0", count: 64))
            let proof = AgentEffectProof(sessionID: sessionID, executionID: executionID, invocationID: invocationID, intentBatchID: batchID, intentSequence: 1, authorization: auth, proposal: reference)
            return .init(store: store, authority: authority, resolver: resolver, path: path, database: database, proof: proof, sessionID: sessionID)
        } catch {
            if let ownedStore { try? await ownedStore.close() }
            await authority.close(); try? database.close(); try? FileManager.default.removeItem(atPath: path)
            throw error
        }
    }

    func count() throws -> Int {
        return try database.read {
            guard try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'ownership_counter')") == true else { return 0 }
            return try Int.fetchOne($0, sql: "SELECT count FROM ownership_counter WHERE id = 1") ?? 0
        }
    }

    func probeProof() -> AgentEffectProof {
        AgentEffectProof(sessionID: proof.sessionID, executionID: proof.executionID, invocationID: UUID(), intentBatchID: proof.intentBatchID, intentSequence: proof.intentSequence, authorization: proof.authorization, proposal: proof.proposal)
    }
}
