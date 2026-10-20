import XCTest
@testable import TmuxSemanticsModel

/// Rules a source review of the model found wrong, each pinned to the tmux
/// code it now follows.
final class SourceReviewTests: XCTestCase {
    private func attached(_ m: TmuxServerModel, _ name: String, to session: SessionHandle) -> ClientHandle {
        let client = m.connect(control: name, session: session)
        _ = m.take(client)
        return client
    }

    /// cmd-refresh-client.c:89-114: after `@%u:%ux%u` fails, `sscanf("@%u:")`
    /// returns 1 whether or not the colon follows, so `@0`, `@0:` and
    /// `@0:junk` all clear the window's size (3.3a+).
    func testPerWindowSizeClearsOnAnyWindowForm() {
        for suffix in ["", ":", ":junk"] {
            let m = TmuxServerModel(version: .v3_4)
            let (session, window) = m.newSession("O", size: CellSize(80, 24))
            let device = attached(m, "device", to: session)
            m.send(device, "refresh-client -C \(window):100x30")
            XCTAssertEqual(m.windowSize(window), CellSize(100, 30))
            XCTAssertEqual(normalized(m.send(device, "refresh-client -C \(window)\(suffix)")).prefix(2), ["%begin 1", "%end 1"])
            XCTAssertEqual(m.windowSize(window), CellSize(80, 24), "`\(window)\(suffix)` clears the per-window size")
            assertFullyModelled(m)
        }
        let m = TmuxServerModel(version: .v3_2)
        let (session, window) = m.newSession("O", size: CellSize(80, 24))
        let device = attached(m, "device", to: session)
        XCTAssertEqual(payload(m.send(device, "refresh-client -C \(window)")), ["bad size argument"], "3.2 has no per-window form")
    }

    /// cmd-attach-session.c:92-100: a session target's winlink (its current
    /// window) becomes the command list's current target too, so a later
    /// untargeted command in the same line acts on the attached session.
    func testAttachMakesItsTargetCurrentForLaterCommands() {
        let m = TmuxServerModel()
        let (a, _) = m.newSession("A", size: CellSize(80, 24))
        m.newWindow(in: a, name: "a1")
        m.newSession("B", size: CellSize(80, 24))
        let device = attached(m, "device", to: a)
        let reply = m.send(device, "select-window -t A:1 ; attach-session -t B ; display-message -p '#{session_name}:#{window_index}'")
        XCTAssertEqual(payload(reply), ["B:0"])
        assertFullyModelled(m)
    }

    /// cmd-find.c:175-202 passes the lookup's flags to
    /// cmd_find_best_session (cmd-find.c:193), so attach-session's
    /// PREFER_UNATTACHED (cmd-attach-session.c:79-86) picks the unattached
    /// session holding a bare `@W`; other commands pick the most active one.
    func testBareWindowAttachPrefersAnUnattachedSession() {
        let m = TmuxServerModel()
        let (owner, window) = m.newSession("A", size: CellSize(80, 24))
        m.newGroupedSession("B", groupedWith: owner)
        let (other, _) = m.newSession("X", size: CellSize(80, 24))
        let laptop = m.attachTTY("laptop", session: owner, size: CellSize(100, 40))
        m.typeKey(laptop)
        let device = attached(m, "device", to: other)
        XCTAssertEqual(payload(m.send(device, "display-message -p -t \(window) '#{session_name}'")), ["A"])
        m.send(device, "attach-session -t \(window)")
        XCTAssertEqual(payload(m.send(device, "display-message -p '#{session_name}'")), ["B"])
        assertFullyModelled(m)
    }

    /// window_pane_resize queues a pane resize only when the pane's size
    /// changes (window.c:1066-1074); a forced unchanged pass still resizes
    /// the window and notifies (W10).
    func testPaneResizesCountOnlyGeometryChanges() {
        let m = TmuxServerModel()
        let (session, window) = m.newSession("O", size: CellSize(80, 24))
        let device = attached(m, "device", to: session)
        m.send(device, "refresh-client -C 100,30")
        XCTAssertEqual(m.paneResizes(window), 1)
        let resizes = m.resizeCount(window)
        m.send(device, "refresh-client -C 100,30")
        XCTAssertEqual(m.resizeCount(window), resizes + 1)
        XCTAssertEqual(m.paneResizes(window), 1)
        assertFullyModelled(m)
    }

    /// format_find reads options with options_to_string(o, idx, 1)
    /// (format.c:3584): a flag is `1`/`0` (options.c:151-155), which is what
    /// `list-clients -f` tests; show-options stays `on`/`off`.
    func testFlagOptionsFormatAsNumbers() {
        let m = TmuxServerModel(version: .v3_4)
        let (session, _) = m.newSession("O", size: CellSize(80, 24))
        let device = attached(m, "device", to: session)
        XCTAssertEqual(payload(m.send(device, "display-message -p '#{mouse}'")), ["0"])
        XCTAssertEqual(payload(m.send(device, "list-clients -f '#{mouse}' -F '#{client_name}'")), [])
        m.send(device, "set-option mouse on")
        XCTAssertEqual(payload(m.send(device, "display-message -p '#{mouse}'")), ["1"])
        XCTAssertEqual(payload(m.send(device, "show-options -v mouse")), ["on"])
        XCTAssertEqual(payload(m.send(device, "list-clients -f '#{mouse}' -F '#{client_name}'")), ["device"])
        assertFullyModelled(m)
    }

    /// server_client_set_flags (server-client.c:3147-3152): from 3.3a `!`
    /// cannot clear read-only; 3.2 clears it (3.2 server-client.c:2380-2383).
    func testNegatedReadOnlyIsKeptFrom33a() {
        for version in TmuxVersion.allCases {
            let m = TmuxServerModel(version: version)
            let (session, _) = m.newSession("O", size: CellSize(80, 24))
            let device = attached(m, "device", to: session)
            m.send(device, "refresh-client -f read-only,no-output")
            m.send(device, "refresh-client -f '!read-only,!no-output'")
            let flags = m.clientFlags(device)
            XCTAssertEqual(flags.contains("read-only"), version >= .v3_3a, "\(version.rawValue): \(flags)")
            XCTAssertFalse(flags.contains("no-output"), "\(version.rawValue): other flags still clear")
            assertFullyModelled(m)
        }
    }

    /// server_client_control_flags (server-client.c:3102-3117): `pause-after`
    /// keeps the scanned age for the client's flags (server-client.c:3180-3183);
    /// a value sscanf cannot read sets nothing.
    func testPauseAfterKeepsItsAge() {
        let m = TmuxServerModel(version: .v3_4)
        let (session, _) = m.newSession("O", size: CellSize(80, 24))
        let device = attached(m, "device", to: session)
        m.send(device, "refresh-client -f pause-after=5")
        XCTAssertTrue(m.clientFlags(device).contains("pause-after=5"), m.clientFlags(device))
        let other = attached(m, "other", to: session)
        m.send(other, "refresh-client -f pause-after=junk")
        XCTAssertFalse(m.clientFlags(other).contains("pause-after"), m.clientFlags(other))
        assertFullyModelled(m)
    }

    /// cmd-refresh-client.c:63-73 reads selectors with sscanf `%d`.
    func testSubscriptionSelectorsScanLikeSscanf() {
        XCTAssertEqual(TmuxServerModel.subscriptionKind("@0junk"), .window(0))
        XCTAssertEqual(TmuxServerModel.subscriptionKind("%3x"), .pane(3))
        XCTAssertEqual(TmuxServerModel.subscriptionKind("% 2"), .pane(2))
        XCTAssertEqual(TmuxServerModel.subscriptionKind("%-1"), .session)
        XCTAssertEqual(TmuxServerModel.subscriptionKind("%*"), .allPanes)
        XCTAssertEqual(TmuxServerModel.subscriptionKind("@*"), .allWindows)
        XCTAssertEqual(TmuxServerModel.subscriptionKind("@x"), .session)
    }

    /// destroy-unattached is a flag in 3.2/3.3a and a choice from 3.4
    /// (options-table.c:87-89, 488-492).
    func testDestroyUnattachedTypeFollowsTheVersion() {
        for version in TmuxVersion.allCases {
            let m = TmuxServerModel(version: version)
            let (session, _) = m.newSession("O", size: CellSize(80, 24))
            let device = attached(m, "device", to: session)
            let keepLast = payload(m.send(device, "set-option destroy-unattached keep-last"))
            let yes = payload(m.send(device, "set-option destroy-unattached yes"))
            if version >= .v3_4 {
                XCTAssertEqual(keepLast, [])
                XCTAssertEqual(yes, ["unknown value: yes"])
            } else {
                XCTAssertEqual(keepLast, ["bad value: keep-last"])
                XCTAssertEqual(yes, [])
            }
            assertFullyModelled(m)
        }
    }

    /// Tessera's view session: `keep-last` destroys it when its last client
    /// goes while the owner still shares the group (server_check_unattached,
    /// server-fn.c:456-484, from server_client_lost, server-client.c:468).
    /// session_destroy notifies session-closed and window-unlinked
    /// (session.c:200-233); a client whose session still links the window
    /// is told `%window-close` (control-notify.c:94-109).
    func testKeepLastDestroysTheViewWhenItsClientGoes() {
        let m = TmuxServerModel(version: .v3_4)
        let (owner, window) = m.newSession("O", size: CellSize(80, 24))
        let view = m.newGroupedSession("O-view", groupedWith: owner)
        let (probes, _) = m.newSession("probes", size: CellSize(80, 24))
        let probe = attached(m, "probe", to: probes)
        let laptop = attached(m, "laptop", to: owner)
        let side = attached(m, "side", to: view)
        m.send(side, "set-option destroy-unattached keep-last")
        _ = m.take(probe)
        _ = m.take(laptop)
        m.lose(side)
        XCTAssertNil(m.sessionHandle(named: "O-view"))
        XCTAssertNotNil(m.sessionHandle(named: "O"))
        XCTAssertEqual(m.take(probe), ["%client-detached side", "%sessions-changed", "%unlinked-window-close \(window)"])
        XCTAssertEqual(m.take(laptop), ["%client-detached side", "%sessions-changed", "%window-close \(window)"],
                       "O still links the window, so its client is told it closed")
        XCTAssertEqual(payload(m.send(laptop, "display-message -p '#{session_grouped}'")), ["1"], "a group of one survives")
        assertFullyModelled(m)
    }

    /// keep-last keeps a session with no group (server-fn.c:470-473); `on`
    /// does not.
    func testKeepLastKeepsAnUngroupedSession() {
        for value in ["keep-last", "on"] {
            let m = TmuxServerModel(version: .v3_4)
            let (session, _) = m.newSession("X", size: CellSize(80, 24))
            let device = attached(m, "device", to: session)
            m.send(device, "set-option destroy-unattached \(value)")
            m.lose(device)
            XCTAssertEqual(m.sessionHandle(named: "X") == nil, value == "on", value)
            assertFullyModelled(m)
        }
    }

    /// From 3.3a server_client_set_session ends with server_check_unattached
    /// (server-client.c:388), so switching away destroys the old session at
    /// once; 3.2 checks only when a client is lost (3.2 server-client.c:347).
    func testSwitchingAwayDestroysFrom33a() {
        for version in TmuxVersion.allCases {
            let m = TmuxServerModel(version: version)
            let (a, _) = m.newSession("A", size: CellSize(80, 24))
            m.newSession("B", size: CellSize(80, 24))
            let device = attached(m, "device", to: a)
            m.send(device, "set-option destroy-unattached on")
            m.send(device, "attach-session -t B")
            XCTAssertEqual(m.sessionHandle(named: "A") == nil, version >= .v3_3a, version.rawValue)
            assertFullyModelled(m)
        }
    }

    /// spawn.c:149-151 and winlink_add (window.c:168-170): automatic indexes
    /// start at the session's base-index.
    func testNewWindowsStartAtBaseIndex() {
        let m = TmuxServerModel()
        let (session, _) = m.newSession("O", size: CellSize(80, 24))
        _ = m.admin("set-option -g base-index 5")
        let window = m.newWindow(in: session, name: "w1")
        XCTAssertEqual(m.admin("display-message -p -t \(window) '#{window_index}'").output, ["5"])
        assertFullyModelled(m)
    }

    /// default_window_size's manual path (resize.c:321-339): sscanf `%ux%u`
    /// of default-size, then clamping to WINDOW_MAXIMUM.
    func testDefaultSizeIsScannedAndClamped() {
        let m = TmuxServerModel()
        let (session, _) = m.newSession("O", size: CellSize(80, 24))
        XCTAssertEqual(m.admin("set-option -t O default-size 100x30junk").errors, [])
        XCTAssertEqual(m.windowSize(m.newWindow(in: session, name: "a")), CellSize(100, 30))
        XCTAssertEqual(m.admin("set-option -t O default-size 12000x30").errors, [])
        XCTAssertEqual(m.windowSize(m.newWindow(in: session, name: "b")), CellSize(10000, 30))
        assertFullyModelled(m)
    }

    /// options_match (options.c:636-676) over the whole table: unique
    /// prefixes resolve, shared ones are ambiguous, unknown names invalid.
    func testOptionNamesResolveLikeOptionsMatch() {
        let m = TmuxServerModel(version: .v3_4)
        let (session, window) = m.newSession("O", size: CellSize(80, 24))
        let device = attached(m, "device", to: session)
        XCTAssertEqual(payload(m.send(device, "set-option -w window-si smallest")), [])
        XCTAssertEqual(m.windowOption(window, "window-size"), "smallest")
        XCTAssertEqual(payload(m.send(device, "set-option status- x")), ["ambiguous option: status-"])
        XCTAssertEqual(payload(m.send(device, "set-option nosuch x")), ["invalid option: nosuch"])
        XCTAssertEqual(payload(m.send(device, "show-options -qv nosuch")), [])
        XCTAssertEqual(payload(m.send(device, "show-options -v statu")), ["ambiguous option: statu"],
                       "status, status-bg, status-fg, ... all start with statu")
        XCTAssertEqual(payload(m.send(device, "show-options -gv destroy-un")), ["off"], "a unique prefix")
        assertFullyModelled(m)

        let unmodelled = TmuxServerModel(version: .v3_4)
        let (other, _) = unmodelled.newSession("O", size: CellSize(80, 24))
        let client = attached(unmodelled, "device", to: other)
        unmodelled.send(client, "set-option -g history-limit 5")
        XCTAssertEqual(unmodelled.unsupported, ["set-option: option history-limit"], "a real option outside the model")
    }

    /// A command-line parse error goes through cmdq_error (stderr for a
    /// client without a session) and the client exits
    /// (server-client.c:2915-2921); a command client that did not attach
    /// exits after its command (server_client_command_done,
    /// server-client.c:2840-2852).
    func testCommandLineErrorsReachStderrAndTheClientExits() {
        let m = TmuxServerModel()
        let (session, _) = m.newSession("O", size: CellSize(80, 24))
        XCTAssertEqual(m.admin("refresh-client -Q").errors, ["command refresh-client: unknown flag -Q"])
        let probe = attached(m, "probe", to: session)
        let ghost = m.connect(control: "ghost", session: SessionHandle(id: 42))
        XCTAssertEqual(normalized(m.take(ghost)), ["%begin 0", "can't find session: $42", "%error 0"])
        XCTAssertEqual(payload(m.send(probe, "list-clients -F '#{client_name}'")), ["probe"])
        XCTAssertEqual(m.take(probe), [], "a client that never attached is not reported detached")
        assertFullyModelled(m)
    }
}
