import Foundation
import Testing
import MiraCore

@Suite("Keychain credentials")
struct KeychainTests {
    @Test func readUsesServiceAndVersionedAccount() throws {
        let fake = LockedFakeKeychain()
        fake.put(Data("secret".utf8), service: KeychainCredentials.service, account: "reference:7")
        let credentials = KeychainCredentials(access: fake)

        #expect(try credentials.read(reference: "reference", version: 7) == "secret")
        #expect(fake.copyCalls == [.init(service: KeychainCredentials.service, account: "reference:7")])
    }

    @Test func successfulSaveUsesImmutableVersionedItemAndCanBeReadBack() throws {
        let fake = LockedFakeKeychain()
        let credentials = KeychainCredentials(access: fake)

        try credentials.save("secret", reference: "reference", version: 8)

        #expect(try credentials.read(reference: "reference", version: 8) == "secret")
        #expect(fake.addCalls == [.init(service: KeychainCredentials.service, account: "reference:8", data: Data("secret".utf8), accessibility: .whenUnlockedThisDeviceOnly, synchronizable: false)])
    }

    @Test func lockedDeniedMissingAndMalformedReadsUseSafeCredentialError() throws {
        let fake = LockedFakeKeychain()
        let credentials = KeychainCredentials(access: fake)

        fake.copyResult = .init(status: .failure(-25308), data: nil)
        expectCredentialMissing { try credentials.read(reference: "ref", version: 1) }
        fake.copyResult = .init(status: .failure(-25291), data: nil)
        expectCredentialMissing { try credentials.read(reference: "ref", version: 1) }
        fake.copyResult = .init(status: .itemNotFound, data: nil)
        expectCredentialMissing { try credentials.read(reference: "ref", version: 1) }
        fake.copyResult = .init(status: .success, data: Data([0xff]))
        expectCredentialMissing { try credentials.read(reference: "ref", version: 1) }
        fake.copyResult = .init(status: .success, data: Data())
        expectCredentialMissing { try credentials.read(reference: "ref", version: 1) }
    }

    @Test func duplicateOrFailedAddLeavesExistingCredentialUntouched() throws {
        let fake = LockedFakeKeychain()
        fake.put(Data("old".utf8), service: KeychainCredentials.service, account: "ref:2")
        let credentials = KeychainCredentials(access: fake)

        fake.addResult = .duplicate
        #expect(throws: MiraError.self) { try credentials.save("new", reference: "ref", version: 2) }
        #expect(fake.data(service: KeychainCredentials.service, account: "ref:2") == Data("old".utf8))

        fake.addResult = .failure(-25299)
        #expect(throws: MiraError.self) { try credentials.save("newer", reference: "ref", version: 2) }
        #expect(fake.data(service: KeychainCredentials.service, account: "ref:2") == Data("old".utf8))
        #expect(fake.addCalls.last?.accessibility == .whenUnlockedThisDeviceOnly)
        #expect(fake.addCalls.last?.synchronizable == false)
    }

    @Test func deletingMissingCredentialIsIdempotent() throws {
        let fake = LockedFakeKeychain()
        fake.deleteResult = .itemNotFound
        let credentials = KeychainCredentials(access: fake)

        try credentials.delete(reference: "missing", version: 4)

        #expect(fake.deleteCalls == [.init(service: KeychainCredentials.service, account: "missing:4")])
    }

    @Test func cleanupRetainsSharedCredentialReferences() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let retained = connection(reference: "shared", version: 1)
        let removed = connection(reference: "shared", version: 1)
        let cleanup = CredentialCleanup(directory: directory)
        let fake = LockedFakeKeychain()
        let credentials = KeychainCredentials(access: fake)

        try cleanup.enqueue([retained, removed])
        #expect(try cleanup.reconcile(retaining: [retained], credentials: credentials) == nil)
        #expect(fake.deleteCalls.isEmpty)
        #expect(try ledgerItems(in: directory).count == 0)
    }

    @Test func failedCleanupDeletionIsQueuedAndRetryable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = connection(reference: "old", version: 1)
        let cleanup = CredentialCleanup(directory: directory)
        let fake = LockedFakeKeychain()
        fake.deleteResult = .failure(-25299)
        let credentials = KeychainCredentials(access: fake)

        try cleanup.enqueue([old])
        #expect(try cleanup.reconcile(retaining: [], credentials: credentials) != nil)
        #expect(try ledgerItems(in: directory).count == 1)

        fake.deleteResult = .success
        #expect(try cleanup.reconcile(retaining: [], credentials: credentials) == nil)
        #expect(try ledgerItems(in: directory).isEmpty)
    }

    @Test func corruptCleanupLedgerRejectsWithoutDeletingAnything() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("credential-cleanup.json"))
        let fake = LockedFakeKeychain()
        let credentials = KeychainCredentials(access: fake)

        #expect(throws: MiraError.self) {
            try CredentialCleanup(directory: directory).reconcile(retaining: [], credentials: credentials)
        }
        #expect(fake.deleteCalls.isEmpty)
    }

    private func connection(reference: String, version: Int) -> ProviderConnection {
        ProviderConnection(name: "Test", providerKind: .openAICompatible, baseURL: "https://example.invalid", credentialReference: reference, credentialVersion: version)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-keychain-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func ledgerItems(in directory: URL) throws -> [LedgerItem] {
        let data = try Data(contentsOf: directory.appendingPathComponent("credential-cleanup.json"))
        return try JSONDecoder().decode(Ledger.self, from: data).items
    }

    private func expectCredentialMissing(_ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected a credentialMissing error.")
        } catch let error as MiraError {
            #expect(error.code == .credentialMissing)
            #expect(error.message == "Unable to read the API key. Save your credentials again in Settings.")
        } catch {
            Issue.record("Expected MiraError.credentialMissing, received \(error).")
        }
    }
}

private struct Ledger: Decodable {
    let items: [LedgerItem]
}

private struct LedgerItem: Decodable, Equatable {
    let reference: String
    let version: Int
}

private final class LockedFakeKeychain: KeychainAccess, @unchecked Sendable {
    struct Call: Equatable, Sendable {
        let service: String
        let account: String
    }
    struct AddCall: Equatable, Sendable {
        let service: String
        let account: String
        let data: Data
        let accessibility: KeychainAccessibility
        let synchronizable: Bool
    }

    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var _copyCalls: [Call] = []
    private var _addCalls: [AddCall] = []
    private var _deleteCalls: [Call] = []
    private var _copyResult: KeychainReadResult?
    private var _addResult: KeychainStatus = .success
    private var _deleteResult: KeychainStatus?

    var copyCalls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _copyCalls
    }
    var addCalls: [AddCall] {
        lock.lock(); defer { lock.unlock() }
        return _addCalls
    }
    var deleteCalls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _deleteCalls
    }
    var copyResult: KeychainReadResult? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _copyResult
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _copyResult = newValue
        }
    }
    var addResult: KeychainStatus {
        get {
            lock.lock(); defer { lock.unlock() }
            return _addResult
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _addResult = newValue
        }
    }
    var deleteResult: KeychainStatus? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _deleteResult
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _deleteResult = newValue
        }
    }

    func put(_ data: Data, service: String, account: String) {
        lock.lock(); defer { lock.unlock() }
        items[key(service, account)] = data
    }

    func data(service: String, account: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[key(service, account)]
    }

    func copy(service: String, account: String) -> KeychainReadResult {
        lock.lock(); defer { lock.unlock() }
        _copyCalls.append(.init(service: service, account: account))
        if let result = _copyResult { return result }
        guard let data = items[key(service, account)] else { return .init(status: .itemNotFound, data: nil) }
        return .init(status: .success, data: data)
    }

    func add(service: String, account: String, data: Data, accessibility: KeychainAccessibility, synchronizable: Bool) -> KeychainStatus {
        lock.lock(); defer { lock.unlock() }
        _addCalls.append(.init(service: service, account: account, data: data, accessibility: accessibility, synchronizable: synchronizable))
        guard _addResult == .success else { return _addResult }
        let itemKey = key(service, account)
        guard items[itemKey] == nil else { return .duplicate }
        items[itemKey] = data
        return .success
    }

    func delete(service: String, account: String) -> KeychainStatus {
        lock.lock(); defer { lock.unlock() }
        _deleteCalls.append(.init(service: service, account: account))
        if let result = _deleteResult { return result }
        let removed = items.removeValue(forKey: key(service, account))
        return removed == nil ? .itemNotFound : .success
    }

    private func key(_ service: String, _ account: String) -> String { "\(service)\u{1f}\(account)" }
}
