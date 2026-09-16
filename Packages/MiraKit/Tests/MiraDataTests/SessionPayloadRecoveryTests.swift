import Foundation
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Session payload recovery", .serialized)
struct SessionPayloadRecoveryTests {
    @Test func committedPayloadReopensWithoutPendingMarker() async throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ConversationID(), batchID = UUID()
        let library = try FileSessionLibrary(directory: root)
        let reference = try await library.stage(Data("committed".utf8), sessionID: session, batchID: batchID,
                                                retentionGroup: UUID(), kind: .userText)
        let batch = payloadBatch(session: session, batchID: batchID, reference: reference)
        #expect(await library.append(batch) == .committed(batch.cursor))
        #expect(try await library.read(reference) == Data("committed".utf8))
        try await library.close()
        #expect(!FileManager.default.fileExists(atPath: markerURL(root, session: session, batch: batchID).path))
        let reopened = try FileSessionLibrary(directory: root)
        let metrics = await reopened.readMetrics()
        #expect(metrics.recoveredPayloadBatches == 0 && metrics.sweptPayloadBatches == 0)
        #expect(metrics.verifiedJournalBytes > 0)
        #expect(try await reopened.read(reference) == Data("committed".utf8))
        try await reopened.close()
    }

    @Test func dormantCorruptBodyDoesNotBlockOpenButFailsReadsAndSnapshots() async throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ConversationID(), batchID = UUID()
        let library = try FileSessionLibrary(directory: root)
        let reference = try await library.stage(largeUTF8Fixture(), sessionID: session, batchID: batchID,
                                                retentionGroup: UUID(), kind: .userText)
        let batch = payloadBatch(session: session, batchID: batchID, reference: reference)
        #expect(await library.append(batch) == .committed(batch.cursor))
        try await library.close()
        try Data("tampered".utf8).write(to: payloadURL(root, reference: reference), options: .atomic)
        let reopened = try FileSessionLibrary(directory: root)
        await #expect(throws: MiraError.self) { _ = try await reopened.read(reference) }
        await #expect(throws: MiraError.self) { _ = try await reopened.withSnapshot { $0.sessions.count } }
        try await reopened.close()
    }

    @Test func stagedOrphanIsRemovedWhileCommittedBodySurvivesReopen() async throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ConversationID(), committedID = UUID(), orphanID = UUID()
        let library = try FileSessionLibrary(directory: root)
        let committed = try await library.stage(externalFixture(), sessionID: session, batchID: committedID,
                                                retentionGroup: UUID(), kind: .userText)
        let batch = payloadBatch(session: session, batchID: committedID, reference: committed)
        #expect(await library.append(batch) == .committed(batch.cursor))
        let orphan = try await library.stage(externalFixture(), sessionID: session, batchID: orphanID,
                                             retentionGroup: UUID(), kind: .draft)
        try await library.close()
        let orphanPath = payloadURL(root, reference: orphan)
        #expect(FileManager.default.fileExists(atPath: orphanPath.path))
        let reopened = try FileSessionLibrary(directory: root)
        #expect(try await reopened.read(committed) == externalFixture())
        #expect(!FileManager.default.fileExists(atPath: orphanPath.path))
        let metrics = await reopened.readMetrics()
        #expect(metrics.recoveredPayloadBatches == 1 && metrics.sweptPayloadBatches == 0)
        try await reopened.verifyNoUnpublished()
        try await reopened.close()
    }

    @Test(arguments: [SessionStorageFaultStage.beforePendingPayloadMark, .afterPendingPayloadMark])
    func pendingMarkerFaultLeavesNoUncommittedReadableBody(stage: SessionStorageFaultStage) async throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try FileSessionLibrary(directory: root) { current in
            if current == stage { throw MiraError(.storage, "Synthetic pending payload fault.") }
        }
        await #expect(throws: MiraError.self) {
            _ = try await library.stage(externalFixture(), sessionID: ConversationID(), batchID: UUID(),
                                        retentionGroup: UUID(), kind: .draft)
        }
        try? await library.close()
        let reopened = try FileSessionLibrary(directory: root)
        try await reopened.verifyNoUnpublished()
        try await reopened.close()
    }

    @Test(arguments: [SessionStorageFaultStage.beforePendingPayloadClear, .afterPendingPayloadClear])
    func clearFaultDoesNotLoseCommittedJournalBatch(stage: SessionStorageFaultStage) async throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ConversationID(), batchID = UUID()
        let failing = try FileSessionLibrary(directory: root) { current in
            if current == stage { throw MiraError(.storage, "Synthetic pending clear fault.") }
        }
        let committedBytes = externalFixture()
        let reference = try await failing.stage(committedBytes, sessionID: session, batchID: batchID,
                                                retentionGroup: UUID(), kind: .userText)
        let unreferenced = try await failing.stage(externalFixture(), sessionID: session, batchID: batchID,
                                                   retentionGroup: UUID(), kind: .draft)
        let batch = payloadBatch(session: session, batchID: batchID, reference: reference)
        #expect(await failing.append(batch) == .committed(batch.cursor))
        #expect(!FileManager.default.fileExists(atPath: payloadURL(root, reference: unreferenced).path))
        try? await failing.close()
        let reopened = try FileSessionLibrary(directory: root)
        #expect(try await reopened.batch(id: batchID, sessionID: session) == batch)
        #expect(try await reopened.read(reference) == committedBytes)
        try await reopened.close()
        let second = try FileSessionLibrary(directory: root)
        #expect(try await second.batch(id: batchID, sessionID: session) == batch)
        try await second.close()
    }

    @Test func missingPendingDirectoryRebuildsAndSweepsOrphan() async throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ConversationID(), batchID = UUID()
        let library = try FileSessionLibrary(directory: root)
        let retainedBytes = externalFixture()
        let reference = try await library.stage(retainedBytes, sessionID: session, batchID: batchID,
                                                retentionGroup: UUID(), kind: .userText)
        let batch = payloadBatch(session: session, batchID: batchID, reference: reference)
        #expect(await library.append(batch) == .committed(batch.cursor))
        try await library.close()
        let orphan = root.appendingPathComponent("payloads").appendingPathComponent(session.rawValue.uuidString)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        let orphanFile = orphan.appendingPathComponent(UUID().uuidString + ".bin")
        try Data("orphan".utf8).write(to: orphanFile)
        let pending = root.appendingPathComponent("pending-payloads", isDirectory: true)
        try? FileManager.default.removeItem(at: pending)
        let reopened = try FileSessionLibrary(directory: root)
        #expect(FileManager.default.fileExists(atPath: pending.path))
        #expect(!FileManager.default.fileExists(atPath: orphanFile.path))
        #expect(try await reopened.read(reference) == retainedBytes)
        try await reopened.close()
    }

    @Test(arguments: ["symlink", "hardlink", "nonempty", "noncanonical"])
    func malformedPendingMarkerIsRejected(kind: String) throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = root.appendingPathComponent("pending-payloads", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let session = ConversationID(), batch = UUID()
        let canonical = pending.appendingPathComponent("\(session.rawValue.uuidString).\(batch.uuidString)")
        switch kind {
        case "symlink":
            let outside = root.appendingPathComponent("outside")
            try Data().write(to: outside)
            try FileManager.default.createSymbolicLink(at: canonical, withDestinationURL: outside)
        case "hardlink":
            let source = root.appendingPathComponent("hardlink-source")
            try Data().write(to: source)
            try FileManager.default.linkItem(at: source, to: canonical)
        case "nonempty":
            try Data("x".utf8).write(to: canonical)
        default:
            try Data().write(to: pending.appendingPathComponent("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.\(batch.uuidString)"))
        }
        #expect(throws: MiraError.self) { _ = try FileSessionLibrary(directory: root) }
    }
}

private func testDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-session-payload-recovery-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func payloadBatch(session: ConversationID, batchID: UUID, reference: SessionPayloadReference) -> SessionBatch {
    .init(id: batchID, sessionID: session, expectedSequence: 0, events: [
        .init(sequence: 1, occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
              fact: .extensionRecorded(namespace: "payload.recovery", schemaVersion: 1, required: false, body: reference))
    ])
}

private func payloadURL(_ root: URL, reference: SessionPayloadReference) -> URL {
    root.appendingPathComponent("payloads").appendingPathComponent(reference.sessionID.rawValue.uuidString)
        .appendingPathComponent(reference.batchID.uuidString).appendingPathComponent(reference.id.uuidString + ".bin")
}

private func markerURL(_ root: URL, session: ConversationID, batch: UUID) -> URL {
    root.appendingPathComponent("pending-payloads").appendingPathComponent("\(session.rawValue.uuidString).\(batch.uuidString)")
}

private func externalFixture() -> Data { Data([0xff, 0xfe, 0xfd, 0xfc]) }

private func largeUTF8Fixture() -> Data { Data(repeating: 0x78, count: 256 * 1024 + 1) }
