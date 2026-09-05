import Foundation
import MiraCore

/// A recovery ledger containing references only. It makes cross-store Keychain cleanup retryable.
struct CredentialCleanup {
    struct Item: Codable, Hashable {
        var reference: String
        var version: Int
        init(_ route: ModelRoute) { reference = route.credentialReference; version = route.credentialVersion }
    }
    private struct Ledger: Codable { var version = 1; var items: [Item] }
    let directory: URL
    private var url: URL { directory.appendingPathComponent("credential-cleanup.json") }

    func enqueue(_ routes: [ModelRoute]) throws {
        let items = Array(Set(try read() + routes.map(Item.init)))
        try write(items)
    }

    func reconcile(retaining routes: [ModelRoute], credentials: KeychainCredentials) throws -> String? {
        let retained = Set(routes.map(Item.init))
        var remaining: [Item] = []
        for item in try read() where !retained.contains(item) {
            do { try credentials.delete(reference: item.reference, version: item.version) }
            catch { remaining.append(item) }
        }
        try write(remaining)
        return remaining.isEmpty ? nil : "连接变更已保存。部分旧 Keychain 凭据暂未清理，已登记重试；可在数据设置中重试清理。"
    }

    private func read() throws -> [Item] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: url))
            guard ledger.version == 1 else { throw MiraError(.storage, "凭据清理记录版本不受支持。") }
            return ledger.items
        } catch { throw MiraError(.storage, "无法读取凭据清理记录，连接变更已暂停。") }
    }
    private func write(_ items: [Item]) throws {
        do {
            try JSONEncoder().encode(Ledger(items: items)).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw MiraError(.storage, "无法保存凭据清理记录，请检查资料库目录权限。") }
    }
}
