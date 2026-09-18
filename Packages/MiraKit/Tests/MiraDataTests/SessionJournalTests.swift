import Foundation
import MiraCore
import Testing
@testable import MiraData

@Suite("File session journal")
struct SessionJournalTests {
    @Test func commitsDuplicatesAndRejectsConflicts() async throws {
        let dir = try temp(); defer { remove(dir) }
        let store = try FileSessionLibrary(directory: dir)
        let id = ConversationID(); let batch = try await simple(store, id, expected: 0)
        let first = await store.append(batch); if first != .committed(batch.cursor) { Issue.record("first append: \(first)") }
        #expect(await store.append(batch) == .committed(batch.cursor))
        let conflict = SessionBatch(id: batch.id, sessionID: id, expectedSequence: 0, events: [SessionEvent(sequence: 1, occurredAt: Date(), fact: .archived(revision: 2))])
        if case .notCommitted = await store.append(conflict) {} else { Issue.record("conflicting batch ID was accepted") }
        try await store.close()
    }

    @Test func cursorAndPageBoundsAreEnforced() async throws {
        let dir = try temp(); defer { remove(dir) }; let store = try FileSessionLibrary(directory: dir); let id = ConversationID()
        for n in 0..<3 {
            let b = try await simple(store, id, expected: Int64(n))
            #expect(await store.append(b) == .committed(b.cursor))
        }
        #expect(try await store.read(sessionID: id, after: 1, limit: 2).count == 2)
        await #expect(throws: MiraError.self) { try await store.read(sessionID: id, after: 0, limit: SessionFormatLimits.maximumReadBatches + 1) }
        try await store.close()
    }

    @Test func stagedPayloadIsInvisibleUntilCommittedAndSurvivesReopen() async throws {
        let dir = try temp(); defer { remove(dir) }; let store = try FileSessionLibrary(directory: dir); let sid = ConversationID(); let bid = UUID()
        let ref = try await store.stage(Data("private".utf8), sessionID: sid, batchID: bid, kind: .userText)
        let title = try await store.stage(Data("Session title".utf8), sessionID: sid, batchID: bid, kind: .title)
        await #expect(throws: MiraError.self) { try await store.read(ref) }
        let batch = SessionBatch(id: bid, sessionID: sid, expectedSequence: 0, events: [
            .init(sequence: 1, occurredAt: Date(), fact: .opened(.init(workspaceID: nil, title: title))),
            .init(sequence: 2, occurredAt: Date(), fact: .extensionRecorded(namespace: "test", schemaVersion: 1, required: false, body: ref))])
        #expect(await store.append(batch) == .committed(batch.cursor)); #expect(try await store.read(ref) == Data("private".utf8)); try await store.close()
        let reopened = try FileSessionLibrary(directory: dir); #expect(try await reopened.read(ref) == Data("private".utf8)); try await reopened.close()
    }

    @Test func truncatedTailIsRecoveredButCompleteCorruptionFailsClosed() async throws {
        let dir = try temp(); defer { remove(dir) }; let sid = ConversationID(); let store = try FileSessionLibrary(directory: dir); let b = try await simple(store, sid, expected: 0); #expect(await store.append(b) == .committed(b.cursor)); try await store.close()
        let journal = dir.appendingPathComponent("sessions/\(sid.rawValue.uuidString).jsonl"); var data = try Data(contentsOf: journal); data.append(Data("{\"incomplete\"".utf8)); try data.write(to: journal); let reopened = try FileSessionLibrary(directory: dir); #expect(try await reopened.batch(id: b.id, sessionID: sid) == b); try await reopened.close()
        var corrupt = try Data(contentsOf: journal); corrupt[corrupt.startIndex] = 88; try corrupt.write(to: journal); #expect(throws: MiraError.self) { _ = try FileSessionLibrary(directory: dir) }
    }

    @Test func secondWriterCannotOpenLibrary() async throws {
        let dir = try temp(); defer { remove(dir) }; let first = try FileSessionLibrary(directory: dir); #expect(throws: MiraError.self) { _ = try FileSessionLibrary(directory: dir) }; try await first.close()
    }

    @Test func uncertainJournalSyncFencesAndReconcileFindsOriginal() async throws {
        let dir = try temp(); defer { remove(dir) }; let faults = Faults(.afterJournalSync); let store = try FileSessionLibrary(directory: dir, faultInjector: faults.call); let b = try await simple(store, ConversationID(), expected: 0)
        if case .indeterminate = await store.append(b) {} else { Issue.record("injected sync uncertainty was not surfaced") }
        let blocked = SessionBatch(id: UUID(), sessionID: b.sessionID, expectedSequence: 0,
            events: [.init(sequence: 1, occurredAt: Date(), fact: .archived(revision: 1))])
        if case .committed = await store.append(blocked) { Issue.record("fenced writer accepted a new batch") }
        #expect(await store.reconcile(b) == .committed(b.cursor)); try await store.close()
    }

    @Test func journalWriteUncertaintyFencesUnrelatedReconcileAndOldDuplicate() async throws {
        let dir = try temp(); defer { remove(dir) }
        let faults = Faults(.afterJournalWrite)
        let store = try FileSessionLibrary(directory: dir, faultInjector: faults.call)
        let first = try await simple(store, ConversationID(), expected: 0)
        if case .indeterminate = await store.append(first) {} else { Issue.record("after-write uncertainty was not surfaced") }
        let unrelated = SessionBatch(id: UUID(), sessionID: first.sessionID, expectedSequence: 0,
            events: [.init(sequence: 1, occurredAt: Date(), fact: .archived(revision: 1))])
        if case .notCommitted = await store.append(unrelated) {} else { Issue.record("unrelated append cleared the fence") }
        if case .notCommitted = await store.reconcile(unrelated) {} else { Issue.record("unrelated reconciliation cleared the fence") }
        #expect(await store.reconcile(first) == .committed(first.cursor))
        #expect(await store.append(first) == .committed(first.cursor))
        try await store.close()
    }

    @Test func uncertaintyAfterExistingHistoryReconcilesWithoutReplayingHistory() async throws {
        let dir = try temp(); defer { remove(dir) }
        let sid = ConversationID(); let store = try FileSessionLibrary(directory: dir)
        let prior = try await simple(store, sid, expected: 0); #expect(await store.append(prior) == .committed(prior.cursor))
        let faults = Faults(.afterJournalSync); let uncertain = SessionBatch(id: UUID(), sessionID: sid, expectedSequence: 1, events: [SessionEvent(sequence: 2, occurredAt: Date(), fact: .archived(revision: 2))]); try await store.close()
        let second = try FileSessionLibrary(directory: dir, faultInjector: faults.call)
        if case .indeterminate = await second.append(uncertain) {} else { Issue.record("history append uncertainty was not surfaced") }
        #expect(await second.reconcile(uncertain) == .committed(uncertain.cursor)); try await second.close(); try await store.close()
    }

    @Test func largeBatchReopensWithinFormatLimit() async throws {
        let dir = try temp(); defer { remove(dir) }; let sid = ConversationID(); let store = try FileSessionLibrary(directory: dir)
        let text = String(repeating: "x", count: 700_000); var expected: Int64 = 0
        for n in 0..<4 {
            let bid = UUID(); let ref = try await store.stage(Data("x".utf8), sessionID: sid, batchID: bid, kind: .module)
            var events: [SessionEvent] = []
            if expected == 0 {
                let title = try await store.stage(Data("Session title".utf8), sessionID: sid, batchID: bid, kind: .title)
                events.append(.init(sequence: 1, occurredAt: Date(), fact: .opened(.init(workspaceID: nil, title: title)))
                )
            }
            events.append(.init(sequence: expected + Int64(events.count) + 1, occurredAt: Date(), fact: .extensionRecorded(namespace: "\(n)-\(text)", schemaVersion: 1, required: false, body: ref)))
            let b = SessionBatch(id: bid, sessionID: sid, expectedSequence: expected, events: events)
            #expect(await store.append(b) == .committed(b.cursor)); expected += Int64(events.count)
        }
        try await store.close(); let reopened = try FileSessionLibrary(directory: dir); #expect(try await reopened.read(sessionID: sid, after: 0, limit: 10).count == 4); try await reopened.close()
    }

    @Test func committedReferenceCanBeReusedByLaterBatch() async throws {
        let dir = try temp(); defer { remove(dir) }; let sid = ConversationID(); let firstID = UUID(); let store = try FileSessionLibrary(directory: dir); let ref = try await store.stage(Data("reused".utf8), sessionID: sid, batchID: firstID, kind: .module)
        let title = try await store.stage(Data("Session title".utf8), sessionID: sid, batchID: firstID, kind: .title)
        let first = SessionBatch(id: firstID, sessionID: sid, expectedSequence: 0, events: [
            .init(sequence: 1, occurredAt: Date(), fact: .opened(.init(workspaceID: nil, title: title))),
            .init(sequence: 2, occurredAt: Date(), fact: .extensionRecorded(namespace: "x", schemaVersion: 1, required: false, body: ref))]); #expect(await store.append(first) == .committed(first.cursor))
        let second = SessionBatch(id: UUID(), sessionID: sid, expectedSequence: 2, events: [SessionEvent(sequence: 3, occurredAt: Date(), fact: .extensionRecorded(namespace: "y", schemaVersion: 1, required: false, body: ref))]); #expect(await store.append(second) == .committed(second.cursor)); try await store.close()
    }

    @Test func symlinkedSessionDirectoryIsRejected() throws {
        let dir = try temp(); defer { remove(dir) }; let outside = try temp(); defer { remove(outside) }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("sessions"), withDestinationURL: outside)
        #expect(throws: MiraError.self) { _ = try FileSessionLibrary(directory: dir) }
    }

    @Test func operatingSystemLockRejectsChildProcessUntilClose() async throws {
        let dir = try temp(); defer { remove(dir) }; let store = try FileSessionLibrary(directory: dir)
        let script = "import fcntl,sys; f=open(sys.argv[1],'r+');\ntry: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB); print('ok'); sys.exit(0)\nexcept BlockingIOError: sys.exit(7)"
        let lock = dir.appendingPathComponent(".lock").path
        let blocked = try runPython(script, argument: lock); #expect(blocked == 7)
        try await store.close(); let free = try runPython(script, argument: lock); #expect(free == 0)
    }

    @Test func completeValidEnvelopeWithoutNewlineIsPreservedAndBadChecksumFails() async throws {
        let dir = try temp(); defer { remove(dir) }; let sid = ConversationID(); let store = try FileSessionLibrary(directory: dir); let b = try await simple(store, sid, expected: 0); #expect(await store.append(b) == .committed(b.cursor)); try await store.close()
        let journal = dir.appendingPathComponent("sessions/\(sid.rawValue.uuidString).jsonl"); var valid = try Data(contentsOf: journal); valid.removeLast(); try valid.write(to: journal); let reopened = try FileSessionLibrary(directory: dir); #expect(try await reopened.batch(id: b.id, sessionID: sid) == b); try await reopened.close()
        var bad = try Data(contentsOf: journal); bad[bad.startIndex + 12] = bad[bad.startIndex + 12] == 48 ? 49 : 48; try bad.write(to: journal); #expect(throws: MiraError.self) { _ = try FileSessionLibrary(directory: dir) }
    }

    @Test func malformedOversizedSingleLineIsRejectedAndEnvelopeIsValidJSON() async throws {
        let dir = try temp(); defer { remove(dir) }; let sid = ConversationID(); let store = try FileSessionLibrary(directory: dir); let b = try await simple(store, sid, expected: 0); #expect(await store.append(b) == .committed(b.cursor)); try await store.close()
        let journal = dir.appendingPathComponent("sessions/\(sid.rawValue.uuidString).jsonl"); let line = try #require(Data(contentsOf: journal).split(separator: 10).last); #expect((try JSONSerialization.jsonObject(with: Data(line))) is [String: Any])
        try (Data(repeating: 65, count: SessionFormatLimits.maximumBatchBytes + 1024) + Data([10])).write(to: journal); #expect(throws: MiraError.self) { _ = try FileSessionLibrary(directory: dir) }
    }

    @Test func directorySyncFaultsHaveExplicitBoundaries() async throws {
        let dir = try temp(); defer { remove(dir) }
        let faults = Faults(.beforeDirectorySync)
        let store = try FileSessionLibrary(directory: dir, faultInjector: faults.call)
        let sessionID = ConversationID(), batchID = UUID()
        let title = try await store.stage(Data("Session title".utf8), sessionID: sessionID, batchID: batchID, kind: .title)
        let batch = SessionBatch(id: batchID, sessionID: sessionID, expectedSequence: 0,
            events: [.init(sequence: 1, occurredAt: Date(), fact: .opened(.init(workspaceID: nil, title: title)))])
        if case .indeterminate = await store.append(batch) {} else { Issue.record("directory sync fault was not surfaced") }
        try? await store.close()
    }

    @Test func headTracksOnlyAcknowledgedBatchesAndReconcileAdvancesIt() async throws {
        let dir = try temp(); defer { remove(dir) }
        let sid = ConversationID()
        try await withStore(at: dir) { store async throws -> Void in
            #expect(try await store.head(sessionID: sid) == .init(cursor: .init(sessionID: sid, sequence: 0), batchID: nil))
        }
        var first: SessionBatch?
        try await withStore(at: dir) { store async throws -> Void in
            let value = try await simple(store, sid, expected: 0)
            first = value
            #expect(await store.append(value) == .committed(value.cursor))
        }
        let firstValue = try #require(first)
        let fault = Faults(.afterJournalSync)
        try await withStore(at: dir, faultInjector: fault.call) { store async throws -> Void in
            let second = try await simple(store, sid, expected: 1)
            guard case .indeterminate = await store.append(second) else { Issue.record("expected uncertain append"); return }
            #expect(try await store.head(sessionID: sid) == .init(cursor: firstValue.cursor, batchID: firstValue.id))
            #expect(await store.reconcile(second) == .committed(second.cursor))
            #expect(try await store.head(sessionID: sid) == .init(cursor: second.cursor, batchID: second.id))
        }
    }

    @Test func readUsesBatchCursorBoundariesForMultiEventRecords() async throws {
        let dir = try temp(); defer { remove(dir) }
        let sid = ConversationID()
        try await withStore(at: dir) { store async throws -> Void in
            let multiID = UUID()
            let title = try await store.stage(Data("Session title".utf8), sessionID: sid, batchID: multiID, kind: .title)
            let multi = SessionBatch(id: multiID, sessionID: sid, expectedSequence: 0, events: [
                .init(sequence: 1, occurredAt: Date(), fact: .opened(.init(workspaceID: nil, title: title))),
                .init(sequence: 2, occurredAt: Date(), fact: .archived(revision: 2)),
                .init(sequence: 3, occurredAt: Date(), fact: .archived(revision: 3))
            ])
            let tail = try await simple(store, sid, expected: 3)
            #expect(await store.append(multi) == .committed(multi.cursor))
            #expect(await store.append(tail) == .committed(tail.cursor))
            #expect(try await store.read(sessionID: sid, after: 0, limit: 1) == [multi])
            #expect(try await store.read(sessionID: sid, after: 2, limit: 1) == [multi])
            #expect(try await store.read(sessionID: sid, after: 3, limit: 1) == [tail])
            #expect(try await store.read(sessionID: sid, after: 4, limit: 1).isEmpty)
        }
    }

    @Test func sessionPaginationKeepsSortedIDsWithoutDuplicates() async throws {
        let dir = try temp(); defer { remove(dir) }
        let ids = (0..<5).map { _ in ConversationID() }.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        try await withStore(at: dir) { store async throws -> Void in
            for id in ids.reversed() {
                let batch = try await simple(store, id, expected: 0)
                #expect(await store.append(batch) == .committed(batch.cursor))
            }
            let second = try await simple(store, ids[2], expected: 1)
            #expect(await store.append(second) == .committed(second.cursor))
            #expect(try await store.sessions(after: nil, limit: 2) == Array(ids.prefix(2)))
            #expect(try await store.sessions(after: ids[1], limit: 2) == Array(ids[2..<4]))
            #expect(try await store.sessions(after: ids[4], limit: 2).isEmpty)
        }
        try await withStore(at: dir) { store async throws -> Void in
            #expect(try await store.sessions(after: nil, limit: 128) == ids)
        }
    }

    private func withStore<T>(at directory: URL, faultInjector: SessionStorageFaultInjector? = nil,
                              body: (FileSessionLibrary) async throws -> T) async throws -> T {
        let store = try FileSessionLibrary(directory: directory, faultInjector: faultInjector)
        do {
            let result = try await body(store)
            try await store.close()
            return result
        } catch {
            try? await store.close()
            throw error
        }
    }

    private func simple(_ store: FileSessionLibrary, _ sid: ConversationID, expected: Int64) async throws -> SessionBatch {
        let id = UUID()
        if expected == 0 {
            let title = try await store.stage(Data("Session title".utf8), sessionID: sid, batchID: id, kind: .title)
            return SessionBatch(id: id, sessionID: sid, expectedSequence: 0,
                events: [.init(sequence: 1, occurredAt: Date(), fact: .opened(.init(workspaceID: nil, title: title)))])
        }
        return SessionBatch(id: id, sessionID: sid, expectedSequence: expected,
            events: [.init(sequence: expected + 1, occurredAt: Date(), fact: .archived(revision: Int(expected + 1)))])
    }
    private func nilReference(_ sid: ConversationID, _ bid: UUID) -> SessionContent { SessionContent(id: UUID(), kind: .module, bytes: Data()) }
    private func temp() throws -> URL { let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mira-session-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false); return u }
    private func remove(_ u: URL) { try? FileManager.default.removeItem(at: u) }
    private func runPython(_ script: String, argument: String) throws -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["python3", "-c", script, argument]; let out = Pipe(); p.standardOutput = out; p.standardError = Pipe(); try p.run(); p.waitUntilExit(); return p.terminationStatus
    }
}

private final class Faults: @unchecked Sendable {
    private let lock = NSLock(); private var pending: SessionStorageFaultStage?
    init(_ stage: SessionStorageFaultStage) { pending = stage }
    var call: SessionStorageFaultInjector { { [self] stage in lock.lock(); defer { lock.unlock() }; if pending == stage { pending = nil; throw MiraError(.storage, "injected") } } }
}
