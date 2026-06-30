import XCTest
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
}
