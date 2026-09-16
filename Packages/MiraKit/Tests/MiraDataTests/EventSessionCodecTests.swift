import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Typed session event codec", .serialized)
struct EventSessionCodecTests {
    @Test func readableTextAndStructuredJSONPreserveExactBytes() throws {
        let session = ConversationID(), batch = UUID()
        let bodies: [(SessionPayloadKind, String)] = [
            (.userText, "123"), (.visibleThinking, "{}"),
            (.modelOutput, "{\"blocks\":[{\"text\":\"https://example.test/a\",\"type\":\"text\"}]}"),
            (.toolResult, "[true,null,1]"), (.toolResult, "null"),
            (.module, "{ \"opaque\": 1 }"), (.module, "{\"largeInteger\":9007199254740993}")
        ]
        let refs = bodies.map { reference(session, batch, UUID(), $0.0, $0.1) }
        let record = FileSessionRecord(batch: .init(id: batch, sessionID: session, expectedSequence: 0,
            events: refs.enumerated().map { index, ref in
                .init(sequence: Int64(index + 1), occurredAt: Date(), fact: .extensionRecorded(
                    namespace: "test.content", schemaVersion: 1, required: false, body: ref))
            }), payloads: Dictionary(uniqueKeysWithValues: zip(refs, bodies).map { ($0.0.id.uuidString, $0.1.1) }))
        let bytes = try FileSessionIO.encodeRecord(record)
        let rows = try bytes.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
        #expect(rows.count == bodies.count + 1)
        #expect(rows.allSatisfy { $0["record"] == nil && $0["payloads"] == nil })
        let nodes = rows.dropLast().map { ($0["payload"] as! [String: Any])["body"] as! [String: Any] }
        #expect(nodes[0]["text"] as? String == "123" && nodes[0]["json"] == nil)
        #expect(nodes[2]["json"] is [String: Any] && nodes[2]["text"] == nil)
        #expect(nodes[4]["json"] is NSNull)
        #expect(nodes[5]["text"] as? String == bodies[5].1)
        #expect(nodes[6]["text"] as? String == bodies[6].1)
        #expect(try FileSessionIO.decodeRecord(bytes) == record)
    }

    @Test func repeatedReferencesStoreBodyOnceAndExternalNodesHaveNoErasureMarker() throws {
        let session = ConversationID(), batch = UUID(), ref = reference(session, batch, UUID(), .title, "hello")
        let events: [SessionEvent] = [
            .init(sequence: 1, occurredAt: Date(), fact: .opened(.init(workspaceID: nil, title: ref))),
            .init(sequence: 2, occurredAt: Date(), fact: .renamed(title: ref, revision: 1))
        ]
        let record = FileSessionRecord(batch: .init(id: batch, sessionID: session, expectedSequence: 0, events: events),
                                       payloads: [ref.id.uuidString: "hello"])
        let encoded = try FileSessionIO.encodeRecord(record)
        #expect(String(decoding: encoded, as: UTF8.self).components(separatedBy: "\"text\":\"hello\"").count == 2)
        #expect(try FileSessionIO.decodeRecord(encoded) == record)
        let external = SessionPayloadReference(id: UUID(), sessionID: session, batchID: batch, retentionGroup: UUID(),
            kind: .module, byteCount: 1, digest: ref.digest, storage: .external)
        let externalRecord = FileSessionRecord(batch: .init(id: batch, sessionID: session, expectedSequence: 0, events: [
            .init(sequence: 1, occurredAt: Date(), fact: .extensionRecorded(namespace: "test", schemaVersion: 1,
                required: false, body: external))]), payloads: [:])
        let externalBytes = try FileSessionIO.encodeRecord(externalRecord)
        #expect(!String(decoding: externalBytes, as: UTF8.self).contains("erased"))
        #expect(try FileSessionIO.decodeRecord(externalBytes) == externalRecord)
    }

    @Test func canonicalEncodingIsDeterministicAndTimestampRoundTrips() throws {
        let record = makeRecord(at: Date(timeIntervalSince1970: 1_700_000_000.987654))
        let bytes = try FileSessionIO.encodeRecord(record)
        #expect(String(decoding: bytes, as: UTF8.self).contains("2023-11-14T22:13:20.988Z"))
        let decoded = try FileSessionIO.decodeRecord(bytes)
        #expect(decoded == record)
        #expect(try FileSessionIO.encodeRecord(decoded) == bytes)
    }

    @Test func recoveryDiscardsEveryIncompleteTransactionBoundary() throws {
        let first = makeRecord(), second = makeRecord(session: first.batch.sessionID, expected: 1, events: 3)
        let prefix = try FileSessionIO.encodeRecord(first) + Data([10])
        let suffix = try FileSessionIO.encodeRecord(second) + Data([10])
        // Cover every byte of the commit and each complete event boundary. Even a
        // complete admission event is invisible until its transaction commits.
        let newlines = suffix.indices.filter { suffix[$0] == 10 }
        let commitStart = newlines[newlines.count - 2] + 1
        let cuts = Set([0, 1, 30] + newlines.dropLast().map { $0 + 1 } + Array(commitStart..<(suffix.count - 1)))
        try withFile { url in
            for cut in cuts.sorted() {
                try (prefix + suffix.prefix(cut)).write(to: url)
                var recovered: [SessionBatch] = []
                try FileSessionIO.scanRecords(url, sessionID: first.batch.sessionID) { record, _, _ in recovered.append(record.batch) }
                #expect(recovered == [first.batch], "Unexpected publication at byte \(cut)")
                #expect(try Data(contentsOf: url) == prefix)
            }
            try (prefix + suffix.dropLast()).write(to: url)
            #expect(try FileSessionIO.scan(url, sessionID: first.batch.sessionID) == [first.batch, second.batch])
            #expect(try Data(contentsOf: url) == prefix + suffix)
        }
    }

    @Test func corruptCompleteCommitWithoutDelimiterFailsWithoutTruncation() throws {
        let record = makeRecord()
        let bytes = try rewriteCommit(FileSessionIO.encodeRecord(record)) { $0["checksum"] = String(repeating: "0", count: 64) }
        try withFile { url in
            try bytes.write(to: url)
            #expect(throws: MiraError.self) { _ = try FileSessionIO.scan(url, sessionID: record.batch.sessionID) }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func invalidCompleteEventAndSequenceOverflowAreRejected() throws {
        let record = makeRecord()
        let bytes = try FileSessionIO.encodeRecord(record)
        let overflow = try rewriteCommit(bytes) { $0["expected_sequence"] = Int64.max }
        #expect(throws: MiraError.self) { _ = try FileSessionIO.decodeRecord(overflow) }
        try withFile { url in
            for tail in ["{\"type\":\"unknown\"}\n", "\n", "{broken}\n"] {
                let corrupted = bytes + Data([10]) + Data(tail.utf8)
                try corrupted.write(to: url)
                #expect(throws: MiraError.self) { _ = try FileSessionIO.scan(url, sessionID: record.batch.sessionID) }
                #expect(try Data(contentsOf: url) == corrupted)
            }
        }
    }

    @Test func largeBodyCrossesReadChunksAndStrictScanNeverRepairs() throws {
        let session = ConversationID(), batch = UUID(), text = String(repeating: "x", count: 170_000)
        let ref = reference(session, batch, UUID(), .userText, text)
        let record = FileSessionRecord(batch: .init(id: batch, sessionID: session, expectedSequence: 0, events: [
            .init(sequence: 1, occurredAt: Date(), fact: .extensionRecorded(namespace: "test.large", schemaVersion: 1,
                required: false, body: ref))]), payloads: [ref.id.uuidString: text])
        let bytes = try FileSessionIO.encodeRecord(record) + Data([10])
        try withFile { url in
            try bytes.write(to: url)
            #expect(try FileSessionIO.scanStrict(url, sessionID: session, maximumRecords: 1) == [record.batch])
            #expect(try FileSessionIO.scan(url, sessionID: session) == [record.batch])
            let eventOnly = Data(bytes.prefix(try #require(bytes.firstIndex(of: 10)) + 1))
            for partial in [Data(bytes.dropLast()), eventOnly] {
                try partial.write(to: url)
                #expect(throws: MiraError.self) { _ = try FileSessionIO.scanStrict(url, sessionID: session, maximumRecords: 1) }
                #expect(try Data(contentsOf: url) == partial)
            }
        }
    }

    private func makeRecord(session: ConversationID = ConversationID(), expected: Int64 = 0,
                            events: Int = 1, at date: Date = Date()) -> FileSessionRecord {
        .init(batch: .init(id: UUID(), sessionID: session, expectedSequence: expected,
            events: (1...events).map { .init(sequence: expected + Int64($0), occurredAt: date, fact: .archived(revision: $0)) }), payloads: [:])
    }
    private func reference(_ session: ConversationID, _ batch: UUID, _ group: UUID, _ kind: SessionPayloadKind, _ text: String) -> SessionPayloadReference {
        .init(id: UUID(), sessionID: session, batchID: batch, retentionGroup: group, kind: kind,
              byteCount: text.utf8.count, digest: FileSessionIO.digest(Data(text.utf8)))
    }
    private func rewriteCommit(_ bytes: Data, mutate: (inout [String: Any]) -> Void) throws -> Data {
        let index = try #require(bytes.lastIndex(of: 10))
        var commit = try #require(JSONSerialization.jsonObject(with: bytes.suffix(from: index + 1)) as? [String: Any])
        mutate(&commit)
        return bytes.prefix(through: index) + (try JSONSerialization.data(withJSONObject: commit, options: [.sortedKeys]))
    }
    private func withFile(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mira-event-codec-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}
