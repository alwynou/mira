import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Session recovery summaries")
struct SessionRecoverySummaryTests {
    @Test func completedSummaryReopensWithoutRestoringFullCheckpoint() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let runtime = try await makeSession(library, renames: 40)
            let expected = await runtime.snapshot()
            let expectedHead = try await library.head(sessionID: runtime.id)
            await runtime.close(); try await library.close()

            let reopened = try FileSessionLibrary(directory: directory)
            let summary = try await JournalSessionReader(journal: reopened, payloads: reopened)
                .recoverySummary(sessionID: expected.id)
            #expect(summary.head == expectedHead)
            #expect(summary.activeExecutionID == expected.activeExecutionID)
            let metrics = await reopened.readMetrics()
            #expect(metrics.restoredRecoverySummaries == 1)
            #expect(metrics.restoredCheckpoints == 0)
            #expect(metrics.scannedBatches == 0)
            #expect(metrics.pageDecodedBatches == 1)
            try await reopened.close()
        }
    }

    @Test func activeAdmissionIsRepresentedAndDoesNotSkipARealSuffix() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let runtime = try await makeSession(library, renames: 40)
            let settled = await runtime.snapshot()
            await runtime.close(); try await library.close()

            let reopened = try FileSessionLibrary(directory: directory)
            let session = settled.id, batchID = UUID(), executionID = ExecutionID()
            let user = try await reopened.stage(Data("user".utf8), sessionID: session,
                                                batchID: batchID, retentionGroup: UUID(), kind: .userText)
            let executionPlan = AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 1,
                driverID: "summary.local", driverRevision: 1, instructions: "Synthetic local answer.",
                limits: .init(), priority: .foreground, route: nil)
            try executionPlan.validate()
            let plan = try await reopened.stage(SessionCodec.encode(executionPlan), sessionID: session,
                                                batchID: batchID, retentionGroup: UUID(), kind: .executionPlan)
            let batch = SessionBatch(id: batchID, sessionID: session, expectedSequence: settled.sequence,
                events: [.init(sequence: settled.sequence + 1, occurredAt: Date(), fact: .admitted(.init(
                    executionID: executionID, userMessageID: MessageID(), userBody: user, plan: plan,
                    hasModelRoute: false, authorizationEpoch: settled.authorizationEpoch,
                    timeZoneIdentifier: "UTC")))])
            #expect(await reopened.append(batch) == .committed(batch.cursor))
            let summary = try await JournalSessionReader(journal: reopened, payloads: reopened)
                .recoverySummary(sessionID: session)
            #expect(summary.head == .init(cursor: batch.cursor, batchID: batch.id))
            #expect(summary.activeExecutionID == executionID)
            #expect(await reopened.readMetrics().restoredRecoverySummaries == 0)
            #expect(try await AgentExecutionPlan.read(for: try #require(
                try await JournalSessionReader(journal: reopened, payloads: reopened)
                    .snapshot(sessionID: session).state.executions[executionID]?.admission), from: reopened) == executionPlan)
            try await reopened.close()
        }
    }

    @Test(arguments: ["missing", "truncated", "damaged", "unkeyed", "version", "prefix", "schemas", "head"])
    func unusableSummaryFallsBackWithoutChangingAuthoritativeState(_ damage: String) async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let runtime = try await makeSession(library, renames: 8)
            let expected = await runtime.snapshot()
            await runtime.close(); try await library.close()
            let url = recoveryURL(directory, expected.id)
            if damage == "missing" { try FileManager.default.removeItem(at: url) }
            else {
                var bytes = try Data(contentsOf: url)
                if damage == "truncated" { bytes = Data(bytes.prefix(max(1, bytes.count / 2))) }
                else if damage == "damaged" { bytes[bytes.count - 1] ^= 1 }
                else {
                    let format = "MIRA-SESSION-RECOVERY-3", prefix = Data((format + "\n").utf8)
                    var value = try #require(JSONSerialization.jsonObject(with: bytes.dropFirst(prefix.count + 65)) as? [String: Any])
                    switch damage {
                    case "version": value["version"] = 999
                    case "prefix": value["prefixDigest"] = String(repeating: "0", count: 64)
                    case "schemas": value["extensionSchemas"] = ["unavailable": [1]]
                    default:
                        var summary = value["summary"] as! [String: Any]
                        var head = summary["head"] as! [String: Any]
                        head["batchID"] = UUID().uuidString; summary["head"] = head; value["summary"] = summary
                    }
                    let body = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                    let signature = damage == "unkeyed" ? Data(FileSessionIO.digest(body).utf8)
                        : try FileSessionCacheAuthentication(directory: directory).signature(body: body, format: format)
                    bytes = prefix + signature + Data([10]) + body
                }
                try bytes.write(to: url)
            }

            let reopened = try FileSessionLibrary(directory: directory)
            let result = try await JournalSessionReader(journal: reopened, payloads: reopened)
                .recoverySummary(sessionID: expected.id)
            #expect(result.head == (try await reopened.head(sessionID: expected.id)))
            #expect(result.activeExecutionID == nil)
            #expect(await reopened.readMetrics().restoredRecoverySummaries == 0)
            #expect(await reopened.readMetrics().restoredCheckpoints == 1)
            #expect(try await JournalSessionReader(journal: reopened, payloads: reopened)
                .snapshot(sessionID: expected.id).state == expected)
            try await reopened.close()
            let again = try FileSessionLibrary(directory: directory)
            #expect(try await JournalSessionReader(journal: again, payloads: again).recoverySummary(sessionID: expected.id) == result)
            #expect(await again.readMetrics().restoredRecoverySummaries == 1)
            try await again.close()
        }
    }

    @Test func requiredSchemaMismatchCannotReuseRecoveryState() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let schemas: [String: Set<Int>] = ["summary.fixture": [1]]
            let runtime = try await makeSession(library, renames: 8, schemas: schemas)
            try committed(await runtime.commit(id: UUID()) { context in
                let body = try await context.stageBytes(Data("extension".utf8), kind: .module, retentionGroup: UUID())
                return [.extensionRecorded(namespace: "summary.fixture", schemaVersion: 1, required: true, body: body)]
            })
            await runtime.close(); try await library.close()
            let reopened = try FileSessionLibrary(directory: directory)
            await #expect(throws: MiraError(.unsupported, "A required session extension is unavailable.")) {
                _ = try await JournalSessionReader(journal: reopened, payloads: reopened)
                    .recoverySummary(sessionID: runtime.id)
            }
            #expect(await reopened.readMetrics().restoredRecoverySummaries == 0)
            #expect(try await JournalSessionReader(journal: reopened, payloads: reopened, extensionSchemas: schemas)
                .recoverySummary(sessionID: runtime.id).head == (try await reopened.head(sessionID: runtime.id)))
            #expect(await reopened.readMetrics().restoredRecoverySummaries == 1)
            try await reopened.close()
        }
    }

    @Test func sourceMutationWhileOpenCannotBeHiddenBySummary() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let runtime = try await makeSession(library, renames: 8)
            try await library.flush()
            #expect(FileManager.default.fileExists(atPath: recoveryURL(directory, runtime.id).path))
            let url = directory.appendingPathComponent("sessions/\(runtime.id.rawValue.uuidString).jsonl")
            var bytes = try Data(contentsOf: url); bytes[12] ^= 1; try bytes.write(to: url)
            await #expect(throws: MiraError.self) {
                _ = try await JournalSessionReader(journal: library, payloads: library)
                    .recoverySummary(sessionID: runtime.id)
            }
            await runtime.close(); try await library.close()
        }
    }

    @Test func recoverySummaryPublicationFaultsPreserveCommittedState() async throws {
        let stages: [SessionStorageFaultStage] = [
            .beforeRecoverySummaryWrite, .afterRecoverySummaryWrite,
            .beforeRecoverySummaryPublication, .afterRecoverySummaryPublication
        ]
        for stage in stages {
            try await withDirectory { directory in
                let library = try FileSessionLibrary(directory: directory) { current in
                    if current == stage { throw MiraError(.storage, "Synthetic recovery summary failure.") }
                }
                let runtime = try await makeSession(library, renames: 8)
                let expected = await runtime.snapshot()
                await runtime.close(); try await library.close()
                let reopened = try FileSessionLibrary(directory: directory)
                #expect(try await JournalSessionReader(journal: reopened, payloads: reopened)
                    .recoverySummary(sessionID: expected.id).activeExecutionID == nil)
                #expect(try await JournalSessionReader(journal: reopened, payloads: reopened)
                    .snapshot(sessionID: expected.id).state == expected)
                try await reopened.close()
            }
        }
    }

    @Test func historicalSummaryCannotReplaceNewerHeader() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let runtime = try await makeSession(library, renames: 8)
            let old = try await library.head(sessionID: runtime.id)
            try await library.flush()
            _ = try committed(await runtime.commit(id: UUID()) { context in
                let title = try await context.stageBytes(Data("newer".utf8), kind: .title, retentionGroup: UUID())
                return [.renamed(title: title, revision: 10)]
            })
            try await library.flush()
            let current = try await library.head(sessionID: runtime.id)
            let bytes = try Data(contentsOf: recoveryURL(directory, runtime.id))
            let other = try await makeSession(library, renames: 1)
            await other.close()
            #expect(try await library.recoverySummary(through: old, extensionSchemas: [:]) == nil)
            #expect(try await JournalSessionReader(journal: library, payloads: library).snapshot(through: old).state.revision == 9)
            try await library.flush()
            #expect(try Data(contentsOf: recoveryURL(directory, runtime.id)) == bytes)
            #expect(try await JournalSessionReader(journal: library, payloads: library)
                .recoverySummary(sessionID: runtime.id).head == current)
            await runtime.close(); try await library.close()
        }
    }

    private func makeSession(_ library: FileSessionLibrary, renames: Int,
                             schemas: [String: Set<Int>] = [:]) async throws -> SessionRuntime {
        let runtime = try await SessionRuntime.open(id: ConversationID(), journal: library, payloads: library, extensionSchemas: schemas)
        try committed(await runtime.commit(id: UUID()) { context in
            let title = try await context.stageBytes(Data("Synthetic title".utf8), kind: .title, retentionGroup: UUID())
            return [.opened(.init(workspaceID: nil, title: title))]
        })
        for revision in 2...(renames + 1) {
            try committed(await runtime.commit(id: UUID()) { context in
                let title = try await context.stageBytes(Data("Synthetic title \(revision)".utf8), kind: .title, retentionGroup: UUID())
                return [.renamed(title: title, revision: revision)]
            })
        }
        return runtime
    }

    @discardableResult private func committed(_ result: SessionCommitResult) throws -> SessionCursor {
        guard case .committed(let cursor) = result else { throw MiraError(.storage, "Synthetic commit failed.") }
        return cursor
    }

    private func recoveryURL(_ directory: URL, _ id: ConversationID) -> URL {
        directory.appendingPathComponent("checkpoints/\(id.rawValue.uuidString).recovery")
    }

    private func withDirectory(_ operation: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-recovery-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await operation(directory)
    }
}
