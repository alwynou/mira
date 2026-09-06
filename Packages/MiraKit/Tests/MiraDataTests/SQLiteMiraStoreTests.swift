import Foundation
import CryptoKit
import Testing
@testable import MiraData
import MiraCore
import GRDB

@Suite("SQLite Mira store")
struct SQLiteMiraStoreTests {
    @Test func emptyConversationTitleIsAcceptedAndReadAsUntitled() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "", createdAt: .now, updatedAt: .now)

        try store.createConversation(conversation)

        #expect(try store.conversations(includeArchived: true).first?.title == "")
        let database = try DatabaseQueue(path: directory.appendingPathComponent("Mira.sqlite").path)
        #expect(try database.read { db in try String.fetchOne(db, sql: "SELECT title FROM conversations WHERE id = ?", arguments: [conversation.id.rawValue.uuidString.lowercased()]) } == "")
    }

    @Test func firstUserInputMatchingGeneratedTitleDoesNotRenameOnSecondSend() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let route = try installFixtureConfiguration(in: store)
        let first = try store.enqueue(conversationID: conversation.id, text: "New Conversation", route: route, executionID: .init(), messageID: .init(), at: .now)
        _ = try store.finish(executionID: first.id, status: .completed, text: "first reply", usage: .init(), error: nil, assistantMessageID: .init(), at: .now)
        let second = try store.enqueue(conversationID: conversation.id, text: "second message", route: route, executionID: .init(), messageID: .init(), at: .now)
        _ = try store.finish(executionID: second.id, status: .completed, text: "second reply", usage: .init(), error: nil, assistantMessageID: .init(), at: .now)

        #expect(try store.conversations(includeArchived: true).first?.title == "New Conversation")
    }

    @Test func oldSchemaVersionIsRejectedWithoutChangingTheLibraryFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do { _ = try SQLiteMiraStore(directory: directory) }
        let path = directory.appendingPathComponent("Mira.sqlite")
        let database = try DatabaseQueue(path: path.path)
        try database.write { db in try db.execute(sql: "PRAGMA user_version = 3") }
        let before = try Data(contentsOf: path)

        #expect(throws: MiraError.self) { _ = try SQLiteMiraStore(directory: directory) }
        #expect(try Data(contentsOf: path) == before)
    }

    @Test func schema8IsRejectedWithoutChangingTheLibraryFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do { _ = try SQLiteMiraStore(directory: directory) }
        let path = directory.appendingPathComponent("Mira.sqlite")
        let database = try DatabaseQueue(path: path.path)
        try database.write { db in try db.execute(sql: "PRAGMA user_version = 8") }
        let before = try Data(contentsOf: path)

        #expect(throws: MiraError.self) { _ = try SQLiteMiraStore(directory: directory) }
        #expect(try Data(contentsOf: path) == before)
    }

    @Test func schema9IsRejectedWithoutChangingTheLibraryFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do { _ = try SQLiteMiraStore(directory: directory) }
        let path = directory.appendingPathComponent("Mira.sqlite")
        let database = try DatabaseQueue(path: path.path)
        try database.write { db in try db.execute(sql: "PRAGMA user_version = 9") }
        let before = try Data(contentsOf: path)

        #expect(throws: MiraError.self) { _ = try SQLiteMiraStore(directory: directory) }
        #expect(try Data(contentsOf: path) == before)
    }

    @Test func catalogAndProtocolFieldsRoundTripThroughSchema11TypedMirrors() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let connection = ProviderConnection(name: "Catalog provider", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", credentialReference: "fixture")
        let catalog = ModelCatalogMetadata(providerID: "provider", modelID: "fixture", displayName: "Fixture", sourceURL: "https://catalog.example/models", sourceRevision: "2026-09", retrievedAt: "2026-09-06T00:00:00Z", contextWindow: 8192, maxOutputTokens: 512, inputModalities: ["text"], outputModalities: ["text"], toolCall: true, structuredOutput: false, reasoning: false, requiresReasoningContinuation: false)
        let model = ModelDescriptor(connectionID: connection.id, modelID: "fixture", contextWindow: 8192, textCapability: .declared, toolCapability: .declared, extractionCapability: .declared, protocolMode: .openAI, catalogMetadata: catalog)
        let route = ModelRoute(id: model.poolRouteID, name: "Fixture", modelDescriptorID: model.id, maxOutputTokens: 512)
        try store.saveConnection(connection, expectedRevision: nil)
        try store.savePoolModel(model, route: route, expectedModelRevision: nil, expectedRouteRevision: nil)

        let saved = try #require(try store.modelConfiguration().models.first)
        #expect(saved.extractionCapability == .declared)
        #expect(saved.protocolMode == .openAI)
        #expect(saved.catalogMetadata == catalog)
        #expect(try store.modelConfiguration().modelPool.first?.route.id == model.poolRouteID)
    }

    @Test func reasoningOnlyDraftRecoversAsInterruptedAssistantTrace() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "Thinking", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let route = try installFixtureConfiguration(in: store)
        let execution = try store.enqueue(conversationID: conversation.id, text: "question", route: route, executionID: .init(), messageID: .init(), at: .now)
        let trace: [CanonicalMessage] = [.init(role: .assistant, text: "", reasoning: .init(format: .openAIContent, text: "opaque partial", blocks: [.string("signed-block")]))]
        try store.checkpoint(executionID: execution.id, text: "", trace: trace, at: .now)
        try store.recoverInterrupted(at: .now)

        let messages = try store.messages(in: conversation.id)
        #expect(messages.last?.status == .interrupted)
        #expect(messages.last?.text == "")
        #expect(messages.last?.trace == trace)
        #expect(try store.draft(for: execution.id) == nil)
    }

    @Test func completeReasoningTraceSurvivesBackupAndMalformedTraceIsRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = directory.deletingLastPathComponent().appendingPathComponent("mira-thinking-\(UUID().uuidString).sqlite")
        let restore = directory.deletingLastPathComponent().appendingPathComponent("mira-thinking-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: backup); try? FileManager.default.removeItem(at: restore) }
        let store = try SQLiteMiraStore(directory: directory)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "Thinking", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let route = try installFixtureConfiguration(in: store)
        let execution = try store.enqueue(conversationID: conversation.id, text: "question", route: route, executionID: .init(), messageID: .init(), at: .now)
        let trace: [CanonicalMessage] = [.init(role: .assistant, text: "", reasoning: .init(format: .openAIContent, text: "opaque signed", blocks: [.object(["signature": .string("abc")])], isComplete: true))]
        try store.finish(executionID: execution.id, status: .completed, text: "answer", trace: trace, usage: .init(), error: nil, assistantMessageID: .init(), at: .now)
        try store.exportBackup(to: backup)
        try store.restoreBackup(from: backup, to: restore)
        let restored = try SQLiteMiraStore(directory: restore)
        #expect(try restored.messages(in: conversation.id).last?.trace == trace)

        let database = try DatabaseQueue(path: testBackupDatabaseURL(backup).path)
        try database.write { db in try db.execute(sql: "UPDATE messages SET trace_json = ? WHERE role = 'assistant'", arguments: ["not-json"]) }
        try resealTestBackupManifest(backup)
        #expect(throws: MiraError.self) { try store.restoreBackup(from: backup, to: restore.appendingPathComponent("malformed")) }
    }

    @Test func failedMigrationPreservesExistingRows() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseQueue(path: directory.appendingPathComponent("Mira.sqlite").path)
        try database.write { db in
            try db.execute(sql: "CREATE TABLE workspaces (legacy_text TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO workspaces VALUES ('must survive failed migration')")
        }
        #expect(throws: MiraError.self) { _ = try SQLiteMiraStore(directory: directory) }
        let preserved = try database.read { db in
            (try String.fetchOne(db, sql: "SELECT legacy_text FROM workspaces"),
             try Int.fetchOne(db, sql: "PRAGMA user_version"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE name='executions'"))
        }
        #expect(preserved.0 == "must survive failed migration")
        #expect(preserved.1 == 0)
        #expect(preserved.2 == 0)
    }

    @Test func modelConfigurationCRUDAndBindingCASRoundTrips() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let snapshot = try installFixtureConfiguration(in: store)

        var binding = RouteBinding(scope: .global, purpose: .conversation, routeID: snapshot.id)
        try store.saveRouteBinding(binding, expectedRevision: nil)
        let saved = try store.modelConfiguration()
        #expect(saved.connections.count == 1)
        #expect(saved.models.count == 1)
        #expect(saved.routes.count == 1)
        #expect(saved.bindings == [binding])
        #expect(try saved.resolve(purpose: .conversation).id == snapshot.id)

        binding.revision = 2
        try store.saveRouteBinding(binding, expectedRevision: 1)
        #expect(throws: MiraError.self) { try store.saveRouteBinding(binding, expectedRevision: 1) }
        var staleBinding = binding
        staleBinding.revision = 1
        #expect(throws: MiraError.self) { try store.removeRouteBinding(staleBinding) }
        try store.removeRouteBinding(binding)
        var route = saved.routes[0]
        route.revision = 2
        route.maxOutputTokens = 512
        try store.saveRoute(route, expectedRevision: 1)
        #expect(throws: MiraError.self) { try store.saveRoute(route, expectedRevision: 1) }
    }

    @Test func activationOnlyConnectionEditsPreserveFreshAttestationsButEndpointEditsStaleThem() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let connection = ProviderConnection(name: "Original", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", credentialReference: "fixture")
        var model = ModelDescriptor(connectionID: connection.id, connectionRevision: connection.revision, modelID: "fixture", contextWindow: 4096, textCapability: .verified, toolCapability: .verified, probeObservation: .init(type: .text, state: .verified))
        let route = ModelRoute(id: model.poolRouteID, name: "fixture", modelDescriptorID: model.id)
        try store.saveConnection(connection, expectedRevision: nil)
        try store.savePoolModel(model, route: route, expectedModelRevision: nil, expectedRouteRevision: nil)

        var renamed = connection
        renamed.revision = 2; renamed.name = "Renamed"; renamed.isEnabled = false
        try store.saveConnection(renamed, expectedRevision: 1)
        var configuration = try store.modelConfiguration()
        model = try #require(configuration.models.first)
        #expect(model.connectionRevision == 2)
        #expect(model.revision == 2)
        #expect(model.textCapability == .verified)
        #expect(configuration.modelPool.isEmpty)

        var endpointChanged = renamed
        endpointChanged.revision = 3; endpointChanged.baseURL = "https://changed.example/v1"; endpointChanged.isEnabled = true
        try store.saveConnection(endpointChanged, expectedRevision: 2)
        configuration = try store.modelConfiguration()
        model = try #require(configuration.models.first)
        #expect(model.connectionRevision == 2)
        #expect(try configuration.snapshot(routeID: route.id).textCapability == .unknown)
        var toggled = endpointChanged
        toggled.revision = 4; toggled.isEnabled = false
        try store.saveConnection(toggled, expectedRevision: 3)
        #expect(try store.modelConfiguration().models.first?.connectionRevision == 2)
        toggled.revision = 5; toggled.isEnabled = true
        try store.saveConnection(toggled, expectedRevision: 4)
        #expect(try store.modelConfiguration().snapshot(routeID: route.id).textCapability == .unknown)
    }

    @Test func unchangedConnectionSavePreservesCapabilitiesButKeyRotationDoesNot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        var connection = ProviderConnection(name: "Provider", providerKind: .anthropic, baseURL: "https://example.invalid/v1", credentialReference: "fixture")
        let model = ModelDescriptor(connectionID: connection.id, modelID: "fixture", contextWindow: 8192, textCapability: .verified)
        let route = ModelRoute(id: model.poolRouteID, name: "fixture", modelDescriptorID: model.id)
        try store.saveConnection(connection, expectedRevision: nil)
        try store.savePoolModel(model, route: route, expectedModelRevision: nil, expectedRouteRevision: nil)
        connection.revision = 2
        try store.saveConnection(connection, expectedRevision: 1)
        #expect(try store.modelConfiguration().snapshot(routeID: route.id).textCapability == .verified)
        connection.revision = 3; connection.credentialVersion = 2
        try store.saveConnection(connection, expectedRevision: 2)
        #expect(try store.modelConfiguration().snapshot(routeID: route.id).textCapability == .unknown)
    }

    @Test func savePoolModelIsAtomicAndUsesIndependentModelAndRouteCAS() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let connection = ProviderConnection(name: "Provider", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", credentialReference: "fixture")
        let model = ModelDescriptor(connectionID: connection.id, modelID: "fixture", contextWindow: 4096, textCapability: .declared)
        let route = ModelRoute(id: model.poolRouteID, name: "fixture", modelDescriptorID: model.id)
        try store.saveConnection(connection, expectedRevision: nil)
        try store.savePoolModel(model, route: route, expectedModelRevision: nil, expectedRouteRevision: nil)

        var changedModel = model
        changedModel.revision = 2; changedModel.isEnabled = false
        var changedRoute = route
        changedRoute.revision = 2; changedRoute.name = "Changed"
        #expect(throws: MiraError.self) {
            try store.savePoolModel(changedModel, route: changedRoute, expectedModelRevision: 1, expectedRouteRevision: 99)
        }
        let afterRollback = try store.modelConfiguration()
        #expect(afterRollback.models.first?.revision == 1)
        #expect(afterRollback.models.first?.isEnabled == true)
        #expect(afterRollback.routes.first?.revision == 1)

        try store.savePoolModel(changedModel, route: changedRoute, expectedModelRevision: 1, expectedRouteRevision: 1)
        let saved = try store.modelConfiguration()
        #expect(saved.models.first?.isEnabled == false)
        #expect(saved.routes.first?.name == "Changed")
    }

    @Test(arguments: [true, false]) func disabledProviderAndModelRoundTripThroughBackup(modelEnabled: Bool) throws {
        let directory = try temporaryDirectory()
        let backup = directory.deletingLastPathComponent().appendingPathComponent("mira-disabled-\(UUID().uuidString).sqlite")
        let restoredDirectory = directory.deletingLastPathComponent().appendingPathComponent("mira-disabled-restored-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.removeItem(at: restoredDirectory)
        }
        let store = try SQLiteMiraStore(directory: directory)
        let connection = ProviderConnection(name: "Provider", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", credentialReference: "fixture")
        let catalog = ModelCatalogMetadata(providerID: "fixture", modelID: "fixture", sourceURL: "https://catalog.example/models", sourceRevision: "fixture", retrievedAt: "2026-09-06", task: .textGeneration)
        var model = ModelDescriptor(connectionID: connection.id, modelID: "fixture", contextWindow: 4096, textCapability: .declared, extractionCapability: .verified, catalogMetadata: catalog)
        try store.saveConnection(connection, expectedRevision: nil)
        try store.savePoolModel(model, route: .init(id: model.poolRouteID, name: "fixture", modelDescriptorID: model.id), expectedModelRevision: nil, expectedRouteRevision: nil)
        var disabled = connection
        disabled.revision = 2; disabled.isEnabled = false
        try store.saveConnection(disabled, expectedRevision: 1)
        model.revision = 3; model.connectionRevision = 2; model.isEnabled = modelEnabled
        try store.savePoolModel(model, route: .init(id: model.poolRouteID, revision: 2, name: "fixture", modelDescriptorID: model.id), expectedModelRevision: 2, expectedRouteRevision: 1)
        try store.exportBackup(to: backup)
        try store.restoreBackup(from: backup, to: restoredDirectory)
        let restored = try SQLiteMiraStore(directory: restoredDirectory)
        let configuration = try restored.modelConfiguration()
        #expect(configuration.connections.first?.isEnabled == false)
        #expect(configuration.models.first?.isEnabled == modelEnabled)
        #expect(configuration.models.first?.extractionCapability == .verified)
        #expect(configuration.models.first?.catalogMetadata == catalog)
    }

    @Test func deletingConnectionCascadesConfigurationButPreservesExecutionSnapshotAndPolicy() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let snapshot = try installFixtureConfiguration(in: store)
        let workspace = Workspace(id: .init(), name: "Restricted", allowedConnectionIDs: [snapshot.connectionID])
        try store.saveWorkspace(workspace, expectedRevision: nil)
        let conversation = Conversation(id: .init(), workspaceID: workspace.id, title: "History", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let execution = try store.enqueue(conversationID: conversation.id, text: "preserve", route: snapshot, executionID: .init(), messageID: .init(), at: .now)

        try store.removeConnection(snapshot.connectionID)

        let configuration = try store.modelConfiguration()
        #expect(configuration.connections.isEmpty)
        #expect(configuration.models.isEmpty)
        #expect(configuration.routes.isEmpty)
        #expect(configuration.bindings.isEmpty)
        #expect(try store.execution(execution.id)?.route == snapshot)
        #expect(try store.workspaces().first?.allowedConnectionIDs == [])
    }

    @Test func staleModelConnectionRevisionCannotBeSavedAfterConnectionChange() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        _ = try installFixtureConfiguration(in: store)
        let configuration = try store.modelConfiguration()
        var connection = configuration.connections[0]
        connection.revision = 2
        try store.saveConnection(connection, expectedRevision: 1)
        var staleModel = configuration.models[0]
        staleModel.revision = 2
        #expect(throws: MiraError.self) { try store.saveModel(staleModel, expectedRevision: 1) }
    }

    @Test func routeBindingRequiresExistingScopeAndUsesStableScopePurposeID() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let snapshot = try installFixtureConfiguration(in: store)
        #expect(throws: MiraError.self) {
            try store.saveRouteBinding(RouteBinding(scope: .workspace(.init()), purpose: .conversation, routeID: snapshot.id), expectedRevision: nil)
        }
        #expect(throws: MiraError.self) {
            try store.saveRouteBinding(RouteBinding(scope: .global, purpose: .conversation, routeID: snapshot.id, revision: 1), expectedRevision: nil)
            try store.saveRouteBinding(RouteBinding(scope: .global, purpose: .conversation, routeID: snapshot.id), expectedRevision: nil)
        }
    }

    @Test func malformedConfigurationAndBindingJSONAreRejectedBeforeBackupInstall() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let snapshot = try installFixtureConfiguration(in: store)
        try store.saveRouteBinding(.init(scope: .global, purpose: .conversation, routeID: snapshot.id), expectedRevision: nil)
        let backup = directory.appendingPathComponent("config-corrupt.sqlite")
        let restored = directory.appendingPathComponent("config-corrupt-restored")
        defer { try? FileManager.default.removeItem(at: backup); try? FileManager.default.removeItem(at: restored) }
        try store.exportBackup(to: backup)
        let database = try DatabaseQueue(path: backup.appendingPathComponent("Mira.sqlite").path)
        try database.write { db in try db.execute(sql: "UPDATE provider_connections SET connection_json = '{}' WHERE id = ?", arguments: [snapshot.connectionID.rawValue.uuidString.lowercased()]) }
        try resealTestBackupManifest(backup)
        #expect(throws: MiraError.self) { try store.restoreBackup(from: backup, to: restored) }
        try FileManager.default.removeItem(at: backup)
        try store.exportBackup(to: backup)
        let secondDatabase = try DatabaseQueue(path: backup.appendingPathComponent("Mira.sqlite").path)
        try secondDatabase.write { db in try db.execute(sql: "UPDATE route_bindings SET binding_json = '{}' WHERE id = ?", arguments: ["global:conversation"]) }
        try resealTestBackupManifest(backup)
        #expect(throws: MiraError.self) { try store.restoreBackup(from: backup, to: restored) }
        #expect(!FileManager.default.fileExists(atPath: restored.path))
    }

    @Test func malformedHistoricalRouteSnapshotIsRejectedBeforeBackupInstall() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let snapshot = try installFixtureConfiguration(in: store)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "History", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        _ = try store.enqueue(conversationID: conversation.id, text: "snapshot", route: snapshot, executionID: .init(), messageID: .init(), at: .now)
        let backup = directory.appendingPathComponent("route-snapshot-corrupt.sqlite")
        let restored = directory.appendingPathComponent("route-snapshot-corrupt-restored")
        defer { try? FileManager.default.removeItem(at: backup); try? FileManager.default.removeItem(at: restored) }
        try store.exportBackup(to: backup)
        let database = try DatabaseQueue(path: backup.appendingPathComponent("Mira.sqlite").path)
        let originalRouteJSON = try database.read { db in try String.fetchOne(db, sql: "SELECT route_json FROM executions")! }
        var routeObject = try JSONSerialization.jsonObject(with: Data(originalRouteJSON.utf8)) as! [String: Any]
        routeObject["adapterVersion"] = "unknown-adapter/1"
        let malformedRouteJSON = String(decoding: try JSONSerialization.data(withJSONObject: routeObject), as: UTF8.self)
        let changedRows = try database.write { db -> Int in
            try db.execute(sql: "UPDATE executions SET route_json = ?", arguments: [malformedRouteJSON])
            return db.changesCount
        }
        let routeJSON = try database.read { db in try String.fetchOne(db, sql: "SELECT route_json FROM executions") }
        #expect(changedRows == 1)
        #expect(routeJSON?.contains("unknown-adapter\\/1") == true)
        try resealTestBackupManifest(backup)
        #expect(throws: MiraError.self) { try store.restoreBackup(from: backup, to: restored) }
        #expect(!FileManager.default.fileExists(atPath: restored.path))
    }

    @Test func malformedWorkspaceConnectionAllowlistIsRejectedFromBackup() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let snapshot = try installFixtureConfiguration(in: store)
        let workspace = Workspace(id: .init(), name: "Restricted", allowedConnectionIDs: [snapshot.connectionID])
        try store.saveWorkspace(workspace, expectedRevision: nil)
        let backup = directory.appendingPathComponent("allowlist-corrupt.sqlite")
        let restored = directory.appendingPathComponent("allowlist-corrupt-restored")
        defer { try? FileManager.default.removeItem(at: backup); try? FileManager.default.removeItem(at: restored) }
        try store.exportBackup(to: backup)
        let database = try DatabaseQueue(path: backup.appendingPathComponent("Mira.sqlite").path)
        try database.write { db in try db.execute(sql: "UPDATE workspaces SET allowed_connection_ids_json = '[\"malformed\"]' WHERE id = ?", arguments: [workspace.id.rawValue.uuidString.lowercased()]) }
        try resealTestBackupManifest(backup)
        #expect(throws: MiraError.self) { try store.restoreBackup(from: backup, to: restored) }
        #expect(!FileManager.default.fileExists(atPath: restored.path))
    }

    @Test func independentConnectionsRaceWithoutCreatingTwoActiveExecutions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SQLiteMiraStore(directory: directory), second = try SQLiteMiraStore(directory: directory)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "Race", createdAt: .now, updatedAt: .now)
        try first.createConversation(conversation)
        let route = try installFixtureConfiguration(in: first)
        let successes = await withTaskGroup(of: Bool.self) { group in
            for store in [first, second] {
                group.addTask {
                    do { _ = try store.enqueue(conversationID: conversation.id, text: "racing input", route: route, executionID: .init(), messageID: .init(), at: .now); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        #expect(successes == 1)
        #expect(try first.messages(in: conversation.id).count == 1)
        #expect(try first.executions(in: conversation.id).count == 1)
    }

    @Test func restoreRejectsMissingInvariantIndexBeforeInstallation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory.appendingPathComponent("live"))
        let backup = directory.appendingPathComponent("backup.sqlite")
        let restored = directory.appendingPathComponent("restored")
        try store.exportBackup(to: backup)
        do {
            let database = try DatabaseQueue(path: backup.appendingPathComponent("Mira.sqlite").path)
            try database.write { db in try db.execute(sql: "DROP INDEX executions_one_active_per_conversation") }
            try resealTestBackupManifest(backup)
        }
        #expect(throws: MiraError.self) { try store.restoreBackup(from: backup, to: restored) }
        #expect(!FileManager.default.fileExists(atPath: restored.path))
        #expect(try store.conversations(includeArchived: true).isEmpty)
    }

    @Test func persistsConversationAndExecutionAcrossReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let workspace = Workspace(id: WorkspaceID(), name: "Fixture")
        try store.saveWorkspace(workspace, expectedRevision: nil)
        let conversation = Conversation(id: ConversationID(), workspaceID: workspace.id, title: "Test", createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 10))
        try store.createConversation(conversation)
        let route = try installFixtureConfiguration(in: store, name: "Fixture route")
        let execution = try store.enqueue(conversationID: conversation.id, text: "hello", route: route, executionID: ExecutionID(), messageID: MessageID(), at: Date(timeIntervalSince1970: 11))
        let requestID = UUID()
        let request = CanonicalModelRequest(executionID: execution.id, system: "s", messages: [.init(role: .user, text: "hello")], requestID: requestID)
        let attempt = ModelAttempt(id: requestID, executionID: execution.id, stepID: UUID(), stepIndex: 1, request: request, createdAt: Date(timeIntervalSince1970: 12))
        try store.prepareAttempt(attempt)
        try store.checkpoint(executionID: execution.id, text: "partial", at: Date(timeIntervalSince1970: 13))
        let attemptUsage = TokenUsage(inputTokens: 100, outputTokens: 30, cacheReadTokens: 40, cacheWriteTokens: 5, reasoningTokens: 10)
        let executionUsage = TokenUsage(inputTokens: 200_000_000, outputTokens: 42, cacheReadTokens: 80, cacheWriteTokens: 10, reasoningTokens: 12, inputTokenBasis: .excludesCache)
        try store.finishAttempt(requestID, output: ModelOutput(text: "model", toolCalls: [], finishReason: .stop), invocations: [], usage: attemptUsage, error: nil, at: Date(timeIntervalSince1970: 13.5))
        _ = try store.finish(executionID: execution.id, status: .completed, text: "done", usage: executionUsage, error: nil, assistantMessageID: MessageID(), at: Date(timeIntervalSince1970: 14))

        let reopened = try SQLiteMiraStore(directory: directory)
        #expect(try reopened.workspaces() == [workspace])
        #expect(try reopened.messages(in: conversation.id).map(\.text) == ["hello", "done"])
        #expect(try reopened.executions(in: conversation.id).first?.status == .completed)
        #expect(try reopened.executions(in: conversation.id).first?.usage == executionUsage)
        #expect(try reopened.attempts(for: execution.id).first?.usage == attemptUsage)
        #expect(try reopened.draft(for: execution.id) == nil)
    }

    @Test func recoveryMaterializesDraftOnceAndTerminalFinishIsIdempotent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let conversation = Conversation(id: ConversationID(), workspaceID: nil, title: "Recovery", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let route = try installFixtureConfiguration(in: store)
        let execution = try store.enqueue(conversationID: conversation.id, text: "go", route: route, executionID: ExecutionID(), messageID: MessageID(), at: .now)
        try store.checkpoint(executionID: execution.id, text: "durable", at: .now)
        try store.recoverInterrupted(at: .now)
        try store.recoverInterrupted(at: .now)
        #expect(try store.executions(in: conversation.id).first?.status == .interrupted)
        #expect(try store.messages(in: conversation.id).filter { $0.role == .assistant }.map(\.text) == ["durable"])
        #expect(try store.finish(executionID: execution.id, status: .completed, text: "late", usage: .init(), error: nil, assistantMessageID: MessageID(), at: .now) == false)
    }

    @Test func concurrentFinishCommitsOneAssistantMessage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SQLiteMiraStore(directory: directory)
        let second = try SQLiteMiraStore(directory: directory)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "Finish race", createdAt: .now, updatedAt: .now)
        try first.createConversation(conversation)
        let route = try installFixtureConfiguration(in: first)
        let execution = try first.enqueue(conversationID: conversation.id, text: "question", route: route, executionID: .init(), messageID: .init(), at: .now)

        let results = await withTaskGroup(of: Bool.self) { group in
            for (store, text) in [(first, "first"), (second, "second")] {
                group.addTask {
                    do {
                        return try store.finish(executionID: execution.id, status: .completed, text: text, usage: .init(), error: nil, assistantMessageID: .init(), at: .now)
                    } catch {
                        return false
                    }
                }
            }
            var committed = 0
            for await result in group where result { committed += 1 }
            return committed
        }

        #expect(results == 1)
        #expect(try first.messages(in: conversation.id).filter { $0.role == .assistant }.count == 1)
        #expect(try first.executions(in: conversation.id).first?.status == .completed)
    }

    @Test func backupRestoresIntoUnusedDirectoryAndDiagnosticsProbeSQLite() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = directory.deletingLastPathComponent().appendingPathComponent("mira-backup-\(UUID().uuidString).sqlite")
        let restore = directory.deletingLastPathComponent().appendingPathComponent("mira-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: backup); try? FileManager.default.removeItem(at: restore) }
        let store = try SQLiteMiraStore(directory: directory)
        let conversation = Conversation(id: ConversationID(), workspaceID: nil, title: "Backup", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        #expect(try store.diagnostics().supportsFTS5)
        try store.exportBackup(to: backup)
        try store.restoreBackup(from: backup, to: restore)
        #expect(try SQLiteMiraStore(directory: restore).conversations(includeArchived: true).map(\.id) == [conversation.id])
    }

    @Test func enqueueFailureRollsBackExecutionAndRevisionConflictsAreRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SQLiteMiraStore(directory: directory)
        let second = try SQLiteMiraStore(directory: directory)
        let conversation = Conversation(id: ConversationID(), workspaceID: nil, title: "Atomic", createdAt: .now, updatedAt: .now)
        try first.createConversation(conversation)
        let messageID = MessageID()
        let route = try installFixtureConfiguration(in: first)
        let execution = try first.enqueue(conversationID: conversation.id, text: "one", route: route, executionID: ExecutionID(), messageID: messageID, at: .now)
        _ = try first.finish(executionID: execution.id, status: .completed, text: "ok", usage: .init(), error: nil, assistantMessageID: MessageID(), at: .now)
        let countBefore = try second.executions(in: conversation.id).count
        #expect(throws: MiraError.self) {
            _ = try second.enqueue(conversationID: conversation.id, text: "duplicate", route: route, executionID: ExecutionID(), messageID: messageID, at: .now)
        }
        #expect(try second.executions(in: conversation.id).count == countBefore)
        let workspace = Workspace(id: WorkspaceID(), name: "Revision")
        try first.saveWorkspace(workspace, expectedRevision: nil)
        #expect(throws: MiraError.self) { try second.saveWorkspace(Workspace(id: workspace.id, name: "stale", revision: 1), expectedRevision: nil) }
    }

    @Test func retryMustTargetLatestExecutionForTheTrigger() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let conversation = Conversation(id: ConversationID(), workspaceID: nil, title: "Retry", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let route = try installFixtureConfiguration(in: store)
        let original = try store.enqueue(conversationID: conversation.id, text: "retry", route: route, executionID: ExecutionID(), messageID: MessageID(), at: Date(timeIntervalSince1970: 1))
        _ = try store.finish(executionID: original.id, status: .failed, text: "partial", usage: .init(), error: MiraError(.network, "network"), assistantMessageID: MessageID(), at: Date(timeIntervalSince1970: 2))
        let replacement = try store.retry(executionID: original.id, newExecutionID: ExecutionID(), route: route, at: Date(timeIntervalSince1970: 3))
        #expect(throws: MiraError.self) { _ = try store.retry(executionID: original.id, newExecutionID: ExecutionID(), route: route, at: .now) }
        _ = try store.finish(executionID: replacement.id, status: .completed, text: "success", usage: .init(), error: nil, assistantMessageID: MessageID(), at: .now)
    }

    @Test func newerBackupIsRejectedWithoutChangingLiveStore() throws {
        let liveDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: liveDirectory) }
        let backup = liveDirectory.deletingLastPathComponent().appendingPathComponent("mira-newer-\(UUID().uuidString).sqlite")
        let restore = liveDirectory.deletingLastPathComponent().appendingPathComponent("mira-newer-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: backup); try? FileManager.default.removeItem(at: restore) }
        let store = try SQLiteMiraStore(directory: liveDirectory)
        let conversation = Conversation(id: ConversationID(), workspaceID: nil, title: "Live", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        try store.exportBackup(to: backup)
        do {
            let backupDB = try DatabaseQueue(path: backup.appendingPathComponent("Mira.sqlite").path)
            try backupDB.write { db in try db.execute(sql: "PRAGMA user_version = 99") }
        }
        try resealTestBackupManifest(backup)
        let sourceBytes = try Data(contentsOf: testBackupDatabaseURL(backup))
            #expect(SQLiteMiraStore.currentSchemaVersion == 11)
        #expect(throws: MiraError.self) { try store.restoreBackup(from: backup, to: restore) }
        #expect(try store.conversations(includeArchived: true).map(\.id) == [conversation.id])
        #expect(!FileManager.default.fileExists(atPath: restore.path))
        #expect(try Data(contentsOf: testBackupDatabaseURL(backup)) == sourceBytes)
    }

    @Test func unknownMigrationIsRejectedAndExistingParentModeIsPreserved() throws {
        let liveDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: liveDirectory) }
        let outputParent = liveDirectory.deletingLastPathComponent().appendingPathComponent("mira-backup-parent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputParent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: outputParent) }
        let beforeMode = try FileManager.default.attributesOfItem(atPath: outputParent.path)[.posixPermissions] as? NSNumber
        let backup = outputParent.appendingPathComponent("backup.sqlite")
        let restore = liveDirectory.deletingLastPathComponent().appendingPathComponent("mira-unknown-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: restore) }
        let store = try SQLiteMiraStore(directory: liveDirectory)
        let conversation = Conversation(id: ConversationID(), workspaceID: nil, title: "Migration", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        try store.exportBackup(to: backup)
        do {
            let backupDB = try DatabaseQueue(path: backup.appendingPathComponent("Mira.sqlite").path)
            try backupDB.write { db in try db.execute(sql: "UPDATE grdb_migrations SET identifier = 'future_migration' WHERE identifier = 'm0_core'") }
        }
        try resealTestBackupManifest(backup)
        #expect(throws: MiraError.self) { try store.restoreBackup(from: backup, to: restore) }
        #expect(try store.conversations(includeArchived: true).map(\.id) == [conversation.id])
        let afterMode = try FileManager.default.attributesOfItem(atPath: outputParent.path)[.posixPermissions] as? NSNumber
        #expect(beforeMode == afterMode)
    }

    @Test func malformedBackupRowsAreRejectedBeforeInstall() throws {
        let liveDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: liveDirectory) }
        let backup = liveDirectory.deletingLastPathComponent().appendingPathComponent("mira-malformed-\(UUID().uuidString).sqlite")
        let restore = liveDirectory.deletingLastPathComponent().appendingPathComponent("mira-malformed-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: backup); try? FileManager.default.removeItem(at: restore) }
        let store = try SQLiteMiraStore(directory: liveDirectory)
        let conversation = Conversation(id: ConversationID(), workspaceID: nil, title: "Safe", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        try store.exportBackup(to: backup)
        do {
            let backupDB = try DatabaseQueue(path: backup.appendingPathComponent("Mira.sqlite").path)
            try backupDB.write { db in try db.execute(sql: "UPDATE conversations SET id = 'malformed'") }
        }
        try resealTestBackupManifest(backup)
        #expect(throws: MiraError.self) { try store.restoreBackup(from: backup, to: restore) }
        #expect(!FileManager.default.fileExists(atPath: restore.path))
        #expect(try store.conversations(includeArchived: true).map(\.id) == [conversation.id])
    }

    @Test func malformedBusinessIDsSurfaceStorageErrorInsteadOfCrashing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let conversation = Conversation(id: ConversationID(), workspaceID: nil, title: "Corrupt", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let db = try DatabaseQueue(path: directory.appendingPathComponent("Mira.sqlite").path)
        try db.write { db in try db.execute(sql: "UPDATE conversations SET id = 'malformed' WHERE id = ?", arguments: [conversation.id.rawValue.uuidString.lowercased()]) }
        #expect(throws: MiraError.self) { _ = try store.conversations(includeArchived: true) }
    }

    @Test func auditPersistsExactCallsAndBlocksNextStepUntilEveryResultExists() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "Audit", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let route = try installFixtureConfiguration(in: store)
        let execution = try store.enqueue(conversationID: conversation.id, text: "tools", route: route, executionID: .init(), messageID: .init(), at: .now)
        let attemptID = UUID(), stepID = UUID()
        let request = CanonicalModelRequest(executionID: execution.id, system: "s", messages: [.init(role: .user, text: "tools")], requestID: attemptID)
        try store.prepareAttempt(.init(id: attemptID, executionID: execution.id, stepID: stepID, stepIndex: 1, request: request, createdAt: .now))
        #expect(try store.request(for: execution.id) == request)
        let calls = [CanonicalToolCall(id: "call-a", name: "fixture.read", arguments: "{\"q\":1}"), CanonicalToolCall(id: "call-b", name: "fixture.read", arguments: "{\"q\":2}")]
        let output = ModelOutput(text: "checking", toolCalls: calls, finishReason: .toolCalls)
        let invocations = calls.enumerated().map { ToolInvocation(id: UUID(), attemptID: attemptID, modelOrder: $0.offset, call: $0.element) }
        try store.finishAttempt(attemptID, output: output, invocations: invocations, usage: .init(inputTokens: 2, outputTokens: 3), error: nil, at: .now)
        #expect(try store.toolInvocations(for: execution.id).map(\.call) == calls)
        #expect(throws: MiraError.self) {
            let nextID = UUID()
            let nextRequest = CanonicalModelRequest(executionID: execution.id, system: "s", messages: [], requestID: nextID)
            try store.prepareAttempt(.init(id: nextID, executionID: execution.id, stepID: UUID(), stepIndex: 2, request: nextRequest, createdAt: .now))
        }
        try store.markToolDispatched(invocations[0].id, at: .now)
        #expect(try store.finishToolInvocation(invocations[0].id, result: .init(status: .succeeded, text: "one"), at: .now))
        #expect(try store.finishToolInvocation(invocations[0].id, result: .init(status: .succeeded, text: "duplicate"), at: .now) == false)
        #expect(try store.finishToolInvocation(invocations[1].id, result: .init(status: .denied, text: "no"), at: .now))
        let nextID = UUID()
        let nextRequest = CanonicalModelRequest(executionID: execution.id, system: "s", messages: [], requestID: nextID)
        try store.prepareAttempt(.init(id: nextID, executionID: execution.id, stepID: UUID(), stepIndex: 2, request: nextRequest, createdAt: .now))
        try store.finishAttempt(nextID, output: .init(text: "done", toolCalls: [], finishReason: .stop), invocations: [], usage: .init(), error: nil, at: .now)
        #expect(try store.finish(executionID: execution.id, status: .completed, text: "done", usage: .init(), error: nil, assistantMessageID: .init(), at: .now))

        let expectedAttempts = try store.attempts(for: execution.id)
        let expectedInvocations = try store.toolInvocations(for: execution.id)
        let backup = directory.appendingPathComponent("audit-backup.sqlite")
        let restoredDirectory = directory.appendingPathComponent("audit-restored")
        try store.exportBackup(to: backup)
        try store.restoreBackup(from: backup, to: restoredDirectory)
        let restored = try SQLiteMiraStore(directory: restoredDirectory)
        #expect(try restored.attempts(for: execution.id) == expectedAttempts)
        #expect(try restored.toolInvocations(for: execution.id) == expectedInvocations)

        let corrupted = directory.appendingPathComponent("audit-corrupted.sqlite")
        try FileManager.default.copyItem(at: backup, to: corrupted)
        let corruptedDB = try DatabaseQueue(path: testBackupDatabaseURL(corrupted).path)
        try corruptedDB.write { db in
            guard let original = try String.fetchOne(db, sql: "SELECT output_json FROM model_attempts WHERE id = ?", arguments: [attemptID.uuidString.lowercased()]) else { throw MiraError(.storage, "missing audit output") }
            var output = try JSONDecoder().decode(ModelOutput.self, from: Data(original.utf8))
            output.toolCalls[0].arguments = "{\"q\":999}"
            let changed = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
            try db.execute(sql: "UPDATE model_attempts SET output_json = ? WHERE id = ?", arguments: [changed, attemptID.uuidString.lowercased()])
        }
        try resealTestBackupManifest(corrupted)
        #expect(throws: MiraError.self) { try store.restoreBackup(from: corrupted, to: directory.appendingPathComponent("corrupted-restored")) }

        let reasoningCorrupted = directory.appendingPathComponent("audit-reasoning-corrupted.sqlite")
        try FileManager.default.copyItem(at: backup, to: reasoningCorrupted)
        let reasoningDB = try DatabaseQueue(path: testBackupDatabaseURL(reasoningCorrupted).path)
        try reasoningDB.write { db in
            guard let original = try String.fetchOne(db, sql: "SELECT output_json FROM model_attempts WHERE id = ?", arguments: [attemptID.uuidString.lowercased()]) else { throw MiraError(.storage, "missing audit output") }
            var output = try JSONDecoder().decode(ModelOutput.self, from: Data(original.utf8))
            output.reasoning = .init(format: .openAIContent, text: "partial", isComplete: false)
            let changed = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
            try db.execute(sql: "UPDATE model_attempts SET output_json = ? WHERE id = ?", arguments: [changed, attemptID.uuidString.lowercased()])
        }
        try resealTestBackupManifest(reasoningCorrupted)
        #expect(throws: MiraError.self) { try store.restoreBackup(from: reasoningCorrupted, to: directory.appendingPathComponent("reasoning-corrupted-restored")) }
    }

    @Test func incompleteModelReasoningIsRejectedBeforeToolAuditWrites() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "Incomplete thinking", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let route = try installFixtureConfiguration(in: store)
        let execution = try store.enqueue(conversationID: conversation.id, text: "question", route: route, executionID: .init(), messageID: .init(), at: .now)
        let attemptID = UUID()
        try store.prepareAttempt(.init(id: attemptID, executionID: execution.id, stepID: UUID(), stepIndex: 1, request: .init(executionID: execution.id, system: "", messages: [], requestID: attemptID), createdAt: .now))
        let call = CanonicalToolCall(id: "call", name: "fixture.read", arguments: "{}")
        let output = ModelOutput(text: "", toolCalls: [call], finishReason: .toolCalls, reasoning: .init(format: .openAIContent, text: "still thinking"))

        #expect(throws: MiraError.self) {
            try store.finishAttempt(attemptID, output: output, invocations: [.init(id: UUID(), attemptID: attemptID, modelOrder: 0, call: call)], usage: .init(), error: nil, at: .now)
        }
        #expect(try store.toolInvocations(for: execution.id).isEmpty)
        #expect(try store.attempts(for: execution.id).first?.status == .prepared)
        #expect(try store.attempts(for: execution.id).first?.output == nil)
    }

    @Test func invalidThinkingBudgetIsRejectedBeforeRouteCommit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let route = try installFixtureConfiguration(in: store)
        let invalid = ModelRoute(id: .init(), name: "Invalid thinking", modelDescriptorID: route.modelDescriptorID, thinking: .init(budgetTokens: -1))

        #expect(throws: MiraError.self) { try store.saveRoute(invalid, expectedRevision: nil) }
        #expect(try store.modelConfiguration().routes.count == 1)
    }

    @Test func recoveryClosesAuditCallsExactlyOnceByDispatchState() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "Recover audit", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let route = try installFixtureConfiguration(in: store)
        let execution = try store.enqueue(conversationID: conversation.id, text: "recover", route: route, executionID: .init(), messageID: .init(), at: .now)
        let attemptID = UUID()
        let request = CanonicalModelRequest(executionID: execution.id, system: "", messages: [], requestID: attemptID)
        try store.prepareAttempt(.init(id: attemptID, executionID: execution.id, stepID: UUID(), stepIndex: 1, request: request, createdAt: .now))
        let calls = [CanonicalToolCall(id: "started", name: "tool", arguments: "{}"), CanonicalToolCall(id: "queued", name: "tool", arguments: "{}")]
        let invocations = calls.enumerated().map { ToolInvocation(id: UUID(), attemptID: attemptID, modelOrder: $0.offset, call: $0.element) }
        try store.finishAttempt(attemptID, output: .init(text: "", toolCalls: calls, finishReason: .toolCalls), invocations: invocations, usage: .init(), error: nil, at: .now)
        try store.markToolDispatched(invocations[0].id, at: .now)
        try store.recoverInterrupted(at: .now)
        let first = try store.toolInvocations(for: execution.id)
        #expect(first.map { $0.result?.status } == [.interrupted, .cancelledBeforeDispatch])
        try store.recoverInterrupted(at: .now)
        #expect(try store.toolInvocations(for: execution.id).map { $0.result?.status } == [.interrupted, .cancelledBeforeDispatch])
        #expect(try store.executions(in: conversation.id).first?.status == .interrupted)
    }

    @Test func auditRejectsForeignAttemptAndTerminalizesOpenToolsOnFinish() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "Constraints", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let route = try installFixtureConfiguration(in: store)
        let execution = try store.enqueue(conversationID: conversation.id, text: "x", route: route, executionID: .init(), messageID: .init(), at: .now)
        let attemptID = UUID()
        let request = CanonicalModelRequest(executionID: execution.id, system: "", messages: [], requestID: attemptID)
        let stepID = UUID()
        try store.prepareAttempt(.init(id: attemptID, executionID: execution.id, stepID: stepID, stepIndex: 1, request: request, createdAt: .now))
        var configuration = Configuration(); configuration.foreignKeysEnabled = true
        let database = try DatabaseQueue(path: directory.appendingPathComponent("Mira.sqlite").path, configuration: configuration)
        #expect(throws: Error.self) {
            try database.write { db in
                try db.execute(sql: "INSERT INTO tool_invocations (id, execution_id, attempt_id, model_order, provider_call_id, tool_name, arguments_json, status, result_json, dispatched_at, completed_at) VALUES (?, ?, ?, 0, 'foreign', 'tool', '{}', 'pending', NULL, NULL, NULL)", arguments: [UUID().uuidString.lowercased(), execution.id.rawValue.uuidString.lowercased(), UUID().uuidString.lowercased()])
            }
        }
        let call = CanonicalToolCall(id: "c", name: "tool", arguments: "{}")
        let bad = ToolInvocation(id: UUID(), attemptID: UUID(), modelOrder: 0, call: call)
        #expect(throws: MiraError.self) {
            try store.finishAttempt(attemptID, output: .init(text: "", toolCalls: [call], finishReason: .toolCalls), invocations: [bad], usage: .init(), error: nil, at: .now)
        }
        #expect(try store.attempts(for: execution.id).first?.status == .prepared)
        #expect(try store.toolInvocations(for: execution.id).isEmpty)
        let good = ToolInvocation(id: UUID(), attemptID: attemptID, modelOrder: 0, call: call)
        try store.finishAttempt(attemptID, output: .init(text: "", toolCalls: [call], finishReason: .toolCalls), invocations: [good], usage: .init(), error: nil, at: .now)
        #expect(try store.finish(executionID: execution.id, status: .interrupted, text: "", usage: .init(), error: MiraError(.interrupted, "stop"), assistantMessageID: .init(), at: .now))
        #expect(try store.toolInvocations(for: execution.id).first?.result?.status == .cancelledBeforeDispatch)
    }

    @Test func completedStopCannotRetrySameStepOrOpenAnotherStep() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "Order", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let route = try installFixtureConfiguration(in: store)
        let execution = try store.enqueue(conversationID: conversation.id, text: "x", route: route, executionID: .init(), messageID: .init(), at: .now)
        let attemptID = UUID()
        let request = CanonicalModelRequest(executionID: execution.id, system: "", messages: [], requestID: attemptID)
        try store.prepareAttempt(.init(id: attemptID, executionID: execution.id, stepID: UUID(), stepIndex: 1, request: request, createdAt: .now))
        try store.finishAttempt(attemptID, output: .init(text: "done", toolCalls: [], finishReason: .stop), invocations: [], usage: .init(), error: nil, at: .now)
        #expect(throws: MiraError.self) {
            let retryID = UUID()
            try store.prepareAttempt(.init(id: retryID, executionID: execution.id, stepID: UUID(), stepIndex: 1, attemptIndex: 2, request: .init(executionID: execution.id, system: "", messages: [], requestID: retryID), createdAt: .now))
        }
        #expect(throws: MiraError.self) {
            let nextID = UUID()
            try store.prepareAttempt(.init(id: nextID, executionID: execution.id, stepID: UUID(), stepIndex: 2, request: .init(executionID: execution.id, system: "", messages: [], requestID: nextID), createdAt: .now))
        }
    }

    private func installFixtureConfiguration(in store: SQLiteMiraStore, name: String = "Fixture") throws -> ResolvedModelRouteSnapshot {
        let snapshot = ResolvedModelRouteSnapshot(name: name, providerKind: .openAICompatible, baseURL: "https://example.invalid", modelID: "fixture", credentialReference: "keychain.fixture", contextWindow: 4096)
        let connection = ProviderConnection(id: snapshot.connectionID, revision: snapshot.connectionRevision, name: "Fixture connection", providerKind: snapshot.providerKind, baseURL: snapshot.baseURL, credentialReference: snapshot.credentialReference, credentialVersion: snapshot.credentialVersion, allowsLoopbackHTTP: snapshot.allowsLoopbackHTTP)
        let model = ModelDescriptor(id: snapshot.modelDescriptorID, revision: snapshot.modelRevision, connectionID: snapshot.connectionID, connectionRevision: snapshot.connectionRevision, modelID: snapshot.modelID, contextWindow: snapshot.contextWindow, textCapability: snapshot.textCapability, toolCapability: snapshot.toolCapability, probeObservation: snapshot.probeObservation)
        let route = ModelRoute(id: snapshot.id, revision: snapshot.revision, name: snapshot.name, modelDescriptorID: snapshot.modelDescriptorID, maxOutputTokens: snapshot.maxOutputTokens, requestsUsage: snapshot.requestsUsage)
        try store.saveConnection(connection, expectedRevision: nil)
        try store.saveModel(model, expectedRevision: nil)
        try store.saveRoute(route, expectedRevision: nil)
        return snapshot
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mira-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
}

func testBackupDatabaseURL(_ backup: URL) -> URL {
    backup.appendingPathComponent("Mira.sqlite")
}

func resealTestBackupManifest(_ backup: URL) throws {
    let databaseURL = testBackupDatabaseURL(backup)
    let databaseBytes = try Data(contentsOf: databaseURL)
    let manifestURL = backup.appendingPathComponent("manifest.json")
    let manifestData = try Data(contentsOf: manifestURL)
    var manifest = try #require(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
    var database = try #require(manifest["database"] as? [String: Any])
    database["digest"] = SHA256.hash(data: databaseBytes).map { String(format: "%02x", $0) }.joined()
    database["byteCount"] = databaseBytes.count
    manifest["database"] = database
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: manifestURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
}
