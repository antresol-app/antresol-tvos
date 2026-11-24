import Foundation
import os
import Security

/// Generic-password items of one Keychain service, addressed by account name.
/// With an `accessGroup` the items live in that shared group (app and Top Shelf extension).
/// Items are readable after the first unlock and stay on this device (no backup or
/// device-to-device transfer); an item made before that is moved to it the first time it is read.
struct Keychain: Sendable {
    let service: String
    var accessGroup: String?

    init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private static let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Antresol", category: "keychain")

    func string(for account: String) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data
        else { return nil }
        // A token stored before it was bound to this device: the attribute is changed in
        // place, the item (and so the sign-in) stays. A failed update changes nothing.
        if (item[kSecAttrAccessible as String] as? String) != (Self.accessible as String) {
            let status = SecItemUpdate(baseQuery(for: account) as CFDictionary, [kSecAttrAccessible as String: Self.accessible] as CFDictionary)
            // Only the service and the status code: never the account (server and profile) or the value.
            if status == errSecSuccess {
                Self.log.info("moved an item of \(service, privacy: .public) to this device only")
            } else if status != errSecItemNotFound {
                Self.log.error("moving an item of \(service, privacy: .public) to this device only failed: \(status, privacy: .public)")
            }
        }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(for: account)
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: Self.accessible]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = Self.accessible
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func remove(_ account: String) throws {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func baseQuery(for account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}
