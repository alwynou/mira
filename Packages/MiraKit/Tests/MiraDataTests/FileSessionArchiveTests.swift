import Darwin
import Foundation
import MiraCore
import Testing

@testable import MiraData

@Suite("File session archives", .timeLimit(.minutes(1)))
struct FileSessionArchiveTests {
    @Test func emptyArchiveRejectsUnexpectedRootAndPayloadEntries() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("payloads"), withIntermediateDirectories: true)
        #expect(try FileSessionArchive.inspect(directory: root).sessions.isEmpty)
        try Data().write(to: root.appendingPathComponent("extra"))
        #expect(throws: MiraError.self) { try FileSessionArchive.inspect(directory: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("extra"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("payloads/orphan"), withIntermediateDirectories: true)
        #expect(throws: MiraError.self) { try FileSessionArchive.inspect(directory: root) }
    }

    @Test func archiveRejectsFIFOBeforeReadingIt() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("payloads"), withIntermediateDirectories: true)
        #expect(mkfifo(sessions.appendingPathComponent("\(UUID().uuidString).jsonl").path, 0o600) == 0)
        #expect(throws: MiraError.self) { try FileSessionArchive.inspect(directory: root) }
    }

    @Test func inlineBodiesRoundTripAndMissingOrCorruptBodiesRejectCapture() async throws {
        let fixture = try await Fixture.make()
        do {
            let (journal, bytes) = try await fixture.library.withSnapshot { snapshot in
                #expect(try snapshot.readBatches(sessionID: fixture.id).map(\.id) == [fixture.batch.id])
                let session = try #require(snapshot.sessions.first)
                #expect(session.payloads.isEmpty)
                guard let body = try snapshot.readRetainedPayload(fixture.title) else { throw MiraError(.storage, "Missing inline fixture body.") }
                return (session.journalURL, body)
            }
            #expect(bytes == Data("Archive title".utf8))
            let archive = fixture.root.appendingPathComponent("inline-archive")
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: archive.appendingPathComponent("sessions"), withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: archive.appendingPathComponent("payloads"), withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: journal, to: archive.appendingPathComponent("sessions").appendingPathComponent(journal.lastPathComponent))
            let inspected = try FileSessionArchive.inspect(directory: archive)
            #expect(try inspected.readRetainedPayload(fixture.title) == bytes)

            let original = try Data(contentsOf: journal)
            let record = try FileSessionIO.decodeRecord(Data(original.dropLast()))
            let missing = FileSessionRecord(batch: record.batch, payloads: [:])
            try (try FileSessionIO.encodeRecord(missing) + Data([10])).write(to: journal)
            await #expect(throws: MiraError.self) { _ = try await fixture.library.withSnapshot { $0.sessions.count } }

            let corruptLine = String(decoding: original, as: UTF8.self)
                .replacingOccurrences(of: "Archive title", with: "Archive titlX")
            try Data(corruptLine.utf8).write(to: journal)
            await #expect(throws: MiraError.self) { _ = try await fixture.library.withSnapshot { $0.sessions.count } }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func externalBodiesRemainInPayloadTreeAndReadThroughSnapshot() async throws {
        let fixture = try await Fixture.make()
        do {
            let batchID = UUID()
            let bytes = Data(repeating: 0x61, count: FileSessionRecord.maximumInlineBytes + 1)
            let reference = try await fixture.library.stage(
                bytes, sessionID: fixture.id, batchID: batchID, retentionGroup: UUID(), kind: .module)
            let batch = SessionBatch(
                id: batchID, sessionID: fixture.id, expectedSequence: 1,
                events: [.init(sequence: 2, occurredAt: Date(), fact: .extensionRecorded(
                    namespace: "archive.test", schemaVersion: 1, required: false, body: reference))])
            #expect(await fixture.library.append(batch) == .committed(batch.cursor))
            try await fixture.library.withSnapshot { snapshot in
                let session = try #require(snapshot.sessions.first)
                #expect(session.payloads[reference] != nil)
                #expect(try snapshot.readRetainedPayload(reference) == bytes)
            }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func retryClearedRetiresContentButArchiveKeepsItsPhysicalBody() async throws {
        let fixture = try await Fixture.make()
        do {
            let cleanup = SessionBatch(
                id: UUID(), sessionID: fixture.id, expectedSequence: 1,
                events: [.init(sequence: 2, occurredAt: Date(), fact: .retryCleared(.init(
                    sourceExecutionID: ExecutionID(), retryExecutionID: ExecutionID(),
                    retentionGroups: [fixture.title.retentionGroup])))])
            #expect(await fixture.library.append(cleanup) == .committed(cleanup.cursor))
            try await fixture.library.withSnapshot { snapshot in
                #expect(try snapshot.readRetainedPayload(fixture.title) == Data("Archive title".utf8))
                let session = try #require(snapshot.sessions.first)
                #expect(session.payloads.isEmpty)
            }
            let journal = fixture.root.appendingPathComponent("live/sessions/\(fixture.id.rawValue.uuidString).jsonl")
            let archive = fixture.root.appendingPathComponent("retired-archive")
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: archive.appendingPathComponent("sessions"), withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: archive.appendingPathComponent("payloads"), withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: journal, to: archive.appendingPathComponent("sessions").appendingPathComponent(journal.lastPathComponent))
            let inspected = try FileSessionArchive.inspect(directory: archive)
            #expect(try inspected.readRetainedPayload(fixture.title) == Data("Archive title".utf8))
            var retainedTitle: String?
            _ = try FileSessionIO.scanStrict(journal, sessionID: fixture.id, maximumRecords: 100) { record in
                if let value = record.payloads[fixture.title.id.uuidString] { retainedTitle = value }
            }
            #expect(retainedTitle == "Archive title")
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func invalidationExplainsMissingBodyButRemnantBlocksCapture() async throws {
        let fixture = try await Fixture.make()
        do {
            let invalidate = SessionBatch(
                id: UUID(), sessionID: fixture.id, expectedSequence: 1,
                events: [
                    .init(
                        sequence: 2, occurredAt: Date(),
                        fact: .invalidated(
                            .init(
                                operationID: UUID(), executionIDs: [],
                                retentionGroups: [fixture.title.retentionGroup], authorizationEpoch: 1,
                                reason: .forgotten)))
                ])
            #expect(await fixture.library.append(invalidate) == .committed(invalidate.cursor))
            await #expect(throws: MiraError.self) { _ = try await fixture.library.withSnapshot { $0.sessions.count } }
            try await fixture.library.purge(sessionID: fixture.id, retentionGroups: [fixture.title.retentionGroup])
            try await fixture.library.withSnapshot { snapshot in
                let session = try #require(snapshot.sessions.first)
                #expect(session.payloads.isEmpty)
                #expect(try snapshot.readRetainedPayload(fixture.title) == nil)
            }
            let archive = fixture.root.appendingPathComponent("captured")
            try FileManager.default.createDirectory(
                at: archive.appendingPathComponent("sessions"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: archive.appendingPathComponent("payloads"), withIntermediateDirectories: true)
            try await fixture.library.withSnapshot { snapshot in
                let session = try #require(snapshot.sessions.first)
                #expect(session.payloads.isEmpty)
                try FileManager.default.copyItem(
                    at: session.journalURL,
                    to: archive.appendingPathComponent("sessions/\(fixture.id.rawValue.uuidString).jsonl"))
            }
            let inspected = try FileSessionArchive.inspect(directory: archive)
            #expect(inspected.sessions.first?.head.cursor.sequence == 2)
            #expect(try inspected.readRetainedPayload(fixture.title) == nil)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test(arguments: [false, true]) func strictScanRejectsIncompleteDelimiterOrTailWithoutRepair(completeLine: Bool)
        async throws
    {
        let fixture = try await Fixture.make()
        do {
            let journal = try await fixture.library.withSnapshot { try #require($0.sessions.first?.journalURL) }
            let original = try Data(contentsOf: journal)
            let changed = completeLine ? Data(original.dropLast()) : original + Data("partial".utf8)
            try changed.write(to: journal)
            #expect(throws: MiraError.self) {
                try FileSessionIO.scanStrict(journal, sessionID: fixture.id, maximumRecords: 100)
            }
            #expect(try Data(contentsOf: journal) == changed)
            await #expect(throws: MiraError.self) { _ = try await fixture.library.withSnapshot { $0.sessions.count } }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func snapshotRejectsUncertainLibrary() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try FileSessionLibrary(directory: root) { stage in
            if stage == .afterJournalSync { throw MiraError(.storage, "Synthetic uncertainty.") }
        }
        let batch = SessionBatch(
            id: UUID(), sessionID: ConversationID(), expectedSequence: 0,
            events: [.init(sequence: 1, occurredAt: Date(), fact: .archived(revision: 1))])
        if case .indeterminate = await library.append(batch) {} else { Issue.record("Expected uncertainty.") }
        await #expect(throws: MiraError.self) { _ = try await library.withSnapshot { $0.sessions.count } }
        try await library.close()
    }

    @Test func callbackFencesWriterAndCloseUntilActualReturn() async throws {
        let fixture = try await Fixture.make()
        let gate = Gate()
        let writerDone = Flag()
        let closeDone = Flag()
        let writerStarted = Flag()
        let snapshot = Task { try await fixture.library.withSnapshot { _ in try gate.hold() } }
        var append: Task<SessionAppendOutcome, Never>?
        var closing: Task<Void, any Error>?
        do {
            try await eventually { gate.entered.value }
            let batch = SessionBatch(
                id: UUID(), sessionID: fixture.id, expectedSequence: 1,
                events: [.init(sequence: 2, occurredAt: Date(), fact: .archived(revision: 1))])
            append = Task {
                writerStarted.mark()
                let result = await fixture.library.append(batch)
                writerDone.mark()
                return result
            }
            try await eventually { writerStarted.value }
            closing = Task {
                try await fixture.library.close()
                closeDone.mark()
            }
            try await Task.sleep(for: .milliseconds(30))
            #expect(!writerDone.value && !closeDone.value)
            gate.release()
            try await snapshot.value
            let outcome = await append?.value
            if case .committed = outcome {
            } else if case .notCommitted = outcome {
            } else {
                Issue.record("Unexpected append outcome.")
            }
            try await closing?.value
            #expect(writerDone.value && closeDone.value)
        } catch {
            gate.release()
            _ = await snapshot.result
            _ = await append?.value
            _ = await closing?.result
            await fixture.close()
            throw error
        }
        await fixture.close()
    }
}

private struct Fixture: Sendable {
    let root: URL, library: FileSessionLibrary, id: ConversationID, batch: SessionBatch, title: SessionPayloadReference
    static func make() async throws -> Self {
        let root = try directory()
        let id = ConversationID()
        let batchID = UUID()
        let library = try FileSessionLibrary(directory: root.appendingPathComponent("live"))
        let title = try await library.stage(
            Data("Archive title".utf8), sessionID: id, batchID: batchID,
            retentionGroup: UUID(), kind: .title)
        let batch = SessionBatch(
            id: batchID, sessionID: id, expectedSequence: 0,
            events: [
                .init(sequence: 1, occurredAt: Date(), fact: .opened(.init(workspaceID: nil, title: title)))
            ])
        #expect(await library.append(batch) == .committed(batch.cursor))
        return .init(root: root, library: library, id: id, batch: batch, title: title)
    }
    func close() async {
        try? await library.close()
        try? FileManager.default.removeItem(at: root)
    }
}
private func directory() throws -> URL {
    let value = FileManager.default.temporaryDirectory.appendingPathComponent(
        "mira-session-archive-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
    return value
}
private func eventually(_ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw MiraError(.storage, "Archive test boundary was not reached.")
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    var value: Bool { lock.withLock { marked } }
    func mark() { lock.withLock { marked = true } }
}
private final class Gate: @unchecked Sendable {
    let entered = Flag()
    private let semaphore = DispatchSemaphore(value: 0)
    func hold() throws {
        entered.mark()
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw MiraError(.storage, "Archive test boundary timed out.")
        }
    }
    func release() { semaphore.signal() }
}
