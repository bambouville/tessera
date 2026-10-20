import Foundation
import XCTest
@testable import TesseraDomainCore

/// Shared-core coverage for the cwd probe: the exact shell text both
/// platforms send, the marker parsing, and the miss debounce.
///
/// Cases come from the iOS `RemoteCwdPollerTests` and Android's
/// `RemoteCwdProbeTest`, plus one named test per hard-won detail so an
/// "obvious cleanup" has to argue with a name first.
final class RemoteCwdProbeTests: XCTestCase {

    // MARK: - reportedPath

    func testMarkerLineWins() {
        XCTAssertEqual(
            RemoteCwdProbe.reportedPath(in: "TESSERA_CWD=/home/user/src\n"),
            "/home/user/src"
        )
        XCTAssertEqual(
            RemoteCwdProbe.reportedPath(in: "  TESSERA_CWD=/tmp \nTESSERA_CWD=/other\n"),
            "/tmp"
        )
    }

    /// Hard-won rule: the marker exists because exec output merges stderr
    /// and the remote login shell's rc files (zshenv, SSH_SOURCE_BASHRC
    /// bashrc, nvm, motd) print ahead of our own output.
    func testMarkerSurvivesLoginShellNoise() {
        XCTAssertEqual(
            RemoteCwdProbe.reportedPath(
                in: "nvm: N/A version not installed\n/usr/local/bin warning\nTESSERA_CWD=/home/user\n"
            ),
            "/home/user"
        )
        // Android's peer case, same answer.
        XCTAssertEqual(
            RemoteCwdProbe.reportedPath(in: "motd\nTESSERA_CWD=/srv/project\n"),
            "/srv/project"
        )
    }

    func testMissesReturnNil() {
        XCTAssertNil(RemoteCwdProbe.reportedPath(in: ""))
        XCTAssertNil(RemoteCwdProbe.reportedPath(in: "\n\n"))
        XCTAssertNil(RemoteCwdProbe.reportedPath(in: "/bare/path/without/marker"))
        XCTAssertNil(RemoteCwdProbe.reportedPath(in: "pgrep: not found"))
        XCTAssertNil(RemoteCwdProbe.reportedPath(in: "TESSERA_CWD=relative/garbage"))
        // Android's peer cases.
        XCTAssertNil(RemoteCwdProbe.reportedPath(in: "TESSERA_CWD=relative/path\n"))
        XCTAssertNil(RemoteCwdProbe.reportedPath(in: "motd only\n"))
    }

    // MARK: - discoveryCommand

    /// Hard-won rule: sshd runs exec payloads as `<login shell> -c`, and
    /// fish / (t)csh reject POSIX `sp=$(...)` outright — every payload
    /// rides an explicit `sh -c '...'`.
    func testCommandsRideExplicitPosixShell() {
        for discovery: RemoteCwdProbe.ShellDiscovery in [
            .moshServerChild(serverPID: 1), .newestLoginShell, .tmuxSession(name: "main"),
        ] {
            let cmd = RemoteCwdProbe.discoveryCommand(for: discovery)
            XCTAssertTrue(cmd.hasPrefix("sh -c '"), "\(discovery)")
            XCTAssertTrue(cmd.hasSuffix("'"), "\(discovery)")
            XCTAssertTrue(cmd.contains(RemoteCwdProbe.pathMarker), "\(discovery)")
            XCTAssertTrue(cmd.contains("exit 0"), "a miss must not surface as an exec error")
        }
    }

    /// Hard-won rule: single quotes inside a payload are escaped with the
    /// `'\''` idiom, which fish and csh parse the same way as sh.
    func testSingleQuotesUseTheEscapeIdiom() {
        let cmd = RemoteCwdProbe.discoveryCommand(for: .tmuxSession(name: "it's mine"))
        XCTAssertTrue(cmd.hasPrefix("sh -c '"))
        XCTAssertTrue(cmd.hasSuffix("'"))
        XCTAssertFalse(cmd.contains("it's mine"), "a raw quote would close the sh -c string")
        XCTAssertTrue(cmd.contains(#"it'\''"#))
        XCTAssertEqual(RemoteCwdProbe.posixWrapped("echo 'hi'"), #"sh -c 'echo '\''hi'\'''"#)
    }

    func testMoshCommandAnchorsOnServerPID() {
        let cmd = RemoteCwdProbe.discoveryCommand(for: .moshServerChild(serverPID: 4242))
        XCTAssertTrue(cmd.contains("pgrep -P 4242"))
        XCTAssertTrue(cmd.contains(#"readlink "/proc/$sp/cwd""#))
        XCTAssertTrue(cmd.contains("lsof"), "needs the macOS/BSD cwd fallback")
        XCTAssertTrue(cmd.contains("TESSERA_CWD="), "path line must be marker-tagged")
        XCTAssertTrue(cmd.contains("exit 0"), "a miss must not surface as an exec error")
    }

    /// Hard-won rule: the tty filter is what excludes the bridge's own
    /// tty-less exec wrapper shell (otherwise always the newest match),
    /// and the max-PID pick has to be explicit because BSD `ps` sorts by
    /// controlling tty, not by pid.
    func testLoginShellCommandFiltersAndPicksMaxPID() {
        let cmd = RemoteCwdProbe.discoveryCommand(for: .newestLoginShell)
        XCTAssertTrue(cmd.contains(#"$2 ~ /^(pts\/|ttys)/"#))
        XCTAssertTrue(cmd.contains(#"$3 !~ /ssh$/"#), "ssh clients also end in 'sh'")
        XCTAssertTrue(cmd.contains("if ($1+0 > p)"))
        XCTAssertTrue(cmd.contains("TESSERA_CWD="))
        XCTAssertTrue(cmd.contains("exit 0"))
    }

    /// Hard-won rule #1: the tmux target is the BARE session name. tmux
    /// matches exact names before prefixes, and the `=` exact-match prefix
    /// comes back EMPTY from display-message on tmux 3.6a (verified
    /// empirically — don't "fix" this back).
    func testTmuxSessionCommandTargetsBareName() {
        let cmd = RemoteCwdProbe.discoveryCommand(for: .tmuxSession(name: "main"))
        XCTAssertTrue(cmd.contains("display-message -p -t"))
        // The target rides the payload single-quoted, then the whole
        // payload is escaped again for the outer `sh -c '...'`.
        XCTAssertTrue(cmd.contains(#"-t '\''main'\''"#))
        XCTAssertFalse(cmd.contains("=main"))
        XCTAssertTrue(cmd.contains("pane_current_path"))
    }

    /// Hard-won rule #2: non-interactive sshd exec PATH omits the
    /// homebrew/local prefixes, so a macOS host's tmux
    /// (/opt/homebrew/bin/tmux) is invisible without the prefix.
    func testTmuxSessionCommandPrependsHomebrewPath() {
        let cmd = RemoteCwdProbe.discoveryCommand(for: .tmuxSession(name: "main"))
        XCTAssertTrue(cmd.contains(#"PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"; "#))
    }

    // MARK: - taskKey

    func testTaskKeyEncodesAllInputs() {
        XCTAssertEqual(
            RemoteCwdProbe.taskKey(
                panelOpen: true, sessionActive: true, tmuxAttached: false, serverPID: 99
            ),
            "open:active:plain:99"
        )
        XCTAssertEqual(
            RemoteCwdProbe.taskKey(panelOpen: false, sessionActive: false, tmuxAttached: true),
            "closed:bg:tmux:nopid"
        )
    }

    // MARK: - FollowDebounce (poll cadence)

    func testPollIntervalAndDebounceConstants() {
        XCTAssertEqual(RemoteCwdProbe.pollIntervalSeconds, 2.5, accuracy: 0.0001)
        XCTAssertEqual(RemoteCwdProbe.missesBeforeClearingFollow, 2)
    }

    func testDebounceReportsHitsAndResetsTheStreak() {
        var debounce = RemoteCwdProbe.FollowDebounce()
        XCTAssertEqual(debounce.step(.probed(output: "TESSERA_CWD=/srv\n")), .report("/srv"))
        XCTAssertEqual(debounce.consecutiveMisses, 0)
        XCTAssertEqual(debounce.step(.probed(output: "noise")), .hold)
        XCTAssertEqual(debounce.step(.probed(output: "TESSERA_CWD=/srv/a\n")), .report("/srv/a"))
        XCTAssertEqual(debounce.consecutiveMisses, 0)
    }

    /// Hard-won rule: a single miss is noise (shell mid-exec, pgrep
    /// hiccup) — follow only clears on the SECOND consecutive miss, and
    /// exactly once, so a permanently silent host doesn't re-clear an
    /// already-cleared follow every 2.5 s.
    func testDebounceClearsOnTheSecondMissAndOnlyOnce() {
        var debounce = RemoteCwdProbe.FollowDebounce()
        XCTAssertEqual(debounce.step(.probed(output: "")), .hold)
        XCTAssertEqual(debounce.step(.probed(output: "")), .clearFollow)
        XCTAssertEqual(debounce.step(.probed(output: "")), .hold)
        XCTAssertEqual(debounce.step(.probed(output: "")), .hold)
        XCTAssertEqual(debounce.consecutiveMisses, 4)
    }

    /// Hard-won rule: while OSC 7 is live it owns follow (instant and
    /// per-shell exact), so the probe is skipped and the miss streak
    /// resets — the poller must not clear a directory OSC 7 is reporting.
    func testOSCSignalStandsThePollerDown() {
        var debounce = RemoteCwdProbe.FollowDebounce()
        XCTAssertEqual(debounce.step(.probed(output: "")), .hold)
        XCTAssertEqual(debounce.step(.oscSignalLive), .hold)
        XCTAssertEqual(debounce.consecutiveMisses, 0)
        XCTAssertEqual(debounce.step(.probed(output: "")), .hold)
        XCTAssertEqual(debounce.step(.probed(output: "")), .clearFollow)
    }

    /// A disconnected bridge says nothing about where the shell is, so a
    /// tick that never ran a command must not count toward the streak.
    func testNotPolledTicksDoNotCountAsMisses() {
        var debounce = RemoteCwdProbe.FollowDebounce()
        XCTAssertEqual(debounce.step(.probed(output: "")), .hold)
        XCTAssertEqual(debounce.step(.notPolled), .hold)
        XCTAssertEqual(debounce.step(.notPolled), .hold)
        XCTAssertEqual(debounce.consecutiveMisses, 1)
        XCTAssertEqual(debounce.step(.probed(output: "")), .clearFollow)
    }

    /// Probe output is remote-controlled data with no `pathCandidate` gate in
    /// front of it, so a reported path smuggling C0/C1 bytes dies here
    /// (Android's hardening, adopted as the shared rule).
    func testReportedPathRejectsControlCharacters() {
        XCTAssertNil(RemoteCwdProbe.reportedPath(in: "TESSERA_CWD=/tmp/evil\u{1B}]0;x\u{07}dir"))
        XCTAssertNil(RemoteCwdProbe.reportedPath(in: "TESSERA_CWD=/tmp/nul\u{00}dir"))
        // NEL (U+0085) is a newline to `split`, so it terminates the line
        // before the scan — use a non-newline C1 control (CSI) here.
        XCTAssertNil(RemoteCwdProbe.reportedPath(in: "TESSERA_CWD=/tmp/c1\u{9B}dir"))
        XCTAssertEqual(
            RemoteCwdProbe.reportedPath(in: "TESSERA_CWD=/tmp/ordinary dir"),
            "/tmp/ordinary dir"
        )
    }
}
