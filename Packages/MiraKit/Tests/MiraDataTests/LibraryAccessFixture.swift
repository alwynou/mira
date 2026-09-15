import Foundation
import GRDB
import MiraCore
import MiraData

/// Synthetic library authority shared by tests of the actual runtime components.
actor LibraryAccessFixture {
    let access: AgentLibraryAccess
    let authority: SQLiteLibraryAuthority
    private let database: DatabaseQueue?
    private let directory: URL?
    private let scope: RuntimeScope
    private var leases: [AgentLibraryAccessLease] = []

    private init(access: AgentLibraryAccess, authority: SQLiteLibraryAuthority,
                 database: DatabaseQueue?, directory: URL?, scope: RuntimeScope) {
        self.access = access; self.authority = authority; self.database = database
        self.directory = directory; self.scope = scope
    }

    static func make() async throws -> LibraryAccessFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-access-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var database: DatabaseQueue?
        var authority: SQLiteLibraryAuthority?
        do {
            var configuration = Configuration()
            configuration.foreignKeysEnabled = true
            configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
            let opened = try DatabaseQueue(path: directory.appendingPathComponent("business.sqlite").path, configuration: configuration)
            database = opened
            let initialized = try SQLiteLibraryAuthority(database: opened)
            authority = initialized
            let access = try await AgentLibraryAccess.open(store: initialized)
            return .init(access: access, authority: initialized, database: opened, directory: directory,
                         scope: RuntimeScope(kind: .application))
        } catch {
            await authority?.close(); try? database?.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Uses the same authority as a fixture's business adapter without taking ownership of its database.
    static func make(authority: SQLiteLibraryAuthority) async throws -> LibraryAccessFixture {
        let access = try await AgentLibraryAccess.open(store: authority)
        return .init(access: access, authority: authority, database: nil, directory: nil,
                     scope: RuntimeScope(kind: .application))
    }

    func acquire() async throws -> AgentLibraryAccessLease {
        let lease = try await access.acquire(in: scope)
        leases.append(lease)
        return lease
    }

    func close() async {
        let closing = Task { await access.close() }
        for lease in leases { await lease.release() }
        leases.removeAll()
        await closing.value
        await scope.dispose()
        if let database { await authority.close(); try? database.close() }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
}
