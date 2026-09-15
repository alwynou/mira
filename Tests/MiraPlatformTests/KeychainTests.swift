import Foundation
import MiraCore
import Testing

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
        #expect(
            fake.addCalls == [
                .init(
                    service: KeychainCredentials.service, account: "reference:8", data: Data("secret".utf8),
                    accessibility: .whenUnlockedThisDeviceOnly, synchronizable: false)
            ])
    }

    @Test func invalidReferenceNeverReachesKeychain() throws {
        let fake = LockedFakeKeychain()
        let credentials = KeychainCredentials(access: fake)
        let long = String(repeating: "x", count: 513)

        #expect(throws: MiraError.self) { try credentials.read(reference: "", version: 1) }
        #expect(throws: MiraError.self) { try credentials.save("secret", reference: long, version: 1) }
        #expect(throws: MiraError.self) { try credentials.delete(reference: "ok", version: 0) }
        #expect(fake.copyCalls.isEmpty)
        #expect(fake.addCalls.isEmpty)
        #expect(fake.deleteCalls.isEmpty)
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
        let cleanup = CredentialCleanup(directory: directory, libraryID: UUID())
        let retained = cleanup.makeReference(version: 1)
        let removed = cleanup.makeReference(version: 2)
        let fake = LockedFakeKeychain()

        try cleanup.enqueue([retained, removed, retained])
        #expect(try cleanup.reconcile(retaining: [retained], credentials: fake) == false)
        #expect(fake.deleteCalls.map(\.account) == ["\(removed.reference):2"])
        #expect(try ledgerItems(in: directory).isEmpty)
        #expect(
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent("credential-cleanup.json").path))
        #expect(try cleanup.reconcile(retaining: [retained], credentials: fake) == false)
        #expect(fake.deleteCalls.count == 1)
    }

    @Test func failedCleanupDeletionIsQueuedAndRetryable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cleanup = CredentialCleanup(directory: directory, libraryID: UUID())
        let old = cleanup.makeReference(version: 1)
        let fake = LockedFakeKeychain()
        fake.deleteResult = .failure(-25299)

        try cleanup.enqueue([old])
        #expect(try cleanup.reconcile(retaining: [], credentials: fake) == true)
        #expect(try ledgerItems(in: directory).count == 1)

        fake.deleteResult = .success
        #expect(try cleanup.reconcile(retaining: [], credentials: fake) == false)
        #expect(try ledgerItems(in: directory).isEmpty)
        #expect(
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent("credential-cleanup.json").path))
    }

    @Test func foreignDirectoryAndReferencesAreNeverDeleted() throws {
        let first = try temporaryDirectory()
        let second = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let owner = CredentialCleanup(directory: first, libraryID: UUID())
        let foreign = CredentialCleanup(directory: second, libraryID: UUID()).makeReference(version: 1)
        let fake = LockedFakeKeychain()

        try owner.enqueue([foreign])
        #expect(!FileManager.default.fileExists(atPath: first.appendingPathComponent("credential-cleanup.json").path))
        #expect(try owner.reconcile(retaining: [], credentials: fake) == false)
        #expect(fake.deleteCalls.isEmpty)
    }

    @Test func corruptOrCrossDirectoryLedgerRejectsBeforeDeleting() throws {
        let directory = try temporaryDirectory()
        let other = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: other)
        }
        let libraryID = UUID()
        let owner = CredentialCleanup(directory: directory, libraryID: libraryID)
        let fake = LockedFakeKeychain()
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("credential-cleanup.json"))
        #expect(throws: MiraError.self) { try owner.reconcile(retaining: [], credentials: fake) }
        #expect(fake.deleteCalls.isEmpty)

        try FileManager.default.removeItem(at: directory.appendingPathComponent("credential-cleanup.json"))
        let crossDirectory = CredentialCleanup(directory: other, libraryID: libraryID)
        let crossReference = crossDirectory.makeReference(version: 1)
        try crossDirectory.enqueue([crossReference])
        let data = try Data(contentsOf: other.appendingPathComponent("credential-cleanup.json"))
        try data.write(to: directory.appendingPathComponent("credential-cleanup.json"), options: .atomic)
        #expect(throws: MiraError.self) { try owner.reconcile(retaining: [], credentials: fake) }
        #expect(fake.deleteCalls.isEmpty)
    }

    @Test func malformedHardlinkedAndOversizedLedgersRejectBeforeDeletion() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cleanup = CredentialCleanup(directory: directory, libraryID: UUID())
        let fake = LockedFakeKeychain()
        let valid = cleanup.makeReference(version: 1)
        try cleanup.enqueue([valid])
        let ledgerURL = directory.appendingPathComponent("credential-cleanup.json")
        let original = try Data(contentsOf: ledgerURL)
        let malformed = String(data: original, encoding: .utf8)!.replacingOccurrences(
            of: valid.reference, with: "\(valid.reference.dropLast(36))not-a-uuid")
        try Data(malformed.utf8).write(to: ledgerURL, options: .atomic)
        #expect(throws: MiraError.self) { try cleanup.reconcile(retaining: [], credentials: fake) }
        #expect(fake.deleteCalls.isEmpty)

        try Data(original).write(to: ledgerURL, options: .atomic)
        let hardlink = directory.appendingPathComponent("credential-cleanup.hardlink")
        try FileManager.default.linkItem(at: ledgerURL, to: hardlink)
        #expect(throws: MiraError.self) { try cleanup.reconcile(retaining: [], credentials: fake) }
        #expect(fake.deleteCalls.isEmpty)
        try FileManager.default.removeItem(at: hardlink)

        try Data(repeating: 0x31, count: 1_048_577).write(to: ledgerURL, options: .atomic)
        #expect(throws: MiraError.self) { try cleanup.reconcile(retaining: [], credentials: fake) }
        #expect(fake.deleteCalls.isEmpty)
    }

    @Test func itemLimitAndLedgerPermissionsAreEnforced() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cleanup = CredentialCleanup(directory: directory, libraryID: UUID())
        let fake = LockedFakeKeychain()
        let refs = (0..<1_024).map { _ in cleanup.makeReference(version: 1) }
        try cleanup.enqueue(refs)
        let ledgerURL = directory.appendingPathComponent("credential-cleanup.json")
        let permissions =
            try FileManager.default.attributesOfItem(atPath: ledgerURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(throws: MiraError.self) { try cleanup.enqueue([cleanup.makeReference(version: 1)]) }
        #expect(fake.deleteCalls.isEmpty)
    }

    @Test func symlinkLedgerAndCrashRemainderAreRejectedOrRecoveredSafely() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cleanup = CredentialCleanup(directory: directory, libraryID: UUID())
        let fake = LockedFakeKeychain()
        let target = directory.appendingPathComponent("target")
        try Data("not-ledger".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("credential-cleanup.json"), withDestinationURL: target)
        #expect(throws: MiraError.self) { try cleanup.enqueue([cleanup.makeReference(version: 1)]) }
        #expect(fake.deleteCalls.isEmpty)

        try FileManager.default.removeItem(at: directory.appendingPathComponent("credential-cleanup.json"))
        try Data("partial".utf8).write(to: directory.appendingPathComponent("credential-cleanup.json.next"))
        try cleanup.enqueue([])
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("credential-cleanup.json.next").path))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mira-keychain-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func ledgerItems(in directory: URL) throws -> [LedgerItem] {
        let url = directory.appendingPathComponent("credential-cleanup.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
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

private final class LockedFakeKeychain: MacCredentialStore, KeychainAccess, @unchecked Sendable {
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
        lock.lock()
        defer { lock.unlock() }
        return _copyCalls
    }
    var addCalls: [AddCall] {
        lock.lock()
        defer { lock.unlock() }
        return _addCalls
    }
    var deleteCalls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return _deleteCalls
    }
    var copyResult: KeychainReadResult? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _copyResult
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _copyResult = newValue
        }
    }
    var addResult: KeychainStatus {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _addResult
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _addResult = newValue
        }
    }
    var deleteResult: KeychainStatus? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _deleteResult
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _deleteResult = newValue
        }
    }

    func put(_ data: Data, service: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        items[key(service, account)] = data
    }
    func data(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[key(service, account)]
    }
    func copy(service: String, account: String) -> KeychainReadResult {
        lock.lock()
        defer { lock.unlock() }
        _copyCalls.append(.init(service: service, account: account))
        if let result = _copyResult { return result }
        guard let data = items[key(service, account)] else { return .init(status: .itemNotFound, data: nil) }
        return .init(status: .success, data: data)
    }
    func add(service: String, account: String, data: Data, accessibility: KeychainAccessibility, synchronizable: Bool)
        -> KeychainStatus
    {
        lock.lock()
        defer { lock.unlock() }
        _addCalls.append(
            .init(
                service: service, account: account, data: data, accessibility: accessibility,
                synchronizable: synchronizable))
        guard _addResult == .success else { return _addResult }
        let itemKey = key(service, account)
        guard items[itemKey] == nil else { return .duplicate }
        items[itemKey] = data
        return .success
    }
    func delete(service: String, account: String) -> KeychainStatus {
        lock.lock()
        defer { lock.unlock() }
        _deleteCalls.append(.init(service: service, account: account))
        if let result = _deleteResult { return result }
        let removed = items.removeValue(forKey: key(service, account))
        return removed == nil ? .itemNotFound : .success
    }
    func save(_ secret: String, reference: String, version: Int) throws {
        let credentials = KeychainCredentials(access: self)
        try credentials.save(secret, reference: reference, version: version)
    }
    func delete(reference: String, version: Int) throws {
        let credentials = KeychainCredentials(access: self)
        try credentials.delete(reference: reference, version: version)
    }
    func read(reference: String, version: Int) throws -> String {
        try KeychainCredentials(access: self).read(reference: reference, version: version)
    }
    private func key(_ service: String, _ account: String) -> String { "\(service)\u{1f}\(account)" }
}
