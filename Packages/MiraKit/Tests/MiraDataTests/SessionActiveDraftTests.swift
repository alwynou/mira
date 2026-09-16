import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Session active drafts", .serialized)
struct SessionActiveDraftTests {
    @Test func replacementReopensWithoutAddingJournalRowsAndOldOwnerCannotDelete() async throws {
        let root = try draftTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = ConversationID(), batchID = UUID(), group = UUID()
        let library = try FileSessionLibrary(directory: root)
        let reference = try await library.stage(Data("request".utf8), sessionID: session, batchID: batchID,
                                                retentionGroup: group, kind: .request)
        let batch = SessionBatch(id: batchID, sessionID: session, expectedSequence: 0,
                                 events: [.init(sequence: 1, occurredAt: Date(), fact: .extensionRecorded(namespace: "request", schemaVersion: 1, required: true, body: reference))])
        #expect(await library.append(batch) == .committed(batch.cursor))
        let first = SessionActiveDraft(request: reference, executionID: .init(), attemptID: UUID(), authorizationEpoch: 1,
                                       revision: 1, blocks: [.init(id: "answer", content: .text("one"))])
        try await library.saveActiveDraft(first)
        let second = SessionActiveDraft(request: reference, executionID: first.executionID, attemptID: first.attemptID,
                                        authorizationEpoch: 1, revision: 2, blocks: [.init(id: "answer", content: .text("two"))])
        try await library.saveActiveDraft(second)
        #expect(try await library.head(sessionID: session).cursor.sequence == 1)
        await #expect(throws: MiraError.self) { try await library.saveActiveDraft(first) }
        try await library.removeActiveDraft(sessionID: session, attemptID: UUID())
        #expect(try await library.activeDraft(sessionID: session) == second)
        try await library.close()
        let reopened = try FileSessionLibrary(directory: root)
        #expect(try await reopened.activeDraft(sessionID: session) == second)
        try await reopened.removeActiveDraft(sessionID: session, attemptID: first.attemptID)
        #expect(try await reopened.activeDraft(sessionID: session) == nil)
        try await reopened.close()
    }

    @Test func invalidationAndUnpublishedCleanupRemoveDrafts() async throws {
        let root = try draftTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = ConversationID(), batchID = UUID(), group = UUID(), operation = UUID()
        let library = try FileSessionLibrary(directory: root)
        let reference = try await library.stage(Data("request".utf8), sessionID: session, batchID: batchID,
                                                retentionGroup: group, kind: .request)
        let accepted = SessionBatch(id: batchID, sessionID: session, expectedSequence: 0,
                                    events: [.init(sequence: 1, occurredAt: Date(), fact: .extensionRecorded(namespace: "request", schemaVersion: 1, required: true, body: reference))])
        #expect(await library.append(accepted) == .committed(accepted.cursor))
        let draft = SessionActiveDraft(request: reference, executionID: .init(), attemptID: UUID(), authorizationEpoch: 1, revision: 1, blocks: [])
        try await library.saveActiveDraft(draft)
        let invalidation = SessionBatch(id: operation, sessionID: session, expectedSequence: 1,
            events: [.init(sequence: 2, occurredAt: Date(), fact: .invalidated(.init(operationID: operation, executionIDs: [], retentionGroups: [group], authorizationEpoch: 2, reason: .forgotten)))])
        #expect(await library.append(invalidation) == .committed(invalidation.cursor))
        try await library.purge(sessionID: session, retentionGroups: [group])
        #expect(try await library.activeDraft(sessionID: session) == nil)
        try await library.verifyPurged(sessionID: session, retentionGroups: [group])
        try await library.close()
    }

    @Test func incompleteToolArgumentsRemainValidAndLinkedDraftsAreRejected() async throws {
        let request = SessionPayloadReference(id: UUID(), sessionID: ConversationID(), batchID: UUID(), retentionGroup: UUID(), kind: .request, byteCount: 1, digest: String(repeating: "a", count: 64))
        let draft = SessionActiveDraft(request: request, executionID: .init(), attemptID: UUID(), authorizationEpoch: 1, revision: 1,
                                       blocks: [.init(id: "tool", content: .toolCall(.init(id: "call", name: "search", arguments: "{\"query\":")))])
        try draft.validate()
        let root = try draftTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("active-drafts"), withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside"); try Data("x".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("active-drafts/\(request.sessionID.rawValue.uuidString).json"), withDestinationURL: outside)
        #expect(throws: MiraError.self) { _ = try FileSessionLibrary(directory: root) }
    }
}

private func draftTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mira-active-draft-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
