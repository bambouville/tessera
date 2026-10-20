import Foundation
import Security

enum BridgeIdentityStoreError: Error, LocalizedError {
    case invalidStoredIdentity
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStoredIdentity:
            "The saved Mac identity is invalid."
        case .keychain:
            "The Mac identity is unavailable in Keychain."
        }
    }
}

enum BridgeIdentityStore {
    private static let service = "com.bambouville.TesseraBridge.identity"
    private static let account = "localEndpointID"

    static func loadOrCreate(migrating legacyValue: String?) throws -> UUID {
        switch try read() {
        case .some(let value): return value
        case .none: break
        }

        let value = legacyValue.flatMap(UUID.init(uuidString:)) ?? UUID()
        return try insertIfMissing(value)
    }

    private static func read() throws -> UUID? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ] as CFDictionary,
            &result
        )
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw BridgeIdentityStoreError.keychain(status)
        }
        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8),
              let value = UUID(uuidString: string) else {
            throw BridgeIdentityStoreError.invalidStoredIdentity
        }
        return value
    }

    private static func insertIfMissing(_ value: UUID) throws -> UUID {
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let data = Data(value.uuidString.utf8)
        var attributes = base
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard let winner = try read() else {
                throw BridgeIdentityStoreError.keychain(errSecItemNotFound)
            }
            return winner
        }
        guard status == errSecSuccess else {
            throw BridgeIdentityStoreError.keychain(status)
        }
        return value
    }
}
