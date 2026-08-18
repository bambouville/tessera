import XCTest
@testable import TmuxControl

final class AutoTmuxScriptTests: XCTestCase {

    // MARK: - command(sessionName:)

    func test_command_includesSessionName() {
        let cmd = AutoTmuxScript.command(sessionName: "tessera-abcdef01")
        XCTAssertTrue(cmd.contains("tessera-abcdef01"),
                      "session name must appear in the generated command")
    }

    func test_command_attachesIfSessionExists() {
        // The has-session check + exec attach must be in the script,
        // and they must reference the same session name.
        let cmd = AutoTmuxScript.command(sessionName: "tessera-deadbeef")
        XCTAssertTrue(cmd.contains("tmux has-session -t tessera-deadbeef"),
                      "must check for the session before attaching")
        XCTAssertTrue(cmd.contains("exec tmux -CC attach -t tessera-deadbeef"),
                      "happy path attach must use exec so the shell exits with tmux")
    }

    func test_command_createsMissingSessionWithAPlainDetachedClient() {
        // The create step must NOT be a control-mode client: `tmux -CC new`
        // has to start the server and speak control mode on the same
        // client, and a server that fails to start leaves the app waiting
        // on a DCS prologue that never arrives. A plain `new-session -d`
        // surfaces that failure as ordinary shell output instead.
        let cmd = AutoTmuxScript.command(sessionName: "tessera-12345678")
        XCTAssertTrue(cmd.contains("tmux new-session -d -s tessera-12345678"),
                      "missing sessions must be created with a plain detached client")
        XCTAssertFalse(cmd.contains("tmux -CC new"),
                      "control mode must only ever attach to an already-running server")
        XCTAssertTrue(cmd.contains("exec tmux -CC attach -t tessera-12345678"),
                      "both branches converge on the same control-mode attach")
    }

    func test_command_reportsStartFailureWhenTheSessionCannotBeCreated() {
        let cmd = AutoTmuxScript.command(sessionName: "tessera-12345678")
        XCTAssertFalse(
            cmd.contains(AutoTmuxScript.startFailedSentinel),
            "the literal marker must not appear — the PTY echo would false-positive it"
        )
        XCTAssertTrue(
            cmd.contains("\\137\\137TESSERA_TMUX_START_FAILED\\137\\137"),
            "a failed create must print the escaped start-failure marker"
        )
    }

    func test_command_geometryNeutralClientIgnoresSizeOnlyForExistingSession() {
        let cmd = AutoTmuxScript.command(
            sessionName: "tessera-12345678",
            preserveExistingGeometry: true
        )
        XCTAssertTrue(
            cmd.contains("exec tmux -CC attach -f ignore-size -t tessera-12345678")
        )
        XCTAssertTrue(cmd.contains("tmux -V 2>/dev/null"))
        XCTAssertTrue(cmd.contains("else exec tmux -CC attach -t tessera-12345678"))
        XCTAssertTrue(
            cmd.contains("tmux new-session -d -s tessera-12345678")
        )
        XCTAssertFalse(
            cmd.contains("new-session -d -f ignore-size")
        )
    }

    // MARK: - failure scanning

    func test_command_reportsNestingInsteadOfAttachingFromInsideTmux() {
        // A host whose dotfiles `exec tmux` runs this one-liner inside a
        // pane. Attaching in control mode from there is refused by tmux,
        // and `exec`ing that refusal takes the login shell — and the
        // connection — down with it.
        let cmd = AutoTmuxScript.command(sessionName: "tessera-12345678")
        XCTAssertTrue(cmd.contains("if [ -n \"$TMUX\" ]; then"),
                      "the script must check for an inherited tmux client first")
        XCTAssertTrue(
            cmd.contains("\\137\\137TESSERA_TMUX_NESTED\\137\\137"),
            "being inside tmux must report the escaped nested marker"
        )
        XCTAssertFalse(
            cmd.contains(AutoTmuxScript.nestedSentinel),
            "the literal marker must not appear — the PTY echo would false-positive it"
        )
    }

    func test_scanner_distinguishesUnavailableFromStartFailure() {
        var scanner = AutoTmuxSentinelScanner()
        XCTAssertEqual(
            scanner.feedForFailure(Array("noise\n".utf8)),
            nil
        )
        XCTAssertEqual(
            scanner.feedForFailure(Array(AutoTmuxScript.startFailedSentinel.utf8)),
            .startFailed
        )

        var second = AutoTmuxSentinelScanner()
        XCTAssertEqual(
            second.feedForFailure(Array(AutoTmuxScript.unavailableSentinel.utf8)),
            .unavailable
        )
    }

    func test_scanner_detectsStartFailureAcrossChunkBoundary() {
        var scanner = AutoTmuxSentinelScanner()
        let bytes = Array(AutoTmuxScript.startFailedSentinel.utf8)
        let split = bytes.count / 2
        XCTAssertNil(scanner.feedForFailure(Array(bytes[..<split])))
        XCTAssertEqual(
            scanner.feedForFailure(Array(bytes[split...])),
            .startFailed
        )
    }

    func test_geometryPreservingClientCommand_requiresTmuxThreeTwo() {
        let cmd = AutoTmuxScript.geometryPreservingClientCommand(
            tmuxCommand: "tmux -u attach-session",
            arguments: "-t target"
        )

        XCTAssertTrue(cmd.contains("[ \"$tessera_tmux_major\" -gt 3 ]"))
        XCTAssertTrue(cmd.contains("[ \"$tessera_tmux_major\" -eq 3 ]"))
        XCTAssertTrue(cmd.contains("[ \"$tessera_tmux_minor\" -ge 2 ]"))
        XCTAssertTrue(cmd.contains("exec tmux -u attach-session -f ignore-size -t target"))
        XCTAssertTrue(cmd.contains("else exec tmux -u attach-session -t target"))
    }

    func test_command_emitsSentinelViaOctalEscapesNotLiterals() {
        // The interpreted printf output is what matches the scanner —
        // the source command must NOT contain the literal sentinel
        // string, otherwise the PTY echoes the command back to us
        // and the scanner false-positives the banner before the shell
        // even runs the if-then-else.
        let cmd = AutoTmuxScript.command(sessionName: "tessera-00000000")
        XCTAssertFalse(
            cmd.contains(AutoTmuxScript.unavailableSentinel),
            "command must NOT contain the literal sentinel string — that would false-positive when the PTY echoes the command back"
        )
        // The escaped form must be present so that the printf produces
        // the sentinel bytes when actually executed.
        XCTAssertTrue(
            cmd.contains("\\137\\137TESSERA_NO_TMUX\\137\\137"),
            "the no-tmux branch must use \\137 octal escapes (which printf interprets as `_`) so the source command doesn't contain the needle"
        )
    }

    func test_command_exportsCOLORTERMBeforeClear() {
        // COLORTERM=truecolor tells CLI tools (bat, delta, Claude Code)
        // to use 24-bit colour. Exported before `clear` so the
        // environment is inherited by tmux and all child panes.
        let cmd = AutoTmuxScript.command(sessionName: "tessera-feedface")
        XCTAssertTrue(cmd.hasPrefix("export COLORTERM=truecolor; clear; "),
                      "command must export COLORTERM then clear before tmux handoff")
    }

    func test_command_endsWithNewline() {
        // The shell needs an Enter to actually run the line — caller
        // would otherwise have to remember to append \n separately.
        let cmd = AutoTmuxScript.command(sessionName: "tessera-cafebabe")
        XCTAssertTrue(cmd.hasSuffix("\n"),
                      "command must end with a newline so the shell executes it")
    }

    func test_command_usesPosixCompatibleShellSyntax() {
        // No bash-isms — should work in /bin/sh, dash, ash, busybox sh,
        // zsh, bash. The script uses only `if/then/else/fi`,
        // `command -v`, `printf`, `exec`, `tmux`. Sanity-check via
        // explicit substring presence rather than execution.
        let cmd = AutoTmuxScript.command(sessionName: "x")
        XCTAssertTrue(cmd.contains("command -v tmux"),
                      "use POSIX-portable `command -v` instead of bash-only `which`")
        XCTAssertTrue(cmd.contains("if "),
                      "use POSIX if/then/else/fi structure")
        XCTAssertTrue(cmd.contains("fi"),
                      "the if blocks must be properly terminated")
    }

    // MARK: - defaultSessionName(forHostKey:)

    func test_defaultSessionName_isDeterministic() {
        // Same host key → same name on every call. Critical for the
        // "reinstall doesn't strand my server-side session" property.
        let a = AutoTmuxScript.defaultSessionName(forHostKey: "user@127.0.0.1:22")
        let b = AutoTmuxScript.defaultSessionName(forHostKey: "user@127.0.0.1:22")
        XCTAssertEqual(a, b)
    }

    func test_defaultSessionName_differsByHostKey() {
        let a = AutoTmuxScript.defaultSessionName(forHostKey: "user@127.0.0.1:22")
        let b = AutoTmuxScript.defaultSessionName(forHostKey: "user@192.168.1.10:22")
        XCTAssertNotEqual(a, b,
                          "different host keys should hash to different session names")
    }

    func test_defaultSessionName_format() {
        // tessera-[0-9a-f]{8} so it's safe to interpolate into a
        // shell `-t <name>` argument without escaping.
        let name = AutoTmuxScript.defaultSessionName(forHostKey: "alice@example.com:2222")
        XCTAssertTrue(name.hasPrefix("tessera-"))
        XCTAssertEqual(name.count, "tessera-".count + 8)
        let hex = String(name.dropFirst("tessera-".count))
        XCTAssertEqual(hex.count, 8)
        XCTAssertTrue(hex.allSatisfy { "0123456789abcdef".contains($0) },
                      "the hex suffix must be all lowercase hex digits")
    }

    // MARK: - sessionNameDigest(_:)

    func test_sessionNameDigest_isDeterministic() {
        // The whole point of the log field: the same session yields the same
        // token across log lines, across reconnects, and across two reports
        // from the same user. A non-deterministic token correlates nothing.
        XCTAssertEqual(
            AutoTmuxScript.sessionNameDigest("acme-prod-payments"),
            AutoTmuxScript.sessionNameDigest("acme-prod-payments")
        )
    }

    func test_sessionNameDigest_distinguishesSessionsOnOneHost() {
        XCTAssertNotEqual(
            AutoTmuxScript.sessionNameDigest("acme-prod-payments"),
            AutoTmuxScript.sessionNameDigest("acme-prod-billing")
        )
    }

    func test_sessionNameDigest_isEightLowercaseHexAndNotTheName() {
        let name = "acme-prod-payments"
        let digest = AutoTmuxScript.sessionNameDigest(name)
        XCTAssertEqual(digest.count, 8)
        XCTAssertTrue(digest.allSatisfy { "0123456789abcdef".contains($0) })
        // No dashes, so the sanitizer's full-UUID rule cannot match it, and no
        // fragment of the user's own label survives.
        XCTAssertFalse(digest.contains("-"))
        XCTAssertFalse(digest.contains("acme"))
        XCTAssertFalse(name.contains(digest))
    }

    func test_sessionNameDigest_sharesOneDerivationWithDefaultSessionName() {
        // `defaultSessionName` must keep using the same primitive: two
        // derivations would silently mint two tokens for one session.
        let key = "alice@example.com:2222"
        let name = AutoTmuxScript.defaultSessionName(forHostKey: key)
        XCTAssertEqual(name, "tessera-\(AutoTmuxScript.sessionNameDigest(key))")
    }

    func test_sessionNameDigest_ofAutoModeNameHidesTheHostKeyDigest() {
        // Auto-mode names are themselves `tessera-<8 hex of host key>`. Hashing
        // again keeps the host-key digest out of the log.
        let autoName = AutoTmuxScript.defaultSessionName(forHostKey: "user@10.0.0.5:22")
        let logged = AutoTmuxScript.sessionNameDigest(autoName)
        XCTAssertFalse(autoName.contains(logged))
    }

    // MARK: - chunkContainsSentinel(_:)

    func test_chunkContainsSentinel_findsExactMatch() {
        let chunk = Array(AutoTmuxScript.unavailableSentinel.utf8)
        XCTAssertTrue(AutoTmuxScript.chunkContainsSentinel(chunk))
    }

    func test_chunkContainsSentinel_findsMatchSurroundedByOtherBytes() {
        // Realistic case: clear escape sequences before, prompt redraw
        // bytes after.
        var chunk: [UInt8] = [0x1B, 0x5B, 0x48, 0x1B, 0x5B, 0x32, 0x4A] // ESC[H ESC[2J
        chunk.append(contentsOf: Array("__TESSERA_NO_TMUX__".utf8))
        chunk.append(contentsOf: Array("\n(base) user@host % ".utf8))
        XCTAssertTrue(AutoTmuxScript.chunkContainsSentinel(chunk))
    }

    func test_chunkContainsSentinel_returnsFalseForOrdinaryOutput() {
        let chunk = Array("hello shell\n(base) user@host % ls /tmp\nfoo bar baz\n".utf8)
        XCTAssertFalse(AutoTmuxScript.chunkContainsSentinel(chunk))
    }

    func test_chunkContainsSentinel_returnsFalseForChunkShorterThanNeedle() {
        let chunk = Array("__TES".utf8) // partial sentinel, too short
        XCTAssertFalse(AutoTmuxScript.chunkContainsSentinel(chunk))
    }

    func test_chunkContainsSentinel_doesNotFalsePositiveOnPartialMatch() {
        // Looks similar but isn't. Common almost-substrings shouldn't
        // trigger the banner.
        let chunk = Array("__TESSERA_NO_TMUX_OK__\n".utf8) // trailing _OK_
        XCTAssertFalse(
            AutoTmuxScript.chunkContainsSentinel(chunk),
            "the scanner shouldn't match a near-miss superstring"
        )
    }

    func test_chunkContainsSentinel_emptyChunkReturnsFalse() {
        XCTAssertFalse(AutoTmuxScript.chunkContainsSentinel([]))
    }

    // MARK: - AutoTmuxSentinelScanner

    func test_sentinelScannerFindsMatchAcrossChunkBoundary() {
        var scanner = AutoTmuxSentinelScanner()

        XCTAssertFalse(scanner.feed(Array("prefix __TESSERA".utf8)))
        XCTAssertTrue(scanner.feed(Array("_NO_TMUX__ suffix".utf8)))
    }

    func test_sentinelScannerResetDropsPartialMatch() {
        var scanner = AutoTmuxSentinelScanner()

        XCTAssertFalse(scanner.feed(Array("__TESSERA".utf8)))
        scanner.reset()

        XCTAssertFalse(scanner.feed(Array("_NO_TMUX__".utf8)))
    }
}
