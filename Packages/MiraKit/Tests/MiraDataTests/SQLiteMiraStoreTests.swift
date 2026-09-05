import Foundation
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
        let route = fixtureRoute()
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
        try database.write { db in try db.execute(sql: "PRAGMA user_version = 2") }
        let before = try Data(contentsOf: path)

        #expect(throws: MiraError.self) { _ = try SQLiteMiraStore(directory: directory) }
        #expect(try Data(contentsOf: path) == before)
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

    @Test func independentConnectionsRaceWithoutCreatingTwoActiveExecutions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SQLiteMiraStore(directory: directory), second = try SQLiteMiraStore(directory: directory)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "Race", createdAt: .now, updatedAt: .now)
        try first.createConversation(conversation)
        let route = fixtureRoute()
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
            let database = try DatabaseQueue(path: backup.path)
            try database.write { db in try db.execute(sql: "DROP INDEX executions_one_active_per_conversation") }
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
        let route = ModelRoute(name: "Fixture route", providerKind: .openAICompatible, baseURL: "https://example.invalid", modelID: "fixture", credentialReference: "keychain.fixture", contextWindow: 4096)
        let execution = try store.enqueue(conversationID: conversation.id, text: "hello", route: route, executionID: ExecutionID(), messageID: MessageID(), at: Date(timeIntervalSince1970: 11))
        let requestID = UUID()
        let request = CanonicalModelRequest(executionID: execution.id, system: "s", messages: [.init(role: .user, text: "hello")], requestID: requestID)
        let attempt = ModelAttempt(id: requestID, executionID: execution.id, stepID: UUID(), stepIndex: 1, request: request, createdAt: Date(timeIntervalSince1970: 12))
        try store.prepareAttempt(attempt)
        try store.checkpoint(executionID: execution.id, text: "partial", at: Date(timeIntervalSince1970: 13))
        try store.finishAttempt(requestID, output: ModelOutput(text: "model", toolCalls: [], finishReason: .stop), invocations: [], usage: TokenUsage(inputTokens: 1, outputTokens: 1), error: nil, at: Date(timeIntervalSince1970: 13.5))
        _ = try store.finish(executionID: execution.id, status: .completed, text: "done", usage: TokenUsage(inputTokens: 1, outputTokens: 2), error: nil, assistantMessageID: MessageID(), at: Date(timeIntervalSince1970: 14))

        let reopened = try SQLiteMiraStore(directory: directory)
        #expect(try reopened.workspaces() == [workspace])
        #expect(try reopened.messages(in: conversation.id).map(\.text) == ["hello", "done"])
        #expect(try reopened.executions(in: conversation.id).first?.status == .completed)
        #expect(try reopened.draft(for: execution.id) == nil)
    }

    @Test func recoveryMaterializesDraftOnceAndTerminalFinishIsIdempotent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let conversation = Conversation(id: ConversationID(), workspaceID: nil, title: "Recovery", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let execution = try store.enqueue(conversationID: conversation.id, text: "go", route: fixtureRoute(), executionID: ExecutionID(), messageID: MessageID(), at: .now)
        try store.checkpoint(executionID: execution.id, text: "durable", at: .now)
        try store.recoverInterrupted(at: .now)
        try store.recoverInterrupted(at: .now)
        #expect(try store.executions(in: conversation.id).first?.status == .interrupted)
        #expect(try store.messages(in: conversation.id).filter { $0.role == .assistant }.map(\.text) == ["durable"])
        #expect(try store.finish(executionID: execution.id, status: .completed, text: "late", usage: .init(), error: nil, assistantMessageID: MessageID(), at: .now) == false)
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
        let execution = try first.enqueue(conversationID: conversation.id, text: "one", route: fixtureRoute(), executionID: ExecutionID(), messageID: messageID, at: .now)
        _ = try first.finish(executionID: execution.id, status: .completed, text: "ok", usage: .init(), error: nil, assistantMessageID: MessageID(), at: .now)
        let countBefore = try second.executions(in: conversation.id).count
        #expect(throws: MiraError.self) {
            _ = try second.enqueue(conversationID: conversation.id, text: "duplicate", route: fixtureRoute(), executionID: ExecutionID(), messageID: messageID, at: .now)
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
        let original = try store.enqueue(conversationID: conversation.id, text: "retry", route: fixtureRoute(), executionID: ExecutionID(), messageID: MessageID(), at: Date(timeIntervalSince1970: 1))
        _ = try store.finish(executionID: original.id, status: .failed, text: "partial", usage: .init(), error: MiraError(.network, "network"), assistantMessageID: MessageID(), at: Date(timeIntervalSince1970: 2))
        let replacement = try store.retry(executionID: original.id, newExecutionID: ExecutionID(), route: fixtureRoute(), at: Date(timeIntervalSince1970: 3))
        #expect(throws: MiraError.self) { _ = try store.retry(executionID: original.id, newExecutionID: ExecutionID(), route: fixtureRoute(), at: .now) }
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
        let backupDB = try DatabaseQueue(path: backup.path)
        try backupDB.write { db in try db.execute(sql: "PRAGMA user_version = 99") }
        let sourceBytes = try Data(contentsOf: backup)
        #expect(throws: MiraError.self) { try store.restoreBackup(from: backup, to: restore) }
        #expect(try store.conversations(includeArchived: true).map(\.id) == [conversation.id])
        #expect(!FileManager.default.fileExists(atPath: restore.path))
        #expect(try Data(contentsOf: backup) == sourceBytes)
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
        let backupDB = try DatabaseQueue(path: backup.path)
        try backupDB.write { db in try db.execute(sql: "UPDATE grdb_migrations SET identifier = 'future_migration' WHERE identifier = 'm0_core'") }
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
        let backupDB = try DatabaseQueue(path: backup.path)
        try backupDB.write { db in try db.execute(sql: "UPDATE conversations SET id = 'malformed'") }
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
        let execution = try store.enqueue(conversationID: conversation.id, text: "tools", route: fixtureRoute(), executionID: .init(), messageID: .init(), at: .now)
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
        let corruptedDB = try DatabaseQueue(path: corrupted.path)
        try corruptedDB.write { db in
            guard let original = try String.fetchOne(db, sql: "SELECT output_json FROM model_attempts WHERE id = ?", arguments: [attemptID.uuidString.lowercased()]) else { throw MiraError(.storage, "missing audit output") }
            var output = try JSONDecoder().decode(ModelOutput.self, from: Data(original.utf8))
            output.toolCalls[0].arguments = "{\"q\":999}"
            let changed = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
            try db.execute(sql: "UPDATE model_attempts SET output_json = ? WHERE id = ?", arguments: [changed, attemptID.uuidString.lowercased()])
        }
        #expect(throws: MiraError.self) { try store.restoreBackup(from: corrupted, to: directory.appendingPathComponent("corrupted-restored")) }
    }

    @Test func recoveryClosesAuditCallsExactlyOnceByDispatchState() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "Recover audit", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let execution = try store.enqueue(conversationID: conversation.id, text: "recover", route: fixtureRoute(), executionID: .init(), messageID: .init(), at: .now)
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
        let execution = try store.enqueue(conversationID: conversation.id, text: "x", route: fixtureRoute(), executionID: .init(), messageID: .init(), at: .now)
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
        let execution = try store.enqueue(conversationID: conversation.id, text: "x", route: fixtureRoute(), executionID: .init(), messageID: .init(), at: .now)
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

    private func fixtureRoute() -> ModelRoute {
        ModelRoute(name: "Fixture", providerKind: .openAICompatible, baseURL: "https://example.invalid", modelID: "fixture", credentialReference: "keychain.fixture", contextWindow: 4096)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mira-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
}
