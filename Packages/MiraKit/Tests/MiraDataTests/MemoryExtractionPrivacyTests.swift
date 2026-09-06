import Foundation
import GRDB
import MiraCore
import Testing
@testable import MiraData

@Suite("Memory extraction privacy boundaries")
struct MemoryExtractionPrivacyTests {
    @Test func successfulExtractionBackupRestoresCommittedMemoryAndAudit() throws {
        let fixture = try makeCompletedFixture()
        defer { remove(fixture.directory) }

        let backup = try export(fixture.store, directory: fixture.directory, name: "successful")
        let restoredDirectory = fixture.directory.appendingPathComponent("successful-restored")
        defer { remove(backup); remove(restoredDirectory) }
        try fixture.store.restoreBackup(from: backup, to: restoredDirectory)

        let restored = try SQLiteMiraStore(directory: restoredDirectory)
        let job = try #require(try restored.memoryExtractionJobs(conversationID: fixture.conversation.id, limit: 10).first)
        #expect(job.state == .completed)
        #expect(job.memoryIDs == [fixture.memoryID])
        let detail = try restored.memoryDetail(fixture.memoryID, workspaceID: nil)
        #expect(detail.memory.state == .candidate)
        #expect(detail.memory.draft?.content == fixture.sourceText)
        #expect(detail.evidence.first?.excerpt == fixture.sourceText)
        #expect(try restored.messages(in: fixture.conversation.id).first?.text == fixture.sourceText)
    }

    @Test func forgettingExtractionMemoryPurgesBodiesAndPreservesSourceAndAccounting() throws {
        let fixture = try makeCompletedFixture()
        defer { remove(fixture.directory) }
        let forgottenAt = date(1010)
        _ = try fixture.store.forgetMemory(fixture.memoryID, workspaceID: nil, expectedRevision: 1, at: forgottenAt)

        let sourceID = id(fixture.sourceMessageID)
        let jobID = id(fixture.claim.job.id)
        let attemptID = id(fixture.claim.attemptID)
        let database = try DatabaseQueue(path: fixture.directory.appendingPathComponent("Mira.sqlite").path)
        let rows = try database.read { db in
            (
                try Row.fetchOne(db, sql: "SELECT text, body_purged_at FROM messages WHERE id = ?", arguments: [sourceID]),
                try Row.fetchOne(db, sql: "SELECT source_hash, body_purged_at FROM memory_extraction_jobs WHERE id = ?", arguments: [jobID]),
                try Row.fetchOne(db, sql: "SELECT request_json, output_json, reserved_tokens, charged_tokens, body_purged_at FROM memory_extraction_attempts WHERE id = ?", arguments: [attemptID]),
                try Row.fetchOne(db, sql: "SELECT excerpt, source_hash, review_reason, body_purged_at FROM memory_extraction_decisions WHERE job_id = ?", arguments: [jobID])
            )
        }
        guard let source = rows.0, let job = rows.1, let attempt = rows.2, let decision = rows.3 else {
            Issue.record("The completed extraction rows were not all present before inspection.")
            return
        }
        #expect((source["text"] as String) == fixture.sourceText)
        #expect((source["body_purged_at"] as Double?) == nil)
        #expect((job["source_hash"] as String?) == nil)
        #expect((job["body_purged_at"] as Double?) != nil)
        #expect((attempt["request_json"] as String?) == nil)
        #expect((attempt["output_json"] as String?) == nil)
        #expect((attempt["reserved_tokens"] as Int) == 0)
        #expect((attempt["charged_tokens"] as Int) > 0)
        #expect((attempt["body_purged_at"] as Double?) != nil)
        #expect((decision["excerpt"] as String?) == nil)
        #expect((decision["source_hash"] as String?) == nil)
        #expect((decision["review_reason"] as String?) == nil)
        #expect((decision["body_purged_at"] as Double?) != nil)

        let backup = try export(fixture.store, directory: fixture.directory, name: "forgotten")
        let restoredDirectory = fixture.directory.appendingPathComponent("forgotten-restored")
        defer { remove(backup); remove(restoredDirectory) }
        try fixture.store.restoreBackup(from: backup, to: restoredDirectory)
        let restored = try SQLiteMiraStore(directory: restoredDirectory)
        let restoredSource = try #require(try restored.messages(in: fixture.conversation.id).first)
        #expect(restoredSource.text == fixture.sourceText)
        #expect(try restored.memoryDetail(fixture.memoryID, workspaceID: nil).memory.forgottenAt != nil)
        #expect(try restored.memoryExtractionBudget(at: forgottenAt).chargedTokens > 0)
    }

    @Test func restoreRejectsResurrectedAttemptBodyUnderPurgedExtractionJob() throws {
        let fixture = try makeCompletedFixture()
        defer { remove(fixture.directory) }
        _ = try fixture.store.forgetMemory(fixture.memoryID, workspaceID: nil, expectedRevision: 1, at: date(1010))
        let backup = try export(fixture.store, directory: fixture.directory, name: "resurrected-attempt")
        defer { remove(backup) }
        let database = try DatabaseQueue(path: backup.appendingPathComponent("Mira.sqlite").path)
        let request = try MemoryExtractionRequestBuilder.request(for: fixture.claim)
        let output = ModelOutput(text: "retained extraction body", toolCalls: [], finishReason: .stop)
        let requestJSON = try encode(request)
        let outputJSON = try encode(output)
        let changed = try database.write { db -> Int in
            try db.execute(sql: "UPDATE memory_extraction_attempts SET body_purged_at = NULL, request_json = ?, output_json = ? WHERE id = ?", arguments: [requestJSON, outputJSON, id(fixture.claim.attemptID)])
            return db.changesCount
        }
        #expect(changed == 1)
        try resealTestBackupManifest(backup)
        let resurrected = try database.read { db in
            try Row.fetchOne(db, sql: "SELECT body_purged_at, request_json, output_json FROM memory_extraction_attempts WHERE id = ?", arguments: [id(fixture.claim.attemptID)])
        }
        #expect((resurrected?["body_purged_at"] as Double?) == nil)
        #expect((resurrected?["request_json"] as String?) != nil)
        try expectStorageRestoreError(fixture.store, backup: backup, name: "resurrected-attempt-restored")
    }

    @Test(arguments: ["source", "policy", "evidence"])
    func restoreRejectsMismatchedDecisionOrMemoryEvidence(_ mutation: String) throws {
        let fixture = try makeCompletedFixture()
        defer { remove(fixture.directory) }
        let backup = try export(fixture.store, directory: fixture.directory, name: "mismatch-" + mutation)
        defer { remove(backup) }
        let database = try DatabaseQueue(path: backup.appendingPathComponent("Mira.sqlite").path)
        let changed = try database.write { db -> Int in
            switch mutation {
            case "source":
                try db.execute(sql: "UPDATE memory_extraction_decisions SET source_revision = source_revision + 1 WHERE job_id = ?", arguments: [id(fixture.claim.job.id)])
            case "policy":
                try db.execute(sql: "UPDATE memory_extraction_decisions SET policy_revision = policy_revision + 1 WHERE job_id = ?", arguments: [id(fixture.claim.job.id)])
            default:
                guard let row = try Row.fetchOne(db, sql: "SELECT evidence_json FROM memory_evidence WHERE memory_id = ?", arguments: [id(fixture.memoryID)]), let original = row["evidence_json"] as String? else { return 0 }
                var evidence = try decode(MemoryEvidence.self, from: original)
                evidence.sourceRevision += 1
                try db.execute(sql: "UPDATE memory_evidence SET evidence_json = ? WHERE memory_id = ?", arguments: [try encode(evidence), id(fixture.memoryID)])
            }
            return db.changesCount
        }
        #expect(changed == 1)
        try resealTestBackupManifest(backup)
        try expectStorageRestoreError(fixture.store, backup: backup, name: "mismatch-" + mutation + "-restored")
    }

    @Test(arguments: ["lease", "ordinal"])
    func restoreRejectsRunningExtractionWithoutMatchingLeaseOrAttemptOrdinal(_ mutation: String) throws {
        let fixture = try makeClaimedFixture()
        defer { remove(fixture.directory) }
        let backup = try export(fixture.store, directory: fixture.directory, name: "running-" + mutation)
        defer { remove(backup) }
        let database = try DatabaseQueue(path: backup.appendingPathComponent("Mira.sqlite").path)
        let changed = try database.write { db -> Int in
            if mutation == "lease" {
                try db.execute(sql: "UPDATE memory_extraction_jobs SET lease_id = ? WHERE id = ?", arguments: [UUID().uuidString.lowercased(), id(fixture.claim.job.id)])
            } else {
                try db.execute(sql: "UPDATE memory_extraction_attempts SET ordinal = ordinal + 1 WHERE id = ?", arguments: [id(fixture.claim.attemptID)])
            }
            return db.changesCount
        }
        #expect(changed == 1)
        try resealTestBackupManifest(backup)
        try expectStorageRestoreError(fixture.store, backup: backup, name: "running-" + mutation + "-restored")
    }

    @Test(arguments: ["settlement", "reservation"])
    func restoreRejectsImpossibleExtractionBudgetAccounting(_ mutation: String) throws {
        let fixture = try makeCompletedFixture()
        defer { remove(fixture.directory) }
        let backup = try export(fixture.store, directory: fixture.directory, name: "budget-" + mutation)
        defer { remove(backup) }
        let database = try DatabaseQueue(path: backup.appendingPathComponent("Mira.sqlite").path)
        let changed = try database.write { db -> Int in
            if mutation == "settlement" {
                try db.execute(sql: "UPDATE memory_extraction_attempts SET charged_tokens = 100001 WHERE id = ?", arguments: [id(fixture.claim.attemptID)])
            } else {
                try db.execute(sql: "UPDATE memory_extraction_attempts SET reserved_tokens = 1 WHERE id = ?", arguments: [id(fixture.claim.attemptID)])
            }
            return db.changesCount
        }
        #expect(changed == 1)
        try resealTestBackupManifest(backup)
        try expectStorageRestoreError(fixture.store, backup: backup, name: "budget-" + mutation + "-restored")
    }

    @Test func lateWorkerCannotCommitOrRetryAfterForget() throws {
        let fixture = try makeCompletedFixture()
        defer { remove(fixture.directory) }
        _ = try fixture.store.forgetMemory(fixture.memoryID, workspaceID: nil, expectedRevision: 1, at: date(1010))
        let output = ModelOutput(text: validOutput, toolCalls: [], finishReason: .stop)
        #expect(throws: MiraError.self) {
            try fixture.store.completeMemoryExtraction(fixture.claim, output: output, usage: .init(inputTokens: 3, outputTokens: 4), at: date(1011))
        }
        #expect(throws: MiraError.self) {
            try fixture.store.retryMemoryExtraction(fixture.claim.job.id, at: date(1012))
        }
        let database = try DatabaseQueue(path: fixture.directory.appendingPathComponent("Mira.sqlite").path)
        let counts = try database.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT count(*) FROM memories WHERE id = ?", arguments: [id(fixture.memoryID)]) ?? 0,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_extraction_decisions WHERE job_id = ?", arguments: [id(fixture.claim.job.id)]) ?? 0
            )
        }
        #expect(counts.0 == 1)
        #expect(counts.1 == 1)
    }

    private struct Fixture {
        let store: SQLiteMiraStore
        let directory: URL
        let conversation: Conversation
        let sourceMessageID: MessageID
        let claim: MemoryExtractionClaim
        let memoryID: MemoryID
        let sourceText: String
    }

    private let sourceText = "I prefer tea"
    private var validOutput: String { Self.validOutputJSON }
    private static let validOutputJSON = "{\"version\":1,\"items\":[{\"content\":\"I prefer tea\",\"quote\":\"I prefer tea\",\"kind\":\"preference\",\"subject\":\"user\",\"sensitivity\":\"standard\",\"inferred\":false,\"stable\":true,\"confidence\":\"high\",\"validFrom\":null,\"validUntil\":null}]}"

    private func makeCompletedFixture() throws -> Fixture {
        let claimed = try makeClaimedFixture()
        let output = ModelOutput(text: validOutput, toolCalls: [], finishReason: .stop)
        let job = try claimed.store.completeMemoryExtraction(claimed.claim, output: output, usage: .init(inputTokens: 3, outputTokens: 4), at: date(1004))
        let memoryID = try #require(job.memoryIDs.first)
        return Fixture(store: claimed.store, directory: claimed.directory, conversation: claimed.conversation, sourceMessageID: claimed.sourceMessageID, claim: claimed.claim, memoryID: memoryID, sourceText: sourceText)
    }

    private func makeClaimedFixture() throws -> Fixture {
        let directory = try temporaryDirectory()
        let store = try SQLiteMiraStore(directory: directory)
        let route = ResolvedModelRouteSnapshot(name: "Extraction", providerKind: .openAICompatible, baseURL: "https://example.invalid", modelID: "fixture", credentialReference: "fixture", contextWindow: 32_768)
        try store.saveConnection(.init(id: route.connectionID, revision: route.connectionRevision, name: "Fixture connection", providerKind: route.providerKind, baseURL: route.baseURL, credentialReference: route.credentialReference, credentialVersion: route.credentialVersion), expectedRevision: nil)
        try store.saveModel(.init(id: route.modelDescriptorID, revision: route.modelRevision, connectionID: route.connectionID, connectionRevision: route.connectionRevision, modelID: route.modelID, contextWindow: route.contextWindow, textCapability: route.textCapability, toolCapability: route.toolCapability, probeObservation: route.probeObservation, extractionCapability: .declared), expectedRevision: nil)
        try store.saveRoute(.init(id: route.id, revision: route.revision, name: route.name, modelDescriptorID: route.modelDescriptorID, maxOutputTokens: route.maxOutputTokens, requestsUsage: route.requestsUsage), expectedRevision: nil)
        try store.saveRouteBinding(.init(scope: .global, purpose: .conversation, routeID: route.id), expectedRevision: nil)
        try store.saveRouteBinding(.init(scope: .global, purpose: .memoryExtraction, routeID: route.id), expectedRevision: nil)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "", createdAt: date(999), updatedAt: date(999))
        try store.createConversation(conversation)
        let at = date(1000)
        try store.saveMemoryCapturePolicy(.init(revision: 2, mode: .candidateOnly, dailyTokenLimit: 100_000, enabledAt: at), expectedRevision: 1, at: at)
        let execution = try store.enqueue(conversationID: conversation.id, text: sourceText, route: route, executionID: .init(), messageID: .init(), at: at)
        _ = try store.finish(executionID: execution.id, status: .completed, text: "Done", usage: .init(inputTokens: 1, outputTokens: 1), error: nil, assistantMessageID: .init(), at: date(1001))
        let sourceMessageID = try #require(try store.messages(in: conversation.id).first(where: { $0.role == .user })?.id)
        let claim = try #require(try store.claimMemoryExtraction(at: date(1002)))
        let request = try MemoryExtractionRequestBuilder.request(for: claim)
        _ = try store.prepareMemoryExtraction(claim, request: request, at: date(1002))
        try store.markMemoryExtractionDispatched(claim, at: date(1003))
        return Fixture(store: store, directory: directory, conversation: conversation, sourceMessageID: sourceMessageID, claim: claim, memoryID: .init(), sourceText: sourceText)
    }

    private func export(_ store: SQLiteMiraStore, directory: URL, name: String) throws -> URL {
        let backup = directory.appendingPathComponent("\(name).sqlite")
        try store.exportBackup(to: backup)
        return backup
    }

    private func expectStorageRestoreError(_ store: SQLiteMiraStore, backup: URL, name: String) throws {
        let destination = backup.deletingLastPathComponent().appendingPathComponent(name)
        defer { remove(destination) }
        do {
            try store.restoreBackup(from: backup, to: destination)
            Issue.record("Restore unexpectedly succeeded for \(name).")
        } catch let error as MiraError {
            #expect(error.code == .storage)
        } catch {
            Issue.record("Restore failed with an unexpected error: \(error.localizedDescription)")
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-extraction-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }
    private func id<T>(_ value: EntityID<T>) -> String { value.rawValue.uuidString.lowercased() }
    private func id(_ value: UUID) -> String { value.uuidString.lowercased() }
    private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: Data(string.utf8))
    }
}
