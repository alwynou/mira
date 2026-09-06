import Foundation
import GRDB
import MiraCore
import Testing
@testable import MiraData

@Suite("Memory privacy backup validation")
struct MemoryPrivacyTests {
    private let forgottenMemoryBodyError = "The forgotten memory still contains a body."
    private let missingSuppressionError = "The memory source suppression is missing."
    private let inconsistentSuppressionError = "The memory suppression record is inconsistent."
    private let auditContentsError = "The database audit contents are invalid."

    @Test func restoreRejectsCoherentRetainedEvidenceForForgottenMemory() throws {
        let (store, directory, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = try store.createMemory(
            draft: .init(content: "Private preference", scope: .global),
            source: .manualEntry(id: UUID(), statement: "Private preference"),
            operationID: UUID(), replacing: nil, expectedRevision: nil, at: date(10)
        ).memory
        _ = try store.forgetMemory(memory.id, workspaceID: nil, expectedRevision: memory.revision, at: date(11))

        let backup = try export(store, in: directory, name: "retained-evidence")
        let database = try DatabaseQueue(path: backup.appendingPathComponent("Mira.sqlite").path)
        let before = try database.read { db in
            try String.fetchOne(db, sql: "SELECT evidence_json FROM memory_evidence WHERE memory_id = ?", arguments: [id(memory.id)])
        }
        guard let before else { Issue.record("The forgotten memory evidence row was not present."); return }
        var evidence = try decode(MemoryEvidence.self, from: before)
        evidence.excerpt = "Private preference"
        evidence.sourceHash = "retained-body-hash"
        evidence.bodyPurgedAt = nil
        let encoded = try encode(evidence)
        let changed = try database.write { db -> Int in
            try db.execute(sql: "UPDATE memory_evidence SET excerpt = ?, source_hash = ?, body_purged_at = NULL, evidence_json = ? WHERE memory_id = ?", arguments: [evidence.excerpt, evidence.sourceHash, encoded, id(memory.id)])
            return db.changesCount
        }
        #expect(changed == 1)
        try resealTestBackupManifest(backup)
        let after = try database.read { db in
            try String.fetchOne(db, sql: "SELECT evidence_json FROM memory_evidence WHERE memory_id = ?", arguments: [id(memory.id)])
        }
        #expect(after != before)
        try expectRestoreError(store, backup: backup, name: "retained-evidence-restored", message: forgottenMemoryBodyError)
        try cleanup(backup)
    }

    @Test func restoreRejectsCoherentRetainedRevisionDraftForForgottenMemory() throws {
        let (store, directory, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = try store.createMemory(
            draft: .init(content: "Private preference", scope: .global),
            source: .manualEntry(id: UUID(), statement: "Private preference"),
            operationID: UUID(), replacing: nil, expectedRevision: nil, at: date(10)
        ).memory
        _ = try store.forgetMemory(memory.id, workspaceID: nil, expectedRevision: memory.revision, at: date(11))

        let backup = try export(store, in: directory, name: "retained-revision")
        let database = try DatabaseQueue(path: backup.appendingPathComponent("Mira.sqlite").path)
        let before = try database.read { db in
            try Row.fetchOne(db, sql: "SELECT draft_json, revision_json FROM memory_revisions WHERE memory_id = ? AND revision = 1", arguments: [id(memory.id)])
        }
        guard let before else { Issue.record("The forgotten memory revision row was not present."); return }
        let retainedDraft = MemoryDraft(content: "Private preference", scope: .global)
        let retainedRevision = MemoryRevision(memoryID: memory.id, revision: 1, draft: retainedDraft, actor: "user", changedAt: date(10))
        let draftJSON = try encode(retainedDraft)
        let revisionJSON = try encode(retainedRevision)
        let changed = try database.write { db -> Int in
            try db.execute(sql: "UPDATE memory_revisions SET draft_json = ?, body_purged_at = NULL, revision_json = ? WHERE memory_id = ? AND revision = 1", arguments: [draftJSON, revisionJSON, id(memory.id)])
            return db.changesCount
        }
        #expect(changed == 1)
        try resealTestBackupManifest(backup)
        let after = try database.read { db in
            try Row.fetchOne(db, sql: "SELECT draft_json, revision_json FROM memory_revisions WHERE memory_id = ? AND revision = 1", arguments: [id(memory.id)])
        }
        #expect((after?["draft_json"] as String?) != (before["draft_json"] as String?))
        #expect((after?["revision_json"] as String?) != (before["revision_json"] as String?))
        try expectRestoreError(store, backup: backup, name: "retained-revision-restored", message: forgottenMemoryBodyError)
        try cleanup(backup)
    }

    @Test func restoreRejectsRecreatedFTSBodyForForgottenMemory() throws {
        let (store, directory, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = try store.createMemory(
            draft: .init(content: "Private preference", scope: .global),
            source: .manualEntry(id: UUID(), statement: "Private preference"),
            operationID: UUID(), replacing: nil, expectedRevision: nil, at: date(10)
        ).memory
        _ = try store.forgetMemory(memory.id, workspaceID: nil, expectedRevision: memory.revision, at: date(11))

        let backup = try export(store, in: directory, name: "recreated-fts")
        let database = try DatabaseQueue(path: backup.appendingPathComponent("Mira.sqlite").path)
        let before = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_search WHERE memory_id = ?", arguments: [id(memory.id)]) ?? 0
        }
        #expect(before == 0)
        let changed = try database.write { db -> Int in
            try db.execute(sql: "INSERT INTO memory_search (memory_id, content) VALUES (?, ?)", arguments: [id(memory.id), "Private preference"])
            return db.changesCount
        }
        #expect(changed == 1)
        try resealTestBackupManifest(backup)
        let after = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_search WHERE memory_id = ?", arguments: [id(memory.id)]) ?? 0
        }
        #expect(after == 1)
        try expectRestoreError(store, backup: backup, name: "recreated-fts-restored", message: forgottenMemoryBodyError)
        try cleanup(backup)
    }

    @Test(arguments: ["delete", "json-mismatch"])
    func restoreRejectsMissingOrMismatchedForgottenSourceSuppression(_ mutation: String) throws {
        let (store, directory, route) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "", createdAt: date(1), updatedAt: date(1))
        try store.createConversation(conversation)
        let execution = try store.enqueue(conversationID: conversation.id, text: "Remember my preference", route: route, executionID: .init(), messageID: .init(), at: date(2))
        let source = try #require(try store.messages(in: conversation.id).first)
        let memory = try store.createMemory(
            draft: .init(content: "Remember my preference", scope: .global),
            source: .message(id: source.id, excerpt: source.text),
            operationID: UUID(), replacing: nil, expectedRevision: nil, at: date(3)
        ).memory
        _ = try store.forgetMemory(memory.id, workspaceID: nil, expectedRevision: memory.revision, at: date(4))

        let backup = try export(store, in: directory, name: "suppression-\(mutation)")
        let database = try DatabaseQueue(path: backup.appendingPathComponent("Mira.sqlite").path)
        let sourceID = id(source.id)
        let before = try database.read { db in
            try Row.fetchOne(db, sql: "SELECT reason, suppression_json FROM memory_source_suppressions WHERE source_kind = 'message' AND source_id = ?", arguments: [sourceID])
        }
        guard let before else { Issue.record("The forgotten message suppression row was not present."); return }
        if mutation == "delete" {
            let changed = try database.write { db -> Int in
                try db.execute(sql: "DELETE FROM memory_source_suppressions WHERE source_kind = 'message' AND source_id = ?", arguments: [sourceID])
                return db.changesCount
            }
            #expect(changed == 1)
            try resealTestBackupManifest(backup)
            let after = try database.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_source_suppressions WHERE source_kind = 'message' AND source_id = ?", arguments: [sourceID]) ?? 0
            }
            #expect(after == 0)
            try expectRestoreError(store, backup: backup, name: "suppression-delete-restored", message: missingSuppressionError)
        } else {
            let originalJSON = before["suppression_json"] as String
            var object = try JSONSerialization.jsonObject(with: Data(originalJSON.utf8)) as! [String: Any]
            object["reason"] = "removed"
            let mismatchedJSON = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            let changed = try database.write { db -> Int in
                try db.execute(sql: "UPDATE memory_source_suppressions SET suppression_json = ? WHERE source_kind = 'message' AND source_id = ?", arguments: [mismatchedJSON, sourceID])
                return db.changesCount
            }
            #expect(changed == 1)
            try resealTestBackupManifest(backup)
            let after = try database.read { db in
                try String.fetchOne(db, sql: "SELECT suppression_json FROM memory_source_suppressions WHERE source_kind = 'message' AND source_id = ?", arguments: [sourceID])
            }
            #expect(after != originalJSON)
            try expectRestoreError(store, backup: backup, name: "suppression-json-restored", message: inconsistentSuppressionError)
        }
        _ = execution
        try cleanup(backup)
    }

    @Test(arguments: ["execution_steps", "tool_invocations", "assistant_drafts"])
    func restoreRejectsRetainedAuditChildrenUnderPurgedExecution(_ child: String) throws {
        let (store, directory, route) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "", createdAt: date(1), updatedAt: date(1))
        try store.createConversation(conversation)
        let execution = try store.enqueue(conversationID: conversation.id, text: "Remember this", route: route, executionID: .init(), messageID: .init(), at: date(2))
        let source = try #require(try store.messages(in: conversation.id).first)
        let memory = try store.createMemory(draft: .init(content: "Remember this", scope: .global), source: .message(id: source.id, excerpt: source.text), operationID: UUID(), replacing: nil, expectedRevision: nil, at: date(3)).memory
        let attemptID = UUID()
        try store.prepareAttempt(.init(id: attemptID, executionID: execution.id, stepID: UUID(), stepIndex: 1, request: .init(executionID: execution.id, system: "system", messages: [], requestID: attemptID), createdAt: date(4)))
        let thinking: [CanonicalMessage] = [.init(role: .assistant, text: "", reasoning: .init(format: .openAIContent, text: "private thought", blocks: [.string("signed opaque")]))]
        try store.checkpoint(executionID: execution.id, text: "draft body", trace: thinking, at: date(5))
        let call = CanonicalToolCall(id: "call-1", name: "fixture.read", arguments: "{}")
        let output = ModelOutput(text: "tool request", toolCalls: [call], finishReason: .toolCalls)
        let invocation = ToolInvocation(id: UUID(), attemptID: attemptID, modelOrder: 0, call: call)
        try store.finishAttempt(attemptID, output: output, invocations: [invocation], usage: .init(inputTokens: 1, outputTokens: 1), error: nil, at: date(6))
        try store.markToolDispatched(invocation.id, at: date(7))
        #expect(try store.finishToolInvocation(invocation.id, result: .init(status: .succeeded, text: "tool result"), at: date(8)))
        try store.recordMemoryUsage([.init(memoryID: memory.id, revision: memory.revision)], executionID: execution.id, at: date(9))
        _ = try store.forgetMemory(memory.id, workspaceID: nil, expectedRevision: memory.revision, at: date(10))

        let backup = try export(store, in: directory, name: "retained-audit")
        let database = try DatabaseQueue(path: backup.appendingPathComponent("Mira.sqlite").path)
        let stepBefore = try database.read { db in try Row.fetchOne(db, sql: "SELECT body_purged_at, output_json FROM execution_steps WHERE execution_id = ?", arguments: [id(execution.id)]) }
        let toolBefore = try database.read { db in try Row.fetchOne(db, sql: "SELECT body_purged_at, arguments_json, result_json FROM tool_invocations WHERE execution_id = ?", arguments: [id(execution.id)]) }
        let draftBefore = try database.read { db in try Row.fetchOne(db, sql: "SELECT body_purged_at, text, trace_json FROM assistant_drafts WHERE execution_id = ?", arguments: [id(execution.id)]) }
        guard stepBefore != nil, toolBefore != nil, draftBefore != nil else { Issue.record("The purged audit child rows were not present."); return }
        #expect((draftBefore?["trace_json"] as String?) == "[]")
        let retainedOutput = try encode(output)
        let retainedResult = try encode(ToolResult(status: .succeeded, text: "retained result"))
        let changed = try database.write { db -> Int in
            switch child {
            case "execution_steps": try db.execute(sql: "UPDATE execution_steps SET body_purged_at = NULL, output_json = ? WHERE execution_id = ?", arguments: [retainedOutput, id(execution.id)])
            case "tool_invocations": try db.execute(sql: "UPDATE tool_invocations SET body_purged_at = NULL, arguments_json = '{}', result_json = ? WHERE execution_id = ?", arguments: [retainedResult, id(execution.id)])
            default: try db.execute(sql: "UPDATE assistant_drafts SET body_purged_at = NULL, text = 'retained draft' WHERE execution_id = ?", arguments: [id(execution.id)])
            }
            return db.changesCount
        }
        #expect(changed == 1)
        try resealTestBackupManifest(backup)
        let retainedRows = try database.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT count(*) FROM execution_steps WHERE execution_id = ? AND body_purged_at IS NULL AND output_json IS NOT NULL", arguments: [id(execution.id)]) ?? 0,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM tool_invocations WHERE execution_id = ? AND body_purged_at IS NULL AND arguments_json IS NOT NULL AND result_json IS NOT NULL", arguments: [id(execution.id)]) ?? 0,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM assistant_drafts WHERE execution_id = ? AND body_purged_at IS NULL AND text = 'retained draft'", arguments: [id(execution.id)]) ?? 0
            )
        }
        #expect(retainedRows.0 == (child == "execution_steps" ? 1 : 0))
        #expect(retainedRows.1 == (child == "tool_invocations" ? 1 : 0))
        #expect(retainedRows.2 == (child == "assistant_drafts" ? 1 : 0))
        try expectRestoreError(store, backup: backup, name: "retained-audit-restored", message: auditContentsError)
        try cleanup(backup)
    }

    @Test func restoreAcceptsHistoricalMemoryUsageAfterMemoryRevision() throws {
        let (store, directory, route) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "", createdAt: date(1), updatedAt: date(1))
        try store.createConversation(conversation)
        let execution = try store.enqueue(conversationID: conversation.id, text: "Use my preference", route: route, executionID: .init(), messageID: .init(), at: date(2))
        let memory = try store.createMemory(draft: .init(content: "Prefers tea", scope: .global), source: .manualEntry(id: UUID(), statement: "Prefers tea"), operationID: UUID(), replacing: nil, expectedRevision: nil, at: date(3)).memory
        let attemptID = UUID()
        try store.prepareAttempt(.init(id: attemptID, executionID: execution.id, stepID: UUID(), stepIndex: 1, request: .init(executionID: execution.id, system: "system", messages: [], requestID: attemptID), createdAt: date(4)))
        try store.recordMemoryUsage([.init(memoryID: memory.id, revision: 1)], executionID: execution.id, at: date(5))
        var revisedDraft = memory.draft!
        revisedDraft.content = "Prefers green tea"
        let revised = try store.reviseMemory(memory.id, workspaceID: nil, draft: revisedDraft, expectedRevision: 1, at: date(6))
        #expect(revised.revision == 2)

        let backup = try export(store, in: directory, name: "historical-usage")
        let restoredDirectory = directory.appendingPathComponent("historical-usage-restored")
        try store.restoreBackup(from: backup, to: restoredDirectory)
        let restored = try SQLiteMiraStore(directory: restoredDirectory)
        #expect(try restored.memoryDetail(memory.id, workspaceID: nil).memory.revision == 2)
        let database = try DatabaseQueue(path: restoredDirectory.appendingPathComponent("Mira.sqlite").path)
        let usageRevision = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT revision FROM memory_usages WHERE execution_id = ? AND memory_id = ?", arguments: [id(execution.id), id(memory.id)])
        }
        #expect(usageRevision == 1)
        try cleanup(backup)
        try? FileManager.default.removeItem(at: restoredDirectory)
    }

    private func makeStore() throws -> (SQLiteMiraStore, URL, ResolvedModelRouteSnapshot) {
        let directory = try temporaryDirectory()
        let store = try SQLiteMiraStore(directory: directory)
        let route = ResolvedModelRouteSnapshot(name: "Fixture", providerKind: .openAICompatible, baseURL: "https://example.invalid", modelID: "fixture", credentialReference: "fixture", contextWindow: 4096)
        try store.saveConnection(.init(id: route.connectionID, revision: route.connectionRevision, name: "Fixture connection", providerKind: route.providerKind, baseURL: route.baseURL, credentialReference: route.credentialReference, credentialVersion: route.credentialVersion), expectedRevision: nil)
        try store.saveModel(.init(id: route.modelDescriptorID, revision: route.modelRevision, connectionID: route.connectionID, connectionRevision: route.connectionRevision, modelID: route.modelID, contextWindow: route.contextWindow, textCapability: route.textCapability, toolCapability: route.toolCapability, probeObservation: route.probeObservation), expectedRevision: nil)
        try store.saveRoute(.init(id: route.id, revision: route.revision, name: route.name, modelDescriptorID: route.modelDescriptorID, maxOutputTokens: route.maxOutputTokens, requestsUsage: route.requestsUsage), expectedRevision: nil)
        return (store, directory, route)
    }

    private func export(_ store: SQLiteMiraStore, in directory: URL, name: String) throws -> URL {
        let backup = directory.appendingPathComponent("\(name).sqlite")
        try store.exportBackup(to: backup)
        return backup
    }

    private func expectRestoreError(_ store: SQLiteMiraStore, backup: URL, name: String, message: String) throws {
        let destination = backup.deletingLastPathComponent().appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: destination) }
        do {
            try store.restoreBackup(from: backup, to: destination)
            Issue.record("Restore unexpectedly succeeded for \(backup.lastPathComponent).")
        } catch let error as MiraError {
            #expect(error == MiraError(.storage, message))
        } catch {
            Issue.record("Restore failed with an unexpected error: \(error.localizedDescription)")
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-memory-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func cleanup(_ url: URL) throws { try? FileManager.default.removeItem(at: url) }
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }
    private func id<T>(_ value: EntityID<T>) -> String { value.rawValue.uuidString.lowercased() }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: Data(value.utf8))
    }
}
