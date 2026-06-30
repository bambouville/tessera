import Foundation
import Security

/// Thin wrapper around the iOS Keychain for storing identity
/// secrets (passwords now, SSH key material in Phase 2).
///
/// Each secret is a `kSecClassGenericPassword` item keyed by a
/// service string + the identity's UUID. This keeps passwords out
/// of SwiftData entirely — only a `CredentialMode.password` flag
/// lives in the model, the actual bytes are in the Keychain with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
enum KeychainHelper {

    private static let passwordService = "com.bambouville.Tessera.password"

    // MARK: - Password

    /// Store or update a password for an identity.
    static func setPassword(_ password: String, forIdentityID id: UUID) {
        let account = id.uuidString
        let data = Data(password.utf8)

        // Try update first; if the item doesn't exist yet, add it.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: passwordService,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let update: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(query as CFDictionary, update as CFDictionary)
        } else {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Retrieve the password for an identity, or nil if not stored.
    static func password(forIdentityID id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: passwordService,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Delete the password for an identity.
    static func deletePassword(forIdentityID id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: passwordService,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
