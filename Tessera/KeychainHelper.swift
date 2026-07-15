import Foundation
import Security

enum KeychainOperation: String, Sendable {
    case add
    case update
    case copy
    case delete
}

/// A status-preserving Keychain failure. The description contains only the
/// operation and Apple's status text; it never includes the secret, account,
/// query, or authentication input.
struct KeychainOperationError: LocalizedError, Equatable, Sendable {
    let operation: KeychainOperation
    let status: OSStatus

    var errorDescription: String? {
        let statusDescription = SecCopyErrorMessageString(status, nil) as String?
            ?? "OSStatus \(status)"
        return "Keychain \(operation.rawValue) failed: \(statusDescription)"
    }
}

/// Injectable boundary around every SecItem operation used for credentials.
/// Production code uses `.live`; tests can return exact OSStatus failures
/// without mutating the simulator's real Keychain.
struct KeychainClient {
    var add: (_ attributes: [String: Any]) -> OSStatus
    var update: (_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    var copyMatching: (_ query: [String: Any]) -> (OSStatus, AnyObject?)
    var delete: (_ query: [String: Any]) -> OSStatus

    static let live = KeychainClient(
        add: { SecItemAdd($0 as CFDictionary, nil) },
        update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        copyMatching: { query in
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        },
        delete: { SecItemDelete($0 as CFDictionary) }
    )
}

/// Checked Keychain operations for identity passwords.
enum KeychainHelper {

    private static let passwordService = "com.bambouville.Tessera.password"
    private static let passwordRevisionLock = NSLock()
    nonisolated(unsafe) private static var mutablePasswordCredentialRevision: UInt64 = 0

    /// Process-lifetime revision only. Existing grants and policy snapshots do
    /// not survive process termination, so persistence is unnecessary and no
    /// password-derived long-lived metadata is created.
    static var passwordCredentialRevision: UInt64 {
        passwordRevisionLock.withLock { mutablePasswordCredentialRevision }
    }

    // MARK: - Password

    static func setPassword(
        _ password: String,
        forIdentityID id: UUID,
        keychain: KeychainClient = .live
    ) throws {
        passwordRevisionLock.lock()
        defer { passwordRevisionLock.unlock() }
        let query = passwordQuery(for: id)
        var data = Data(password.utf8)
        defer { data.resetBytes(in: 0..<data.count) }
        let (copyStatus, _) = keychain.copyMatching(query)

        switch copyStatus {
        case errSecSuccess:
            let status = keychain.update(
                query,
                [kSecValueData as String: data]
            )
            guard status == errSecSuccess else {
                throw KeychainOperationError(operation: .update, status: status)
            }

        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] =
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = keychain.add(attributes)
            guard status == errSecSuccess else {
                throw KeychainOperationError(operation: .add, status: status)
            }

        default:
            throw KeychainOperationError(operation: .copy, status: copyStatus)
        }
        announcePasswordCredentialRevision(
            advancePasswordCredentialRevisionWhileLocked()
        )
    }

    /// Returns nil only when the item does not exist. Protected-data,
    /// entitlement, authentication, and decoding failures are surfaced.
    static func password(
        forIdentityID id: UUID,
        keychain: KeychainClient = .live
    ) throws -> String? {
        try passwordCredential(
            forIdentityID: id,
            keychain: keychain
        ).password
    }

    /// Reads password and revision under the same lock used by mutations, so
    /// an authentication snapshot can never pair an old password with the
    /// revision assigned to a concurrent rotation.
    static func passwordCredential(
        forIdentityID id: UUID,
        keychain: KeychainClient = .live
    ) throws -> (password: String?, revision: UInt64) {
        passwordRevisionLock.lock()
        defer { passwordRevisionLock.unlock() }
        var query = passwordQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, result) = keychain.copyMatching(query)
        if status == errSecItemNotFound {
            return (nil, mutablePasswordCredentialRevision)
        }
        guard status == errSecSuccess else {
            throw KeychainOperationError(operation: .copy, status: status)
        }
        guard var data = result as? Data else {
            throw KeychainOperationError(operation: .copy, status: errSecDecode)
        }
        defer { data.resetBytes(in: 0..<data.count) }
        guard let password = String(data: data, encoding: .utf8) else {
            throw KeychainOperationError(operation: .copy, status: errSecDecode)
        }
        return (password, mutablePasswordCredentialRevision)
    }

    /// Returns whether an item was actually removed.
    @discardableResult
    static func deletePassword(
        forIdentityID id: UUID,
        keychain: KeychainClient = .live
    ) throws -> Bool {
        passwordRevisionLock.lock()
        defer { passwordRevisionLock.unlock() }
        let status = keychain.delete(passwordQuery(for: id))
        if status == errSecItemNotFound {
            announcePasswordCredentialRevision(
                advancePasswordCredentialRevisionWhileLocked()
            )
            return false
        }
        guard status == errSecSuccess else {
            throw KeychainOperationError(operation: .delete, status: status)
        }
        announcePasswordCredentialRevision(
            advancePasswordCredentialRevisionWhileLocked()
        )
        return true
    }

    private static func advancePasswordCredentialRevisionWhileLocked() -> UInt64 {
        mutablePasswordCredentialRevision &+= 1
        return mutablePasswordCredentialRevision
    }

    private static func announcePasswordCredentialRevision(_ revision: UInt64) {
        Task { @MainActor in
            SSHAuthenticationPolicyStore.shared.observePasswordCredentialRevision(
                revision
            )
        }
    }

    private static func passwordQuery(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: passwordService,
            kSecAttrAccount as String: id.uuidString,
        ]
    }
}
