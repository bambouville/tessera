import XCTest
@testable import Tessera

// Pure-helper coverage for the shared cwd poller (the loop itself is
// exercised through the session views; these pin the shell commands,
// output parsing, and task-identity recipe).
final class RemoteCwdPollerTests: XCTestCase {

    // MARK: - reportedPath(in:)

    func testMarkerLineWins() {
        XCTAssertEqual(
            RemoteCwdPoller.reportedPath(in: "TESSERA_CWD=/home/user/src\n"),
            "/home/user/src"
        )
        XCTAssertEqual(
            RemoteCwdPoller.reportedPath(in: "  TESSERA_CWD=/tmp \nTESSERA_CWD=/other\n"),
            "/tmp"
        )
    }

    func testMarkerSurvivesLoginShellNoise() {
        // rc files sourced by the remote login shell (zshenv, bashrc
        // under SSH_SOURCE_BASHRC) print into the merged exec stream
        // ahead of our output — the marker keeps parsing alive.
        XCTAssertEqual(
            RemoteCwdPoller.reportedPath(
                in: "nvm: N/A version not installed\n/usr/local/bin warning\nTESSERA_CWD=/home/user\n"
            ),
            "/home/user"
        )
    }

    func testMissesReturnNil() {
        XCTAssertNil(RemoteCwdPoller.reportedPath(in: ""))
        XCTAssertNil(RemoteCwdPoller.reportedPath(in: "\n\n"))
        XCTAssertNil(RemoteCwdPoller.reportedPath(in: "/bare/path/without/marker"))
        XCTAssertNil(RemoteCwdPoller.reportedPath(in: "pgrep: not found"))
        XCTAssertNil(RemoteCwdPoller.reportedPath(in: "TESSERA_CWD=relative/garbage"))
    }

    // MARK: - discoveryCommand(for:)

    func testCommandsRideExplicitPosixShell() {
        // sshd runs exec payloads via `<login shell> -c`; fish and
        // (t)csh reject POSIX `sp=$(...)`, so both commands must wrap
        // themselves in `sh -c '...'`.
        for discovery: RemoteCwdPoller.ShellDiscovery
            in [.moshServerChild(serverPID: 1), .newestLoginShell] {
            let cmd = RemoteCwdPoller.discoveryCommand(for: discovery)
            XCTAssertTrue(cmd.hasPrefix("sh -c '"))
            XCTAssertTrue(cmd.hasSuffix("'"))
        }
    }

    func testMoshCommandAnchorsOnServerPID() {
        let cmd = RemoteCwdPoller.discoveryCommand(for: .moshServerChild(serverPID: 4242))
        XCTAssertTrue(cmd.contains("pgrep -P 4242"))
        XCTAssertTrue(cmd.contains(#"readlink "/proc/$sp/cwd""#))
        XCTAssertTrue(cmd.contains("lsof"), "needs the macOS/BSD cwd fallback")
        XCTAssertTrue(cmd.contains("TESSERA_CWD="), "path line must be marker-tagged")
        XCTAssertTrue(cmd.contains("exit 0"), "a miss must not surface as an exec error")
    }

    func testTmuxSessionCommandTargetsBareName() {
        let cmd = RemoteCwdPoller.discoveryCommand(for: .tmuxSession(name: "main"))
        XCTAssertTrue(cmd.hasPrefix("sh -c '"))
        XCTAssertTrue(cmd.contains(#"PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"; "#),
                      "homebrew tmux is off the non-interactive sshd PATH on macOS hosts")
        XCTAssertTrue(cmd.contains("display-message -p -t"))
        XCTAssertFalse(cmd.contains("=main"),
                       "the = exact-match prefix returns EMPTY from display-message on tmux 3.6a")
        XCTAssertTrue(cmd.contains("pane_current_path"))
        XCTAssertTrue(cmd.contains("TESSERA_CWD="))
        XCTAssertTrue(cmd.contains("exit 0"))
    }

    func testLoginShellCommandFiltersAndPicksMaxPID() {
        let cmd = RemoteCwdPoller.discoveryCommand(for: .newestLoginShell)
        XCTAssertTrue(cmd.contains(#"$2 ~ /^(pts\/|ttys)/"#),
                      "tty filter is what excludes the bridge's own exec wrapper")
        XCTAssertTrue(cmd.contains(#"$3 !~ /ssh$/"#), "ssh clients also end in 'sh'")
        XCTAssertTrue(cmd.contains("if ($1+0 > p)"),
                      "must pick max PID explicitly — macOS ps sorts by tty, not pid")
        XCTAssertTrue(cmd.contains("TESSERA_CWD="))
        XCTAssertTrue(cmd.contains("exit 0"))
    }

    // MARK: - taskKey

    func testTaskKeyEncodesAllInputs() {
        XCTAssertEqual(
            RemoteCwdPoller.taskKey(
                panelOpen: true, sessionActive: true,
                tmuxAttached: false, serverPID: 99
            ),
            "open:active:plain:99"
        )
        XCTAssertEqual(
            RemoteCwdPoller.taskKey(
                panelOpen: false, sessionActive: false, tmuxAttached: true
            ),
            "closed:bg:tmux:nopid"
        )
    }
}
