import Foundation
import XCTest
@testable import TesseraSessionCore

/// Ported from the iOS `MoshBootstrapTests` parse cases and Android's
/// `MoshBootstrapParserTest` / `MoshSessionRecoveryPolicyTest`, so the one
/// shared grammar keeps satisfying both platforms' pinned behaviour.
final class MoshBootstrapGrammarTests: XCTestCase {

    private let sessionKey = "qiXpjXIk6M8/nWtBn9s6rQ"

    // MARK: - Connect response

    func testReadsPortAndKey() throws {
        let parsed = try MoshBootstrapGrammar.parseConnectResponse(
            stdout: "MOSH CONNECT 60001 \(sessionKey)\n"
        )

        XCTAssertEqual(parsed.udpPort, 60_001)
        XCTAssertEqual(parsed.base64Key, sessionKey)
        XCTAssertNil(parsed.serverPID)
    }

    func testReadsPortAndKeyFromStderr() throws {
        let parsed = try MoshBootstrapGrammar.parseConnectResponse(
            stdout: "",
            stderr: "MOSH CONNECT 60004 X8YJtMJsZL0ak6kBE4FmlA\n"
        )

        XCTAssertEqual(parsed.udpPort, 60_004)
        XCTAssertEqual(parsed.base64Key, "X8YJtMJsZL0ak6kBE4FmlA")
    }

    func testIgnoresSurroundingNoise() throws {
        let stdout = """
        mosh-server (mosh 1.4.0)
        MOSH CONNECT 60002 8aBls0YgYKK/xIYqQ9uKJg
        mosh-server detached
        """

        let parsed = try MoshBootstrapGrammar.parseConnectResponse(stdout: stdout)

        XCTAssertEqual(parsed.udpPort, 60_002)
        XCTAssertEqual(parsed.base64Key, "8aBls0YgYKK/xIYqQ9uKJg")
        XCTAssertNil(parsed.serverPID)
    }

    /// Android's `acceptsDetachedBannerAndNormalizesOptionalPadding`.
    func testAcceptsDetachedBannerAndNormalizesOptionalPadding() throws {
        let parsed = try MoshBootstrapGrammar.parseConnectResponse(
            stdout: "warning\n[mosh-server detached, pid = 912]\n"
                + "MOSH CONNECT 60042 AAECAwQFBgcICQoLDA0ODw==\n"
        )

        XCTAssertEqual(parsed.udpPort, 60_042)
        XCTAssertEqual(parsed.serverPID, 912)
        XCTAssertEqual(parsed.base64Key, "AAECAwQFBgcICQoLDA0ODw")
    }

    func testReadsRealServerTranscript() throws {
        let stdout = """
        mosh-server (mosh 1.4.0) [build mosh 1.4.0]
        Copyright 2012 Keith Winstein <mosh-devel@mit.edu>
        License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.
        This is free software: you are free to change and redistribute it.
        There is NO WARRANTY, to the extent permitted by law.

        [mosh-server detached, pid = 111904]
        MOSH CONNECT 60001 \(sessionKey)
        """

        let parsed = try MoshBootstrapGrammar.parseConnectResponse(stdout: stdout)

        XCTAssertEqual(parsed.udpPort, 60_001)
        XCTAssertEqual(parsed.base64Key, sessionKey)
        XCTAssertEqual(parsed.serverPID, 111_904)
    }

    func testThrowsWhenLineMissing() {
        assertFailure(.missingConnect) {
            try MoshBootstrapGrammar.parseConnectResponse(stdout: "mosh-server ready\n")
        }
    }

    func testThrowsWhenPortIsMalformed() {
        assertFailure(.malformedConnect) {
            try MoshBootstrapGrammar.parseConnectResponse(
                stdout: "MOSH CONNECT nope \(sessionKey)\n"
            )
        }
    }

    func testThrowsWhenKeyIsMalformed() {
        assertFailure(.malformedConnect) {
            try MoshBootstrapGrammar.parseConnectResponse(stdout: "MOSH CONNECT 60003 ***\n")
        }
    }

    /// Android's `rejectsMalformedConnectInsteadOfUsingAnAmbiguousCredential`.
    func testRejectsOutOfRangePortInsteadOfUsingAnAmbiguousCredential() {
        assertFailure(.malformedConnect) {
            try MoshBootstrapGrammar.parseConnectResponse(
                stdout: "MOSH CONNECT 70000 not-a-valid-key"
            )
        }
        assertFailure(.malformedConnect) {
            try MoshBootstrapGrammar.parseConnectResponse(
                stdout: "MOSH CONNECT 0 \(sessionKey)"
            )
        }
    }

    /// iOS's strict literal prefix is canonical: mosh-server emits exactly one
    /// space, and a lenient whitespace split only widens what a garbled or
    /// hostile transcript can talk the client into dialling. A shape that
    /// never comes from mosh-server is not a connect line at all — so this is
    /// `missingConnect`, not `malformedConnect`.
    func testLenientWhitespaceSplitIsNotAConnectLine() {
        assertFailure(.missingConnect) {
            try MoshBootstrapGrammar.parseConnectResponse(
                stdout: "MOSH\tCONNECT 60001 \(sessionKey)\n"
            )
        }
        assertFailure(.missingConnect) {
            try MoshBootstrapGrammar.parseConnectResponse(
                stdout: "MOSH  CONNECT 60001 \(sessionKey)\n"
            )
        }
        assertFailure(.missingConnect) {
            try MoshBootstrapGrammar.parseConnectResponse(
                stdout: "mosh connect 60001 \(sessionKey)\n"
            )
        }
    }

    func testExtraFieldsAreMalformedNotTruncated() {
        assertFailure(.malformedConnect) {
            try MoshBootstrapGrammar.parseConnectResponse(
                stdout: "MOSH CONNECT 60001 \(sessionKey) extra\n"
            )
        }
    }

    /// A later well-formed line still wins after an earlier malformed one:
    /// mosh-server can print noise before its real banner.
    func testLaterWellFormedLineWinsOverEarlierMalformedOne() throws {
        let parsed = try MoshBootstrapGrammar.parseConnectResponse(
            stdout: "MOSH CONNECT bad key\nMOSH CONNECT 60001 \(sessionKey)\n"
        )

        XCTAssertEqual(parsed.udpPort, 60_001)
    }

    // MARK: - Key normalisation

    func testNormalizedConnectKeyAcceptsOnlyExactBase64Body() {
        XCTAssertEqual(MoshBootstrapGrammar.normalizedConnectKey(sessionKey), sessionKey)
        XCTAssertEqual(
            MoshBootstrapGrammar.normalizedConnectKey(sessionKey + "=="),
            sessionKey
        )
        XCTAssertNil(MoshBootstrapGrammar.normalizedConnectKey(""))
        XCTAssertNil(MoshBootstrapGrammar.normalizedConnectKey("="))
        XCTAssertNil(MoshBootstrapGrammar.normalizedConnectKey(String(sessionKey.dropLast())))
        XCTAssertNil(MoshBootstrapGrammar.normalizedConnectKey(sessionKey + "A"))
        XCTAssertNil(MoshBootstrapGrammar.normalizedConnectKey(sessionKey + "="))
        // `-`/`_` is base64url, not what mosh-server prints.
        XCTAssertNil(
            MoshBootstrapGrammar.normalizedConnectKey("qiXpjXIk6M8_nWtBn9s6rQ")
        )
    }

    // MARK: - Detached PID banner

    func testDetachedServerPIDRequiresTheExactBanner() {
        XCTAssertEqual(
            MoshBootstrapGrammar.detachedServerPID(
                from: "noise\n[mosh-server detached, pid = 912]\nmore"
            ),
            912
        )
        XCTAssertNil(
            MoshBootstrapGrammar.detachedServerPID(from: "[mosh-server detached, pid = 0]")
        )
        XCTAssertNil(
            MoshBootstrapGrammar.detachedServerPID(from: "[mosh-server detached, pid = -3]")
        )
        XCTAssertNil(
            MoshBootstrapGrammar.detachedServerPID(from: "[mosh-server detached, pid = abc]")
        )
        XCTAssertNil(
            MoshBootstrapGrammar.detachedServerPID(from: "[mosh-server detached, pid = 912")
        )
        XCTAssertNil(MoshBootstrapGrammar.detachedServerPID(from: "mosh-server detached"))
    }

    // MARK: - Missing server

    /// Android's `doesNotTreatArbitraryShellOutputAsMissingServer`.
    func testMissingServerNeedsBothMarkers() {
        XCTAssertTrue(
            MoshBootstrapGrammar.transcriptSuggestsMissingServer(
                "sh: mosh-server: command not found"
            )
        )
        XCTAssertTrue(
            MoshBootstrapGrammar.transcriptSuggestsMissingServer(
                "bash: line 1: /usr/bin/mosh-server: No such file or directory"
            )
        )
        XCTAssertFalse(
            MoshBootstrapGrammar.transcriptSuggestsMissingServer(
                "MOSH CONNECT 60001 \(sessionKey)"
            )
        )
        XCTAssertFalse(
            MoshBootstrapGrammar.transcriptSuggestsMissingServer("tmux: command not found")
        )
        XCTAssertFalse(MoshBootstrapGrammar.transcriptSuggestsMissingServer(""))
    }

    func testMissingServerReadsBothStreams() {
        XCTAssertTrue(
            MoshBootstrapGrammar.transcriptSuggestsMissingServer(
                stdout: "",
                stderr: "sh: 1: mosh-server: not found"
            )
        )
        XCTAssertTrue(
            MoshBootstrapGrammar.transcriptSuggestsMissingServer(
                stdout: "sh: 1: mosh-server: not found",
                stderr: ""
            )
        )
    }

    // MARK: - Command construction

    /// `-c 256` is the one input mosh-server has for the TERM it exports;
    /// dropping it is how every mosh session became an 8-colour `xterm`.
    func testServerNewInvocationAlwaysAsksForTwoHundredFiftySixColours() {
        for launch in [nil, "", "tmux new -A -s tessera", "htop"] {
            let invocation = MoshBootstrapGrammar.serverNewInvocation(launchCommand: launch)
            XCTAssertTrue(invocation.hasPrefix("mosh-server new -c 256"), invocation)
        }
    }

    func testServerNewInvocationAppendsOnlyARealLaunchCommand() {
        XCTAssertEqual(
            MoshBootstrapGrammar.serverNewInvocation(launchCommand: nil),
            "mosh-server new -c 256"
        )
        XCTAssertEqual(
            MoshBootstrapGrammar.serverNewInvocation(launchCommand: ""),
            "mosh-server new -c 256"
        )
        XCTAssertEqual(
            MoshBootstrapGrammar.serverNewInvocation(launchCommand: "   \n "),
            "mosh-server new -c 256"
        )
        XCTAssertEqual(
            MoshBootstrapGrammar.serverNewInvocation(launchCommand: "tmux -u new-session -A -s 'x'"),
            "mosh-server new -c 256 -- tmux -u new-session -A -s 'x'"
        )
    }

    /// The exec channel runs a non-login shell, so the command must find
    /// mosh-server on a login-only PATH by itself: probe, exec directly when
    /// it resolves, otherwise re-run the identical argv via the login shell.
    /// `MoshBootstrapCommandDeliveryTests` runs the result through a real
    /// `sh` for both branches; this pins the shape.
    func testServerNewCommandProbesThenFallsBackToTheLoginShell() {
        let plain = MoshBootstrapGrammar.serverNewCommand(launchCommand: nil)
        XCTAssertEqual(
            plain,
            "sh -c 'if command -v mosh-server >/dev/null 2>&1; then exec mosh-server new -c 256; "
                + "else exec \"${SHELL:-/bin/sh}\" -l -c '\\''exec mosh-server new -c 256'\\''; fi'"
        )
        XCTAssertEqual(
            MoshBootstrapGrammar.serverNewCommand(launchCommand: "   \n "),
            plain,
            "an all-whitespace launch command must still yield a plain login shell"
        )
        let launched = MoshBootstrapGrammar.serverNewCommand(launchCommand: "tmux new -A -s tessera")
        XCTAssertTrue(launched.hasPrefix("sh -c 'if command -v mosh-server >/dev/null 2>&1; then "))
        XCTAssertTrue(launched.contains("then exec mosh-server new -c 256 -- tmux new -A -s tessera; else exec "))
        XCTAssertTrue(launched.hasSuffix("; fi'"))
    }

    func testSingleQuotingEscapesEmbeddedQuotes() {
        XCTAssertEqual(MoshBootstrapGrammar.singleQuotedShellString("plain"), "'plain'")
        XCTAssertEqual(
            MoshBootstrapGrammar.singleQuotedShellString("printf 'hi'; echo done"),
            "'printf '\\''hi'\\''; echo done'"
        )
    }

    // MARK: - Server termination

    /// Android's `termination command fences PID reuse before TERM`, plus the
    /// byte-for-byte text iOS's own kill site sends today.
    func testTerminationCommandFencesPIDReuseBeforeTERM() {
        let command = MoshBootstrapGrammar.makeServerTerminationScript(pid: 4242)

        XCTAssertTrue(command.contains("pid=4242"))
        XCTAssertTrue(command.contains("ps -p"))
        XCTAssertTrue(command.contains("*mosh-server*"))
        XCTAssertTrue(command.contains("exit 64"))
        XCTAssertTrue(command.contains("kill -TERM"))
        XCTAssertFalse(command.contains("kill -KILL"))

        XCTAssertEqual(
            command,
            "sh -lc 'pid=4242; "
                + "if ! kill -0 \"$pid\" 2>/dev/null; then exit 0; fi; "
                + "set -- $(ps -p \"$pid\" -o comm= 2>/dev/null); "
                + "case \"${1:-}\" in *mosh-server*) ;; *) exit 64;; esac; "
                + "kill -TERM \"$pid\"; n=0; "
                + "while kill -0 \"$pid\" 2>/dev/null && [ \"$n\" -lt 5 ]; do "
                + "sleep 1; n=$((n+1)); done; "
                + "! kill -0 \"$pid\" 2>/dev/null'"
        )
    }

    /// An already-exited server is success, never an error the caller has to
    /// explain to the user.
    func testTerminationCommandTreatsAnExitedServerAsSuccess() {
        let command = MoshBootstrapGrammar.makeServerTerminationScript(pid: 1)
        XCTAssertTrue(command.contains("if ! kill -0 \"$pid\" 2>/dev/null; then exit 0; fi"))
    }

    // MARK: - Server liveness

    /// The probe only reads: no signal but `kill -0`, the same PID-reuse
    /// fence as termination, and a non-login shell.
    func testLivenessScriptIsReadOnlyAndFencesPIDReuse() {
        let command = MoshBootstrapGrammar.makeServerLivenessScript(pid: 4242)

        XCTAssertEqual(
            command,
            "sh -c 'pid=4242; "
                + "if ! kill -0 \"$pid\" 2>/dev/null; then echo TESSERA_MOSH_SERVER=gone; exit 0; fi; "
                + "c=$(ps -p \"$pid\" -o comm= 2>/dev/null); "
                + "case \"$c\" in "
                + "*mosh-server*) echo TESSERA_MOSH_SERVER=alive;; "
                + "*[![:space:]]*) echo TESSERA_MOSH_SERVER=gone;; "
                + "*) echo TESSERA_MOSH_SERVER=unknown;; esac'"
        )
        XCTAssertFalse(command.contains("-TERM"))
        XCTAssertFalse(command.contains("-KILL"))
        XCTAssertFalse(command.contains("sh -lc"))
    }

    /// Run the real script under /bin/sh against processes this test owns, so
    /// the shell text and the parser agree about every branch.
    func testLivenessScriptAnswersForRealProcesses() throws {
        #if os(macOS)
        // A live process whose command name is not mosh-server: a reused PID.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate() }
        XCTAssertEqual(
            try runLivenessScript(pid: Int(sleeper.processIdentifier)),
            .gone
        )

        // A process named mosh-server, the case that must read as alive. A
        // symlink keeps the platform binary runnable (a copy is killed for
        // its signature), and the space in the directory is the macOS shape
        // a word-split name check would misread as a reused PID.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("liveness \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = directory.appendingPathComponent("mosh-server")
        try FileManager.default.createSymbolicLink(
            at: server,
            withDestinationURL: URL(fileURLWithPath: "/bin/sleep")
        )
        let fake = Process()
        fake.executableURL = server
        fake.arguments = ["30"]
        try fake.run()
        defer { fake.terminate() }
        XCTAssertEqual(try runLivenessScript(pid: Int(fake.processIdentifier)), .alive)

        // An exited PID.
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        XCTAssertEqual(try runLivenessScript(pid: Int(exited.processIdentifier)), .gone)
        #else
        throw XCTSkip("needs a host shell")
        #endif
    }

    func testLivenessParserTrustsOnlyExactMarkerLines() {
        XCTAssertEqual(MoshBootstrapGrammar.parseServerLiveness("TESSERA_MOSH_SERVER=alive\n"), .alive)
        XCTAssertEqual(MoshBootstrapGrammar.parseServerLiveness("motd\r\n  TESSERA_MOSH_SERVER=gone \r\n"), .gone)
        XCTAssertEqual(MoshBootstrapGrammar.parseServerLiveness("TESSERA_MOSH_SERVER=unknown"), .unknown)
        // Nothing, noise, or a value the probe never prints is no evidence.
        XCTAssertEqual(MoshBootstrapGrammar.parseServerLiveness(""), .unknown)
        XCTAssertEqual(MoshBootstrapGrammar.parseServerLiveness("bash: ps: command not found"), .unknown)
        XCTAssertEqual(MoshBootstrapGrammar.parseServerLiveness("TESSERA_MOSH_SERVER=dead"), .unknown)
        XCTAssertEqual(MoshBootstrapGrammar.parseServerLiveness("echo TESSERA_MOSH_SERVER=gone"), .unknown)
        // The last marker wins.
        XCTAssertEqual(
            MoshBootstrapGrammar.parseServerLiveness("TESSERA_MOSH_SERVER=gone\nTESSERA_MOSH_SERVER=alive"),
            .alive
        )
    }

    func testLivenessPolicyEndsOnlyOnGoneAndBacksOffWhileTheHostIsDown() {
        typealias Policy = MoshServerLivenessPolicy
        XCTAssertEqual(Policy.unreachableGraceSeconds, 3)
        XCTAssertTrue(Policy.endsAttempt(after: .gone))
        for outcome in [Policy.Outcome.alive, .unknown, .hostUnreachable] {
            XCTAssertFalse(Policy.endsAttempt(after: outcome), "\(outcome)")
        }
        XCTAssertNil(Policy.nextProbeDelaySeconds(after: .gone, consecutiveHostFailures: 0))
        XCTAssertEqual(Policy.nextProbeDelaySeconds(after: .alive, consecutiveHostFailures: 3), 60)
        XCTAssertEqual(Policy.nextProbeDelaySeconds(after: .unknown, consecutiveHostFailures: 0), 60)
        let ladder = (0...12).map {
            Policy.nextProbeDelaySeconds(after: .hostUnreachable, consecutiveHostFailures: $0)
        }
        XCTAssertEqual(ladder, [2, 2, 4, 8, 15, 15, 15, 15, 30, 30, 60, 60, 60])
        // A host that reboots inside two minutes is asked often enough to be
        // caught within a rung of coming back.
        XCTAssertEqual(ladder[1...7].compactMap { $0 }.reduce(0, +), 74)
        XCTAssertEqual(
            Policy.nextProbe(after: .hostUnreachable, consecutiveHostFailures: 2, askedOwner: false),
            .after(4),
            "a probe that asked nothing keeps the ladder"
        )
        XCTAssertEqual(Policy.nextProbe(after: .alive, consecutiveHostFailures: 0, askedOwner: false), .after(60))
        XCTAssertEqual(Policy.nextProbe(after: .gone, consecutiveHostFailures: 0, askedOwner: true), Policy.NextProbe.none)
        XCTAssertEqual(Policy.nextProbe(after: .alive, consecutiveHostFailures: 0, askedOwner: true), .onWake)
        XCTAssertEqual(Policy.nextProbe(after: .unknown, consecutiveHostFailures: 0, askedOwner: true), .onWake)
        XCTAssertEqual(
            Policy.nextProbe(after: .hostUnreachable, consecutiveHostFailures: 1, askedOwner: true),
            .after(60),
            "a destination behind a jump host is still asked again, at most once a settled interval"
        )
        XCTAssertEqual(Policy.Outcome(MoshServerLiveness.alive), .alive)
        XCTAssertEqual(Policy.Outcome(MoshServerLiveness.gone), .gone)
        XCTAssertEqual(Policy.Outcome(MoshServerLiveness.unknown), .unknown)
    }

    // MARK: - Helpers

    #if os(macOS)
    private func runLivenessScript(pid: Int) throws -> MoshServerLiveness {
        let command = MoshBootstrapGrammar.makeServerLivenessScript(pid: pid)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return MoshBootstrapGrammar.parseServerLiveness(output)
    }
    #endif

    private func assertFailure(
        _ expected: MoshBootstrapGrammarFailure,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> MoshConnectCredentials
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? MoshBootstrapGrammarFailure,
                expected,
                file: file,
                line: line
            )
            // The classification must never carry the transcript back out.
            XCTAssertFalse(
                String(describing: error).contains(self.sessionKey),
                file: file,
                line: line
            )
        }
    }
}

/// One test per pattern in the shared ordered redaction list, plus the
/// invariant the whole thing exists for.
final class SensitiveDataRedactionTests: XCTestCase {

    private let sessionKey = "qiXpjXIk6M8/nWtBn9s6rQ"

    /// The invariant: no transcript containing a MOSH CONNECT line survives
    /// redaction with its key intact, in any of the shapes the transports can
    /// hand us.
    func testNoConnectTranscriptSurvivesWithTheKeyIntact() {
        let transcripts = [
            "MOSH CONNECT 60001 \(sessionKey)",
            "before\nMOSH CONNECT 60001 \(sessionKey)\nafter",
            "MOSH CONNECT 60001\n\(sessionKey)",
            "mosh connect 60001 \(sessionKey)",
            "MOSH\tCONNECT\t60001\t\(sessionKey)",
            "wrapped=MOSH CONNECT 60001\\n\(sessionKey)",
            "native failure payload=\(sessionKey)==",
            "failure MOSH CONNECT \(sessionKey) malformed",
        ]

        for transcript in transcripts {
            XCTAssertFalse(
                SensitiveDataRedaction.redactTransportDetail(transcript)
                    .contains(sessionKey),
                transcript
            )
            XCTAssertFalse(
                SensitiveDataRedaction.redact(transcript).contains(sessionKey),
                transcript
            )
        }
    }

    func testMoshConnectLinePatternKeepsOnlyAValidatedPort() {
        XCTAssertEqual(
            SensitiveDataRedaction.redactTransportDetail(
                "MOSH CONNECT 65535 \(sessionKey) trailing-noise"
            ),
            "MOSH CONNECT 65535 <redacted>"
        )
        XCTAssertEqual(
            SensitiveDataRedaction.redactTransportDetail("MOSH CONNECT 0 \(sessionKey)"),
            "MOSH CONNECT <redacted>"
        )
        XCTAssertEqual(
            SensitiveDataRedaction.redactTransportDetail("MOSH CONNECT 65536 \(sessionKey)"),
            "MOSH CONNECT <redacted>"
        )
        XCTAssertEqual(
            SensitiveDataRedaction.redactTransportDetail(
                "failure MOSH CONNECT \(sessionKey) malformed"
            ),
            "failure MOSH CONNECT <redacted>"
        )
    }

    func testMoshConnectKeyPatternCatchesBareAndPaddedKeys() {
        XCTAssertEqual(
            SensitiveDataRedaction.redactTransportDetail("MOSH CONNECT 60001\n\(sessionKey)"),
            "MOSH CONNECT <redacted>\n<redacted-key>"
        )
        XCTAssertEqual(
            SensitiveDataRedaction.redactTransportDetail(
                "native failure payload=\(sessionKey)=="
            ),
            "native failure payload=<redacted-key>"
        )
        // 21 and 23 characters are not a mosh key; a bounded token stays
        // readable so diagnostics keep their correlation values.
        XCTAssertEqual(
            SensitiveDataRedaction.redactTransportDetail("id=abcdefghijklmnopqrstu"),
            "id=abcdefghijklmnopqrstu"
        )
    }

    func testCredentialAssignmentPattern() {
        XCTAssertEqual(
            SensitiveDataRedaction.redact(
                "auth password=hunter2 next=1",
                patterns: [.credentialAssignment]
            ),
            "auth password=<redacted> next=1"
        )
        XCTAssertEqual(
            SensitiveDataRedaction.redact(
                "PASSPHRASE:letmein SECRET=a TOKEN=b",
                patterns: [.credentialAssignment]
            ),
            "PASSPHRASE=<redacted> SECRET=<redacted> TOKEN=<redacted>"
        )
        XCTAssertEqual(
            SensitiveDataRedaction.redact(
                "state=connected",
                patterns: [.credentialAssignment]
            ),
            "state=connected"
        )
    }

    func testEndpointIdentifierPattern() {
        XCTAssertEqual(
            SensitiveDataRedaction.redact(
                "connecting to alice@prod.internal port=22",
                patterns: [.endpointIdentifier]
            ),
            "connecting to <redacted-endpoint> port=22"
        )
        XCTAssertEqual(
            SensitiveDataRedaction.redact(
                "no identity here",
                patterns: [.endpointIdentifier]
            ),
            "no identity here"
        )
        // A tmux window id is the identity a control-mode report is read for.
        // It is not an endpoint and must survive redaction, including inside
        // an escaped tab-separated row.
        XCTAssertEqual(
            SensitiveDataRedaction.redact(
                #"render-ledger refresh surface=live target=@3 stage=deep"#,
                patterns: [.endpointIdentifier]
            ),
            #"render-ledger refresh surface=live target=@3 stage=deep"#
        )
        XCTAssertEqual(
            SensitiveDataRedaction.redact(
                #"__tessera_windows__\t@3\t0\tshell"#,
                patterns: [.endpointIdentifier]
            ),
            #"__tessera_windows__\t@3\t0\tshell"#
        )
        XCTAssertEqual(
            SensitiveDataRedaction.redact(
                "ssh://alice@prod.internal/path",
                patterns: [.endpointIdentifier]
            ),
            "ssh://<redacted-endpoint>/path"
        )
    }

    /// The applied order is the list's, never the caller's argument order —
    /// a caller cannot accidentally run the key scrub before the line scrub
    /// and lose the port that makes a failure diagnosable.
    func testApplicationOrderIsTheListsNotTheCallers() {
        let text = "MOSH CONNECT 60001 \(sessionKey)"
        XCTAssertEqual(
            SensitiveDataRedaction.redact(text, patterns: [.moshConnectKey, .moshConnectLine]),
            SensitiveDataRedaction.redact(text, patterns: [.moshConnectLine, .moshConnectKey])
        )
        XCTAssertEqual(
            SensitiveDataRedaction.redact(text, patterns: [.moshConnectKey, .moshConnectLine]),
            "MOSH CONNECT 60001 <redacted>"
        )
    }

    func testOrderedPatternsCoversEveryCase() {
        XCTAssertEqual(
            Set(SensitiveDataRedaction.orderedPatterns),
            Set(SensitiveDataRedaction.Pattern.allCases)
        )
        XCTAssertEqual(
            SensitiveDataRedaction.orderedPatterns,
            [.moshConnectLine, .moshConnectKey, .credentialAssignment, .endpointIdentifier]
        )
        XCTAssertEqual(
            SensitiveDataRedaction.transportDetailPatterns,
            [.moshConnectLine, .moshConnectKey]
        )
    }

    func testTranscriptSummaryContainsOnlyBoundedMetadata() {
        let summary = SensitiveDataRedaction.bootstrapTranscriptSummary(
            stdout: "MOSH CONNECT 60001 \(sessionKey)",
            stderr: sessionKey
        )

        XCTAssertFalse(summary.contains(sessionKey))
        XCTAssertEqual(summary, "stdoutBytes=41 stderrBytes=22 connectMarker=true")
    }
}
