import XCTest
import Crypto
import Security
import LocalAuthentication
import NIOEmbedded
import NIOSSH
@testable import Tessera

final class KeyStoreSecurityTests: XCTestCase {
    func test_newKeyProtectionDefaultsFollowExplicitGlobalPreference() {
        XCTAssertFalse(
            KeyOwnerPresencePolicy.initialKeyPreference(globalPreference: false)
        )
        XCTAssertTrue(
            KeyOwnerPresencePolicy.initialKeyPreference(globalPreference: true)
        )
    }

    func test_protectionChangePreauthorizesBothProtectedReadsAndEnableRollback() {
        XCTAssertTrue(
            KeyOwnerPresencePolicy.requiresAuthorizationForProtectionChange(
                currentBoundary: .userPresence,
                enabling: false
            )
        )
        XCTAssertTrue(
            KeyOwnerPresencePolicy.requiresAuthorizationForProtectionChange(
                currentBoundary: .deviceUnlocked(deviceOnly: false),
                enabling: true
            )
        )
        XCTAssertFalse(
            KeyOwnerPresencePolicy.requiresAuthorizationForProtectionChange(
                currentBoundary: .deviceUnlocked(deviceOnly: false),
                enabling: false
            )
        )
    }

    // On physical devices a user-presence ACL can gate even the non-secret
    // attributes read. The refusal must classify as presence protection so
    // integrity reports "authentication required" (not unavailable) and the
    // protection toggle can start its authorized rewrite instead of failing
    // with "User interaction is not allowed".
    func test_aclGatedAttributeReadClassifiesAsUserPresence() throws {
        let keychain = InMemoryKeychain()
        let stored = try KeyStore.generateEd25519(
            name: "gated",
            context: (),
            protection: .userPresence,
            keychain: keychain.client
        )
        keychain.copyStatus = errSecInteractionNotAllowed

        XCTAssertEqual(
            try KeyStore.materialProtection(
                forKeyID: stored.id,
                keychain: keychain.client
            ),
            .userPresence
        )
        XCTAssertEqual(
            KeyStore.privateMaterialIntegrity(
                forKeyID: stored.id,
                algorithm: .ed25519,
                isSecureEnclave: false,
                expectedAuthorizedKeysLine: stored.authorizedKeysLine,
                keychain: keychain.client
            ),
            .authenticationRequired
        )
    }

    func test_keyOwnerPresencePolicyPreservesOffPreferenceAgainstStaleBoundary() {
        XCTAssertFalse(
            KeyOwnerPresencePolicy.reconciledKeyPreference(
                currentPreference: false,
                isSecureEnclave: false,
                boundaryProtection: .userPresence
            )
        )
        XCTAssertFalse(
            KeyOwnerPresencePolicy.isRequired(
                globalPreference: false,
                keyPreference: false,
                boundaryProtection: .userPresence
            )
        )
    }

    func test_reconciliationNeverOverwritesSecureEnclaveIntent() {
        XCTAssertTrue(
            KeyOwnerPresencePolicy.reconciledKeyPreference(
                currentPreference: true,
                isSecureEnclave: true,
                boundaryProtection: .deviceUnlocked
            )
        )
        XCTAssertFalse(
            KeyOwnerPresencePolicy.reconciledKeyPreference(
                currentPreference: false,
                isSecureEnclave: true,
                boundaryProtection: .userPresence
            )
        )
    }

    func test_actualBoundaryOverridesStaleMetadataForEffectivePolicy() throws {
        let suite = "KeyStoreSecurityTests.actual-boundary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = KeySecurityMetadataStore(defaults: defaults, storageKey: "m")
        let keychain = InMemoryKeychain()
        let unlocked = try KeyStore.generateEd25519(
            name: "unlocked",
            context: (),
            protection: .deviceUnlocked,
            keychain: keychain.client
        )
        metadata.markBoundaryProtection(.userPresence, for: unlocked.id)

        XCTAssertFalse(
            KeyOwnerPresencePolicy.isRequired(
                globalPreference: false,
                key: unlocked,
                metadata: metadata,
                keychain: keychain.client
            )
        )

        let protected = try KeyStore.generateEd25519(
            name: "protected",
            context: (),
            protection: .userPresence,
            keychain: keychain.client
        )
        metadata.markBoundaryProtection(.deviceUnlocked, for: protected.id)
        XCTAssertFalse(
            KeyOwnerPresencePolicy.isRequired(
                globalPreference: false,
                key: protected,
                metadata: metadata,
                keychain: keychain.client
            )
        )
    }

    func test_authorizedProtectionRewriteDoesNotPassContextToDelete() throws {
        let keychain = InMemoryKeychain()
        keychain.rejectsDeleteAuthenticationContext = true
        let stored = try KeyStore.generateEd25519(
            name: "rewrite",
            context: (),
            protection: .userPresence,
            keychain: keychain.client
        )
        let authorization = BiometricAuthorization(context: LAContext())

        try KeyStore.updateProtection(
            forKeyID: stored.id,
            to: .deviceUnlocked,
            isSecureEnclave: false,
            authorization: authorization,
            keychain: keychain.client
        )

        XCTAssertFalse(keychain.sawDeleteAuthenticationContext)
        XCTAssertEqual(
            try KeyStore.materialProtection(
                forKeyID: stored.id,
                keychain: keychain.client
            ),
            .deviceUnlocked(deviceOnly: false)
        )
    }

    func test_protectionRewriteWithoutAuthorizationForbidsRawKeychainPrompt() throws {
        let keychain = InMemoryKeychain()
        let stored = try KeyStore.generateEd25519(
            name: "no-prompt-rewrite",
            context: (),
            protection: .userPresence,
            keychain: keychain.client
        )
        keychain.enforcesUserPresenceForProtectedData = true

        XCTAssertThrowsError(
            try KeyStore.updateProtection(
                forKeyID: stored.id,
                to: .deviceUnlocked,
                isSecureEnclave: false,
                keychain: keychain.client
            )
        ) { error in
            XCTAssertEqual(
                error as? KeychainOperationError,
                KeychainOperationError(
                    operation: .copy,
                    status: errSecInteractionNotAllowed
                )
            )
        }
        XCTAssertTrue(keychain.sawInteractionNotAllowedContext)
        XCTAssertEqual(
            try KeyStore.materialProtection(
                forKeyID: stored.id,
                keychain: keychain.client
            ),
            .userPresence
        )
    }

    func test_unattendedDeletionDoesNotReadPrivateMaterial() throws {
        let keychain = InMemoryKeychain()
        let stored = try KeyStore.generateEd25519(
            name: "pending-delete",
            context: (),
            protection: .deviceUnlocked,
            keychain: keychain.client
        )

        XCTAssertTrue(
            try KeyStore.deleteKey(
                forKeyID: stored.id,
                keychain: keychain.client
            )
        )
        XCTAssertFalse(keychain.sawInteractionNotAllowedContext)
        XCTAssertTrue(keychain.items.isEmpty)
    }

    func test_protectedDeletionDoesNotAuthenticateOrReadPrivateMaterial() throws {
        let keychain = InMemoryKeychain()
        let stored = try KeyStore.generateEd25519(
            name: "protected-pending-delete",
            context: (),
            protection: .userPresence,
            keychain: keychain.client
        )
        keychain.enforcesUserPresenceForProtectedData = true

        XCTAssertTrue(
            try KeyStore.deleteKey(
                forKeyID: stored.id,
                keychain: keychain.client
            )
        )
        XCTAssertFalse(keychain.sawInteractionNotAllowedContext)
        XCTAssertTrue(keychain.items.isEmpty)
    }

    func test_authMethodWithoutAuthorizationForbidsRawKeychainPrompt() async throws {
        let keychain = InMemoryKeychain()
        let stored = try KeyStore.generateEd25519(
            name: "no-prompt",
            context: (),
            protection: .userPresence,
            keychain: keychain.client
        )
        keychain.enforcesUserPresenceForProtectedData = true

        do {
            _ = try await KeyStore.authMethod(
                forKeyID: stored.id,
                algorithm: .ed25519,
                username: "alice",
                keychain: keychain.client
            )
            XCTFail("protected material unexpectedly loaded without authorization")
        } catch let error as KeychainOperationError {
            XCTAssertEqual(error.operation, .copy)
            XCTAssertEqual(error.status, errSecInteractionNotAllowed)
        }
        XCTAssertTrue(keychain.sawInteractionNotAllowedContext)
    }

    func test_exportWithoutAuthorizationForbidsRawKeychainPrompt() throws {
        let keychain = InMemoryKeychain()
        let stored = try KeyStore.generateEd25519(
            name: "no-prompt-export",
            context: (),
            protection: .userPresence,
            keychain: keychain.client
        )
        keychain.enforcesUserPresenceForProtectedData = true

        XCTAssertThrowsError(
            try KeyStore.exportEncryptedEd25519PrivateKey(
                forKeyID: stored.id,
                passphrase: "backup passphrase",
                comment: stored.name,
                keychain: keychain.client
            )
        ) { error in
            XCTAssertEqual(
                error as? KeychainOperationError,
                KeychainOperationError(
                    operation: .copy,
                    status: errSecInteractionNotAllowed
                )
            )
        }
        XCTAssertTrue(keychain.sawInteractionNotAllowedContext)
    }

    func test_keyOwnerPresencePolicyRequiresBothUserControls() {
        XCTAssertFalse(
            KeyOwnerPresencePolicy.isRequired(
                globalPreference: true,
                keyPreference: false,
                boundaryProtection: .deviceUnlocked
            )
        )
        XCTAssertFalse(
            KeyOwnerPresencePolicy.isRequired(
                globalPreference: false,
                keyPreference: false,
                boundaryProtection: .deviceUnlocked
            )
        )
        XCTAssertTrue(
            KeyOwnerPresencePolicy.isRequired(
                globalPreference: true,
                keyPreference: true,
                boundaryProtection: .deviceUnlocked
            )
        )
        XCTAssertFalse(
            KeyOwnerPresencePolicy.isRequired(
                globalPreference: false,
                keyPreference: true,
                boundaryProtection: .userPresence
            )
        )
    }

    @MainActor
    func test_staleBoundaryRollbackRestoresActualProtectionInsteadOfPreference() {
        let harness = LifecyclePersistenceHarness()
        harness.failingBoundary = .protection
        let key = StoredKey(requiresBiometric: false)
        var applied: [KeyStore.KeyProtection] = []

        XCTAssertThrowsError(
            try StoredKeyLifecycle.updateProtection(
                for: key,
                enabled: false,
                persistence: harness.persistence,
                applyBoundary: { applied.append($0) },
                inspectBoundary: { .userPresence }
            )
        )

        XCTAssertEqual(applied, [.deviceUnlocked, .userPresence])
        XCTAssertFalse(key.requiresBiometric)
    }

    @MainActor
    func test_disablingOwnerPresenceRewritesBoundaryBeforePersistingOff() throws {
        let harness = LifecyclePersistenceHarness()
        let key = StoredKey(requiresBiometric: true)
        var applied: [KeyStore.KeyProtection] = []

        try StoredKeyLifecycle.updateProtection(
            for: key,
            enabled: false,
            persistence: harness.persistence,
            applyBoundary: { applied.append($0) },
            inspectBoundary: { .userPresence }
        )

        XCTAssertEqual(applied, [.deviceUnlocked])
        XCTAssertFalse(key.requiresBiometric)
        XCTAssertEqual(harness.saveAttempts, [.protection])
        XCTAssertEqual(harness.rollbackCount, 0)
    }

    @MainActor
    func test_authenticatedDisableLeavesSameKeyUsableWithoutAuthorization() async throws {
        let keychain = InMemoryKeychain()
        keychain.enforcesUserPresenceForProtectedData = true
        let key = try KeyStore.generateEd25519(
            name: "reversible",
            context: (),
            protection: .userPresence,
            keychain: keychain.client
        )
        // Physical iOS can return an unconstrained access-control object for
        // the prompt-free replacement. The complete OFF transaction must not
        // mistake that normalized representation for a surviving ACL.
        keychain.normalizesAccessibleItemsToAccessControl = true
        key.requiresBiometric = true
        let harness = LifecyclePersistenceHarness(keys: [key])
        let authorization = BiometricAuthorization(context: LAContext())

        try StoredKeyLifecycle.updateProtection(
            for: key,
            enabled: false,
            persistence: harness.persistence,
            applyBoundary: { protection in
                try KeyStore.updateProtection(
                    forKeyID: key.id,
                    to: protection,
                    isSecureEnclave: false,
                    authorization: authorization,
                    keychain: keychain.client
                )
            },
            inspectBoundary: {
                try KeyStore.materialProtection(
                    forKeyID: key.id,
                    keychain: keychain.client
                )
            }
        )

        keychain.sawInteractionNotAllowedContext = false
        let method = try await KeyStore.authMethod(
            forKeyID: key.id,
            algorithm: .ed25519,
            username: "tester",
            keychain: keychain.client
        )

        XCTAssertNotNil(method)
        XCTAssertTrue(keychain.sawInteractionNotAllowedContext)
        XCTAssertFalse(key.requiresBiometric)
        XCTAssertEqual(
            try KeyStore.materialProtection(
                forKeyID: key.id,
                keychain: keychain.client
            ),
            .deviceUnlocked(deviceOnly: false)
        )
    }

    func test_boundaryMetadataOverwriteReplacesStaleProtection() throws {
        let suite = "KeyStoreSecurityTests.recovery-boundary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = KeySecurityMetadataStore(defaults: defaults, storageKey: "m")
        let keyID = UUID()

        metadata.markBoundaryProtection(.userPresence, for: keyID)
        metadata.markBoundaryProtection(.deviceUnlocked, for: keyID)

        XCTAssertEqual(
            metadata.record(for: keyID).boundaryProtection,
            .deviceUnlocked
        )
    }

    fileprivate enum InjectedFailure: Error {
        case save(KeyLifecycleSaveBoundary)
        case boundaryRollback
        case keychainDelete
    }

    func test_encryptedOpenSSHEd25519_roundTripsWithCorrectPassphrase() throws {
        let original = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(0..<32)
        )
        let pem = try KeyStore.encryptedOpenSSHRepresentation(
            privateKey: original,
            passphrase: "correct horse battery staple",
            comment: "roundtrip@test",
            salt: Data(repeating: 0xA5, count: 16),
            check: 0x1234_5678
        )
        XCTAssertTrue(pem.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        let recovered = try Curve25519.Signing.PrivateKey(
            sshEd25519: pem,
            decryptionKey: Data("correct horse battery staple".utf8)
        )
        XCTAssertEqual(recovered.rawRepresentation, original.rawRepresentation)

        let fingerprint = try KeyStore.recoveryFingerprint(
            data: Data(pem.utf8),
            passphrase: "correct horse battery staple"
        )
        XCTAssertEqual(
            fingerprint,
            KeyStore.fingerprint(
                forAuthorizedKeysLine: KeyStore.ed25519AuthorizedKeysLine(
                    publicKey: original.publicKey,
                    comment: ""
                )
            )
        )
        let stored = StoredKey(
            authorizedKeysLine: KeyStore.ed25519AuthorizedKeysLine(
                publicKey: original.publicKey,
                comment: "roundtrip@test"
            )
        )
        XCTAssertEqual(stored.canonicalFingerprint, fingerprint)
        XCTAssertFalse(stored.canonicalFingerprint.hasSuffix("="))
    }

    func test_encryptedSourceImportAcceptsCorrectPassphrase() throws {
        let original = Curve25519.Signing.PrivateKey()
        let pem = try KeyStore.encryptedOpenSSHRepresentation(
            privateKey: original,
            passphrase: "source password",
            comment: "encrypted-import",
            salt: Data(repeating: 0x44, count: 16),
            check: 0xAA55_AA55
        )
        let keychain = InMemoryKeychain()

        let imported = try KeyStore.importKey(
            data: Data(pem.utf8),
            passphrase: "source password",
            name: "imported",
            keychain: keychain.client
        )

        XCTAssertEqual(imported.algorithm, .ed25519)
        XCTAssertEqual(
            try KeyStore.privateMaterialFingerprint(
                forKeyID: imported.id,
                algorithm: imported.algorithm,
                keychain: keychain.client
            ),
            KeyStore.canonicalFingerprint(
                forAuthorizedKeysLine: imported.authorizedKeysLine
            )
        )
    }

    func test_encryptedSourceImportRejectsWrongPassphraseBeforeKeychainMutation() throws {
        let pem = try KeyStore.encryptedOpenSSHRepresentation(
            privateKey: Curve25519.Signing.PrivateKey(),
            passphrase: "right source password",
            comment: "encrypted-import",
            salt: Data(repeating: 0x22, count: 16),
            check: 0x1234_1234
        )
        let keychain = InMemoryKeychain()

        XCTAssertThrowsError(
            try KeyStore.importKey(
                data: Data(pem.utf8),
                passphrase: "wrong source password",
                name: "must fail",
                keychain: keychain.client
            )
        ) { error in
            XCTAssertEqual(
                error as? KeyStore.KeyImportError,
                .invalidPrivateKeyOrPassphrase
            )
        }
        XCTAssertTrue(keychain.items.isEmpty)
    }

    func test_encryptedOpenSSHEd25519_rejectsWrongPassphraseSafely() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let pem = try KeyStore.encryptedOpenSSHRepresentation(
            privateKey: privateKey,
            passphrase: "right passphrase",
            comment: "test",
            salt: Data(repeating: 7, count: 16),
            check: 42
        )

        XCTAssertThrowsError(
            try KeyStore.recoveryFingerprint(
                data: Data(pem.utf8),
                passphrase: "wrong passphrase"
            )
        ) { error in
            XCTAssertEqual(
                error as? KeyStore.KeyImportError,
                .invalidPrivateKeyOrPassphrase
            )
            XCTAssertFalse(error.localizedDescription.contains("wrong passphrase"))
        }
    }

    func test_recoveryRestoresMatchingMaterialUnderExistingUUID() throws {
        let keychain = InMemoryKeychain()
        let privateKey = Curve25519.Signing.PrivateKey()
        let pem = try KeyStore.encryptedOpenSSHRepresentation(
            privateKey: privateKey,
            passphrase: "recovery passphrase",
            comment: "test",
            salt: Data(repeating: 9, count: 16),
            check: 99
        )
        let id = UUID()
        let expected = KeyStore.fingerprint(
            forAuthorizedKeysLine: KeyStore.ed25519AuthorizedKeysLine(
                publicKey: privateKey.publicKey,
                comment: ""
            )
        )

        let recovered = try KeyStore.recoverEd25519Key(
            data: Data(pem.utf8),
            passphrase: "recovery passphrase",
            forKeyID: id,
            expectedFingerprint: expected,
            keychain: keychain.client
        )

        XCTAssertEqual(recovered, expected)
        XCTAssertTrue(
            try KeyStore.hasPrivateMaterial(
                forKeyID: id,
                keychain: keychain.client
            )
        )
        XCTAssertTrue(
            try KeyStore.verifyPrivateMaterial(
                forKeyID: id,
                algorithm: .ed25519,
                expectedFingerprint: expected,
                keychain: keychain.client
            )
        )
    }

    func test_recoveryRejectsFingerprintMismatchBeforeKeychainMutation() throws {
        let keychain = InMemoryKeychain()
        let privateKey = Curve25519.Signing.PrivateKey()
        let pem = try KeyStore.encryptedOpenSSHRepresentation(
            privateKey: privateKey,
            passphrase: "recovery passphrase",
            comment: "test",
            salt: Data(repeating: 3, count: 16),
            check: 3
        )
        let id = UUID()

        XCTAssertThrowsError(
            try KeyStore.recoverEd25519Key(
                data: Data(pem.utf8),
                passphrase: "recovery passphrase",
                forKeyID: id,
                expectedFingerprint: "SHA256:not-the-key",
                keychain: keychain.client
            )
        ) { error in
            guard case .fingerprintMismatch = error as? KeyStore.RecoveryError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(
            try KeyStore.hasPrivateMaterial(
                forKeyID: id,
                keychain: keychain.client
            )
        )
    }

    func test_recoveryRepairsMismatchedMaterialUnderExistingUUID() throws {
        let keychain = InMemoryKeychain()
        let wrong = try KeyStore.generateEd25519(
            name: "wrong",
            context: (),
            keychain: keychain.client
        )
        let expectedKey = Curve25519.Signing.PrivateKey()
        let expectedLine = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: expectedKey.publicKey,
            comment: "expected"
        )
        let pem = try KeyStore.encryptedOpenSSHRepresentation(
            privateKey: expectedKey,
            passphrase: "repair passphrase",
            comment: "expected",
            salt: Data(repeating: 8, count: 16),
            check: 8
        )

        XCTAssertEqual(
            KeyStore.privateMaterialIntegrity(
                forKeyID: wrong.id,
                algorithm: .ed25519,
                expectedAuthorizedKeysLine: expectedLine,
                keychain: keychain.client
            ),
            .mismatched
        )

        try KeyStore.recoverEd25519Key(
            data: Data(pem.utf8),
            passphrase: "repair passphrase",
            forKeyID: wrong.id,
            expectedFingerprint: KeyStore.canonicalFingerprint(
                forAuthorizedKeysLine: expectedLine
            ),
            keychain: keychain.client
        )

        XCTAssertEqual(
            KeyStore.privateMaterialIntegrity(
                forKeyID: wrong.id,
                algorithm: .ed25519,
                expectedAuthorizedKeysLine: expectedLine,
                keychain: keychain.client
            ),
            .valid
        )
    }

    func test_nonInteractiveIntegrityDoesNotPromptForProtectedMaterial() throws {
        let keychain = InMemoryKeychain()
        let stored = try KeyStore.generateEd25519(
            name: "protected",
            context: (),
            protection: .userPresence,
            keychain: keychain.client
        )
        keychain.dataCopyStatus = errSecInteractionNotAllowed

        XCTAssertEqual(
            KeyStore.privateMaterialIntegrity(
                forKeyID: stored.id,
                algorithm: stored.algorithm,
                expectedAuthorizedKeysLine: stored.authorizedKeysLine,
                keychain: keychain.client
            ),
            .authenticationRequired
        )
        XCTAssertTrue(keychain.sawInteractionNotAllowedContext)
    }

    func test_attributesOnlyACLChallengeStillPermitsAuthenticationAttempt() throws {
        let keychain = InMemoryKeychain()
        let stored = try KeyStore.generateEd25519(
            name: "protected attributes",
            context: (),
            protection: .userPresence,
            keychain: keychain.client
        )
        // Physical iOS can gate even kSecReturnAttributes for an item whose
        // access control requires owner presence. This is evidence of a
        // protected exact-match item, not missing or corrupt key material.
        keychain.copyStatus = errSecInteractionNotAllowed

        let integrity = KeyStore.privateMaterialIntegrity(
            forKeyID: stored.id,
            algorithm: stored.algorithm,
            expectedAuthorizedKeysLine: stored.authorizedKeysLine,
            keychain: keychain.client
        )

        XCTAssertEqual(integrity, .authenticationRequired)
        XCTAssertTrue(integrity.permitsAuthenticationAttempt)
    }

    func test_mismatchedIntegrityClearsStaleBackupTruth() throws {
        let suite = "KeyStoreSecurityTests.metadata.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = KeySecurityMetadataStore(
            defaults: defaults,
            storageKey: "records"
        )
        let id = UUID()
        metadata.markBackupExported(
            for: id,
            fingerprint: "SHA256:expected",
            at: Date(timeIntervalSince1970: 1)
        )

        metadata.markMaterialIntegrity(.mismatched, for: id)

        XCTAssertNil(metadata.record(for: id).backupExportedAt)
        XCTAssertNil(metadata.record(for: id).backupFingerprint)
        XCTAssertEqual(metadata.record(for: id).materialIntegrity, .mismatched)
    }

    func test_generationCannotSucceedAfterKeychainAddFailure() {
        let keychain = InMemoryKeychain()
        keychain.addStatus = errSecInteractionNotAllowed

        XCTAssertThrowsError(
            try KeyStore.generateEd25519(
                name: "must fail",
                context: (),
                keychain: keychain.client
            )
        ) { error in
            XCTAssertEqual(
                error as? KeychainOperationError,
                KeychainOperationError(
                    operation: .add,
                    status: errSecInteractionNotAllowed
                )
            )
        }
        XCTAssertTrue(keychain.items.isEmpty)
    }

    func test_importCannotSucceedAfterKeychainAddFailure() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let pem = privateKey.makeSSHRepresentation(comment: "import")
        let keychain = InMemoryKeychain()
        keychain.addStatus = errSecDiskFull

        XCTAssertThrowsError(
            try KeyStore.importKey(
                pem: pem,
                passphrase: nil,
                name: "must fail",
                keychain: keychain.client
            )
        ) { error in
            XCTAssertEqual(
                error as? KeychainOperationError,
                KeychainOperationError(operation: .add, status: errSecDiskFull)
            )
        }
    }

    func test_softwareKeyDefaultIsMigratableButNotSynchronizable() throws {
        let keychain = InMemoryKeychain()
        _ = try KeyStore.generateEd25519(
            name: "migratable",
            context: (),
            keychain: keychain.client
        )
        let attributes = try XCTUnwrap(keychain.items.values.first)

        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlocked as String
        )
        XCTAssertNil(attributes[kSecAttrSynchronizable as String])
    }

    func test_userPresenceProtectionIsAppliedAtKeychainBoundary() throws {
        let keychain = InMemoryKeychain()
        _ = try KeyStore.generateEd25519(
            name: "protected",
            context: (),
            protection: .userPresence,
            keychain: keychain.client
        )
        let attributes = try XCTUnwrap(keychain.items.values.first)

        XCTAssertNotNil(attributes[kSecAttrAccessControl as String])
        XCTAssertNil(attributes[kSecAttrAccessible as String])
    }

    func test_removeAndRestoreTokenCompensatesDeletion() throws {
        let keychain = InMemoryKeychain()
        let stored = try KeyStore.generateEd25519(
            name: "compensate",
            context: (),
            keychain: keychain.client
        )
        let before = try KeyStore.privateMaterialFingerprint(
            forKeyID: stored.id,
            algorithm: .ed25519,
            keychain: keychain.client
        )

        let token = try XCTUnwrap(
            KeyStore.removeKeyMaterial(
                forKeyID: stored.id,
                keychain: keychain.client
            )
        )
        XCTAssertFalse(
            try KeyStore.hasPrivateMaterial(
                forKeyID: stored.id,
                keychain: keychain.client
            )
        )

        try KeyStore.restoreDeletedKeyMaterial(token, keychain: keychain.client)
        XCTAssertEqual(
            try KeyStore.privateMaterialFingerprint(
                forKeyID: stored.id,
                algorithm: .ed25519,
                keychain: keychain.client
            ),
            before
        )
    }

    func test_integrityReportDetectsMetadataOnlyAndOrphanedItemsWithoutData() throws {
        let keychain = InMemoryKeychain()
        let live = try KeyStore.generateEd25519(
            name: "live",
            context: (),
            keychain: keychain.client
        )
        let orphan = try KeyStore.generateEd25519(
            name: "orphan",
            context: (),
            keychain: keychain.client
        )
        let missing = UUID()

        let report = try KeyStore.integrityReport(
            metadataKeyIDs: [live.id, missing],
            keychain: keychain.client
        )

        XCTAssertEqual(report.metadataOnlyKeyIDs, Set([missing]))
        XCTAssertEqual(report.orphanedKeyIDs, Set([orphan.id]))
        XCTAssertEqual(report.invalidAccountCount, 0)
    }

    func test_materialProtectionIsDerivedFromKeychainAttributes() throws {
        let keychain = InMemoryKeychain()
        let stored = try KeyStore.generateEd25519(
            name: "protected",
            context: (),
            protection: .deviceUnlocked,
            keychain: keychain.client
        )

        XCTAssertEqual(
            try KeyStore.materialProtection(
                forKeyID: stored.id,
                keychain: keychain.client
            ),
            .deviceUnlocked(deviceOnly: false)
        )
    }

    func test_unconstrainedAccessControlDoesNotLookBiometricProtected() throws {
        let keychain = InMemoryKeychain()
        keychain.normalizesAccessibleItemsToAccessControl = true
        let stored = try KeyStore.generateEd25519(
            name: "normalized-unprotected",
            context: (),
            protection: .deviceUnlocked,
            keychain: keychain.client
        )

        XCTAssertNotNil(
            keychain.items[stored.id.uuidString]?[kSecAttrAccessControl as String]
        )
        XCTAssertEqual(
            try KeyStore.materialProtection(
                forKeyID: stored.id,
                keychain: keychain.client
            ),
            .deviceUnlocked(deviceOnly: false)
        )
        XCTAssertTrue(keychain.sawInteractionNotAllowedContext)
    }

    func test_RSAImportIsDisabledBeforeKeychainMutation() {
        let keychain = InMemoryKeychain()

        XCTAssertThrowsError(
            try KeyStore.importKey(
                pem: makeMinimalOpenSSHKey(type: "ssh-rsa"),
                passphrase: nil,
                name: "legacy rsa",
                keychain: keychain.client
            )
        ) { error in
            XCTAssertEqual(error as? KeyStore.KeyImportError, .rsaNotSupported)
        }
        XCTAssertTrue(keychain.items.isEmpty)
    }

    func test_passwordOperationsPreserveKeychainStatus() {
        let keychain = InMemoryKeychain()
        keychain.copyStatus = errSecNotAvailable

        XCTAssertThrowsError(
            try KeychainHelper.setPassword(
                "secret",
                forIdentityID: UUID(),
                keychain: keychain.client
            )
        ) { error in
            XCTAssertEqual(
                error as? KeychainOperationError,
                KeychainOperationError(operation: .copy, status: errSecNotAvailable)
            )
        }
    }

    func test_passwordUpdatePreservesKeychainStatus() throws {
        let keychain = InMemoryKeychain()
        let id = UUID()
        try KeychainHelper.setPassword(
            "first",
            forIdentityID: id,
            keychain: keychain.client
        )
        keychain.updateStatus = errSecInteractionNotAllowed

        XCTAssertThrowsError(
            try KeychainHelper.setPassword(
                "second",
                forIdentityID: id,
                keychain: keychain.client
            )
        ) { error in
            XCTAssertEqual(
                error as? KeychainOperationError,
                KeychainOperationError(
                    operation: .update,
                    status: errSecInteractionNotAllowed
                )
            )
        }
    }

    func test_passwordCredentialRevisionAdvancesAcrossRotationAndDeletion() throws {
        let keychain = InMemoryKeychain()
        let id = UUID()
        let before = KeychainHelper.passwordCredentialRevision

        try KeychainHelper.setPassword(
            "first",
            forIdentityID: id,
            keychain: keychain.client
        )
        let first = try KeychainHelper.passwordCredential(
            forIdentityID: id,
            keychain: keychain.client
        )
        XCTAssertEqual(first.password, "first")
        XCTAssertGreaterThan(first.revision, before)

        try KeychainHelper.setPassword(
            "second",
            forIdentityID: id,
            keychain: keychain.client
        )
        let second = try KeychainHelper.passwordCredential(
            forIdentityID: id,
            keychain: keychain.client
        )
        XCTAssertEqual(second.password, "second")
        XCTAssertGreaterThan(second.revision, first.revision)

        XCTAssertTrue(
            try KeychainHelper.deletePassword(
                forIdentityID: id,
                keychain: keychain.client
            )
        )
        XCTAssertGreaterThan(
            KeychainHelper.passwordCredentialRevision,
            second.revision
        )
    }

    func test_keyDeletionPreservesKeychainStatusAndMaterial() throws {
        let keychain = InMemoryKeychain()
        let stored = try KeyStore.generateEd25519(
            name: "delete failure",
            context: (),
            keychain: keychain.client
        )
        keychain.deleteStatus = errSecAuthFailed

        XCTAssertThrowsError(
            try KeyStore.removeKeyMaterial(
                forKeyID: stored.id,
                keychain: keychain.client
            )
        ) { error in
            XCTAssertEqual(
                error as? KeychainOperationError,
                KeychainOperationError(operation: .delete, status: errSecAuthFailed)
            )
        }
        XCTAssertTrue(
            try KeyStore.hasPrivateMaterial(
                forKeyID: stored.id,
                keychain: keychain.client
            )
        )
    }

    @MainActor
    func test_generationAndImportSaveBoundariesCompensateKeychainMaterial() {
        for boundary in [
            KeyLifecycleSaveBoundary.generation,
            KeyLifecycleSaveBoundary.keyImport,
        ] {
            let harness = LifecyclePersistenceHarness()
            harness.failingBoundary = boundary
            let key = StoredKey(name: boundary.rawValue)
            var compensatedIDs: [UUID] = []

            XCTAssertThrowsError(
                try StoredKeyLifecycle.persistCreatedKey(
                    key,
                    boundary: boundary,
                    persistence: harness.persistence,
                    compensate: { compensatedIDs.append($0) }
                )
            ) { error in
                guard case .creationPersistenceFailed(_, nil) =
                    error as? KeyLifecycleError else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
            XCTAssertEqual(harness.saveAttempts, [boundary])
            XCTAssertEqual(harness.rollbackCount, 1)
            XCTAssertEqual(compensatedIDs, [key.id])
        }
    }

    @MainActor
    func test_creationSaveFailureReportsCleanupFailureWithoutSuccess() {
        let harness = LifecyclePersistenceHarness()
        harness.failingBoundary = .generation

        XCTAssertThrowsError(
            try StoredKeyLifecycle.persistCreatedKey(
                StoredKey(name: "cleanup-failure"),
                boundary: .generation,
                persistence: harness.persistence,
                compensate: { _ in throw InjectedFailure.keychainDelete }
            )
        ) { error in
            guard case .creationPersistenceFailed(_, let cleanup?) =
                error as? KeyLifecycleError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(cleanup is InjectedFailure)
            XCTAssertTrue(error.localizedDescription.contains("No success was reported"))
        }
    }

    @MainActor
    func test_protectionSaveFailureChecksAndCompletesBoundaryRollback() {
        let harness = LifecyclePersistenceHarness()
        harness.failingBoundary = .protection
        let key = StoredKey(requiresBiometric: false)
        var applied: [KeyStore.KeyProtection] = []

        XCTAssertThrowsError(
            try StoredKeyLifecycle.updateProtection(
                for: key,
                enabled: true,
                persistence: harness.persistence,
                applyBoundary: { applied.append($0) },
                inspectBoundary: { .deviceUnlocked(deviceOnly: false) }
            )
        ) { error in
            guard case .protectionPersistenceFailed =
                error as? KeyLifecycleError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(applied, [.userPresence, .deviceUnlocked])
        XCTAssertEqual(harness.saveAttempts, [.protection])
        XCTAssertFalse(key.requiresBiometric)
    }

    @MainActor
    func test_protectionRollbackFailureReportsActualKeychainBoundary() throws {
        let suite = "KeyStoreSecurityTests.protection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = KeySecurityMetadataStore(defaults: defaults, storageKey: "m")
        let harness = LifecyclePersistenceHarness()
        harness.failingBoundary = .protection
        let key = StoredKey(requiresBiometric: false)
        var applyCount = 0

        XCTAssertThrowsError(
            try StoredKeyLifecycle.updateProtection(
                for: key,
                enabled: true,
                persistence: harness.persistence,
                metadata: metadata,
                applyBoundary: { _ in
                    applyCount += 1
                    if applyCount == 2 { throw InjectedFailure.boundaryRollback }
                },
                inspectBoundary: { .userPresence }
            )
        ) { error in
            guard case .protectionRollbackFailed(_, _, .userPresence?) =
                error as? KeyLifecycleError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(
                error.localizedDescription.contains("Face ID/Touch ID")
            )
        }
        // The failed transaction must not adopt the surviving ACL as the
        // user's preference. The boundary record explains why the key is
        // unavailable, but cannot manufacture permission to authenticate.
        XCTAssertFalse(key.requiresBiometric)
        XCTAssertEqual(
            metadata.record(for: key.id).boundaryProtection,
            .userPresence
        )
        XCTAssertFalse(
            KeyOwnerPresencePolicy.isRequired(
                globalPreference: false,
                keyPreference: key.requiresBiometric,
                boundaryProtection: metadata.record(for: key.id).boundaryProtection
            )
        )
    }

    @MainActor
    func test_protectionRollbackFailurePreservesOnPreferenceAgainstWeakerBoundary() throws {
        let suite = "KeyStoreSecurityTests.protection-on.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = KeySecurityMetadataStore(defaults: defaults, storageKey: "m")
        let harness = LifecyclePersistenceHarness()
        harness.failingBoundary = .protection
        let key = StoredKey(requiresBiometric: true)
        var applyCount = 0
        var inspected: [KeyStore.KeyMaterialProtection] = [
            .userPresence,
            .deviceUnlocked(deviceOnly: false),
        ]

        XCTAssertThrowsError(
            try StoredKeyLifecycle.updateProtection(
                for: key,
                enabled: false,
                persistence: harness.persistence,
                metadata: metadata,
                applyBoundary: { _ in
                    applyCount += 1
                    if applyCount == 2 { throw InjectedFailure.boundaryRollback }
                },
                inspectBoundary: { inspected.removeFirst() }
            )
        ) { error in
            guard case .protectionRollbackFailed(_, _, .deviceUnlocked?) =
                error as? KeyLifecycleError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        // The user's standing ON policy survives even though only the weaker
        // ACL remains, so the app-level gate still requires owner presence.
        XCTAssertTrue(key.requiresBiometric)
        XCTAssertEqual(
            metadata.record(for: key.id).boundaryProtection,
            .deviceUnlocked
        )
        XCTAssertTrue(
            KeyOwnerPresencePolicy.isRequired(
                globalPreference: true,
                keyPreference: key.requiresBiometric,
                boundaryProtection: metadata.record(for: key.id).boundaryProtection
            )
        )
    }

    @MainActor
    func test_deletionSaveFailureNeverTouchesKeychainAndClearsIntent() throws {
        let (journal, defaults, suite) = try makeDeletionJournal()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = StoredKey(name: "delete")
        let identity = Identity(credentialMode: .key(key.id))
        let harness = LifecyclePersistenceHarness(keys: [key], identities: [identity])
        harness.failingBoundary = .deletion
        var deletedMaterial = false

        XCTAssertThrowsError(
            try StoredKeyLifecycle.delete(
                key,
                persistence: harness.persistence,
                journal: journal,
                deleteMaterial: { _ in deletedMaterial = true }
            )
        )
        XCTAssertFalse(deletedMaterial)
        XCTAssertTrue(journal.intents().isEmpty)
        XCTAssertEqual(harness.saveAttempts, [.deletion])
    }

    @MainActor
    func test_deletionJournalResumesAfterCrashBoundaryWithoutSecrets() throws {
        let (journal, defaults, suite) = try makeDeletionJournal()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = StoredKey(
            name: "public-name",
            authorizedKeysLine: "ssh-ed25519 PUBLIC-BLOB public-comment"
        )
        let identity = Identity(credentialMode: .key(key.id))
        let harness = LifecyclePersistenceHarness(keys: [key], identities: [identity])

        XCTAssertThrowsError(
            try StoredKeyLifecycle.delete(
                key,
                persistence: harness.persistence,
                journal: journal,
                deleteMaterial: { _ in throw InjectedFailure.keychainDelete }
            )
        ) { error in
            guard case .deletionPending = error as? KeyLifecycleError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(identity.credentialMode, .none)
        XCTAssertTrue(harness.keys.isEmpty)
        XCTAssertEqual(journal.intents().map(\.keyID), [key.id])
        let journalText = String(
            data: try XCTUnwrap(defaults.data(forKey: "journal")),
            encoding: .utf8
        ) ?? ""
        XCTAssertFalse(journalText.contains("PUBLIC-BLOB"))
        XCTAssertFalse(journalText.contains("public-name"))

        var resumedDeletionIDs: [UUID] = []
        let report = StoredKeyLifecycle.reconcilePendingDeletions(
            persistence: harness.persistence,
            journal: journal,
            deleteMaterial: { resumedDeletionIDs.append($0) }
        )
        XCTAssertEqual(report, .init(completed: 1, failed: 0))
        XCTAssertEqual(resumedDeletionIDs, [key.id])
        XCTAssertTrue(journal.intents().isEmpty)
    }

    @MainActor
    func test_deletionRecoverySaveFailureLeavesIntentAndMaterialUntouched() throws {
        let (journal, defaults, suite) = try makeDeletionJournal()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = StoredKey(name: "pending")
        let identity = Identity(credentialMode: .key(key.id))
        let harness = LifecyclePersistenceHarness(keys: [key], identities: [identity])
        harness.failingBoundary = .deletionRecovery
        try journal.begin(keyID: key.id, at: Date(timeIntervalSince1970: 10))
        var deletedMaterial = false

        let report = StoredKeyLifecycle.reconcilePendingDeletions(
            persistence: harness.persistence,
            journal: journal,
            deleteMaterial: { _ in deletedMaterial = true }
        )

        XCTAssertEqual(report, .init(completed: 0, failed: 1))
        XCTAssertFalse(deletedMaterial)
        XCTAssertEqual(journal.intents().map(\.keyID), [key.id])
        XCTAssertEqual(harness.saveAttempts, [.deletionRecovery])
    }

    func test_oneShotAuthDelegateDropsSoftwarePrivateKeyAfterOffer() throws {
        let delegate = OneShotSoftwareKeyAuthDelegate(
            username: "alice",
            key: .ed25519(Curve25519.Signing.PrivateKey())
        )
        XCTAssertTrue(delegate.retainsPrivateKey)

        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(
            availableMethods: [.publicKey],
            nextChallengePromise: promise
        )

        XCTAssertFalse(delegate.retainsPrivateKey)
        XCTAssertNotNil(try promise.futureResult.wait())
    }

    private func makeMinimalOpenSSHKey(type: String) -> String {
        var publicBlob = Data()
        publicBlob.appendTestSSHString(type)

        var payload = Data("openssh-key-v1\0".utf8)
        payload.appendTestSSHString("none")
        payload.appendTestSSHString("none")
        payload.appendTestSSHString(Data())
        payload.appendTestUInt32(1)
        payload.appendTestSSHString(publicBlob)
        payload.appendTestSSHString(Data())

        return """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(payload.base64EncodedString())
        -----END OPENSSH PRIVATE KEY-----
        """
    }

    private func makeDeletionJournal() throws -> (
        KeyDeletionIntentStore,
        UserDefaults,
        String
    ) {
        let suite = "KeyStoreSecurityTests.deletion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (
            KeyDeletionIntentStore(defaults: defaults, storageKey: "journal"),
            defaults,
            suite
        )
    }
}

private final class InMemoryKeychain {
    var items: [String: [String: Any]] = [:]
    var presenceProtectedAccounts: Set<String> = []
    var addStatus: OSStatus = errSecSuccess
    var copyStatus: OSStatus?
    var dataCopyStatus: OSStatus?
    var updateStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess
    var sawInteractionNotAllowedContext = false
    var sawDeleteAuthenticationContext = false
    var enforcesUserPresenceForProtectedData = false
    var rejectsDeleteAuthenticationContext = false
    var normalizesAccessibleItemsToAccessControl = false

    lazy var client = KeychainClient(
        add: { [unowned self] attributes in
            guard self.addStatus == errSecSuccess else { return self.addStatus }
            guard let account = attributes[kSecAttrAccount as String] as? String
            else { return errSecParam }
            guard self.items[account] == nil else { return errSecDuplicateItem }
            let requiresPresence = attributes[kSecAttrAccessControl as String] != nil
            var storedAttributes = attributes
            if self.normalizesAccessibleItemsToAccessControl,
               attributes[kSecAttrAccessControl as String] == nil,
               attributes[kSecAttrAccessible as String] != nil {
                var error: Unmanaged<CFError>?
                guard let accessControl = SecAccessControlCreateWithFlags(
                    nil,
                    kSecAttrAccessibleWhenUnlocked,
                    [],
                    &error
                ) else { return errSecParam }
                storedAttributes[kSecAttrAccessControl as String] = accessControl
            }
            self.items[account] = storedAttributes
            if requiresPresence {
                self.presenceProtectedAccounts.insert(account)
            } else {
                self.presenceProtectedAccounts.remove(account)
            }
            return errSecSuccess
        },
        update: { [unowned self] query, changes in
            guard self.updateStatus == errSecSuccess else { return self.updateStatus }
            guard let account = query[kSecAttrAccount as String] as? String,
                  var item = self.items[account]
            else { return errSecItemNotFound }
            for (key, value) in changes { item[key] = value }
            self.items[account] = item
            if changes[kSecAttrAccessControl as String] != nil {
                self.presenceProtectedAccounts.insert(account)
            } else if changes[kSecAttrAccessible as String] != nil {
                self.presenceProtectedAccounts.remove(account)
            }
            return errSecSuccess
        },
        copyMatching: { [unowned self] query in
            if let status = self.copyStatus { return (status, nil) }
            let wantsData = query[kSecReturnData as String] as? Bool == true
            let wantsAttributes = query[kSecReturnAttributes as String] as? Bool == true
            if let context = query[kSecUseAuthenticationContext as String]
                as? LAContext,
               context.interactionNotAllowed {
                self.sawInteractionNotAllowedContext = true
            }
            if wantsData, let status = self.dataCopyStatus {
                return (status, nil)
            }
            if query[kSecAttrAccount as String] == nil, wantsAttributes {
                let service = query[kSecAttrService as String] as? String
                let matches = self.items.values.filter {
                    service == nil || ($0[kSecAttrService as String] as? String) == service
                }
                guard !matches.isEmpty else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, matches as NSArray)
            }
            guard let account = query[kSecAttrAccount as String] as? String,
                  let item = self.items[account]
            else { return (errSecItemNotFound, nil) }

            if self.enforcesUserPresenceForProtectedData,
               wantsData,
               self.presenceProtectedAccounts.contains(account) {
                guard let context = query[kSecUseAuthenticationContext as String]
                    as? LAContext,
                      !context.interactionNotAllowed else {
                    return (errSecInteractionNotAllowed, nil)
                }
            }

            if wantsData && wantsAttributes {
                return (errSecSuccess, item as NSDictionary)
            }
            if wantsData {
                return (errSecSuccess, item[kSecValueData as String] as AnyObject?)
            }
            if wantsAttributes {
                return (errSecSuccess, item as NSDictionary)
            }
            return (errSecSuccess, nil)
        },
        delete: { [unowned self] query in
            if query[kSecUseAuthenticationContext as String] is LAContext {
                self.sawDeleteAuthenticationContext = true
                if self.rejectsDeleteAuthenticationContext {
                    return errSecParam
                }
            }
            guard self.deleteStatus == errSecSuccess else { return self.deleteStatus }
            guard let account = query[kSecAttrAccount as String] as? String,
                  self.items.removeValue(forKey: account) != nil
            else { return errSecItemNotFound }
            self.presenceProtectedAccounts.remove(account)
            return errSecSuccess
        }
    )
}

@MainActor
private final class LifecyclePersistenceHarness {
    var keys: [StoredKey]
    var identities: [Identity]
    var failingBoundary: KeyLifecycleSaveBoundary?
    var saveAttempts: [KeyLifecycleSaveBoundary] = []
    var rollbackCount = 0

    init(keys: [StoredKey] = [], identities: [Identity] = []) {
        self.keys = keys
        self.identities = identities
    }

    var persistence: KeyLifecyclePersistence {
        KeyLifecyclePersistence(
            insertKey: { [unowned self] key in
                keys.append(key)
            },
            deleteKey: { [unowned self] key in
                keys.removeAll { $0.id == key.id }
            },
            fetchKeys: { [unowned self] in keys },
            fetchIdentities: { [unowned self] in identities },
            save: { [unowned self] boundary in
                saveAttempts.append(boundary)
                if failingBoundary == boundary {
                    throw KeyStoreSecurityTests.InjectedFailure.save(boundary)
                }
            },
            rollback: { [unowned self] in
                rollbackCount += 1
            }
        )
    }
}

private extension Data {
    mutating func appendTestUInt32(_ value: UInt32) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendTestSSHString(_ string: String) {
        appendTestSSHString(Data(string.utf8))
    }

    mutating func appendTestSSHString(_ data: Data) {
        appendTestUInt32(UInt32(data.count))
        append(data)
    }
}
