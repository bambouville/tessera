import Foundation
import Security
import Crypto
import CryptoKit
import Citadel
import NIOSSH

/// Manages SSH key lifecycle: generation, import, Keychain storage,
/// and bridging to Citadel's auth methods.
///
/// Private key bytes are stored in iOS Keychain with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Public key
/// metadata lives in SwiftData via `StoredKey`.
enum KeyStore {

    private static let keyService = "com.bambouville.Tessera.sshkey"

    private enum KeyStoreError: LocalizedError {
        case accessControlCreationFailed(String)

        var errorDescription: String? {
            switch self {
            case .accessControlCreationFailed(let reason):
                return "Could not create Secure Enclave access control: \(reason)"
            }
        }
    }

    // MARK: - Generate

    /// Generate a new Ed25519 key pair.
    static func generateEd25519(name: String, context: Any /* ModelContext */) throws -> StoredKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let id = UUID()

        // Store raw 32-byte seed in Keychain.
        storeKeyData(privateKey.rawRepresentation, forKeyID: id)

        let pubLine = ed25519AuthorizedKeysLine(
            publicKey: privateKey.publicKey, comment: name
        )

        let stored = StoredKey(
            id: id,
            name: name,
            algorithm: .ed25519,
            authorizedKeysLine: pubLine,
            createdAt: Date()
        )
        return stored
    }

    /// Generate a new ECDSA P-256 key pair.
    static func generateP256(name: String, enclave: Bool = false) throws -> StoredKey {
        let id = UUID()

        if enclave {
            var accessControlError: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .privateKeyUsage,
                &accessControlError
            ) else {
                let reason = accessControlError
                    .map { String(describing: $0.takeRetainedValue()) }
                    ?? "unknown error"
                throw KeyStoreError.accessControlCreationFailed(reason)
            }

            let privateKey = try SecureEnclave.P256.Signing.PrivateKey(
                accessControl: accessControl
            )
            storeKeyData(privateKey.dataRepresentation, forKeyID: id)

            let pubLine = p256AuthorizedKeysLine(
                publicKey: privateKey.publicKey, comment: name
            )
            let stored = StoredKey(
                id: id,
                name: name,
                algorithm: .ecdsaP256,
                authorizedKeysLine: pubLine,
                createdAt: Date()
            )
            stored.isSecureEnclave = true
            return stored
        }

        let privateKey = P256.Signing.PrivateKey()
        // Store x963 representation in Keychain.
        storeKeyData(privateKey.x963Representation, forKeyID: id)
        let pubLine = p256AuthorizedKeysLine(
            publicKey: privateKey.publicKey, comment: name
        )

        let stored = StoredKey(
            id: id,
            name: name,
            algorithm: .ecdsaP256,
            authorizedKeysLine: pubLine,
            createdAt: Date()
        )
        return stored
    }

    // MARK: - Import

    /// Import an SSH private key from OpenSSH PEM format.
    /// Uses Citadel's public API for Ed25519 and RSA.
    /// P256 import is not supported (Citadel limitation).
    static func importKey(
        pem: String,
        passphrase: String?,
        name: String
    ) throws -> StoredKey {
        let keyType = try SSHKeyDetection.detectPrivateKeyType(from: pem)
        let dk = passphrase.flatMap { Data($0.utf8) }
        let id = UUID()

        switch keyType {
        case .ed25519:
            let privateKey = try Curve25519.Signing.PrivateKey(
                sshEd25519: pem, decryptionKey: dk
            )
            storeKeyData(privateKey.rawRepresentation, forKeyID: id)
            let pubLine = ed25519AuthorizedKeysLine(
                publicKey: privateKey.publicKey, comment: name
            )
            return StoredKey(
                id: id, name: name, algorithm: .ed25519,
                authorizedKeysLine: pubLine
            )

        case .rsa:
            // Validate the PEM parses (will decrypt if needed).
            let _ = try Insecure.RSA.PrivateKey(
                sshRsa: pem, decryptionKey: dk
            )
            // For reconnect, we need a decryptable form. If the key
            // is encrypted, re-export isn't possible through Citadel's
            // API, so reject encrypted RSA imports.
            if dk != nil {
                throw KeyImportError.encryptedRSANotSupported
            }
            // Unencrypted RSA: store the PEM as-is — re-parse works.
            storeKeyData(Data(pem.utf8), forKeyID: id)
            let pubLine = rsaPublicKeyPlaceholder(name: name)
            return StoredKey(
                id: id, name: name, algorithm: .rsa,
                authorizedKeysLine: pubLine
            )

        default:
            throw KeyImportError.unsupportedAlgorithm(keyType.description)
        }
    }

    enum KeyImportError: LocalizedError {
        case unsupportedAlgorithm(String)
        case encryptedRSANotSupported

        var errorDescription: String? {
            switch self {
            case .unsupportedAlgorithm(let alg):
                return "Importing \(alg) keys is not supported. Generate in-app instead."
            case .encryptedRSANotSupported:
                return "Passphrase-protected RSA keys cannot be imported. Use an unencrypted RSA key, or generate an Ed25519 key instead."
            }
        }
    }

    // MARK: - Auth method resolution

    /// Build a Citadel `SSHAuthenticationMethod` from a stored key.
    static func authMethod(
        forKeyID id: UUID,
        algorithm: KeyAlgorithm,
        username: String,
        requireBiometric: Bool = false,
        isSecureEnclave: Bool = false
    ) async -> SSHAuthenticationMethod? {
        if requireBiometric {
            let result = await BiometricGate.evaluate(reason: "unlock SSH key for \(username)")
            guard case .authenticated = result else { return nil }
        }

        guard let data = loadKeyData(forKeyID: id) else { return nil }

        switch algorithm {
        case .ed25519:
            guard data.count == 32,
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
            else { return nil }
            return .ed25519(username: username, privateKey: key)

        case .ecdsaP256:
            if isSecureEnclave {
                guard let key = try? SecureEnclave.P256.Signing.PrivateKey(
                    dataRepresentation: data
                ) else { return nil }
                return EnclaveAuthDelegate.makeAuthMethod(
                    username: username,
                    key: key
                )
            }

            guard let key = try? P256.Signing.PrivateKey(x963Representation: data)
            else { return nil }
            return .p256(username: username, privateKey: key)

        case .rsa:
            // RSA keys are stored as PEM text; re-parse with Citadel.
            guard let pem = String(data: data, encoding: .utf8),
                  let key = try? Insecure.RSA.PrivateKey(sshRsa: pem)
            else { return nil }
            return .rsa(username: username, privateKey: key)
        }
    }

    // MARK: - Delete

    static func deleteKey(forKeyID id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Keychain helpers

    private static func storeKeyData(_ data: Data, forKeyID id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func loadKeyData(forKeyID id: UUID) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return data
    }

    // MARK: - Public key formatting

    /// Build an `authorized_keys` line for an Ed25519 public key.
    /// Wire format: [len "ssh-ed25519"]["ssh-ed25519"][len raw][raw 32 bytes]
    static func ed25519AuthorizedKeysLine(
        publicKey: Curve25519.Signing.PublicKey,
        comment: String
    ) -> String {
        let algo = "ssh-ed25519"
        var wireData = Data()
        wireData.appendSSHString(algo)
        wireData.appendSSHString(publicKey.rawRepresentation)
        return "\(algo) \(wireData.base64EncodedString()) \(comment)"
    }

    /// Build an `authorized_keys` line for a P-256 public key.
    /// Wire format: [len "ecdsa-sha2-nistp256"]["ecdsa-sha2-nistp256"]
    ///              [len "nistp256"]["nistp256"][len point][uncompressed point]
    static func p256AuthorizedKeysLine(
        publicKey: P256.Signing.PublicKey,
        comment: String
    ) -> String {
        let algo = "ecdsa-sha2-nistp256"
        let curve = "nistp256"
        var wireData = Data()
        wireData.appendSSHString(algo)
        wireData.appendSSHString(curve)
        wireData.appendSSHString(publicKey.x963Representation)
        return "\(algo) \(wireData.base64EncodedString()) \(comment)"
    }

    /// RSA public key export from a raw PEM is complex (need to
    /// extract modulus + exponent). For now, store a placeholder.
    /// The key works for auth; export requires more work.
    private static func rsaPublicKeyPlaceholder(name: String) -> String {
        "ssh-rsa (imported, use ssh-keygen -y to extract public key) \(name)"
    }
}

// MARK: - Data SSH string helper

private extension Data {
    /// Append a length-prefixed SSH string (4-byte big-endian length + payload).
    mutating func appendSSHString(_ string: String) {
        let bytes = Data(string.utf8)
        appendSSHString(bytes)
    }

    mutating func appendSSHString(_ data: Data) {
        var len = UInt32(data.count).bigEndian
        append(Data(bytes: &len, count: 4))
        append(data)
    }

    mutating func appendSSHString(_ data: some ContiguousBytes) {
        let d = data.withUnsafeBytes { Data($0) }
        appendSSHString(d)
    }
}
