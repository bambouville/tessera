import XCTest
@testable import TmuxSemanticsModel

/// Single rules of the model, each named after the tmux code it follows.
final class ModelRuleTests: XCTestCase {
    // MARK: Control-mode framing

    /// A command-line `attach-session` runs without CMDQ_STATE_CONTROL, so its
    /// block carries flags 0 (cmd-queue.c:618); `%session-changed` follows
    /// the block (control_notify_client_session_changed).
    func testAttachBlockHasFlagsZeroAndSessionChangedFollows() {
        let m = TmuxServerModel()
        let (session, _) = m.newSession("O", size: CellSize(80, 24))
        let client = m.connect(control: "device", session: session)
        XCTAssertEqual(normalized(m.take(client)), ["%begin 0", "%end 0", "%session-changed \(session) O"])
        XCTAssertEqual(normalized(m.send(client, "display-message -p ok")), ["%begin 1", "ok", "%end 1"])
    }

    /// Notifications are queued (notify_add) and delivered after the command
    /// list's blocks; `%session-window-changed` goes to every control client,
    /// `%layout-change` only to clients whose session holds the window.
    func testNotificationRoutingAndOrdering() {
        let m = TmuxServerModel()
        let (owner, _) = m.newSession("O", size: CellSize(80, 24))
        let w1 = m.newWindow(in: owner, name: "w1")
        let (other, otherWindow) = m.newSession("X", size: CellSize(80, 24))
        let device = m.connect(control: "device", session: owner)
        let stranger = m.connect(control: "stranger", session: other)
        _ = m.take(device)
        _ = m.take(stranger)

        XCTAssertEqual(normalized(m.send(device, "select-window -t :1")),
                       ["%begin 1", "%end 1", "%session-window-changed \(owner) \(w1)"])
        XCTAssertEqual(m.take(stranger), ["%session-window-changed \(owner) \(w1)"])

        m.send(device, "refresh-client -C 100,30")
        XCTAssertEqual(m.take(stranger).filter { $0.hasPrefix("%layout-change") }, [], "X does not hold O's windows")
        m.send(stranger, "refresh-client -C 90,20")
        XCTAssertEqual(m.windowSize(otherWindow), CellSize(90, 20))
        let deviceLayouts = m.take(device).filter { $0.hasPrefix("%layout-change") }
        XCTAssertFalse(deviceLayouts.contains { $0.hasPrefix("%layout-change \(otherWindow) ") })
        XCTAssertEqual(deviceLayouts.count, 2, "the stranger's forced pass still resizes O's two windows (W10)")
        assertFullyModelled(m)
    }

    // MARK: Options

    /// An untargeted `set-option @x` lands on the issuer's session; `-w` on
    /// the issuer's current window; `-t` on the named target; `-g` globally
    /// (options_scope_from_flags, options.c:855-907).
    func testOptionScopes() {
        let m = TmuxServerModel()
        let (owner, window) = m.newSession("O", size: CellSize(80, 24))
        let (other, _) = m.newSession("X", size: CellSize(80, 24))
        let device = m.connect(control: "device", session: owner)

        m.send(device, "set-option @a 1")
        m.send(device, "set-option -w @b 2")
        m.send(device, "set-option -t X @c 3")
        m.send(device, "set-option -g @d 4")
        XCTAssertEqual(m.sessionOption(owner, "@a"), "1")
        XCTAssertEqual(m.windowOption(window, "@b"), "2")
        XCTAssertEqual(m.sessionOption(other, "@c"), "3")
        XCTAssertNil(m.sessionOption(owner, "@d"))
        XCTAssertEqual(payload(m.send(device, "show-options -gv @d")), ["4"])
        XCTAssertEqual(payload(m.send(device, "show-options @a")), ["@a 1"])
        XCTAssertEqual(payload(m.send(device, "set-option @e 'two words' ; show-options @e")), ["@e \"two words\""])
        XCTAssertEqual(normalized(m.send(device, "set-option @f")), ["%begin 1", "empty value", "%error 1"])
        XCTAssertEqual(normalized(m.send(device, "set-option -t nowhere @g 1")),
                       ["%begin 1", "no such session: nowhere", "%error 1"],
                       "CMD_FIND_CANFAIL hides the lookup error; the scope reports it")
        XCTAssertEqual(normalized(m.send(device, "set-option -w window-size bogus")),
                       ["%begin 1", "unknown value: bogus", "%error 1"])
        assertFullyModelled(m)
    }

    /// format_find looks up options before variables, in the order server,
    /// pane, window, global window, session, global session
    /// (format.c:3573-3583): a window option hides a session option of the
    /// same name (W1).
    func testFormatLookupFindsWindowOptionBeforeSessionOption() {
        let m = TmuxServerModel()
        let (owner, _) = m.newSession("O", size: CellSize(80, 24))
        let device = m.connect(control: "device", session: owner)
        m.send(device, "set-option @x session")
        XCTAssertEqual(payload(m.send(device, "display-message -p '#{@x}'")), ["session"])
        m.send(device, "set-option -w @x window")
        XCTAssertEqual(payload(m.send(device, "display-message -p '#{@x}'")), ["window"])
        m.send(device, "set-option -g -w @x global-window")
        m.send(device, "set-option -w -u @x")
        XCTAssertEqual(payload(m.send(device, "display-message -p '#{@x}'")), ["global-window"],
                       "the global window table also precedes the session")
        XCTAssertEqual(payload(m.send(device, "display-message -p '#{?#{==:#{@x},global-window},yes,no}'")), ["yes"])
        assertFullyModelled(m)
    }

    /// options_push_changes (options.c:1103-1168) redraws every attached
    /// client after every set, including user options; a `-u` with nothing
    /// to remove does not push (cmd-set-option.c:180-182).
    func testOptionPushRedrawsEveryAttachedTerminal() {
        let m = TmuxServerModel()
        let (owner, _) = m.newSession("O", size: CellSize(80, 24))
        let (other, _) = m.newSession("X", size: CellSize(80, 24))
        let laptop = m.attachTTY("laptop", session: other, size: CellSize(120, 40))
        let device = m.connect(control: "device", session: owner)
        let before = m.repaints(laptop)
        m.send(device, "set-option @x 1")
        XCTAssertEqual(m.repaints(laptop), before + 1, "a session option of O repaints a terminal on X")
        m.send(device, "set-option -u @y")
        XCTAssertEqual(m.repaints(laptop), before + 1)
        assertFullyModelled(m)
    }

    // MARK: Sizing

    /// `refresh-client -C @W:WxH` exists from 3.3a (cmd-refresh-client.c:89-114);
    /// 3.2 rejects it as a bad size.
    func testPerWindowClientSizeIsVersionGated() {
        for version in TmuxVersion.allCases {
            let m = TmuxServerModel(version: version)
            let (owner, window) = m.newSession("O", size: CellSize(80, 24))
            let device = m.connect(control: "device", session: owner)
            let lines = m.send(device, "refresh-client -C \(window):100x30")
            if version.hasPerWindowClientSize {
                XCTAssertEqual(normalized(lines).prefix(2), ["%begin 1", "%end 1"], "\(version)")
                XCTAssertEqual(m.windowSize(window), CellSize(100, 30), "\(version)")
                m.send(device, "refresh-client -C \(window):100x40")
                XCTAssertEqual(m.windowSize(window), CellSize(100, 40))
                // Clearing keeps CLIENT_WINDOWSIZECHANGED (never cleared), so the
                // client now sizes from its tty: 80x24 from server_client_create
                // (server-client.c:275-276) until `-C W,H` sets it.
                m.send(device, "refresh-client -C \(window):")
                XCTAssertEqual(m.windowSize(window), CellSize(80, 24), "\(version)")
            } else {
                XCTAssertEqual(normalized(lines), ["%begin 1", "bad size argument", "%error 1"], "\(version)")
                XCTAssertEqual(m.windowSize(window), CellSize(80, 24))
            }
            assertFullyModelled(m)
        }
    }

    /// `refresh-client` handles -A, -B and -C exclusively, in that order
    /// (cmd-refresh-client.c:266-290): with `-B` present, `-C` is ignored.
    func testRefreshClientSubscriptionShadowsSize() {
        let m = TmuxServerModel()
        let (owner, window) = m.newSession("O", size: CellSize(80, 24))
        let device = m.connect(control: "device", session: owner)
        m.send(device, "refresh-client -B 'x:@*:#{window_id}' -C 100,30")
        XCTAssertEqual(m.windowSize(window), CellSize(80, 24))
        XCTAssertEqual(normalized(m.send(device, "refresh-client -C 0,30")),
                       ["%begin 1", "size too small or too big", "%error 1"])
        XCTAssertEqual(normalized(m.send(device, "refresh-client -C abc")),
                       ["%begin 1", "bad size argument", "%error 1"])
        assertFullyModelled(m)
    }

    /// ignore_client_size (resize.c:68-96): an ignore-size client is ignored
    /// only while some attached client without ignore-size exists. Alone, it
    /// sizes the window.
    func testIgnoreSizeClientSizesWhenAlone() {
        let m = TmuxServerModel()
        let (owner, window) = m.newSession("O", size: CellSize(80, 24))
        let visible = m.attachTTY("mosh-visible", session: owner, size: CellSize(100, 31), flags: ["ignore-size"])
        XCTAssertEqual(m.windowSize(window), CellSize(100, 30))
        let device = m.connect(control: "device", session: owner)
        XCTAssertEqual(m.windowSize(window), CellSize(100, 30))
        m.send(device, "refresh-client -C 70,20")
        XCTAssertEqual(m.windowSize(window), CellSize(70, 20),
                       "the device took latest on attach; the visible client is now ignored")
        _ = visible
        assertFullyModelled(m)
    }

    /// `resize-window` is immediate and makes the window manual
    /// (cmd-resize-window.c:109-112); unsetting `window-size` returns it to
    /// `latest` through a deferred pass.
    func testResizeWindowIsImmediateAndManual() {
        for version in TmuxVersion.allCases {
            let m = TmuxServerModel(version: version)
            let (owner, window) = m.newSession("O", size: CellSize(80, 24))
            let laptop = m.attachTTY("laptop", session: owner, size: CellSize(120, 40))
            let admin = m.admin("resize-window -x 50 -y 20 -t \(window)")
            XCTAssertEqual(admin.errors, [])
            XCTAssertEqual(m.windowSize(window), CellSize(50, 20), "\(version)")
            XCTAssertEqual(m.windowOption(window, "window-size"), "manual")
            m.resizeTTY(laptop, to: CellSize(130, 41))
            XCTAssertEqual(m.windowSize(window), CellSize(50, 20), "manual windows ignore clients (\(version))")
            m.admin("set-option -w -u -t \(window) window-size")
            XCTAssertEqual(m.windowSize(window), CellSize(130, 40), "\(version)")
            XCTAssertEqual(m.admin("resize-window -x 0 -t \(window)").errors, ["width too small"])
            assertFullyModelled(m)
        }
    }

    /// select-window makes an attached issuer `latest` even when it is an
    /// unsized control client (cmd-select-window.c:145-146); while it holds
    /// `latest`, a second sizing client cannot size the window.
    func testSelectWindowGivesLatestToUnsizedControlClient() {
        let m = TmuxServerModel()
        let (owner, window) = m.newSession("O", size: CellSize(80, 24))
        let laptop = m.attachTTY("laptop", session: owner, size: CellSize(120, 40))
        let other = m.connect(control: "other", session: owner)
        m.send(other, "refresh-client -C 90,30")
        m.typeKey(laptop)
        XCTAssertEqual(m.windowSize(window), CellSize(120, 39))
        let device = m.connect(control: "device", session: owner)
        m.typeKey(laptop)
        m.send(device, "select-window")
        XCTAssertEqual(m.latest(window), .client("device"))
        m.resizeTTY(laptop, to: CellSize(140, 45))
        XCTAssertEqual(m.latest(window), .client("laptop"), "MSG_RESIZE moves latest back")
        XCTAssertEqual(m.windowSize(window), CellSize(140, 44))
        assertFullyModelled(m)
    }

    /// server_client_attached_lost (server-client.c:328-357): with no
    /// remaining client showing the window, `latest` keeps the lost client.
    func testLatestDanglesWithoutCandidate() {
        let m = TmuxServerModel(version: .v3_4)
        let (owner, window) = m.newSession("O", size: CellSize(80, 24))
        let w1 = m.newWindow(in: owner, name: "w1")
        let user = m.newGroupedSession("U", groupedWith: owner)
        let laptop = m.attachTTY("laptop", session: user, size: CellSize(120, 40))
        m.admin("select-window -t U:1")
        let device = m.connect(control: "device", session: owner)
        m.send(device, "refresh-client -C 100,30")
        XCTAssertEqual(m.latest(window), .client("device"))
        m.lose(device)
        XCTAssertEqual(m.latest(window), .dangling("device"), "the laptop shows w1, not w0")
        XCTAssertEqual(m.currentWindow(user), w1)
        _ = laptop
        assertFullyModelled(m)
    }

    // MARK: Lists and versions

    /// `list-clients -t S` lists only clients whose session is exactly S
    /// (cmd-list-clients.c:76-78); `-f` exists from 3.4.
    func testListClientsTargetAndFilterVersions() {
        for version in TmuxVersion.allCases {
            let m = TmuxServerModel(version: version)
            let (owner, _) = m.newSession("O", size: CellSize(80, 24))
            let view = m.newGroupedSession("V", groupedWith: owner)
            let a = m.connect(control: "a", session: owner)
            _ = m.connect(control: "b", session: view)
            XCTAssertEqual(payload(m.send(a, "list-clients -t V -F '#{client_name} #{session_name}'")), ["b V"])
            let filtered = normalized(m.send(a, "list-clients -f '#{==:#{session_name},O}' -F '#{client_name}'"))
            switch version {
            case .v3_2:
                XCTAssertEqual(filtered, ["%begin 1", "parse error: usage: list-clients [-F format] [-t target-session]", "%error 1"])
            case .v3_3a:
                XCTAssertEqual(filtered, ["%begin 1", "parse error: command list-clients: unknown flag -f", "%error 1"])
            case .v3_4, .v3_6a:
                XCTAssertEqual(filtered, ["%begin 1", "a", "%end 1"])
            }
            let line = payload(m.send(a, "list-clients -t O"))
            XCTAssertEqual(line, ["a: O [80x24 xterm-256color] (attached,focused,control-mode)"])
            assertFullyModelled(m)
        }
    }

    /// Subscriptions evaluate only the subscriber's own session
    /// (control_check_subs_all_panes, control.c:907-954): a view never sees
    /// the owner's session stamp, but does see a window stamp.
    func testPaneSubscriptionSeesOnlyOwnSession() {
        let m = TmuxServerModel()
        let (owner, window) = m.newSession("O", size: CellSize(80, 24))
        let view = m.newGroupedSession("V", groupedWith: owner)
        let ssh = m.connect(control: "ssh", session: owner)
        let mosh = m.connect(control: "mosh", session: view)
        m.send(mosh, "refresh-client -B 'stamp:%*:#{@stamp}'")
        m.send(ssh, "set-option @stamp A")
        _ = m.take(mosh)
        m.advance(seconds: 1)
        XCTAssertEqual(m.take(mosh), ["%subscription-changed stamp \(view) \(window) 0 %0 : "])
        m.send(ssh, "set-option -w @stamp A")
        m.advance(seconds: 1)
        XCTAssertEqual(m.take(mosh).filter { $0.hasPrefix("%subscription") },
                       ["%subscription-changed stamp \(view) \(window) 0 %0 : A"])
        assertFullyModelled(m)
    }

    func testServerVersionMapping() {
        XCTAssertEqual(TmuxVersion.forServerVersion("tmux 3.4")?.version, .v3_4)
        XCTAssertEqual(TmuxVersion.forServerVersion("tmux 3.4")?.exact, true)
        XCTAssertEqual(TmuxVersion.forServerVersion("tmux 3.5a")?.version, .v3_4)
        XCTAssertEqual(TmuxVersion.forServerVersion("tmux 3.5a")?.exact, false)
        XCTAssertEqual(TmuxVersion.forServerVersion("tmux 3.3")?.version, .v3_3a)
        XCTAssertEqual(TmuxVersion.forServerVersion("tmux 3.2a")?.version, .v3_2)
        XCTAssertEqual(TmuxVersion.forServerVersion("tmux next-3.7")?.version, nil)
        XCTAssertNil(TmuxVersion.forServerVersion("tmux 2.9"))
    }
}
