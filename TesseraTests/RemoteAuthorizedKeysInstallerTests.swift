import XCTest
import Crypto
@testable import Tessera

final class RemoteAuthorizedKeysInstallerTests: XCTestCase {
    func test_singleQuotedShellString_wrapsPlainLine() {
        XCTAssertEqual(
            RemoteAuthorizedKeysInstaller.singleQuotedShellString("ssh-ed25519 AAAA test"),
            "'ssh-ed25519 AAAA test'"
        )
    }

    func test_singleQuotedShellString_escapesApostrophe() {
        XCTAssertEqual(
            RemoteAuthorizedKeysInstaller.singleQuotedShellString("ssh-ed25519 AAAA alice's-key"),
            "'ssh-ed25519 AAAA alice'\\''s-key'"
        )
    }

    func test_makeInstallCommand_buildsIdempotentAppend() {
        let command = RemoteAuthorizedKeysInstaller.makeInstallCommand(
            line: "ssh-ed25519 AAAA test"
        )

        XCTAssertEqual(
            command,
            "mkdir -m 700 -p ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && { grep -qxF 'ssh-ed25519 AAAA test' ~/.ssh/authorized_keys || echo 'ssh-ed25519 AAAA test' >> ~/.ssh/authorized_keys; }"
        )
    }

    func test_makeInstallCommand_escapesApostrophe() {
        let command = RemoteAuthorizedKeysInstaller.makeInstallCommand(
            line: "ssh-ed25519 AAAA alice's-key"
        )

        XCTAssertTrue(command.contains("grep -qxF 'ssh-ed25519 AAAA alice'\\''s-key'"))
        XCTAssertTrue(command.contains("echo 'ssh-ed25519 AAAA alice'\\''s-key'"))
    }

    func test_makeVerifyCommand_checksForMarker() {
        let command = RemoteAuthorizedKeysInstaller.makeVerifyCommand(
            line: "ssh-ed25519 AAAA test"
        )

        XCTAssertEqual(
            command,
            "if grep -qxF 'ssh-ed25519 AAAA test' ~/.ssh/authorized_keys; then echo TESSERA_KEY_INSTALLED; else echo TESSERA_KEY_MISSING; fi"
        )
    }

    func test_makeVerifyCommand_escapesApostrophe() {
        let command = RemoteAuthorizedKeysInstaller.makeVerifyCommand(
            line: "ssh-ed25519 AAAA alice's-key"
        )

        XCTAssertEqual(
            command,
            "if grep -qxF 'ssh-ed25519 AAAA alice'\\''s-key' ~/.ssh/authorized_keys; then echo TESSERA_KEY_INSTALLED; else echo TESSERA_KEY_MISSING; fi"
        )
    }

    func test_makeRevokeCommand_removesSemanticIdentityAndVerifiesAbsence() throws {
        let line = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: Curve25519.Signing.PrivateKey().publicKey,
            comment: "alice's-key"
        )
        let fields = line.split(separator: " ", maxSplits: 2)
        let blob = String(fields[1])
        let command = try RemoteAuthorizedKeysInstaller.makeRevokeCommand(line: line)

        XCTAssertTrue(command.contains("awk -v tessera_type='ssh-ed25519'"))
        XCTAssertTrue(command.contains("-v tessera_blob='\(blob)'"))
        XCTAssertTrue(command.contains("mv \"$tmp\" ~/.ssh/authorized_keys"))
        XCTAssertTrue(command.contains("TESSERA_KEY_REMOVED"))
        XCTAssertTrue(command.contains("TESSERA_KEY_STILL_PRESENT"))
        XCTAssertFalse(command.contains("alice"))
        XCTAssertFalse(command.contains("grep -vxF"))
    }

    func test_semanticRevoke_matchesChangedComment() throws {
        let key = Curve25519.Signing.PrivateKey()
        let target = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: key.publicKey,
            comment: "original-comment"
        )
        let candidate = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: key.publicKey,
            comment: "renamed elsewhere"
        )

        XCTAssertTrue(
            try RemoteAuthorizedKeysInstaller.line(
                candidate,
                referencesSameKeyAs: target
            )
        )
    }

    func test_semanticRevoke_matchesLeadingOptionsIncludingQuotedWhitespace() throws {
        let target = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: Curve25519.Signing.PrivateKey().publicKey,
            comment: "original"
        )
        let candidate = #"from="10.0.0.0/8",command="echo hello world",no-pty \#(target)"#

        XCTAssertTrue(
            try RemoteAuthorizedKeysInstaller.line(
                candidate,
                referencesSameKeyAs: target
            )
        )
    }

    func test_semanticRevoke_doesNotMatchUnrelatedKey() throws {
        let target = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: Curve25519.Signing.PrivateKey().publicKey,
            comment: "target"
        )
        let unrelated = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: Curve25519.Signing.PrivateKey().publicKey,
            comment: "unrelated"
        )

        XCTAssertFalse(
            try RemoteAuthorizedKeysInstaller.line(
                unrelated,
                referencesSameKeyAs: target
            )
        )
    }

    func test_semanticRevoke_ignoresTargetLookingTextInUnrelatedComment() throws {
        let target = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: Curve25519.Signing.PrivateKey().publicKey,
            comment: "target"
        )
        let unrelated = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: Curve25519.Signing.PrivateKey().publicKey,
            comment: "comment contains \(target)"
        )

        XCTAssertFalse(
            try RemoteAuthorizedKeysInstaller.line(
                unrelated,
                referencesSameKeyAs: target
            )
        )
    }

    func test_semanticRevoke_ignoresCommentedOutTarget() throws {
        let target = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: Curve25519.Signing.PrivateKey().publicKey,
            comment: "target"
        )

        XCTAssertFalse(
            try RemoteAuthorizedKeysInstaller.line(
                "# disabled \(target)",
                referencesSameKeyAs: target
            )
        )
    }

    func test_semanticRevoke_ignoresMalformedQuoteAfterParsedKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let target = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: key.publicKey,
            comment: "target"
        )
        let candidate = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: key.publicKey,
            comment: "comment with unmatched \" quote"
        )

        XCTAssertTrue(
            try RemoteAuthorizedKeysInstaller.line(
                candidate,
                referencesSameKeyAs: target
            )
        )
    }

    func test_semanticRevoke_rejectsMalformedTarget() {
        let candidate = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: Curve25519.Signing.PrivateKey().publicKey,
            comment: "valid"
        )

        XCTAssertThrowsError(
            try RemoteAuthorizedKeysInstaller.line(
                candidate,
                referencesSameKeyAs: "ssh-ed25519 AAAA malformed"
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteAuthorizedKeysInstaller.InstallError,
                .invalidPublicKey
            )
        }
        XCTAssertThrowsError(
            try RemoteAuthorizedKeysInstaller.makeRevokeCommand(
                line: "ssh-ed25519 AAAA malformed"
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteAuthorizedKeysInstaller.InstallError,
                .invalidPublicKey
            )
        }
    }

    func test_semanticRevoke_preservesMalformedQuotedCandidate() throws {
        let target = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: Curve25519.Signing.PrivateKey().publicKey,
            comment: "target"
        )
        let candidate = "command=\"unterminated \(target)"

        XCTAssertFalse(
            try RemoteAuthorizedKeysInstaller.line(
                candidate,
                referencesSameKeyAs: target
            )
        )
    }

    func test_validateCanInstall_throwsForSelfInstall() {
        let keyID = UUID()
        let host = Host(address: "example.com", user: "alice", storedKeyID: keyID)

        XCTAssertThrowsError(
            try RemoteAuthorizedKeysInstaller.validateCanInstall(keyID: keyID, on: host)
        ) { error in
            XCTAssertEqual(
                error as? RemoteAuthorizedKeysInstaller.InstallError,
                .selfInstall
            )
        }
    }

    func test_explicitSelfRevokeRequiresTargetKeyWhileInstallStillRejectsIt() {
        let keyID = UUID()
        let selfAuthenticated = Host(
            address: "example.com",
            user: "alice",
            storedKeyID: keyID
        )
        let alternate = Host(
            address: "example.com",
            user: "alice",
            storedKeyID: UUID()
        )

        XCTAssertNoThrow(
            try RemoteAuthorizedKeysInstaller.validateCanSelfRevoke(
                keyID: keyID,
                on: selfAuthenticated
            )
        )
        XCTAssertThrowsError(
            try RemoteAuthorizedKeysInstaller.validateCanInstall(
                keyID: keyID,
                on: selfAuthenticated
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteAuthorizedKeysInstaller.InstallError,
                .selfInstall
            )
        }
        XCTAssertThrowsError(
            try RemoteAuthorizedKeysInstaller.validateCanSelfRevoke(
                keyID: keyID,
                on: alternate
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteAuthorizedKeysInstaller.InstallError,
                .targetKeyRequired
            )
        }
    }

    func test_deviceAccessRevokeUsesTargetKeyOnlyWhileHostStillSelectsIt() {
        let targetKeyID = UUID()
        var host = Host(
            address: "example.com",
            user: "alice",
            storedKeyID: targetKeyID
        )

        XCTAssertTrue(
            RemoteAuthorizedKeysInstaller.shouldRevokeUsingTargetKey(
                keyID: targetKeyID,
                on: host
            )
        )

        host.storedKeyID = UUID()
        XCTAssertFalse(
            RemoteAuthorizedKeysInstaller.shouldRevokeUsingTargetKey(
                keyID: targetKeyID,
                on: host
            )
        )

        host.storedKeyID = nil
        XCTAssertFalse(
            RemoteAuthorizedKeysInstaller.shouldRevokeUsingTargetKey(
                keyID: targetKeyID,
                on: host
            )
        )
    }

    func test_trackedRevocationRequiresExactFrozenRoute() {
        let jump = Host(
            id: UUID(),
            address: "jump.example",
            port: 2200,
            user: "relay",
            transport: .ssh
        )
        var host = Host(
            id: UUID(),
            address: "target.internal",
            user: "alice",
            transport: .mosh,
            jumpChain: [jump]
        )
        let route = RemoteAccessRouteIdentity.value(for: host)

        XCTAssertNoThrow(
            try RemoteAuthorizedKeysInstaller.validateRevocationRoute(
                route,
                on: host
            )
        )
        XCTAssertThrowsError(
            try RemoteAuthorizedKeysInstaller.validateRevocationRoute(nil, on: host)
        ) { error in
            XCTAssertEqual(
                error as? RemoteAuthorizedKeysInstaller.InstallError,
                .routeChanged
            )
        }

        host.jumpChain[0].port = 2201
        XCTAssertThrowsError(
            try RemoteAuthorizedKeysInstaller.validateRevocationRoute(route, on: host)
        ) { error in
            XCTAssertEqual(
                error as? RemoteAuthorizedKeysInstaller.InstallError,
                .routeChanged
            )
        }
    }

    func test_syncInstallAuthorizationRejectsLiveCredentialReResolution() {
        let signingKey = Curve25519.Signing.PrivateKey()
        let line = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: signingKey.publicKey,
            comment: "sync-test"
        )
        let parts = line.split(separator: " ", maxSplits: 2)
        let blob = String(parts[1])
        let blobData = try! XCTUnwrap(Data(base64Encoded: blob))
        let key = EnrollmentPublicKey(
            id: UUID(),
            displayName: "sync test key",
            algorithm: .ed25519,
            blob: blob,
            fingerprint: EnrollmentPublicKey.fingerprint(forSSHBlob: blobData),
            protection: .software
        )
        let jumpID = UUID()
        let jump = Host(
            id: jumpID,
            address: "jump.example",
            user: "relay",
            storedKeyID: UUID()
        )
        let host = Host(
            id: UUID(),
            address: "target.internal",
            user: "alice",
            storedKeyID: UUID(),
            jumpChain: [jump]
        )
        let request = SyncDeviceAccessGrantEngine.InstallRequest(
            host: host,
            hostLabel: "target",
            endpoint: "alice@target.internal:22",
            peerDeviceName: "iPhone",
            flow: .enrollment,
            publicKey: key
        )
        let context = RemoteAuthorizedKeysInstaller.LedgerContext(
            keyID: key.id,
            hostID: host.id,
            hostLabel: request.hostLabel,
            endpoint: request.endpoint,
            routeIdentity: request.routeIdentity,
            authorizationSnapshot: request.grantSnapshot,
            peerDeviceName: request.peerDeviceName,
            direction: .grantedToPeer,
            flow: .enrollment,
            publicKeyFingerprint: key.fingerprint,
            authorizedKeysLine: key.authorizedKeysLine
        )

        XCTAssertNoThrow(
            try RemoteAuthorizedKeysInstaller.validateInstallationAuthorization(
                context,
                on: host
            )
        )
        var changedCredential = host
        changedCredential.jumpChain[0].storedKeyID = UUID()
        XCTAssertThrowsError(
            try RemoteAuthorizedKeysInstaller.validateInstallationAuthorization(
                context,
                on: changedCredential
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteAuthorizedKeysInstaller.InstallError,
                .routeChanged
            )
        }
    }

    func test_installAuthorizationCannotOverwriteEarlierRouteLedger() throws {
        let suite = "RemoteAuthorizedKeysInstallerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = KeySecurityMetadataStore(defaults: defaults, storageKey: "ledger")
        let keyID = UUID()
        let host = Host(id: UUID(), address: "new.example", user: "alice")
        let line = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: Curve25519.Signing.PrivateKey().publicKey,
            comment: "target"
        )
        let fingerprint = KeyStore.canonicalFingerprint(forAuthorizedKeysLine: line)
        metadata.recordRemoteInstallation(
            keyID: keyID,
            hostID: host.id,
            hostLabel: "old",
            endpoint: "alice@old.example:22",
            routeIdentity: "old-route",
            direction: .localInstallation,
            publicKeyFingerprint: fingerprint,
            authorizedKeysLine: line
        )
        let context = RemoteAuthorizedKeysInstaller.LedgerContext(
            metadata: metadata,
            keyID: keyID,
            hostID: host.id,
            hostLabel: "new",
            endpoint: "alice@new.example:22",
            routeIdentity: RemoteAccessRouteIdentity.value(for: host),
            publicKeyFingerprint: fingerprint,
            authorizedKeysLine: line
        )

        XCTAssertThrowsError(
            try RemoteAuthorizedKeysInstaller.validateInstallationAuthorization(
                context,
                on: host
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteAuthorizedKeysInstaller.InstallError,
                .routeChanged
            )
        }
        XCTAssertEqual(
            metadata.record(for: keyID).remoteInstallations.first?.routeIdentity,
            "old-route"
        )
    }

    func test_validateCanInstall_allowsDifferentAuthKey() {
        let host = Host(
            address: "example.com",
            user: "alice",
            storedKeyID: UUID()
        )

        XCTAssertNoThrow(
            try RemoteAuthorizedKeysInstaller.validateCanInstall(keyID: UUID(), on: host)
        )
    }

    func test_validateCanInstall_allowsPasswordHost() {
        let host = Host(address: "example.com", user: "alice", storedKeyID: nil)

        XCTAssertNoThrow(
            try RemoteAuthorizedKeysInstaller.validateCanInstall(keyID: UUID(), on: host)
        )
    }

    func test_validateCanInstall_rechecksLiveCredentialAfterInitialAlternate() throws {
        let targetKeyID = UUID()
        let alternateKeyID = UUID()
        let hostID = UUID()
        let initialSnapshot = Host(
            id: hostID,
            address: "example.test",
            user: "alice",
            storedKeyID: alternateKeyID
        )
        var resolvedLiveHost = initialSnapshot
        resolvedLiveHost.storedKeyID = targetKeyID

        XCTAssertNoThrow(
            try RemoteAuthorizedKeysInstaller.validateCanInstall(
                keyID: targetKeyID,
                on: initialSnapshot
            )
        )
        XCTAssertThrowsError(
            try RemoteAuthorizedKeysInstaller.validateCanInstall(
                keyID: targetKeyID,
                on: resolvedLiveHost
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteAuthorizedKeysInstaller.InstallError,
                .selfInstall
            )
        }
    }
}
