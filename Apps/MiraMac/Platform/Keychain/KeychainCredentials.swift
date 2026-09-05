import Foundation
import Security
import MiraCore

enum KeychainAccessibility: Equatable, Sendable {
    case whenUnlockedThisDeviceOnly
}

enum KeychainStatus: Equatable, Sendable {
    case success
    case itemNotFound
    case duplicate
    case failure(Int32)
}

struct KeychainReadResult: Sendable {
    let status: KeychainStatus
    let data: Data?
}

/// The small typed surface used by credential storage and cleanup.
/// Security.framework dictionaries remain confined to its concrete adapter.
protocol KeychainAccess: Sendable {
    func copy(service: String, account: String) -> KeychainReadResult
    func add(service: String, account: String, data: Data, accessibility: KeychainAccessibility, synchronizable: Bool) -> KeychainStatus
    func delete(service: String, account: String) -> KeychainStatus
}

private struct SecurityKeychainAccess: KeychainAccess {
    func copy(service: String, account: String) -> KeychainReadResult {
        var query = identity(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return KeychainReadResult(status: map(status), data: result as? Data)
    }

    func add(service: String, account: String, data: Data, accessibility: KeychainAccessibility, synchronizable: Bool) -> KeychainStatus {
        var attributes = identity(service: service, account: account)
        attributes[kSecValueData as String] = data
        if accessibility == .whenUnlockedThisDeviceOnly {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        attributes[kSecAttrSynchronizable as String] = synchronizable
        return map(SecItemAdd(attributes as CFDictionary, nil))
    }

    func delete(service: String, account: String) -> KeychainStatus {
        map(SecItemDelete(identity(service: service, account: account) as CFDictionary))
    }

    private func identity(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func map(_ status: OSStatus) -> KeychainStatus {
        switch status {
        case errSecSuccess: .success
        case errSecItemNotFound: .itemNotFound
        case errSecDuplicateItem: .duplicate
        default: .failure(status)
        }
    }
}

struct KeychainCredentials: CredentialReader, Sendable {
    static let service = "com.alwynou.mira.provider-credentials"
    private let access: any KeychainAccess

    init(access: (any KeychainAccess)? = nil) {
        self.access = access ?? SecurityKeychainAccess()
    }

    func read(reference: String, version: Int) throws -> String {
        let result = access.copy(service: Self.service, account: account(reference: reference, version: version))
        guard result.status == .success, let data = result.data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw MiraError(.credentialMissing, "Unable to read the API key. Save your credentials again in Settings.")
        }
        return value
    }

    func save(_ secret: String, reference: String, version: Int) throws {
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MiraError(.credentialMissing, "Enter an API key.") }
        let status = access.add(service: Self.service, account: account(reference: reference, version: version), data: Data(secret.utf8), accessibility: .whenUnlockedThisDeviceOnly, synchronizable: false)
        guard status == .success else {
            throw MiraError(.credentialMissing, "Keychain could not save the key. Existing credentials were not replaced.")
        }
    }

    func delete(reference: String, version: Int) throws {
        let status = access.delete(service: Self.service, account: account(reference: reference, version: version))
        guard status == .success || status == .itemNotFound else {
            throw MiraError(.credentialMissing, "Keychain could not remove the old credentials.")
        }
    }

    private func account(reference: String, version: Int) -> String {
        "\(reference):\(version)"
    }
}
