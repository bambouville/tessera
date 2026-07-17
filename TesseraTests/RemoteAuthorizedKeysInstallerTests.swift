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
