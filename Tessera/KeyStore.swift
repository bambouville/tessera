import Foundation
import Security
import Crypto
import CryptoKit
import Citadel
import NIOSSH
import CommonCrypto
import CCitadelBcrypt
import LocalAuthentication

/// Manages SSH key generation, recovery, checked Keychain storage, and
/// bridging to Citadel's authentication methods. SwiftData owns public
/// metadata; this type never writes private material to a file or a log.
enum KeyStore {

    private static let keyService = "com.bambouville.Tessera.sshkey"

    /// Protection selected when software key material is first stored.
    /// `.deviceUnlocked` participates in encrypted device backups but is not
    /// synchronizable. `.userPresence` additionally asks Security to enforce
    /// biometric-or-device-passcode authentication at Keychain retrieval.
    enum KeyProtection: Equatable, Sendable {
        case deviceUnlocked
        case userPresence
    }

    enum KeyStoreError: LocalizedError {
        case accessControlCreationFailed(String)
        case privateMaterialMissing
        case invalidPrivateMaterial
        case secureEnclaveProtectionRequiresRotation
        case unexpectedKeychainResult
        case compensationFailed(primary: Error, compensation: Error)

        var errorDescription: String? {
            switch self {
            case .accessControlCreationFailed(let reason):
                return "Could not create key access control: \(reason)"
            case .privateMaterialMissing:
                return "The private key material is missing from this device."
            case .invalidPrivateMaterial:
                return "The stored private key material is invalid."
            case .secureEnclaveProtectionRequiresRotation:
                return "Secure Enclave protection cannot be changed after creation. Rotate the key instead."
            case .unexpectedKeychainResult:
                return "The Keychain returned an unexpected result."
            case .compensationFailed(let primary, let compensation):
                return "The key operation failed (\(primary.localizedDescription)) and its recovery action also failed (\(compensation.localizedDescription))."
            }
        }
    }

    enum KeyImportError: LocalizedError, Equatable {
        case unsupportedAlgorithm(String)
        case rsaNotSupported
        case invalidTextEncoding
        case invalidPrivateKeyOrPassphrase

        var errorDescription: String? {
            switch self {
            case .unsupportedAlgorithm(let algorithm):
                return "Importing \(algorithm) keys is not supported. Use Ed25519 instead."
            case .rsaNotSupported:
                return "RSA import is disabled because the current SSH stack can only offer the deprecated RSA/SHA-1 signature. Use Ed25519 instead."
            case .invalidTextEncoding:
                return "The private key is not valid UTF-8 OpenSSH text."
            case .invalidPrivateKeyOrPassphrase:
                return "The OpenSSH private key or its passphrase is invalid."
            }
        }
    }

    enum RecoveryError: LocalizedError, Equatable {
        case passphraseRequired
        case unsupportedAlgorithm
        case fingerprintMismatch(expected: String, actual: String)
        case randomGenerationFailed(OSStatus)
        case keyDerivationFailed
        case encryptionFailed(CCCryptorStatus)

        var errorDescription: String? {
            switch self {
            case .passphraseRequired:
                return "A non-empty recovery passphrase is required."
            case .unsupportedAlgorithm:
                return "Encrypted recovery export currently supports Ed25519 software keys only."
            case .fingerprintMismatch:
                return "This recovery key does not match the selected key."
            case .randomGenerationFailed:
                return "Secure random generation failed."
            case .keyDerivationFailed:
                return "Could not derive the OpenSSH recovery encryption key."
            case .encryptionFailed:
                return "Could not encrypt the OpenSSH recovery key."
            }
        }
    }

    /// Opaque compensation token returned by `removeKeyMaterial`. It retains
    /// the item's bytes and exact accessibility/access-control attributes only
    /// in memory so a failed metadata transaction can restore the item.
    struct DeletedKeyMaterial {
        fileprivate let id: UUID
        fileprivate var data: Data
        fileprivate let protectionAttributes: [String: Any]
    }

    enum KeyMaterialProtection: Equatable {
        case missing
        case deviceUnlocked(deviceOnly: Bool)
        case userPresence
    }

    struct IntegrityReport: Equatable {
        let metadataOnlyKeyIDs: Set<UUID>
        let orphanedKeyIDs: Set<UUID>
        let invalidAccountCount: Int
    }

    // MARK: - Generate

    static func generateEd25519(
        name: String,
        context: Any /* ModelContext */,
        protection: KeyProtection = .deviceUnlocked,
        keychain: KeychainClient = .live
    ) throws -> StoredKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let id = UUID()

        try storeKeyData(
            privateKey.rawRepresentation,
            forKeyID: id,
            protection: protection,
            deviceBound: false,
            keychain: keychain
        )

        return StoredKey(
            id: id,
            name: name,
            algorithm: .ed25519,
            authorizedKeysLine: ed25519AuthorizedKeysLine(
                publicKey: privateKey.publicKey,
                comment: name
            ),
            createdAt: Date()
        )
    }

    static func generateP256(
        name: String,
        enclave: Bool = false,
        protection: KeyProtection = .deviceUnlocked,
        keychain: KeychainClient = .live
    ) throws -> StoredKey {
        let id = UUID()

        if enclave {
            let accessControl = try makeAccessControl(
                accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                flags: secureEnclaveFlags(for: protection)
            )
            let privateKey = try SecureEnclave.P256.Signing.PrivateKey(
                accessControl: accessControl
            )
            try storeKeyData(
                privateKey.dataRepresentation,
                forKeyID: id,
                protection: protection,
                deviceBound: true,
                keychain: keychain
            )

            let stored = StoredKey(
                id: id,
                name: name,
                algorithm: .ecdsaP256,
                authorizedKeysLine: p256AuthorizedKeysLine(
                    publicKey: privateKey.publicKey,
                    comment: name
                ),
                createdAt: Date()
            )
            stored.isSecureEnclave = true
            return stored
        }

        let privateKey = P256.Signing.PrivateKey()
        try storeKeyData(
            privateKey.x963Representation,
            forKeyID: id,
            protection: protection,
            deviceBound: false,
            keychain: keychain
        )
        return StoredKey(
            id: id,
            name: name,
            algorithm: .ecdsaP256,
            authorizedKeysLine: p256AuthorizedKeysLine(
                publicKey: privateKey.publicKey,
                comment: name
            ),
            createdAt: Date()
        )
    }

    // MARK: - Import and recovery

    static func importKey(
        data: Data,
        passphrase: String?,
        name: String,
        protection: KeyProtection = .deviceUnlocked,
        keychain: KeychainClient = .live
    ) throws -> StoredKey {
        guard let text = String(data: data, encoding: .utf8) else {
            throw KeyImportError.invalidTextEncoding
        }
        return try importKey(
            pem: text,
            passphrase: passphrase,
            name: name,
            protection: protection,
            keychain: keychain
        )
    }

    static func importKey(
        pem: String,
        passphrase: String?,
        name: String,
        protection: KeyProtection = .deviceUnlocked,
        keychain: KeychainClient = .live
    ) throws -> StoredKey {
        let keyType: SSHKeyType
        do {
            keyType = try SSHKeyDetection.detectPrivateKeyType(from: pem)
        } catch {
            throw KeyImportError.invalidPrivateKeyOrPassphrase
        }

        switch keyType {
        case .rsa:
            // Citadel 0.12.1 offers only legacy ssh-rsa/SHA-1. Reject every
            // RSA size until RSA-SHA2 is proven at packet/server-log level.
            throw KeyImportError.rsaNotSupported

        case .ed25519:
            let privateKey: Curve25519.Signing.PrivateKey
            do {
                var decryptionKey = passphrase.map { Data($0.utf8) }
                defer {
                    var bytes = decryptionKey
                    decryptionKey = nil
                    let count = bytes?.count ?? 0
                    bytes?.resetBytes(in: 0..<count)
                }
                privateKey = try Curve25519.Signing.PrivateKey(
                    sshEd25519: pem,
                    decryptionKey: decryptionKey
                )
            } catch {
                throw KeyImportError.invalidPrivateKeyOrPassphrase
            }

            let id = UUID()
            try storeKeyData(
                privateKey.rawRepresentation,
                forKeyID: id,
                protection: protection,
                deviceBound: false,
                keychain: keychain
            )
            return StoredKey(
                id: id,
                name: name,
                algorithm: .ed25519,
                authorizedKeysLine: ed25519AuthorizedKeysLine(
                    publicKey: privateKey.publicKey,
                    comment: name
                )
            )

        default:
            throw KeyImportError.unsupportedAlgorithm(keyType.description)
        }
    }

    /// Export an in-memory, passphrase-encrypted `openssh-key-v1` Ed25519 key.
    /// The returned Data is ready for a SwiftUI FileDocument/share workflow;
    /// no plaintext private-key file or pasteboard value is created.
    static func exportEncryptedEd25519PrivateKey(
        forKeyID id: UUID,
        passphrase: String,
        comment: String,
        authorization: BiometricAuthorization? = nil,
        keychain: KeychainClient = .live
    ) throws -> Data {
        var raw = try requiredKeyData(
            forKeyID: id,
            authorization: authorization,
            interactionNotAllowed: authorization == nil,
            keychain: keychain
        )
        defer { raw.resetBytes(in: 0..<raw.count) }
        guard raw.count == 32,
              let privateKey = try? Curve25519.Signing.PrivateKey(
                rawRepresentation: raw
              )
        else {
            throw KeyStoreError.invalidPrivateMaterial
        }
        let text = try encryptedOpenSSHRepresentation(
            privateKey: privateKey,
            passphrase: passphrase,
            comment: comment
        )
        return Data(text.utf8)
    }

    /// Restore a missing Ed25519 secret under an existing metadata UUID. The
    /// expected fingerprint is checked before any Keychain mutation, so all
    /// Identity/host references repair without accepting the wrong key.
    @discardableResult
    static func recoverEd25519Key(
        data: Data,
        passphrase: String,
        forKeyID id: UUID,
        expectedFingerprint: String,
        protection: KeyProtection = .deviceUnlocked,
        keychain: KeychainClient = .live
    ) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw KeyImportError.invalidTextEncoding
        }
        return try recoverEd25519Key(
            pem: text,
            passphrase: passphrase,
            forKeyID: id,
            expectedFingerprint: expectedFingerprint,
            protection: protection,
            keychain: keychain
        )
    }

    /// Decrypts and fingerprints a recovery file without changing Keychain or
    /// SwiftData state. This is used to verify an exported backup while the
    /// original live key is still present.
    static func recoveryFingerprint(
        data: Data,
        passphrase: String
    ) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw KeyImportError.invalidTextEncoding
        }
        return try recoveryFingerprint(pem: text, passphrase: passphrase)
    }

    static func recoveryFingerprint(
        pem: String,
        passphrase: String
    ) throws -> String {
        let privateKey = try parseRecoveryEd25519Key(
            pem: pem,
            passphrase: passphrase
        )
        return canonicalFingerprint(
            forAuthorizedKeysLine: ed25519AuthorizedKeysLine(
                publicKey: privateKey.publicKey,
                comment: ""
            )
        )
    }

    @discardableResult
    static func recoverEd25519Key(
        pem: String,
        passphrase: String,
        forKeyID id: UUID,
        expectedFingerprint: String,
        protection: KeyProtection = .deviceUnlocked,
        keychain: KeychainClient = .live
    ) throws -> String {
        let privateKey = try parseRecoveryEd25519Key(
            pem: pem,
            passphrase: passphrase
        )

        let actual = canonicalFingerprint(
            forAuthorizedKeysLine: ed25519AuthorizedKeysLine(
                publicKey: privateKey.publicKey,
                comment: ""
            )
        )
        guard actual == expectedFingerprint else {
            throw RecoveryError.fingerprintMismatch(
                expected: expectedFingerprint,
                actual: actual
            )
        }

        // Recovery is also the repair path for valid-but-wrong bytes under an
        // existing UUID. Preserve the old material in memory until replacement
        // succeeds so an add failure cannot destroy the only live credential.
        var oldMaterial = try removeKeyMaterial(
            forKeyID: id,
            interactionNotAllowed: true,
            keychain: keychain
        )
        defer { discardDeletedKeyMaterial(&oldMaterial) }
        do {
            try storeKeyData(
                privateKey.rawRepresentation,
                forKeyID: id,
                protection: protection,
                deviceBound: false,
                keychain: keychain
            )
        } catch {
            guard let oldMaterial else { throw error }
            do {
                try restoreDeletedKeyMaterial(oldMaterial, keychain: keychain)
            } catch let compensationError {
                throw KeyStoreError.compensationFailed(
                    primary: error,
                    compensation: compensationError
                )
            }
            throw error
        }
        return actual
    }

    // MARK: - Integrity and fingerprinting

    /// Returns false only for `errSecItemNotFound`; all other statuses throw.
    static func hasPrivateMaterial(
        forKeyID id: UUID,
        keychain: KeychainClient = .live
    ) throws -> Bool {
        var query = baseQuery(forKeyID: id)
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let (status, _) = keychain.copyMatching(query)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw KeychainOperationError(operation: .copy, status: status)
        }
        return true
    }

    /// Determines whether Security will release the item without owner
    /// authentication. Attribute dictionaries are not sufficient by
    /// themselves: iOS can return an unconstrained `SecAccessControl` for an
    /// item stored with ordinary device-unlocked accessibility. When that
    /// happens, probe the value with interaction disabled and immediately wipe
    /// it; success proves prompt-free access, while an ACL refusal proves user
    /// presence without ever allowing Security to present UI.
    static func materialProtection(
        forKeyID id: UUID,
        keychain: KeychainClient = .live
    ) throws -> KeyMaterialProtection {
        var query = baseQuery(forKeyID: id)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let (status, result) = keychain.copyMatching(query)
        if status == errSecItemNotFound { return .missing }
        // On-device, an item behind a user-presence ACL can refuse even this
        // attributes-only read under a non-interactive context. The refusal
        // itself is the answer: the item exists and is presence-protected.
        // Device-unlocked items always answer attribute reads.
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            return .userPresence
        }
        guard status == errSecSuccess else {
            throw KeychainOperationError(operation: .copy, status: status)
        }
        guard let attributes = result as? [String: Any] else {
            throw KeyStoreError.unexpectedKeychainResult
        }
        let accessible = attributes[kSecAttrAccessible as String] as? String
        guard attributes[kSecAttrAccessControl as String] != nil else {
            guard let accessible else {
                throw KeyStoreError.unexpectedKeychainResult
            }
            return .deviceUnlocked(
                deviceOnly: accessible
                    == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            )
        }

        var accessProbe = baseQuery(forKeyID: id)
        accessProbe[kSecReturnData as String] = true
        accessProbe[kSecMatchLimit as String] = kSecMatchLimitOne
        accessProbe[kSecUseAuthenticationContext as String] = context
        let (accessStatus, accessResult) = keychain.copyMatching(accessProbe)
        switch accessStatus {
        case errSecSuccess:
            guard var data = accessResult as? Data else {
                throw KeyStoreError.unexpectedKeychainResult
            }
            data.resetBytes(in: 0..<data.count)
            return .deviceUnlocked(
                deviceOnly: accessible
                    == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            )
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed:
            return .userPresence
        default:
            throw KeychainOperationError(operation: .copy, status: accessStatus)
        }
    }

    /// Inventories account UUIDs for Tessera's key service without requesting
    /// any private bytes. Callers can surface/repair metadata-only rows and
    /// explicitly clean orphaned items without logging account identifiers.
    static func integrityReport(
        metadataKeyIDs: Set<UUID>,
        keychain: KeychainClient = .live
    ) throws -> IntegrityReport {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: context,
        ]
        let (status, result) = keychain.copyMatching(query)
        if status == errSecItemNotFound {
            return IntegrityReport(
                metadataOnlyKeyIDs: metadataKeyIDs,
                orphanedKeyIDs: [],
                invalidAccountCount: 0
            )
        }
        guard status == errSecSuccess else {
            throw KeychainOperationError(operation: .copy, status: status)
        }

        let attributes: [[String: Any]]
        if let many = result as? [[String: Any]] {
            attributes = many
        } else if let one = result as? [String: Any] {
            attributes = [one]
        } else {
            throw KeyStoreError.unexpectedKeychainResult
        }

        var keychainIDs: Set<UUID> = []
        var invalidAccountCount = 0
        for item in attributes {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let id = UUID(uuidString: account) else {
                invalidAccountCount += 1
                continue
            }
            keychainIDs.insert(id)
        }
        return IntegrityReport(
            metadataOnlyKeyIDs: metadataKeyIDs.subtracting(keychainIDs),
            orphanedKeyIDs: keychainIDs.subtracting(metadataKeyIDs),
            invalidAccountCount: invalidAccountCount
        )
    }

    static func canonicalFingerprint(forAuthorizedKeysLine line: String) -> String {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2,
              let blob = Data(base64Encoded: String(fields[1]))
        else { return "" }
        return openSSHFingerprint(blob)
    }

    /// Compatibility spelling for existing callers. New code should use the
    /// canonical name to make OpenSSH's unpadded representation explicit.
    static func fingerprint(forAuthorizedKeysLine line: String) -> String {
        canonicalFingerprint(forAuthorizedKeysLine: line)
    }

    /// Performs a non-interactive integrity check. Owner-presence protected
    /// items return `.authenticationRequired` instead of triggering Face ID,
    /// Touch ID, or passcode merely because the app/UI is reconciling state.
    static func privateMaterialIntegrity(
        forKeyID id: UUID,
        algorithm: KeyAlgorithm,
        isSecureEnclave: Bool = false,
        expectedAuthorizedKeysLine: String,
        keychain: KeychainClient = .live
    ) -> KeyMaterialIntegrity {
        let expected = canonicalFingerprint(
            forAuthorizedKeysLine: expectedAuthorizedKeysLine
        )
        guard !expected.isEmpty else { return .invalid }
        guard algorithm != .rsa else { return .unsupportedAlgorithm }

        let protection: KeyMaterialProtection
        do {
            protection = try materialProtection(forKeyID: id, keychain: keychain)
        } catch let error as KeychainOperationError
            where error.operation == .copy
                && error.status == errSecInteractionNotAllowed {
            // On physical devices, an access-controlled generic-password item
            // can require owner presence even for an attributes-only query.
            // The exact service/account match therefore proved that protected
            // material exists; authentication will perform the authoritative
            // read. Do not misclassify this expected ACL gate as corruption
            // and erase session-restore snapshots for a key that just worked.
            return .authenticationRequired
        } catch {
            return .unavailable
        }
        if protection == .missing { return .missing }

        do {
            let actual = try privateMaterialFingerprint(
                forKeyID: id,
                algorithm: algorithm,
                isSecureEnclave: isSecureEnclave,
                interactionNotAllowed: true,
                keychain: keychain
            )
            return actual == expected ? .valid : .mismatched
        } catch let error as KeychainOperationError {
            if protection == .userPresence,
               error.operation == .copy,
               error.status == errSecInteractionNotAllowed {
                return .authenticationRequired
            }
            if error.status == errSecItemNotFound { return .missing }
            return .unavailable
        } catch KeyStoreError.privateMaterialMissing {
            return .missing
        } catch KeyStoreError.invalidPrivateMaterial {
            return .invalid
        } catch RecoveryError.unsupportedAlgorithm {
            return .unsupportedAlgorithm
        } catch {
            return .unavailable
        }
    }

    static func privateMaterialFingerprint(
        forKeyID id: UUID,
        algorithm: KeyAlgorithm,
        isSecureEnclave: Bool = false,
        interactionNotAllowed: Bool = true,
        keychain: KeychainClient = .live
    ) throws -> String {
        var data = try requiredKeyData(
            forKeyID: id,
            interactionNotAllowed: interactionNotAllowed,
            keychain: keychain
        )
        defer { data.resetBytes(in: 0..<data.count) }
        let line: String

        switch algorithm {
        case .ed25519:
            guard data.count == 32,
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
            else { throw KeyStoreError.invalidPrivateMaterial }
            line = ed25519AuthorizedKeysLine(publicKey: key.publicKey, comment: "")

        case .ecdsaP256:
            if isSecureEnclave {
                guard let key = try? SecureEnclave.P256.Signing.PrivateKey(
                    dataRepresentation: data
                ) else { throw KeyStoreError.invalidPrivateMaterial }
                line = p256AuthorizedKeysLine(publicKey: key.publicKey, comment: "")
            } else {
                guard let key = try? P256.Signing.PrivateKey(x963Representation: data)
                else { throw KeyStoreError.invalidPrivateMaterial }
                line = p256AuthorizedKeysLine(publicKey: key.publicKey, comment: "")
            }

        case .rsa:
            // New RSA material cannot enter the store. A legacy RSA item has
            // no trustworthy stored public blob and is deliberately ineligible.
            throw RecoveryError.unsupportedAlgorithm
        }

        return canonicalFingerprint(forAuthorizedKeysLine: line)
    }

    static func verifyPrivateMaterial(
        forKeyID id: UUID,
        algorithm: KeyAlgorithm,
        isSecureEnclave: Bool = false,
        expectedFingerprint: String,
        keychain: KeychainClient = .live
    ) throws -> Bool {
        try privateMaterialFingerprint(
            forKeyID: id,
            algorithm: algorithm,
            isSecureEnclave: isSecureEnclave,
            keychain: keychain
        ) == expectedFingerprint
    }

    // MARK: - Auth method resolution

    /// Build a Citadel method. Nil means the item is absent; malformed data
    /// and Keychain policy failures throw so callers cannot treat them as a
    /// successful credential resolution.
    static func authMethod(
        forKeyID id: UUID,
        algorithm: KeyAlgorithm,
        username: String,
        authorization: BiometricAuthorization? = nil,
        isSecureEnclave: Bool = false,
        keychain: KeychainClient = .live
    ) async throws -> SSHAuthenticationMethod? {
        guard var data = try loadKeyData(
            forKeyID: id,
            authorization: authorization,
            interactionNotAllowed: authorization == nil,
            keychain: keychain
        ) else {
            return nil
        }
        defer { data.resetBytes(in: 0..<data.count) }

        switch algorithm {
        case .ed25519:
            guard data.count == 32,
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
            else { return nil }
            return OneShotSoftwareKeyAuthDelegate.makeAuthMethod(
                username: username,
                key: .ed25519(key)
            )

        case .ecdsaP256:
            if isSecureEnclave {
                let authenticationContext: LAContext
                if let authorization {
                    authenticationContext = authorization.context
                } else {
                    authenticationContext = LAContext()
                    authenticationContext.interactionNotAllowed = true
                }
                guard let key = try? SecureEnclave.P256.Signing.PrivateKey(
                    dataRepresentation: data,
                    authenticationContext: authenticationContext
                ) else { return nil }
                return EnclaveAuthDelegate.makeAuthMethod(username: username, key: key)
            }

            guard let key = try? P256.Signing.PrivateKey(x963Representation: data)
            else { return nil }
            return OneShotSoftwareKeyAuthDelegate.makeAuthMethod(
                username: username,
                key: .p256(key)
            )

        case .rsa:
            // Legacy items are intentionally disabled with RSA import because
            // Citadel's implementation signs user auth using RSA/SHA-1.
            return nil
        }
    }

    // MARK: - Checked lifecycle and compensation

    /// Removes the item and returns an in-memory token that can recreate it
    /// with its previous accessibility/access-control attributes.
    static func removeKeyMaterial(
        forKeyID id: UUID,
        authorization: BiometricAuthorization? = nil,
        interactionNotAllowed: Bool = false,
        keychain: KeychainClient = .live
    ) throws -> DeletedKeyMaterial? {
        guard var snapshot = try keyMaterialSnapshot(
            forKeyID: id,
            authorization: authorization,
            interactionNotAllowed: interactionNotAllowed,
            keychain: keychain
        ) else { return nil }

        // Authentication is required to release protected bytes, not to delete
        // the exact generic-password row. Supplying an LAContext to
        // SecItemDelete is rejected on physical devices and left the old ACL in
        // place after a successful app-level evaluation.
        let status = keychain.delete(baseQuery(forKeyID: id))
        guard status == errSecSuccess else {
            snapshot.data.resetBytes(in: 0..<snapshot.data.count)
            throw KeychainOperationError(operation: .delete, status: status)
        }
        return snapshot
    }

    static func restoreDeletedKeyMaterial(
        _ token: DeletedKeyMaterial,
        keychain: KeychainClient = .live
    ) throws {
        try addKeyData(
            token.data,
            forKeyID: token.id,
            protectionAttributes: token.protectionAttributes,
            keychain: keychain
        )
    }

    /// Best-effortly clears the compensating copy once a surrounding metadata
    /// transaction has either committed or restored the Keychain item.
    static func discardDeletedKeyMaterial(_ token: inout DeletedKeyMaterial?) {
        guard var value = token else { return }
        value.data.resetBytes(in: 0..<value.data.count)
        token = nil
    }

    @discardableResult
    static func deleteKey(
        forKeyID id: UUID,
        authorization: BiometricAuthorization? = nil,
        keychain: KeychainClient = .live
    ) throws -> Bool {
        // Deletion is an explicit destructive action and does not require the
        // private bytes. Delete the exact row directly so OFF never becomes an
        // excuse to read protected material or present authentication merely
        // to discard it. The lifecycle journal makes failures retryable.
        _ = authorization
        let status = keychain.delete(baseQuery(forKeyID: id))
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw KeychainOperationError(operation: .delete, status: status)
        }
        return true
    }

    /// Idempotent cleanup for create/import when the following SwiftData save
    /// fails. A non-not-found Keychain failure remains visible to the caller.
    @discardableResult
    static func compensateFailedCreation(
        forKeyID id: UUID,
        keychain: KeychainClient = .live
    ) throws -> Bool {
        let status = keychain.delete(baseQuery(forKeyID: id))
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw KeychainOperationError(operation: .delete, status: status)
        }
        return true
    }

    /// Changes an existing software key's Keychain ACL. Secure Enclave ACLs
    /// are embedded in the hardware key and require rotation. If replacement
    /// fails, the old item is restored before the error is surfaced.
    static func updateProtection(
        forKeyID id: UUID,
        to protection: KeyProtection,
        isSecureEnclave: Bool,
        authorization: BiometricAuthorization? = nil,
        keychain: KeychainClient = .live
    ) throws {
        guard !isSecureEnclave else {
            throw KeyStoreError.secureEnclaveProtectionRequiresRotation
        }
        guard var old = try removeKeyMaterial(
            forKeyID: id,
            authorization: authorization,
            interactionNotAllowed: authorization == nil,
            keychain: keychain
        )
        else { throw KeyStoreError.privateMaterialMissing }
        defer { old.data.resetBytes(in: 0..<old.data.count) }

        do {
            try storeKeyData(
                old.data,
                forKeyID: id,
                protection: protection,
                deviceBound: false,
                keychain: keychain
            )
        } catch {
            do {
                try restoreDeletedKeyMaterial(old, keychain: keychain)
            } catch let compensationError {
                throw KeyStoreError.compensationFailed(
                    primary: error,
                    compensation: compensationError
                )
            }
            throw error
        }
    }

    /// Converts a legacy `WhenUnlockedThisDeviceOnly` software item to the
    /// migratable `WhenUnlocked` default. Returns false when no migration is
    /// needed. Protected items keep their ACL unchanged.
    @discardableResult
    static func migrateSoftwareKeyAccessibilityIfNeeded(
        forKeyID id: UUID,
        isSecureEnclave: Bool,
        keychain: KeychainClient = .live
    ) throws -> Bool {
        guard !isSecureEnclave else { return false }
        guard var snapshot = try keyMaterialSnapshot(forKeyID: id, keychain: keychain)
        else { throw KeyStoreError.privateMaterialMissing }
        defer { snapshot.data.resetBytes(in: 0..<snapshot.data.count) }
        guard snapshot.protectionAttributes[kSecAttrAccessControl as String] == nil,
              let accessibility = snapshot.protectionAttributes[
                kSecAttrAccessible as String
              ] as? String,
              accessibility == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        else { return false }

        try updateProtection(
            forKeyID: id,
            to: .deviceUnlocked,
            isSecureEnclave: false,
            keychain: keychain
        )
        return true
    }

    // MARK: - Keychain implementation

    private static func storeKeyData(
        _ data: Data,
        forKeyID id: UUID,
        protection: KeyProtection,
        deviceBound: Bool,
        keychain: KeychainClient
    ) throws {
        let accessibility = deviceBound
            ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            : kSecAttrAccessibleWhenUnlocked
        let attributes: [String: Any]
        switch protection {
        case .deviceUnlocked:
            attributes = [kSecAttrAccessible as String: accessibility]
        case .userPresence:
            attributes = [
                kSecAttrAccessControl as String: try makeAccessControl(
                    accessible: accessibility,
                    flags: .userPresence
                )
            ]
        }
        try addKeyData(
            data,
            forKeyID: id,
            protectionAttributes: attributes,
            keychain: keychain
        )
    }

    private static func addKeyData(
        _ data: Data,
        forKeyID id: UUID,
        protectionAttributes: [String: Any],
        keychain: KeychainClient
    ) throws {
        var attributes = baseQuery(forKeyID: id)
        attributes[kSecValueData as String] = data
        for (key, value) in protectionAttributes {
            attributes[key] = value
        }
        let status = keychain.add(attributes)
        guard status == errSecSuccess else {
            throw KeychainOperationError(operation: .add, status: status)
        }
    }

    private static func loadKeyData(
        forKeyID id: UUID,
        authorization: BiometricAuthorization? = nil,
        interactionNotAllowed: Bool = false,
        keychain: KeychainClient
    ) throws -> Data? {
        var query = baseQuery(forKeyID: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let authorization {
            query[kSecUseAuthenticationContext as String] = authorization.context
        } else if interactionNotAllowed {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        let (status, result) = keychain.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainOperationError(operation: .copy, status: status)
        }
        guard let data = result as? Data else {
            throw KeyStoreError.unexpectedKeychainResult
        }
        return data
    }

    private static func requiredKeyData(
        forKeyID id: UUID,
        authorization: BiometricAuthorization? = nil,
        interactionNotAllowed: Bool = false,
        keychain: KeychainClient
    ) throws -> Data {
        guard let data = try loadKeyData(
            forKeyID: id,
            authorization: authorization,
            interactionNotAllowed: interactionNotAllowed,
            keychain: keychain
        )
        else { throw KeyStoreError.privateMaterialMissing }
        return data
    }

    private static func keyMaterialSnapshot(
        forKeyID id: UUID,
        authorization: BiometricAuthorization? = nil,
        interactionNotAllowed: Bool = false,
        keychain: KeychainClient
    ) throws -> DeletedKeyMaterial? {
        var query = baseQuery(forKeyID: id)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let authorization {
            query[kSecUseAuthenticationContext as String] = authorization.context
        } else if interactionNotAllowed {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        let (status, result) = keychain.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainOperationError(operation: .copy, status: status)
        }
        guard let attributes = result as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data
        else { throw KeyStoreError.unexpectedKeychainResult }

        var protection: [String: Any] = [:]
        if let accessControl = attributes[kSecAttrAccessControl as String] {
            protection[kSecAttrAccessControl as String] = accessControl
        } else if let accessible = attributes[kSecAttrAccessible as String] {
            protection[kSecAttrAccessible as String] = accessible
        } else {
            throw KeyStoreError.unexpectedKeychainResult
        }
        return DeletedKeyMaterial(
            id: id,
            data: data,
            protectionAttributes: protection
        )
    }

    private static func baseQuery(forKeyID id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    private static func makeAccessControl(
        accessible: CFString,
        flags: SecAccessControlCreateFlags
    ) throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            accessible,
            flags,
            &error
        ) else {
            let reason = error.map { String(describing: $0.takeRetainedValue()) }
                ?? "unknown error"
            throw KeyStoreError.accessControlCreationFailed(reason)
        }
        return accessControl
    }

    private static func secureEnclaveFlags(
        for protection: KeyProtection
    ) -> SecAccessControlCreateFlags {
        switch protection {
        case .deviceUnlocked:
            return .privateKeyUsage
        case .userPresence:
            return [.privateKeyUsage, .userPresence]
        }
    }

    private static func parseRecoveryEd25519Key(
        pem: String,
        passphrase: String
    ) throws -> Curve25519.Signing.PrivateKey {
        do {
            guard try SSHKeyDetection.detectPrivateKeyType(from: pem) == .ed25519 else {
                throw RecoveryError.unsupportedAlgorithm
            }
            var decryptionKey = Data(passphrase.utf8)
            defer { decryptionKey.resetBytes(in: 0..<decryptionKey.count) }
            return try Curve25519.Signing.PrivateKey(
                sshEd25519: pem,
                decryptionKey: decryptionKey
            )
        } catch let error as RecoveryError {
            throw error
        } catch {
            throw KeyImportError.invalidPrivateKeyOrPassphrase
        }
    }

    // MARK: - Encrypted OpenSSH Ed25519 format

    /// Pure formatting seam used by tests with a known key. Salt/check values
    /// remain injectable without weakening production randomness.
    static func encryptedOpenSSHRepresentation(
        privateKey: Curve25519.Signing.PrivateKey,
        passphrase: String,
        comment: String,
        salt suppliedSalt: Data? = nil,
        check suppliedCheck: UInt32? = nil
    ) throws -> String {
        guard !passphrase.isEmpty else { throw RecoveryError.passphraseRequired }

        let salt = try suppliedSalt ?? secureRandomData(count: 16)
        guard salt.count == 16 else { throw RecoveryError.randomGenerationFailed(errSecParam) }
        let check = suppliedCheck ?? UInt32.random(in: .min ... .max)
        let rounds: UInt32 = 16

        var publicBlob = Data()
        publicBlob.appendSSHString("ssh-ed25519")
        publicBlob.appendSSHString(privateKey.publicKey.rawRepresentation)

        var privateBlob = Data()
        defer { privateBlob.resetBytes(in: 0..<privateBlob.count) }
        privateBlob.appendUInt32(check)
        privateBlob.appendUInt32(check)
        privateBlob.appendSSHString("ssh-ed25519")
        privateBlob.appendSSHString(privateKey.publicKey.rawRepresentation)
        var combinedPrivateKey = privateKey.rawRepresentation
        defer {
            combinedPrivateKey.resetBytes(in: 0..<combinedPrivateKey.count)
        }
        combinedPrivateKey.append(privateKey.publicKey.rawRepresentation)
        privateBlob.appendSSHString(combinedPrivateKey)

        // Citadel 0.12.1 incorrectly rejects a full 16-byte padding block.
        // A harmless trailing comment space avoids that parser edge while the
        // resulting file remains a standard OpenSSH key.
        var normalizedComment = comment
        var prospective = privateBlob
        defer { prospective.resetBytes(in: 0..<prospective.count) }
        prospective.appendSSHString(normalizedComment)
        if prospective.count.isMultiple(of: 16) {
            normalizedComment.append(" ")
        }
        privateBlob.appendSSHString(normalizedComment)
        let paddingCount = 16 - (privateBlob.count % 16)
        privateBlob.append(contentsOf: (1...paddingCount).map(UInt8.init))

        var kdfOptions = Data()
        kdfOptions.appendSSHString(salt)
        kdfOptions.appendUInt32(rounds)

        var passphraseData = Data(passphrase.utf8)
        defer { passphraseData.resetBytes(in: 0..<passphraseData.count) }
        var derived = try deriveOpenSSHKey(
            passphrase: passphraseData,
            salt: salt,
            rounds: rounds,
            outputCount: 48
        )
        defer { derived.resetBytes(in: 0..<derived.count) }
        var encryptionKey = Data(derived.prefix(32))
        var encryptionIV = Data(derived.suffix(16))
        defer {
            encryptionKey.resetBytes(in: 0..<encryptionKey.count)
            encryptionIV.resetBytes(in: 0..<encryptionIV.count)
        }
        let encrypted = try aes256CTR(
            privateBlob,
            key: encryptionKey,
            iv: encryptionIV
        )

        var payload = Data("openssh-key-v1\0".utf8)
        payload.appendSSHString("aes256-ctr")
        payload.appendSSHString("bcrypt")
        payload.appendSSHString(kdfOptions)
        payload.appendUInt32(1)
        payload.appendSSHString(publicBlob)
        payload.appendSSHString(encrypted)

        let base64 = payload.base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 70).map { offset in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(
                start,
                offsetBy: min(70, base64.count - offset)
            )
            return String(base64[start..<end])
        }
        return (["-----BEGIN OPENSSH PRIVATE KEY-----"] + lines + [
            "-----END OPENSSH PRIVATE KEY-----",
            "",
        ]).joined(separator: "\n")
    }

    private static let initializeBCryptSHA512: Void = {
        citadel_set_crypto_hash_sha512 { output, input, inputLength in
            guard let output, let input else { return }
            let bytes = UnsafeRawBufferPointer(
                start: input,
                count: Int(inputLength)
            )
            let digest = SHA512.hash(data: Data(bytes))
            digest.withUnsafeBytes { digestBytes in
                output.update(
                    from: digestBytes.bindMemory(to: UInt8.self).baseAddress!,
                    count: SHA512.Digest.byteCount
                )
            }
        }
    }()

    private static func deriveOpenSSHKey(
        passphrase: Data,
        salt: Data,
        rounds: UInt32,
        outputCount: Int
    ) throws -> Data {
        _ = initializeBCryptSHA512
        var output = Data(count: outputCount)
        let status = passphrase.withUnsafeBytes { passphraseBytes in
            salt.withUnsafeBytes { saltBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    citadel_bcrypt_pbkdf(
                        passphraseBytes.bindMemory(to: UInt8.self).baseAddress!,
                        passphraseBytes.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress!,
                        saltBytes.count,
                        outputBytes.bindMemory(to: UInt8.self).baseAddress!,
                        outputCount,
                        rounds
                    )
                }
            }
        }
        guard status == 0 else { throw RecoveryError.keyDerivationFailed }
        return output
    }

    private static func aes256CTR(
        _ plaintext: Data,
        key: Data,
        iv: Data
    ) throws -> Data {
        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBytes.baseAddress,
                    keyBytes.baseAddress,
                    keyBytes.count,
                    nil,
                    0,
                    0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }
        guard createStatus == kCCSuccess, let cryptor else {
            throw RecoveryError.encryptionFailed(createStatus)
        }
        defer { CCCryptorRelease(cryptor) }

        var ciphertext = Data(count: plaintext.count)
        var moved = 0
        let updateStatus = plaintext.withUnsafeBytes { plaintextBytes in
            ciphertext.withUnsafeMutableBytes { ciphertextBytes in
                CCCryptorUpdate(
                    cryptor,
                    plaintextBytes.baseAddress,
                    plaintextBytes.count,
                    ciphertextBytes.baseAddress,
                    ciphertextBytes.count,
                    &moved
                )
            }
        }
        guard updateStatus == kCCSuccess, moved == plaintext.count else {
            throw RecoveryError.encryptionFailed(updateStatus)
        }
        return ciphertext
    }

    private static func secureRandomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw RecoveryError.randomGenerationFailed(status)
        }
        return data
    }

    // MARK: - Public key formatting

    static func ed25519AuthorizedKeysLine(
        publicKey: Curve25519.Signing.PublicKey,
        comment: String
    ) -> String {
        let algorithm = "ssh-ed25519"
        var wireData = Data()
        wireData.appendSSHString(algorithm)
        wireData.appendSSHString(publicKey.rawRepresentation)
        return "\(algorithm) \(wireData.base64EncodedString()) \(comment)"
    }

    static func p256AuthorizedKeysLine(
        publicKey: P256.Signing.PublicKey,
        comment: String
    ) -> String {
        let algorithm = "ecdsa-sha2-nistp256"
        var wireData = Data()
        wireData.appendSSHString(algorithm)
        wireData.appendSSHString("nistp256")
        wireData.appendSSHString(publicKey.x963Representation)
        return "\(algorithm) \(wireData.base64EncodedString()) \(comment)"
    }

    private static func openSSHFingerprint(_ publicBlob: Data) -> String {
        let digest = SHA256.hash(data: publicBlob)
        return "SHA256:" + Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendSSHString(_ string: String) {
        appendSSHString(Data(string.utf8))
    }

    mutating func appendSSHString(_ data: Data) {
        appendUInt32(UInt32(data.count))
        append(data)
    }

    mutating func appendSSHString(_ data: some ContiguousBytes) {
        appendSSHString(data.withUnsafeBytes { Data($0) })
    }
}
