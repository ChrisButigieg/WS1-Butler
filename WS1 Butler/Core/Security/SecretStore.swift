import Foundation
import Security

nonisolated enum SecretStoreError: LocalizedError, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        case .encodingFailed:
            return "Could not encode credentials."
        }
    }
}

/// Storage for per-server credentials.
protocol SecretStore: AnyObject {
    func secrets(for serverID: UUID) throws -> ServerSecrets
    func save(_ secrets: ServerSecrets, for serverID: UUID) throws
    func delete(for serverID: UUID) throws
}

/// Keychain-backed secret storage.
///
/// - Items are `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: they are never included in
///   backups or iCloud Keychain sync and cannot be read while the device is locked.
/// - On macOS the data-protection keychain is preferred; if the build lacks the
///   entitlement required for it, the sandboxed file-based keychain is used instead.
final class KeychainSecretStore: SecretStore {
    private let service: String

    init(service: String = "mil.afrc.ws1butler.credentials") {
        self.service = service
    }

    func secrets(for serverID: UUID) throws -> ServerSecrets {
        var query = baseQuery(for: serverID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        // Without the data-protection entitlement, lookups report "not found" rather than
        // "missing entitlement", and saves land in the legacy keychain — so check it too.
        if status == errSecMissingEntitlement || status == errSecItemNotFound, usesDataProtection {
            result = nil
            status = SecItemCopyMatching(legacy(query) as CFDictionary, &result)
        }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return ServerSecrets() }
            return (try? JSONDecoder().decode(ServerSecrets.self, from: data)) ?? ServerSecrets()
        case errSecItemNotFound:
            return ServerSecrets()
        default:
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    func save(_ secrets: ServerSecrets, for serverID: UUID) throws {
        guard let data = try? JSONEncoder().encode(secrets) else { throw SecretStoreError.encodingFailed }
        let query = baseQuery(for: serverID)

        var status = upsert(query: query, data: data)
        if status == errSecMissingEntitlement {
            status = upsert(query: legacy(query), data: data)
        }
        guard status == errSecSuccess else { throw SecretStoreError.unexpectedStatus(status) }
    }

    func delete(for serverID: UUID) throws {
        let query = baseQuery(for: serverID)
        var statuses = [SecItemDelete(query as CFDictionary)]
        if usesDataProtection {
            // Remove any copy stored in the legacy keychain as well.
            statuses.append(SecItemDelete(legacy(query) as CFDictionary))
        }
        let acceptable: Set<OSStatus> = [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement]
        if let failure = statuses.first(where: { !acceptable.contains($0) }) {
            throw SecretStoreError.unexpectedStatus(failure)
        }
    }

    private var usesDataProtection: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    // MARK: Helpers

    private func upsert(query: [String: Any], data: Data) -> OSStatus {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var insert = query
        insert.merge(attributes) { _, new in new }
        insert[kSecAttrLabel as String] = "WS1 Butler server credentials"
        return SecItemAdd(insert as CFDictionary, nil)
    }

    private func baseQuery(for serverID: UUID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString,
            kSecAttrSynchronizable as String: false
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private func legacy(_ query: [String: Any]) -> [String: Any] {
        var copy = query
        copy.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        return copy
    }
}

/// Volatile secret storage used by tests, previews, and UI-test runs.
final class InMemorySecretStore: SecretStore {
    private var storage: [UUID: ServerSecrets] = [:]

    func secrets(for serverID: UUID) throws -> ServerSecrets { storage[serverID] ?? ServerSecrets() }
    func save(_ secrets: ServerSecrets, for serverID: UUID) throws { storage[serverID] = secrets }
    func delete(for serverID: UUID) throws { storage[serverID] = nil }
}
