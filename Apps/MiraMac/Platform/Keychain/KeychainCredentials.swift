import Foundation
import Security
import MiraCore

struct KeychainCredentials: CredentialReader {
    private let service = "com.alwynou.mira.provider-credentials"

    func read(reference: String, version: Int) throws -> String {
        var query = identity(reference, version)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw MiraError(.credentialMissing, "无法读取 API Key，请在设置中重新保存凭据。")
        }
        return value
    }

    func save(_ secret: String, reference: String, version: Int) throws {
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MiraError(.credentialMissing, "请输入 API Key。") }
        var attributes = identity(reference, version)
        attributes[kSecValueData as String] = Data(secret.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw MiraError(.credentialMissing, "Keychain 保存失败，原有凭据未被替换。")
        }
    }

    func delete(reference: String, version: Int) throws {
        let status = SecItemDelete(identity(reference, version) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MiraError(.credentialMissing, "Keychain 暂时无法移除旧凭据。") }
    }

    // The untyped dictionary is required by Security.framework, and stays inside this adapter.
    private func identity(_ reference: String, _ version: Int) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "\(reference):\(version)"]
    }
}
