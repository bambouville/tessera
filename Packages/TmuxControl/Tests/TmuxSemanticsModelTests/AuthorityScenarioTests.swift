import XCTest
import TmuxControlCore
@testable import TmuxSemanticsModel

/// The review's authority scenarios (docs/reviews/takeover-authority-review-2026-10-05.md
/// D1, D2 and §6.2 W2, W3, W4, W9, W10), replayed against the model.
final class AuthorityScenarioTests: XCTestCase {
    // MARK: D1

    /// D1: the untargeted stamp is a *session* option; grouped sessions share
    /// windows but not options, so the owner and the view never see each
    /// other's stamp. `list-clients -t <own session>` never lists the peer and
    /// `%client-detached` reaches everyone. A window-scoped stamp is visible
    /// from both, because format lookup finds window options before session
    /// ones.
    func testD1SessionStampIsInvisibleAcrossOwnerAndView() {
        for version in TmuxVersion.allCases {
            let m = TmuxServerModel(version: version)
            let (owner, window) = m.newSession("O", size: CellSize(80, 24), windowName: "w0")
            let view = m.newGroupedSession("O-tessera-view", groupedWith: owner)
            let ssh = m.connect(control: "ssh-device", session: owner)
            let mosh = m.connect(control: "mosh-side", session: view, flags: ["no-output"])
            _ = m.take(ssh)
            _ = m.take(mosh)

            XCTAssertEqual(normalized(m.send(ssh, "set-option @tessera_authority 'v1 A 1 iPad'")), ["%begin 1", "%end 1"])
            XCTAssertEqual(m.sessionOption(owner, "@tessera_authority"), "v1 A 1 iPad")
            XCTAssertNil(m.sessionOption(view, "@tessera_authority"))

            // An unset `@` option is an error from 3.3a; 3.2 prints nothing.
            XCTAssertEqual(
                normalized(m.send(mosh, "show-options -v @tessera_authority")),
                version >= .v3_3a
                    ? ["%begin 1", "invalid option: @tessera_authority", "%error 1"]
                    : ["%begin 1", "%end 1"],
                "\(version)"
            )
            XCTAssertEqual(payload(m.send(mosh, "display-message -p '#{@tessera_authority}'")), [""])

            m.send(mosh, "set-option @tessera_authority 'v1 B 1 Pixel'")
            XCTAssertEqual(payload(m.send(ssh, "show-options -v @tessera_authority")), ["v1 A 1 iPad"])
            XCTAssertEqual(payload(m.send(mosh, "show-options -v @tessera_authority")), ["v1 B 1 Pixel"])

            // Presence proof: list-clients -t lists only exact-session clients.
            XCTAssertEqual(payload(m.send(mosh, "list-clients -t O-tessera-view -F '#{client_name}'")), ["mosh-side"])
            XCTAssertEqual(payload(m.send(ssh, "list-clients -t O -F '#{client_name}'")), ["ssh-device"])
            XCTAssertEqual(payload(m.send(ssh, "list-clients -F '#{client_name}'")), ["ssh-device", "mosh-side"])

            // A window-scoped stamp is shared through the window.
            m.send(ssh, "set-option -w @tessera_authority 'v1 A 2 iPad'")
            XCTAssertEqual(m.windowOption(window, "@tessera_authority"), "v1 A 2 iPad")
            XCTAssertEqual(payload(m.send(mosh, "display-message -p '#{@tessera_authority}'")), ["v1 A 2 iPad"])

            // Any detach anywhere reaches every control client.
            let bystander = m.newSession("other", size: CellSize(80, 24)).session
            let unrelated = m.connect(control: "unrelated", session: bystander)
            _ = m.take(mosh)
            m.lose(unrelated)
            XCTAssertEqual(m.take(mosh), ["%client-detached unrelated"])
            XCTAssertEqual(m.take(ssh).filter { $0.hasPrefix("%client-detached") }, ["%client-detached unrelated"])
            assertFullyModelled(m)
        }
    }

    // MARK: D2

    /// D2: the side channel's `refresh-client -C`, `resize-window` and
    /// `set -w -u window-size` never take `latest`, so the unset's
    /// recalculation snaps the window back to the sized laptop that holds it.
    func testD2SideChannelResizeSnapsBackToSizedLatestLaptop() {
        for version in TmuxVersion.allCases {
            let m = TmuxServerModel(version: version)
            let (owner, window) = m.newSession("O", size: CellSize(80, 24), windowName: "w0")
            let view = m.newGroupedSession("O-tessera-view", groupedWith: owner)
            let laptop = m.attachTTY("laptop", session: owner, size: CellSize(200, 50))
            XCTAssertEqual(m.windowSize(window), CellSize(200, 49), "\(version)")
            XCTAssertEqual(m.latest(window), .client("laptop"))
            let side = m.connect(control: "mosh-side", session: view, flags: ["no-output"])
            XCTAssertEqual(m.latest(window), .client("mosh-side"), "attaching moves latest")
            XCTAssertEqual(m.windowSize(window), CellSize(200, 49), "an unsized control client never sizes")
            m.typeKey(laptop)
            XCTAssertEqual(m.latest(window), .client("laptop"), "the laptop typed last")
            _ = m.take(side)

            m.send(side, "refresh-client -C 100,30")
            XCTAssertEqual(m.windowSize(window), CellSize(200, 49), "-C never takes latest (\(version))")

            let replay = m.send(side, "resize-window -x 100 -y 30 -t \(window) ; set-option -w -u -t \(window) window-size")
            XCTAssertEqual(normalized(replay).filter { $0.hasPrefix("%") && !$0.hasPrefix("%layout-change") },
                           ["%begin 1", "%end 1", "%begin 1", "%end 1"])
            let layouts = replay.filter { $0.hasPrefix("%layout-change") }
            XCTAssertEqual(layouts.count, 2, "\(version): \(replay)")
            XCTAssertTrue(layouts.first?.contains("100x30") ?? false, "the manual resize lands first")
            XCTAssertTrue(layouts.last?.contains("200x49") ?? false, "then the unset snaps back")
            XCTAssertEqual(m.windowSize(window), CellSize(200, 49), "\(version)")
            XCTAssertEqual(m.latest(window), .client("laptop"))
            XCTAssertNil(m.windowOption(window, "window-size"))
            assertFullyModelled(m)
        }
    }

    /// D2's fix: a targetless `select-window` in the same line makes the side
    /// channel `latest`, and the forced `-C` pass then sizes from it. A later
    /// laptop keystroke takes `latest` back without any stamp (W4).
    func testD2TargetlessSelectWindowFenceWinsLatest() {
        for version in TmuxVersion.allCases {
            let m = TmuxServerModel(version: version)
            let (owner, window) = m.newSession("O", size: CellSize(80, 24), windowName: "w0")
            let view = m.newGroupedSession("O-tessera-view", groupedWith: owner)
            let laptop = m.attachTTY("laptop", session: owner, size: CellSize(200, 50))
            let side = m.connect(control: "mosh-side", session: view, flags: ["no-output"])
            _ = m.take(side)

            let claim = m.send(side, "select-window ; refresh-client -C 100,30")
            XCTAssertEqual(normalized(claim).filter { !$0.hasPrefix("%layout-change") },
                           ["%begin 1", "%end 1", "%begin 1", "%end 1"])
            XCTAssertEqual(m.windowSize(window), CellSize(100, 30), "\(version)")
            XCTAssertEqual(m.latest(window), .client("mosh-side"))
            XCTAssertEqual(m.currentWindow(view), window, "targetless select-window stays on the view's own window")

            m.typeKey(laptop)
            XCTAssertEqual(m.latest(window), .client("laptop"))
            XCTAssertEqual(m.windowSize(window), CellSize(200, 49), "\(version)")
            XCTAssertTrue(m.take(side).contains { $0.hasPrefix("%layout-change \(window)") && $0.contains("200x49") })
            assertFullyModelled(m)
        }
    }

    /// D2/W2: cmd_find_target's empty target uses cmd_find_from_client;
    /// cmd_select_window_exec sets s->curw->window->latest to the issuer.
    /// cmd_refresh_client_control_client_size installs the grid without
    /// taking latest; cmd_set_option_exec's unset calls recalculate_sizes,
    /// whose clients_calculate_size chooses that latest sizing client.
    func testD2SharedReplayFencesBeforeUnsetAndWinsIdlePlainLatest() throws {
        for version in TmuxVersion.allCases {
            for omitFence in [false, true] {
                let m = TmuxServerModel(version: version)
                let (owner, window) = m.newSession("O", size: CellSize(80, 24))
                let view = m.newGroupedSession("O-view", groupedWith: owner)
                let laptop = m.attachTTY("laptop", session: owner, size: CellSize(160, 48))
                _ = m.attachTTY("visible", session: view, size: CellSize(100, 31), flags: ["ignore-size"])
                let side = m.connect(control: "side", session: view, flags: ["no-output"])
                m.send(side, "refresh-client -C 100,30")
                m.typeKey(laptop)
                XCTAssertEqual(m.latest(window), .client("laptop"))
                // P6: no new -C is needed: the peer cannot change this
                // connection's acknowledged control-client size.
                let commands = TmuxWindowSizeReplay.commands(
                    windowID: WindowId(window.id),
                    requested: try TmuxClientGeometry(columns: 100, rows: 30)
                )
                XCTAssertEqual(commands.count, 4)
                for command in commands.dropLast() where !omitFence || command != "select-window" {
                    m.send(side, command) // one line and one FIFO slot per mutation
                }
                let expected = omitFence ? CellSize(160, 47) : CellSize(100, 30)
                XCTAssertEqual(m.windowSize(window), expected, "\(version) omitFence=\(omitFence)")
                XCTAssertEqual(payload(m.send(side, commands.last!)),
                    ["tessera-window-size\t\(window)\t\(expected.columns)\t\(expected.rows)"])
                XCTAssertEqual(m.latest(window), .client(omitFence ? "laptop" : "side"))
                XCTAssertNil(m.windowOption(window, "window-size"))
                assertFullyModelled(m)
            }
        }
    }

    /// W2: even when the grouped sibling typed most recently and is on a
    /// different window, the replay's targetless fence stays in our view.
    func testD2SharedReplayNeverSwitchesMostActiveGroupedSibling() throws {
        for version in TmuxVersion.allCases {
            let m = TmuxServerModel(version: version)
            let (owner, w0) = m.newSession("O", size: CellSize(80, 24))
            let w1 = m.newWindow(in: owner, name: "other")
            let view = m.newGroupedSession("O-view", groupedWith: owner)
            let laptop = m.attachTTY("laptop", session: owner, size: CellSize(160, 48))
            let side = m.connect(control: "side", session: view)
            m.admin("select-window -t \(owner):\(w1)")
            m.typeKey(laptop)
            m.send(side, "refresh-client -C 100,30")
            for command in TmuxWindowSizeReplay.commands(windowID: WindowId(w0.id),
                requested: try TmuxClientGeometry(columns: 100, rows: 30)) {
                m.send(side, command)
            }
            XCTAssertEqual(m.currentWindow(owner), w1)
            XCTAssertEqual(m.currentWindow(view), w0)
            XCTAssertEqual(m.latest(w0), .client("side"))
            XCTAssertEqual(m.windowSize(w0), CellSize(100, 30))
            assertFullyModelled(m)
        }
    }

    /// W4/P6: every visible keystroke steals latest despite ignore-size.
    /// An owner replay with a newly advertised grid fences it back; a bare
    /// fence also suffices under latest without resize/unset (W11).
    func testD2SharedOwnerReplayAfterVisibleKeyUsesNewestAdvertisedGrid() throws {
        for version in TmuxVersion.allCases {
            let m = TmuxServerModel(version: version)
            let (owner, window) = m.newSession("O", size: CellSize(80, 24))
            let view = m.newGroupedSession("O-view", groupedWith: owner)
            _ = m.attachTTY("laptop", session: owner, size: CellSize(160, 48))
            let visible = m.attachTTY("visible", session: view, size: CellSize(100, 31), flags: ["ignore-size"])
            let side = m.connect(control: "side", session: view)
            m.send(side, "refresh-client -C 100,30")
            m.send(side, "select-window")
            m.typeKey(visible)
            XCTAssertEqual(m.latest(window), .client("visible"))
            m.send(side, "refresh-client -C 90,28")
            XCTAssertEqual(m.windowSize(window), CellSize(100, 30), "ignored latest freezes the window")
            for command in TmuxWindowSizeReplay.commands(windowID: WindowId(window.id),
                requested: try TmuxClientGeometry(columns: 90, rows: 28)) {
                m.send(side, command)
            }
            XCTAssertEqual(m.latest(window), .client("side"))
            XCTAssertEqual(m.windowSize(window), CellSize(90, 28))
            m.typeKey(visible)
            m.send(side, "refresh-client -C 95,29")
            m.send(side, "select-window")
            XCTAssertEqual(m.windowSize(window), CellSize(95, 29), "latest needs no manual resize/unset")
            assertFullyModelled(m)
        }
    }

    // MARK: Mosh keystroke

    /// A keystroke on the mosh visible client (`tmux attach -f ignore-size` on
    /// the view) makes it `latest`. recalculate refuses to size from an
    /// ignore-size client while a sizing client exists, and with two sizing
    /// clients on the window only `latest` may size it, so the window
    /// freezes: even a forced `-C` pass leaves it alone.
    func testMoshKeystrokeMovesLatestToIgnoreSizeClientAndFreezesWindow() {
        for version in TmuxVersion.allCases {
            let m = TmuxServerModel(version: version)
            let (owner, window) = m.newSession("O", size: CellSize(80, 24), windowName: "w0")
            let view = m.newGroupedSession("O-tessera-view", groupedWith: owner)
            let laptop = m.attachTTY("laptop", session: owner, size: CellSize(200, 50))
            let side = m.connect(control: "mosh-side", session: view, flags: ["no-output"])
            m.send(side, "select-window ; refresh-client -C 100,30")
            let visible = m.attachTTY("mosh-visible", session: view, size: CellSize(100, 31), flags: ["ignore-size"])
            XCTAssertEqual(m.latest(window), .client("mosh-visible"), "attach alone moves latest")
            XCTAssertEqual(m.windowSize(window), CellSize(100, 30))

            m.typeKey(laptop)
            XCTAssertEqual(m.windowSize(window), CellSize(200, 49))
            m.send(side, "select-window ; refresh-client -C 100,30")
            XCTAssertEqual(m.windowSize(window), CellSize(100, 30))

            m.typeKey(visible)
            XCTAssertEqual(m.latest(window), .client("mosh-visible"), "\(version)")
            XCTAssertEqual(m.clientFlags(visible), "attached,focused,ignore-size")
            let resizesBefore = m.resizeCount(window)
            m.send(side, "refresh-client -C 90,28")
            XCTAssertEqual(m.windowSize(window), CellSize(100, 30), "frozen (\(version))")
            XCTAssertEqual(m.resizeCount(window), resizesBefore, "no client qualifies, so no resize at all")
            assertFullyModelled(m)
        }
    }

    // MARK: W2

    /// W2: `select-window -t @W` resolves through
    /// cmd_find_best_session_with_window to the most recently active session
    /// holding W. After the laptop types in its grouped session, the device's
    /// tab switch moves the laptop's window instead of its own. `$S:@W`
    /// targets the issuer's session.
    func testW2BareWindowTargetSwitchesGroupedSiblingThatTypedLast() {
        let m = TmuxServerModel(version: .v3_4)
        let (owner, w0) = m.newSession("O", size: CellSize(80, 24), windowName: "w0")
        let w1 = m.newWindow(in: owner, name: "w1")
        let user = m.newGroupedSession("U", groupedWith: owner)
        let laptop = m.attachTTY("laptop", session: user, size: CellSize(200, 50))
        let device = m.connect(control: "device", session: owner)
        _ = m.take(device)

        m.send(device, "select-window -t \(w1)")
        XCTAssertEqual(m.currentWindow(owner), w1, "the device's session was the most recently active")
        m.send(device, "select-window -t \(w0)")
        XCTAssertEqual(m.currentWindow(owner), w0)

        m.typeKey(laptop)
        let switched = m.send(device, "select-window -t \(w1)")
        XCTAssertEqual(m.currentWindow(user), w1, "the laptop's view moved")
        XCTAssertEqual(m.currentWindow(owner), w0, "the device's own session did not")
        XCTAssertEqual(normalized(switched), ["%begin 1", "%end 1", "%session-window-changed \(user) \(w1)"])
        XCTAssertEqual(m.latest(w1), .client("device"), "the issuer still becomes latest of the window it moved")

        m.send(device, "select-window -t '\(owner):\(w1)'")
        XCTAssertEqual(m.currentWindow(owner), w1)
        XCTAssertEqual(
            normalized(m.send(device, "select-window -t '\(owner):@99'")),
            ["%begin 1", "can't find window: @99", "%error 1"]
        )
        assertFullyModelled(m)
    }

    // MARK: W3

    /// W3: `%layout-change` is written as soon as the notification queue
    /// runs, but `%subscription-changed` waits for the subscriber's own
    /// one-second timer, so geometry can lead the subscribed value by up to
    /// one second.
    func testW3SubscriptionLagsLayoutChangeByUpToOneSecond() {
        let m = TmuxServerModel(version: .v3_4)
        let (owner, window) = m.newSession("O", size: CellSize(80, 24), windowName: "w0")
        let device = m.connect(control: "device", session: owner)
        let peer = m.connect(control: "peer", session: owner)
        m.send(peer, "refresh-client -B 'geo:@*:#{window_width}x#{window_height}'")
        _ = m.take(peer)

        m.advance(seconds: 1)
        XCTAssertEqual(m.take(peer), ["%subscription-changed geo \(owner) \(window) 0 - : 80x24"])

        m.advance(seconds: 0.3)
        m.send(device, "refresh-client -C 120,40")
        let layout = m.transcript(peer).last { $0.text.hasPrefix("%layout-change") }!
        XCTAssertTrue(layout.text.contains("120x40"))
        XCTAssertEqual(m.take(peer).filter { $0.hasPrefix("%subscription-changed") }, [], "not yet")

        m.advance(seconds: 1)
        _ = m.take(peer)
        let subscription = m.transcript(peer).last { $0.text.hasPrefix("%subscription-changed") }!
        XCTAssertEqual(subscription.text, "%subscription-changed geo \(owner) \(window) 0 - : 120x40")
        let lag = subscription.time - layout.time
        XCTAssertGreaterThan(lag, 0)
        XCTAssertLessThanOrEqual(lag, 1_000_000)
        XCTAssertEqual(Double(lag) / 1_000_000, 0.7, accuracy: 0.001)

        m.advance(seconds: 3)
        XCTAssertEqual(m.take(peer), [], "unchanged values are not repeated")
        assertFullyModelled(m)
    }

    // MARK: W4

    /// W4: when `latest` disconnects, 3.3a+ hands it to the remaining client
    /// with the newest activity among those showing the window
    /// (server_client_attached_lost); 3.2 leaves it dangling, which freezes
    /// the window while two sizing clients remain.
    func testW4LostLatestHandsOffOn33ButDanglesOn32() {
        for version in TmuxVersion.allCases {
            let m = TmuxServerModel(version: version)
            let (owner, window) = m.newSession("O", size: CellSize(80, 24), windowName: "w0")
            let view = m.newGroupedSession("O-tessera-view", groupedWith: owner)
            let side = m.connect(control: "mosh-side", session: view, flags: ["no-output"])
            m.send(side, "refresh-client -C 90,28")
            let laptop = m.attachTTY("laptop", session: owner, size: CellSize(200, 50))
            m.typeKey(laptop)
            let device = m.connect(control: "device", session: owner)
            m.send(device, "select-window ; refresh-client -C 100,30")
            XCTAssertEqual(m.latest(window), .client("device"))
            XCTAssertEqual(m.windowSize(window), CellSize(100, 30))

            m.lose(device)
            if version.handsOffLatestOnLostClient {
                XCTAssertEqual(m.latest(window), .client("laptop"), "\(version)")
                XCTAssertEqual(m.windowSize(window), CellSize(200, 49), "\(version)")
            } else {
                XCTAssertEqual(m.latest(window), .dangling("device"), "\(version)")
                XCTAssertEqual(m.windowSize(window), CellSize(100, 30), "frozen on \(version)")
            }
            assertFullyModelled(m)
        }
    }

    /// W4: the handoff ignores ignore-size, so a mosh visible client that
    /// typed last inherits `latest` and the window freezes.
    func testW4HandoffCanLandOnIgnoreSizeClient() {
        let m = TmuxServerModel(version: .v3_4)
        let (owner, window) = m.newSession("O", size: CellSize(80, 24), windowName: "w0")
        let view = m.newGroupedSession("O-tessera-view", groupedWith: owner)
        let side = m.connect(control: "mosh-side", session: view, flags: ["no-output"])
        m.send(side, "refresh-client -C 90,28")
        let laptop = m.attachTTY("laptop", session: owner, size: CellSize(200, 50))
        let visible = m.attachTTY("mosh-visible", session: view, size: CellSize(100, 31), flags: ["ignore-size"])
        m.typeKey(laptop)
        m.typeKey(visible)
        let device = m.connect(control: "device", session: owner)
        m.send(device, "select-window ; refresh-client -C 100,30")
        XCTAssertEqual(m.windowSize(window), CellSize(100, 30))

        m.lose(device)
        XCTAssertEqual(m.latest(window), .client("mosh-visible"))
        XCTAssertEqual(m.windowSize(window), CellSize(100, 30), "frozen")
        assertFullyModelled(m)
    }

    // MARK: W9

    /// W9: a failing command drops the rest of its line (cmdq_remove_group):
    /// no `%begin`/`%end` for the dropped commands, and their effects never
    /// happen.
    func testW9ErrorMidLineDropsTheRestOfTheLine() {
        let m = TmuxServerModel(version: .v3_4)
        let (owner, _) = m.newSession("O", size: CellSize(80, 24), windowName: "w0")
        let device = m.connect(control: "device", session: owner)
        _ = m.take(device)

        let lines = m.send(device, "display-message -p first ; select-window -t @9 ; set-option @dropped 1")
        XCTAssertEqual(normalized(lines), [
            "%begin 1", "first", "%end 1",
            "%begin 1", "can't find window: @9", "%error 1",
        ])
        XCTAssertNil(m.sessionOption(owner, "@dropped"))

        // The next line is a new group and runs normally.
        XCTAssertEqual(normalized(m.send(device, "set-option @kept 1")), ["%begin 1", "%end 1"])
        XCTAssertEqual(m.sessionOption(owner, "@kept"), "1")

        // A parse error rejects the whole line before anything runs.
        XCTAssertEqual(
            normalized(m.send(device, "set-option @early 1 ; bogus-command")),
            ["%begin 1", "parse error: unknown command: bogus-command", "%error 1"]
        )
        XCTAssertNil(m.sessionOption(owner, "@early"))
        assertFullyModelled(m)
    }

    // MARK: W10

    /// W10: `refresh-client -C` is never a no-op: `recalculate_sizes_now(1)`
    /// skips the unchanged-size guard, so every window with a size is resized,
    /// `%layout-change` goes out and terminals showing it redraw. Every
    /// `set-option` redraws every attached client.
    func testW10UnchangedRefreshClientSizeStillForcesPassAndRedraws() {
        let m = TmuxServerModel(version: .v3_4)
        let (owner, window) = m.newSession("O", size: CellSize(80, 24), windowName: "w0")
        let user = m.newGroupedSession("U", groupedWith: owner)
        let laptop = m.attachTTY("laptop", session: user, size: CellSize(200, 50))
        let device = m.connect(control: "device", session: owner)
        m.send(device, "select-window ; refresh-client -C 100,30")
        XCTAssertEqual(m.windowSize(window), CellSize(100, 30))

        let resizes = m.resizeCount(window)
        let repaints = m.repaints(laptop)
        let again = m.send(device, "refresh-client -C 100,30")
        XCTAssertEqual(m.windowSize(window), CellSize(100, 30))
        XCTAssertEqual(m.resizeCount(window), resizes + 1)
        XCTAssertEqual(again.filter { $0.hasPrefix("%layout-change") }.count, 1)
        XCTAssertEqual(m.repaints(laptop), repaints + 1)

        // A deferred pass with the same size is a no-op (resize.c:385-395).
        let passes = m.resizeCount(window)
        m.send(device, "select-window")
        XCTAssertEqual(m.resizeCount(window), passes)

        // set-option redraws every attached client (options_push_changes).
        let pushes = m.optionPushes
        let beforeOption = m.repaints(laptop)
        m.send(device, "set-option @tessera_authority 'v1 A 3 iPad'")
        XCTAssertEqual(m.optionPushes, pushes + 1)
        XCTAssertEqual(m.repaints(laptop), beforeOption + 1)

        // `-u` of an unset option is not a change: no push.
        m.send(device, "set-option -u @never-set")
        XCTAssertEqual(m.optionPushes, pushes + 1)
        assertFullyModelled(m)
    }

    /// W10's storm estimate: 10 chord switches, each with `-C`, across 10
    /// windows and 4 control clients is 400 `%layout-change` lines, and the
    /// laptop showing one of the windows repaints once per switch.
    func testW10ChordSwitchStormIsFourHundredLayoutChanges() {
        let m = TmuxServerModel(version: .v3_4)
        let (owner, first) = m.newSession("O", size: CellSize(80, 24), windowName: "w0")
        var windows = [first]
        for index in 1..<10 {
            windows.append(m.newWindow(in: owner, name: "w\(index)"))
        }
        let user = m.newGroupedSession("U", groupedWith: owner)
        let laptop = m.attachTTY("laptop", session: user, size: CellSize(200, 50))
        let controls = (0..<4).map { m.connect(control: "control-\($0)", session: owner) }
        for control in controls {
            m.send(control, "refresh-client -C 100,30")
        }
        let driver = controls[0]
        for index in 0..<10 {
            m.send(driver, "select-window -t :\(index)")
        }
        for window in windows {
            XCTAssertEqual(m.latest(window), .client("control-0"))
        }
        controls.forEach { _ = m.take($0) }
        let repaints = m.repaints(laptop)

        var driverLines: [String] = []
        for index in 0..<10 {
            driverLines += m.send(driver, "select-window -t :\(index) ; refresh-client -C 100,30")
        }
        let layoutLines = (driverLines + controls.flatMap { m.take($0) }).filter { $0.hasPrefix("%layout-change") }
        XCTAssertEqual(layoutLines.count, 400)
        XCTAssertEqual(m.repaints(laptop) - repaints, 10)
        assertFullyModelled(m)
    }
}
