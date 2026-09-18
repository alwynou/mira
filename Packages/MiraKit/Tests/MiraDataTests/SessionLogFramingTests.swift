import Foundation
import XCTest
import MiraCore
@testable import MiraData

@MainActor
final class SessionLogFramingTests: XCTestCase {
    func testHeaderAndEventsAreReadableAndReopeningSupportsIndexedReadsAndAppend() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = ConversationID()
        let library = try FileSessionLibrary(directory: root)
        let first = try await opening(library, id: id)
        let firstOutcome = await library.append(first)
        XCTAssertEqual(firstOutcome, .committed(first.cursor))
        let journal = root.appendingPathComponent("sessions/\(id.rawValue.uuidString).jsonl")
        let rows = try String(contentsOf: journal, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(rows.first?["type"] as? String, "session")
        XCTAssertNil(rows.first?["seq"])
        XCTAssertEqual(rows.last?["type"] as? String, "mira/commit")
        XCTAssertNil(rows.last?["seq"])
        XCTAssertTrue(rows.dropFirst().dropLast().enumerated().allSatisfy { $0.element["seq"] as? Int == $0.offset })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("payloads").path))
        try await library.close()

        let reopened = try FileSessionLibrary(directory: root)
        let restored = try await reopened.batch(id: first.id, sessionID: id)
        XCTAssertEqual(restored, first)
        let nextID = UUID()
        let title = try await reopened.stage(Data("Renamed".utf8), sessionID: id, batchID: nextID, kind: .title)
        let next = SessionBatch(id: nextID, sessionID: id, expectedSequence: first.cursor.sequence,
            events: [.init(sequence: first.cursor.sequence + 1, occurredAt: instant,
                           fact: .renamed(title: title, revision: 2))])
        let nextOutcome = await reopened.append(next)
        XCTAssertEqual(nextOutcome, .committed(next.cursor))
        let firstAgain = try await reopened.batch(id: first.id, sessionID: id)
        let nextAgain = try await reopened.batch(id: next.id, sessionID: id)
        XCTAssertEqual(firstAgain, first)
        XCTAssertEqual(nextAgain, next)
        try await reopened.close()
    }

    func testEveryInterruptedTailRecoversOnlyTheCommittedPrefix() throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = ConversationID()
        let first = rawOpening(id: id)
        let encoded = try FileSessionIO.frame(first, previous: .initial)
        let second = SessionBatch(id: UUID(), sessionID: id, expectedSequence: 1,
            events: [.init(sequence: 2, occurredAt: instant, fact: .archived(revision: 2))])
        let tail = try FileSessionIO.frame(second, previous: encoded.state).bytes + Data([10])
        let prefix = encoded.bytes + Data([10])
        let url = root.appendingPathComponent("journal.jsonl")
        for length in 0..<tail.count {
            try (prefix + tail.prefix(length)).write(to: url)
            let result = try FileSessionIO.scan(url, sessionID: id)
            // A complete commit missing only LF is acknowledged by recovery.
            XCTAssertEqual(result, length == tail.count - 1 ? [first, second] : [first])
            XCTAssertEqual(try Data(contentsOf: url), length == tail.count - 1 ? prefix + tail : prefix)
        }
    }

    func testCommittedCorruptionIsRejectedWithoutTruncation() throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = ConversationID()
        let encoded = try FileSessionIO.frame(rawOpening(id: id), previous: .initial)
        var data = encoded.bytes + Data([10])
        let marker = try XCTUnwrap(data.range(of: Data("\"checksum\":\"".utf8)))
        data[marker.upperBound] = data[marker.upperBound] == 48 ? 49 : 48
        let url = root.appendingPathComponent("journal.jsonl")
        try data.write(to: url)
        XCTAssertThrowsError(try FileSessionIO.scan(url, sessionID: id))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testStrictArchiveScanNeverRepairsIncompleteTail() throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = ConversationID()
        let data = try FileSessionIO.frame(rawOpening(id: id), previous: .initial).bytes
        let url = root.appendingPathComponent("journal.jsonl")
        try data.write(to: url)
        XCTAssertThrowsError(try FileSessionIO.scanStrict(url, sessionID: id, maximumRecords: 10))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    private var instant: Date { Date(timeIntervalSince1970: 1_800_144_000.123) }
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mira-session-log-\(UUID())")
    }
    private func rawOpening(id: ConversationID) -> SessionBatch {
        .init(id: UUID(), sessionID: id, expectedSequence: 0,
              events: [.init(sequence: 1, occurredAt: instant,
                             fact: .opened(.init(workspaceID: nil, title: .init(kind: .title, bytes: Data("Synthetic".utf8)))))])
    }
    private func opening(_ library: FileSessionLibrary, id: ConversationID) async throws -> SessionBatch {
        let batchID = UUID()
        let title = try await library.stage(Data("Synthetic".utf8), sessionID: id, batchID: batchID, kind: .title)
        return .init(id: batchID, sessionID: id, expectedSequence: 0,
                     events: [.init(sequence: 1, occurredAt: instant, fact: .opened(.init(workspaceID: nil, title: title)))])
    }
}
