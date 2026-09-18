import Foundation
import GRDB
import MiraCore
import MiraData
import MiraProviders
import Testing

@Suite("Local memory embedding runtime")
struct MemoryEmbeddingRuntimeTests {
    @Test("real 4-bit recall rejects unrelated queries in a small library", .enabled(if: ProcessInfo.processInfo.environment["MIRA_TEST_EMBEDDING_MODEL_DIRECTORY"] != nil))
    func semanticRecallFiltersUnrelatedMemories() async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["MIRA_TEST_EMBEDDING_MODEL_DIRECTORY"])
        let directory = URL(fileURLWithPath: raw, isDirectory: true)
        try MacMemoryEmbeddingInstaller.validate(directory: directory)
        let service = MacMemoryEmbeddingService(directory: directory)
        let database = try DatabaseQueue()
        let authority = try SQLiteLibraryAuthority(database: database, validators: [SQLiteMemoryStore.maintenanceValidator])
        let workspaces = try SQLiteWorkspaceStore(database: database, libraryID: authority.libraryID)
        let store = try SQLiteMemoryStore(database: database, libraryID: authority.libraryID, embeddings: service)
        do {
            try await service.prepare()
            let authorization = try await authority.authorization()
            let now = Date()
            let documents = [
                "My dog is a black cocker spaniel.",
                "I take my dog for a forty-five minute walk every evening.",
                "My dog's name is Mochi."
            ]
            var memories: [Memory] = []
            for text in documents {
                memories.append(try await store.createMemory(
                    draft: .init(content: text, scope: .global, allowsRemoteUse: true),
                    source: .manualEntry(id: UUID(), statement: text), operationID: UUID(),
                    replacing: nil, expectedRevision: nil, authorization: authorization, at: now).memory)
            }
            var documentVectors: [[Float]] = []
            for memory in memories {
                let job = try #require(try await store.pendingMemoryIndexJobs(limit: 4).first { $0.memoryID == memory.id })
                let vector = try await service.embed(.documents([job.content]))[0]
                documentVectors.append(vector)
                #expect(try await store.completeMemoryIndexJob(job, vector: vector, authorization: authorization))
            }
            let cases: [(query: String, expected: Int?)] = [
                ("What is my pet called?", 2),
                ("How long do I exercise my dog?", 1),
                ("What breed is my dog?", 0),
                ("Explain quantum entanglement", nil),
                ("PostgreSQL database index tuning", nil),
                ("Which laptop processor should I buy?", nil),
                ("Volcano formation and plate tectonics", nil),
                ("How do I bake sourdough bread?", nil),
                ("Hello", nil)
            ]
            for (index, item) in cases.enumerated() {
                let vector = try await service.embed(.query(item.query))[0]
                let scores = documentVectors.map { cosine(vector, $0) }
                // Synthetic score diagnostics document the local relevance boundary, not provider logs.
                print("Memory recall fixture \(index): scores=\(scores)")
                let request = AgentContextRequest(sessionID: .init(), executionID: .init(), workspaceID: nil,
                    userText: item.query, authorizationEpoch: 0, destination: .local)
                let result = try await store.recallMemories(query: item.query, request: request, limit: 6, at: now)
                if let expected = item.expected {
                    #expect(result.memories.contains { $0.id == memories[expected].id })
                } else {
                    #expect(result.memories.isEmpty, "Unrelated query fixture \(index) returned memories.")
                }
                #expect(!result.isTruncated)
            }
        } catch {
            await store.close(); await workspaces.close(); await authority.close(); await service.close()
            try? database.close()
            throw error
        }
        await store.close(); await workspaces.close(); await authority.close(); await service.close()
        try database.close()
    }

    @Test("verified 4-bit model embeds and drains", .enabled(if: ProcessInfo.processInfo.environment["MIRA_TEST_EMBEDDING_MODEL_DIRECTORY"] != nil))
    func verifiedModelEmbedsAndDrains() async throws {
        guard let rawPath = ProcessInfo.processInfo.environment["MIRA_TEST_EMBEDDING_MODEL_DIRECTORY"],
              !rawPath.isEmpty else {
            // This is an explicit local-hardware test. CI and ordinary host tests skip
            // unless a caller supplies a verified model directory.
            return
        }
        let directory = URL(fileURLWithPath: rawPath, isDirectory: true)
        try MacMemoryEmbeddingInstaller.validate(directory: directory)

        let service = MacMemoryEmbeddingService(directory: directory)
        try await service.prepare()
        #expect(await service.status() == .ready)

        let documents = [
            "I usually eat a dairy-free breakfast with fruit and oats.",
            "My primary laptop is a 14-inch model with 32 GB of memory.",
            "I prefer quiet hotels near public transit when I travel."
        ]
        let vectors = try await service.embed(.documents(documents))
        let query = try await service.embed(.query("What do I usually eat for breakfast?"))
        #expect(vectors.count == 3)
        #expect(query.count == 1)
        #expect(vectors.allSatisfy { $0.count == 1024 && $0.allSatisfy(\.isFinite) })
        #expect(query[0].count == 1024 && query[0].allSatisfy(\.isFinite))
        #expect(vectors.allSatisfy { abs(norm($0) - 1) < 0.000_01 })
        #expect(abs(norm(query[0]) - 1) < 0.000_01)

        let scores = vectors.map { cosine(query[0], $0) }
        #expect(scores[0] == scores.max())

        let short = try await service.embed(.documents([documents[0]]))[0]
        let padded = try await service.embed(.documents([documents[0], "A short unrelated note."]))[0]
        #expect(cosine(short, padded) >= 0.999)

        await service.close()
        #expect(await service.status() == .unavailable)
        do {
            _ = try await service.embed(.query("should be rejected after close"))
            Issue.record("A closed embedding service accepted a new request.")
        } catch let error as MiraError {
            #expect(error.code == .busy)
        } catch {
            Issue.record("A closed embedding service returned an unexpected error.")
        }

        // close is terminal; a new service can reopen the same verified installation.
        let reopened = MacMemoryEmbeddingService(directory: directory)
        try await reopened.prepare()
        #expect(await reopened.status() == .ready)
        await reopened.close()
    }

    @Test("four completed turns extract above the former quota and persist native vectors", .enabled(if: ProcessInfo.processInfo.environment["MIRA_TEST_EMBEDDING_MODEL_DIRECTORY"] != nil))
    func fourCompletedTurnsPersistNativeVector() async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["MIRA_TEST_EMBEDDING_MODEL_DIRECTORY"])
        let modelURL = URL(fileURLWithPath: raw, isDirectory: true)
        try MacMemoryEmbeddingInstaller.validate(directory: modelURL)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mira-NativeMemory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = MacMemoryEmbeddingService(directory: modelURL)
        let library = try await MacLibrary.open(embeddings: service, directory: directory,
            notifications: NativeMemoryNotifications(), credentials: NativeMemoryCredentials(),
            modules: { [NativeMemoryModule(registry: $0)] })
        do {
            let group = try await library.workloads()
            let route = try await NativeMemoryRoute.install(in: group)
            let session = ConversationID()
            let turns = ["I prefer dairy-free breakfasts with fruit and oats.", "I work in the morning.", "I like concise answers.", "I prefer quiet hotels near transit."]
            var firstExecution: ExecutionID?
            for (index, text) in turns.enumerated() {
                let command = AgentSubmitCommand(id: UUID(), sessionID: session, executionID: .init(),
                    input: .message(id: .init(), text: text, timeZoneIdentifier: "UTC"),
                    options: .init(instructions: String(repeating: "Synthetic context for memory verification. ", count: 150), route: route),
                    opening: index == 0 ? .init(title: "Synthetic memory", workspaceID: nil) : nil)
                if index == 0 { firstExecution = command.executionID }
                guard case .committed = await group.application.submit(command) else { throw MiraError(.storage, "Synthetic turn admission failed.") }
                guard case .committed = await group.application.waitForExecution(id: command.executionID, sessionID: session) else { throw MiraError(.storage, "Synthetic turn failed.") }
            }
            await group.wake()
            let execution = try #require(firstExecution)
            var configuration = Configuration()
            configuration.readonly = true
            // The observer reads while the production background worker commits its vector.
            configuration.busyMode = .timeout(5)
            let database = try DatabaseQueue(path: directory.appendingPathComponent("Business.sqlite").path, configuration: configuration)
            defer { try? database.close() }
            let deadline = ContinuousClock.now + .seconds(45)
            while try await database.read({ try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_embeddings") }) != 1 {
                guard ContinuousClock.now < deadline else { throw MiraError(.timeout, "Automatic memory did not produce a native vector.") }
                try await Task.sleep(for: .milliseconds(50))
            }
            let page = try await group.memories.extractionStatus(sessionID: session, executionID: execution, workspaceID: nil)
            let job = try #require(page.jobs.first)
            #expect(page.jobs.count == 1 && job.state == .completed && job.memoryCount == 1)
            let report = try await group.memories.extractionReport(job.id, sessionID: session, executionID: execution, workspaceID: nil)
            #expect(report.attempts.count == 1)
            #expect(report.attempts.first?.reservedTokens ?? 0 > 10_000)
            #expect(report.attempts.first?.dispatchedAt != nil)
            #expect(try await group.memories.list(workspaceID: nil, states: [.active], limit: 8).memories.count == 1)
            let bytes: Data = try await database.read { db in
                try #require(try Data.fetchOne(db, sql: "SELECT v.vector FROM memory_embeddings v JOIN memory_records m ON m.id=v.memory_id AND m.revision=v.revision JOIN memory_embedding_state s ON s.generation=v.generation WHERE m.state='active' AND s.dimensions=1024"))
            }
            #expect(bytes.count == 1024 * 4)
            let vector: [Float] = bytes.withUnsafeBytes { buffer in
                (0..<bytes.count / 4).map { Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
            }
            #expect(vector.allSatisfy(\.isFinite) && abs(norm(vector) - 1) < 0.000_01)
            #expect(await library.close().isSettled)
        } catch {
            _ = await library.close()
            throw error
        }
    }

    private func norm(_ vector: [Float]) -> Float {
        sqrt(vector.reduce(0) { $0 + $1 * $1 })
    }

    private func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        lhs.indices.reduce(0) { $0 + lhs[$1] * rhs[$1] }
    }
}

private struct NativeMemoryRoute {
    static func install(in group: MacLibraryWorkloads) async throws -> AgentModelRoute {
        let schema = AgentConfigurationValue(schema: .init(id: "test.memory.schema", revision: 1), value: .object([:]))
        let endpoint = AgentModelEndpoint(id: "test", configuration: schema, credential: nil)
        let connection = AgentConfiguredConnection(id: .init(), revision: 1, configurationRevision: 1,
            name: "Synthetic memory", isEnabled: true, definitionID: nil, endpoints: [endpoint], discovery: nil, defaultInvocation: nil)
        let model = AgentConfiguredModel(id: .init(), revision: 1, authorizationRevision: 1,
            reference: .init(connectionID: connection.id, modelID: "memory"), displayName: "Synthetic memory", isEnabled: true,
            invocations: [.init(id: "default", revision: 1, adapter: NativeMemoryModule.identity, endpointID: endpoint.id,
                contextWindow: 131_072, maximumOutputTokens: 2_048,
                capabilities: [AgentModelCapabilityID.streamingText: .declared, AgentModelCapabilityID.toolCalls: .declared],
                configuration: schema, parameterSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]))], facts: [])
        let preset = AgentRoutePreset(id: RouteID(model.id.rawValue), revision: 1, name: "Synthetic memory", modelDescriptorID: model.id,
            invocationID: "default", maximumOutputTokens: 2_048, configuration: schema)
        _ = try await group.credentialSettings.saveConnection(
            id: connection.id, name: connection.name, isEnabled: connection.isEnabled,
            definitionID: connection.definitionID, endpoints: connection.endpoints,
            discovery: connection.discovery, defaultInvocation: connection.defaultInvocation,
            previous: nil, credentialEndpointID: endpoint.id, credential: .keep)
        try await group.modelSettings.savePoolModel(model, preset: preset, expectedModelRevision: nil, expectedPresetRevision: nil)
        return try await group.modelSettings.resolve(purpose: AgentModelPurposeID.conversation,
            explicitRouteID: preset.id, sessionSelection: .inherit, workspaceID: nil).route
    }
}

private struct NativeMemoryModule: RuntimeModule {
    static let identity = AgentAdapterIdentity(id: "test.memory", revision: 1)
    let id = "test.memory"
    let dependencies: Set<String> = []
    let registry: RuntimeRegistry<AgentCapability>
    func activate(in scope: RuntimeScope) async throws {
        try await registry.register(id: id, value: .model(NativeMemoryAdapter()), scope: scope)
        try await registry.register(id: "test.memory.configuration", value: .modelConfiguration(NativeMemoryConfiguration()), scope: scope)
    }
}

private struct NativeMemoryConfiguration: AgentModelConfigurationProvider {
    let identity = NativeMemoryModule.identity
    func descriptor(for invocation: AgentModelInvocationSpec) throws -> AgentModelConfigurationDescriptor {
        let schema = AgentConfigurationSchema(identity: .init(id: "test.memory.schema", revision: 1), title: "Synthetic memory",
            schema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]), defaults: .object([:]))
        return .init(adapter: identity, title: "Synthetic memory", credential: .none, connection: schema, route: schema)
    }
    func configuration(for candidate: AgentModelRouteCandidate) throws -> JSONValue { .object([:]) }
}

private struct NativeMemoryAdapter: AgentModelAdapter {
    let identity = NativeMemoryModule.identity
    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        try input.validate(for: route)
        if !input.allowsToolCalls { #expect(input.tools.contains { $0.name == "memory.remember" }) }
        let wire = try SessionCodec.decode(JSONValue.self, from: SessionCodec.encode(input))
        let prepared = AgentPreparedModelRequest(adapter: identity, input: input, wirePayload: wire,
            estimatedInputTokens: try SessionCodec.encode(wire).count)
        try prepared.validate(for: route)
        return prepared
    }
    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        let (stream, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
        let text = request.input.allowsToolCalls ? "Done" : #"{"version":3,"items":[{"content":"I prefer dairy-free breakfasts with fruit and oats.","inputIndex":0,"kind":"preference","subject":"user","sensitivity":"standard","inferred":false,"stable":true,"confidence":"high","validFrom":null,"validUntil":null,"assertion":{"mode":"directStable","aspectKey":"food.breakfast","changeIntent":"independent"}}]}"#
        continuation.yield(.blockStarted(.init(id: "text", content: .text(text))))
        continuation.yield(.blockFinished(id: "text"))
        continuation.yield(.usage(.init(inputTokens: 100, outputTokens: 10)))
        continuation.yield(.finished(.stop))
        continuation.finish()
        return .init(events: stream, cancelAndDrain: { continuation.finish() })
    }
    func replay(_ messages: [AgentModelMessage], from source: AgentModelRoute, to target: AgentModelRoute, boundary: AgentReplayBoundary) throws -> AgentReplayDecision { .include(messages) }
}

private struct NativeMemoryNotifications: LocalNotificationPort {
    func permission() async -> NotificationPermission { .denied }
    func requestPermission() async throws -> Bool { false }
    func pending() async -> [ReminderNotification] { [] }
    func install(_ notification: ReminderNotification) async throws { throw MiraError(.unsupported, "Synthetic notifications are unavailable.") }
    func remove(_ identifier: String) async {}
}

private struct NativeMemoryCredentials: MacCredentialStore {
    func read(reference: String, version: Int) throws -> String { throw MiraError(.credentialMissing, "Synthetic memory never reads credentials.") }
    func save(_ secret: String, reference: String, version: Int) throws { throw MiraError(.unsupported, "Synthetic memory never writes credentials.") }
    func delete(reference: String, version: Int) throws {}
}
