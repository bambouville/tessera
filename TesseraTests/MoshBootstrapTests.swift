import XCTest
@testable import Tessera

final class MoshBootstrapTests: XCTestCase {

    func test_bootstrapCommand_autoTmuxUsesResolvedSessionName() {
        let host = Host(
            address: "example.com",
            user: "alice",
            launchMode: .autoTmux
        )

        let command = MoshBootstrap.bootstrapCommand(for: host) { _ in
            "tessera-auto1234"
        }

        XCTAssertEqual(
            command,
            "mosh-server new -- tmux -u new-session -A -s tessera-auto1234 \\; set-option -t tessera-auto1234 status off"
        )
    }

    func test_bootstrapCommand_pinnedTmuxUsesTrimmedPinnedName() {
        let host = Host(
            address: "example.com",
            user: "alice",
            launchMode: .pinnedTmux,
            tmuxSessionName: "  dev-session  "
        )

        let command = MoshBootstrap.bootstrapCommand(for: host) { _ in
            "tessera-fallback"
        }

        XCTAssertEqual(
            command,
            "mosh-server new -- tmux -u new-session -A -s dev-session \\; set-option -t dev-session status off"
        )
    }

    func test_bootstrapCommand_pinnedTmuxFallsBackWhenNameIsEmpty() {
        let host = Host(
            address: "example.com",
            user: "alice",
            launchMode: .pinnedTmux,
            tmuxSessionName: "   "
        )

        let command = MoshBootstrap.bootstrapCommand(for: host) { _ in
            "tessera-fallback"
        }

        XCTAssertEqual(
            command,
            "mosh-server new -- tmux -u new-session -A -s tessera-fallback \\; set-option -t tessera-fallback status off"
        )
    }

    func test_bootstrapCommand_pinnedTmuxFallsBackWhenNameIsUnsafe() {
        let host = Host(
            address: "example.com",
            user: "alice",
            launchMode: .pinnedTmux,
            tmuxSessionName: "prod; rm -rf /"
        )

        let command = MoshBootstrap.bootstrapCommand(for: host) { _ in
            "tessera-fallback"
        }

        XCTAssertEqual(
            command,
            "mosh-server new -- tmux -u new-session -A -s tessera-fallback \\; set-option -t tessera-fallback status off"
        )
    }

    func test_bootstrapCommand_customCommandUsesSingleQuotedShellWrapper() {
        let host = Host(
            address: "example.com",
            user: "alice",
            launchMode: .customCommand,
            launchCommand: "printf 'hi'; echo done"
        )

        let command = MoshBootstrap.bootstrapCommand(for: host)

        XCTAssertEqual(
            command,
            "mosh-server new -- sh -lc 'printf '\\''hi'\\''; echo done'"
        )
    }

    func test_bootstrapCommand_emptyCustomCommandFallsBackToLoginShell() {
        let host = Host(
            address: "example.com",
            user: "alice",
            launchMode: .customCommand,
            launchCommand: ""
        )

        let command = MoshBootstrap.bootstrapCommand(for: host)

        XCTAssertEqual(command, "mosh-server new")
    }

    func test_parseConnectResponse_readsPortAndKey() throws {
        let result = try MoshBootstrap.parseConnectResponse(
            stdout: "MOSH CONNECT 60001 qiXpjXIk6M8/nWtBn9s6rQ\n"
        )

        XCTAssertEqual(result, MoshBootstrapResult(
            udpPort: 60_001,
            base64Key: "qiXpjXIk6M8/nWtBn9s6rQ",
            serverPID: nil,
            detectedOSHint: nil
        ))
    }

    func test_parseConnectResponse_readsPortAndKeyFromStderr() throws {
        let result = try MoshBootstrap.parseConnectResponse(
            stdout: "",
            stderr: "MOSH CONNECT 60004 X8YJtMJsZL0ak6kBE4FmlA\n"
        )

        XCTAssertEqual(result, MoshBootstrapResult(
            udpPort: 60_004,
            base64Key: "X8YJtMJsZL0ak6kBE4FmlA",
            serverPID: nil,
            detectedOSHint: nil
        ))
    }

    func test_parseConnectResponse_ignoresSurroundingNoise() throws {
        let stdout = """
        mosh-server (mosh 1.4.0)
        MOSH CONNECT 60002 8aBls0YgYKK/xIYqQ9uKJg
        mosh-server detached
        """

        let result = try MoshBootstrap.parseConnectResponse(stdout: stdout)

        XCTAssertEqual(result, MoshBootstrapResult(
            udpPort: 60_002,
            base64Key: "8aBls0YgYKK/xIYqQ9uKJg",
            serverPID: nil,
            detectedOSHint: nil
        ))
    }

    func test_parseConnectResponse_normalizesOptionalPadding() throws {
        let result = try MoshBootstrap.parseConnectResponse(
            stdout: "MOSH CONNECT 60003 qiXpjXIk6M8/nWtBn9s6rQ==\n"
        )

        XCTAssertEqual(result, MoshBootstrapResult(
            udpPort: 60_003,
            base64Key: "qiXpjXIk6M8/nWtBn9s6rQ",
            serverPID: nil,
            detectedOSHint: nil
        ))
    }

    func test_parseConnectResponse_readsRealServerTranscript() throws {
        let stdout = """
        mosh-server (mosh 1.4.0) [build mosh 1.4.0]
        Copyright 2012 Keith Winstein <mosh-devel@mit.edu>
        License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.
        This is free software: you are free to change and redistribute it.
        There is NO WARRANTY, to the extent permitted by law.

        [mosh-server detached, pid = 111904]
        MOSH CONNECT 60001 qiXpjXIk6M8/nWtBn9s6rQ
        """

        let result = try MoshBootstrap.parseConnectResponse(stdout: stdout)

        XCTAssertEqual(result, MoshBootstrapResult(
            udpPort: 60_001,
            base64Key: "qiXpjXIk6M8/nWtBn9s6rQ",
            serverPID: 111_904,
            detectedOSHint: nil
        ))
    }

    func test_parseConnectResponse_throwsWhenLineMissing() {
        XCTAssertThrowsError(
            try MoshBootstrap.parseConnectResponse(stdout: "mosh-server ready\n")
        ) { error in
            XCTAssertEqual(
                error as? MoshBootstrapError,
                .missingConnect(stdout: "mosh-server ready\n")
            )
        }
    }

    func test_parseConnectResponse_throwsWhenPortIsMalformed() {
        let stdout = "MOSH CONNECT nope qiXpjXIk6M8/nWtBn9s6rQ\n"

        XCTAssertThrowsError(
            try MoshBootstrap.parseConnectResponse(stdout: stdout)
        ) { error in
            XCTAssertEqual(
                error as? MoshBootstrapError,
                .malformedConnect(stdout: stdout)
            )
        }
    }

    func test_parseConnectResponse_throwsWhenKeyIsMalformed() {
        let stdout = "MOSH CONNECT 60003 ***\n"

        XCTAssertThrowsError(
            try MoshBootstrap.parseConnectResponse(stdout: stdout)
        ) { error in
            XCTAssertEqual(
                error as? MoshBootstrapError,
                .malformedConnect(stdout: stdout)
            )
        }
    }
}

final class HostTransportModelTests: XCTestCase {

    func test_persistedHostTransportDefaultsToSSH() {
        let persisted = PersistedHost()

        XCTAssertEqual(persisted.transportRaw, "ssh")
        XCTAssertEqual(persisted.transport, .ssh)
    }

    func test_persistedHostTransportFallsBackToSSHForUnknownRawValue() {
        let persisted = PersistedHost()
        persisted.transportRaw = "telnet"

        XCTAssertEqual(persisted.transport, .ssh)
    }

    func test_persistedHostTransportRoundTripsAndBridgesToHost() {
        let persisted = PersistedHost()
        persisted.transport = .mosh

        XCTAssertEqual(persisted.transportRaw, "mosh")
        XCTAssertEqual(persisted.transport, .mosh)
        XCTAssertEqual(Host(from: persisted).transport, .mosh)
    }

    func test_persistedHostConnectionKeyIncludesTransport() {
        let persisted = PersistedHost(
            address: "example.com",
            port: 2200,
            transport: .mosh
        )

        XCTAssertEqual(
            persisted.connectionKey,
            "mosh:@example.com:2200"
        )
    }
}

final class MoshInputNormalizerTests: XCTestCase {

    func test_normalizeArrowKeys_convertsCSIArrowsToSS3() {
        let bytes = Array("\u{1B}[A\u{1B}[B\u{1B}[C\u{1B}[D".utf8)

        let normalized = MoshInputNormalizer.normalizeArrowKeysForMosh(bytes)

        XCTAssertEqual(
            normalized,
            Array("\u{1B}OA\u{1B}OB\u{1B}OC\u{1B}OD".utf8)
        )
    }

    func test_normalizeArrowKeys_leavesSS3ArrowsUntouched() {
        let bytes = Array("\u{1B}OA\u{1B}OB".utf8)

        let normalized = MoshInputNormalizer.normalizeArrowKeysForMosh(bytes)

        XCTAssertEqual(normalized, bytes)
    }

    func test_normalizeArrowKeys_ignoresNonArrowEscapeSequences() {
        let bytes = Array("\u{1B}[200~hello\u{1B}[A".utf8)

        let normalized = MoshInputNormalizer.normalizeArrowKeysForMosh(bytes)

        XCTAssertEqual(
            normalized,
            Array("\u{1B}[200~hello\u{1B}OA".utf8)
        )
    }

    func test_terminalHardwareKeys_useStandardVTSequences() {
        XCTAssertEqual(
            TesseraTerminalHardwareKey.pageUp.escapeSequence,
            Array("\u{1B}[5~".utf8)
        )
        XCTAssertEqual(
            TesseraTerminalHardwareKey.pageDown.escapeSequence,
            Array("\u{1B}[6~".utf8)
        )
    }
}

final class MoshSessionFailureClassificationTests: XCTestCase {

    func test_postConnectClosedFailureIsTreatedAsDisconnect() {
        XCTAssertTrue(
            MoshSession.shouldTreatPostConnectFailureAsDisconnect("Connection closed")
        )
        XCTAssertTrue(
            MoshSession.shouldTreatPostConnectFailureAsDisconnect("channel EOF")
        )
    }

    func test_nonDisconnectFailureIsNotTreatedAsDisconnect() {
        XCTAssertFalse(
            MoshSession.shouldTreatPostConnectFailureAsDisconnect("Permission denied")
        )
    }
}

@MainActor
final class MoshSessionFailureMessageTests: XCTestCase {

    func test_userFacingStartupFailureMessage_upgradesGenericConnectionClosed() {
        XCTAssertEqual(
            MoshSession.userFacingStartupFailureMessage(from: "Connection closed"),
            "Could not start mosh. The remote host may not have `mosh-server` installed or on PATH, or it exited immediately during startup."
        )
    }

    func test_userFacingStartupFailureMessage_preservesSpecificMissingServerReason() {
        let reason = "Could not start mosh: the remote host does not have `mosh-server` installed or on PATH."

        XCTAssertEqual(
            MoshSession.userFacingStartupFailureMessage(from: reason),
            reason
        )
    }
}
