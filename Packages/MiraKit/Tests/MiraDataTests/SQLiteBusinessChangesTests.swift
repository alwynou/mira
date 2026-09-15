import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("SQLite business changes", .timeLimit(.minutes(1)))
struct SQLiteBusinessChangesTests {
    @Test func committedWritesPublishMonotonicRevisionsAndRollbackPublishesNothing() async throws {
        let fixture = try BusinessChangesFixture.make()
        do {
            let changes = SQLiteBusinessChanges(database: fixture.database)
            let stream = try await changes.observe()
            var iterator = stream.makeAsyncIterator()
            #expect(await iterator.next() == .init(revision: 0))

            try fixture.writeValue(1)
            #expect(await iterator.next() == .init(revision: 1))

            #expect(throws: Rollback.self) {
                try fixture.database.write { db in
                    try db.execute(sql: "INSERT INTO values_table(value) VALUES (2)")
                    throw Rollback()
                }
            }

            try fixture.writeValue(3)
            #expect(await iterator.next() == .init(revision: 2))
            #expect(try await fixture.database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM values_table") == 2
            })
            await changes.close()
            #expect(await iterator.next() == .init(revision: 2, isClosed: true))
            #expect(await iterator.next() == nil)
        } catch {
            try? fixture.database.close()
            try? FileManager.default.removeItem(at: fixture.url)
            throw error
        }
        try fixture.database.close()
        try? FileManager.default.removeItem(at: fixture.url)
    }

    @Test func rolledBackSavepointDoesNotPublishARevisionWhenOuterTransactionCommits() async throws {
        let fixture = try BusinessChangesFixture.make()
        do {
            let changes = SQLiteBusinessChanges(database: fixture.database)
            let stream = try await changes.observe()
            var iterator = stream.makeAsyncIterator()
            #expect(await iterator.next() == .init(revision: 0))

            try await fixture.database.write { db in
                try db.inSavepoint {
                    try db.execute(sql: "INSERT INTO values_table(value) VALUES (2)")
                    return .rollback
                }
                return Database.TransactionCompletion.commit
            }
            try fixture.writeValue(3)
            #expect(await iterator.next() == .init(revision: 1))
            #expect(try await fixture.database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM values_table") == 1
            })
            await changes.close()
        } catch {
            try? fixture.database.close()
            try? FileManager.default.removeItem(at: fixture.url)
            throw error
        }
        try fixture.database.close()
        try? FileManager.default.removeItem(at: fixture.url)
    }

    @Test func lateSubscribersReceiveLatestRevisionAndSlowSubscribersCoalesce() async throws {
        let fixture = try BusinessChangesFixture.make()
        do {
            let changes = SQLiteBusinessChanges(database: fixture.database)
            let first = try await changes.observe()
            var firstIterator = first.makeAsyncIterator()
            #expect(await firstIterator.next() == .init(revision: 0))

            try fixture.writeValue(1)
            try fixture.writeValue(2)
            try fixture.writeValue(3)
            #expect(await firstIterator.next() == .init(revision: 3))

            let late = try await changes.observe()
            var lateIterator = late.makeAsyncIterator()
            #expect(await lateIterator.next() == .init(revision: 3))
            await changes.close()
            #expect(await lateIterator.next() == .init(revision: 3, isClosed: true))
            #expect(await lateIterator.next() == nil)
        } catch {
            try? fixture.database.close()
            try? FileManager.default.removeItem(at: fixture.url)
            throw error
        }
        try fixture.database.close()
        try? FileManager.default.removeItem(at: fixture.url)
    }

    @Test func independentLibrariesOnlyPublishTheirOwnCommittedWrites() async throws {
        let first = try BusinessChangesFixture.make()
        let second = try BusinessChangesFixture.make()
        do {
            let firstChanges = SQLiteBusinessChanges(database: first.database)
            let secondChanges = SQLiteBusinessChanges(database: second.database)
            let firstStream = try await firstChanges.observe()
            let secondStream = try await secondChanges.observe()
            var firstIterator = firstStream.makeAsyncIterator()
            var secondIterator = secondStream.makeAsyncIterator()
            #expect(await firstIterator.next() == .init(revision: 0))
            #expect(await secondIterator.next() == .init(revision: 0))

            try first.writeValue(1)
            #expect(await firstIterator.next() == .init(revision: 1))
            try second.writeValue(1)
            #expect(await secondIterator.next() == .init(revision: 1))
            await firstChanges.close()
            await secondChanges.close()
        } catch {
            try? first.database.close()
            try? second.database.close()
            try? FileManager.default.removeItem(at: first.url)
            try? FileManager.default.removeItem(at: second.url)
            throw error
        }
        try first.database.close()
        try second.database.close()
        try? FileManager.default.removeItem(at: first.url)
        try? FileManager.default.removeItem(at: second.url)
    }

    @Test func cancelledSubscriberIsRemovedAndClosedSourceFinishesNewSubscribers() async throws {
        let fixture = try BusinessChangesFixture.make()
        do {
            let changes = SQLiteBusinessChanges(database: fixture.database)
            let stream = try await changes.observe()
            let cancellation = Task {
                var iterator = stream.makeAsyncIterator()
                _ = await iterator.next()
                return await iterator.next() == nil
            }
            cancellation.cancel()
            #expect(await cancellation.value)
            try fixture.writeValue(1)

            let late = try await changes.observe()
            var iterator = late.makeAsyncIterator()
            #expect(await iterator.next() == .init(revision: 1))
            await changes.close()
            #expect(await iterator.next() == .init(revision: 1, isClosed: true))
            #expect(await iterator.next() == nil)
        } catch {
            try? fixture.database.close()
            try? FileManager.default.removeItem(at: fixture.url)
            throw error
        }
        try fixture.database.close()
        try? FileManager.default.removeItem(at: fixture.url)
    }

    @Test func closeRacesAWriteWithoutPublishingAfterTheObserverIsDrained() async throws {
        let fixture = try BusinessChangesFixture.make()
        do {
            let changes = SQLiteBusinessChanges(database: fixture.database)
            let closing = Task { await changes.close() }
            try fixture.writeValue(1)
            await closing.value

            let stream = try await changes.observe()
            var iterator = stream.makeAsyncIterator()
            let closed = try #require(await iterator.next())
            #expect(closed.isClosed)
            #expect(closed.revision <= 1)
            #expect(await iterator.next() == nil)
        } catch {
            try? fixture.database.close()
            try? FileManager.default.removeItem(at: fixture.url)
            throw error
        }
        try fixture.database.close()
        try? FileManager.default.removeItem(at: fixture.url)
    }

    @Test func concurrentCloseCallersWaitForBlockedDatabaseObserverRemoval() async throws {
        let fixture = try BusinessChangesFixture.make()
        do {
            let changes = SQLiteBusinessChanges(database: fixture.database)
            let stream = try await changes.observe()
            var iterator = stream.makeAsyncIterator()
            #expect(await iterator.next() == .init(revision: 0))

            let gate = BlockingTransaction()
            let writer = Task {
                try fixture.database.write { db in try gate.write(in: db) }
            }
            await gate.waitUntilEntered()

            let firstFinished = CloseFlag()
            let secondFinished = CloseFlag()
            let first = Task {
                await changes.close()
                await firstFinished.mark()
            }
            let second = Task {
                await changes.close()
                await secondFinished.mark()
            }
            second.cancel()
            for _ in 0..<100 { await Task.yield() }
            #expect(await firstFinished.value == false)
            #expect(await secondFinished.value == false)

            gate.release()
            try await writer.value
            await first.value
            _ = await second.value
            #expect(await firstFinished.value)
            #expect(await secondFinished.value)
        } catch {
            try? fixture.database.close()
            try? FileManager.default.removeItem(at: fixture.url)
            throw error
        }
        try fixture.database.close()
        try? FileManager.default.removeItem(at: fixture.url)
    }
}

private struct Rollback: Error {}

private actor CloseFlag {
    private(set) var value = false
    func mark() { value = true }
}

private final class BlockingTransaction: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    private let releaseSignal = DispatchSemaphore(value: 0)

    func write(in db: Database) throws {
        try db.execute(sql: "INSERT INTO values_table(value) VALUES (99)")
        entered.signal()
        releaseSignal.wait()
    }

    func release() { releaseSignal.signal() }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                self.entered.wait()
                continuation.resume()
            }
        }
    }
}

private final class BusinessChangesFixture: @unchecked Sendable {
    let url: URL
    let database: DatabaseQueue

    private init(url: URL, database: DatabaseQueue) {
        self.url = url
        self.database = database
    }

    static func make() throws -> BusinessChangesFixture {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("business-changes-\(UUID()).sqlite")
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let database = try DatabaseQueue(path: url.path, configuration: configuration)
        try database.write { db in
            try db.execute(sql: "CREATE TABLE values_table(value INTEGER NOT NULL)")
        }
        return .init(url: url, database: database)
    }

    func writeValue(_ value: Int) throws {
        try database.write { db in
            try db.execute(sql: "INSERT INTO values_table(value) VALUES (?)", arguments: [value])
        }
    }
}
