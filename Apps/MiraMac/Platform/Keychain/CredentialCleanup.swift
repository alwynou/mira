import Foundation
import MiraCore

/// A recovery ledger containing references only. It makes cross-store Keychain cleanup retryable.
struct CredentialCleanup {
    struct Item: Codable, Hashable {
        var reference: String
        var version: Int
        init(_ route: ProviderConnection) { reference = route.credentialReference; version = route.credentialVersion }
    }
    private struct Ledger: Codable { var version = 1; var items: [Item] }
    let directory: URL
    private var url: URL { directory.appendingPathComponent("credential-cleanup.json") }

    func enqueue(_ routes: [ProviderConnection]) throws {
        let items = Array(Set(try read() + routes.map(Item.init)))
        try write(items)
    }

    func reconcile(retaining routes: [ProviderConnection], credentials: KeychainCredentials) throws -> String? {
        let retained = Set(routes.map(Item.init))
        var remaining: [Item] = []
        for item in try read() where !retained.contains(item) {
            do { try credentials.delete(reference: item.reference, version: item.version) }
            catch { remaining.append(item) }
        }
        try write(remaining)
        return remaining.isEmpty ? nil : "Connection changes were saved. Some old Keychain credentials could not be removed and were queued for retry. Retry cleanup in Data settings."
    }

    private func read() throws -> [Item] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: url))
            guard ledger.version == 1 else { throw MiraError(.storage, "The credential cleanup ledger version is unsupported.") }
            return ledger.items
        } catch { throw MiraError(.storage, "Unable to read the credential cleanup ledger. Connection changes are paused.") }
    }
    private func write(_ items: [Item]) throws {
        do {
            try JSONEncoder().encode(Ledger(items: items)).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw MiraError(.storage, "Unable to save the credential cleanup ledger. Check library directory permissions.") }
    }
}
