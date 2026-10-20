import XCTest
@testable import TmuxControlCore

final class AgentCommandAccessTests: XCTestCase {
    func testReadsAreReadOnlyAndLaunchWritesAreNot() {
        for command in [
            "display-message -p -t %3 '#{window_id}'", "display -p x", "capture-pane -p -t %3",
            "capturep -p", "show-options -p -v -t %3 @tessera_agent_launch_receipt", "show -gv x",
            "list-panes -s -F '#{pane_id}'", "list-windows", "list-sessions", "list-clients",
            "delete-buffer -b 'tessera-agent-launch-1'", "  display-message -p x",
        ] {
            XCTAssertTrue(TmuxAgentCommandAccess.isReadOnly(command), command)
        }
        for command in [
            "set-buffer -b b 'eA=='", "new-window -d -P -F '#{pane_id}'",
            "split-window -d -P -F '#{pane_id}' -h -t '%3' helper", "send-keys -t %3 -H 61",
            "select-window -t @1", "kill-pane -t %3", "display-messagex", "", "   ",
        ] {
            XCTAssertFalse(TmuxAgentCommandAccess.isReadOnly(command), command)
        }
    }

    func testReadsAndStrictPaneRepliesAreAuthorityNeutral() {
        for command in [
            "display-message -p -t %3 '#{window_id}'", "capture-pane -p -t %3", "list-panes -s",
            "delete-buffer -b b", "send-keys -t %3 -H 61", "send-keys -t %0 -H 00 ff AA 9F",
            "send-keys -t %123 Enter", "send-keys -t %3 Escape", "send-keys -t %3 Tab",
            "send-keys -t %3 BTab", "send-keys -t %3 Up", "send-keys -t %3 Down",
            "send-keys -t %3 Left", "send-keys -t %3 Right", "send-keys -t %3 S-Left",
            "send-keys -t %3 C-]", "  send-keys\t-t %3  -H 61  ",
        ] {
            XCTAssertTrue(TmuxAgentCommandAccess.isAuthorityNeutral(command), command)
        }
        XCTAssertFalse(TmuxAgentCommandAccess.isReadOnly("send-keys -t %3 -H 61"))
    }

    func testOtherFlagsTargetsKeysAndCompoundCommandsAreNotNeutral() {
        let commands = [
            "", "   ", "send-keys", "send-keys -t %3", "send-keys -t %3 -H",
            "send-keys -t %3 -H 6", "send-keys -t %3 -H 061", "send-keys -t %3 -H gg",
            "send-keys -t %3 -H 0x61", "send-keys -t %3 -H '61'", "send-keys -t %3 -H ６１",
            "send-keys -t %3 Enter Escape", "send-keys -t %3 enter", "send-keys -t %3 up",
            "send-keys -t %3 S-Right", "send-keys -t %3 C-c",
            "send-keys -t %3 C-m", "send-keys -t %3 -H 61 Enter", "send-keys -H -t %3 61",
            "send-keys -t '%3' Enter", "send-keys -t % Enter", "send-keys -t %٣ Enter",
            "send-keys -t @3 Enter", "send-keys -t $3 Enter", "send-keys -t :3 Enter",
            "send-keys -t .3 Enter", "send-keys -t %3.1 Enter", "send-keys -t %3:1 Enter",
            "send-keys -t %3 Enter; new-window", "send-keys -t %3 Enter \\; new-window",
            "send-keys -t %3 -H 61\n", "send-keys -t %3 Enter\r", "send-keys -t %3 Enter\u{0}",
            "send-keys -t %3\u{00a0}Enter", "new-window -d", "set-buffer -b b x",
            "split-window -d -t %3", "select-window -t @3", "select-pane -t %3",
        ]
        for command in commands {
            XCTAssertFalse(TmuxAgentCommandAccess.isAuthorityNeutral(command), command)
        }
        for flag in ["-X", "-R", "-M", "-F", "-N", "-l", "-K", "-c"] {
            XCTAssertFalse(TmuxAgentCommandAccess.isAuthorityNeutral("send-keys -t %3 \(flag) Enter"), flag)
            XCTAssertFalse(TmuxAgentCommandAccess.isAuthorityNeutral("send-keys \(flag) -t %3 Enter"), flag)
            XCTAssertFalse(TmuxAgentCommandAccess.isAuthorityNeutral("send-keys -t %3 -H 61 \(flag)"), flag)
        }
    }
}
