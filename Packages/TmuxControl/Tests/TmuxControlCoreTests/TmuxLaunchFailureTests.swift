import XCTest
@testable import TmuxControlCore

/// The reporter's own capture is the first case here: a Pixel connecting to a
/// macOS host whose sshd shell cannot see Homebrew's tmux.
final class TmuxLaunchFailureTests: XCTestCase {

    func testTheReportedZshCommandNotFoundIsUnavailable() {
        XCTAssertEqual(
            TmuxLaunchFailure.classify(exitStatus: 127, output: "zsh:1: command not found: tmux\n"),
            .unavailable
        )
    }

    /// 127 is the shell's own "command not found", so it must classify even
    /// when the host localizes or suppresses the message.
    func testExitStatus127AloneIsUnavailable() {
        XCTAssertEqual(TmuxLaunchFailure.classify(exitStatus: 127, output: ""), .unavailable)
    }

    func testOtherShellsPhrasingIsUnavailable() {
        for message in [
            "bash: tmux: command not found",
            "sh: 1: tmux: not found",
            "/bin/sh: tmux: No such file or directory",
        ] {
            XCTAssertEqual(
                TmuxLaunchFailure.classify(exitStatus: nil, output: message),
                .unavailable,
                message
            )
        }
    }

    func testNestingIsReportedBeforeAnythingElse() {
        XCTAssertEqual(
            TmuxLaunchFailure.classify(
                exitStatus: 1,
                output: "sessions should be nested with care, unset $TMUX to force"
            ),
            .nested
        )
    }

    func testServerTroubleIsAStartFailure() {
        for message in [
            "no server running on /tmp/tmux-501/default",
            "failed to connect to server",
            "lost server",
            "open terminal failed: not a terminal",
        ] {
            XCTAssertEqual(
                TmuxLaunchFailure.classify(exitStatus: 1, output: message),
                .startFailed,
                message
            )
        }
    }

    /// An unrecognised message with a non-zero exit still failed to launch, and
    /// a plain shell beats the dead session the unclassified path produced.
    func testUnrecognisedNonZeroExitStillDegrades() {
        XCTAssertEqual(
            TmuxLaunchFailure.classify(exitStatus: 3, output: "something went sideways"),
            .startFailed
        )
    }

    /// The caller gates on non-engagement, but a clean exit with nothing to say
    /// is not evidence the launch failed — leave it to the disconnect path.
    func testCleanExitWithNoSignalIsNotALaunchFailure() {
        XCTAssertNil(TmuxLaunchFailure.classify(exitStatus: 0, output: ""))
        XCTAssertNil(TmuxLaunchFailure.classify(exitStatus: nil, output: ""))
    }

    /// "not found" about something other than tmux must not be read as a
    /// missing tmux: the host may simply have a noisy login banner.
    func testUnrelatedNotFoundTextIsNotUnavailable() {
        XCTAssertNil(
            TmuxLaunchFailure.classify(exitStatus: nil, output: "ls: /etc/motd.d: not found")
        )
    }

    /// The raw values cross the C ABI and are part of the contract.
    func testRawValuesAreStable() {
        XCTAssertEqual(TmuxLaunchFailure.unavailable.rawValue, 1)
        XCTAssertEqual(TmuxLaunchFailure.startFailed.rawValue, 2)
        XCTAssertEqual(TmuxLaunchFailure.nested.rawValue, 3)
    }
}
