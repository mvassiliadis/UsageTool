import Foundation
import Security

protocol SecretStore: Sendable {
    func save(_ secret: Data) async throws
    func load() async throws -> Data?
    func delete() async throws
    func contains() async throws -> Bool
    /// Where the secret actually lives, once an operation has revealed it. `nil` until then.
    func backing() async -> SecretStoreBacking?
}

extension SecretStore {
    func contains() async throws -> Bool { try await load() != nil }
}

/// Which store a secret ended up in. Surfaced in Settings because an ad-hoc signed
/// build silently gets the legacy Keychain rather than the data protection one.
enum SecretStoreBacking: Sendable, Equatable {
    case dataProtection
    case legacyFile
    case inMemory

    var label: String {
        switch self {
        case .dataProtection: "Keychain (data protection)"
        case .legacyFile: "Keychain (legacy file-based)"
        case .inMemory: "In memory (not persisted)"
        }
    }
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

    /// The data protection keychain requires an `application-identifier` (or
    /// `keychain-access-groups`) entitlement. Ad-hoc signed local builds have
    /// neither, so every request fails with `errSecMissingEntitlement`. When
    /// that happens we fall back to the legacy file-based keychain, which is
    /// available to unsigned and ad-hoc signed apps.
    private var useDataProtection = true
    private var observedBacking: SecretStoreBacking?

    func backing() -> SecretStoreBacking? { observedBacking }

    init(service: String = "dev.usagetool.credentials", account: String = "openrouter-management-key") {
        self.service = service
        self.account = account
    }

    func save(_ secret: Data) throws {
        try perform { query, dataProtection in
            var query = query
            var attributes: [CFString: Any] = [kSecValueData: secret]
            // Accessibility classes only apply to the data protection keychain.
            if dataProtection { attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updateStatus == errSecSuccess { return errSecSuccess }
            guard updateStatus == errSecItemNotFound else { return updateStatus }
            for (key, value) in attributes { query[key] = value }
            return SecItemAdd(query as CFDictionary, nil)
        }
    }

    func load() throws -> Data? {
        var item: CFTypeRef?
        let found = try performAllowingNotFound { query, _ in
            var query = query
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            return SecItemCopyMatching(query as CFDictionary, &item)
        }
        guard found else { return nil }
        guard let data = item as? Data else { throw KeychainError.invalidData }
        return data
    }

    func delete() throws {
        _ = try performAllowingNotFound { query, _ in
            SecItemDelete(query as CFDictionary)
        }
    }

    func contains() throws -> Bool {
        try performAllowingNotFound { query, _ in
            var query = query
            query[kSecReturnData] = false
            query[kSecMatchLimit] = kSecMatchLimitOne
            return SecItemCopyMatching(query as CFDictionary, nil)
        }
    }

    /// Runs `operation` against the preferred keychain, retrying once against
    /// the legacy keychain when the entitlement for the data protection
    /// keychain is missing.
    @discardableResult
    private func status(_ operation: ([CFString: Any], Bool) -> OSStatus) -> OSStatus {
        var result = operation(baseQuery, useDataProtection)
        if result == errSecMissingEntitlement, useDataProtection {
            useDataProtection = false
            result = operation(baseQuery, useDataProtection)
        }
        if result != errSecMissingEntitlement {
            observedBacking = useDataProtection ? .dataProtection : .legacyFile
        }
        return result
    }

    private func perform(_ operation: ([CFString: Any], Bool) -> OSStatus) throws {
        let result = status(operation)
        guard result == errSecSuccess else { throw KeychainError.unexpectedStatus(result) }
    }

    /// Returns `true` when the item exists, `false` for `errSecItemNotFound`.
    @discardableResult
    private func performAllowingNotFound(_ operation: ([CFString: Any], Bool) -> OSStatus) throws -> Bool {
        let result = status(operation)
        if result == errSecItemNotFound { return false }
        guard result == errSecSuccess else { throw KeychainError.unexpectedStatus(result) }
        return true
    }

    private var baseQuery: [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if useDataProtection { query[kSecUseDataProtectionKeychain] = true }
        return query
    }
}

actor MemorySecretStore: SecretStore {
    private var value: Data?
    func save(_ secret: Data) { value = secret }
    func load() -> Data? { value }
    func delete() { value = nil }
    func contains() -> Bool { value != nil }
    func backing() -> SecretStoreBacking? { .inMemory }
}
