import Darwin
import Foundation
import MiraCore
import Testing

@Suite("macOS library selection", .timeLimit(.minutes(1)))
struct MacLibrarySelectionTests {
    @Test
    func switchingAndActiveStateSurviveReopen() async throws {
        try await withDirectory { directory in
            let file = directory.appendingPathComponent("selection.json")
            let first = selected(
                directory: "/tmp/mira-first", id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
            let second = selected(
                directory: "/tmp/mira-second", id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
            let store = try MacLibrarySelectionStore(fileURL: file)
            let pending = try await store.begin(from: first, to: second)
            #expect(pending == .switching(from: first, to: second))
            #expect(try await store.state() == pending)
            await store.close()

            let reopened = try MacLibrarySelectionStore(fileURL: file)
            #expect(try await reopened.state() == pending)
            try await reopened.complete(expected: pending, state: .active(second))
            #expect(try await reopened.state() == .active(second))
            await reopened.close()

            let final = try MacLibrarySelectionStore(fileURL: file)
            #expect(try await final.state() == .active(second))
            await final.close()
        }
    }

    @Test
    func beginAndCompleteUseStrictCASAndRejectPendingReplacement() async throws {
        try await withDirectory { directory in
            let store = try MacLibrarySelectionStore(fileURL: directory.appendingPathComponent("selection.json"))
            let first = selected(directory: "/tmp/mira-cas-first", id: UUID())
            let second = selected(directory: "/tmp/mira-cas-second", id: UUID())
            let other = selected(directory: "/tmp/mira-cas-other", id: UUID())
            let pending = try await store.begin(from: first, to: second)

            await #expect(throws: MiraError.self) {
                _ = try await store.begin(from: first, to: other)
            }
            await #expect(throws: MiraError.self) {
                try await store.complete(expected: .active(first), state: .active(second))
            }
            #expect(try await store.state() == pending)

            try await store.complete(expected: pending, state: .active(second))
            await #expect(throws: MiraError.self) {
                try await store.complete(expected: pending, state: .active(other))
            }
            await store.close()
        }
    }

    @Test
    func malformedAndUnknownVersionFilesAreRejected() async throws {
        try await withDirectory { directory in
            let file = directory.appendingPathComponent("selection.json")
            try write(
                file,
                data: Data(
                    #"{"version":99,"state":{"active":{"directory":"/tmp/x","libraryID":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"}}}"#
                        .utf8))
            let unknown = try MacLibrarySelectionStore(fileURL: file)
            await #expect(throws: MiraError.self) { _ = try await unknown.state() }
            await unknown.close()

            try write(file, data: Data("not-json".utf8))
            let malformed = try MacLibrarySelectionStore(fileURL: file)
            await #expect(throws: MiraError.self) { _ = try await malformed.state() }
            await malformed.close()
        }
    }

    @Test
    func unknownNestedFieldsAreRejectedWithoutChangingTheSelection() async throws {
        try await withDirectory { directory in
            let file = directory.appendingPathComponent("selection.json")
            let store = try MacLibrarySelectionStore(fileURL: file)
            let from = selected(directory: "/tmp/mira-nested-first", id: UUID())
            let to = selected(directory: "/tmp/mira-nested-second", id: UUID())
            let pending = try await store.begin(from: from, to: to)
            try await store.complete(expected: pending, state: .active(to))
            var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var state = try #require(envelope["state"] as? [String: Any])
            state["unknown"] = true
            envelope["state"] = state
            let bytes = try JSONSerialization.data(withJSONObject: envelope)
            try write(file, data: bytes)
            await #expect(throws: MiraError.self) { _ = try await store.state() }
            #expect(try Data(contentsOf: file) == bytes)
            await store.close()
        }
    }

    @Test
    func lockExcludesAnotherOwnerAndCloseRejectsFurtherOperations() async throws {
        try await withDirectory { directory in
            let file = directory.appendingPathComponent("selection.json")
            let first = try MacLibrarySelectionStore(fileURL: file)
            await #expect(throws: MiraError.self) {
                _ = try MacLibrarySelectionStore(fileURL: file)
            }
            await first.close()

            let second = try MacLibrarySelectionStore(fileURL: file)
            await second.close()
            await #expect(throws: MiraError.self) { _ = try await second.state() }
        }
    }

    @Test
    func hardLinkedSelectionFileIsRejected() async throws {
        try await withDirectory { directory in
            let file = directory.appendingPathComponent("selection.json")
            let store = try MacLibrarySelectionStore(fileURL: file)
            let value = selected(directory: "/tmp/mira-hardlink", id: UUID())
            _ = try await store.begin(from: value, to: value)
            await store.close()
            let link = directory.appendingPathComponent("selection-copy.json")
            guard Darwin.link(file.path, link.path) == 0 else {
                throw MiraError(.storage, "Could not create test hard link.")
            }
            let linkedStore = try MacLibrarySelectionStore(fileURL: link)
            await #expect(throws: MiraError.self) { _ = try await linkedStore.state() }
            await linkedStore.close()
        }
    }

    private func selected(directory: String, id: UUID) -> MacSelectedLibrary {
        .init(directory: URL(fileURLWithPath: directory, isDirectory: true), libraryID: id)
    }

    private func write(_ file: URL, data: Data) throws {
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func withDirectory(_ operation: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mira-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try await operation(directory)
    }
}
