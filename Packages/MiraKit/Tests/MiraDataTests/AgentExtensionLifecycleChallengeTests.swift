import Foundation
import GRDB
import MiraCore
import MiraData
import Testing

@Suite("Agent extension persistence and lifecycle challenges", .timeLimit(.minutes(1)))
struct AgentExtensionLifecycleChallengeTests {
    @Test func observerReconnectsAndProjectionRebuildDoesNotReplay() async throws {
        let fixture = try await ObserverFixture.make(batchCount: 3)
        do {
            let first = try await fixture.coordinator.advance(
                consumerID: fixture.consumer.identity.id,
                sessionID: fixture.sessionID)
            #expect(first.checkpoint.head.cursor.sequence == 3)
            #expect(try fixture.rows() == [1, 2, 3])
            #expect(await fixture.block.prepares == 3)
            await fixture.coordinator.close()
            await fixture.consumer.close()
            try await fixture.library.close()
            await fixture.scope.dispose()
            try fixture.database.close()

            let reopened = try await ObserverFixture.reopen(fixture)
            do {
                let nextID = UUID()
                let next = SessionBatch(
                    id: nextID, sessionID: reopened.sessionID, expectedSequence: 3,
                    events: [
                        .init(
                            sequence: 4, occurredAt: Date(timeIntervalSince1970: 4),
                            fact: .archived(revision: 4))
                    ])
                guard case .committed = await reopened.library.append(next) else {
                    throw MiraError(.storage, "The synthetic suffix batch was not committed.")
                }
                let replay = try await reopened.coordinator.advance(
                    consumerID: reopened.consumer.identity.id,
                    sessionID: reopened.sessionID)
                #expect(replay.processedBatches == 1)
                #expect(try reopened.rows() == [1, 2, 3, 4])
                let projectionURL = fixture.directory.appendingPathComponent("query.sqlite")
                try await rebuildObserverProjection(
                    library: reopened.library, sessionID: reopened.sessionID, url: projectionURL)
                try FileManager.default.removeItem(at: projectionURL)
                try await rebuildObserverProjection(
                    library: reopened.library, sessionID: reopened.sessionID, url: projectionURL)
                #expect(try reopened.rows() == [1, 2, 3, 4])
                let unchanged = try await reopened.coordinator.advance(
                    consumerID: reopened.consumer.identity.id,
                    sessionID: reopened.sessionID)
                #expect(unchanged.processedBatches == 0)
                #expect(await reopened.block.prepares == 1)
                await reopened.coordinator.close()
                await reopened.consumer.close()
                try await reopened.library.close()
                await reopened.scope.dispose()
                try reopened.database.close()
            } catch {
                await reopened.coordinator.close()
                await reopened.consumer.close()
                try? await reopened.library.close()
                await reopened.scope.dispose()
                try? reopened.database.close()
                throw error
            }
            try FileManager.default.removeItem(at: fixture.directory)
        } catch {
            await fixture.coordinator.close()
            await fixture.consumer.close()
            try? await fixture.library.close()
            await fixture.scope.dispose()
            try? fixture.database.close()
            try? FileManager.default.removeItem(at: fixture.directory)
            throw error
        }
    }

    @Test func repeatedWakeAndReplayNeverDuplicateObserverRows() async throws {
        let fixture = try await ObserverFixture.make(batchCount: 1)
        do {
            _ = try await fixture.coordinator.advance(
                consumerID: fixture.consumer.identity.id,
                sessionID: fixture.sessionID)
            _ = try await fixture.coordinator.advance(
                consumerID: fixture.consumer.identity.id,
                sessionID: fixture.sessionID)
            #expect(try fixture.rows() == [1])
            await fixture.coordinator.close()
            await fixture.consumer.close()
            try await fixture.library.close()
            await fixture.scope.dispose()
            try fixture.database.close()
            try FileManager.default.removeItem(at: fixture.directory)
        } catch {
            await fixture.coordinator.close()
            await fixture.consumer.close()
            try? await fixture.library.close()
            await fixture.scope.dispose()
            try? fixture.database.close()
            try? FileManager.default.removeItem(at: fixture.directory)
            throw error
        }
    }

    @Test func failedActivationRollsBackAndReleasedActivationCanBeReused() async throws {
        let registry = RuntimeRegistry<AgentCapability>()
        let parent = RuntimeScope(kind: .application)
        let probe = ModuleLifecycleProbe()
        let good = OwnedChallengeModule(registry: registry, probe: probe)
        let failedCleanup = LifecycleGate()
        let bad = FailingModule(id: "bad", dependencies: ["good"], cleanup: failedCleanup)
        do {
            let failing = try RuntimeModuleHost(modules: [good, bad])
            await #expect(throws: MiraError.self) { try await failing.activate(in: parent) }
            #expect(await failedCleanup.isOpen)
            #expect(await probe.starts == 1)
            #expect(await probe.drains == 1)
            #expect(await probe.cleanups == 1)
            let rolledBack = try await registry.freeze()
            #expect(rolledBack.entries.isEmpty)
            await rolledBack.release()

            let host = try RuntimeModuleHost(modules: [good])
            for expectedCount in 2...3 {
                let activation = try await host.activate(in: parent)
                let visible = try await registry.freeze()
                #expect(visible.entries.count == 1)
                #expect(await probe.starts == expectedCount)
                #expect(await probe.drains == expectedCount - 1)
                await visible.release()
                await activation.dispose()
                await activation.dispose()
                #expect(await probe.drains == expectedCount)
                #expect(await probe.cleanups == expectedCount)
                let removed = try await registry.freeze()
                #expect(removed.entries.isEmpty)
                await removed.release()
            }
            await parent.dispose()
            #expect(await probe.cleanups == 3)
        } catch {
            await parent.dispose()
            throw error
        }
    }

    @Test func catalogLeaseBlocksModuleReleaseUntilConsumerPassDrains() async throws {
        let fixture = try await ObserverFixture.make(batchCount: 1, blocked: true, register: false)
        let parent = RuntimeScope(kind: .application)
        let host = try RuntimeModuleHost(modules: [
            RegisteringModule(
                id: "consumer", registry: fixture.registry,
                consumer: fixture.consumer, gate: fixture.moduleGate)
        ])
        do {
            let activation = try await host.activate(in: parent)
            let pass = Task {
                try await fixture.coordinator.advance(
                    consumerID: fixture.consumer.identity.id,
                    sessionID: fixture.sessionID)
            }
            await fixture.block.entered.wait()
            let releaseFinished = LifecycleGate()
            let releasing = Task {
                await activation.dispose()
                await releaseFinished.release()
            }
            // Only scope disposal cancels this owned task; its drain proves disposal has begun.
            await fixture.moduleGate.waitForFinish()
            #expect(!(await releaseFinished.isOpen))
            await fixture.block.gate.release()
            _ = try await pass.value
            await releaseFinished.wait()
            _ = await releasing.value
            await parent.dispose()
            await fixture.coordinator.close()
            await fixture.consumer.close()
            try await fixture.library.close()
            await fixture.scope.dispose()
            try fixture.database.close()
            try FileManager.default.removeItem(at: fixture.directory)
        } catch {
            await fixture.block.gate.release()
            await fixture.coordinator.close()
            await fixture.consumer.close()
            try? await fixture.library.close()
            await fixture.scope.dispose()
            try? fixture.database.close()
            await parent.dispose()
            try? FileManager.default.removeItem(at: fixture.directory)
            throw error
        }
    }
}

private struct ObserverFixture: Sendable {
    let directory: URL
    let database: DatabaseQueue
    let library: FileSessionLibrary
    let consumer: SQLiteSessionConsumer
    let registry: RuntimeRegistry<AgentCapability>
    let scope: RuntimeScope
    let coordinator: AgentSessionConsumerCoordinator
    let sessionID: ConversationID
    let moduleGate: LifecycleGate
    let block: ObserverBlock

    static func make(batchCount: Int, blocked: Bool = false, register: Bool = true) async throws -> ObserverFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-extension-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var database: DatabaseQueue?
        var library: FileSessionLibrary?
        var consumer: SQLiteSessionConsumer?
        var scope: RuntimeScope?
        do {
            var configuration = Configuration()
            configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
            let openedDatabase = try DatabaseQueue(
                path: directory.appendingPathComponent("observer.sqlite").path,
                configuration: configuration)
            database = openedDatabase
            let openedLibrary = try FileSessionLibrary(directory: directory.appendingPathComponent("sessions"))
            library = openedLibrary
            let sessionID = ConversationID()
            for sequence in 1...max(1, batchCount) {
                let batchID = UUID()
                let fact: SessionFact
                if sequence == 1 {
                    let title = try await openedLibrary.stage(
                        Data("opened".utf8), sessionID: sessionID,
                        batchID: batchID, retentionGroup: UUID(), kind: .title)
                    fact = .opened(.init(workspaceID: nil, title: title))
                } else if sequence == 2 {
                    let title = try await openedLibrary.stage(
                        Data("renamed-\(sequence)".utf8), sessionID: sessionID,
                        batchID: batchID, retentionGroup: UUID(), kind: .title)
                    fact = .renamed(title: title, revision: sequence)
                } else {
                    let title = try await openedLibrary.stage(
                        Data("renamed-\(sequence)".utf8), sessionID: sessionID,
                        batchID: batchID, retentionGroup: UUID(), kind: .title)
                    fact = .renamed(title: title, revision: sequence)
                }
                let batch = SessionBatch(
                    id: batchID, sessionID: sessionID, expectedSequence: Int64(sequence - 1),
                    events: [
                        .init(
                            sequence: Int64(sequence), occurredAt: Date(timeIntervalSince1970: Double(sequence)),
                            fact: fact)
                    ])
                guard case .committed = await openedLibrary.append(batch) else {
                    throw MiraError(.storage, "The synthetic session batch was not committed.")
                }
            }
            let block = ObserverBlock()
            let handler = ObserverHandler(block: block, blocked: blocked)
            let openedConsumer = try SQLiteSessionConsumer(
                database: openedDatabase, identity: .init(id: "observer", revision: 1), handler: handler)
            consumer = openedConsumer
            let registry = RuntimeRegistry<AgentCapability>()
            let openedScope = RuntimeScope(kind: .application)
            scope = openedScope
            if register {
                try await registry.register(id: "observer", value: .consumer(openedConsumer), scope: openedScope)
            }
            let coordinator = try AgentSessionConsumerCoordinator(journal: openedLibrary, registry: registry)
            return .init(
                directory: directory, database: openedDatabase, library: openedLibrary, consumer: openedConsumer,
                registry: registry, scope: openedScope, coordinator: coordinator, sessionID: sessionID,
                moduleGate: LifecycleGate(), block: block)
        } catch {
            await consumer?.close()
            await scope?.dispose()
            try? await library?.close()
            try? database?.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func reopen(_ old: ObserverFixture) async throws -> ObserverFixture {
        let library = try FileSessionLibrary(directory: old.directory.appendingPathComponent("sessions"))
        let scope = RuntimeScope(kind: .application)
        var database: DatabaseQueue?
        var consumer: SQLiteSessionConsumer?
        do {
            var configuration = Configuration()
            configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
            let db = try DatabaseQueue(
                path: old.directory.appendingPathComponent("observer.sqlite").path, configuration: configuration)
            database = db
            let block = ObserverBlock()
            let openedConsumer = try SQLiteSessionConsumer(
                database: db, identity: .init(id: "observer", revision: 1), handler: ObserverHandler(block: block))
            consumer = openedConsumer
            let registry = RuntimeRegistry<AgentCapability>()
            try await registry.register(id: "observer", value: .consumer(openedConsumer), scope: scope)
            let coordinator = try AgentSessionConsumerCoordinator(journal: library, registry: registry)
            return .init(
                directory: old.directory, database: db, library: library, consumer: openedConsumer, registry: registry,
                scope: scope, coordinator: coordinator, sessionID: old.sessionID, moduleGate: LifecycleGate(),
                block: block)
        } catch {
            await scope.dispose()
            await consumer?.close()
            try? await library.close()
            try? database?.close()
            throw error
        }
    }

    func rows() throws -> [Int64] {
        try database.read { try Int64.fetchAll($0, sql: "SELECT sequence FROM observer_records ORDER BY sequence") }
    }
}

private struct ObserverHandler: SQLiteSessionConsumerHandler, Sendable {
    let block: ObserverBlock
    let blocked: Bool
    init(block: ObserverBlock, blocked: Bool = false) {
        self.block = block
        self.blocked = blocked
    }
    func prepare(_ delivery: AgentSessionConsumerDelivery) async throws -> any SQLiteSessionConsumerTransaction {
        await block.incrementPrepare()
        if blocked {
            await block.entered.release()
            await block.gate.wait()
        }
        return ObserverTransaction(sequence: delivery.batch.cursor.sequence)
    }
}

private struct ObserverTransaction: SQLiteSessionConsumerTransaction {
    let sequence: Int64
    func apply(in db: Database) throws {
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS observer_records (sequence INTEGER PRIMARY KEY)")
        try db.execute(sql: "INSERT INTO observer_records(sequence) VALUES (?)", arguments: [sequence])
    }
    func close() async {}
}

private actor ObserverBlock {
    let entered = LifecycleGate()
    let gate = LifecycleGate()
    private(set) var prepares = 0
    func incrementPrepare() { prepares += 1 }
}

private actor RecordingConsumer: AgentSessionConsumer {
    let identity = AgentSessionConsumerIdentity(id: "module-consumer", revision: 1)
    func checkpoint(sessionID: ConversationID) async throws -> AgentSessionConsumerCheckpoint? { nil }
    func consume(_ delivery: AgentSessionConsumerDelivery) async throws -> AgentSessionConsumerCheckpoint {
        delivery.checkpoint
    }
}

private struct FailingModule: RuntimeModule {
    let id: String
    let dependencies: Set<String>
    let cleanup: LifecycleGate
    init(id: String, dependencies: Set<String> = [], cleanup: LifecycleGate = LifecycleGate()) {
        self.id = id
        self.dependencies = dependencies
        self.cleanup = cleanup
    }
    func activate(in scope: RuntimeScope) async throws {
        try await scope.registerCleanup { await cleanup.release() }
        throw MiraError(.configuration, "synthetic activation failure")
    }
}

private struct RegisteringModule: RuntimeModule {
    let id: String
    let registry: RuntimeRegistry<AgentCapability>
    let consumer: any AgentSessionConsumer
    let gate: LifecycleGate
    var dependencies: Set<String> { [] }
    func activate(in scope: RuntimeScope) async throws {
        try await registry.register(id: id, value: .consumer(consumer), scope: scope)
        _ = try await scope.ownTask {
            await gate.started()
            await withTaskCancellationHandler(
                operation: { await gate.wait() }, onCancel: { Task { await gate.release() } })
            await gate.finished()
        }
        await gate.waitUntilStarted()
    }
}

private actor LifecycleGate {
    private var open = false
    private var startedFlag = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    func started() {
        startedFlag = true
        let values = startWaiters
        startWaiters.removeAll()
        values.forEach { $0.resume() }
    }
    func waitUntilStarted() async {
        if startedFlag { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var finishedFlag = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    var isOpen: Bool { open }
    func release() {
        open = true
        let values = waiters
        waiters.removeAll()
        values.forEach { $0.resume() }
    }
    func finished() {
        finishedFlag = true
        let values = finishWaiters
        finishWaiters.removeAll()
        values.forEach { $0.resume() }
    }
    func waitForFinish() async {
        if finishedFlag { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }
}

private actor ModuleLifecycleProbe {
    private(set) var starts = 0
    private(set) var drains = 0
    private(set) var cleanups = 0
    func start() { starts += 1 }
    func drain() { drains += 1 }
    func cleanup() { cleanups += 1 }
}
private struct OwnedChallengeModule: RuntimeModule {
    let id = "good"
    let dependencies: Set<String> = []
    let registry: RuntimeRegistry<AgentCapability>
    let probe: ModuleLifecycleProbe
    func activate(in scope: RuntimeScope) async throws {
        let gate = LifecycleGate()
        try await scope.registerCleanup { await probe.cleanup() }
        try await registry.register(id: "challenge.owned-consumer", value: .consumer(RecordingConsumer()), scope: scope)
        _ = try await scope.ownTask {
            await probe.start()
            await gate.started()
            await withTaskCancellationHandler(
                operation: { await gate.wait() }, onCancel: { Task { await gate.release() } })
            await probe.drain()
        }
        await gate.waitUntilStarted()
    }
}

private func rebuildObserverProjection(library: FileSessionLibrary, sessionID: ConversationID, url: URL) async throws {
    let projection = try SQLiteSessionProjection(path: url.path)
    var coordinator: SessionProjectionCoordinator?
    do {
        let opened = try SessionProjectionCoordinator(journal: library, projection: projection)
        coordinator = opened
        _ = try await opened.rebuild(sessionID: sessionID)
        await opened.close()
        try await projection.close()
    } catch {
        await coordinator?.close()
        try? await projection.close()
        throw error
    }
}
