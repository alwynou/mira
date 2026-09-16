import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("SQLite library restoration", .timeLimit(.minutes(2)))
struct SQLiteLibraryRestorerTests {
    @Test
    func restoresDomainArchiveDespiteCallerCancellation() async throws {
        try await withTaskWorkflow(
            outputs: [[.blockStarted(.init(id: "text", content: .text("Restored answer"))), .blockFinished(id: "text"), .finished(.stop)]],
            memoryEnabled: true,
            knowledgeEnabled: true
        ) { fixture in
            let memory = try #require(fixture.memory)
            let knowledge = try #require(fixture.knowledge)
            let authorization = try await fixture.authority.authorization()
            _ = try await fixture.run("Keep this archive source")
            let savedMemory = try await memory.createMemory(
                draft: .init(content: "A retained archive memory", scope: .global),
                source: .manualEntry(id: UUID(), statement: "A retained archive memory"),
                operationID: UUID(), replacing: nil, expectedRevision: nil,
                authorization: authorization, at: TaskWorkflowFixture.now)
            let indexJob = try #require(try await memory.pendingMemoryIndexJobs(limit: 4).first)
            #expect(try await memory.completeMemoryIndexJob(indexJob, vector: [1] + Array(repeating: Float(0), count: 1023), authorization: authorization))
            let imported = try await knowledge.importMarkdown(
                .init(title: "Restored notes.md", bytes: Data("# Restored notes\nretained body".utf8)),
                workspaceID: nil, updating: nil, expectedRevision: nil, operationID: UUID(),
                authorization: authorization, at: TaskWorkflowFixture.now)
            let task = try await fixture.save(
                draft: .init(title: "Paused reminder", reminderAt: TaskWorkflowFixture.now.addingTimeInterval(3_600)),
                status: .open)
            let extraction = try SQLiteMemoryExtractionStore(
                database: fixture.database, libraryID: fixture.authority.libraryID)
            let privacy = try SQLiteSessionPrivacyPlanStore(
                database: fixture.database, libraryID: fixture.authority.libraryID)
            let consumer = try SQLiteSessionConsumer(
                database: fixture.database,
                identity: .init(id: "restorer.fixture.consumer", revision: 1),
                handler: RestorerNoopHandler())

            let modules = try restorationModules()
            let archive = fixture.directory.appendingPathComponent("restoration-archive")
            try await stopFixtureProducers(fixture)
            await extraction.close()
            await privacy.close()
            await consumer.close()
            let interrupted = try await stageRestorationDraft(
                fixture,
                source: .domain(
                    namespace: "memories", id: savedMemory.memory.id.rawValue, revision: savedMemory.memory.revision))
            let exporter = try SQLiteLibraryArchiveExporter(
                database: fixture.database, sessions: fixture.library,
                libraryID: fixture.authority.libraryID, attachmentDirectory: fixture.directory,
                modules: modules)
            do {
                _ = try await exporter.export(to: archive, authorization: authorization)
            } catch {
                await exporter.close()
                throw error
            }
            await exporter.close()
            let originalManifest = try await SQLiteLibraryArchiveExporter.validate(at: archive, modules: modules)
            let exportedDatabase = try DatabaseQueue(path: archive.appendingPathComponent("Business.sqlite").path)
            #expect(try await exportedDatabase.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_embeddings") } == 0)
            #expect(try await exportedDatabase.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_embedding_jobs") } == 0)
            try exportedDatabase.close()
            #expect(try await fixture.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_embeddings") } == 1)

            let destination = fixture.directory.appendingPathComponent("restored-library")
            let gate = RestorationSourceGate()
            let restorer = try SQLiteLibraryRestorer(
                modules: modules,
                sourceFactory: { context in
                    await gate.enter()
                    return try await restorationSources(context)
                })
            let result: SQLiteLibraryRestorationResult
            let restoring = Task { try await restorer.restore(from: archive, to: destination) }
            await gate.waitUntilEntered()
            restoring.cancel()
            let closing = Task { await restorer.close() }
            await gate.release()
            do {
                result = try await restoring.value
            } catch {
                await closing.value
                throw error
            }
            await closing.value
            await #expect(throws: MiraError.self) { try await restorer.restore(from: archive, to: destination) }
            #expect(try await SQLiteLibraryArchiveExporter.validate(at: archive, modules: modules) == originalManifest)
            #expect(result.sessions.count == 2)
            #expect(result.authorization == authorization)
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.json").path))
            #expect(
                FileManager.default.fileExists(
                    atPath: destination.appendingPathComponent("Projections/Session.sqlite").path))

            let restoredDatabase = try DatabaseQueue(path: destination.appendingPathComponent("Business.sqlite").path)
            let restoredLibrary = try FileSessionLibrary(directory: destination.appendingPathComponent("Sessions"))
            let restoredAuthority = try SQLiteLibraryAuthority(database: restoredDatabase)
            let restoredMemory = try SQLiteMemoryStore(
                database: restoredDatabase, libraryID: restoredAuthority.libraryID)
            let restoredKnowledge = try SQLiteKnowledgeStore(
                database: restoredDatabase, libraryID: restoredAuthority.libraryID,
                directory: destination.appendingPathComponent("knowledge"))
            let restoredTasks = try SQLiteTaskStore(database: restoredDatabase, libraryID: restoredAuthority.libraryID)
            var restoredSettings: SQLiteAgentModelSettings?
            do {
                let restoredHeads = try await restoredLibrary.withSnapshot { snapshot in
                    snapshot.sessions.map(\.head)
                }
                #expect(restoredHeads == result.sessions)
                #expect(try await restoredMemory.pendingMemoryIndexJobs(limit: 4).map(\.memoryID) == [savedMemory.memory.id])
                let memories = try await restoredMemory.memoryList(
                    workspaceID: nil, states: [.active, .candidate, .archived], query: "retained", limit: 10)
                #expect(memories.memories.contains { $0.draft?.content == "A retained archive memory" })
                let sources = try await restoredKnowledge.knowledgeSources(
                    scope: .init(workspaceID: nil, destination: .local), limit: 10)
                #expect(sources.contains { $0.id == imported.source.id })
                let detail = try await restoredKnowledge.knowledgeSource(
                    imported.source.id, versionID: imported.version.id,
                    scope: .init(workspaceID: nil, destination: .local))
                let chunk = try #require(detail.chunks.first)
                let body = try await restoredKnowledge.sourceChunk(
                    chunk.id,
                    scope: .init(workspaceID: nil, destination: .local))
                #expect(body.text == "# Restored notes\nretained body")
                let restoredTask = try await restoredTasks.taskDetail(task.id, workspaceID: nil)
                #expect(restoredTask.deliveryState == .paused)
                let settings = try SQLiteAgentModelSettings(database: restoredDatabase, libraryID: result.authorization.libraryID)
                restoredSettings = settings
                let connection = try await settings.connection(id: fixture.route.connectionID)
                #expect(connection?.isEnabled == false)
                #expect(connection?.endpoints.allSatisfy { $0.credential == nil } == true)
                await settings.close()
                restoredSettings = nil
                let restoredHead = try #require(result.sessions.first { $0.cursor.sessionID == interrupted.sessionID })
                for head in result.sessions {
                    let runtime = try await SessionRuntime.open(
                        id: head.cursor.sessionID, journal: restoredLibrary, payloads: restoredLibrary,
                        extensionSchemas: restorationExtensionSchemas(modules))
                    let state = await runtime.snapshot()
                    #expect(state.activeExecutionID == nil)
                    if head.cursor.sessionID == interrupted.sessionID {
                        let completion = try #require(state.executions[interrupted.executionID]?.completion)
                        #expect(completion.status == .interrupted)
                        let answer = try #require(completion.answer)
                        let thinking = try #require(completion.visibleThinking)
                        #expect(try await restoredLibrary.read(answer) == Data("Draft from retained memory".utf8))
                        #expect(try await restoredLibrary.read(thinking) == Data("Thinking from retained memory".utf8))
                    }
                    await runtime.close()
                }
                let projection = try SQLiteSessionProjection(
                    path: destination.appendingPathComponent("Projections/Session.sqlite").path)
                do {
                    let head = try await projection.head(sessionID: restoredHead.cursor.sessionID)
                    #expect(head == restoredHead)
                    let summary = try await projection.session(id: restoredHead.cursor.sessionID)
                    #expect(summary?.activeExecutionID == nil)
                    let messages = try await projection.messages(
                        sessionID: restoredHead.cursor.sessionID, beforeSequence: nil, limit: 10)
                    #expect(messages.contains { $0.role == .user && $0.body != nil })
                    #expect(messages.contains { $0.role == .assistant && $0.body != nil })
                    let executions = try await projection.executions(
                        sessionID: restoredHead.cursor.sessionID, beforeSequence: nil, limit: 10)
                    #expect(executions.count == 1)
                    #expect(executions.first?.completion?.status == .interrupted)
                    try await projection.close()
                } catch {
                    try? await projection.close()
                    throw error
                }
            } catch {
                await restoredSettings?.close()
                try? await restoredLibrary.close()
                await restoredAuthority.close()
                await restoredMemory.close()
                await restoredKnowledge.close()
                await restoredTasks.close()
                try? restoredDatabase.close()
                throw error
            }
            try await restoredLibrary.close()
            await restoredAuthority.close()
            await restoredMemory.close()
            await restoredKnowledge.close()
            await restoredTasks.close()
            try restoredDatabase.close()
        }
    }

    @Test
    func everyRestorationFaultCleansStageAndPreservesArchiveAndDestination() async throws {
        try await withTaskWorkflow(
            outputs: [[.blockStarted(.init(id: "text", content: .text("Restoration source"))), .blockFinished(id: "text"), .finished(.stop)]],
            memoryEnabled: true,
            knowledgeEnabled: true
        ) { fixture in
            _ = try await fixture.run("Fault restoration source")
            let authorization = try await fixture.authority.authorization()
            let extraction = try SQLiteMemoryExtractionStore(
                database: fixture.database, libraryID: fixture.authority.libraryID)
            let privacy = try SQLiteSessionPrivacyPlanStore(
                database: fixture.database, libraryID: fixture.authority.libraryID)
            let consumer = try SQLiteSessionConsumer(
                database: fixture.database,
                identity: .init(id: "restorer.fault.consumer", revision: 1),
                handler: RestorerNoopHandler())
            let modules = try restorationModules()
            try await stopFixtureProducers(fixture)
            await extraction.close()
            await privacy.close()
            await consumer.close()
            let archive = fixture.directory.appendingPathComponent("fault-archive")
            let exporter = try SQLiteLibraryArchiveExporter(
                database: fixture.database, sessions: fixture.library,
                libraryID: fixture.authority.libraryID, attachmentDirectory: fixture.directory,
                modules: modules)
            do { _ = try await exporter.export(to: archive, authorization: authorization) } catch {
                await exporter.close()
                throw error
            }
            await exporter.close()
            let originalManifest = try await SQLiteLibraryArchiveExporter.validate(at: archive, modules: modules)

            for stage in LibraryRestorationFaultStage.allCases {
                let destination = fixture.directory.appendingPathComponent("failed-\(String(describing: stage))")
                let probe = RestorationFaultProbe(expected: stage)
                let restorer = try SQLiteLibraryRestorer(
                    modules: modules, sourceFactory: restorationSources,
                    faultInjector: { actual in
                        probe.hit(actual)
                        if actual == stage { throw MiraError(.storage, "Synthetic restoration fault.") }
                    })
                await #expect(throws: MiraError.self) {
                    _ = try await restorer.restore(from: archive, to: destination)
                }
                await restorer.close()
                #expect(probe.wasHit)
                #expect(!FileManager.default.fileExists(atPath: destination.path))
                let siblings = try FileManager.default.contentsOfDirectory(
                    at: destination.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                #expect(!siblings.contains { $0.lastPathComponent.hasPrefix(".mira-archive-") })
                #expect(
                    try await SQLiteLibraryArchiveExporter.validate(at: archive, modules: modules) == originalManifest)
            }

            let existing = fixture.directory.appendingPathComponent("existing-destination")
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
            let sentinel = existing.appendingPathComponent("sentinel")
            try Data("keep".utf8).write(to: sentinel)
            let restorer = try SQLiteLibraryRestorer(modules: modules, sourceFactory: restorationSources)
            await #expect(throws: MiraError.self) {
                _ = try await restorer.restore(from: archive, to: existing)
            }
            await restorer.close()
            #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
        }
    }
}

private func restorationModules() throws -> [SQLiteArchiveModule] {
    [
        try SQLiteWorkspaceStore.archiveModule(),
        try SQLiteAgentModelSettings.archiveModule(),
        try SQLiteMemoryStore.archiveModule(),
        try SQLiteMemoryExtractionStore.archiveModule(),
        try SQLiteKnowledgeStore.archiveModule(blobDirectory: "knowledge/Blobs"),
        try SQLiteTaskStore.archiveModule(),
        try SQLiteBusinessEffects.archiveModule(),
        try SQLiteSessionConsumer.archiveModule(),
        try SQLiteSessionPrivacyPlanStore.archiveModule(),
    ]
}

private func restorationExtensionSchemas(_ modules: [SQLiteArchiveModule]) -> [String: Set<Int>] {
    Dictionary(uniqueKeysWithValues: modules.flatMap { $0.sessionExtensions.map { ($0.key, $0.value) } })
}

private func stopFixtureProducers(_ fixture: TaskWorkflowFixture) async throws {
    await fixture.model.releaseStream()
    _ = await fixture.runtime.shutdown()
    await fixture.reminders.close()
    await fixture.tasks.close()
    await fixture.scheduler.shutdown()
    await fixture.scope.dispose()
    try await fixture.business.close()
    await fixture.memory?.close()
    await fixture.knowledge?.close()
    await fixture.store.close()
    await fixture.workspaces.close()
    await fixture.settings.close()
    await fixture.contextPolicy.close()
}

private func restorationSources(
    _ context: SQLiteLibraryRestorationContext
) async throws -> SQLiteLibraryRestorationSources {
    var memory: SQLiteMemoryStore?
    var knowledge: SQLiteKnowledgeStore?
    var tasks: SQLiteTaskStore?
    var policy: SQLiteAgentContextPolicy?
    let scope = RuntimeScope(kind: .application)
    do {
        let memoryStore = try SQLiteMemoryStore(database: context.database, libraryID: context.authorization.libraryID)
        memory = memoryStore
        let knowledgeStore = try SQLiteKnowledgeStore(
            database: context.database, libraryID: context.authorization.libraryID,
            directory: context.directory.appendingPathComponent("knowledge"))
        knowledge = knowledgeStore
        let taskStore = try SQLiteTaskStore(database: context.database, libraryID: context.authorization.libraryID)
        tasks = taskStore
        let contextPolicy = try SQLiteAgentContextPolicy(
            database: context.database, libraryID: context.authorization.libraryID)
        policy = contextPolicy
        let authorities = RuntimeRegistry<any AgentDomainSourceAuthority>()
        try await authorities.register(id: "memories", value: MemorySourceAuthority(store: memoryStore), scope: scope)
        try await authorities.register(
            id: KnowledgeSources.metadataNamespace,
            value: try KnowledgeSourceAuthority(store: knowledgeStore, namespace: KnowledgeSources.metadataNamespace),
            scope: scope)
        try await authorities.register(
            id: KnowledgeSources.chunkNamespace,
            value: try KnowledgeSourceAuthority(store: knowledgeStore, namespace: KnowledgeSources.chunkNamespace),
            scope: scope)
        try await authorities.register(id: "tasks", value: TaskSourceAuthority(store: taskStore), scope: scope)
        let reader = JournalSessionReader(
            journal: context.sessions, payloads: context.sessions, extensionSchemas: context.extensionSchemas)
        let authorizer = JournalAgentSourceAuthorizer(reader: reader, policy: contextPolicy, domains: authorities)
        return .init(
            authorizer: authorizer,
            close: {
                await scope.dispose()
                await memoryStore.close()
                await knowledgeStore.close()
                await taskStore.close()
                await contextPolicy.close()
            })
    } catch {
        await scope.dispose()
        await memory?.close()
        await knowledge?.close()
        await tasks?.close()
        await policy?.close()
        throw error
    }
}

private struct RestorerNoopHandler: SQLiteSessionConsumerHandler {
    func prepare(_ delivery: AgentSessionConsumerDelivery) async throws -> any SQLiteSessionConsumerTransaction {
        RestorerNoopTransaction()
    }
}

private actor RestorationSourceGate {
    private var entered = false
    private var released = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func enter() async {
        entered = true
        enterWaiters.forEach { $0.resume() }
        enterWaiters.removeAll()
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enterWaiters.append($0) } }
    }
    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private struct RestorerNoopTransaction: SQLiteSessionConsumerTransaction {
    func apply(in db: Database) throws {}
    func close() async {}
}

private final class RestorationFaultProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let expected: LibraryRestorationFaultStage
    private var reached = false

    init(expected: LibraryRestorationFaultStage) {
        self.expected = expected
    }

    func hit(_ actual: LibraryRestorationFaultStage) {
        guard actual == expected else { return }
        lock.withLock { reached = true }
    }

    var wasHit: Bool { lock.withLock { reached } }
}

// Stage a current-format interrupted prefix after all application producers are closed.
// Every admission, attempt and draft still passes the real SessionRuntime reducer.
private func stageRestorationDraft(_ fixture: TaskWorkflowFixture, source: AgentSourceReference) async throws
    -> AgentExecutionAddress
{
    let address = AgentExecutionAddress(sessionID: .init(), executionID: .init())
    let runtime = try await SessionRuntime.open(
        id: address.sessionID, journal: fixture.library, payloads: fixture.library)
    do {
        let admitted = await runtime.commit(id: UUID()) { context in
            let title = try await context.stageBytes(
                Data("Restoration draft".utf8), kind: .title, retentionGroup: UUID())
            let user = try await context.stageBytes(
                Data("Restore this draft".utf8), kind: .userText, retentionGroup: UUID())
            let plan = AgentExecutionPlan(
                runtimeID: UUID(), catalogGeneration: 1, driverID: "mira.default", driverRevision: 1,
                instructions: "Retain this draft.", limits: .init(), priority: .foreground, route: fixture.route)
            let planReference = try await context.stage(plan, kind: .executionPlan, retentionGroup: UUID())
            return [
                .opened(.init(workspaceID: nil, title: title)),
                .admitted(
                    .init(
                        executionID: address.executionID, userMessageID: .init(), userBody: user,
                        plan: planReference, hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC")),
            ]
        }
        try taskRequireCommitted(admitted)
        let attemptID = UUID()
        let stepID = UUID()
        let started = await runtime.commit(id: UUID()) { context in
            let request = AgentContextRequest(
                sessionID: address.sessionID, executionID: address.executionID,
                workspaceID: nil, userText: "Restore this draft", authorizationEpoch: 0,
                destination: .model(fixture.route))
            let input = AgentModelInput(
                stepID: stepID, executionID: address.executionID, instructions: "Retain this draft.",
                messages: [.init(role: .user, blocks: [.init(id: "text", content: .text("Restore this draft"))])], tools: [])
            let build = AgentContextBuild(
                request: request,
                prepared: .init(
                    adapter: fixture.route.adapter, input: input, wirePayload: .object([:]), estimatedInputTokens: 1),
                inheritedSources: [source], evidence: [], omissions: [])
            let requestReference = try await context.stage(build, kind: .request, retentionGroup: UUID())
            return [
                .phaseChanged(executionID: address.executionID, phase: .preparing),
                .attemptStarted(
                    .init(
                        id: attemptID, executionID: address.executionID, stepID: stepID,
                        stepIndex: 1, attemptIndex: 1, request: requestReference)),
            ]
        }
        try taskRequireCommitted(started)
        let checkpoint = await runtime.commit(id: UUID()) { context in
            var facts: [SessionFact] = []
            for (part, text): (SessionDraftPart, String) in [
                (.answer, "Draft from retained memory"), (.thinking, "Thinking from retained memory"),
            ] {
                let bytes = Data(text.utf8)
                let reference = try await context.stageBytes(bytes, kind: .draft, retentionGroup: UUID())
                facts.append(
                    .draftCheckpoint(
                        .init(
                            executionID: address.executionID, attemptID: attemptID,
                            part: part, baseSequence: nil, prefixByteCount: 0, suffixByteCount: 0,
                            replacement: reference, resultByteCount: bytes.count)))
            }
            return facts
        }
        try taskRequireCommitted(checkpoint)
        await runtime.close()
        return address
    } catch {
        await runtime.close()
        throw error
    }
}
