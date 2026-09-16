import Foundation
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Inline session journal", .serialized)
struct InlineSessionJournalTests {
    @Test func ordinaryTextKindsStayInlineInTheJournal() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let session = ConversationID(), batchID = UUID()
            let kinds: [SessionPayloadKind] = [.userText, .visibleAnswer, .visibleThinking, .toolCall, .request]
            var references: [SessionPayloadReference] = []
            var values: [Data] = []
            for (index, kind) in kinds.enumerated() {
                let value = Data("inline-\(kind.rawValue)-\(index)".utf8)
                values.append(value)
                references.append(try await library.stage(value, sessionID: session, batchID: batchID,
                                                          retentionGroup: UUID(), kind: kind))
            }
            let batch = extensionBatch(session: session, batchID: batchID, expected: 0, references: references)
            #expect(await library.append(batch) == .committed(batch.cursor))
            #expect(references.allSatisfy { $0.storage == .inline })
            for (index, reference) in references.enumerated() { #expect(try await library.read(reference) == values[index]) }
            #expect(try childNames(directory.appendingPathComponent("payloads")) == [])
            let journal = try String(contentsOf: journalURL(directory, session), encoding: .utf8)
            for bytes in values { #expect(journal.contains(String(decoding: bytes, as: UTF8.self))) }
            #expect(try childNames(directory.appendingPathComponent("pending-payloads")) == [])
            try await library.close()
        }
    }

    @Test func uncommittedInlineStageIsInvisibleAndLeavesNoPayloadFiles() async throws {
        try await withDirectory { directory in
            let session = ConversationID()
            let library = try FileSessionLibrary(directory: directory)
            let reference = try await library.stage(Data("staged only".utf8), sessionID: session, batchID: UUID(),
                                                    retentionGroup: UUID(), kind: .userText)
            #expect(reference.storage == .inline)
            await #expect(throws: MiraError.self) { try await library.read(reference) }
            #expect(try childNames(directory.appendingPathComponent("sessions")) == [])
            #expect(try childNames(directory.appendingPathComponent("payloads")) == [])
            try await library.close()
            let reopened = try FileSessionLibrary(directory: directory)
            let sessions = try await reopened.sessions(after: nil, limit: 10)
            #expect(sessions.isEmpty)
            try await reopened.close()
        }
    }

    @Test func uncertainAppendReconcilesInlineBatchAfterRestart() async throws {
        try await withDirectory { directory in
            let session = ConversationID(), batchID = UUID()
            let failing = try FileSessionLibrary(directory: directory) { stage in
                if stage == .afterJournalWrite { throw MiraError(.storage, "Synthetic journal write uncertainty.") }
            }
            let reference = try await failing.stage(Data("durable inline body".utf8), sessionID: session,
                                                    batchID: batchID, retentionGroup: UUID(), kind: .userText)
            let batch = extensionBatch(session: session, batchID: batchID, expected: 0, references: [reference])
            guard case .indeterminate = await failing.append(batch) else {
                Issue.record("afterJournalWrite did not produce an indeterminate append")
                try await failing.close()
                return
            }
            try await failing.close()
            let reopened = try FileSessionLibrary(directory: directory)
            #expect(await reopened.reconcile(batch) == .committed(batch.cursor))
            #expect(try await reopened.read(reference) == Data("durable inline body".utf8))
            #expect(try await reopened.head(sessionID: session) == .init(cursor: batch.cursor, batchID: batch.id))
            try await reopened.close()
        }
    }

    @Test func appendingARecordPreservesEveryPriorJournalByte() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let session = ConversationID()
            let first = extensionBatch(session: session, batchID: UUID(), expected: 0, references: [])
            #expect(await library.append(first) == .committed(first.cursor))
            let url = journalURL(directory, session)
            let prefix = try Data(contentsOf: url)
            let second = extensionBatch(session: session, batchID: UUID(), expected: 1, references: [])
            #expect(await library.append(second) == .committed(second.cursor))
            let appended = try Data(contentsOf: url)
            #expect(appended.count > prefix.count)
            #expect(appended.prefix(prefix.count) == prefix)
            try await library.close()
        }
    }

    @Test func exactUTF8NewlinesQuotesAndUnicodeRoundTrip() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let session = ConversationID(), value = "line one\n\"quoted\" — 中文 🐉\nline three" // i18n-fixture: exact UTF-8 persistence across JSON escaping.
            let reference = try await library.stage(Data(value.utf8), sessionID: session, batchID: UUID(),
                                                    retentionGroup: UUID(), kind: .userText)
            let batch = extensionBatch(session: session, batchID: reference.batchID, expected: 0, references: [reference])
            #expect(await library.append(batch) == .committed(batch.cursor))
            #expect(reference.storage == .inline)
            #expect(try await library.read(reference) == Data(value.utf8))
            try await library.close()
        }
    }

    @Test func binaryAndOversizedTextUseExternalPayloadFiles() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let session = ConversationID()
            let binary = Data([0xff, 0xfe, 0x00, 0xfd])
            let binaryReference = try await library.stage(binary, sessionID: session, batchID: UUID(),
                                                          retentionGroup: UUID(), kind: .toolResult)
            let large = Data(repeating: 0x78, count: 256 * 1024 + 1)
            let largeReference = try await library.stage(large, sessionID: session, batchID: UUID(),
                                                         retentionGroup: UUID(), kind: .modelOutput)
            #expect(binaryReference.storage == .external && largeReference.storage == .external)
            let first = extensionBatch(session: session, batchID: binaryReference.batchID, expected: 0, references: [binaryReference])
            #expect(await library.append(first) == .committed(first.cursor))
            let second = extensionBatch(session: session, batchID: largeReference.batchID, expected: 1, references: [largeReference])
            #expect(await library.append(second) == .committed(second.cursor))
            #expect(try await library.read(binaryReference) == binary)
            #expect(try await library.read(largeReference) == large)
            #expect(FileManager.default.fileExists(atPath: payloadURL(directory, reference: binaryReference).path))
            #expect(FileManager.default.fileExists(atPath: payloadURL(directory, reference: largeReference).path))
            try await library.close()
        }
    }

    @Test func inlineBatchBudgetOverflowUsesExternalStorage() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let session = ConversationID(), batchID = UUID()
            var references: [SessionPayloadReference] = []
            for _ in 0..<9 {
                references.append(try await library.stage(Data(repeating: 0x78, count: 240_000), sessionID: session,
                                                           batchID: batchID, retentionGroup: UUID(), kind: .module))
            }
            #expect(references.dropLast().allSatisfy { $0.storage == .inline })
            #expect(references.last?.storage == .external)
            let batch = extensionBatch(session: session, batchID: batchID, expected: 0, references: references)
            #expect(await library.append(batch) == .committed(batch.cursor))
            #expect(try await library.read(references[8]) == Data(repeating: 0x78, count: 240_000))
            try await library.close()
        }
    }

    @Test func missingLiveInlineBodyIsRejectedAfterRecomputedEnvelope() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let session = ConversationID(), value = Data("live inline body".utf8)
            let reference = try await library.stage(value, sessionID: session, batchID: UUID(), retentionGroup: UUID(), kind: .userText)
            let batch = extensionBatch(session: session, batchID: reference.batchID, expected: 0, references: [reference])
            #expect(await library.append(batch) == .committed(batch.cursor))
            try await library.close()
            let url = journalURL(directory, session)
            let original = try Data(contentsOf: url)
            var record = try FileSessionIO.decodeRecord(Data(original.dropLast()))
            record.payloads.removeValue(forKey: reference.id.uuidString)
            let replacement = try FileSessionIO.encodeRecord(record) + Data([10])
            try replacement.write(to: url)
            #expect(throws: MiraError.self) { _ = try FileSessionLibrary(directory: directory) }
        }
    }

    @Test func privacyPurgeRemovesInlineBytesButPreservesJournalAndAllowsLaterAppend() async throws {
        try await withDirectory { directory in
            let library = try FileSessionLibrary(directory: directory)
            let session = ConversationID(), targetGroup = UUID(), retainedGroup = UUID(), firstID = UUID()
            let target = try await library.stage(Data("erase me".utf8), sessionID: session, batchID: firstID,
                                                 retentionGroup: targetGroup, kind: .userText)
            let retained = try await library.stage(Data("keep me".utf8), sessionID: session, batchID: firstID,
                                                   retentionGroup: retainedGroup, kind: .visibleAnswer)
            let first = extensionBatch(session: session, batchID: firstID, expected: 0, references: [target, retained])
            #expect(await library.append(first) == .committed(first.cursor))
            let invalidation = SessionBatch(id: UUID(), sessionID: session, expectedSequence: first.cursor.sequence, events: [
                .init(sequence: first.cursor.sequence + 1, occurredAt: Date(), fact: .invalidated(.init(operationID: UUID(), executionIDs: [],
                    retentionGroups: [targetGroup], authorizationEpoch: 1, reason: .forgotten)))])
            #expect(await library.append(invalidation) == .committed(invalidation.cursor))
            await #expect(throws: MiraError.self) { try await library.read(target) }
            let head = try await library.head(sessionID: session)
            try await library.purge(sessionID: session, retentionGroups: [targetGroup])
            #expect(try await library.head(sessionID: session) == head)
            #expect(try await library.batch(id: first.id, sessionID: session) == first)
            #expect(try await library.read(retained) == Data("keep me".utf8))
            let journal = try String(contentsOf: journalURL(directory, session), encoding: .utf8)
            #expect(!journal.contains("erase me") && journal.contains("keep me"))
            try await library.verifyPurged(sessionID: session, retentionGroups: [targetGroup])
            let later = try await library.stage(Data("later".utf8), sessionID: session, batchID: UUID(), retentionGroup: UUID(), kind: .draft)
            let laterBatch = extensionBatch(session: session, batchID: later.batchID, expected: head.cursor.sequence,
                                             references: [later])
            #expect(await library.append(laterBatch) == .committed(laterBatch.cursor))
            try await library.close()
        }
    }

    @Test(arguments: [
        SessionStorageFaultStage.beforeInlinePurgeWrite,
        .afterInlinePurgeWrite,
        .beforeInlinePurgePublication,
        .afterInlinePurgePublication
    ])
    func inlinePurgeFaultsResumeOnReopen(_ stage: SessionStorageFaultStage) async throws {
        try await withDirectory { directory in
            let session = ConversationID(), group = UUID()
            let library = try FileSessionLibrary(directory: directory)
            let reference = try await library.stage(Data("purge fault body".utf8), sessionID: session, batchID: UUID(),
                                                     retentionGroup: group, kind: .userText)
            let batch = extensionBatch(session: session, batchID: reference.batchID, expected: 0, references: [reference])
            #expect(await library.append(batch) == .committed(batch.cursor))
            let invalidation = SessionBatch(id: UUID(), sessionID: session, expectedSequence: 1, events: [
                .init(sequence: 2, occurredAt: Date(), fact: .invalidated(.init(operationID: UUID(), executionIDs: [],
                    retentionGroups: [group], authorizationEpoch: 1, reason: .forgotten)))])
            #expect(await library.append(invalidation) == .committed(invalidation.cursor))
            try await library.close()
            #expect(throws: MiraError.self) {
                _ = try FileSessionLibrary(directory: directory) { current in
                    if current == stage { throw MiraError(.storage, "Synthetic inline purge fault.") }
                }
            }
            let reopened = try FileSessionLibrary(directory: directory)
            try await reopened.verifyPurged(sessionID: session, retentionGroups: [group])
            #expect(!containsPurgeTemporary(in: directory))
            try await reopened.close()
        }
    }

    private func extensionBatch(session: ConversationID, batchID: UUID, expected: Int64,
                                references: [SessionPayloadReference]) -> SessionBatch {
        .init(id: batchID, sessionID: session, expectedSequence: expected,
              events: references.enumerated().map { index, reference in
                  .init(sequence: expected + Int64(index) + 1, occurredAt: Date(),
                        fact: .extensionRecorded(namespace: "inline.fixture.\(reference.kind.rawValue)",
                                                  schemaVersion: 1, required: false, body: reference))
              } + (references.isEmpty ? [.init(sequence: expected + 1, occurredAt: Date(), fact: .archived(revision: Int(expected + 1)))] : []))
    }

    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-inline-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    private func journalURL(_ directory: URL, _ session: ConversationID) -> URL {
        directory.appendingPathComponent("sessions/\(session.rawValue.uuidString).jsonl")
    }

    private func payloadURL(_ directory: URL, reference: SessionPayloadReference) -> URL {
        directory.appendingPathComponent("payloads/\(reference.sessionID.rawValue.uuidString)/\(reference.batchID.uuidString)/\(reference.id.uuidString).bin")
    }

    private func childNames(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func containsPurgeTemporary(in directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return false }
        return enumerator.compactMap { $0 as? URL }.contains { $0.lastPathComponent.hasPrefix(".purge-") }
    }
}
