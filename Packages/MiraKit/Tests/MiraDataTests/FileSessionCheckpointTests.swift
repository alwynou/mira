import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("File session state checkpoints")
struct FileSessionCheckpointTests {
    @Test func journalReopenPreservesExplicitSessionSelection() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let runtime = try await makeSession(library, renames: 0)
            let selected = AgentSessionModelSelection.selected(.init(
                routeID: RouteID(),
                model: .init(connectionID: ConnectionID(), modelID: "synthetic-model"),
                modelConfigurationID: ModelDescriptorID()))
            try committed(await runtime.commit(id: UUID()) { _ in
                [.modelSelectionChanged(selection: selected, expectedRevision: 0)]
            })
            let expected = await runtime.snapshot()
            #expect(expected.modelSelection == selected)
            await runtime.close(); try await library.close()
            let reopened = try FileSessionLibrary(directory: directory)
            let snapshot = try await reader(reopened).snapshot(sessionID: expected.id)
            #expect(snapshot.state.modelSelection == selected)
            #expect(snapshot.state.modelSelectionRevision == 1)
            try await reopened.close()
        }
    }

    @Test func forgedCacheChecksumsCannotAuthorizeStateOrDeleteReferencedPayloads() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let runtime = try await makeSession(library, renames: 1), expected = await runtime.snapshot()
            let reference = try #require(expected.title)
            await runtime.close(); try await library.close()
            let indexURL = directory.appendingPathComponent("indexes/\(runtime.id.rawValue.uuidString).index")
            try forgeUnkeyedCache(indexURL, format: "MIRA-SESSION-INDEX-2") { value in
                value["references"] = []
            }
            try forgeUnkeyedCache(checkpointURL(directory, runtime.id), format: "MIRA-SESSION-STATE-2") { value in
                var snapshot = value["snapshot"] as! [String: Any]
                var state = snapshot["state"] as! [String: Any]
                state["isArchived"] = true; snapshot["state"] = state; value["snapshot"] = snapshot
            }
            let reopened = try FileSessionLibrary(directory: directory)
            #expect(try await reader(reopened).snapshot(sessionID: runtime.id).state == expected)
            #expect(try await reopened.read(reference) == Data("Synthetic title 2".utf8))
            #expect(await reopened.readMetrics().indexedSessions == 0)
            #expect(await reopened.readMetrics().restoredCheckpoints == 0)
            try await reopened.close()
        }
    }

    @Test(arguments: ["missing", "truncated", "overexposed"])
    func losingTheCacheAuthenticationKeyOnlyRequiresRebuildingCaches(damage: String) async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let runtime = try await makeSession(library, renames: 2), expected = await runtime.snapshot()
            await runtime.close(); try await library.close()
            let authentication = directory.appendingPathComponent(".cache-authentication")
            switch damage {
            case "missing": try FileManager.default.removeItem(at: authentication)
            case "truncated": try Data([1]).write(to: authentication)
            default: try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: authentication.path)
            }
            let reopened = try FileSessionLibrary(directory: directory)
            #expect(try await reader(reopened).snapshot(sessionID: runtime.id).state == expected)
            #expect(await reopened.readMetrics().indexedSessions == 0)
            #expect(await reopened.readMetrics().restoredCheckpoints == 0)
            #expect((try FileManager.default.attributesOfItem(atPath: authentication.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            try await reopened.close()
        }
    }

    @Test func runtimeCommitsPersistAFullCheckpointAndReopenDoesNotReplayHistory() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let runtime = try await makeSession(library, renames: 40)
            let expected = await runtime.snapshot()
            await runtime.close(); try await library.close()
            let reopened = try FileSessionLibrary(directory: directory)
            let before = await reopened.readMetrics()
            let snapshot = try await reader(reopened).snapshot(sessionID: runtime.id)
            let after = await reopened.readMetrics()
            #expect(snapshot.state == expected)
            #expect(after.restoredCheckpoints - before.restoredCheckpoints == 1)
            #expect(after.pageDecodedBatches - before.pageDecodedBatches <= 2)
            #expect(after.scannedBatches == 0)
            try await reopened.close()
        }
    }

    @Test func deletingEverySidecarRebuildsExactlyTheSameAuthoritativeState() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let runtime = try await makeSession(library, renames: 8)
            let expected = await runtime.snapshot()
            await runtime.close(); try await library.close()
            for name in ["indexes", "checkpoints"] { try FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
            let rebuilt = try FileSessionLibrary(directory: directory)
            #expect(try await reader(rebuilt).snapshot(sessionID: runtime.id).state == expected)
            #expect(await rebuilt.readMetrics().restoredCheckpoints == 0)
            #expect(await rebuilt.readMetrics().scannedBatches == 9)
            try await rebuilt.close()
        }
    }

    @Test func damagedCheckpointFallsBackToReplayAndIsReplaced() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let runtime = try await makeSession(library, renames: 2), expected = await runtime.snapshot()
            await runtime.close(); try await library.close()
            let url = checkpointURL(directory, runtime.id)
            var bytes = try Data(contentsOf: url); bytes[bytes.count - 2] ^= 1; try bytes.write(to: url)
            let reopened = try FileSessionLibrary(directory: directory)
            #expect(try await reader(reopened).snapshot(sessionID: runtime.id).state == expected)
            #expect(await reopened.readMetrics().restoredCheckpoints == 0)
            try await reopened.close()
            let again = try FileSessionLibrary(directory: directory)
            #expect(try await reader(again).snapshot(sessionID: runtime.id).state == expected)
            #expect(await again.readMetrics().restoredCheckpoints == 1)
            try await again.close()
        }
    }

    @Test func staleCheckpointReducesPrivacyInvalidationBeforeReturningAnyState() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let runtime = try await makeSession(library, renames: 0)
            let group = UUID()
            try committed(await runtime.commit(id: UUID()) { context in
                let body = try await context.stageBytes(Data("Private synthetic body".utf8), kind: .module, retentionGroup: group)
                return [.extensionRecorded(namespace: "test.fixture", schemaVersion: 1, required: false, body: body)]
            })
            let original = await runtime.snapshot()
            await runtime.close(); try await library.close()
            let reopened = try FileSessionLibrary(directory: directory)
            let invalidation = SessionBatch(id: UUID(), sessionID: runtime.id, expectedSequence: original.sequence,
                events: [.init(sequence: original.sequence + 1, occurredAt: Date(), fact: .invalidated(.init(
                    operationID: UUID(), executionIDs: [], retentionGroups: [group], authorizationEpoch: 1, reason: .forgotten)))])
            #expect(await reopened.append(invalidation) == .committed(invalidation.cursor))
            try await reopened.purge(sessionID: runtime.id, retentionGroups: [group])
            // Direct journal append leaves the older state sidecar as a valid prefix.
            try await reopened.close()
            let recovered = try FileSessionLibrary(directory: directory)
            let result = try await reader(recovered).snapshot(sessionID: runtime.id)
            #expect(result.state.authorizationEpoch == 1)
            #expect(result.state.invalidatedRetentionGroups.contains(group))
            #expect(await recovered.readMetrics().restoredCheckpoints == 1)
            let reference = try #require(original.references.values.first { $0.retentionGroup == group })
            await #expect(throws: MiraError.self) { _ = try await recovered.read(reference) }
            try await recovered.close()
        }
    }

    @Test func changedRequiredExtensionRegistryCannotReusePersistedState() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let runtime = try await makeSession(library, renames: 0, schemas: ["test.fixture": [1]])
            try committed(await runtime.commit(id: UUID()) { context in
                let body = try await context.stageBytes(Data("Synthetic extension".utf8), kind: .module, retentionGroup: UUID())
                return [.extensionRecorded(namespace: "test.fixture", schemaVersion: 1, required: true, body: body)]
            })
            await runtime.close(); try await library.close()
            let reopened = try FileSessionLibrary(directory: directory)
            await #expect(throws: MiraError(.unsupported, "A required session extension is unavailable.")) {
                _ = try await reader(reopened).snapshot(sessionID: runtime.id)
            }
            #expect(await reopened.readMetrics().restoredCheckpoints == 0)
            let compatible = JournalSessionReader(journal: reopened, payloads: reopened, extensionSchemas: ["test.fixture": [1]])
            #expect(try await compatible.snapshot(sessionID: runtime.id).state.sequence == 2)
            #expect(await reopened.readMetrics().restoredCheckpoints == 1)
            try await reopened.close()
        }
    }

    @Test func snapshotRemainsAtTheRequestedEarlierBatchWhenTheHotCheckpointIsNewer() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let runtime = try await makeSession(library, renames: 0)
            let first = try await library.head(sessionID: runtime.id), expected = await runtime.snapshot()
            try await library.flush()
            try committed(await runtime.commit(id: UUID()) { context in
                let title = try await context.stageBytes(Data("Newer".utf8), kind: .title, retentionGroup: UUID())
                return [.renamed(title: title, revision: 2)]
            })
            let older = try await reader(library).snapshot(through: first)
            #expect(older.state == expected)
            let beforeLatest = await library.readMetrics()
            #expect(try await reader(library).snapshot(sessionID: runtime.id).state.revision == 2)
            #expect(await library.readMetrics().pageDecodedBatches - beforeLatest.pageDecodedBatches == 2)
            await runtime.close(); try await library.close()
        }
    }

    @Test func checkpointPublicationFailuresPreserveCommittedStateAndReopen() async throws {
        for stage in [SessionStorageFaultStage.beforeCheckpointWrite, .afterCheckpointWrite, .beforeCheckpointPublication, .afterCheckpointPublication] {
            try await withDirectory { directory in
                let library = try FileSessionLibrary(directory: directory) { current in
                    if current == stage { throw MiraError(.storage, "Synthetic checkpoint failure.") }
                }
                let runtime = try await makeSession(library, renames: 1), expected = await runtime.snapshot()
                await runtime.close(); try await library.close()
                let reopened = try FileSessionLibrary(directory: directory)
                #expect(try await reader(reopened).snapshot(sessionID: runtime.id).state == expected)
                try await reopened.close()
            }
        }
    }

    @Test func sourceChangeWhileOpenCannotBeHiddenByAHotCheckpoint() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let runtime = try await makeSession(library, renames: 1)
            let url = directory.appendingPathComponent("sessions/\(runtime.id.rawValue.uuidString).jsonl")
            var bytes = try Data(contentsOf: url); bytes[12] ^= 1; try bytes.write(to: url)
            await #expect(throws: MiraError.self) { _ = try await reader(library).snapshot(sessionID: runtime.id) }
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
        for revision in 2..<(renames + 2) {
            try committed(await runtime.commit(id: UUID()) { context in
                let title = try await context.stageBytes(Data("Synthetic title \(revision)".utf8), kind: .title, retentionGroup: UUID())
                return [.renamed(title: title, revision: revision)]
            })
        }
        return runtime
    }
    private func committed(_ value: SessionCommitResult) throws {
        guard case .committed = value else { throw MiraError(.storage, "Synthetic session did not commit.") }
    }
    private func reader(_ library: FileSessionLibrary) -> JournalSessionReader { .init(journal: library, payloads: library) }
    private func checkpointURL(_ directory: URL, _ id: ConversationID) -> URL { directory.appendingPathComponent("checkpoints/\(id.rawValue.uuidString).state") }
    private func forgeUnkeyedCache(_ url: URL, format: String, mutate: (inout [String: Any]) -> Void) throws {
        let prefix = Data((format + "\n").utf8), bytes = try Data(contentsOf: url)
        var value = try #require(JSONSerialization.jsonObject(with: bytes.dropFirst(prefix.count + 65)) as? [String: Any])
        mutate(&value)
        let body = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try (prefix + Data(FileSessionIO.digest(body).utf8) + Data([10]) + body).write(to: url)
    }
    private func withDirectory(_ operation: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-checkpoint-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await operation(directory)
    }
}
