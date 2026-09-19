import Foundation
import Security

protocol SecretStore: Sendable {
    func save(_ secret: Data) async throws
    func load() async throws -> Data?
    func delete() async throws
    func contains() async throws -> Bool
}

extension SecretStore {
    func contains() async throws -> Bool { try await load() != nil }
}

enum KeychainError: Error, Equatable, LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status): "Keychain operation failed (OSStatus \(status))"
        case .invalidData: "The stored Keychain item has an unexpected format"
        }
    }
}

actor KeychainStore: SecretStore {
    private let service: String
    private let account: String

    init(service: String = "dev.usagetool.credentials", account: String = "openrouter-management-key") {
        self.service = service
        self.account = account
    }

    func save(_ secret: Data) throws {
        var query = baseQuery
        let attributes: [CFString: Any] = [
            kSecValueData: secret,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.unexpectedStatus(updateStatus) }
        for (key, value) in attributes { query[key] = value }
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data else { throw KeychainError.invalidData }
        return data
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func contains() throws -> Bool {
        var query = baseQuery
        query[kSecReturnData] = false
        query[kSecMatchLimit] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        return true
    }

    private var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
    }
}

actor MemorySecretStore: SecretStore {
    private var value: Data?
    func save(_ secret: Data) { value = secret }
    func load() -> Data? { value }
    func delete() { value = nil }
    func contains() -> Bool { value != nil }
}
