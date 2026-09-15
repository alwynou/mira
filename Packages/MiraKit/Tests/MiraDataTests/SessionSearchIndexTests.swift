import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("SQLite session search index")
struct SessionSearchIndexTests {
    private func temporaryPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mira-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Search.sqlite").path
    }

    private func withIndex<T>(_ path: String, _ body: (SQLiteSessionSearchIndex) async throws -> T) async throws -> T {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let index: SQLiteSessionSearchIndex
        do { index = try SQLiteSessionSearchIndex(path: path) } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        do {
            let value = try await body(index)
            try await index.close()
            try? FileManager.default.removeItem(at: directory)
            return value
        } catch {
            try? await index.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func withConfiguredIndex<T>(
        _ path: String, substringIndexEnabled: Bool, maximumCandidates: Int = 20_000,
        maximumDuration: Duration = .milliseconds(200), _ body: (SQLiteSessionSearchIndex) async throws -> T
    ) async throws -> T {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let index: SQLiteSessionSearchIndex
        do {
            index = try SQLiteSessionSearchIndex(
                path: path, substringIndexEnabled: substringIndexEnabled, maximumCandidates: maximumCandidates,
                maximumDuration: maximumDuration)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        do {
            let value = try await body(index)
            try await index.close()
            try? FileManager.default.removeItem(at: directory)
            return value
        } catch {
            try? await index.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func reference(
        _ session: ConversationID, _ batch: UUID, kind: SessionPayloadKind, text: String, group: UUID = UUID()
    ) -> SessionPayloadReference {
        .init(
            id: UUID(), sessionID: session, batchID: batch, retentionGroup: group, kind: kind,
            byteCount: text.utf8.count, digest: FileSessionIO.digest(Data(text.utf8)))
    }

    private func update(
        session: ConversationID, batchID: UUID = UUID(), expected: Int64, event: SessionEvent,
        document: SessionSearchDocument? = nil
    ) -> SessionSearchUpdate {
        .init(
            batch: SessionBatch(id: batchID, sessionID: session, expectedSequence: expected, events: [event]),
            documents: document.map { [$0] } ?? [])
    }

    @Test("Real linked FTS indexes English, Chinese and mixed literal text")
    func searchAndCapabilities() async throws {
        let path = try temporaryPath()
        try await withIndex(path) { index in
            let session = ConversationID()
            let batch = UUID()
            let title = reference(session, batch, kind: .title, text: "早餐 Swift/Path %_ \"quoted\"")  // i18n-fixture: Unicode search matching data.
            let event = SessionEvent(
                sequence: 1, occurredAt: Date(timeIntervalSince1970: 100),
                fact: .opened(.init(workspaceID: nil, title: title)))
            try await index.apply(
                update(
                    session: session, batchID: batch, expected: 0, event: event,
                    document: .init(
                        location: .init(
                            sessionID: session, messageID: nil, executionID: nil, part: .title, sequence: 1,
                            occurredAt: event.occurredAt, reference: title), text: "早餐 Swift/Path %_ \"quoted\"")))  // i18n-fixture: Unicode search matching data.
            let english = try await index.search(.init(text: "swift/path"), after: nil, limit: 10)
            #expect(english.matches.count == 1)
            #expect(english.capabilities.wordIndex)
            let chinese = try await index.search(.init(text: "早餐"), after: nil, limit: 10)  // i18n-fixture: Unicode search matching data.
            #expect(chinese.matches.count == 1)
            let literal = try await index.search(.init(text: "%_ \"quoted\""), after: nil, limit: 10)
            #expect(literal.matches.count == 1)
        }
    }

    @Test("Scope, archive, time filters and cursor binding are hard boundaries")
    func filtersAndCursorReset() async throws {
        let path = try temporaryPath()
        try await withIndex(path) { index in
            let session = ConversationID()
            let workspace = WorkspaceID()
            let b1 = UUID()
            let title = reference(session, b1, kind: .title, text: "needle")
            let opened = SessionEvent(
                sequence: 1, occurredAt: Date(timeIntervalSince1970: 100),
                fact: .opened(.init(workspaceID: workspace, title: title)))
            try await index.apply(
                update(
                    session: session, batchID: b1, expected: 0, event: opened,
                    document: .init(
                        location: .init(
                            sessionID: session, messageID: nil, executionID: nil, part: .title, sequence: 1,
                            occurredAt: opened.occurredAt, reference: title), text: "needle")))
            let page = try await index.search(
                .init(
                    text: "needle", scope: .workspace(workspace), since: Date(timeIntervalSince1970: 100),
                    until: Date(timeIntervalSince1970: 101)), after: nil, limit: 1)
            #expect(page.matches.count == 1)
            let cursor = SessionSearchCursor(indexID: UUID(), beforeRowID: 1, queryDigest: "bad")
            await #expect(throws: MiraError.self) {
                try await index.search(.init(text: "needle"), after: cursor, limit: 1)
            }
            let archived = try await index.search(.init(text: "needle", includeArchived: false), after: nil, limit: 1)
            #expect(archived.matches.count == 1)
        }
    }

    @Test("Batch retry is idempotent and gaps or conflicting identities fail")
    func batchIdentityAndGap() async throws {
        let path = try temporaryPath()
        try await withIndex(path) { index in
            let session = ConversationID()
            let bid = UUID()
            let title = reference(session, bid, kind: .title, text: "same")
            let event = SessionEvent(
                sequence: 1, occurredAt: Date(), fact: .opened(.init(workspaceID: nil, title: title)))
            let value = update(
                session: session, batchID: bid, expected: 0, event: event,
                document: .init(
                    location: .init(
                        sessionID: session, messageID: nil, executionID: nil, part: .title, sequence: 1,
                        occurredAt: event.occurredAt, reference: title), text: "same"))
            try await index.apply(value)
            try await index.apply(value)
            #expect((try await index.head(sessionID: session))?.cursor.sequence == 1)
            await #expect(throws: MiraError.self) {
                try await index.apply(
                    .init(
                        batch: .init(id: UUID(), sessionID: session, expectedSequence: 0, events: [event]),
                        documents: []))
            }
            let conflict = SessionSearchUpdate(
                batch: .init(
                    id: bid, sessionID: session, expectedSequence: 0,
                    events: [
                        SessionEvent(
                            sequence: 1, occurredAt: event.occurredAt,
                            fact: .opened(
                                .init(workspaceID: nil, title: reference(session, bid, kind: .title, text: "other"))))
                    ]), documents: [])
            await #expect(throws: MiraError.self) { try await index.apply(conflict) }
        }
    }

    @Test("Invalidation removes every document in a retention group and clear recreates identity")
    func invalidationAndClear() async throws {
        let path = try temporaryPath()
        try await withIndex(path) { index in
            let session = ConversationID()
            let group = UUID()
            let bid = UUID()
            let title = reference(session, bid, kind: .title, text: "secret", group: group)
            let opened = SessionEvent(
                sequence: 1, occurredAt: Date(), fact: .opened(.init(workspaceID: nil, title: title)))
            try await index.apply(
                update(
                    session: session, batchID: bid, expected: 0, event: opened,
                    document: .init(
                        location: .init(
                            sessionID: session, messageID: nil, executionID: nil, part: .title, sequence: 1,
                            occurredAt: opened.occurredAt, reference: title), text: "secret")))
            let invalidation = SessionInvalidation(
                operationID: UUID(), executionIDs: [], retentionGroups: [group], authorizationEpoch: 1,
                reason: .forgotten)
            try await index.apply(
                .init(
                    batch: .init(
                        id: UUID(), sessionID: session, expectedSequence: 1,
                        events: [.init(sequence: 2, occurredAt: Date(), fact: .invalidated(invalidation))]),
                    documents: []))
            #expect((try await index.search(.init(text: "secret"), after: nil, limit: 10)).matches.isEmpty)
            let old = try await index.head(sessionID: session)
            try await index.clear()
            try await index.verifyEmpty()
            #expect((try await index.head(sessionID: session)) == nil)
            #expect(old != nil)
        }
    }

    @Test("Capabilities expose the linked SQLite FTS probes")
    func capabilitiesAreObservable() async throws {
        let path = try temporaryPath()
        try await withIndex(path) { index in
            let session = ConversationID()
            let batch = UUID()
            let title = reference(session, batch, kind: .title, text: "probe")
            let event = SessionEvent(
                sequence: 1, occurredAt: Date(timeIntervalSinceReferenceDate: 0.123456789), fact: .opened(.init(workspaceID: nil, title: title)))
            try await index.apply(
                update(
                    session: session, batchID: batch, expected: 0, event: event,
                    document: .init(
                        location: .init(
                            sessionID: session, messageID: nil, executionID: nil, part: .title, sequence: 1,
                            occurredAt: event.occurredAt, reference: title), text: "probe")))
            let page = try await index.search(.init(text: "probe"), after: nil, limit: 1)
            #expect(page.capabilities.wordIndex)
            #expect(page.matches.first?.occurredAt == event.occurredAt)
            let boundary = try await index.search(
                .init(text: "probe", since: event.occurredAt, until: event.occurredAt.addingTimeInterval(0.00000001)),
                after: nil, limit: 1)
            #expect(boundary.matches.count == 1)
        }
    }

    @Test("Trigram-disabled indexes use bounded substring fallback for short Chinese terms")
    func trigramDisabledFallback() async throws {
        let path = try temporaryPath()
        try await withConfiguredIndex(path, substringIndexEnabled: false, maximumCandidates: 4) { index in
            let session = ConversationID()
            let batch = UUID()
            let text = "春日早餐 Swift/Path" // i18n-fixture: Unicode search matching data.
            let title = reference(session, batch, kind: .title, text: text)  // i18n-fixture: Unicode search matching data.
            let event = SessionEvent(
                sequence: 1, occurredAt: Date(), fact: .opened(.init(workspaceID: nil, title: title)))
            try await index.apply(
                update(
                    session: session, batchID: batch, expected: 0, event: event,
                    document: .init(
                        location: .init(
                            sessionID: session, messageID: nil, executionID: nil, part: .title, sequence: 1,
                            occurredAt: event.occurredAt, reference: title), text: text)))
            let two = try await index.search(.init(text: "早餐"), after: nil, limit: 4)  // i18n-fixture: Unicode search matching data.
            let three = try await index.search(.init(text: "春日早"), after: nil, limit: 4)  // i18n-fixture: Unicode search matching data.
            // Chinese strings are intentional Unicode/search fixtures, not UI copy.
            #expect(two.matches.count == 1)
            #expect(three.matches.count == 1)
            #expect(two.capabilities.wordIndex)
            #expect(three.capabilities.wordIndex)
        }
    }

    @Test("Duplicate documents and mismatched timestamps are rejected")
    func invalidDocumentMetadata() async throws {
        let path = try temporaryPath()
        try await withIndex(path) { index in
            let session = ConversationID()
            let batch = UUID()
            let title = reference(session, batch, kind: .title, text: "metadata")
            let event = SessionEvent(
                sequence: 1, occurredAt: Date(timeIntervalSince1970: 10),
                fact: .opened(.init(workspaceID: nil, title: title)))
            let location = SessionSearchLocation(
                sessionID: session, messageID: nil, executionID: nil, part: .title, sequence: 1,
                occurredAt: event.occurredAt, reference: title)
            let document = SessionSearchDocument(location: location, text: "metadata")
            await #expect(throws: MiraError.self) {
                try await index.apply(
                    .init(
                        batch: .init(id: batch, sessionID: session, expectedSequence: 0, events: [event]),
                        documents: [document, document]))
            }
            let wrongTime = SessionSearchDocument(
                location: .init(
                    sessionID: session, messageID: nil, executionID: nil, part: .title, sequence: 1,
                    occurredAt: Date(timeIntervalSince1970: 11), reference: title), text: "metadata")
            await #expect(throws: MiraError.self) {
                try await index.apply(
                    .init(
                        batch: .init(id: batch, sessionID: session, expectedSequence: 0, events: [event]),
                        documents: [wrongTime]))
            }
        }
    }

    @Test("Clear invalidates old cursors and recreates a private empty database")
    func clearIdentityAndPermissions() async throws {
        let path = try temporaryPath()
        try await withIndex(path) { index in
            let session = ConversationID()
            let batch = UUID()
            let title = reference(session, batch, kind: .title, text: "cursor")
            let event = SessionEvent(
                sequence: 1, occurredAt: Date(), fact: .opened(.init(workspaceID: nil, title: title)))
            try await index.apply(
                update(
                    session: session, batchID: batch, expected: 0, event: event,
                    document: .init(
                        location: .init(
                            sessionID: session, messageID: nil, executionID: nil, part: .title, sequence: 1,
                            occurredAt: event.occurredAt, reference: title), text: "cursor")))
            let first = try await index.search(.init(text: "cursor"), after: nil, limit: 1)
            let oldCursor = try #require(first.nextCursor)
            try await index.clear()
            try await index.verifyEmpty()
            await #expect(throws: MiraError.self) {
                try await index.search(.init(text: "cursor"), after: oldCursor, limit: 1)
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test("Cancellation of an in-flight search propagates CancellationError")
    func cancelledSearchThrowsCancellationError() async throws {
        let path = try temporaryPath()
        try await withConfiguredIndex(
            path, substringIndexEnabled: false, maximumCandidates: 20_000, maximumDuration: .milliseconds(200)
        ) { index in
            let task = Task { try await index.search(.init(text: "cancel-me"), after: nil, limit: 1) }
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("Cancelled search unexpectedly succeeded")
            } catch is CancellationError {} catch { Issue.record("Expected CancellationError, got \(error)") }
        }
    }

    @Test("Pagination advances independently from truncation")
    func paginationAndCandidateCap() async throws {
        let path = try temporaryPath()
        try await withConfiguredIndex(path, substringIndexEnabled: false, maximumCandidates: 2) { index in
            for ordinal in 0..<5 {
                let session = ConversationID()
                let batch = UUID()
                let text = "common \(ordinal == 0 ? "needle" : "haystack")"
                let title = reference(session, batch, kind: .title, text: text)
                let event = SessionEvent(
                    sequence: 1, occurredAt: Date(), fact: .opened(.init(workspaceID: nil, title: title)))
                try await index.apply(
                    update(
                        session: session, batchID: batch, expected: 0, event: event,
                        document: .init(
                            location: .init(
                                sessionID: session, messageID: nil, executionID: nil, part: .title,
                                sequence: 1, occurredAt: event.occurredAt, reference: title), text: text)))
            }
            let first = try await index.search(.init(text: "needle"), after: nil, limit: 10)
            #expect(first.isTruncated && first.matches.isEmpty && first.scannedCandidates == 2)
            let second = try await index.search(.init(text: "needle"), after: #require(first.nextCursor), limit: 10)
            #expect(second.isTruncated && second.matches.isEmpty && second.scannedCandidates == 2)
            let third = try await index.search(.init(text: "needle"), after: #require(second.nextCursor), limit: 10)
            #expect(!third.isTruncated && third.matches.count == 1 && third.nextCursor == nil)
            var cursor: SessionSearchCursor?
            var ids = Set<UUID>()
            repeat {
                let page = try await index.search(.init(text: "common"), after: cursor, limit: 2)
                #expect(!page.isTruncated)
                for hit in page.matches { #expect(ids.insert(hit.reference.id).inserted) }
                cursor = page.nextCursor
            } while cursor != nil
            #expect(ids.count == 5)
        }
    }

    @Test("Archived and workspace filters exclude nonmatching sessions")
    func negativeScopeAndArchiveFilters() async throws {
        let path = try temporaryPath()
        try await withIndex(path) { index in
            let session = ConversationID()
            let workspace = WorkspaceID()
            let batch = UUID()
            let title = reference(session, batch, kind: .title, text: "scoped")
            let opened = SessionEvent(
                sequence: 1, occurredAt: Date(), fact: .opened(.init(workspaceID: workspace, title: title)))
            try await index.apply(
                update(
                    session: session, batchID: batch, expected: 0, event: opened,
                    document: .init(
                        location: .init(
                            sessionID: session, messageID: nil, executionID: nil, part: .title, sequence: 1,
                            occurredAt: opened.occurredAt, reference: title), text: "scoped")))
            let archived = SessionEvent(sequence: 2, occurredAt: Date(), fact: .archived(revision: 2))
            try await index.apply(
                .init(
                    batch: .init(id: UUID(), sessionID: session, expectedSequence: 1, events: [archived]), documents: []
                ))
            #expect(
                try await index.search(.init(text: "scoped", includeArchived: false), after: nil, limit: 10).matches
                    .isEmpty)
            #expect(
                try await index.search(
                    .init(text: "scoped", scope: .workspace(WorkspaceID()), includeArchived: true), after: nil,
                    limit: 10
                ).matches.isEmpty)
            #expect(
                try await index.search(.init(text: "scoped", includeArchived: true), after: nil, limit: 10).matches
                    .count == 1)
        }
    }

    @Test("A failed clear stays fenced and can retry without touching unsafe links")
    func failedClearIsRetryable() async throws {
        let path = try temporaryPath()
        try await withIndex(path) { index in
            let target = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("unrelated.txt")
            try Data("unrelated".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(atPath: path + "-shm", withDestinationPath: target.path)
            await #expect(throws: MiraError.self) { try await index.clear() }
            #expect(try Data(contentsOf: target) == Data("unrelated".utf8))
            await #expect(throws: MiraError.self) { try await index.head(sessionID: ConversationID()) }
            try FileManager.default.removeItem(atPath: path + "-shm")
            try await index.clear()
            try await index.verifyEmpty()
        }
    }

    @Test("FTS vocabulary verification detects residual postings without content rows")
    func emptyVerificationChecksPostings() async throws {
        let path = try temporaryPath()
        try await withIndex(path) { index in
            let session = ConversationID()
            let batch = UUID()
            let title = reference(session, batch, kind: .title, text: "residual")
            let event = SessionEvent(
                sequence: 1, occurredAt: Date(), fact: .opened(.init(workspaceID: nil, title: title)))
            try await index.apply(
                update(
                    session: session, batchID: batch, expected: 0, event: event,
                    document: .init(
                        location: .init(
                            sessionID: session, messageID: nil, executionID: nil, part: .title,
                            sequence: 1, occurredAt: event.occurredAt, reference: title), text: "residual")))
            let corruption = try DatabaseQueue(path: path)
            do {
                try await corruption.write { db in
                    try db.execute(
                        sql: "DELETE FROM search_documents; DELETE FROM search_batches; DELETE FROM search_sessions")
                }
                try corruption.close()
            } catch {
                try? corruption.close()
                throw error
            }
            await #expect(throws: MiraError.self) { try await index.verifyEmpty() }
            try await index.clear()
            try await index.verifyEmpty()
        }
    }

    @Test("An expired zero-duration budget reports truncation")
    func expiredBudgetIsExplicit() async throws {
        let path = try temporaryPath()
        try await withConfiguredIndex(
            path, substringIndexEnabled: false, maximumCandidates: 20_000, maximumDuration: .milliseconds(0)
        ) { index in
            let page = try await index.search(.init(text: "anything"), after: nil, limit: 10)
            #expect(page.isTruncated)
        }
    }
}
