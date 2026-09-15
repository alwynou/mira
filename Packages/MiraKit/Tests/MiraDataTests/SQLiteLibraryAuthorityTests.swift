import Foundation
import CryptoKit
import Testing
import GRDB
@testable import MiraCore
@testable import MiraData

@Suite("SQLite library authority")
struct SQLiteLibraryAuthorityTests {
    @Test func identityAndPendingAuthorizationSurviveActualDatabaseReopen() async throws {
        try await withAuthorityFixture { fixture in
            let first = try fixture.authority()
            let initial = try await first.authorization()
            #expect(initial.libraryID == first.libraryID)
            #expect(initial.epoch == 0)
            try await fixture.reopen()
            let reopenedReady = try fixture.authority()
            #expect(try await reopenedReady.authorization() == initial)
            let pending = try await reopenedReady.begin(maintenanceRequest(), expected: initial)
            #expect(pending.previousAuthorization == initial)
            #expect(pending.authorization.epoch == 1)
            #expect(pending.completedAt == nil)
            try await fixture.reopen()
            let reopenedPending = try fixture.authority()
            #expect(try await reopenedPending.state() == .init(authorization: pending.authorization, pending: pending))
            #expect(try await reopenedPending.operation(id: pending.request.id) == pending)
            #expect(try await reopenedPending.operation(id: UUID()) == nil)
            try await expectAuthorityFailure(.unauthorized, "Library maintenance prevents new authorization.") {
                _ = try await reopenedPending.authorization()
            }
        }
    }

    @Test func beginUsesExactCommandIdentityAndExpectedAuthority() async throws {
        try await withAuthorityFixture { fixture in
            let authority = try fixture.authority()
            let initial = try await authority.authorization()
            let request = maintenanceRequest()
            let pending = try await authority.begin(request, expected: initial)
            #expect(try await authority.begin(request, expected: initial) == pending)
            for (command, expected) in [
                (maintenanceRequest(id: request.id), initial),
                (request, pending.authorization),
                (maintenanceRequest(), initial),
                (maintenanceRequest(), pending.authorization),
                (request, .init(libraryID: UUID(), epoch: initial.epoch))
            ] {
                try await expectAuthorityConflict { _ = try await authority.begin(command, expected: expected) }
            }
            #expect(try await authority.state() == .init(authorization: pending.authorization, pending: pending))
        }
    }

    @Test func completionIsIdempotentWithoutReopeningOldAuthorityOrClearingNewWork() async throws {
        try await withAuthorityFixture { fixture in
            let authority = try fixture.authority()
            let initial = try await authority.authorization()
            let first = try await authority.begin(maintenanceRequest(), expected: initial)
            let date = Date(timeIntervalSince1970: 1_700_000_001)
            let completed = try await authority.complete(first, at: date)
            #expect(completed.completedAt == date)
            #expect(try await authority.authorization() == first.authorization)
            #expect(try await authority.complete(first, at: date.addingTimeInterval(5)) == completed)
            #expect(try await authority.begin(first.request, expected: initial) == completed)
            try await expectAuthorityConflict { _ = try await authority.begin(maintenanceRequest(), expected: initial) }
            let second = try await authority.begin(maintenanceRequest(), expected: completed.authorization)
            #expect(second.authorization.epoch == 2)
            #expect(try await authority.complete(completed, at: date.addingTimeInterval(20)) == completed)
            #expect(try await authority.begin(first.request, expected: initial) == completed)
            #expect(try await authority.state().pending == second)
            let forged = AgentLibraryMaintenanceOperation(request: maintenanceRequest(id: second.request.id),
                previousAuthorization: second.previousAuthorization, authorization: second.authorization, completedAt: nil)
            try await expectAuthorityConflict { _ = try await authority.complete(forged, at: date) }
            #expect(try await authority.state().pending == second)
            let final = try await authority.complete(second, at: date.addingTimeInterval(30))
            try await fixture.reopen()
            let reopened = try fixture.authority()
            #expect(try await reopened.state() == .init(authorization: final.authorization, pending: nil))
            #expect(try await reopened.operation(id: first.request.id) == completed)
            #expect(try await reopened.operation(id: second.request.id) == final)
        }
    }

    @Test(arguments: [SQLiteLibraryAuthorityFaultPoint.afterBeginCommit, .afterCompletionCommit])
    func lostAcknowledgementPreservesCommittedFactAndDoesNotRepeatMutation(point: SQLiteLibraryAuthorityFaultPoint) async throws {
        try await withAuthorityFixture { fixture in
            let hooks = AuthorityHookCounts()
            let authority = try fixture.authority { seen in
                hooks.record(seen)
                if seen == point { throw AuthorityPrivateFailure() }
            }
            let initial = try await authority.authorization()
            let request = maintenanceRequest()
            let date = Date(timeIntervalSince1970: 1_700_000_002)
            let stored: AgentLibraryMaintenanceOperation
            switch point {
            case .afterBeginCommit:
                try await expectAuthorityFailure(.storage, "The library authority operation failed.") {
                    _ = try await authority.begin(request, expected: initial)
                }
                stored = try #require(try await authority.operation(id: request.id))
                #expect(try await authority.begin(request, expected: initial) == stored)
                #expect(stored.completedAt == nil)
                #expect(hooks.counts == [1, 0])
            case .afterCompletionCommit:
                let pending = try await authority.begin(request, expected: initial)
                try await expectAuthorityFailure(.storage, "The library authority operation failed.") {
                    _ = try await authority.complete(pending, at: date)
                }
                stored = try #require(try await authority.operation(id: request.id))
                #expect(stored.completedAt == date)
                #expect(try await authority.complete(pending, at: date.addingTimeInterval(10)) == stored)
                #expect(try await authority.begin(request, expected: initial) == stored)
                #expect(hooks.counts == [1, 1])
            }
            #expect(stored.authorization.epoch == 1)
            try await fixture.reopen()
            let reopened = try fixture.authority()
            #expect(try await reopened.operation(id: request.id) == stored)
            #expect(try await reopened.state() == .init(authorization: stored.authorization,
                                                      pending: stored.completedAt == nil ? stored : nil))
            #expect(try await reopened.begin(request, expected: initial) == stored)
        }
    }

    @Test func concurrentDistinctCommandsOnSharedDatabaseHaveOneWinner() async throws {
        try await withAuthorityFixture { fixture in
            let first = try fixture.authority(), second = try fixture.authority()
            let initial = try await first.authorization()
            let a = maintenanceRequest(), b = maintenanceRequest()
            async let left = captureAuthorityBegin(first, request: a, expected: initial)
            async let right = captureAuthorityBegin(second, request: b, expected: initial)
            let outcomes = await [left, right]
            let successes = outcomes.compactMap { try? $0.get() }
            #expect(successes.count == 1)
            let winner = try #require(successes.first)
            for outcome in outcomes {
                if case .failure(let error) = outcome {
                    #expect(error == MiraError(.conflict, "The library maintenance operation conflicts with current authority."))
                }
            }
            #expect(try await first.state() == .init(authorization: winner.authorization, pending: winner))
            #expect(try await second.state() == first.state())
            #expect(try await first.operation(id: winner.request.id == a.id ? b.id : a.id) == nil)
        }
    }

    @Test(arguments: AuthorityCorruption.allCases)
    func corruptCurrentAuthorityFailsClosedWithFixedDiagnostic(corruption: AuthorityCorruption) async throws {
        try await withAuthorityFixture { fixture in
            let authority = try fixture.authority()
            let initial = try await authority.authorization()
            let operation = try await authority.begin(maintenanceRequest(), expected: initial)
            let completed = try await authority.complete(operation, at: Date(timeIntervalSince1970: 1_700_000_001))
            if corruption == .rollbackPointer {
                let second = try await authority.begin(maintenanceRequest(), expected: completed.authorization)
                _ = try await authority.complete(second, at: Date(timeIntervalSince1970: 1_700_000_002))
            }
            await authority.close()
            try await fixture.database.write { db in
                switch corruption {
                case .libraryID:
                    try db.execute(sql: "UPDATE agent_library_metadata SET library_id = 'private-authority-fixture'")
                case .epoch:
                    try db.execute(sql: "UPDATE agent_library_metadata SET epoch = '01'")
                case .digest:
                    try db.execute(sql: "UPDATE agent_library_maintenance SET digest = 'private-authority-fixture'")
                case .invalidJSON:
                    let bytes = Data("private-authority-fixture".utf8)
                    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    try db.execute(sql: "UPDATE agent_library_maintenance SET operation_json = ?, digest = ?", arguments: [bytes, digest])
                case .oversizedRecord:
                    try db.execute(sql: "PRAGMA ignore_check_constraints=ON")
                    try db.execute(sql: "UPDATE agent_library_maintenance SET operation_json = zeroblob(2097153)")
                case .missingIndex:
                    try db.execute(sql: "DROP INDEX agent_library_maintenance_pending")
                case .rollbackPointer:
                    try db.execute(sql: "UPDATE agent_library_metadata SET epoch = ?, current_operation_id = ?",
                                   arguments: [String(completed.authorization.epoch), completed.request.id.uuidString])
                }
            }
            do {
                _ = try fixture.authority()
                Issue.record("Corrupt authority was opened")
            } catch let error as MiraError {
                #expect(error == MiraError(.storage, "The library authority metadata is invalid."))
                #expect(!error.message.contains("private-authority-fixture"))
            }
        }
    }

    @Test func partialOwnedSchemaIsRejectedWithoutCreatingMissingTables() async throws {
        try await withAuthorityFixture { fixture in
            try await fixture.database.write { db in
                try db.execute(sql: "CREATE TABLE agent_library_metadata(value TEXT)")
            }
            do {
                _ = try fixture.authority()
                Issue.record("Partial authority schema was accepted")
            } catch let error as MiraError {
                #expect(error == MiraError(.storage, "The library authority metadata is invalid."))
            }
            #expect(try await fixture.database.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='agent_library_maintenance'")
            } == 0)
        }
    }

    @Test(arguments: ["PRAGMA synchronous=NORMAL", "PRAGMA foreign_keys=OFF"])
    func insufficientDurabilityRejectsInitializationAndLaterMutation(setting: String) async throws {
        try await withAuthorityFixture { fixture in
            let authority = try fixture.authority()
            let initial = try await authority.authorization()
            try await fixture.database.writeWithoutTransaction { try $0.execute(sql: setting) }
            do {
                _ = try fixture.authority()
                Issue.record("Insufficient durability was accepted")
            } catch let error as MiraError {
                #expect(error == MiraError(.configuration, "The library authority durability settings are insufficient."))
            }
            try await expectAuthorityFailure(.configuration, "The library authority durability settings are insufficient.") {
                _ = try await authority.begin(maintenanceRequest(), expected: initial)
            }
            #expect(try await authority.state() == .init(authorization: initial, pending: nil))
        }
    }

    @Test func closeDrainsAcceptedCommitAcknowledgementAndKeepsSharedDatabaseOpen() async throws {
        try await withAuthorityFixture { fixture in
            let gate = AuthorityAcknowledgementGate()
            let authority = try fixture.authority { _ in gate.block() }
            let initial = try await authority.authorization()
            let completed = AuthorityCompletionFlag()
            let request = maintenanceRequest()
            let begin = Task { try await authority.begin(request, expected: initial) }
            var closing: Task<Void, Never>?
            do {
                try await waitForAuthorityObservation { gate.entered }
                begin.cancel()
                closing = Task { await authority.close(); completed.mark() }
                try await waitForAuthorityObservation { authority.isClosing }
                #expect(!completed.value)
                try await expectAuthorityFailure(.storage, "The library authority is closed.") { _ = try await authority.state() }
                // SQL committed before the deliberately withheld acknowledgement.
                #expect(try await fixture.database.read { try String.fetchOne($0, sql: "SELECT epoch FROM agent_library_metadata") } == "1")
                gate.release()
                let operation = try await begin.value
                await closing?.value
                #expect(completed.value)
                #expect(operation.request == request)
                try await fixture.database.write { try $0.execute(sql: "CREATE TABLE authority_sentinel(value INTEGER)") }
                let independent = try fixture.authority()
                #expect(try await independent.state().pending == operation)
            } catch {
                gate.release()
                _ = try? await begin.value
                await closing?.value
                throw error
            }
        }
    }
}

private func maintenanceRequest(id: UUID = UUID()) -> AgentLibraryMaintenanceRequest {
    .init(id: id, namespace: "tests.invalidate", revision: 1,
          scope: .sources([.domain(namespace: "memory", id: UUID(), revision: 1)]),
          requestedAt: Date(timeIntervalSince1970: 1_700_000_000))
}

private func expectAuthorityFailure(_ code: MiraError.Code, _ message: String,
                                    operation: () async throws -> Void) async throws {
    do { try await operation(); Issue.record("Expected library authority failure was not returned") }
    catch let error as MiraError { #expect(error == MiraError(code, message)) }
}

private func expectAuthorityConflict(operation: () async throws -> Void) async throws {
    try await expectAuthorityFailure(.conflict, "The library maintenance operation conflicts with current authority.", operation: operation)
}

private func captureAuthorityBegin(_ authority: SQLiteLibraryAuthority, request: AgentLibraryMaintenanceRequest,
                                   expected: AgentLibraryAuthorization) async -> Result<AgentLibraryMaintenanceOperation, MiraError> {
    do { return .success(try await authority.begin(request, expected: expected)) }
    catch let error as MiraError { return .failure(error) }
    catch { Issue.record(error); return .failure(.init(.storage, "Unexpected synthetic failure.")) }
}

enum AuthorityCorruption: CaseIterable, Sendable {
    case libraryID, epoch, digest, invalidJSON, oversizedRecord, missingIndex, rollbackPointer
}

private struct AuthorityPrivateFailure: Error, CustomStringConvertible {
    var description: String { "private-authority-fixture" }
}

private final class AuthorityHookCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var begins = 0, completions = 0
    var counts: [Int] { lock.withLock { [begins, completions] } }
    func record(_ point: SQLiteLibraryAuthorityFaultPoint) {
        lock.withLock { switch point { case .afterBeginCommit: begins += 1; case .afterCompletionCommit: completions += 1 } }
    }
}

private final class AuthorityAcknowledgementGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false, released = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return started }
    func block() {
        condition.lock(); started = true
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

private final class AuthorityCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    var value: Bool { lock.withLock { completed } }
    func mark() { lock.withLock { completed = true } }
}

private func waitForAuthorityObservation(_ predicate: () -> Bool) async throws {
    let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !predicate() {
        guard clock.now < deadline else { throw MiraError(.timeout, "Synthetic authority observation timed out.") }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private final class AuthorityFixture {
    let directory: URL
    private(set) var database: DatabaseQueue
    private var authorities: [SQLiteLibraryAuthority] = []

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-authority-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { database = try Self.open(directory) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    private static func open(_ directory: URL) throws -> DatabaseQueue {
        var configuration = Configuration(); configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
        return try DatabaseQueue(path: directory.appendingPathComponent("business.sqlite").path, configuration: configuration)
    }
    func authority(afterCommit: (@Sendable (SQLiteLibraryAuthorityFaultPoint) throws -> Void)? = nil) throws -> SQLiteLibraryAuthority {
        let authority = try SQLiteLibraryAuthority(database: database, validators: [.init(identity: .init(namespace: "tests.invalidate", revision: 1), validate: { request, _ in try request.validate() })], afterCommit: afterCommit)
        authorities.append(authority)
        return authority
    }
    func reopen() async throws {
        for authority in authorities { await authority.close() }
        authorities.removeAll()
        try database.close()
        database = try Self.open(directory)
    }
    func close() async {
        for authority in authorities { await authority.close() }
        try? database.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func withAuthorityFixture(_ body: (AuthorityFixture) async throws -> Void) async throws {
    let fixture = try AuthorityFixture()
    do { try await body(fixture); await fixture.close() }
    catch { await fixture.close(); throw error }
}
