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

    @Test func snapshotIncludesOnlyCommittedLiveBodiesAndRejectsMissingOrChangedBytes() async throws {
        let fixture = try await Fixture.make()
        do {
            _ = try await fixture.library.stage(
                Data("unpublished".utf8), sessionID: fixture.id,
                batchID: UUID(), retentionGroup: UUID(), kind: .module)
            let files = try await fixture.library.withSnapshot { snapshot in
                #expect(try snapshot.readBatches(sessionID: fixture.id).map(\.id) == [fixture.batch.id])
                return try #require(snapshot.sessions.first).payloads
            }
            #expect(files.count == 1)
            let body = try #require(files[fixture.title])
            try Data("wrong".utf8).write(to: body)
            await #expect(throws: MiraError.self) { _ = try await fixture.library.withSnapshot { $0.sessions.count } }
            try FileManager.default.removeItem(at: body)
            await #expect(throws: MiraError.self) { _ = try await fixture.library.withSnapshot { $0.sessions.count } }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func invalidationExplainsMissingBodyButRemnantBlocksCapture() async throws {
        let fixture = try await Fixture.make()
        do {
            let body = try await fixture.library.withSnapshot {
                try #require($0.sessions.first?.payloads[fixture.title])
            }
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
            #expect(!FileManager.default.fileExists(atPath: body.path))
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
            #expect(try FileSessionArchive.inspect(directory: archive).sessions.first?.head.cursor.sequence == 2)
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
